#!/bin/bash
DAEMON="dockerd"

DIR_LOGS="/workspace/logs"
DOCKERD_LOG="${DIR_LOGS}/dockerd.log"

case "${1}" in
  start)
    # Call dockerd-entrypoint to start dockerd, then check that dockerd has started

    #
    if ! test -d ${DIR_LOGS}
    then
      echo "Creating logging directory: ${DIR_LOGS}"
      mkdir -p ${DIR_LOGS}
    fi

    # Start the docker daemon in the background
    echo "Starting dockerd with '--mtu=1440' in order to be compatible with Calico on K8S"
    bash /usr/local/bin/dockerd-entrypoint.sh --mtu=1440 > ${DOCKERD_LOG} 2>&1 &
    echo "dockerd logs redirected to:${DOCKERD_LOG}"
    
    # Check if dockerd has started
    while ! /usr/bin/pgrep ${DAEMON}
    do
        echo "Waiting for dockerd pid"
        sleep 14
    done

    PID=`/usr/bin/pgrep $DAEMON`
    echo "${DAEMON} pid:${PID}"

    if [ "${PID}" ]
    then
        while ! docker stats --no-stream
        do
            echo "Waiting for dockerd to start"
            sleep 10
            if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]] && [ ! -d /root/.docker ]
            then
                mkdir /root/.docker
                echo "${DOCKER_SECRET_AUTH}" > /root/.docker/config.json
                echo "Docker login"
            fi
            echo "Launching docker info"
            docker info
        done
    fi
    ;;
  stop)
    /usr/bin/pkill ${DAEMON}
    sleep 10
    while /usr/bin/pgrep ${DAEMON} && ! ps -e | grep ${DAEMON} | grep -q defunct
    do
        /usr/bin/pkill -9 ${DAEMON}
        sleep 5
    done
    ;;
  *)
    echo "Usage: ${0} [start|stop]"
    ;;
esac
