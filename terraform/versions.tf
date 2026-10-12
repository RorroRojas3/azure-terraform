terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # Partial configuration; each environment supplies environments/<env>/backend.hcl at init.
  backend "azurerm" {}
}
