#!/bin/bash -e
##-------------------------------------------------------------------
## File : start_docker_container.sh
## Author : Denny <denny.zhang001@gmail.com>
## Description :
## --
## Created : <2015-05-28>
## Updated: Time-stamp: <2015-08-04 10:03:11>
##-------------------------------------------------------------------
image_name=${1?"docker image name"}
image_repo_name=${image_name%:*}

function log() {
    local msg=${1?}
    echo -ne `date +['%Y-%m-%d %H:%M:%S']`" $msg\n"

    if [ -n "$LOG_FILE" ]; then
        echo -ne `date +['%Y-%m-%d %H:%M:%S']`" $msg\n" >> $LOG_FILE
    fi
}

function ensure_is_root() {
    # Make sure only root can run our script
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root." 1>&2
        exit 1
    fi
}

function os_release() {
    set -e
    distributor_id=$(lsb_release -a 2>/dev/null | grep 'Distributor ID' | awk -F":\t" '{print $2}')
    if [ "$distributor_id" == "RedHatEnterpriseServer" ]; then
        echo "redhat"
    elif [ "$distributor_id" == "Ubuntu" ]; then
        echo "ubuntu"
    else
        if grep CentOS /etc/issue 1>/dev/null 2>/dev/null; then
            echo "centos"
        else
            if uname -a | grep '^Darwin' 1>/dev/null 2>/dev/null; then
                echo "osx"
            else
                echo "ERROR: Not supported OS"
            fi
        fi
    fi
}
################################################################################################
function docker_pull_image() {
    local image_repo_name=${1?}
    local image_name=${2?}
    local flag_file=${3?}
    command="docker pull $image_name"

    old_image_id=""
    if docker images | grep $image_repo_name; then
        old_image_id=$(docker images | grep $image_repo_name | awk -F' ' '{print $3}')
    fi

    log "docker pull $image_name, this steps may take tens of minutes."
    set +e
    docker pull $image_name
    if [ $? -eq 0 ]; then
        log "Retry: docker pull $image_name, in case doggy internet issue."
        docker pull $image_name
    fi
    set -e

    new_image_id=$(docker images | grep $image_repo_name | awk -F' ' '{print $3}')

    if [ "$old_image_id" = "$new_image_id" ]; then
        echo "no" > $flag_file
    else
        echo "yes" > $flag_file
    fi
}

function is_container_running(){
    local container_name=${1?}
    if docker ps -a | grep $container_name 1>/dev/null 2>/dev/null; then
        if docker ps | grep $container_name 1>/dev/null 2>/dev/null; then
            echo "running"
        else
            echo "dead"
        fi
    else
        echo "none"
    fi
}

function shell_exit() {
    exit_code=$?
    END=$(date +%s)
    DIFF=$(echo "$END - $START" | bc)
    log "Track time spent: $DIFF seconds"
    if [ $exit_code -eq 0 ]; then
        log "All set. Let's try Jenkins now: http://192.168.50.10:28080"
    else
        log "ERROR: the procedure failed"
    fi
    exit $exit_code
}

function config_auto_start() {
    service_name=${1?}
    local os_release_name=$(os_release)
    if [ "$os_release_name" == "ubuntu" ]; then
        update-rc.d docker_sandbox defaults
        update-rc.d docker_sandbox enable
    fi

    if [ "$os_release_name" == "redhat" ] || [ "$os_release_name" == "centos" ]; then
        chkconfig docker_sandbox on
    fi
}

################################################################################################
START=$(date +%s)
ensure_is_root

trap shell_exit SIGHUP SIGINT SIGTERM 0

# set PATH, just in case binary like chmod can't be found
PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log "prepare shared directory for docker"
mkdir -p /root/docker/

log "Install autostart script for /etc/init.d/docker_sandbox"
curl -o /etc/init.d/docker_sandbox \
     https://raw.githubusercontent.com/DennyZhang/data/master/vagrant/docker_sandbox.sh
chmod 755 /etc/init.d/docker_sandbox
config_auto_start "docker_sandbox"

log "Start docker of docker-jenkins"
flag_file="image.txt"

docker_pull_image $image_repo_name $image_name $flag_file
image_has_new_version=`cat $flag_file`

container_name="docker-jenkins"
container_status=$(is_container_running $container_name)
if [ $container_status = "running" ] && [ "$image_has_new_version" = "yes" ]; then
    log "$image_name has new version, stop old running container: $container_name"
    docker stop $container_name
    docker rm $container_name
    container_status="none"
fi

if [ $container_status = "none" ]; then
    docker run -d -t --privileged -v /root/docker/:/var/lib/jenkins/code/ \
           --name $container_name -p 5022:22 -p 28000:28000 -p 28080:28080 -p 3128:3128 \
           $image_name /usr/sbin/sshd -D
elif [ $container_status = "dead" ]; then
    docker start $container_name
fi

log "Start docker of docker-all-in-one"
container_name="docker-all-in-one"
container_status=$(is_container_running $container_name)
if [ $container_status = "running" ] && [ "$image_has_new_version" = "yes" ]; then
    log "$image_name has new version, stop old running container: $container_name"
    docker stop $container_name
    docker rm $container_name
    container_status="none"
fi

if [ $container_status = "none" ]; then
    # TODO:
    docker run -d -t --privileged --name $container_name \
           -p 10000-10050:10000-10050 -p 80:80 -p 443:443 \
           -p 6022:22 -p 1389:1389 $image_name /usr/sbin/sshd -D
elif [ $container_status = "dead" ]; then
    docker start $container_name
fi

log "Start services inside docker"
service docker_sandbox start

for d in `ls -d /root/docker/*`; do
    rm -rf $d/*
done

chmod 777 -R /root/docker/

log "Check docker containers: docker ps"
docker ps
## File : start_docker_container.sh ends
