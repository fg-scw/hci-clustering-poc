################################################################################
# Terraform Configuration
# Provider versions and requirements
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.40.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
  }
}

################################################################################
# Provider Configuration
################################################################################

provider "scaleway" {
  region = var.region
  zone   = var.zone
}
