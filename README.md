# hdp26_and_hibench_install

The package installs Hadoop HDP2.6 + HiBench package to assist in benchmark tests of various environments and settings. The installer assumes Centos-7 installed on all participating nodes

### Package Content
* hdp_2.6_install.sh – script to install HDP, either as a single node or cluster
* HiBench_install_config_generator.pl – CFG file generator for HiBench_install.sh installer
* HiBench_install.sh – script to install ML section from the HiBench Package. 

### Important 
The installer should be run as root. 
As Hadoop requires reverse DNS ability, the installer writes all participating hosts to /etc/hosts of all of them. 
The installer perform additional actions like turning off firewall and setting passwordless login between the master
and other participants. 
For more details please see the HDP install document at: 
https://docs.hortonworks.com/HDPDocuments/Ambari-2.6.2.0/bk_ambari-installation/content/prepare_the_environment.html 

### Using it

* Short setup instructions
```
# Download the installer
yum install git wget -y
git clone https://github.com/lovengulu/hdp26_and_hibench_install.git
cd hdp26_and_hibench_install

# On the master node, run the following line. 
# To install on a single node, run without parameters. 
# For cluster, specify a list of slaves to install as follows:
./hdp_2.6_install.sh  [slave1.MySite.com slave2.MySite.com … ]

# Wait! 
# The Hadoop install process continues in the background after the script is done. This can take several minutes. 
# DO NOT PROCEED WITH THE NEXT STEP BEFORE Hadoop install is complete.
# To monitor the Hadoop and the install process, point your web browser to http://<your.ambari.server>:8080
# Tip1: The last lines of the installer output spell out the link to the ambari server and the user/paswword. 
# Tip2: After the HDP install is complete and before runng any test, it is required to to manually configure YARM memory and restart the depending services. 
#       The enclosed "hdp26_and_HiBench_Install_Instructions" PDF document gives a brief explanation on doing so. 
#       Consult HDP documentation if more details are needed. 


# Generate CFG file for installing HiBench
./HiBench_install_config_generator.pl

# Review the config file. Edit it if needed. 
cat HiBench_install.cfg

# Once satisfied, run the installer:
./HiBench_install.sh

# Reminder: If YARM memory not configured by now, be sure to do so before running the test below. 
# It is ok to configure YARN and restart the required services while the "HiBench_install" procedure is running.  


```

* Run test:

```
# to run tests, login as “hdfs”:
su – hdfs

# prepare test sample:
/opt/HiBench/bin/workloads/ml/kmeans/prepare/prepare.sh

# run a test: 
/opt/HiBench/bin/workloads/ml/kmeans/spark/run.sh
```

## Known issues:
*  hdp_2.6_install.sh  installs fine but some of the services don't start automatically. Those services do start manually. 


