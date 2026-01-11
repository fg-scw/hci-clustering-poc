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
  # Authentication via environment variables (recommended):
  #   SCW_ACCESS_KEY
  #   SCW_SECRET_KEY
  #   SCW_DEFAULT_PROJECT_ID
  #
  # Or via variables:
  # access_key  = var.scw_access_key
  # secret_key  = var.scw_secret_key
  # project_id  = var.scw_project_id

  region = var.region
  zone   = var.zone
}
