# Scripts for the prow job periodic-dind-build

The goal of these scripts and the two associated prow jobs is to automate the process of building the docker-ce and containerd packages (as well as the static binaries) for ppc64le and of testing them. The packages would then be shared with the Docker team and be available on the https://download.docker.com package repositories.

To build these packages, we use the [docker-ce-packaging](https://github.com/docker/docker-ce-packaging) and the [containerd-packaging](https://github.com/docker/containerd-packaging/) repositories.

For now, this process is semi-automated.

## Prow jobs

At the beginning, there was only one periodic prow job. However, it was taking too long to build the docker and containerd packages and exceeded the 2-hour timeout. It was taking a little bit more than 3 hours. We first worked on a periodic prow job because of the lack of tags on the [docker-ce-packaging](https://github.com/docker/docker-ce-packaging) repository and of webhooks to this repository. 
For the moment, it is a semi-automated process, since we still need to manually edit the env.list file with the versions and the hash commits.

The prow job was then split into two postsubmit prow jobs. 
1. First prow job : [postsubmit-build-docker.yaml](https://github.com/florencepascual/test-infra/blob/postsubmit-docker-build/config/jobs/ppc64le-cloud/build-docker/postsubmit-build-docker.yaml)

This postsubmit prow job is triggered by the editing of the [env.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/env.list). This file contains the information we need to build the packages : 
- DOCKER_VERS : latest version of docker, that we want to build
- DOCKER_PACKAGING_REF : commit associated to the latest version of docker
- CONTAINERD_BUILD : if set to 1, it means that a new containerd version has been released in the 1.4 branch and that we have not built it yet ; if set to 0, it means that we have already built it in a previous prow job and that we do not need to build it again (we will still check that no new distribution has been added in the meantime).
- CONTAINERD_VERS : latest version of containerd
- CONTAINERD_PACKAGING_REF : commit associated to the latest version of containerd
- RUNC_VERS : runc version used to build the static packages

This prow job builds the dynamic docker packages and then pushes them to our internal COS bucket, before editing this file [date.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/date.list) with the date. We use the date in the directory where we store the docker packages in the COS bucket, so that we don't confuse the different builds.

1. [Start the docker daemon](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L20:L22)
2. [Access to the internal COS Bucket and set up the environmental variables](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L29:L34)
3. [Build the dynamic and static docker packages](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L36:L40)
4. [Push to the github repository the date.list file](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L48:L49)

2. Second prow job : [postsubmit-build-container.yaml](https://github.com/florencepascual/test-infra/blob/postsubmit-docker-build/config/jobs/ppc64le-cloud/build-docker/postsubmit-build-containerd.yaml)

This postsubmit prow job is triggered by the editing of the [date.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/date.list), which was edited at the end of the first prow job.
This prow job builds the dynamic containerd packages (if CONTAINERD_BUILD is set to 1 in the [env.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/env.list)), the static packages, and tests all packages.

1. [Start the docker daemon](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L23:L25)
2. [Access to the internal COS Bucket and set up the environmental variables](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L34)
3. [Get the dockertest and containerd directories if CONTAINERD_BUILD=0 from the COS bucket](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L35)
4. [Build the dynamic containerd packages if CONTAINERD_BUILD=1 and the static packages](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L42:L46)
5. [Test the dynamic and static packages and check if there are any errors](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L48:L58)
6. [Push to the COS bucket shared with the Docker team the docker and containerd packages](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/prow-build-docker.sh#L63:L65)

### The 8 scripts in detail

- [dockerctl.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/dockerctl.sh)
**Usage**: dockerctl [start] | [stop]

Start or Stop the dockerd daemon.
This script runs the **dockerd-entrypoint.sh** in the background and then checks if the docker daemon has started and is running. We specify the MTU. See the reason [here](https://sylwit.medium.com/how-we-spent-a-full-day-figuring-out-a-mtu-issue-with-docker-4d81fdfe2caf).

- [get-env.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/get-env.sh)

This script mounts the internal COS bucket for further uses.
It clones the [docker-ce-packaging](https://github.com/docker/docker-ce-packaging) using the hash commit specified in the [env.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/env.list) and gets the list of distributions in the **env-distrib.list**.

- [get-env-containerd.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/get-env-containerd.sh)

This script mounts the internal COS bucket, if it has not already been mounted.
It gets the dockertest directory from the COS bucket. 
It also gets the latest containerd directory in the COS bucket, if the latest version has already been built. We get the latest containerd directory for the tests.

- [build-docker.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/build-docker.sh)

This script builds the version of the dynamic docker packages, which is specified in the [env.list](https://github.com/florencepascual/docker-ce-build/blob/feature-optimising-builds-task/env/env.list).
We build in parallel to gain some time. We build 4 distributions at the same time.
After each package successfully built, we push the package to our internal COS bucket, to ensure that we have them stored in case the prow job fails before finishing.

- [build-containerd.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/get-build-containerd.sh)

This script builds the version of the dynamic docker packages, which is specified in the [env.list](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/env/env.list) and the static packages. As already mentionned, it only builds the containerd packages if CONTAINERD_BUILD is set to 1. 
We cannot build the packages in parallel, due to a ``git`` command in the Makefile.
As for the **build-docker.sh**, the packages are pushed to the internal COS bucket.

- [build-static.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/build-static.sh)

This script builds the static binaries and rename them (removes the version and adds ppc64le). It should be run in a container. The image of the container is the same image used as the basis of the prow jobs : [quay.io/powercloud/docker-ce-build](https://quay.io/repository/powercloud/docker-ce-build).

- [test.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test.sh)

This script sets up the tests for both the docker-ce and containerd packages and the static binaries. In this script, for each distribution, we build an image, where we install the newly built packages. We then run a docker based on this said image, in which we run **test_launch.sh**.
We do this for each distribution, for the docker-ce packages and the static binaries.
It generates an **errors.txt** file with a summary of all tests, containing the exit codes of each test.

- [test-launch.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-launch.sh)

This script is called in the **test.sh**. This runs three tests for every distro we have built, using the [powercloud/dockertest](https://github.ibm.com/powercloud/dockertest). It uses gotestsum to generate xml files.
- test 1 : TestDistro
- test 2 : TestDistroInstallPackage
- test 3 : TestDistroPackageCheck

- [check-tests.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/check-tests.sh)

This script checks the **errors.txt**, generated by the test.sh, to determine if there are any errors in the tests of the packages.

- [push-COS.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/push-COS.sh)

This script should push all packages built to the COS bucket shared with Docker. However, all cp commands are commented for now, since it is still a test.

- [test-staging.sh](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-staging.sh)

This script is not called in any of the prow jobs, but is used manually to check the packages published by Docker on https://download-stage.docker.com are correct.
It uses the same basis as **test.sh** but uses different images (test-staging-DEBS and test-staging-RPMS).

### The 7 images in detail

- [dind-docker-build](https://github.com/florencepascual/test-infra/blob/master/images/docker-in-docker/Dockerfile)

This Dockerfile is used for getting a docker-in-docker container. It is used for the basis of the prow job, as well as for the container building the packages and the one testing the packages. It also installs s3fs to get directly access to the COS buckets.

- [test-DEBS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-DEBS/Dockerfile) and [test-RPMS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-RPMS/Dockerfile)

These two Dockerfiles are used for testing the docker-ce and containerd packages. Depending on the distro type (debs or rpms), we use them to build a container to test the packages and run **test_launch.sh**.

- [test-static-DEBS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-static-DEBS/Dockerfile) and [test-static-RPMS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-static-RPMS/Dockerfile)

These two Dockerfiles are used for testing the static binaries. Like the two aforementioned Dockerfiles : depending on the distro type (debs or rpms), we use them to build a container to test the packages and run **test_launch.sh**.

- [test-staging-DEBS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-staging-DEBS/Dockerfile) and [test-staging-RPMS](https://github.com/ppc64le-cloud/docker-ce-build/blob/main/test-staging-RPMS/Dockerfile)

These two Dockerfiles are used for testing the packages after Docker has published them on https://download-stage.docker.com. As well as for the previous Dockerfiles, depending on the distro type, we use them to build a container and test the packages with the script **test_launch.sh**.

## How to test the scripts manually in a pod
### Set up the secrets and the pod

You need first to set up the secrets docker-token and docker-s3-credentials with kubectl.

```bash
# docker-token
docker login
kubectl create secret generic docker-token \
    --from-file=.dockerconfigjson=$HOME/.docker/config.json \
    --type=kubernetes.io/dockerconfigjson
```
Template of secret for the **secret-s3.yaml** and the **git-credentials** (the latter only for tests), you just need to add the password in base64.
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: #add name
type: Opaque
data:
  password: #add password in base64
```

```bash
kubectl apply -f secret-s3.yaml
```
You also need the **dockerd-entrypoint.sh**, which is the script that starts the docker daemon :
```
wget -O /usr/local/bin/dockerd-entrypoint.sh https://raw.githubusercontent.com/docker-library/docker/094faa88f437cafef7aeb0cc36e75b59046cc4b9/20.10/dind/dockerd-entrypoint.sh
chmod +x /usr/local/bin/dockerd-entrypoint.sh
```
**pod.yaml**
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
    args:
    - "--mtu=1440"
    image: quay.io/powercloud/docker-ce-build
    resources:
      requests:
        cpu: "4000m"
        memory: "8Gi"
      limits:
        cpu: "4000m"
        memory: "8Gi"
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
            name: docker-s3-credentials
            key: password
  terminationGracePeriodSeconds: 18
  volumes:
  - name: docker-graph-storage
    emptyDir: {}
```
```bash
kubectl apply -f pod.yaml
kubectl exec -it pod/pod-docker-build -- /bin/bash
```

Explanations :
- The MTU needs to be specified, see [Investigate the docker daemon configuration for docker-in-docker](https://github.ibm.com/powercloud/container-dev/issues/1543)
- The resources : [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- The securityContext must be "privileged" and the volume /var/lib/docker must be specified : see [Docker can now run within Docker](https://www.docker.com/blog/docker-can-now-run-within-docker/)

### Run the scripts

Run **prow-build-docker.sh** or **prow-build-container.sh** except for the line calling **dockerctl.sh**. The **dockerd-entrypoint.sh** script has already been called as entrypoint of the pod, so it should not be called a second time.

## How to test the whole prow job on a cluster

If the cluster was already created, get only the config file containing the necessary information to connect to the cluster and point the KUBECONFIG variable to the file.
If there is no cluster, you can create a ppc64le cluster with kubeadm.
The script that can run the prow job on the ppc64le cluster must be used on an x86 machine (no ppc64le support for kind).

### Set up a ppc64le cluster with kubeadm

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
On either of these machines, where the ppc64le cluster is running, configure the secrets (docker-s3-credentials and docker-token if needed).

### Run the prow job on a x86 machine
On the x86 machine :
```bash
# Set CONFIG_PATH and JOB_CONFIG_PATH with an absolute path
export CONFIG_PATH="$(pwd)/test-infra/config/prow/config.yaml"
export JOB_CONFIG_PATH="$(pwd)/test-infra/config/jobs/periodic/docker-in-docker/periodic-build-docker.yaml"

./test-infra/hack/test-pj.sh ${JOB_NAME}
# The job name is specified in your yaml.
```
#### Things to know when running a prow job against a ppc64le cluster :

- If you don't need it and you are asked about **Volume "ssh-keys-bot-ssh-secret"**, answer empty, or you can remove these lines from the [config.yaml](https://github.com/ppc64le-cloud/test-infra/blob/master/config/prow/config.yaml#L77:L78).
- In the [test-pj.sh](https://github.com/ppc64le-cloud/test-infra/blob/master/hack/test-pj.sh#L16), the **--local** flag specifies the local directory in which the logs will be stored. If you want it to be pushed to a COS bucket or if you want the logs to be displayed in the UI, you need to remove the **--local** flag and the directory specified afterwards.
- Namespace : test-pods (namespace where to test the prow jobs)
- The [prow UI](https://prow.ppc64le-cloud.org/) and the [job-history of my prow job postsubmit-build-docker](https://prow.ppc64le-cloud.org/job-history/s3/prow-logs/logs/postsubmit-build-docker)
