# delta

DevOps Tooling - Automate and Orchestrate.

A collection of DevOps automation and orchestration tooling, covering CI/CD on Kubernetes and Ansible-driven OS patching for Linux and Windows fleets.

## Contents

| Directory | What it does |
|---|---|
| [`K8s/jenkins-server`](K8s/jenkins-server) | Kustomize-based Jenkins deployment (with Docker-in-Docker) on k3s, managed via shell scripts. Includes TLS via cert-manager and Traefik. |
| [`Ansible_OS_Patching/Linux_Patching`](Ansible_OS_Patching/Linux_Patching) | Ansible playbooks that automate patching for CentOS/RHEL and Debian/Ubuntu, plus pre-flight checks. |
| [`Ansible_OS_Patching/Linux_Patching_group_by`](Ansible_OS_Patching/Linux_Patching_group_by) | Group-based variant of the Linux patching playbooks (CentOS/RHEL 7-9, Ubuntu 18.04/20.04), with a Jenkinsfile and wrapper scripts for check/apply runs. |
| [`Ansible_OS_Patching/Windows_Patching`](Ansible_OS_Patching/Windows_Patching) | Ansible playbooks for patching Windows Server (security-only or full update rollups) over WinRM. |
| [`Ansible_Docker/ansible-containers/docker-nginx`](Ansible_Docker/ansible-containers/docker-nginx) | Ansible role for deploying an nginx container. |

## Jenkins on Kubernetes (k3s)

The most involved piece of tooling here is the Jenkins-on-k3s stack — see [`K8s/jenkins-server/README.md`](K8s/jenkins-server/README.md) for full architecture, deployment order, and troubleshooting.

Quick start:
```bash
cd K8s/jenkins-server
./deploy-certs.sh deploy    # cert-manager must come first — Jenkins Ingress depends on its ClusterIssuer
./deploy-jenkins.sh deploy
```

## Ansible OS Patching

Playbooks for automating routine OS patching across Linux and Windows estates. Each subdirectory has its own README with installation and usage details; in short:

```bash
# Linux (RHEL/CentOS/Ubuntu)
cd Ansible_OS_Patching/Linux_Patching
ansible-playbook update-by-group.yml -v
ansible-playbook rhel9-patch-simple.yml --check   # dry run

# Windows
cd Ansible_OS_Patching/Windows_Patching
ansible-playbook win-update-all.yml -e "admin_password=your_password"
```

## License

[MIT](LICENSE)

## Author

Joey Allen
