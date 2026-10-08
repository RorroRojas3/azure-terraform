# Created by bootstrap/New-TfStateBackend.ps1 (account) and bootstrap/New-AppEnvironment.ps1 (container).
# The pipeline adds OIDC settings through ARM_* environment variables; locally, Azure CLI credentials are used.
storage_account_name = "andessttfstate9ac756"
container_name       = "tfstate-dev"
key                  = "infra.tfstate"
use_azuread_auth     = true
