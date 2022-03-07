#!/bin/bash
# Script to get the env.list file and to generate the list of distros
# The env.list would contain the DOCKER_VERS, the DOCKER_PACKAGING_REF, which is the commit associated to the version of docker,
# CONTAINERD_BUILD, which is set to 1 if there has been a new version of containerd released,
# CONTAINERD_VERS, CONTAIINERD_PACKAGING_REF which is the commit associated to the version of containerd,
# and RUNC_VERS, containing the version of runc used to build the static packages.

set -eu

PATH_COS="/mnt"
PATH_PASSWORD="/root/.s3fs_cos_secret"

COS_BUCKET_PRIVATE="ppc64le-docker"
URL_COS_PRIVATE="https://s3.us-south.cloud-object-storage.appdomain.cloud"

FILE_ENV_PATH="${PATH_SCRIPTS}/env"
FILE_ENV="env.list"

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

# Copy the env.list to the local /workspace
cp ${FILE_ENV_PATH}/${FILE_ENV} /workspace/${FILE_ENV}

set -o allexport
source /workspace/${FILE_ENV}

# Generate the list of distributions
mkdir docker-ce-packaging
pushd docker-ce-packaging
git init
git remote add origin https://github.com/docker/docker-ce-packaging.git
git fetch origin ${DOCKER_PACKAGING_REF}
git checkout FETCH_HEAD

make REF=${DOCKER_VERS} checkout
popd

# Get the distributions list in the docker-ce-packaging repository
echo DEBS=\"`cd docker-ce-packaging/deb && ls -1d debian-* ubuntu-*`\" >> ${FILE_ENV}
echo RPMS=\"`cd docker-ce-packaging/rpm && ls -1d centos-* fedora-*`\" >> ${FILE_ENV}

#echo DEBS=\"ubuntu-bionic\" >> ${FILE_ENV}
#echo RPMS=\"centos-8 fedora-34\" >> ${FILE_ENV}

source /workspace/${FILE_ENV}

# Check if we have the env.list
if ! test -f /workspace/${FILE_ENV}
then
    echo "The env.list has not been generated."
    exit 1
else
# Check there are 6 env variables in env.list from github
    if grep -Fq "DOCKER_VERS" ${FILE_ENV} && grep -Fq "DOCKER_PACKAGING_REF" ${FILE_ENV} && grep -Fq "CONTAINERD_BUILD" ${FILE_ENV} && grep -Fq "CONTAINERD_VERS" ${FILE_ENV} && grep -Fq "CONTAINERD_PACKAGING_REF" ${FILE_ENV} && grep -Fq "RUNC_VERS" ${FILE_ENV}
    then
        echo "DOCKER_VERS : ${DOCKER_VERS}, DOCKER_PACKAGING_REF : ${DOCKER_PACKAGING_REF}, CONTAINERD_BUILD : ${CONTAINERD_BUILD}, CONTAINERD_VERS : ${CONTAINERD_VERS}, CONTAINERD_PACKAGING_REF : ${CONTAINERD_PACKAGING_REF} and RUNC_VERS :${RUNC_VERS} are in env.list."
    else
        echo "DOCKER_VERS, DOCKER_PACKAGING_REF, CONTAINERD_BUILD, CONTAINERD_VERS, CONTAINERD_PACKAGING_REF and/or RUNC_VERS are not in env.list."
        cat /workspace/${FILE_ENV}
        exit 1
    fi
# check there are two env variables in env.list we just added regarding the distributions
    if grep -Fq "DEBS" ${FILE_ENV} || grep -Fq "RPMS" ${FILE_ENV}
    then
        echo "DEBS and/or RPMS are in env.list."
    else
        echo "DEBS and RPMS are not in env.list."
        cat /workspace/${FILE_ENV}
        exit 1
    fi
    echo "The env.list has been copied and the list of distributions has been generated and added to env.list."
fi
