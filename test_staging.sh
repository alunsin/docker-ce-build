#!/bin/bash

set -ue

set -o allexport
source env.list
source env-distrib.list

DIR_TEST="/workspace/test-staging_docker-ce-${DOCKER_VERS}_containerd-${CONTAINERD_VERS}"
export DIR_TEST

PATH_DOCKERFILE="${PATH_SCRIPTS}/test-staging"

# Create the test directory
if ! test -d ${DIR_TEST}
then
    mkdir -p "${DIR_TEST}"
fi

echo "# Tests of the dynamic packages #"
for PACKTYPE in DEBS RPMS
do
    echo "## Looking for distro type: ${PACKTYPE} ##" 2>&1 | tee -a ${LOG}

    for DISTRO in ${!PACKTYPE}
    do
        echo "## Looking for ${DISTRO} ##" 2>&1 | tee -a ${LOG}
        DISTRO_NAME="$(cut -d'-' -f1 <<<"${DISTRO}")"
        DISTRO_VERS="$(cut -d'-' -f2 <<<"${DISTRO}")"

	# Get all environment variables
        IMAGE_NAME="t_docker_${DISTRO_NAME}_${DISTRO_VERS}"
        CONT_NAME="t_docker_run_${DISTRO_NAME}_${DISTRO_VERS}"
        BUILD_LOG="build_${DISTRO_NAME}_${DISTRO_VERS}.log"
        TEST_LOG="test_${DISTRO_NAME}_${DISTRO_VERS}.log"
        TEST_JUNIT="unit-tests-${DISTRO_NAME}-${DISTRO_VERS}.xml"

        export DISTRO_NAME
        export DISTRO_VERS

        # Get in the tmp directory and get the Dockerfile
        if ! test -d tmp
        then
            mkdir tmp
        else
            rm -rf tmp
            mkdir tmp
        fi
        pushd tmp

        echo "### # Copying the packages and the dockerfile for ${DISTRO} # ###" 2>&1 | tee -a ${LOG}
        # Copy the Dockerfile
        cp ${PATH_DOCKERFILE}-${PACKTYPE}/Dockerfile .
        # Copy the test_launch.sh which will be copied in /usr/local/bin
        cp ${PATH_SCRIPTS}/test_launch.sh .

	# Check if we have the Dockerfile and the test_launch.sh
	ls Dockerfile && ls test_launch.sh
	if [[ $? -ne 0 ]]
	then
	    # The Dockerfile and/or the test_launch.sh is/are missing
	    echo "The Dockerfile and/or the test_launch.sh is/are missing." 2>&1 | tee -a ${LOG}
	    continue
	else
	    # Building the test image

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

        docker build -t ${IMAGE_NAME} --build-arg DISTRO_NAME=${DISTRO_NAME} --build-arg DISTRO_VERS=${DISTRO_VERS} . 2>&1 | tee ${DIR_TEST}/${BUILD_LOG}

        if [[ $? -ne 0 ]]; then
            echo "ERROR: docker build failed for ${DISTRO}, see details from '${BUILD_LOG}'" 2>&1 | tee -a ${LOG}
            continue
        else
            echo "Docker build for ${DISTRO} done" 2>&1 | tee -a ${LOG}
        fi

        echo "### ### Running the tests from the container: ${CONT_NAME} ### ###" 2>&1 | tee -a ${LOG}
        if [[ ! -z ${DOCKER_SECRET_AUTH+z} ]]
        then
            docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} --env DOCKER_SECRET_AUTH --env DISTRO_NAME --env DISTRO_VERS --env PATH_SCRIPTS --env DIR_TEST --env LOG --privileged --name ${CONT_NAME} ${IMAGE_NAME}
        else
            docker run -d -v /workspace:/workspace -v ${PATH_SCRIPTS}:${PATH_SCRIPTS} --env DISTRO_NAME --env DISTRO_VERS --env PATH_SCRIPTS --env DIR_TEST --env LOG --privileged --name ${CONT_NAME} ${IMAGE_NAME}
        fi

    status_code="$(docker container wait $CONT_NAME)"
        if [[ ${status_code} -ne 0 ]]; then
            echo "ERROR: The test suite failed for ${DISTRO}. See details from '${TEST_LOG}'" 2>&1 | tee -a ${LOG}
            docker logs $CONT_NAME 2>&1 | tee ${DIR_TEST}/${TEST_LOG}
        else
            docker logs $CONT_NAME 2>&1 | tee ${DIR_TEST}/${TEST_LOG}
            echo "Tests done" 2>&1 | tee -a ${LOG}
        fi

        echo "### ### # Cleanup: ${CONT_NAME} # ### ###"
        docker stop ${CONT_NAME}
        docker rm ${CONT_NAME}
        docker image rm ${IMAGE_NAME}
	fi
	popd
        rm -rf tmp
    done
done
