# Created by bootstrap/New-TfStateBackend.ps1, which grants write access to -BootstrapAdminObjectIds only.
storage_account_name = "andessttfstate"
container_name       = "tfstate-bootstrap"
key                  = "bootstrap.tfstate"
use_azuread_auth     = true
