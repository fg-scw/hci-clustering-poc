# Proxmox Ceph HCI on Scaleway

Déploiement automatisé d'un cluster hyperconvergé Proxmox + Ceph sur Scaleway Elastic Metal.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                           Scaleway VPC                                │
├─────────────────────────────┬────────────────────────────────────────┤
│   Public Network (vmbr1)    │      Cluster Network (vmbr2)           │
│   172.16.28.0/22            │      172.16.36.0/22                    │
│   Ceph MON, VM traffic      │      Ceph OSD Replication              │
├─────────────────────────────┴────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐              │
│  │    pve1     │    │    pve2     │    │    pve3     │              │
│  │  VLAN 1991  │    │  VLAN 1991  │    │  VLAN 1991  │  ← Public    │
│  │  VLAN 2128  │    │  VLAN 2128  │    │  VLAN 3358  │  ← Cluster   │
│  │   Proxmox   │    │   Proxmox   │    │   Proxmox   │              │
│  │  Ceph MON   │    │  Ceph MON   │    │  Ceph MON   │              │
│  │  Ceph OSD   │    │  Ceph OSD   │    │  Ceph OSD   │              │
│  └─────────────┘    └─────────────┘    └─────────────┘              │
│       Rack A             Rack A             Rack B                   │
└──────────────────────────────────────────────────────────────────────┘
```

### Spécificité Scaleway : VLANs par rack

> ⚠️ **Important** : Sur Scaleway Elastic Metal, les serveurs sur un même Private Network peuvent avoir des **VLAN IDs différents**. Cela correspond à l'architecture physique du datacenter (racks différents).
>
> Le déploiement gère automatiquement cette spécificité en attribuant les VLANs au niveau de chaque serveur (host_vars) et non globalement.

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

### Étape 1 : Déployer l'infrastructure (Terraform)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Éditer `terraform.tfvars` :
```hcl
# OBLIGATOIRE : ID de clé SSH Scaleway (`scw iam ssh-key list`)
ssh_key_ids = ["xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"]

# OBLIGATOIRE : Mot de passe Proxmox (8+ chars)
service_password = "VotreMotDePasse123!"

# Type de serveur
server_type = "EM-I120E-NVME"  # 2 disques → 1 OSD/nœud (test)
# server_type = "EM-L220E-NVME"  # 4 disques → 3 OSDs/nœud (production)
```

```bash
terraform init
terraform apply
```

⏱️ **Attendre 10-15 minutes** que les serveurs passent en état `ready` :
```bash
scw baremetal server list zone=fr-par-2 -o wide
```

---

### Étape 2 : Configuration manuelle SSH (OBLIGATOIRE)

> ⚠️ **Scaleway désactive SSH root par défaut sur Proxmox.**
> Cette étape doit être effectuée manuellement sur chaque nœud.

#### 2.1 Obtenir les URLs Proxmox

```bash
terraform output proxmox_urls
```

#### 2.2 Pour CHAQUE nœud (pve1, pve2, pve3)

1. **Ouvrir l'interface web Proxmox** : `https://<IP>:8006`

2. **Se connecter** :
   - User: `root`
   - Password: la valeur de `service_password`
   - Realm: `Linux PAM`

3. **Ouvrir le Shell** : Cliquer sur le nœud → **Shell**

4. **Exécuter ces commandes** :

```bash
# Activer SSH avec authentification par clé
sed -i 's/#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Ajouter VOTRE clé SSH publique (depuis votre poste local)
# ⚠️ REMPLACEZ par votre propre clé !
cat >> ~/.ssh/authorized_keys << 'EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDXaSVcJLERTOT4WHfDqRX/x6cCGRjnbDbeIrq4Lnrm7KJTh6vvuAzZ1c3mRbArywxgOnY9ziuPKILZqto+L8Dk/Zqdqn4zOBZWQ0MuPBk0e4kuKctVkMNa+2HpJ41Zs+MeTc8CM40qP5ODehVzIfz8+E5FhJZ1XOU7mncBpepd3+/leLYarTaAU= fab@MacBook-Pro-de-Fabien-2.local
EOF

# Vérifier que la clé est bien ajoutée
cat ~/.ssh/authorized_keys
```

> 💡 **Astuce** : Pour obtenir votre clé publique SSH :
> ```bash
> cat ~/.ssh/id_rsa.pub
> # ou
> cat ~/.ssh/id_ed25519.pub
> ```

#### 2.3 Tester la connexion SSH

```bash
# Depuis votre poste local
ssh root@<IP_PVE1>
ssh root@<IP_PVE2>
ssh root@<IP_PVE3>
```

---

### Étape 3 : Déploiement Ansible

```bash
cd ../ansible

# Installer les collections requises
ansible-galaxy install -r requirements.yml

# Vérifier la connectivité
ansible all -m ping
```

**Si le ping fonctionne** :
```bash
# Déploiement complet
ansible-playbook playbooks/site.yml
```

#### Déploiement étape par étape (recommandé pour debug)

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
│   ├── main.tf                    # Ressources Scaleway
│   ├── variables.tf               # Variables (server_type, etc.)
│   ├── outputs.tf                 # IPs, URLs, config Ceph
│   └── terraform.tfvars.example
│
└── ansible/
    ├── ansible.cfg
    ├── requirements.yml           # Collections requises
    ├── inventory/                 # Généré par Terraform
    │   ├── hosts.yml
    │   └── group_vars/proxmox.yml
    └── playbooks/
        ├── 00-enable-ssh.yml      # Vérification SSH
        ├── 01-bootstrap.yml       # Réseau + /etc/hosts
        ├── 02-cluster.yml         # Cluster Proxmox + NTP
        ├── 03-ceph.yml            # Ceph complet
        └── site.yml               # Tout-en-un
```

---

## Types de serveurs supportés

| Type | CPU | RAM | Disques | OSDs/nœud | Total OSDs | Usage |
|------|-----|-----|---------|-----------|------------|-------|
| **EM-I120E-NVME** | 8C/16T | 64GB | 2× 960GB NVMe | 1 | 3 | Test/Dev |
| **EM-L220E-NVME** | 8C | 64GB | 4× 1.92TB NVMe | 3 | 9 | Production |

> ⚠️ Avec 3 OSDs (1/nœud), la perte d'un nœud = perte de disponibilité Ceph.

---

## Commandes utiles

### Terraform

```bash
terraform output proxmox_urls          # URLs interfaces web
terraform output server_public_ips     # IPs pour SSH
terraform output ceph_configuration    # Config Ceph détectée
```

### Ansible

```bash
ansible all -m ping                                    # Test connectivité
ansible proxmox -m shell -a "pvecm status"            # Status cluster
ansible proxmox -m shell -a "ceph -s"                 # Status Ceph
```

### Proxmox (sur un nœud)

```bash
pvecm status              # Status cluster
pvecm nodes               # Liste des nœuds
ceph -s                   # Status Ceph
ceph osd tree             # Arbre OSDs
ceph health detail        # Détails santé
```

---

## Troubleshooting

### SSH "Permission denied"

```bash
# Vérifier que la clé SSH est présente sur le nœud
ssh -v root@<IP>

# Si la clé n'est pas présente, l'ajouter via Proxmox Shell (Étape 2)
```

### Ping échoue sur réseau privé

```bash
# Vérifier que les bridges sont configurés
ansible proxmox -m shell -a "ip addr show vmbr1"
ansible proxmox -m shell -a "ip addr show vmbr2"

# Relancer le bootstrap si nécessaire
ansible-playbook playbooks/01-bootstrap.yml
```

### Cluster join échoue

```bash
# Vérifier que /etc/hosts est correct sur tous les nœuds
ansible proxmox -m shell -a "cat /etc/hosts"

# Vérifier la connectivité réseau privé
ansible proxmox -m shell -a "ping -c 3 proxmox-hci-pve1"
```

### Ceph health warning

```bash
# Voir les détails
ceph health detail

# Vérifier les OSDs
ceph osd tree
ceph osd status
```

---

## Coûts estimés (Scaleway)

- 3× EM-I120E-NVME : ~€150/mois × 3 = **~€450/mois**
- 3× EM-L220E-NVME : ~€450/mois × 3 = **~€1,350/mois**
- Public Gateway VPC-GW-S : ~€10/mois

---

## Public Gateway & SSH Bastion

Le déploiement inclut un **Public Gateway** optionnel qui fournit :

1. **NAT Masquerade** : Les VMs sur le Private Network peuvent accéder à Internet
2. **SSH Bastion** : Accès SSH aux VMs sans IP publique

### Configuration

```hcl
# Dans terraform.tfvars
enable_public_gateway = true
enable_ssh_bastion    = true
bastion_port          = 61000  # Port SSH du bastion
```

### Accès SSH via Bastion

```bash
# Accès à une VM sur le Private Network
ssh -J bastion@<GATEWAY_IP>:61000 user@<VM_PRIVATE_IP>

# Accès direct à un nœud Proxmox via bastion
ssh -J bastion@<GATEWAY_IP>:61000 root@172.16.28.10
```

### DHCP pour les VMs

Le gateway configure automatiquement un pool DHCP :
- Plage : `172.16.28.100` → `172.16.28.250`
- DNS : 1.1.1.1, 8.8.8.8
- Route par défaut via le gateway

---

## Cloud-init (Limitations actuelles)

### État actuel

Scaleway supporte maintenant **cloud-init** sur Elastic Metal pour automatiser la configuration au premier boot. Cependant :

1. ✅ **Fonctionnel via Console/API Scaleway** : cloud-init est disponible
2. ❌ **Non disponible via Terraform** : Le provider `scaleway_baremetal_server` ne supporte pas encore l'attribut `user_data`

### Impact sur le déploiement

Pour le moment, la configuration SSH est gérée par :
- `ssh_key_ids` : Injection des clés SSH (fonctionnel)
- Le playbook `01-bootstrap.yml` : Configuration SSH additionnelle

### Alternative avec l'API Scaleway

Si tu souhaites utiliser cloud-init directement, tu peux :

1. Créer les serveurs via Terraform (sans cloud-init)
2. Utiliser l'API Scaleway pour ajouter user_data avant le premier boot :

```bash
curl -X PATCH \
  -H "X-Auth-Token: $SCW_SECRET_KEY" \
  -H "Content-Type: application/json" \
  "https://api.scaleway.com/baremetal/v3/zones/fr-par-2/servers/<SERVER_ID>" \
  -d '{
    "user_data": "#cloud-config\nssh_pwauth: false\nruncmd:\n  - sed -i \"s/#PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config\n  - systemctl restart sshd"
  }'
```

---

## Liens utiles

- [Proxmox VE Documentation](https://pve.proxmox.com/pve-docs/)
- [Proxmox Ceph Documentation](https://pve.proxmox.com/wiki/Deploy_Hyper-Converged_Ceph_Cluster)
- [Scaleway Elastic Metal](https://www.scaleway.com/en/elastic-metal/)
- [Scaleway Public Gateway](https://www.scaleway.com/en/docs/network/public-gateways/)
- [Scaleway Cloud-init on EM](https://www.scaleway.com/en/docs/elastic-metal/concepts/#cloud-init)
