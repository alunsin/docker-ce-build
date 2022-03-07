#!/bin/bash
# Script building the dynamic containerd packages and the static binaries

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

if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_VERS}_${DATE}"
  checkDirectory ${DIR_CONTAINERD}
  DIR_CONTAINERD_COS="${DIR_COS_BUCKET}/containerd-${CONTAINERD_VERS}"
  checkDirectory ${DIR_CONTAINERD_COS}
fi

DIR_LOGS="/workspace/logs"
checkDirectory ${DIR_LOGS}

DIR_LOGS_COS="${DIR_COS_BUCKET}/logs"
checkDirectory ${DIR_LOGS_COS}

PATH_DISTROS_MISSING="/workspace/distros-missing.txt"

# Function to build containerd packages
# $1 : distro
buildContainerd() {
  echo "= Building containerd for $1 ="
  build_before=$SECONDS
  DISTRO=$1
  DISTRO_NAME="$(cut -d'-' -f1 <<<"${DISTRO}")"
  DISTRO_VERS="$(cut -d'-' -f2 <<<"${DISTRO}")"

  TARGET="docker.io/library/${DISTRO_NAME}:${DISTRO_VERS}"
  if [[ "${DISTRO_NAME}:${DISTRO_VERS}" == centos:8* ]]
	then
    ##
    # Switch to quay.io for CentOS 8 stream
    # See https://github.com/docker/containerd-packaging/pull/263
    ##
    echo "Switching to CentOS 8 stream and using quay.io"

    TARGET="quay.io/centos/centos:stream8"
  fi

  echo "Calling make REF=${CONTAINERD_VERS} ${TARGET}"
  cd /workspace/containerd-packaging &&\
   make REF=${CONTAINERD_VERS} ${TARGET} > ${DIR_LOGS}/build_containerd_${DISTRO}.log 2>&1

  RET=$?
  if [[ $RET -ne 0 ]]
	then
	    # The Dockerfile and/or the test_launch.sh is/are missing
	    echo "ERROR: the make command terminated with exit code:$RET"
  fi

  # Check if the dynamic containerd package has been built
  if test -d build/${DISTRO_NAME}/${DISTRO_VERS}
  then
    echo "Containerd for ${DISTRO} built"

    echo "== Copying packages to ${DIR_CONTAINERD} =="
    checkDirectory ${DIR_CONTAINERD}/${DISTRO_NAME}
    cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}

    echo "=== Copying packages to ${DIR_CONTAINERD_COS} ==="
    checkDirectory ${DIR_CONTAINERD_COS}/${DISTRO_NAME}
    cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS}

    echo "==== Copying log to ${DIR_LOGS_COS} ===="
    cp ${DIR_LOGS}/build_containerd_${DISTRO}.log ${DIR_LOGS_COS}/build_containerd_${DISTRO}.log

    # Checking everything has been copied
    if [[ ! -d ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS} || \
          ! -d ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS} ]]
    then
      echo "ERROR: Containerd for ${DISTRO} was not copied."
    fi

  else
    echo "ERROR: Containerd for ${DISTRO} not built"

    echo "== Copying log to ${DIR_LOGS_COS} =="
    cp ${DIR_LOGS}/build_containerd_${DISTRO}.log ${DIR_LOGS_COS}/build_containerd_${DISTRO}.log

    echo "== Log start for the build failure of ${DISTRO} =="
    cat ${DIR_LOGS}/build_containerd_${DISTRO}.log
    echo "== Log end for the build failure of ${DISTRO} =="
  fi
  build_after=$SECONDS
  build_duration=$(expr $build_after - $build_before) \
    && echo "DURATION BUILD containerd ${DISTRO} : $(($build_duration / 60)) minutes and $(($build_duration % 60)) seconds elapsed."
}

if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  echo "= Cloning containerd-packaging ="

  mkdir containerd-packaging
  cd containerd-packaging
  git init
  git remote add origin https://github.com/docker/containerd-packaging.git
  git fetch origin ${CONTAINERD_PACKAGING_REF}
  git checkout FETCH_HEAD

  make REF=${CONTAINERD_VERS} checkout
fi

before=$SECONDS
for PACKTYPE in DEBS RPMS
do
  for DISTRO in ${!PACKTYPE}
  do
    if [[ ${CONTAINERD_BUILD} != "0" ]]
    then
      buildContainerd ${DISTRO}
    else
      # Check if the package is there for this distribution
      echo "= Check containerd ="

      DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_VERS}_${DATE}"

      DISTRO_NAME="$(cut -d'-' -f1 <<<"${DISTRO}")"
      DISTRO_VERS="$(cut -d'-' -f2 <<<"${DISTRO}")"

      if test -d ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}
      then
        echo "${DISTRO} already built"
      else
        echo "== ${DISTRO} missing =="
        if ! test -f ${PATH_DISTROS_MISSING}
        then
          touch ${PATH_DISTROS_MISSING}
        fi
        # Add the distro to the distros-missing.txt
        echo "${DISTRO}" >> ${PATH_DISTROS_MISSING}
      fi
    fi
  done
done
after=$SECONDS
duration=$(expr $after - $before) && echo "DURATION TOTAL CONTAINERD : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

# Build containerd for the distros in ${PATH_DISTROS_MISSING}
if [[ ${CONTAINERD_BUILD} == "0" ]] && test -f ${PATH_DISTROS_MISSING}
then
  echo "= Building containerd - distros missing ="
  if ! test -d containerd-packaging
  then
    mkdir containerd-packaging
    cd /workspace/containerd-packaging
    git init
    git remote add origin https://github.com/docker/containerd-packaging.git
    git fetch origin ${CONTAINERD_PACKAGING_REF}
    git checkout FETCH_HEAD
    make REF=${CONTAINERD_VERS} checkout
  fi

  while read -r line
  do
    buildPackages "containerd" $line
  done < ${PATH_DISTROS_MISSING}
fi

cd /workspace

# Check if the containerd packages have been built
ls ${DIR_CONTAINERD}/*
if [[ $? -ne 0 ]]
then
  # No containerd packages built
  echo "No packages built for containerd"
  exit 1
else
  # Containerd packages built
  echo "Packages built for containerd"
  exit 0
fi
