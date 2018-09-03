#!/usr/bin/bash
#
# HiBench - K-Means test installer
# 
# 1. Set prerequsuits (Install JAVA, mvn)
# 2. Build K-Means test package.
# 3. Set initial configuration 
# 4. Show brief instructions to run test
# 


# Get Install parameters 
source HiBench_install.cfg

# some minimal verification 
if [[ ! -d $HIBENCH_SPARK_HOME  ]]; then 
    echo "ERROR: The direcory $HIBENCH_SPARK_HOME does NOT exists. Fix the variable HIBENCH_SPARK_HOME to the correct path and run this script again" 
	exit
fi

# remove trailing slash - if exsits. 
HIBENCH_SPARK_HOME=${HIBENCH_SPARK_HOME%/}
# find out if using "spark" or "spark2" 
SPARK_VER=$(echo $HIBENCH_SPARK_HOME | sed  's/.*\///')


# Parameters for the install process.  
TMP_DIR=/tmp
FQDN=$(hostname -f)

JDK_DOWNLOAD_PATH="http://download.oracle.com/otn-pub/java/jdk/8u181-b13/96a7b8442fe848ef90c96a2fad6ed6d1/jdk-8u181-linux-x64.tar.gz"

#################################

function MAIN {
    install_prerequsuits
	install_HiBench
	set_configuration
	brief_test_instructions
}	

function install_prerequsuits {
    yum install git wget -y

    # Install JAVA 
    cd $TMP_DIR
    jdk_file=$(basename $JDK_DOWNLOAD_PATH)
    wget -c --header "Cookie: oraclelicense=accept-securebackup-cookie" $JDK_DOWNLOAD_PATH
    cd /usr/jdk64/
    tar xvf $TMP_DIR/$jdk_file
    jdk_dir=$(ls -1td jdk* | grep -v tar  | sort | tail -1)

    # Set JAVA_HOME for the rest of this session and later for running HiBench tests. 
    export JAVA_HOME=/usr/jdk64/$jdk_dir
    echo "export JAVA_HOME=$JAVA_HOME" >> ~hdfs/.bash_profile


    # Install MVN
	latest_maven_release="3.5.3"
    cd $TMP_DIR
	# Use archive so the script doesn't break upon new release of maven
    #wget http://apache.spd.co.il/maven/maven-3/${latest_maven_release}/binaries/apache-maven-${latest_maven_release}-bin.tar.gz
	wget https://archive.apache.org/dist/maven/maven-3/${latest_maven_release}/binaries/apache-maven-${latest_maven_release}-bin.tar.gz 
    tar xvfz apache-maven-${latest_maven_release}-bin.tar.gz
    export PATH=$PATH:/tmp/apache-maven-${latest_maven_release}/bin

}

function install_HiBench {
    cd /opt
    git clone https://github.com/intel-hadoop/HiBench.git
    cd /opt/HiBench/

	if [ $SPARK_VER = "spark" ]; then
        mvn -Phadoopbench -Psparkbench -Dspark=1.6 -Dscala=2.10 clean package
	else
		mvn -Psparkbench -Dmodules -Pml  -Dspark=2.2 -Dscala=2.11 clean package
	fi

    chmod -R 777 /opt/HiBench/
}

function set_configuration { 
    
    #
    # CONFIGS
    #
    # 1. This function adjust the following tree configuration files based on the variables that are set above:
    #     /opt/HiBench/conf/hadoop.conf
    #     /opt/HiBench/conf/hibench.conf
    #     /opt/HiBench/conf/spark.conf
    #    IT IS ADVISED TO REVIEW THE CHANGES VS. THE ORIGINAL/TEMPLATE FILES
	# 
    # 2. The properties of the K-Means test are difined at: /opt/HiBench/conf/workloads/ml/kmeans.conf
    #    This script does NOT modify this file. The user may adjust those properties if needed. 	

	
	
    # write hadoop.conf based on the template 
    sed /opt/HiBench/conf/hadoop.conf.template  -e "s=/PATH/TO/YOUR/HADOOP/ROOT=/usr/hdp/current/hadoop-client= ;
                                                   s=hibench.hadoop.release\(\s*\)\(.*\)=hibench.hadoop.release\1\hdp=  ; 
    											   s=localhost:8020=$FQDN:8020="   > /opt/HiBench/conf/hadoop.conf
    
    # write hibench.conf based on the template 
    sed -i.BAK /opt/HiBench/conf/hibench.conf -e "s/\(hibench.scale.profile[ \t]*\)[[:alnum:]]*/\1${HIBENCH_SCALE_PROFILE}/ ; 
                                                  s/\(hibench.masters.hostnames\).*/\1\t\t${FQDN}/ ; 
                                                  s/\(hibench.slaves.hostnames\).*/\1\t\t${FQDN}/  ;
                                                  s/\(hibench.workload.input\).*/\1\t\tInput/      ;
                                                  s/\(hibench.workload.output\).*/\1\t\tOutput/"
    											  


	# write spark.conf based on the HERE-DOCUMENT template
	# but first, save the ORIG (or PREVIOUS version) 
	local conf_file='/opt/HiBench/conf/spark.conf'
	[[ -e "${conf_file}.ORIG" ]] && cp -p  ${conf_file} ${conf_file}.PREVIOUS  || mv ${conf_file} ${conf_file}.ORIG

    read -r -d '' SPARK_CONF <<EOF
# Spark home
hibench.spark.home      $HIBENCH_SPARK_HOME

# Spark master
#   standalone mode: spark://xxx:7077
#   YARN mode: yarn-client
hibench.spark.master    yarn-client

# executor number and cores when running on Yarn
hibench.yarn.executor.num     $HIBENCH_YARN_EXECUTOR_NUM
hibench.yarn.executor.cores   $HIBENCH_YARN_EXECUTOR_CORES

# executor and driver memory in standalone & YARN mode
spark.executor.memory  $SPARK_EXECUTOR_MEMORY
spark.driver.memory    $SPARK_DRIVER_MEMORY
spark.yarn.executor.memoryOverhead $SPARK_YARN_EXECUTOR_MEMORYOVERHEAD
spark.yarn.driver.memoryOverhead $SPARK_YARN_DRIVER_MEMORYOVERHEAD
spark.memory.offHeap.size $SPARK_MEMORY_OFFHEAP_SIZE

spark.eventLog.enabled=true
spark.eventLog.dir=hdfs://${FQDN}:8020/spark-history
spark.yarn.historyServer.address=http://${FQDN}:18080/
spark.history.fs.logDirectory=hdfs://${FQDN}:8020/spark-history
spark.executor.extraJavaOptions=-XX:+UseLargePages -XX:+PrintGC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps

# set spark parallelism property according to hibench's parallelism value
spark.default.parallelism     \${hibench.default.map.parallelism}

# set spark sql's default shuffle partitions according to hibench's parallelism value
spark.sql.shuffle.partitions  \${hibench.default.shuffle.parallelism}

#======================================================
# Spark Streaming
#======================================================
# Spark streaming Batchnterval in millisecond (default 100)
hibench.streambench.spark.batchInterval          100

# Number of nodes that will receive kafka input (default: 4)
hibench.streambench.spark.receiverNumber        4

# Indicate RDD storage level. (default: 2)
# 0 = StorageLevel.MEMORY_ONLY
# 1 = StorageLevel.MEMORY_AND_DISK_SER
# other = StorageLevel.MEMORY_AND_DISK_SER_2
hibench.streambench.spark.storageLevel 0

# indicate whether to test the write ahead log new feature (default: false)
hibench.streambench.spark.enableWAL false

# if testWAL is true, this path to store stream context in hdfs shall be specified. If false, it can be empty (default: /var/tmp)
hibench.streambench.spark.checkpointPath /var/tmp

# whether to use direct approach or not (dafault: true)
hibench.streambench.spark.useDirectMode true
EOF
    ###############
    echo "$SPARK_CONF" > $conf_file

	
}


function brief_test_instructions {
cat <<EOF

# Once the install completes without errors, can run a test by:
# login to hdfs:
su - hdfs 

# prepare test sample:
/opt/HiBench/bin/workloads/ml/kmeans/prepare/prepare.sh

# run a test: 
/opt/HiBench/bin/workloads/ml/kmeans/spark/run.sh

# TBD: 
#  - Where to test the results. 
#  - ignore an error.  /dev/stderr: Permission denied
#  - what is the purpose of: hdfs dfs -ls /HiBench

EOF

}

##################################

MAIN 


