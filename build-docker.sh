#!/bin/bash
# Script building the dynamic docker packages

set -u

set -o allexport
source env.list

NCPUs=`grep processor /proc/cpuinfo | wc -l`
echo "Nber of available CPUs: ${NCPUs}"

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

DIR_COS_BUCKET="/mnt/s3_ppc64le-docker/prow-docker/build-docker-${DOCKER_REF}_${DATE}"
checkDirectory ${DIR_COS_BUCKET}

DIR_DOCKER="/workspace/docker-ce-${DOCKER_REF}_${DATE}"
checkDirectory ${DIR_DOCKER}

DIR_DOCKER_COS="${DIR_COS_BUCKET}/docker-ce-${DOCKER_REF}"
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

##
# Patch GO image so that we use bullseye instead of buster which is EOL
# For instance the golang:1.18.6-buster is only supported for x86
##
patchGoVersion() {
  MKFILE_PATH=$1/Makefile

  echo "Patching GO image from buster to bullseye for $MKFILE_PATH"
  sed -ri  's/GO_VERSION\)\-buster/GO_VERSION\)\-bullseye/' $MKFILE_PATH
}

# Function to build docker packages
# $1 : distro
# $2 : DEBS or RPMS
buildDocker() {
  echo "= Building docker for $1 ="
  local build_before=$SECONDS
  local DISTRO=$1
  local PACKTYPE=$2
  local PACKTYPE_TMP=${PACKTYPE,,}
  local DIR=${PACKTYPE_TMP:0:3}
  cd /workspace/docker-ce-packaging/${DIR} && VERSION=${DOCKER_REF} make ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz &> ${DIR_LOGS}/build_docker_${DISTRO}.log

  # Check if the dynamic docker package has been built
  if test -f ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz
  then
    echo "Docker for ${DISTRO} built"

    echo "== Copying dynamic docker package bundles-ce-${DISTRO}-ppc64le.tar.gz to ${DIR_DOCKER} =="
    cp -r ${DIR}build/bundles-ce-${DISTRO}-ppc64le.tar.gz ${DIR_DOCKER}

    echo "== Copying dynamic docker package bundles-ce-${DISTRO}-ppc64le.tar.gz to ${DIR_DOCKER_COS} =="
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

  local build_after=$SECONDS
  local build_duration=$(expr $build_after - $build_before) && echo "DURATION BUILD docker ${DISTRO} : $(($build_duration / 60)) minutes and $(($build_duration % 60)) seconds elapsed."
}

echo "# Building dynamic docker packages #"

cd /workspace/docker-ce-packaging/deb
patchDockerFiles .
cd /workspace/docker-ce-packaging/rpm
patchDockerFiles .
cd /workspace

patchGoVersion /workspace/docker-ce-packaging/deb
patchGoVersion /workspace/docker-ce-packaging/rpm

before=$SECONDS
# 1) Build the list of distros
# List of Distros that appear in the list though they are EOL or must not be built
DisNo+=( "ubuntu-impish" "debian-buster" )
for PACKTYPE in DEBS RPMS
do
  for DISTRO in ${!PACKTYPE}
  do
    No=0
    for (( d=0 ; d<${#DisNo[@]} ; d++ ))
    do
      if [ ${DISTRO} == ${DisNo[d]} ]
      then
        No=1
        break
      fi
    done
    if [ $No -eq 0 ]
    then
      echo "Distro / Packtype: ${DISTRO} / ${PACKTYPE}"
      Dis+=( $DISTRO )
      Pac+=( $PACKTYPE )
    fi
  done
done
nD=${#Dis[@]}
echo "Number of distros: $nD"

# 2) Launch builds and wait for them in parallel
# Max number of builds running in parallel:
max=${NCPUs}
# Current number of builds being run:
n=0
# Index of Distro & Build in the pids[] Dis[] and Pac[] arrays:
i=0
while true
do
  while [ $n -lt $max ] && [ $i -lt ${nD} ]
  do
    buildDocker ${Dis[i]} ${Pac[i]} &
    pids+=( $! )
    echo "Build distrib: i:$i ${Dis[i]} pid:${pids[i]}"
    let "n=n+1"
    let "i=i+1"
#    echo "i: $i  n: $n"
  done
#  echo "PIDs: ${pids[*]}"
  for (( j=0 ; j<${#pids[@]} ; j++ ))
  do
    pid=${pids[j]}
    if [ ${pid} -ne 0 ]
    then
      break
    fi
  done
  echo "Waiting for '${pid}' '${Dis[j]}' build to complete"
  wait ${pid}
  echo "            '${pid}' '${Dis[j]}' build completed"
  pids[j]=0
  let "n=n-1"
#  echo "i: $i  n: $n" 
  if [ $n -eq 0 ]
  then
    break
  fi
done
after=$SECONDS
duration=$(expr $after - $before) && echo "DURATION TOTAL DOCKER : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

cd /workspace
echo "= Building static binaries ="

before_build=$SECONDS

cd /workspace/docker-ce-packaging/static

CONT_NAME=docker-build-static
# https://quay.io/repository/powercloud/docker-ce-build?tab=tags
QUAYIO_REPOSITORY="powercloud"
# Test ! Test a new DockerInDocker image before pushing it to Raji's Production Cluster
# https://quay.io/repository/trex58i/docker-ce-build?tab=tags
#QUAYIO_REPOSITORY="trex58i"
if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
then
  DOCKER_SECRET_AUTH_IN_ENV="--env DOCKER_SECRET_AUTH"
else
  DOCKER_SECRET_AUTH_IN_ENV=""
fi
docker run -d \
           -v /workspace:/workspace \
           -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} \
           -v ${ARTIFACTS}:${ARTIFACTS} \
           --env PATH_SCRIPTS \
           ${DOCKER_SECRET_AUTH_IN_ENV} \
           --privileged \
           --name ${CONT_NAME} \
           quay.io/${QUAYIO_REPOSITORY}/docker-ce-build \
           ${PATH_SCRIPTS}/build-static.sh

status_code="$(docker container wait ${CONT_NAME})"
if [[ ${status_code} -ne 0 ]]; then
  # Save static build logs
  echo "==== Copying static log to ${DIR_LOGS_COS}/${STATIC_LOG} ===="
  cp ${DIR_LOGS}/${STATIC_LOG} ${DIR_LOGS_COS}/${STATIC_LOG}
  
  # Note: Messages from build-static.sh and build-docker.sh are not always echoed by "docker logs" in temporal order
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

    echo "==== Copying static log to ${DIR_LOGS_COS}/${STATIC_LOG} ===="
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
