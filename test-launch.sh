#!/bin/bash
# Script that launches tests from the repo https://github.ibm.com/powercloud/dockertest

set -eu

# Start the dockerd and wait for it to start
${PATH_SCRIPTS}/dockerctl.sh start

# Run the docker test suite that consists of 3 tests
echo "= Docker test suite for ${DISTRO_NAME} ="
export GOPATH=${WORKSPACE}/test:/go
export PATH="/workspace/test/bin:$PATH"
export GO111MODULE=auto
cd /workspace/test/src/github.ibm.com/powercloud/dockertest
go install gotest.tools/gotestsum@v1.7.0

if [[ ${DISTRO_NAME} == "alpine" ]]
then
  gotestsum --format standard-verbose --junitfile ${DIR_TEST}/junit-tests-${DISTRO_NAME}.xml --debug -- ./tests/${DISTRO_NAME}
else
  gotestsum --format standard-verbose --junitfile ${DIR_TEST}/junit-tests-${DISTRO_NAME}-${DISTRO_VERS}.xml --debug -- ./tests/${DISTRO_NAME}
fi

echo "== End of the docker test suite =="

exit 0
