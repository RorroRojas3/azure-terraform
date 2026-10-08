provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true

  # bootstrap/New-AppEnvironment.ps1 registers providers; the pipeline identity has no subscription-scope rights.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Purging needs subscription-scope permissions the environment pipeline identity intentionally lacks.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }

    storage {
      # Storage firewalls deny Microsoft-hosted agents; everything here is managed through ARM instead.
      data_plane_available = false
    }
  }
}
