# Scripts for the prow job periodic-dind-build

The goal of these scripts and the associated prow job is to automate the process of building the docker-ce and containerd packages (as well as the static binaries) for ppc64le and of testing them. The packages would then be shared with the Docker team and be available on the https://download.docker.com package repositories.

To build these packages, we use the [docker-ce-packaging](https://github.com/docker/docker-ce-packaging) and the [containerd-packaging](https://github.com/docker/containerd-packaging/) repositories.

## [Prow job](https://github.com/florencepascual/test-infra/blob/master/config/jobs/periodic/docker-in-docker/periodic-dind-build.yaml)

The prow job is at the moment a periodic one, that is supposed to build the docker-ce and containerd packages, and the static binaries for ppc64le and test them. 
For the moment, it is a semi-automated process, since the prow job is a periodic one, meaning that it is not a presubmit or postsubmit prow job triggered by a new tag on [docker/docker-ce-packaging](https://github.com/docker/docker-ce-packaging). However, we cannot yet implement a presubmit or postsubmit prow job, for two reasons : there are no tags yet and there are no webhooks to which we have access.
To get around the lack of tags, we get an environment variable file containing the versions of docker and containerd we want to build, from our internal COS Bucket.

1. [Start the docker daemon](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L17-L19)
2. [Access to the internal COS Bucket for the environment variable file and the dockertest repository](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L26-L28)
3. [Build the packages](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L34-L36)
4. [Test the packages](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L38-L40)
5. [Check the errors.txt file for errors](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L42-L45)
6. [Push to COS Buckets](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prowjob-periodic-dind-build.sh#L47-L49)

### The 8 scripts in detail

- [dockerd-starting.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/dockerd-starting.sh)

This script runs the **dockerd-entrypoint.sh** and then checks if the docker daemon has started and is running.

- [get_env.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/get_env.sh)

This script gets from our internal COS bucket, the environment variable file, containing the version of docker-ce and containerd we want to build, and also the dockertest repository we use for the tests. 
If we put the CONTAINERD_VERS variable to 0, it means there are no new version of containerd in the 1.4 branch, and the **build.sh** script won't build it again. For test purposes, the script also copies the last version of containerd we have built and stored in the COS bucket, in the workspace.

- [build.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/build.sh)

This script builds the version of docker-ce and containerd we specified in the environment variable file, and runs **build_static.sh** in a docker to build the static binaries.

- [build_static.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/build_static.sh)

This script builds the static binaries and rename them (removes the version and adds ppc64le).

- [test.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test.sh)

This script sets up the tests for both the docker-ce and containerd packages and the static binaries. In this script, for each distribution, we build an image, where we install the newly built packages. We then run a docker based on this said image, in which we run **test_launch.sh**. 
We do this for each distribution, but also both for the docker-ce packages and the static binaries.
It generates an **errors.txt** file with a summary of all tests, containing the exit codes of each test. 

- [test_launch.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test_launch.sh)

This script is called in the **test.sh**. This runs the tests for every distro we have built.

- [check_tests.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/check_tests.sh)

This script checks out the **errors.txt**, generated by the test.sh, if there are any errors in the tests of the packages.

- [push_COS.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/push_COS.sh)

This script pushes the packages built, the tests and the log to our internal COS Bucket, it does not push anything to the COS Bucket shared with Docker, since it is still a test.
The goal would be to push to our internal COS bucket, whether there are any errors or not, and to push to the COS Bucket shared with Docker, only if there are no errors.

### The 5 images in detail

- [dind-docker-build](https://github.com/florencepascual/test-infra/blob/master/images/docker-in-docker/Dockerfile)

This Dockerfile is used for getting a docker-in-docker container. It is used for the basis of the prow job, as well as for the container building the packages and the one testing the packages. It also installs s3fs to get directly access to the COS buckets.

- [test-DEBS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-DEBS/Dockerfile) and [test-RPMS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-RPMS/Dockerfile)

These two Dockerfiles are used for testing the docker-ce and containerd packages. Depending on the distro type (debs or rpms), we use them to build a container to test the packages and run **test_launch.sh**.

- [test-static-DEBS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-static-DEBS/Dockerfile) and [test-static-RPMS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-static-RPMS/Dockerfile)

These two Dockerfiles are used for testing the static binaries. Like the two aforementioned Dockerfiles : depending on the distro type (debs or rpms), we use them to build a container to test the packages and run **test_launch.sh**. 


## How to test the scripts manually in a pod
### Set up the secrets and the pod

You need first to set up the secrets docker-token and secret-s3 with kubectl.

```bash
# docker-token
docker login
kubectl create secret generic docker-token \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson
```
Add the following to **secret-s3.yaml**, with the secret :
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: secret-s3
type: Opaque
data:
  password: 
```
```bash
kubectl apply -f secret-s3.yaml
```
You also need the **dockerd-entrypoint.sh**, which is the script that starts the docker daemon :
```
wget -O /usr/local/bin/dockerd-entrypoint.sh https://raw.githubusercontent.com/docker-library/docker/094faa88f437cafef7aeb0cc36e75b59046cc4b9/20.10/dind/dockerd-entrypoint.sh
chmod +x /usr/local/bin/dockerd-entrypoint.sh
```
Then, you need to create the pod. Add the following to **pod.yaml** :
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-docker-build
spec:
  automountServiceAccountToken: false
  containers:
  - name: test
    command:
    - /usr/local/bin/dockerd-entrypoint.sh
    image: quay.io/powercloud/docker-ce-build
    resources: {}
    terminationMessagePolicy: FallbackToLogsOnError
    securityContext:
      privileged: true
    volumeMounts:
    - name: docker-graph-storage
      mountPath: /var/lib/docker
    env:
      - name: DOCKER_SECRET_AUTH
        valueFrom:
          secretKeyRef:
            name: docker-token
            key: .dockerconfigjson
      - name: S3_SECRET_AUTH
        valueFrom:
          secretKeyRef:
            name: secret-s3
            key: password
  restartPolicy: Never
  terminationGracePeriodSeconds: 18
  volumes:
  - name: docker-graph-storage
    emptyDir: {}
status: {}  
```
```bash
kubectl apply -f pod.yaml
kubectl exec -it pod/pod-docker-build -- /bin/bash
```
### Run the scripts
#### 0. Get the scripts

```bash
URL_GITHUB="https://github.com/powercloud/docker-ce-build.git"

# get the scripts
mkdir -p /home/prow/go/src/github.com/ppc64le-cloud
cd /home/prow/go/src/github.com/ppc64le-cloud
git clone ${URL_GITHUB}

# path to the scripts 
PATH_SCRIPTS="/home/prow/go/src/github.com/ppc64le-cloud/docker-ce-build"
LOG="/workspace/prowjob.log"

export PATH_SCRIPTS
export LOG

chmod a+x ${PATH_SCRIPTS}/*.sh

echo "Prow Job to build docker-ce" 2>&1 | tee ${LOG}

# Go to the workdir
cd /workspace
```
#### 1. Start the docker daemon
```bash
echo "** Starting dockerd **" 2>&1 | tee -a ${LOG}
# Check whether the docker daemon has started
# Comment the line calling dockerd-entrypoint.sh in dockerd-starting.sh, because the dockerd-entrypoint.sh is already running.
source ${PATH_SCRIPTS}/dockerd-starting.sh
```
#### 2. Get the env file and the dockertest repo and the latest built of containerd if we don't want to build containerd
```bash
echo "** Set up (env files and dockertest) **" 2>&1 | tee -a ${LOG}
source ${PATH_SCRIPTS}/get_env.sh

set -o allexport
source env.list
source env-distrib.list
```
#### 3. Build docker_ce and containerd and the static binaries
```bash
echo "*** Build ***" 2>&1 | tee -a ${LOG}
source ${PATH_SCRIPTS}/build.sh
```
#### 4. Test the packages
```bash
echo "*** * Tests * ***" 2>&1 | tee -a ${LOG}
source ${PATH_SCRIPTS}/test.sh
```
#### 5. Check if there are errors in the tests : NOERR or ERR
```bash
echo "*** ** Tests check ** ***" 2>&1 | tee -a ${LOG}
source ${PATH_SCRIPTS}/check_tests.sh
echo "The tests results : ${CHECK_TESTS_BOOL}" 2>&1 | tee -a ${LOG}
```
#### 6. Push to the COS Bucket according to CHECK_TESTS_BOOL
```bash
echo "*** *** Push to the COS Buckets *** ***" 2>&1 | tee -a ${LOG}
source ${PATH_SCRIPTS}/push_COS.sh
```
## How to test a prow job
### Set up a ppc64le cluster
On a ppc64le machine : 
See https://github.com/ppc64le-cloud/test-infra/wiki/Creating-Kubernetes-cluster-with-kubeadm-on-Power

On an x86 machine:
```bash
rm -rf $HOME/.kube/config/admin.conf
nano $HOME/.kube/config/admin.conf
# Copy the admin.conf from the ppc64le machine
export KUBECONFIG=$HOME/.kube/config/admin.conf
# Check if the cluster is running
kubectl cluster-info
```
On either of these machines, where the ppc64le cluster is running, configure the secrets :
```bash
# docker-token
docker login
kubectl create secret generic docker-token \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson
```
Add the following to **secret-s3.yaml**, with the secret :
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: secret-s3
type: Opaque
data:
  password: 
```
```bash
kubectl apply -f secret-s3.yaml
```
You also need the **dockerd-entrypoint.sh**, which is the script that starts the docker daemon :
```bash
wget -O /usr/local/bin/dockerd-entrypoint.sh https://raw.githubusercontent.com/docker-library/docker/094faa88f437cafef7aeb0cc36e75b59046cc4b9/20.10/dind/dockerd-entrypoint.sh
chmod +x /usr/local/bin/dockerd-entrypoint.sh
```
### Run the prow job on a x86 machine
On the x86 machine :
```bash
# Get the ppc64le-cloud/test-infra repository
git clone https://github.com/florencepascual/test-infra.git
# Set CONFIG_PATH and JOB_CONFIG_PATH with an absolute path
export CONFIG_PATH="$(pwd)/test-infra/config/prow/config.yaml" 
export JOB_CONFIG_PATH="$(pwd)/test-infra/config/jobs/periodic/docker-in-docker/periodic-dind-build.yaml"

./test-infra-test/hack/test-pj.sh docker-build
```
If you are asked about **Volume "ssh-keys-bot-ssh-secret"**, answer empty.
