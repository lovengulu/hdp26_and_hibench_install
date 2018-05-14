#!/usr/bin/perl

# Amount of memory to leave (for OS and Hadoop Daemons)
$reserve_mem_gb=10;
# Number of cpus to reserve (for OS and Hadoop Daemons etc.)
$reserve_cpu=2;
# As rule of thumb, 4 or 5 core per executors yields the best CPU utilization
$number_of_cores_per_executor=2; 

# Calculate the required properties based on the settings above and the current hardware in deployment
$tot_mem_kb = `grep MemTotal: /proc/meminfo | awk '{print \$2}' ` ;
$tot_cpu =  `lscpu  | grep '^CPU(s):' | awk '{print  \$2}'` ; 
chomp $tot_cpu;

$avilable_cpu = $tot_cpu - $reserve_cpu;
$avilable_mem = $tot_mem_kb - $reserve_mem_gb * 1024 * 1024;

$num_of_nodes = `curl  -H "X-Requested-By: ambari" -X GET -u admin:admin http://localhost:8080/api/v1/hosts | grep host_name | wc -l`;

$num_of_executors = int($avilable_cpu / $number_of_cores_per_executor); 
print "mem_per_executor = int($avilable_mem / $num_of_executors / 1024\n";
$mem_per_executor = int($avilable_mem / $num_of_executors / 1024);

$spark_executor_memory_gb = int($mem_per_executor * 0.93 /1024); 
$spark_yarn_executor_memoryoverhead_mb = int($mem_per_executor * 0.07);

# Assuming all nodes have similar hardware
$num_of_executors_in_all_nodes = $num_of_executors * $num_of_nodes;

$hdp_version = `ls -tr /usr/hdp/ | grep 2\. | head -1` ;
chomp $hdp_version;


# config_content is template for configuring the HiBench_install script. 
# The calculations for filling this template are in this script under the template.  

$config_content = <<"EOF";
# HIBENCH_SCALE_PROFILE - Available value is tiny, small, large, huge, gigantic and bigdata
HIBENCH_SCALE_PROFILE=small

# executor number and cores when running on Yarn
HIBENCH_YARN_EXECUTOR_NUM=$num_of_executors_in_all_nodes
HIBENCH_YARN_EXECUTOR_CORES=$number_of_cores_per_executor

# executor and driver memory in standalone & YARN mode
SPARK_EXECUTOR_MEMORY=${spark_executor_memory_gb}g
SPARK_DRIVER_MEMORY=2g
SPARK_YARN_EXECUTOR_MEMORYOVERHEAD=${spark_yarn_executor_memoryoverhead_mb}
SPARK_YARN_DRIVER_MEMORYOVERHEAD=400
SPARK_MEMORY_OFFHEAP_SIZE=1024m

# Be sure to configure here the correct directory. (remember that spark and spark2 are NOT in the same directory)
HIBENCH_SPARK_HOME=/usr/hdp/${hdp_version}/spark2

EOF


$cfg_file="HiBench_install.cfg";


open CFG, '>', $cfg_file or die "Cannot open $cfg_file: $!";

print CFG $config_content;

