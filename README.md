# devops-utils-bootstrappers

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell Script](https://img.shields.io/badge/Shell_Script-121011?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white)](https://www.debian.org/)
[![RHEL](https://img.shields.io/badge/Red%20Hat-EE0000?logo=redhat&logoColor=white)](https://www.redhat.com/)

> 🛠️ A collection of shell scripts for quickly bootstrapping common DevOps tools and utilities.

## 📋 Overview

This repository contains setup scripts for provisioning development and production environments with essential infrastructure tools. Each script is designed to be idempotent and can be run on fresh systems or existing installations.

## 📦 Available Scripts

| Script | Tool | Description |
|--------|------|-------------|
| `setup-vault.sh` | ![Vault](https://img.shields.io/badge/Vault-FFEC6E?logo=vault&logoColor=black) | Installs and configures HashiCorp Vault |
| `setup-lynx.sh` | ![Lynx](https://img.shields.io/badge/Lynx-8A2BE2?logo=internetexplorer&logoColor=white) | Installs the Lynx text-based web browser |
| `setup-terraform.sh` | ![Terraform](https://img.shields.io/badge/Terraform-7B42BC?logo=terraform&logoColor=white) | Installs Terraform CLI |
| `setup-consul.sh` | ![Consul](https://img.shields.io/badge/Consul-F24C53?logo=consul&logoColor=white) | Installs and configures HashiCorp Consul |
| `setup-docker.sh` | ![Docker](https://img.shields.io/badge/Docker-2496ED?logo=docker&logoColor=white) | Installs Docker Engine and Docker Compose |
| `setup-kubectl.sh` | ![Kubernetes](https://img.shields.io/badge/kubectl-326CE5?logo=kubernetes&logoColor=white) | Installs kubectl and configures kubeconfig |

## 🚀 Usage

```bash
# Clone the repository
git clone https://github.com/yourorg/devops-utils-bootstrappers.git
cd devops-utils-bootstrappers

# Make scripts executable
chmod +x scripts/*.sh

# Run a specific setup script
./scripts/setup-vault.sh
```

## ✅ Requirements

- 🐚 Bash 4.0+
- 🔐 Root/sudo access
- 🌐 Internet connectivity

## 💻 Supported Platforms

| Platform | Versions |
|----------|----------|
| ![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?logo=ubuntu&logoColor=white) | 20.04 / 22.04 / 24.04 |
| ![Debian](https://img.shields.io/badge/Debian-A81D33?logo=debian&logoColor=white) | 11 / 12 |
| ![RHEL](https://img.shields.io/badge/RHEL-EE0000?logo=redhat&logoColor=white) | 8 / 9 |
| ![Amazon Linux](https://img.shields.io/badge/Amazon%20Linux-FF9900?logo=amazon&logoColor=white) | 2 / 2023 |

## ⚙️ Configuration

Each script reads from environment variables or a `.env` file in the repository root:

```bash
# .env.example
VAULT_VERSION="1.15.0"
INSTALL_DIR="/usr/local/bin"
LOG_LEVEL="info"
```

## 🤝 Contributing

1. 🍴 Fork the repository
2. 🌿 Create a feature branch
3. 📬 Submit a pull request

## 📄 License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
