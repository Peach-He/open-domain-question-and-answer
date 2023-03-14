#!/bin/bash
# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

cores_per_worker=0
head_address='0.0.0.0'
usage() {
  echo "Usage: $0 -r [run_type] [optional parameters]"
  echo "  options:"
  echo "    -h Display usage"
  echo "    -r run_type"
  echo "         Run type = [startup_all, startup_workers, stop_ray, clean_ray, stop_es, clean_ray, clean_all]"
  echo "         The recommendation is a single instance using no more than a single socket."
  echo "    -e es_cores"
  echo "         Core number of ElasticSearch  = [1..n = Cores]"
  echo "    -u head_address"
  echo "         Ray head address (127.0.0.1)"
  echo "    -s cores_per_worker"
  echo "         Cores per Ray worker, for multi-instance indexing"
  echo "    -c cores_per_head"
  echo "         Cores per Ray head, for multi-instance indexing"
  echo "    -m mkldnn_verbose"
  echo "         MKLDNN_VERBOSE value"
  echo "    -d database"
  echo "         startup the database=[postgresql, elasticsearch, all]"
  echo "    -f dataset"
  echo "         folder path of mounting to docker container"
  echo "    -w workspace"
  echo "         folder path of workspace which includes you source code"
  echo "    -b es_data"
  echo "         data folder path of mounting to elasticsearch database container"
  echo "    -p postgres_data"
  echo "         data folder path of mounting to postgresql database container"
  echo ""
  echo "  examples:"
  echo "    Startup the ray cluster "
  echo "      $0 -r startup_all -e 4 -c 10 -s 40"
  echo ""
}

while getopts "h?r:s:e:u:c:m:d:f:w:b:p:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 1
        ;;
    r)  run_type=$OPTARG
        ;;
    e)  es_cores=$OPTARG
        ;;
    u)  head_address=$OPTARG
        ;;
    s)  cores_per_worker=$OPTARG
        ;;
    c)  cores_per_head=$OPTARG
        ;;
    m)  verbose=$OPTARG
        ;;
    d)  database=$OPTARG
        ;;
    f)  dataset=$OPTARG
        ;;
    w)  workspace=$OPTARG
        ;;
    b)  es_data=$OPTARG
        ;;
    p)  postgres_data=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

[ "${1:-}" = "--" ] && shift


## Override default values for values specified by the user

if [ ! -z "$es_cores" ]; then
  es_cores=$es_cores
fi

if [ ! -z "$head_address" ]; then
  head_address=$head_address
fi

if [ ! -z "$cores_per_worker" ]; then
  cores_per_worker=$cores_per_worker
fi

if [ ! -z "$cores_per_head" ]; then
  cores_per_head=$cores_per_head
fi

if [ ! -z "$verbose" ]; then
    export MKLDNN_VERBOSE=$verbose
fi

if [ ! -z $database ]; then
    database=$database
fi

if [ ! -z $dataset ]; then
    dataset=$dataset
fi

if [ ! -z $workspace ]; then
    workspace=$workspace
fi

if [ ! -z $es_data ]; then
    es_data=$es_data
fi

if [ ! -z $postgres_data ]; then
    postgres_data=$postgres_data
fi

CORES=`lscpu | grep 'Core(s)' | awk '{print $4}'`
SOCKETS=`cat /proc/cpuinfo | grep 'physical id' | sort | uniq | wc -l`
total_cores=`expr $CORES \* $SOCKETS \* 2`
start_core_idx=0
stop_core_idx=`expr $total_cores - 1`
cores_range=${start_core_idx}'-'${stop_core_idx}
post_fix=`date +%Y%m%d`'-'`date +%s`

if [[ $run_type = "startup_all" ]]; then
    echo "cores_range = ${cores_range}"
    es_stop_core_idx=`expr $es_cores - 1`
    es_cores_range=${start_core_idx}'-'${es_stop_core_idx}
    start_core_idx=`expr $start_core_idx + $es_cores`
    ray_head_cores_range=${start_core_idx}'-'`expr $start_core_idx + ${cores_per_head} - 1`
    echo "es_cores_range = ${es_cores_range}"
    echo "ray_head_cores_range = ${ray_head_cores_range}"
    start_core_idx=`expr $start_core_idx + $cores_per_head`
    available_cores=`expr $total_cores - $es_cores - $cores_per_head`
    echo "available_cores = ${available_cores}"
    echo "cores_per_worker = ${cores_per_worker}"
    #worker_num='0'
    if [[ $cores_per_worker -eq 0 ]]; then
        worker_num=0
    else 
        worker_num=`expr $available_cores / ${cores_per_worker}`
    fi
    echo "worker_num = ${worker_num}"
    echo "head_address=$head_address"
    head_name='head''-'${post_fix}
    es_image='elasticsearch:7.9.2'
    if [[ $database = "elasticsearch" ]] || [[ $database = "all" ]]; then
        es_name='elasticsearch-'${post_fix}
        if [ ! -z $es_data ]; then
            docker run -d --name $es_name  --network host --cpuset-cpus=${es_cores_range} --shm-size=8gb -e "discovery.type=single-node" \
                -v ${es_data}:/usr/share/elasticsearch/data \
                -e ES_JAVA_OPTS="-Xmx8g -Xms8g" ${es_image}
        else
            docker run -d --name $es_name  --network host --cpuset-cpus=${es_cores_range} --shm-size=8gb -e "discovery.type=single-node" \
                -e ES_JAVA_OPTS="-Xmx8g -Xms8g" ${es_image}
        fi
    fi

    if [[ $database = "postgresql" ]] || [[ $database = "all" ]]; then
        postgres_name='postgres-'${post_fix}
        if [ ! -z $postgres_data ]; then
            docker run --network host -d --name $postgres_name -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
                -v ${postgres_data}:/var/lib/postgresql/data --cpuset-cpus=${es_cores_range} postgres:14.1-alpine
        else
            docker run --network host -d --name $postgres_name -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
                --cpuset-cpus=${es_cores_range} postgres:14.1-alpine
        fi
        sleep 5
        docker exec -d $postgres_name psql -U postgres -c "CREATE DATABASE haystack;"
    fi

    sleep 10
    docker run -itd -p 8265:8265 --cap-add=NET_ADMIN --network host -v ${workspace}:/home/user/indexing -v ${dataset}:/home/user/dataset \
            --cpuset-cpus=${ray_head_cores_range} \
            --shm-size=64gb --name $head_name haystack-ray /bin/bash  &
    sleep 5
    #docker exec -d $head_name /bin/bash -c "ip link del dev eth1"
    docker exec -d $head_name /bin/bash -c "ray start --node-ip-address=${head_address} --head --dashboard-host='0.0.0.0' --dashboard-port=8265"
    #head_address=`docker inspect --format '{{ .NetworkSettings.IPAddress }}' $head_name`
    head_address=${head_address}':6379'
    echo "head_address=$head_address"
    for (( i = 0; i < ${worker_num}; i++ ))
    do
        ray_worker_cores_range=${start_core_idx}'-'`expr $start_core_idx + ${cores_per_worker} - 1`
        echo "ray_worker_cores_range = ${ray_worker_cores_range}"
        worker_name='ray-'$i'-'${post_fix}
        docker run -itd --cpuset-cpus=${ray_worker_cores_range} --cap-add=NET_ADMIN --network host -v ${workspace}:/home/user/indexing -v ${dataset}:/home/user/dataset \
                --shm-size=2gb \
                --name $worker_name  haystack-ray  /bin/bash &
        sleep 5
        #docker exec -d $worker_name /bin/bash -c "ip link del dev eth1"
        docker exec -d $worker_name /bin/bash -c "ray start --address=$head_address"
        start_core_idx=`expr $start_core_idx + $cores_per_worker`
    done

elif [[ $run_type = "startup_workers" ]]; then
    echo "cores_range = ${cores_range}"
    head_address=${head_address}':6379'
    echo "head_address=$head_address"
    worker_num=`expr $total_cores / ${cores_per_worker}`
    echo "worker_num = ${worker_num}"

    for (( i = 0; i < ${worker_num}; i++ ))
    do
        ray_worker_cores_range=${start_core_idx}'-'`expr $start_core_idx + ${cores_per_worker} - 1`
        echo "ray_worker_cores_range = ${ray_worker_cores_range}"
        worker_name='ray-'$i'-'${post_fix}
        docker run -itd --cpuset-cpus=${ray_worker_cores_range} --cap-add=NET_ADMIN --network host  -v ${dataset}:/home/user/dataset\
                --shm-size=2gb \
                --name $worker_name  haystack-ray  /bin/bash &
        sleep 5
        #docker exec -d $worker_name /bin/bash -c "ip link del dev eth1"
        docker exec -d $worker_name /bin/bash -c "ray start --address=$head_address"
        start_core_idx=`expr $start_core_idx + $cores_per_worker`
    done

elif [[ $run_type = "stop_ray" ]]; then
    echo "stop ray containers"
    docker stop $(docker ps -a |grep -E 'head|ray'|awk '{print $1 }')

elif [[ $run_type = "clean_ray" ]]; then
    echo "clean ray containers"
    docker rm $(docker ps -a |grep -E 'head|ray'|awk '{print $1 }')

elif [[ $run_type = "stop_es" ]]; then
    echo "stop elasticsearch container"
    docker stop $(docker ps -a |grep -E 'elasticsearch'|awk '{print $1 }')

elif [[ $run_type = "clean_es" ]]; then
    echo "clear elasticsearch container"
    docker rm $(docker ps -a |grep -E 'elasticsearch'|awk '{print $1 }')
    
elif [[ $run_type = "clean_all" ]]; then
    echo "stop and clear ray and elasticsearch container"
    docker stop $(docker ps -a |grep -E 'head|ray|elasticsearch|postsql'|awk '{print $1 }')
    docker rm $(docker ps -a |grep -E 'head|ray|elasticsearch|postsql'|awk '{print $1 }')
fi
