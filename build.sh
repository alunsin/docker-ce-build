#!/bin/bash
# Script building the docker-ce and containerd packages and the static binaries

set -ue

set -o allexport
source env.list
source env-distrib.list

DIR_DOCKER="/workspace/docker-ce-${DOCKER_VERS}_${DATE}"
if ! test -d ${DIR_DOCKER}
then
  mkdir ${DIR_DOCKER}
fi

DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_VERS}_${DATE}"
if ! test -d ${DIR_CONTAINERD}
then
  mkdir ${DIR_CONTAINERD}
fi

DIR_LOGS="/workspace/logs"
if ! test -d ${DIR_LOGS}
then
  mkdir ${DIR_LOGS}
fi

DIR_COS_BUCKET="/mnt/s3_ppc64le-docker/prow-docker/build-docker-${DOCKER_VERS}_${DATE}"
if ! test -d ${DIR_COS_BUCKET}
then
  mkdir ${DIR_COS_BUCKET}
fi

DIR_DOCKER_COS="${DIR_COS_BUCKET}/docker-ce-${DOCKER_VERS}"
if ! test -d ${DIR_DOCKER_COS}
then
  mkdir ${DIR_DOCKER_COS}
fi

DIR_CONTAINERD_COS="${DIR_COS_BUCKET}/containerd-${CONTAINERD_VERS}"
if ! test -d ${DIR_CONTAINERD_COS}
then
  mkdir ${DIR_CONTAINERD_COS}
fi

DIR_LOGS_COS="${DIR_COS_BUCKET}/logs"
if ! test -d ${DIR_LOGS_COS}
then
  mkdir ${DIR_LOGS_COS}
fi

PATH_DISTROS_MISSING="/workspace/distros-missing.txt"

STATIC_LOG="static.log"

echo "# Building docker-ce #" 2>&1 | tee -a ${LOG}

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

before_build_DEBS=$SECONDS

pushd /workspace/docker-ce-packaging/deb
patchDockerFiles .
for DEB in ${DEBS}
do
  echo "= Building for ${DEB} =" 2>&1 | tee -a ${LOG}

  VERSION=${DOCKER_VERS} make debbuild/bundles-ce-${DEB}-ppc64le.tar.gz &> ${DIR_LOGS}/build_docker_${DEB}.log

  if test -f debbuild/bundles-ce-${DEB}-ppc64le.tar.gz
  then
    echo "${DEB} built" 2>&1 | tee -a ${LOG}

    echo "== Copying packages to ${DIR_DOCKER} and to the internal COS Bucket ==" 2>&1 | tee -a ${LOG}
    cp -r debbuild/bundles-ce-${DEB}-ppc64le.tar.gz ${DIR_DOCKER}
    cp -r debbuild/bundles-ce-${DEB}-ppc64le.tar.gz ${DIR_DOCKER_COS}

    echo "== Copying log to ${DIR_LOGS_COS} ==" 2>&1 | tee -a ${LOG}
    cp ${DIR_LOGS}/build_docker_${DEB}.log ${DIR_LOGS_COS}/build_docker_${DEB}.log

    # Checking everything has been copied
    ls -f ${DIR_DOCKER}/bundles-ce-${DEB}-ppc64le.tar.gz && ls -f ${DIR_DOCKER_COS}/bundles-ce-${DEB}-ppc64le.tar.gz && ls -f ${DIR_LOGS_COS}/build_docker_${DEB}.log
    if [[ $? -eq 0 ]]
    then
      echo "${DEB} was copied." 2>&1 | tee -a ${LOG}
    else
      echo "${DEB} was not copied." 2>&1 | tee -a ${LOG}
    fi
  else
    echo "${DEB} not built" 2>&1 | tee -a ${LOG}
  fi
done
popd
after_build_DEBS=$SECONDS
duration_build_DEBS=$(expr $after_build_DEBS - $before_build_DEBS)
echo "DURATION BUILD DEBS : $(($duration_build_DEBS / 60)) minutes and $(($duration_build_DEBS % 60)) seconds elapsed." 2>&1 | tee -a ${LOG}

before_build_RPMS=$SECONDS
pushd docker-ce-packaging/rpm
patchDockerFiles .
for RPM in ${RPMS}
do
  echo "= Building for ${RPM} =" 2>&1 | tee -a ${LOG}

  VERSION=${DOCKER_VERS} make rpmbuild/bundles-ce-${RPM}-ppc64le.tar.gz &> ${DIR_LOGS}/build_docker_${RPM}.log

  if test -f rpmbuild/bundles-ce-${RPM}-ppc64le.tar.gz
  then
    echo "${RPM} built" 2>&1 | tee -a ${LOG}

    echo "== Copying packages to ${DIR_DOCKER} and to the internal COS Bucket ==" 2>&1 | tee -a ${LOG}
    cp -r rpmbuild/bundles-ce-${RPM}-ppc64le.tar.gz ${DIR_DOCKER}
    cp -r rpmbuild/bundles-ce-${RPM}-ppc64le.tar.gz ${DIR_DOCKER_COS}

    echo "== Copying log to ${DIR_LOGS_COS} ==" 2>&1 | tee -a ${LOG}
    cp ${DIR_LOGS}/build_docker_${RPM}.log ${DIR_LOGS_COS}/build_docker_${RPM}.log

    # Checking everything has been copied
    ls -f ${DIR_DOCKER}/bundles-ce-${RPM}-ppc64le.tar.gz && ls -f ${DIR_DOCKER_COS}/bundles-ce-${RPM}-ppc64le.tar.gz && ls -f ${DIR_LOGS_COS}/build_docker_${RPM}.log
    if [[ $? -eq 0 ]]
    then
      echo "${RPM} was copied." 2>&1 | tee -a ${LOG}
    else
      echo "${RPM} was not copied." 2>&1 | tee -a ${LOG}
    fi
  else
    echo "${RPM} not built" 2>&1 | tee -a ${LOG}
  fi
done
popd
after_build_RPMS=$SECONDS
duration_build_RPMS=$(expr $after_build_RPMS - $before_build_RPMS)
echo "DURATION BUILD RPMS : $(($duration_build_RPMS / 60)) minutes and $(($duration_build_RPMS % 60)) seconds elapsed." 2>&1 | tee -a ${LOG}

before_build_static=$SECONDS
echo "= Building static binaries =" 2>&1 | tee -a ${LOG}
pushd docker-ce-packaging/static

CONT_NAME=docker-build-static
if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
then
  docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env PATH_SCRIPTS --env LOG --env DOCKER_SECRET_AUTH --privileged --name ${CONT_NAME} quay.io/powercloud/docker-ce-build ${PATH_SCRIPTS}/build_static.sh
else
  docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env PATH_SCRIPTS --env LOG --privileged --name ${CONT_NAME} quay.io/powercloud/docker-ce-build ${PATH_SCRIPTS}/build_static.sh
fi

status_code="$(docker container wait ${CONT_NAME})"
if [[ ${status_code} -ne 0 ]]; then
  echo "The static binaries build failed. See details from '${STATIC_LOG}'" 2>&1 | tee -a ${LOG}
  docker logs ${CONT_NAME} 2>&1 | tee ${DIR_LOGS}/${STATIC_LOG}
  docker rm ${CONT_NAME}
else
  docker logs ${CONT_NAME} 2>&1 | tee ${DIR_LOGS}/${STATIC_LOG}
  docker rm ${CONT_NAME}

  echo "Static binaries built" 2>&1 | tee -a ${LOG}

  echo "== Copying packages to ${DIR_DOCKER} and to the internal COS Bucket ==" 2>&1 | tee -a ${LOG}
  cp build/linux/tmp/*.tgz ${DIR_DOCKER}
  cp build/linux/tmp/*.tgz ${DIR_DOCKER_COS}

  echo "== Copying log to ${DIR_LOGS_COS} ==" 2>&1 | tee -a ${LOG}
  cp ${DIR_LOGS}/${STATIC_LOG} ${DIR_LOGS_COS}/${STATIC_LOG}

  # Checking everything has been copied
  ls -f ${DIR_DOCKER}/*.tgz && ls -f ${DIR_DOCKER_COS}/*.tgz && ls -f ${DIR_LOGS_COS}/${STATIC_LOG}
  if [[ $? -eq 0 ]]
  then
    echo "The static binaries were copied." 2>&1 | tee -a ${LOG}
  else
    echo "The static binaries were not copied." 2>&1 | tee -a ${LOG}
  fi
fi

popd
after_build_static=$SECONDS
duration_build_static=$(expr $after_build_static - $before_build_static)
echo "DURATION BUILD STATIC : $(($duration_build_static / 60)) minutes and $(($duration_build_static % 60)) seconds elapsed." 2>&1 | tee -a ${LOG}

before_build_containerd=$SECONDS
if [[ ${CONTAINERD_BUILD} != "0" ]]
then
  echo "## Building containerd ##" 2>&1 | tee -a ${LOG}

  mkdir containerd-packaging
  pushd containerd-packaging
  git init
  git remote add origin https://github.com/docker/containerd-packaging.git
  git fetch --depth 1 origin ${CONTAINERD_PACKAGING_REF}
  git checkout FETCH_HEAD

  make REF=${CONTAINERD_VERS} checkout

  DISTROS="${DEBS//-/:} ${RPMS//-/:}"

  for DISTRO in $DISTROS
  do
    echo "= Building for ${DISTRO} =" 2>&1 | tee -a ${LOG}
    make REF=${CONTAINERD_VERS} docker.io/library/${DISTRO} &> ${DIR_LOGS}/build_containerd_${DISTRO}.log
    DISTRO_NAME="$(cut -d':' -f1 <<<"${DISTRO}")"
    DISTRO_VERS="$(cut -d':' -f2 <<<"${DISTRO}")"

    if test -d build/${DISTRO_NAME}/${DISTRO_VERS}
    then
      echo "${DISTRO} built" 2>&1 | tee -a ${LOG}

      echo "== Copying packages to ${DIR_CONTAINERD} ==" 2>&1 | tee -a ${LOG}
      if ! test -d ${DIR_CONTAINERD}/${DISTRO_NAME}
      then
        mkdir ${DIR_CONTAINERD}/${DISTRO_NAME}
      fi
      cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}

      echo "== Copying packages to ${DIR_CONTAINERD_COS} ==" 2>&1 | tee -a ${LOG}
      if ! test -d ${DIR_CONTAINERD_COS}/${DISTRO_NAME}
      then
        mkdir ${DIR_CONTAINERD_COS}/${DISTRO_NAME}
      fi
      cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS}

      echo "== Copying log to ${DIR_LOGS_COS} ==" 2>&1 | tee -a ${LOG}
      cp ${DIR_LOGS}/build_containerd_${DISTRO}.log ${DIR_LOGS_COS}/build_containerd_${DISTRO}.log

      # Checking everything has been copied
      ls -d ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS} && ls -d ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS} && ls -f ${DIR_LOGS_COS}/build_containerd_${DISTRO}.log
      if [[ $? -eq 0 ]]
      then
        echo "${DISTRO} was copied." 2>&1 | tee -a ${LOG}
      else
        echo "${DISTRO} was not copied." 2>&1 | tee -a ${LOG}
      fi
    else
      echo "${DISTRO} not built" 2>&1 | tee -a ${LOG}
    fi
  done

  popd

else
  # Check if in DIR_CONTAINERD there are builds for every distro in env-distrib.list
  # Create a txt file with the name of the distros missing if there are any
  echo "= Check containerd =" 2>&1 | tee -a ${LOG}
  DISTROS="${DEBS//-/:} ${RPMS//-/:}"

  for DISTRO in $DISTROS
  do
    DISTRO_NAME="$(cut -d':' -f1 <<<"${DISTRO}")"
    DISTRO_VERS="$(cut -d':' -f2 <<<"${DISTRO}")"

    if test -d ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}
    then
      echo "${DISTRO} already built" 2>&1 | tee -a ${LOG}
    else
      echo "== ${DISTRO} missing ==" 2>&1 | tee -a ${LOG}
      if ! test -f ${PATH_DISTROS_MISSING}
      then
        touch ${PATH_DISTROS_MISSING}
      fi
      # Add the distro to the distros-missing.txt
      echo "${DISTRO}" >> ${PATH_DISTROS_MISSING}

      # Build the package
      if ! test -d containerd-packaging
      then
          mkdir containerd-packaging
          pushd containerd-packaging
          git init
          git remote add origin https://github.com/docker/containerd-packaging.git
          git fetch --depth 1 origin ${CONTAINERD_PACKAGING_REF}
          git checkout FETCH_HEAD
          make REF=${CONTAINERD_VERS} checkout
      fi
      pushd containerd-packaging

      make REF=${CONTAINERD_VERS} docker.io/library/${DISTRO} &> ${DIR_LOGS}/build_containerd_${DISTRO}.log
      if test -d build/${DISTRO_NAME}/${DISTRO_VERS}
      then
        echo "${DISTRO} built" 2>&1 | tee -a ${LOG}
        echo "=== Copying packages to ${DIR_CONTAINERD} and to the COS bucket ===" 2>&1 | tee -a ${LOG}
        if ! test -d ${DIR_CONTAINERD}/${DISTRO_NAME}
        then
          mkdir ${DIR_CONTAINERD}/${DISTRO_NAME}
        fi
        cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}

        echo "=== Copying packages to ${DIR_CONTAINERD_COS} ===" 2>&1 | tee -a ${LOG}
        if ! test -d ${DIR_CONTAINERD_COS}/${DISTRO_NAME}
        then
          mkdir ${DIR_CONTAINERD_COS}/${DISTRO_NAME}
        fi
        cp -r build/${DISTRO_NAME}/${DISTRO_VERS} ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS}

        echo "== Copying log to ${DIR_LOGS_COS} ==" 2>&1 | tee -a ${LOG}
        cp ${DIR_LOGS}/build_containerd_${DISTRO}.log ${DIR_LOGS_COS}/build_containerd_${DISTRO}.log

        # Checking everything has been copied
        ls -d ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS} && ls -d ${DIR_CONTAINERD_COS}/${DISTRO_NAME}/${DISTRO_VERS}
        if [[ $? -eq 0 ]]
        then
          echo "${DISTRO} was copied." 2>&1 | tee -a ${LOG}
        else
          echo "${DISTRO} was not copied." 2>&1 | tee -a ${LOG}
        fi
      else
        echo "${DISTRO} not built" 2>&1 | tee -a ${LOG}
      fi
      popd
    fi
  done
fi
after_build_containerd=$SECONDS
duration_build_containerd=$(expr $after_build_containerd - $before_build_containerd)
echo "DURATION BUILD CONTAINERD : $(($duration_build_containerd / 60)) minutes and $(($duration_build_containerd % 60)) seconds elapsed." 2>&1 | tee -a ${LOG}

# Check if the docker-ce packages have been built
ls ${DIR_DOCKER}/*
if [[ $? -ne 0 ]]
then
  # No docker-ce packages built
  echo "No packages built for docker" 2>&1 | tee -a ${LOG}
  BOOL_DOCKER=0
else
  # Docker-ce packages built
  BOOL_DOCKER=1
fi

# Check if the containerd packages have been built
ls ${DIR_CONTAINERD}/*
if [[ $? -ne 0 ]]
then
  # No containerd packages built
  echo "No packages built for containerd" 2>&1 | tee -a ${LOG}
  BOOL_CONTAINERD=0
else
  # Containerd packages built
  BOOL_CONTAINERD=1
fi

# Check if all packages have been built
if [[ ${BOOL_DOCKER} -eq 0 ]] || [[ ${BOOL_CONTAINERD} -eq 0 ]]
then
  # There are no docker-ce and/or no containerd packages built
  echo "No packages built for either docker, or containerd" 2>&1 | tee -a ${LOG}
  exit 1
elif [[ ${BOOL_DOCKER} -eq 1 ]] && [[ ${BOOL_CONTAINERD} -eq 1 ]]
then
  # There are docker-ce and containerd packages built
  echo "All packages built" 2>&1 | tee -a ${LOG}
fi
