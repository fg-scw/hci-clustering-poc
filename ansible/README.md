# Ansible - Proxmox Ceph HCI Configuration

Configuration automatisée du cluster Proxmox + Ceph via Ansible.

## Prérequis

```bash
brew install ansible netaddr
pip install ansible jmespath netaddr
ansible-galaxy install -r requirements.yml
```

## Fichiers générés par Terraform

Après `terraform apply`, les fichiers suivants sont créés :

- `inventory/hosts.yml` - Inventaire avec IPs et config OSD
- `inventory/group_vars/proxmox.yml` - Variables du cluster

## Playbooks

| Playbook | Description |
|----------|-------------|
| `01-bootstrap.yml` | Configure réseau (VLAN, bridges), /etc/hosts |
| `02-cluster.yml` | Crée le cluster Proxmox, NTP, échange clés SSH |
| `03-ceph.yml` | Installe Ceph : MON, MGR, OSDs, pools |
| `site.yml` | Exécute tout dans l'ordre |

## Usage

```bash
# Vérifier la connectivité
ansible all -m ping

# Déploiement complet
ansible-playbook playbooks/site.yml

# Ou étape par étape
ansible-playbook playbooks/01-bootstrap.yml
ansible-playbook playbooks/02-cluster.yml
ansible-playbook playbooks/03-ceph.yml
```

## Notes

- Utilise les commandes natives `pvecm` et `pveceph` (pas de rôles externes)
- Compatible avec Ansible 2.15+
- Idempotent : peut être relancé sans risque
