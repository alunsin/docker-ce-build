#!/bin/bash
# Script building the dynamic containerd packages and the static binaries

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

if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_REF}_${DATE}"
  checkDirectory ${DIR_CONTAINERD}
  DIR_CONTAINERD_COS="${DIR_COS_BUCKET}/containerd-${CONTAINERD_REF}"
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
  local build_before=$SECONDS
  local DISTRO=$1
  local DISTRO_NAME="$(cut -d'-' -f1 <<<"${DISTRO}")"
  local DISTRO_VERS="$(cut -d'-' -f2 <<<"${DISTRO}")"

  local TARGET="docker.io/library/${DISTRO_NAME}:${DISTRO_VERS}"

  # Create a directory for building in // the Distros
  mkdir /workspace/containerd-packaging-${DISTRO}
  cp -r /workspace/containerd-packaging-ref/* /workspace/containerd-packaging-${DISTRO}
  
  if [[ "${DISTRO_NAME}:${DISTRO_VERS}" == centos:8 ]]
  then
    ##
    # Switch to quay.io for CentOS 8 stream
    # See https://github.com/docker/containerd-packaging/pull/263
    ##
    echo "Switching to CentOS 8 stream and using quay.io"

    TARGET="quay.io/centos/centos:stream8"

  elif [[ "${DISTRO_NAME}:${DISTRO_VERS}" == centos:9 ]]
  then
    ##
    # Switch to quay.io for CentOS 9 stream
    # See https://github.com/docker/containerd-packaging/pull/283
    ##
    echo "Switching to CentOS 9 stream and using quay.io"

    TARGET="quay.io/centos/centos:stream9"
  fi

  local MAKE_OPTS="REF=${CONTAINERD_REF}"
  if [[ ! -z "${CONTAINERD_GO_VERSION}" ]]
  then
    MAKE_OPTS+=" GOLANG_VERSION=${CONTAINERD_GO_VERSION}"
  fi

  echo "Calling make ${MAKE_OPTS} ${TARGET}"
  cd /workspace/containerd-packaging-${DISTRO} && \
    make ${MAKE_OPTS} ${TARGET} > ${DIR_LOGS}/build_containerd_${DISTRO}.log 2>&1

  local RET=$?
  if [[ $RET -ne 0 ]]
	then
	    # The Dockerfile and/or the test-launch.sh is/are missing
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
  local build_after=$SECONDS
  local build_duration=$(expr $build_after - $build_before) \
    && echo "DURATION BUILD containerd ${DISTRO} : $(($build_duration / 60)) minutes and $(($build_duration % 60)) seconds elapsed."
}

if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  echo "= Cloning containerd-packaging ="

  mkdir containerd-packaging-ref
  cd containerd-packaging-ref
  git init
  git remote add origin https://github.com/docker/containerd-packaging.git
  git fetch origin ${CONTAINERD_PACKAGING_REF}
  git checkout FETCH_HEAD


  if [[ ! -z "${CONTAINERD_RUNC_REF}" ]]
  then
    export RUNC_REF=${CONTAINERD_RUNC_REF}
  fi

  make REF=${CONTAINERD_REF} checkout
fi

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
        echo "Distro: ${DISTRO}"
        Dis+=( $DISTRO )
    fi
  done
done
nD=${#Dis[@]}
echo "Number of distros: $nD"

if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  # 2) Launch builds and wait for them in parallel
  # Max number of builds running in parallel:
  max=${NCPUs}
  # Current number of builds being run:
  n=0
  # Index of Distro & Build in the pids[] Dis[] array:
  i=0
  while true
  do
    while [ $n -lt $max ] && [ $i -lt ${nD} ]
    do
      buildContainerd ${Dis[i]} &
      pids+=( $! )
      echo "Build distrib: i:$i ${Dis[i]} pid:${pids[i]}"
      let "n=n+1"
      let "i=i+1"
  #   echo "i: $i  n: $n"
    done
  # echo "PIDs: ${pids[*]}"
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
else
  # Don't build
  for (( d=0 ; d<${#Dis[@]} ; d++ ))
  do
    DISTRO=${Dis[d]}
    # Check if the package is there for this distribution
    echo "= Check containerd ="

    DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_REF}_${DATE}"

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
  done
fi
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
    make REF=${CONTAINERD_REF} checkout
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
