# One-time adoption of what the retired New-AppEnvironment.ps1 already created for dev, so the first apply adopts
# it instead of failing with "already exists". Delete this file after that apply succeeds.

import {
  to = azurerm_resource_group.environment["dev"]
  id = "/subscriptions/290386d7-b5ac-433a-8c4c-db95cc6c36b4/resourceGroups/andes-rg-dev"
}

import {
  to = azurerm_storage_container.state["dev"]
  id = "/subscriptions/290386d7-b5ac-433a-8c4c-db95cc6c36b4/resourceGroups/andes-rg-tfstate/providers/Microsoft.Storage/storageAccounts/andessttfstateeb129c/blobServices/default/containers/tfstate-dev"
}

import {
  to = azuread_group.sql_admins["dev"]
  id = "/groups/b95fe8ce-9459-47c6-b248-2045eec6f2d7"
}

import {
  to = azurerm_role_assignment.state_contributor["dev-4ee09cb0-d7e7-4be4-b82f-2674695eb9df"]
  id = "/subscriptions/290386d7-b5ac-433a-8c4c-db95cc6c36b4/resourceGroups/andes-rg-tfstate/providers/Microsoft.Storage/storageAccounts/andessttfstateeb129c/blobServices/default/containers/tfstate-dev/providers/Microsoft.Authorization/roleAssignments/2b811bf0-a83a-417d-8a5e-9ef5970e9a9c"
}
