# Every provider signs in as the admin running `az login`: no personal access token or secret to store.

provider "azuredevops" {
  org_service_url = var.azure_devops_org_url
  use_cli         = true
}

provider "azurerm" {
  subscription_id     = var.subscription_id
  storage_use_azuread = true

  # Registered here, by an admin, so the environment pipelines never need subscription-scope rights.
  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.AlertsManagement",
    "Microsoft.Consumption",
    "Microsoft.DocumentDB",
    "Microsoft.Insights",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.OperationalInsights",
    "Microsoft.Sql",
    "Microsoft.Storage",
    "Microsoft.Web",
  ]

  features {}
}
