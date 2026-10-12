terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.16"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # Partial configuration; backend.hcl points at the admin-only tfstate-bootstrap container.
  backend "azurerm" {}
}
