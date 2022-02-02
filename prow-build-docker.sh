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
exit_code_build=`echo $?`
echo "Exit code build : ${exit_code_build}"

duration=$SECONDS
echo "DURATION ALL : $(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

#Stop the dockerd
echo "* Stopping dockerd *"
${PATH_SCRIPTS}/dockerctl.sh stop

if [[ ${exit_code_build} -eq 0 ]]
then
    echo "Build docker successful"
    cd ${PATH_SCRIPTS}
    git add . && git commit -m "New build docker ${DOCKER_VERS}" && git push
    exit_code_git=`echo $?`
    echo "Exit code prow-build-docker.sh : ${exit_code_git}"
    if [[ ${exit_code_git} -eq 0 ]]
    then
        echo "Git push successful"
        exit 0
    else
        echo "Git push not successful"
        exit 1
    fi
else
    echo "Build docker not successful"
    exit 1
fi