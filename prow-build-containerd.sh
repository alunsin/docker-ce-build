#!/bin/bash

set -u

# Path to the scripts
SECONDS=0
PATH_SCRIPTS="/home/prow/go/src/github.com/${REPO_OWNER}/${REPO_NAME}"

if [[ -z ${ARTIFACTS} ]]
then
    ARTIFACTS=/logs/artifacts
    echo "Setting ARTIFACTS to ${ARTIFACTS}"
    mkdir -p ${ARTIFACTS}
fi

export PATH_SCRIPTS

echo "Prow Job to build the containerd packages"

# Go to the workdir
cd /workspace

# Start the dockerd and wait for it to start
echo "* Starting dockerd and waiting for it *"
${PATH_SCRIPTS}/dockerctl.sh start

# Get the env file and the dockertest repo and the latest built of containerd if we don't want to build containerd
echo "** Set up (env files) **"
${PATH_SCRIPTS}/get-env.sh
${PATH_SCRIPTS}/get-env-containerd.sh

set -o allexport
source env.list
source date.list
export DATE

# Build containerd
echo "*** Build containerd packages ***"
${PATH_SCRIPTS}/build-containerd.sh
exit_code_build=`echo $?`
echo "Exit code build : ${exit_code_build}"

# Test the packages
echo "*** * Tests * ***"
${PATH_SCRIPTS}/test.sh

# Check if there are errors in the tests : NOERR or ERR
echo "*** ** Tests check ** ***"
${PATH_SCRIPTS}/check-tests.sh
CHECK_TESTS_BOOL=`echo $?`
echo "Exit code check : ${CHECK_TESTS_BOOL}"
echo "The tests results : ${CHECK_TESTS_BOOL}"
export CHECK_TESTS_BOOL

duration=$SECONDS
echo "DURATION ALL : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."


# Push to the COS Bucket according to CHECK_TESTS_BOOL
echo "*** *** Push to the COS Buckets *** ***"
${PATH_SCRIPTS}/push-COS.sh

#Stop the dockerd
echo "* Stopping dockerd *"
${PATH_SCRIPTS}/dockerctl.sh stop

if [[ ${CHECK_TESTS_BOOL} -eq 0 ]]
then
    echo "NO ERROR"
    exit 0
else
    echo "ERROR"
    exit 1
fi
