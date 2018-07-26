#!/usr/bin/bash

#
# hdp_2.6_installer:
# Usage: 
#     ./hdp_2.6_installer  [ list of slave nodes ] 
# 
# The scrip will install HDP 2.6 on the server from which this script is run. 
# An addition, if a list of slave nodes is present in the command line, the scrip will install Ambari-Agent on the nodes, 
# and install Hadoop services that are listed in the SLAVES_SERVICES array in the code below. 
# All participating servers should have Centos-7 pre-installed
# 
# HDP2.4 may be installed by this by setting 'STACK_VERSION=2.4' below. This option tested only for installing single node. 
#
# 

STACK="HDP"
STACK_VERSION="2.6"
OS_TYPE="centos7"
AMBARI_VER="2.6.1.5"
BASE_URL_AMBARI="http://public-repo-1.hortonworks.com/ambari/${OS_TYPE}/2.x/updates/${AMBARI_VER}"

# Master
FQDN_HOSTNAME=`hostname -f`

# SLAVE_HOSTS - lists the hostnames for installing slave nodes.  
# Values passed from command line. if no argoments are given, the install is on a single node.
SLAVE_HOSTS=($@)


function MAIN {

    setup_password_less_ssh 
    setup_password_less_ssh_on_slaves $SLAVE_HOSTS
    # be aware that setup_etc_hosts_on_all() modifies $SLAVE_HOSTS so hosts comply with FQDN 
    setup_etc_hosts_on_all $SLAVE_HOSTS
    prepare_the_environment 
    ambari_install 
    setup_mysql
    ambari_server_config_and_start 
    ambari_agent_config_and_start
    set_ambari_agent_on_slaves $SLAVE_HOSTS
    write_blueprint_json
    blueprint_install

    echo "Install process can be monitored at: http://${FQDN_HOSTNAME}:8080/ "
    echo "User/Password:   admin/admin"

}

function setup_password_less_ssh { 
    if [ ! -f /root/.ssh/id_rsa ]; then
        cat /dev/zero | ssh-keygen -q -N ""
    fi

    cd /root/.ssh
    cat id_rsa.pub >> authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys

    reply=`ssh -o StrictHostKeyChecking=no $FQDN_HOSTNAME date`
    if [ -z "$reply" ]; then
        echo 'Error in ssh-keygen process. Please confirm manually and run the script again'
        echo 'Exiting ... '
        exit
    fi
    cd -
}

function setup_password_less_ssh_on_slaves {
    local slave_hosts=$1

    echo "#############################################################"
    echo "## Setting password-less login on the hosts used as slaves ##"
    echo "#############################################################"

    for slave in ${SLAVE_HOSTS[@]} 
    do
        echo -e "\nSetting password-less login on slave host: $slave"
        echo    "Please enter the password for: $slave"
        cat ~/.ssh/id_rsa.pub | ssh -o StrictHostKeyChecking=no ${slave} 'mkdir -p .ssh && cat >> .ssh/authorized_keys'
    done
    
    # now test it
    ssh_login_error=""
    for slave in ${SLAVE_HOSTS[@]}
    do
        reply=`ssh  -o BatchMode=yes $slave date`
        if [ -z "$reply" ]; then
            echo "Error in setting password_less_ssh_on_slave: ${slave}. "
            echo "Please confirm manually and run the script again"
            ssh_login_error=1
        fi
    done

    if [ -n "$ssh_login_error" ]; then
        exit
    fi
}

function setup_etc_hosts_on_all {

    local slave_hosts=$1
    local get_hostname_error=""
    local etc_hosts_duplicates_error=""

    echo "#############################################################"
    echo "## Testing/Setting FQDN on slaves ##"
    echo "#############################################################"

    # build array with the hostnames 
    local short_hostnames=( $(hostname) )
    local fqdn_hostnames=( $(hostname -f) )
    local my_ip=$(getent ahostsv4 $FQDN_HOSTNAME | grep STREAM | awk '{print $1}')
    local etc_host_entries="\n# HDP cluster hosts \n${my_ip} $(hostname -f) $(hostname)"

    # test that $my_ip looks like a valid ipv4. 
    if [ $(tr -dc '.' <<< "$my_ip" | wc -c) -ne "3" ]; then
        # found more than the 3 expected dots in the ip. something is wrong.
        echo ERROR in getting local IP. A common error is an invalid entry or multiple entries in /etc/hosts
        echo "     resolve the issue and run this script once again" 
        exit
    fi        
        
    for slave in ${SLAVE_HOSTS[@]} 
    do
        local short_name=$(ssh -o BatchMode=yes $slave hostname)
        local long_name=$(ssh -o BatchMode=yes $slave hostname -f)

        if [ -z "$short_name" ] || [ -z "$long_name" ]; then
            echo ERROR in getting remote names of : ${slave}. 
            echo Please confirm & fix manually by running "ssh ${slave} hostname" and run the script again
            get_hostname_error="${get_hostname_error}${slave} \n"
        fi

        short_hostnames=("${short_hostnames[@]}"  $short_name)
        fqdn_hostnames=("${fqdn_hostnames[@]}"  $long_name)
        etc_host_entries="${etc_host_entries}\n$(getent ahostsv4 $slave | grep STREAM | awk '{print $1}') ${long_name} ${short_name}" 
    done

    etc_host_entries="${etc_host_entries}\n\n"
    
    if [ -n "$get_hostname_error" ]; then
        echo -e "ERROR - unable to get hostname of the following:\n${get_hostname_error}"
        exit
    fi

    # test if any has $my_ip in /etc/hosts, if not - add all participating hosts 
    local host_to_search=("$FQDN_HOSTNAME" "${SLAVE_HOSTS[@]}")
    for host in ${host_to_search[@]} 
    do
        echo "INFO: inspecting ${host}:/etc/hosts"
        local entry_count=$(ssh -o BatchMode=yes $host "grep -c $my_ip /etc/hosts")
        if [ "$entry_count" -eq "0" ]; then
            echo "INFO: adding participants to ${host}:/etc/hosts" 
            echo -e "$etc_host_entries" | ssh -o StrictHostKeyChecking=no ${host} ' cat >> /etc/hosts'
        elif [ "$entry_count" -eq "1" ]; then
            echo -e "\n  *** Attention:  ${host}:/etc/hosts includes the master ($my_ip) - Not addind anything and assuming it is all correct  *** \n"         
        elif [ "$entry_count" -gt "1" ]; then
            echo -e "\n  *** ERROR:  ${host}:/etc/hosts contain ${entry_count} entries for ${my_ip} - fix it manually and try again *** \n" 
            etc_hosts_duplicates_error="${etc_hosts_duplicates_error} ${host}"
        fi
    done

    if [ -n "$etc_hosts_duplicates_error" ]; then
        echo -e "ERROR - The folowing hosts include multiple entries in /etc/hosts :\n${etc_hosts_duplicates_error}"
        exit
    fi
    
    SLAVE_HOSTS=(${fqdn_hostnames[@]:1})
}

function prepare_the_environment {
    
    yum install -y ntp
    systemctl is-enabled ntpd
    systemctl enable ntpd
    systemctl start ntpd    
    
    systemctl disable firewalld
    service firewalld stop
    
    # Disable SELinux (Security Enhanced Linux).
    setenforce 0

    # Turn off iptables. 
    iptables -L        ; # but first check its status 
    iptables -F
    
    # Stop PackageKit 
    service packagekit status
    service packagekit stop
    
    # Read-Write-execute: already set in /etc/profile for Centos7. 
    umask 0022

    # IF permanent change is required for ulimit, need to edit /etc/security/limits.conf. However, such instructions do not appear in the install guide:
    # HORTONWORKS DOCS » APACHE AMBARI 2.6.1.5 » APACHE AMBARI INSTALLATION guide. 
    
    # set ulimit
    ulimit_sn=`ulimit -Sn`
    ulimit_hn=`ulimit -Hn`
    
    if [ "$ulimit_sn" -lt 10000 -a "$ulimit_hn" -lt 10000 ] 
    then
        echo "Setting: ulimit -n 10000"
        ulimit -n 10000
    fi
    
}


function ambari_install {
    echo "INFO: Installing ambari server from:  $BASE_URL_AMBARI"
    echo "This section downloads the required packages to run ambari-server."
    
    wget -nv ${BASE_URL_AMBARI}/ambari.repo -O /etc/yum.repos.d/ambari.repo
    yum repolist
    
    yum install -y ambari-server 
    
}

function setup_mysql {
    wget http://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
    rpm -ivh mysql-community-release-el7-5.noarch.rpm
    #yum update -y 

    yum install mysql-server -y 
    # Be aware that the server binds to localhost. good enough for this install. 
    systemctl start mysqld
    
    # MySql connector download page: https://dev.mysql.com/downloads/connector/j/
    local ver="5.1.46"
    wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-${ver}.tar.gz -O /tmp/mysql-connector-java-${ver}.tar.gz

    cd /usr/lib
    tar xvfz /tmp/mysql-connector-java-${ver}.tar.gz
    mkdir -p /usr/share/java/
    ln -s /usr/lib/mysql-connector-java-${ver}/mysql-connector-java-${ver}-bin.jar /usr/share/java/mysql-connector-java.jar
    cd - 
    
}


function ambari_server_config_and_start {
    echo "INFO: ambari_config_start:"
    echo "    Detailed explanation and instructions for manual install and configuration of ambari-server at:" 
    echo "    https://docs.hortonworks.com/HDPDocuments/Ambari-2.6.1.0/bk_ambari-installation/content/set_up_the_ambari_server.html "
    
    # setup with the MySql connector installed previously
    ambari-server setup -s 
    ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar
    ambari-server start
} 

function ambari_agent_config_and_start {
    yum install ambari-agent -y 
    # in a single-node cluster, setting the hostname is not mandatory
    sed /etc/ambari-agent/conf/ambari-agent.ini -i.ORIG -e "s/hostname=localhost/hostname=${FQDN_HOSTNAME}/"
    ambari-agent start   
}

function set_ambari_agent_on_slaves {
    local slave_hosts=$1
    for slave in ${SLAVE_HOSTS[@]}
    do
        echo "Remove FW and security from: $slave"
        ssh -o StrictHostKeyChecking=no $slave "$(typeset -f prepare_the_environment); prepare_the_environment"
        echo "Node Registration: $slave"
        scp -p /etc/yum.repos.d/ambari.repo  $slave:/etc/yum.repos.d/ambari.repo
        ssh -o BatchMode=yes  $slave "yum install ambari-agent -y"
        scp -p /etc/ambari-agent/conf/ambari-agent.ini  $slave:/etc/ambari-agent/conf/ambari-agent.ini
        ssh -o BatchMode=yes  $slave "ambari-agent start"
    done
    echo "Nodes Registration DONE"
}


function download_helper_files {
    # the Helper file may use to assist in setup config files. (Not implemented) 
    wget http://public-repo-1.hortonworks.com/HDP/tools/2.6.0.3/hdp_manual_install_rpm_helper_files-2.6.0.3.8.tar.gz
    tar zxvf hdp_manual_install_rpm_helper_files-2.6.0.3.8.tar.gz
    PATH_HDP_MANUAL_INSTALL_RPM_HELPER_FILES=`pwd`/hdp_manual_install_rpm_helper_files-2.6.0.3.8
}

function set_hadoop_config {
    # Partially implemented 
    # upon completion, this functions set: SERVICES_CONFIG with valid JSON configuration. 
    used_ram_gb=$1 # 10
    container_ram=$2  # 2024


    used_ram_mb="$((used_ram_gb * 1024))"
    used_ram_mb_div_10="$((used_ram_mb / 10))"
    
    # TODO: 
    # Not using the version as in the default: 
    #    "yarn.app.mapreduce.am.command-opts" : "-Xmx ...  -Dhdp.version=${hdp.version}",
    # Omitted:
    #   "mapreduce.task.io.sort.mb" 
    
# yarn.scheduler.minimum-allocation-mb=6144          : "$container_ram"            
# yarn.scheduler.maximum-allocation-mb=49152        : "$used_ram_mb"
# yarn.nodemanager.resource.memory-mb=49152        : "$used_ram_mb"
# mapreduce.map.memory.mb=6144                    : "$container_ram"
# mapreduce.map.java.opts=-Xmx4915m                : "$used_ram_mb_div_10"
# mapreduce.reduce.memory.mb=6144                : "$container_ram"
# mapreduce.reduce.java.opts=-Xmx4915m            : "$used_ram_mb_div_10"
# yarn.app.mapreduce.am.resource.mb=6144            : "$container_ram"
# yarn.app.mapreduce.am.command-opts=-Xmx4915m    : "$used_ram_mb_div_10"
# mapreduce.task.io.sort.mb=2457
 


read -r -d '' YARN_SITE <<EOF
    {
      "yarn-site" : {
        "properties_attributes" : { },
        "properties" : {
          "yarn.scheduler.minimum-allocation-mb" : "$container_ram",
          "yarn.scheduler.maximum-allocation-mb" : "$used_ram_mb",
          "yarn.nodemanager.resource.memory-mb" : "$used_ram_mb"
        }
      }
    }
EOF

# There's another config, so add separator 


read -r -d '' MAPRED_SITE <<EOF
    {
      "mapred-site" : {
        "properties_attributes" : { },
        "properties" : {
            "mapreduce.map.memory.mb" :  "$container_ram",
            "mapreduce.map.java.opts" :  "-Xmx${used_ram_mb_div_10}m",
            "mapreduce.reduce.memory.mb" :  "$container_ram",
            "mapreduce.reduce.java.opts" :  "-Xmx${used_ram_mb_div_10}m",  
            "yarn.app.mapreduce.am.resource.mb" :  "$container_ram",
            "yarn.app.mapreduce.am.command-opts" :  "-Xmx${used_ram_mb_div_10}m"
        }
      }
    }
EOF

    # concatenate to $services_config all the configs created above. Separate with commas 
    
    SERVICES_CONFIG="$YARN_SITE,$MAPRED_SITE"
    
    valid_json=$(echo "[  $SERVICES_CONFIG ] " | python -m json.tool >> /dev/null && echo "0"  || echo "1" )
    if [ "$valid_json" == "1" ]; then 
        echo "***********************************************************"
        echo "ERROR: the following services configuration not in a valid JSON format:  "
        echo 
        echo "[  $SERVICES_CONFIG ] "
        echo "***********************************************************"
    fi     
    
    }  #########  end of function     set_hadoop_config  ################


function write_blueprint_json {
    # This function expect 3 parameters: blueprint_name, cluster_name FQDN_HOSTNAME. Defaults are set below if not passed. 
    # $STACK_VERSION is mandatory global variable. 
    # $SERVICES_CONFIG is optionally set previously. 


    blueprint_name=${1:-hdp-setup-bluprint}
    cluster_name=${2:-host_group_1}
    FQDN_HOSTNAME=${3:-$FQDN_HOSTNAME}


    stack_version_int=$(echo $STACK_VERSION | tr -d ".")
    # Can add below  more definitions for HDP_xxx_STACK. The stack to install is determined by "$STACK_VERSION" by taking the digits 
    # and omitting the dot (.)


    # the SPARK clients are not installed on the master for cluster install. 
    # Therefor, need to add it explicitly for single-node install. 
    # (In this deployment, the cluster is managed by YARN and NOT by Spark.)
    if [ ${#SLAVE_HOSTS[@]} -eq 0 ]; 
    then 
        # Single node 
         read -r -d '' services_not_to_install_on_master <<EOF
        { "name" : "SPARK2_CLIENT" },
        { "name" : "SPARK_CLIENT" },
        { "name" : "NODEMANAGER" },
        { "name" : "DATANODE" },
EOF
    fi

    read -r -d '' HDP_26_STACK <<EOF
        { "name" : "HIVE_SERVER" },
        ${services_not_to_install_on_master}
        { "name" : "METRICS_MONITOR" },
        { "name" : "HIVE_METASTORE" },
        { "name" : "TEZ_CLIENT" },
        { "name" : "ZOOKEEPER_CLIENT" },
        { "name" : "HCAT" },
        { "name" : "SPARK2_JOBHISTORYSERVER" },
        { "name" : "SPARK_JOBHISTORYSERVER" },        
        { "name" : "WEBHCAT_SERVER" },
        { "name" : "ACTIVITY_ANALYZER" },
        { "name" : "SECONDARY_NAMENODE" },
        { "name" : "HST_AGENT" },
        { "name" : "SLIDER" },
        { "name" : "ZOOKEEPER_SERVER" },
        { "name" : "METRICS_COLLECTOR" },
        { "name" : "METRICS_GRAFANA" },
        { "name" : "YARN_CLIENT" },
        { "name" : "HDFS_CLIENT" },
        { "name" : "HST_SERVER" },
        { "name" : "MYSQL_SERVER" },
        { "name" : "HISTORYSERVER" },
        { "name" : "NAMENODE" },
        { "name" : "PIG" },
        { "name" : "ACTIVITY_EXPLORER" },
        { "name" : "MAPREDUCE2_CLIENT" },
        { "name" : "AMBARI_SERVER" },
        { "name" : "APP_TIMELINE_SERVER" },
        { "name" : "HIVE_CLIENT" },
        { "name" : "RESOURCEMANAGER"  }
EOF
        

    read -r -d '' HDP_24_STACK <<EOF
        { "name" : "NODEMANAGER"},
        { "name" : "HIVE_SERVER"},
        { "name" : "METRICS_MONITOR"},
        { "name" : "HIVE_METASTORE"},
        { "name" : "TEZ_CLIENT"},
        { "name" : "ZOOKEEPER_CLIENT"},
        { "name" : "HCAT"},
        { "name" : "WEBHCAT_SERVER"},
        { "name" : "SECONDARY_NAMENODE"},
        { "name" : "ZOOKEEPER_SERVER"},
        { "name" : "METRICS_COLLECTOR"},
        { "name" : "SPARK_CLIENT"},
        { "name" : "YARN_CLIENT"},
        { "name" : "HDFS_CLIENT"},
        { "name" : "MYSQL_SERVER"},
        { "name" : "HISTORYSERVER"},
        { "name" : "NAMENODE"},
        { "name" : "PIG"},
        { "name" : "MAPREDUCE2_CLIENT"},
        { "name" : "AMBARI_SERVER"},
        { "name" : "DATANODE"},
        { "name" : "SPARK_JOBHISTORYSERVER"},
        { "name" : "APP_TIMELINE_SERVER"},
        { "name" : "HIVE_CLIENT"},
        { "name" : "RESOURCEMANAGER"}
EOF
        

    read -r -d '' SLAVES_SERVICES <<EOF
        { "name" : "NODEMANAGER"},
        { "name" : "HDFS_CLIENT"},
        { "name" : "MAPREDUCE2_CLIENT"},
        { "name" : "SPARK_CLIENT"},
        { "name" : "SPARK2_CLIENT"},
        { "name" : "DATANODE"}
EOF

        
    HDP_STACK="HDP_${stack_version_int}_STACK"

# Create JSONs

    function gen_slave_hosts_json {
        local slave_hosts=""
        local num_slave_hosts=${#SLAVE_HOSTS[@]}
        local index=0
#        if [ $num_slave_hosts -gt 0 ]; then 
            for host in ${SLAVE_HOSTS[@]}; do
                let "index++"
                slave_hosts="$slave_hosts\n\t\t{ \"fqdn\" : \"${host}\" }"
                if [ $index -lt $num_slave_hosts ]; then
                    slave_hosts="$slave_hosts, "
                fi
            done
#        fi
        read -r -d '' slave_hosts_str <<EOF
        {
          "name" : "slaves",
          "hosts" : [
          $slave_hosts
          ]
        }
EOF

    if [ $num_slave_hosts -gt 0 ]; then 
        echo -e ",$slave_hosts_str"
    fi
    }

    slave_hosts_json=$(gen_slave_hosts_json)

    cat <<EOF > hostmapping.json
{
  "blueprint" : "${blueprint_name}",
  "default_password" : "admin",
  "host_groups" :[
    {
      "name" : "${cluster_name}",
      "hosts" : [
        {
          "fqdn" : "${FQDN_HOSTNAME}"
        }
      ]
    }
    $slave_hosts_json
  ]
}
EOF


    cat <<EOF > cluster_configuration.json
{   "configurations" : [ 
    $SERVICES_CONFIG
    ], 
    "host_groups" : [ { "name" : "${cluster_name}", "components" : [ 
        ${!HDP_STACK}
      ],        
      "cardinality" : "1"
    }, 
    { "name" : "slaves", "components" : [ 
        ${SLAVES_SERVICES}
      ],        
      "cardinality" : "1"
    }    
  ],
  "Blueprints" : {
    "blueprint_name" : "${blueprint_name}",
    "stack_name" : "${STACK}",
    "stack_version" : "${STACK_VERSION}"
  }
}
EOF

}   ###### end of: write_blueprint_json   ##################################################


function blueprint_install {

# Can take 3 optional parameters:
#     $blueprint_name $cluster_name $dest_hostname 
# Consider adding 2 (or more) optional parameters for the memory and other config parameters. 


blueprint_name=${1:-hdp-setup-bluprint}
cluster_name=${2:-host_group_1}
dest_hostname=${3:-$FQDN_HOSTNAME}

# TODO: Once tuned for performance, can you set_hadoop_config() to set those parameters at install time.   

#set_hadoop_config

#write_repo_json should register the specific stack version to install. The Ambari version used here seems not to interpret it correctly. 
#Most liekely later Ambari releases fixed it. Not tested again. 
#write_repo_json()

curl -H "X-Requested-By: ambari" -X POST -u admin:admin http://${dest_hostname}:8080/api/v1/blueprints/${blueprint_name} -d @cluster_configuration.json
curl -H "X-Requested-By: ambari" -X POST -u admin:admin http://${dest_hostname}:8080/api/v1/clusters/${cluster_name} -d @hostmapping.json

}

#####################  EXECUTE  Predefined Functions #########

MAIN $@

