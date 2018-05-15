# hdp26_and_hibench_install

The package installs Hadoop HDP2.6 + HiBench package to assist in benchmark tests of various environments and settings. The installer assumes Centos-7 installed on all participating nodes


### Package Content
* hdp_2.6_install.sh – script to install HDP, either as a single node or cluster
* HiBench_install_config_generator.pl – CFG file generator for HiBench_install.sh installer
* HiBench_install.sh – script to install ML section from the HiBench Package. 

### Using it

* Short setup instructions
```
# Download the installer
yum install git -y
git clone https://github.com/lovengulu/hdp26_and_hibench_install.git
cd hdp26_and_hibench_install

# On the master node, run the following line. 
# To install on a single node, run without parameters. 
./hdp_2.6_install.sh  [slave1 slave2 … ]

# Generate CFG file for installing HiBench
./HiBench_install_config_generator.pl

# Review the config file. Edit it if needed. 
cat HiBench_install.cfg

# Once satisfied, run the installer:
./HiBench_install.sh
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
