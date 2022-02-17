#!/bin/bash
##
# Usage: trigger-prow-job-from-git.sh -r ${TRACKING_REPO} -b ${TRACKING_BRANCH} -s ${SRC_FILE DEST_FILE} -d ${DEST_FILE DEST_FILE}
#
# *** Important ***
#  Please make sure that the ssh key for the git push is configured
#  and the github.com has been added to the ~/.ssh/known_hosts prior entering here
##

set -eu

display_usage() {
 echo "usage: -r <TRACKING_REPO> -b <TRACKING_BRANCH> -s <SRC_FILE> DEST_FILE} -d <DEST_FILE>}"
 echo "Example:"
 echo "  ./trigger-prow-job-from-git.sh -r alunsin/docker-ce-build -b prow-job-tracking -s $PWD/env/date.list -d 
job/postsubmit-build-docker-al"
 exit 1
}


while getopts ":r:b:s:d:" option; do
    case "${option}" in
        r)
            TRACKING_REPO=${OPTARG}
            ;;
        b)
            TRACKING_BRANCH=${OPTARG}
            ;;
        s)
            SRC_FILE=${OPTARG}
            ;;
        d)
            DEST_FILE=${OPTARG}
            ;;
        *)
            display_usage
            ;;
    esac
done
shift $((OPTIND-1))

(($OPTIND == 9)) || display_usage

#Display every command from here
set -x

JOB_TRACKING_DIR="/tmp/${TRACKING_BRANCH}"

mkdir -p ${JOB_TRACKING_DIR}
pushd ${JOB_TRACKING_DIR}

git init > /dev/null 2>&1

git config --global user.email "ppc64le@in.ibm.com"
git config --global user.name "Runtime Team Jobs"

git fetch git@github.com:${TRACKING_REPO}.git ${TRACKING_BRANCH}
git branch --force ${TRACKING_BRANCH} FETCH_HEAD
git checkout ${TRACKING_BRANCH}
cp ${SRC_FILE}  ${DEST_FILE}
git add ${DEST_FILE}
git commit -m "Job commit: ${DEST_FILE}"
git push git@github.com:${TRACKING_REPO}.git ${TRACKING_BRANCH}

popd
rm -rf ${JOB_TRACKING_DIR}