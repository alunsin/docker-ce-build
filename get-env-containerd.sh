#!/bin/bash
# Script to get the date.list, the dockertest repository and the latest containerd packages if CONTAINERD_BUILD is set to 0

set -u

PATH_COS="/mnt"
PATH_PASSWORD="${PATH_SCRIPTS}/.s3fs_cos_secret"

COS_BUCKET_PRIVATE="ppc64le-docker"
URL_COS_PRIVATE="https://s3.us-south.cloud-object-storage.appdomain.cloud"

FILE_DATE="${PATH_SCRIPTS}/env/date.list"

PATH_DOCKERTEST="/workspace/test/src/github.ibm.com/powercloud"

# Copy the date file
cp ${FILE_DATE} /workspace/date.list

set -o allexport
source /workspace/env.list
source /workspace/date.list

# Mount the COS bucket if not mounted
if ! test -d ${PATH_COS}/s3_${COS_BUCKET_PRIVATE}
then
    # Set up the s3 secret if not already configured
    if ! test -f ${PATH_PASSWORD}
    then
        echo ":${S3_SECRET_AUTH}" > ${PATH_PASSWORD}
        chmod 600 ${PATH_PASSWORD}
    fi
    mkdir -p ${PATH_COS}/s3_${COS_BUCKET_PRIVATE}
    s3fs ${COS_BUCKET_PRIVATE} ${PATH_COS}/s3_${COS_BUCKET_PRIVATE} -o url=${URL_COS_PRIVATE} -o passwd_file=${PATH_PASSWORD} -o ibm_iam_auth
fi

# Copy the dockertest repo to the local /workspace
mkdir -p ${PATH_DOCKERTEST}
cp -r ${PATH_COS}/s3_${COS_BUCKET_PRIVATE}/prow-docker/dockertest ${PATH_DOCKERTEST}/dockertest

#Patch test for centos so that its use centos 7 instead of centos 8 (EOL)
# See https://github.com/docker-library/official-images/pull/11831
echo "Temporary fix: patching test suite to use centos 7"
sed -i 's/Centos="latest"/Centos="centos7"/g' ${PATH_DOCKERTEST}/dockertest/version/version.go

# Get the docker-ce packages
mkdir /workspace/docker-ce-${DOCKER_VERS}_${DATE}
cp -r ${PATH_COS}/s3_${COS_BUCKET_PRIVATE}/prow-docker/build-docker-${DOCKER_VERS}_${DATE}/docker-ce-${DOCKER_VERS}/* /workspace/docker-ce-${DOCKER_VERS}_${DATE}

# Get the containerd packages if CONTAINERD_BUILD=0
if [[ ${CONTAINERD_BUILD} = "0" ]]
then
    echo "CONTAINERD_BUILD is set to 0, we copy the containerd packages from the COS bucket"
    mkdir /workspace/containerd-${CONTAINERD_VERS}_${DATE}
    cp -r ${PATH_COS}/s3_${COS_BUCKET_PRIVATE}/prow-docker/containerd-${CONTAINERD_VERS} /workspace/containerd-${CONTAINERD_VERS}_${DATE}
else
    echo "CONTAINERD_BUILD is set to 1"
fi

# Check if we have the dockertest
if ! test -d ${PATH_DOCKERTEST}/dockertest
then
    echo "The dockertest directory has not been copied."
    exit 1
fi

# Check if we have the docker packages
if ! test -d /workspace/docker-ce-${DOCKER_VERS}_${DATE}
then
    echo "The docker packages have not been copied."
    exit 1
fi

# Check if we have the containerd packages if CONTAINERD_BUILD is 0
if [[ ${CONTAINERD_BUILD} = "0" ]]
then
    if test -d /workspace/containerd-${CONTAINERD_VERS}
    then
        echo "The containerd packages have been copied."
    else
        echo "The containerd packages have not been copied."
        exit 1
    fi
else
    echo "The dockertest directory has been copied."
fi
