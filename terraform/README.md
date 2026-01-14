# Terraform - Scaleway Infrastructure

Déploiement de l'infrastructure Scaleway pour le cluster Proxmox Ceph HCI.

## Ressources créées

- **VPC** avec 2 Private Networks (public + cluster)
- **3× Elastic Metal** servers avec Proxmox VE 8
- **IPAM** - IPs réservées avant déploiement
- **Fichiers générés** pour Ansible

## Configuration

```bash
cp terraform.tfvars.example terraform.tfvars
vim terraform.tfvars
```

### Variables requises

| Variable | Description |
|----------|-------------|
| `ssh_key_ids` | Liste des IDs de clés SSH (`scw iam ssh-key list`) |
| `service_password` | Mot de passe Proxmox root (8+ chars) |

### Variables optionnelles

| Variable | Default | Description |
|----------|---------|-------------|
| `server_type` | `EM-L220E-NVME` | Type de serveur Elastic Metal |
| `node_count` | `3` | Nombre de nœuds (min 3) |
| `ceph_osd_disks` | Auto-détecté | Liste des disques OSD |

## Outputs importants

```bash
terraform output proxmox_urls          # URLs Proxmox
terraform output server_public_ips     # IPs pour SSH
terraform output ceph_configuration    # Config Ceph
terraform output -raw next_steps       # Prochaines étapes
```

## Fichiers générés

Après `terraform apply` :

```
../ansible/inventory/
├── hosts.yml              # Inventaire Ansible
└── group_vars/
    └── proxmox.yml        # Variables cluster
```
