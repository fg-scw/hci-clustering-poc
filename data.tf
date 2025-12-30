################################################################################
# Data Sources
################################################################################

# =============================================================================
# SSH Keys
# =============================================================================

data "scaleway_iam_ssh_key" "keys" {
  for_each = toset(var.ssh_key_ids)
  ssh_key_id = each.value
}

# =============================================================================
# Elastic Metal Offers
# =============================================================================

data "scaleway_baremetal_offer" "selected" {
  zone = var.zone
  name = var.server_type
}

# =============================================================================
# Current Project
# =============================================================================

data "scaleway_account_project" "current" {
  project_id = var.project_id
}

# =============================================================================
# Outputs from Data Sources
# =============================================================================

output "server_offer_details" {
  description = "Details of selected server offer"
  value = {
    name             = data.scaleway_baremetal_offer.selected.name
    commercial_range = data.scaleway_baremetal_offer.selected.commercial_range
    cpu = {
      name       = data.scaleway_baremetal_offer.selected.cpu[0].name
      core_count = data.scaleway_baremetal_offer.selected.cpu[0].core_count
    }
    memory = {
      capacity = data.scaleway_baremetal_offer.selected.memory[0].capacity
    }
    disks = [for d in data.scaleway_baremetal_offer.selected.disk : {
      capacity = d.capacity
      type     = d.type
    }]
  }
}

output "os_info" {
  description = "Operating system configuration"
  value = {
    id   = var.os_id
    name = "Proxmox VE 8 | Debian 12 (Bookworm)"
  }
}

output "project_info" {
  description = "Current Scaleway project"
  value = {
    id   = data.scaleway_account_project.current.id
    name = data.scaleway_account_project.current.name
  }
}
