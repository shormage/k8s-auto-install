# How to Run 

download package.tar.gz 

chmod +x R_SH

sudo ./R_SH

# Project Structure
R_SH/
├── R_SH
├── config.env
├── common.sh
├── install.sh
├── health.sh
├── reset.sh
├── package.tar.gz ------> ├── packages/
                           ├── v1.34/
                           └── v1.35/
└── logs/

# R_SH Kubernetes Installer v2.0

## Overview

**R_SH Kubernetes Installer** is a Bash-based installation tool designed to simplify the deployment of Kubernetes clusters using `kubeadm`.

The main goal of this project is to provide a clean, repeatable, and production-friendly way to install Kubernetes Master and Worker nodes in both **online** and **fully offline** environments.

This installer is especially useful for private data centers, restricted networks, enterprise environments, and offline infrastructures where direct access to public container registries or package repositories is not available.

Online and Offline Installation Modes

The installer supports two installation modes:

#### Online Mode

In online mode, the installer can download required packages and manifests from official sources.

#### Offline Mode

In offline mode, the installer does not use the internet.

All required files must already exist inside the local `packages` directory.

For example:

```text
packages/
├── v1.34/
└── v1.35/

How to Run
chmod +x R_SH
sudo ./R_SH
