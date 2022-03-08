#!/bin/bash
# Script testing the docker-ce and containerd packages and the static binaries

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

checkFile() {
  if ! test -f $1
  then
    touch $1
    echo "$1 created"
  else
    echo "$1 already created"
  fi
}

DIR_TEST="/workspace/tests"
export DIR_TEST
checkDirectory ${DIR_TEST}

DIR_DOCKER="/workspace/docker-ce-${DOCKER_VERS}_${DATE}"
DIR_CONTAINERD="/workspace/containerd-${CONTAINERD_VERS}_${DATE}"

PATH_DOCKERFILE="${PATH_SCRIPTS}/test"

DIR_COS_BUCKET="/mnt/s3_ppc64le-docker/prow-docker/build-docker-${DOCKER_VERS}_${DATE}"

DIR_TEST_COS="${DIR_COS_BUCKET}/tests"
checkDirectory ${DIR_TEST_COS}

FILE_ERRORS="errors.txt"
PATH_ERRORS="${DIR_TEST}/${FILE_ERRORS}"
checkFile ${PATH_ERRORS}
PATH_ERRORS_COS="${DIR_TEST_COS}/${FILE_ERRORS}"

echo "# Tests of the dynamic packages #"
for PACKTYPE in DEBS RPMS
do
  for DISTRO in ${!PACKTYPE}
  do
    begin=$SECONDS
    echo "## Looking for ${DISTRO} ##"
    DISTRO_NAME="$(cut -d'-' -f1 <<<"${DISTRO}")"
    DISTRO_VERS="$(cut -d'-' -f2 <<<"${DISTRO}")"

    # Get all environment variables
    IMAGE_NAME="t_docker_${DISTRO_NAME}_${DISTRO_VERS}"
    CONT_NAME="t_docker_run_${DISTRO_NAME}_${DISTRO_VERS}"
    BUILD_LOG="build_${DISTRO_NAME}_${DISTRO_VERS}.log"
    TEST_LOG="test_${DISTRO_NAME}_${DISTRO_VERS}.log"
    TEST_JUNIT="junit-tests-${DISTRO_NAME}-${DISTRO_VERS}.xml"

    export DISTRO_NAME
    export DISTRO_VERS

    # Get in the tmp directory and get the docker-ce and containerd packages and the Dockerfile in it
    checkDirectory tmp
    pushd tmp

    echo "### Copying the packages and the dockerfile for ${DISTRO} ###"
    # Copy the docker-ce packages
    cp ${DIR_DOCKER}/bundles-ce-${DISTRO_NAME}-${DISTRO_VERS}-ppc64*.tar.gz .
    # Copy the containerd packages (we have two different configurations depending on the package type)
    CONTAINERD_VERS_2=$(echo ${CONTAINERD_VERS} | cut -d'v' -f2)
    if [[ ${PACKTYPE} == "DEBS" ]]
    then
      # For the debian packages, we don't want the dbgsym package
      cp ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}/ppc64*/containerd.io_${CONTAINERD_VERS_2}*_ppc64*.deb .
    elif [[ ${PACKTYPE} == "RPMS" ]]
    then
      cp ${DIR_CONTAINERD}/${DISTRO_NAME}/${DISTRO_VERS}/ppc64*/containerd.io-${CONTAINERD_VERS_2}*.ppc64*.rpm .
    fi

    # Copy the Dockerfile
    cp ${PATH_DOCKERFILE}-${PACKTYPE}/Dockerfile .

    # Copy the test-launch.sh
    cp ${PATH_SCRIPTS}/test-launch.sh .

    # Check if we have the docker-ce and containerd packages and the Dockerfile and the test-launch.sh
    ls bundles-ce-${DISTRO_NAME}-${DISTRO_VERS}-ppc64le.tar.gz && ls containerd*ppc64*.* && ls Dockerfile && ls test-launch.sh
    if [[ $? -ne 0 ]]
    then
      # The docker-ce packages and/or the containerd packages and/or the Dockerfile is/are missing
      echo "ERROR: The docker-ce packages and/or the containerd packages and/or the Dockerfile is/are missing"
    else
      echo "### # Building the test image: ${IMAGE_NAME} # ###"
      # Building the test image
        if [[ "${DISTRO_NAME}:${DISTRO_VERS}" == centos:8* ]]
        then
          ##
          # Switch to quay.io for CentOS 8 stream
          # See https://github.com/docker/containerd-packaging/pull/263
          # See https://github.com/docker-library/official-images/pull/11831
          ##
          echo "Temporary fix: patching Dockerfile for using CentOS 8 stream and quay.io "
          sed -i 's/FROM ppc64le.*/FROM quay.io\/centos\/centos\:stream8/g' Dockerfile
        fi

      docker build -t ${IMAGE_NAME} --build-arg DISTRO_NAME=${DISTRO_NAME} --build-arg DISTRO_VERS=${DISTRO_VERS} . > ${DIR_TEST}/${BUILD_LOG} 2>&1

      if [[ $? -ne 0 ]]
      then
        echo "ERROR: docker build failed for ${DISTRO}, see details from '${BUILD_LOG}'"
        echo "== Log start for the docker build failure of ${DISTRO} =="
        cat ${DIR_TEST}/${BUILD_LOG}
        echo "== Log end for the docker build failure of ${DISTRO} =="
      else
        echo "Docker build for ${DISTRO} done"
      fi

      # Copying the build log to the COS bucket
      if test -f ${DIR_TEST}/${BUILD_LOG}
      then
        echo "Build log for ${DISTRO} copied to the COS bucket"
        cp ${DIR_TEST}/${BUILD_LOG} ${DIR_TEST_COS}
      else
        echo "No build log for ${DISTRO}"
      fi

      # Running the tests
      echo "### ## Running the tests from the container: ${CONT_NAME} ## ###"
      if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
      then
        docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env DOCKER_SECRET_AUTH --env DISTRO_NAME --env DISTRO_VERS --env PATH_SCRIPTS --env DIR_TEST --privileged --name ${CONT_NAME} ${IMAGE_NAME}
      else
        docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --env DISTRO_NAME --env DISTRO_VERS --env PATH_SCRIPTS --env DIR_TEST --privileged --name ${CONT_NAME} ${IMAGE_NAME}
      fi

      status_code="$(docker container wait $CONT_NAME)"
      docker logs $CONT_NAME > ${DIR_TEST}/${TEST_LOG} 2>&1

      if [[ ${status_code} -ne 0 ]]; then
        echo "ERROR: The test suite failed for ${DISTRO}. See details from '${TEST_LOG}'"
        echo "== Log start for the test failure of ${DISTRO} =="
        cat ${DIR_TEST}/${TEST_LOG}
        echo "== Log end for the test failure of ${DISTRO} =="
      else
        echo "Tests done"
      fi

      # Copying the test logs to the COS bucket
      if test -f ${DIR_TEST}/${TEST_LOG}
      then
        echo "Test log for ${DISTRO} copied to the COS bucket"
        cp ${DIR_TEST}/${TEST_LOG} ${DIR_TEST_COS}
      else
        echo "No test log for ${DISTRO}"
      fi

      if test -f ${DIR_TEST}/${TEST_JUNIT}
      then
        echo "Test junit copied to the COS bucket and ${ARTIFACTS}"
        cp ${DIR_TEST}/${TEST_JUNIT} ${DIR_TEST_COS}
        cp ${DIR_TEST}/${TEST_JUNIT} ${ARTIFACTS}
      else
        echo "No test junit for ${DISTRO}"
      fi
    fi
    popd
    rm -rf tmp

    end=$SECONDS
    duration=$(expr $end - $begin)
    echo "DURATION TEST ${DISTRO}: $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

    # Check the logs and get in the errors.txt a summary of the error logs
    echo "### ### # Checking the logs # ### ###"
    echo "DISTRO ${DISTRO_NAME} ${DISTRO_VERS}" 2>&1 | tee -a ${PATH_ERRORS}

    if test -f ${DIR_TEST}/${TEST_LOG} && [[ $(eval "cat ${DIR_TEST}/${TEST_LOG} | grep -c exitCode") == 4 ]]
    then
      echo "Dynamic packages" 2>&1 | tee -a ${PATH_ERRORS}
      # We get 4 exitCodes in the log (3 tests + the output of the first containing exitCode)
      TEST_1=$(eval "cat ${DIR_TEST}/${TEST_LOG} | grep exitCode | awk 'NR==2' | rev | cut -d' ' -f 1")
      TEST_2=$(eval "cat ${DIR_TEST}/${TEST_LOG} | grep exitCode | awk 'NR==3' | rev | cut -d' ' -f 1")
      TEST_3=$(eval "cat ${DIR_TEST}/${TEST_LOG} | grep exitCode | awk 'NR==4' | rev | cut -d' ' -f 1")
    else
      TEST_1=1
      TEST_2=1
      TEST_3=1
    fi

    echo "TestDistro : ${TEST_1}" 2>&1 | tee -a ${PATH_ERRORS}
    echo "TestDistroInstallPackage : ${TEST_2}" 2>&1 | tee -a ${PATH_ERRORS}
    echo "TestDistroPackageCheck : ${TEST_3}" 2>&1 | tee -a ${PATH_ERRORS}

    [[ "$TEST_1" -eq "0" ]] && [[ "$TEST_2" -eq "0" ]] && [[ "$TEST_3" -eq "0" ]]
    TEST=$?

    # Copying the errors.txt to the COS bucket
    cp ${PATH_ERRORS} ${PATH_ERRORS_COS}
  done
done


begin=$SECONDS
echo "# Tests for the static packages #"

DISTRO_NAME="alpine"

IMAGE_NAME_STATIC="t-static_docker_${DISTRO_NAME}"
CONT_NAME_STATIC="t-static_docker_run_${DISTRO_NAME}"
BUILD_LOG_STATIC="build-static_${DISTRO_NAME}.log"
TEST_LOG_STATIC="test-static_${DISTRO_NAME}.log"
TEST_JUNIT_STATIC="junit-tests-${DISTRO_NAME}.xml"

export DISTRO_NAME

# Get in the tmp directory and get the docker-ce and containerd packages and the Dockerfile in it
if ! test -d tmp
then
  mkdir tmp
else
  rm -rf tmp
  mkdir tmp
fi
pushd tmp

echo "## Copying the static packages and the dockerfile for ${DISTRO_NAME} ##"
# Copy the static binaries
cp ${DIR_DOCKER}/docker-ppc64le.tgz .
# Copy the Dockerfile
cp ${PATH_DOCKERFILE}-static-alpine/Dockerfile .
# Copy the test-launch.sh
cp ${PATH_SCRIPTS}/test-launch.sh .
# Check if we have the static binaries and Dockerfile and the test-launch.sh
ls docker-ppc64le.tgz && ls Dockerfile && ls test-launch.sh
if [[ $? -ne 0 ]]
then
  # The static binaries and/or the Dockerfile is/are missing
  echo "The static binaries and/or the Dockerfile and/or the test-launch.sh is/are missing"
else
  # Building the test image
  echo "### Building the test image: ${IMAGE_NAME_STATIC} ###"
  docker build -t ${IMAGE_NAME_STATIC} . > ${DIR_TEST}/${BUILD_LOG_STATIC} 2>&1

  if [[ $? -ne 0 ]]; then
    echo "ERROR: docker build failed for ${DISTRO_NAME}, see details from '${BUILD_LOG_STATIC}'"
  else
    echo "Docker build done"
  fi

  # Copying the build log to the COS bucket
  if test -f ${DIR_TEST}/${BUILD_LOG_STATIC}
  then
    echo "Build log for the static packages copied to the COS bucket"
    cp ${DIR_TEST}/${BUILD_LOG_STATIC} ${DIR_TEST_COS}
  else
    echo "No build log for the static packages"
  fi

  # Running the tests
  echo "### # Running the tests from the container: ${CONT_NAME_STATIC} # ###"
  if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
  then
    docker run -d --env DOCKER_SECRET_AUTH --env DISTRO_NAME --env PATH_SCRIPTS --env DIR_TEST -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --privileged --name ${CONT_NAME_STATIC} ${IMAGE_NAME_STATIC}
  else
    docker run -d --env DISTRO_NAME --env PATH_SCRIPTS --env DIR_TEST -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} -v ${ARTIFACTS}:${ARTIFACTS} --privileged --name ${CONT_NAME_STATIC} ${IMAGE_NAME_STATIC}
  fi

  status_code="$(docker container wait ${CONT_NAME_STATIC})"
  if [[ ${status_code} -ne 0 ]]; then
    echo "ERROR: The test suite failed for ${DISTRO_NAME}. See details from '${TEST_LOG_STATIC}'"
    docker logs ${CONT_NAME_STATIC} > ${DIR_TEST}/${TEST_LOG_STATIC} 2>&1
  else
    docker logs ${CONT_NAME_STATIC} > ${DIR_TEST}/${TEST_LOG_STATIC} 2>&1
    echo "Tests done"
  fi

  # Copying the test logs to the COS bucket
  if test -f ${DIR_TEST}/${TEST_LOG_STATIC}
  then
    echo "Test log for the static packages copied to the COS Bucket"
    cp ${DIR_TEST}/${TEST_LOG_STATIC} ${DIR_TEST_COS}
  else
    echo "No test log for the static packages"
  fi

  if test -f ${DIR_TEST}/${TEST_JUNIT_STATIC}
  then
    echo "Test junit for the static packages copied to the COS bucket"
    cp ${DIR_TEST}/${TEST_JUNIT_STATIC} ${DIR_TEST_COS}
    cp ${DIR_TEST}/${TEST_JUNIT_STATIC} ${ARTIFACTS}
  else
    echo " No test junit for the static packages"
  fi
fi
popd
rm -rf tmp

end=$SECONDS
duration=$(expr $end - $begin)
echo "DURATION test ${DISTRO_NAME}: $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

# Check the logs and get in the errors.txt a summary of the error logs
echo "### ### Checking the logs ### ###"

if test -f ${DIR_TEST}/${TEST_LOG_STATIC} && [[ $(eval "cat ${DIR_TEST}/${TEST_LOG_STATIC} | grep -c exitCode") == 4 ]]
then
  echo "Static binaries" 2>&1 | tee -a ${PATH_ERRORS}
  # We get 4 exitCodes in the log (3 tests + the output of the first containing exitCode)
  TEST_1_STATIC=$(eval "cat ${DIR_TEST}/${TEST_LOG_STATIC} | grep exitCode | awk 'NR==2' | rev | cut -d' ' -f 1")
  TEST_2_STATIC=$(eval "cat ${DIR_TEST}/${TEST_LOG_STATIC} | grep exitCode | awk 'NR==3' | rev | cut -d' ' -f 1")
  TEST_3_STATIC=$(eval "cat ${DIR_TEST}/${TEST_LOG_STATIC} | grep exitCode | awk 'NR==4' | rev | cut -d' ' -f 1")
else
  TEST_1_STATIC=1
  TEST_2_STATIC=1
  TEST_3_STATIC=1
fi

echo "TestDistro : ${TEST_1_STATIC}" 2>&1 | tee -a ${PATH_ERRORS}
echo "TestDistroInstallPackage : ${TEST_2_STATIC}" 2>&1 | tee -a ${PATH_ERRORS}
echo "TestDistroPackageCheck : ${TEST_3_STATIC}" 2>&1 | tee -a ${PATH_ERRORS}

[[ "$TEST_1_STATIC" -eq "0" ]] && [[ "$TEST_2_STATIC" -eq "0" ]] && [[ "$TEST_3_STATIC" -eq "0" ]]
TEST_STATIC=$?

[[ "$TEST" -eq "0" ]] && [[ "$TEST_STATIC" -eq "0" ]]
echo "All : $?" 2>&1 | tee -a ${PATH_ERRORS}

# Copying the errors.txt to the COS bucket
cp ${PATH_ERRORS} ${PATH_ERRORS_COS}
