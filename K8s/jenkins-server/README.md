# Jenkins on Kubernetes (k3s)

A Kustomize-based deployment of Jenkins with Docker-in-Docker (dind) on k3s,
managed via shell scripts. Includes TLS termination via Traefik and cert-manager,
and a working CI pipeline to Docker Hub.

## Directory Structure

```
K8s/jenkins-server/
├── deploy-jenkins.sh                  # Deploy/manage Jenkins
├── deploy-certs.sh                    # Deploy/manage cert-manager
├── check-dind-images.sh               # Inspect dind image storage
├── compose/
│   └── docker-compose.yml             # Original compose reference
├── cert-manager/
│   └── kustomize/
│       ├── kustomization.yml
│       └── selfsigned-issuer.yml
└── jenkins-server/
    └── kustomize/
        ├── kustomization.yml
        ├── jenkins-deployment.yml                # Jenkins LTS container
        ├── jenkins-docker-deployment.yml  # dind container
        ├── jenkins-docker-service.yml     # ClusterIP — dind port 2376
        ├── jenkins-service.yml            # NodePort 30081 — Jenkins UI
        ├── jenkins-ingress.yml            # Traefik HTTPS — jenkins.local
        ├── jenkins-rbac.yml               # ServiceAccount, Role, ClusterRole
        ├── jenkins-data-pvc.yml           # /var/jenkins_home — 100Mi RWO
        └── jenkins-docker-certs-pvc.yml   # /certs/client — 100Mi RWO
```

## Architecture

```
jenkins-server (namespace)
├── jenkins (Pod)                  # Jenkins LTS — jdk21, ports 8080/50000
│   └── initContainer              # Copies docker CLI binary from docker:latest
├── jenkins-docker (Deployment)    # docker:dind — port 2376, overlay2
├── jenkins-docker (Service)       # ClusterIP — TCP/TLS to dind
├── jenkins (Service)              # NodePort 30081 — Jenkins UI
├── jenkins (Ingress)              # Traefik HTTPS — jenkins.local:443
├── jenkins-data (PVC)             # Jenkins home — 100Mi RWO
└── jenkins-certs (PVC)            # TLS certs shared with dind — 100Mi RWO

cert-manager (namespace)
├── cert-manager (Deployment)      # Certificate controller
├── cert-manager-webhook           # Admission webhook
└── selfsigned-issuer (ClusterIssuer)  # Issues self-signed certs
```

Jenkins connects to dind over TLS at `tcp://jenkins-docker:2376`.
Certs are shared via the `jenkins-certs` PVC and mounted read-only into Jenkins.
The docker CLI binary is injected at pod startup via an init container.

## Prerequisites

- k3s with Traefik ingress controller (included by default)
- `kubectl` configured against your cluster
- `kustomize` (optional — falls back to `kubectl kustomize`)
- `/etc/hosts` entry on the browsing machine: `<node-ip>  jenkins.local`

## Deployment Order

cert-manager must be deployed before Jenkins so the `ClusterIssuer` exists
when the Jenkins Ingress is created.

```bash
# 1. Deploy cert-manager and ClusterIssuer
cd K8s/jenkins-server
./deploy-certs.sh deploy

# 2. Deploy Jenkins once cert-manager is confirmed ready
./deploy-jenkins.sh deploy
```

## Accessing Jenkins

| Method | URL | Notes |
|---|---|---|
| HTTPS (Ingress) | https://jenkins.local | Requires /etc/hosts entry |
| NodePort | http://\<node-ip\>:30081 | Direct access, no hostname needed |

```bash
# Find the node IP
kubectl get nodes -o wide
```

### Initial Admin Password

```bash
kubectl exec -n jenkins-server \
  $(kubectl get pods -n jenkins-server -l io.kompose.service=jenkins \
  -o jsonpath='{.items[0].metadata.name}') \
  -- cat /var/jenkins_home/secrets/initialAdminPassword
```

## Managing the Deployment

```bash
# Jenkins
./deploy-jenkins.sh deploy      # Deploy or re-apply
./deploy-jenkins.sh status      # Show all resources and PVC state
./deploy-jenkins.sh logs        # Tail logs from the first Jenkins pod
./deploy-jenkins.sh restart     # Teardown then redeploy
./deploy-jenkins.sh teardown    # Remove all resources (prompts before deleting PVCs)

# cert-manager
./deploy-certs.sh deploy        # Install cert-manager and ClusterIssuer
./deploy-certs.sh status        # Show deployments, issuers and certificates
./deploy-certs.sh teardown      # Remove cert-manager (prompts for confirmation)
```

## TLS Configuration

dind generates TLS certificates at startup. The `DOCKER_TLS_SAN` environment
variable ensures the certificate includes the correct hostnames so Jenkins
can verify it:

```yaml
# jenkins-docker-deployment.yml
env:
  - name: DOCKER_TLS_CERTDIR
    value: /certs
  - name: DOCKER_TLS_SAN
    value: "DNS:jenkins-docker,DNS:localhost,IP:127.0.0.1"
```

If you see `x509: certificate is valid for docker, not jenkins-docker`:

```bash
# Delete the certs PVC to force regeneration
kubectl delete pvc jenkins-certs -n jenkins-server

# Restart dind to regenerate certs with the correct SANs
kubectl rollout restart deployment/jenkins-docker -n jenkins-server
```

## Docker CLI in Jenkins

The Jenkins image does not include the docker CLI. An init container copies
the binary from `docker:latest` into a shared `emptyDir` volume which is
then mounted into the Jenkins container at `/usr/local/bin/docker`:

```yaml
initContainers:
  - name: install-docker-cli
    image: docker:latest
    command: ['sh', '-c', 'cp /usr/local/bin/docker /docker-bin/docker']
    volumeMounts:
      - mountPath: /docker-bin
        name: docker-bin
```

## Pipeline Configuration

Pipelines follow this repo convention:

```
Docker/
└── <project>/
    ├── Dockerfile
    └── Jenkinsfile
```

In Jenkins, set the script path to `Docker/<project>/Jenkinsfile` under
**Pipeline script from SCM** and point SCM at your Git repository.

### Hello World Pipeline

Validates the full Jenkins → dind → build → run chain:

```groovy
pipeline {
    agent any

    environment {
        DOCKER_HOST       = "tcp://jenkins-docker:2376"
        DOCKER_TLS_VERIFY = "1"
        DOCKER_CERT_PATH  = "/certs/client"
        IMAGE_NAME        = "hello-world-jenkins"
        IMAGE_TAG         = "${BUILD_NUMBER}"
    }

    stages {
        stage('Docker Version') {
            steps { sh 'docker version' }
        }
        stage('Build Image') {
            steps {
                sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} Docker/hello-world/'
            }
        }
        stage('Test Image') {
            steps { sh 'docker run --rm ${IMAGE_NAME}:${IMAGE_TAG}' }
        }
        stage('Cleanup') {
            steps { sh 'docker rmi ${IMAGE_NAME}:${IMAGE_TAG}' }
        }
    }

    post {
        success { echo "Build ${BUILD_NUMBER} completed successfully" }
        failure { echo "Build ${BUILD_NUMBER} failed — check logs above" }
    }
}
```

### Docker Hub Pipeline

Add Docker Hub credentials in Jenkins before use:
**Manage Jenkins → Credentials → Global → Add → Username with password**

Use a Docker Hub access token (not your password). Set the ID to match
`DOCKERHUB_CREDENTIALS` in the `Jenkinsfile`.

```groovy
pipeline {
    agent any

    environment {
        DOCKERHUB_CREDENTIALS = credentials('cred-dockerhub')
        DOCKER_HOST           = "tcp://jenkins-docker:2376"
        DOCKER_TLS_VERIFY     = "1"
        DOCKER_CERT_PATH      = "/certs/client"
        IMAGE_NAME            = "cred/hello-world-jenkins"
        IMAGE_TAG             = "${BUILD_NUMBER}"
    }

    stages {
        stage('Docker Version') { steps { sh 'docker version' } }
        stage('Build Image') {
            steps {
                sh 'docker build -t ${IMAGE_NAME}:${IMAGE_TAG} Docker/hello-world/'
            }
        }
        stage('Test Image') {
            steps { sh 'docker run --rm ${IMAGE_NAME}:${IMAGE_TAG}' }
        }
        stage('Docker Hub Login') {
            steps {
                sh 'echo $DOCKERHUB_CREDENTIALS_PSW | docker login -u $DOCKERHUB_CREDENTIALS_USR --password-stdin'
            }
        }
        stage('Push Image') {
            steps { sh 'docker push ${IMAGE_NAME}:${IMAGE_TAG}' }
        }
        stage('Cleanup') {
            steps { sh 'docker rmi ${IMAGE_NAME}:${IMAGE_TAG}' }
        }
    }

    post {
        always  { sh 'docker logout' }
        success { echo "Build ${BUILD_NUMBER} pushed to Docker Hub successfully" }
        failure { echo "Build ${BUILD_NUMBER} failed — check logs above" }
    }
}
```

## Inspecting dind Storage

```bash
# Run the check script
./check-dind-images.sh

# Or manually
DIND_POD=$(kubectl get pods -n jenkins-server \
  -l io.kompose.service=jenkins-docker \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec <pod-name> -n jenkins-server $DIND_POD -- docker images
kubectl exec <pod-name> -n jenkins-server $DIND_POD -- docker system df

# Remove a specific image
kubectl exec <pod-name> -n jenkins-server $DIND_POD -- docker rmi <image-name> --force
```

Always include a `Cleanup` stage in pipelines to remove images after build
and push — the `jenkins-certs` and `jenkins-data` PVCs are only 100Mi.

## Quick Reference

| What | Command |
|---|---|
| List all pods | `kubectl get pods -n jenkins-server` |
| Get dind endpoints | `kubectl get endpointslices -n jenkins-server -l kubernetes.io/service-name=jenkins-docker` |
| Exec into Jenkins | `kubectl exec -it <pod> -n jenkins-server -- /bin/bash` |
| Exec into dind | `kubectl exec -it <dind-pod> -n jenkins-server -- /bin/sh` |
| Pod logs | `kubectl logs <pod> -n jenkins-server` |
| All resources | `kubectl get all -n jenkins-server` |
| PVC status | `kubectl get pvc -n jenkins-server` |
| cert-manager certs | `kubectl get certificates --all-namespaces` |

## Troubleshooting

**Pods stuck in Pending:**
```bash
kubectl get pvc -n jenkins-server
kubectl describe pvc jenkins-certs -n jenkins-server
kubectl get events -n jenkins-server --sort-by='.lastTimestamp' | tail -20
```

**docker: not found in pipeline:**
Check the init container completed successfully:
```bash
kubectl describe pod jenkins -n jenkins-server | grep -A5 "Init Containers"
```

**TLS certificate hostname mismatch:**
Delete the `jenkins-certs` PVC and restart the dind Deployment to regenerate
certs with the correct SANs — see the TLS Configuration section above.

**dind endpoint unset:**
```bash
kubectl get endpointslices -n jenkins-server \
  -l kubernetes.io/service-name=jenkins-docker
```
If empty, verify the dind Deployment pod template label is
`io.kompose.service: jenkins-docker` and matches the service selector.

## Configuration Notes

| Setting | Value | Location |
|---|---|---|
| Jenkins UI NodePort | 30081 | `jenkins-service.yml` |
| Jenkins HTTPS hostname | jenkins.local | `jenkins-ingress.yml` |
| dind TLS port | 2376 (ClusterIP) | `jenkins-docker-service.yml` |
| Jenkins home storage | 100Mi RWO | `jenkins-data-pvc.yml` |
| Certs storage | 100Mi RWO | `jenkins-docker-certs-pvc.yml` |
| CPU / memory limits | 500m–2 / 512Mi–2Gi | `kustomization.yml` patch |
| Environment | development | `kustomization.yml` labels |

> **Storage note:** 100Mi for `jenkins-data` will fill quickly with plugins
> and build artefacts. Consider increasing to 5–10Gi for anything beyond
> initial testing. Monitor dind storage regularly with `./check-dind-images.sh`
> and ensure every pipeline includes a `Cleanup` stage.
