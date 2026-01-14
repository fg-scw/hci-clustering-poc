# Proxmox Ceph HCI on Scaleway

Déploiement automatisé d'un cluster hyperconvergé Proxmox + Ceph sur Scaleway Elastic Metal.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                              Scaleway VPC                                        │
├───────────────────────────────┬──────────────────────────────────────────────────┤
│   Public Network (vmbr1)      │      Cluster Network (vmbr2)                     │
│   172.16.28.0/22              │      172.16.36.0/22                              │
│   Ceph MON, VM traffic        │      Ceph OSD Replication                        │
├───────────────────────────────┴──────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │    pve1     │    │    pve2     │    │    pve3     │    │  Public Gateway  │   │
│  │   Proxmox   │    │   Proxmox   │    │   Proxmox   │    │  ┌────────────┐  │   │
│  │  Ceph MON   │    │  Ceph MON   │    │  Ceph MON   │    │  │ SSH Bastion│  │   │
│  │  Ceph OSD   │    │  Ceph OSD   │    │  Ceph OSD   │    │  │ NAT (SNAT) │  │   │
│  └─────────────┘    └─────────────┘    └─────────────┘    │  │ DHCP Server│  │   │
│       Rack A             Rack A             Rack B        │  └────────────┘  │   │
│                                                           └──────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────┘
```

## Fonctionnalités

- ✅ **Public Gateway** : NAT pour accès internet des VMs + SSH Bastion
- ✅ **IPAM** : Adresses IP réservées et prévisibles
- ✅ **Ansible idempotent** : Relance sûre du déploiement à tout moment
- ✅ **Multi-type serveur** : Support EM-I120E-NVME, EM-L220E-NVME, etc.
- ✅ **Partitionnement automatique** : OS sur nvme0n1, autres disques libres pour Ceph

## Prérequis

```bash
# Outils requis
brew install terraform    # ou apt install terraform
pip install ansible jmespath netaddr

# Collections Ansible
ansible-galaxy collection install community.general ansible.posix

# Configuration Scaleway CLI
scw init
```

---

## Workflow de déploiement

### Étape 1 : Configurer les variables Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Éditer terraform.tfvars :
```hcl
# OBLIGATOIRE : ID de clé SSH Scaleway IAM
# Récupérer avec : scw iam ssh-key list
ssh_key_ids = ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]

# OBLIGATOIRE : Mot de passe Proxmox (8+ chars)
service_password = "VotreMotDePasse123!"

# Type de serveur
server_type = "EM-I120E-NVME"  # 2 disques - 1 OSD/noeud (test)
# server_type = "EM-L220E-NVME"  # 4 disques - 3 OSDs/noeud (production)

# Public Gateway (optionnel mais recommandé)
enable_public_gateway = true
enable_ssh_bastion    = true
```

### Étape 2 : Déployer l'infrastructure

```bash
terraform init
terraform apply
```

Attendre 10-15 minutes que les serveurs passent en état ready :
```bash
scw baremetal server list zone=fr-par-2 -o wide
```

### Étape 3 : Configurer SSH manuellement sur chaque noeud

> **IMPORTANT** : Cloud-init n'est PAS supporté sur les images Proxmox VE pour Elastic Metal.
> Vous devez configurer SSH manuellement via la console Proxmox (Shell) avant de pouvoir utiliser Ansible.

**Sur chaque serveur** via la console Web Proxmox (https://IP:8006 > Shell) :

```bash
# 1. Configurer SSH pour autoriser root avec clé
sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# 2. Ajouter votre clé SSH publique (remplacer par votre clé)
mkdir -p ~/.ssh
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-rsa AAAAB3... votre-cle-publique ...== user@machine
EOF

# 3. Configurer les dépôts Proxmox (optionnel mais recommandé)
rm -f /etc/apt/sources.list.d/pve-enterprise.list
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
```

Pour obtenir votre clé publique (sur votre machine locale) :
```bash
cat ~/.ssh/id_rsa.pub
```

### Étape 4 : Vérifier l'accès SSH

```bash
# Depuis votre machine locale
ssh root@<IP_SERVEUR>

# Doit fonctionner sans demander de mot de passe
```

### Étape 5 : Déployer avec Ansible

```bash
cd ../ansible

# Installer les collections requises
ansible-galaxy install -r requirements.yml

# Vérifier la connectivité
ansible all -m ping

# Déploiement complet
ansible-playbook playbooks/site.yml
```

#### Déploiement étape par étape (debug)

```bash
# 1. Bootstrap : réseau, /etc/hosts
ansible-playbook playbooks/01-bootstrap.yml

# 2. Cluster : création cluster Proxmox, NTP, échange clés SSH
ansible-playbook playbooks/02-cluster.yml

# 3. Ceph : MON, MGR, OSDs, pool
ansible-playbook playbooks/03-ceph.yml
```

---

## Structure du projet

```
proxmox-ceph-hci-scaleway/
├── README.md
├── terraform/
│   ├── main.tf                    # Locals et configuration principale
│   ├── variables.tf               # Variables d'entrée
│   ├── network.tf                 # VPC, Private Networks, IPAM
│   ├── servers.tf                 # Serveurs Elastic Metal
│   ├── gateway.tf                 # Public Gateway + SSH Bastion
│   ├── inventory.tf               # Génération inventaire Ansible
│   ├── outputs.tf                 # Outputs
│   ├── data.tf                    # Data sources
│   ├── versions.tf                # Providers
│   └── terraform.tfvars.example
│
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml
    ├── inventory/                  # Généré par Terraform
    │   ├── hosts.yml
    │   └── group_vars/
    │       └── all.yml
    └── playbooks/
        ├── site.yml               # Playbook principal
        ├── 01-bootstrap.yml       # Réseau, /etc/hosts
        ├── 02-cluster.yml         # Cluster Proxmox
        └── 03-ceph.yml            # Installation Ceph
```

---

## Configuration réseau

### Bridges Proxmox

| Bridge | Réseau           | Usage                          |
|--------|------------------|--------------------------------|
| vmbr0  | IP publique      | Management (SSH, API)          |
| vmbr1  | 172.16.28.0/22   | Ceph public, trafic VMs        |
| vmbr2  | 172.16.36.0/22   | Ceph cluster (réplication OSD) |

---

## Troubleshooting

### SSH ne fonctionne pas après déploiement

1. **Vérifiez la configuration sshd** :
   ```bash
   # Via console Proxmox
   grep -E "PermitRootLogin|PubkeyAuthentication" /etc/ssh/sshd_config
   ```

2. **Vérifiez la clé SSH** :
   ```bash
   cat ~/.ssh/authorized_keys
   ```

3. **Redémarrez SSH** :
   ```bash
   systemctl restart sshd
   ```

### Les VMs n'ont pas d'accès internet

1. Vérifier que Public Gateway est activé
2. Vérifier que le masquerading (SNAT) est configuré
3. Vérifier la route par défaut dans les VMs

---

## Références

- [Proxmox VE Documentation](https://pve.proxmox.com/wiki/Main_Page)
- [Ceph Documentation](https://docs.ceph.com/)
- [Scaleway Elastic Metal](https://www.scaleway.com/en/elastic-metal/)

## Licence

MIT License - voir [LICENSE](LICENSE)
