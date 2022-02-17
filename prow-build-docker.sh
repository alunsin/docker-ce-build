#!/bin/bash

set -u

# Path to the scripts
SECONDS=0
PATH_SCRIPTS="/home/prow/go/src/github.com/${REPO_OWNER}/${REPO_NAME}"
DATE=`date +%d%m%y-%H%M`

echo DATE=\"${DATE}\" 2>&1 | tee ${PATH_SCRIPTS}/env/date.list

export DATE
export PATH_SCRIPTS

echo "Prow Job to build the dynamic docker packages"

# Go to the workdir
cd /workspace

# Start the dockerd and wait for it to start
echo "* Starting dockerd and waiting for it *"
${PATH_SCRIPTS}/dockerctl.sh start

# Mount the COS bucket and get the env files
echo "** Set up (COS bucket and env files) **"
${PATH_SCRIPTS}/get-env.sh

set -o allexport
source env.list

# Build dynamic docker packages
echo "*** Build ***"
${PATH_SCRIPTS}/build-docker.sh
exit_code_build=$?
echo "Exit code build : ${exit_code_build}"

duration=$SECONDS
echo "DURATION ALL : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

#Stop the dockerd
echo "* Stopping dockerd *"
${PATH_SCRIPTS}/dockerctl.sh stop

if [[ ${exit_code_build} -ne 0 ]]
then
    echo "Docker build failed (${exit_code_build})"
    exit 1
fi


echo "Triggering the next prow job using git commit"
TRACKING_REPO=${REPO_OWNER}/${REPO_NAME}
TRACKING_BRANCH=prow-job-tracking
FILE_TO_PUSH=job/${JOB_NAME}

cd ${PATH_SCRIPTS}
./trigger-prow-job-from-git.sh -r ${TRACKING_REPO} \
 -b ${TRACKING_BRANCH} -s ${PWD}/env/date.list -d ${FILE_TO_PUSH}

if [ $? -ne 0 ]
then
    echo "Failed to add the git commit to trigger the next job"
    exit 2
fi
