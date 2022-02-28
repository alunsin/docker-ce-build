#!/bin/bash
# Script building the dynamic docker packages

set -u

set -o allexport
source env.list

# Function to create the directory if it does not exist
checkDirectory() {
  if ! test -d $1
  then
    mkdir $1
    echo "$1 created"
  else
    echo "$1 already created"
  fi
}

DIR_COS_BUCKET="/mnt/s3_ppc64le-docker/prow-docker/build-docker-${DOCKER_VERS}_${DATE}"
checkDirectory ${DIR_COS_BUCKET}

DIR_DOCKER="/workspace/docker-ce-${DOCKER_VERS}_${DATE}"
checkDirectory ${DIR_DOCKER}

DIR_DOCKER_COS="${DIR_COS_BUCKET}/docker-ce-${DOCKER_VERS}"
checkDirectory ${DIR_DOCKER_COS}

DIR_LOGS="/workspace/logs"
checkDirectory ${DIR_LOGS}

DIR_LOGS_COS="${DIR_COS_BUCKET}/logs"
checkDirectory ${DIR_LOGS_COS}

STATIC_LOG="static.log"

# Count of distros
nb=$((`echo $DEBS | wc -w`+`echo $RPMS | wc -w`))

# Workaround for builkit cache issue where fedora-32/Dockerfile
# (or the 1st Dockerfile used by buildkit) is used for all fedora's version
# See https://github.com/moby/buildkit/issues/1368
patchDockerFiles() {
  Dockfiles="$(find $1  -name 'Dockerfile')"
  d=$(date +%s)
  i=0
  for file in ${Dockfiles}; do
      i=$(( i + 1 ))
      echo "patching timestamp for ${file}"
      touch -d @$(( d + i )) "${file}"
  done
}

# Function to build docker packages
# $1 : distro
# $2 : DEBS or RPMS
buildDocker() {
  echo "= Building docker for $1 ="
  build_before=$SECONDS
  DISTRO=$1
  PACKTYPE=$2
  PACKTYPE_TMP=${PACKTYPE,,}
  DIR=${PACKTYPE_TMP:0:3}
  cd /workspace/docker-ce-packaging/${DIR} && VERSION=${DOCKER_VERS} make ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz &> ${DIR_LOGS}/build_docker_${DISTRO}.log

  # Check if the dynamic docker package has been built
  if test -f ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz
  then
    echo "Docker for ${DISTRO} built"

    echo "== Copying dynamic docker packages to ${DIR_DOCKER} =="
    cp -r ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz ${DIR_DOCKER}

    echo "=== Copying packages to ${DIR_DOCKER_COS} ==="
    cp -r ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz ${DIR_DOCKER_COS}

    echo "== Copying log to ${DIR_LOGS_COS} =="
    cp ${DIR_LOGS}/build_docker_${DISTRO}.log ${DIR_LOGS_COS}/build_docker_${DISTRO}.log

    # Checking everything has been copied
    if test -f ${DIR_DOCKER}/bundles-ce-${DISTRO}-ppc64le.tar.gz && test -f ${DIR_DOCKER_COS}/bundles-ce-${DISTRO}-ppc64le.tar.gz && test -f ${DIR_LOGS_COS}/build_docker_${DISTRO}.log
    then
      echo "Docker for ${DISTRO} was copied."
    else
      echo "Docker for ${DISTRO} was not copied."
    fi
  else
    echo "ERROR: Docker for ${DISTRO} not built"

    echo "== Copying log to ${DIR_LOGS_COS} =="
    cp ${DIR_LOGS}/build_docker_${DISTRO}.log ${DIR_LOGS_COS}/build_docker_${DISTRO}.log

    echo "== Log start for the build failure of ${DISTRO} =="
    cat ${DIR_LOGS}/build_docker_${DISTRO}.log
    echo "== Log end for the build failure of ${DISTRO} =="

  fi

  build_after=$SECONDS
  build_duration=$(expr $build_after - $build_before) && echo "DURATION BUILD docker ${DISTRO} : $(($build_duration / 60)) minutes and $(($build_duration % 60)) seconds elapsed."
}

echo "# Building dynamic docker packages #"

cd /workspace/docker-ce-packaging/deb
patchDockerFiles .
cd /workspace/docker-ce-packaging/rpm
patchDockerFiles .
cd /workspace

before=$SECONDS
i=1
for PACKTYPE in DEBS RPMS
do
  for DISTRO in ${!PACKTYPE}
  do
    echo "i : $i"
    n=$(($i%4))
    echo "n = $n"
    if [[ $n -eq "1" ]]
    then
      echo "We initialise the pids"
      pids=()
    fi

    buildDocker ${DISTRO} ${PACKTYPE} &
    declare "pid_$i=$(echo $!)"
    var="pid_$i"
    pids+=( ${!var} )

    if [[ $i -eq $nb ]] || [[ $n -eq "0" ]]
    then
      echo "We wait for the pids"
      wait ${pids[@]}
    fi

    let "i=i+1"
  done
done
after=$SECONDS
duration=$(expr $after - $before) && echo "DURATION TOTAL DOCKER : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

cd /workspace
echo "= Building static binaries ="

before_build=$SECONDS

cd /workspace/docker-ce-packaging/static

CONT_NAME=docker-build-static
if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
then
  docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env PATH_SCRIPTS --env DOCKER_SECRET_AUTH --privileged --name ${CONT_NAME} quay.io/powercloud/docker-ce-build ${PATH_SCRIPTS}/build-static.sh
else
  docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env PATH_SCRIPTS --privileged --name ${CONT_NAME} quay.io/powercloud/docker-ce-build ${PATH_SCRIPTS}/build-static.sh
fi

status_code="$(docker container wait ${CONT_NAME})"
if [[ ${status_code} -ne 0 ]]; then
  echo "The static binaries build failed. See details from '${STATIC_LOG}'"
  docker logs ${CONT_NAME}
else
  after_build=$SECONDS
  duration_build=$(expr $after_build - $before_build)
  echo "DURATION BUILD STATIC : $(($duration_build / 60)) minutes and $(($duration_build % 60)) seconds elapsed."
  docker logs ${CONT_NAME}

  # Check if the static packages have been built
  if test -f build/linux/tmp/docker-ppc64le.tgz
  then
    echo "Static binaries built"

    echo "== Copying static packages to ${DIR_DOCKER} =="
    cp build/linux/tmp/*.tgz ${DIR_DOCKER}

    echo "=== Copying static packages to ${DIR_DOCKER_COS} ==="
    cp build/linux/tmp/*.tgz ${DIR_DOCKER_COS}

    echo "==== Copying log to ${DIR_LOGS_COS} ===="
    cp ${DIR_LOGS}/${STATIC_LOG} ${DIR_LOGS_COS}/${STATIC_LOG}

    # Checking everything has been copied
    ls -f ${DIR_DOCKER}/*.tgz && ls -f ${DIR_DOCKER_COS}/*.tgz && ls -f ${DIR_LOGS_COS}/${STATIC_LOG}
    if [[ $? -eq 0 ]]
    then
      echo "The static binaries were copied."
    else
      echo "The static binaries were not copied."
    fi
  fi
fi

cd /workspace

# Check if the docker-ce packages have been built
ls ${DIR_DOCKER}/*
if [[ $? -ne 0 ]]
then
  # No docker-ce packages built
  echo "No packages built for docker"
  exit 1
else
  # Docker-ce packages built
  echo "Docker packages built"
  exit 0
fi
