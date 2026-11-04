# Operations

Runbooks for running the environments after they exist. For first-time setup and rebuilds, see [Manual deployment](manual-deployment.md). For how the pipeline works, see [Pipeline](pipeline.md).

- [Day-to-day](#day-to-day)
- [State care](#state-care)
- [Add an environment](#add-an-environment)
- [Add a role to `assignable_role_names`](#add-a-role-to-assignable_role_names)
- [Troubleshooting](#troubleshooting)

## Day-to-day

### Change your IP

Edit `allowed_ip_addresses` in `terraform/environments/<env>/terraform.tfvars`, open a PR (the plan shows the firewall changes) and merge. The SQL, Key Vault, Storage and Cosmos DB firewalls follow.

SQL firewall rules are keyed by address, for example `azurerm_mssql_firewall_rule.allowed["203-0-113-10_32"]` named `allow-203-0-113-10_32`, so changing an address replaces only its own rule.

### Add blob containers or Cosmos DB containers

Edit `storage_containers` or `cosmos_containers` in the environment's `terraform.tfvars`:

```hcl
storage_containers = ["uploads"]

cosmos_containers = {
  orders = { partition_key_paths = ["/customerId"] }
}
```

Cosmos DB containers must be declared here, because Entra data-plane roles can't create databases or containers.

### Retry a failed SQL grant

Use **Rerun failed jobs** on the run. It re-runs `grant` without re-applying. If the grant was skipped entirely, see [The SQL grant didn't run after a failed apply](#the-sql-grant-didnt-run-after-a-failed-apply).

### Approve a promotion

A merge applies dev, then each later environment waits for its Environment's approvers in turn. Review the plan, approve the newest run, and reject runs you don't want promoted. The details, including what a timeout does, are in [Pipeline](pipeline.md#promotion-and-approvals).

### Run Terraform locally

You need two kinds of access:

- **State:** `Storage Blob Data Contributor` on the `tfstate-<env>` container, which listing your object ID in `state_contributor_object_ids` (bootstrap tfvars) grants.
- **Resources:** a plan refreshes every resource, including POST list actions that Reader lacks, so you need Contributor or Owner on `andes-softsol-rg-<env>`. An apply or destroy also changes role assignments, which needs Owner or Contributor plus Role Based Access Control Administrator.

Then run, with the environment you want in place of `<env>`:

```powershell
az login
terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
terraform -chdir=terraform plan "-var-file=environments/<env>/terraform.tfvars"
```

Add `-reconfigure` whenever you switch environments (it's needed once `terraform/.terraform` exists). Never use `-migrate-state`: it would copy one environment's state into another.

Prefer applying through the pipeline. A local apply bypasses approvals; see [Manual deployment, Part 6b](manual-deployment.md#part-6b-deploy-by-hand-from-a-workstation).

## State care

Each environment's state is the blob `infra.tfstate` in the `tfstate-<env>` container of `andessoftsolsttfstate` (the bootstrap's is `bootstrap.tfstate` in `tfstate-bootstrap`). The account has versioning plus 30-day blob and container soft delete, and its resource group carries a `CanNotDelete` lock. Losing state doesn't delete infrastructure; it orphans it ([primer](terraform-primer.md#terraform-only-manages-whats-in-its-state)).

### Restore an earlier state version

Every write to a state blob creates a version, so you can roll back a bad apply's state or an accidental overwrite.

1. In the Azure portal, open the storage account `andessoftsolsttfstate`, then **Containers → `tfstate-<env>` → `infra.tfstate`**.
2. Select the **Versions** tab.
3. Select the version you want, then select **Make current version**.

This needs two things that `state_contributor_object_ids` alone doesn't give you:

- **Reader** (or higher) on the storage account, so the portal can open it. Subscription Owner covers it.
- **Data access with your Entra account.** Shared keys are disabled, so on the container page set **Authentication method** to **Microsoft Entra user account**. Your `Storage Blob Data Contributor` on `tfstate-<env>` then applies (only `-BootstrapAdminObjectIds` have it on `tfstate-bootstrap`).

See [Manage and restore soft-deleted blobs](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-manage). A restored state describes an older reality, so run a plan afterwards and read it before applying anything.

If the blob itself was deleted, restore it from the soft-delete retention window with **Undelete**, then promote the version you want.

### A stuck lease

A run that crashes mid-apply can leave the state blob leased, and the next run fails with `Error acquiring the state lock`. **Only do this when no run is active.** Breaking a lease under a live apply risks corrupting state.

Use the lock ID printed in the error:

```powershell
terraform -chdir=terraform force-unlock <lock-id>
```

Or break the lease directly:

```powershell
az storage blob lease break --account-name andessoftsolsttfstate --container-name tfstate-<env> --blob-name infra.tfstate --auth-mode login
```

## Add an environment

These steps added qa through prod; follow them for any further environment. No Terraform code changes are needed.

Resource names are fixed (`andes-softsol-<type>-<env>`, built from `local.names` in `terraform/locals.tf`), so the same environment always gets the same names. The cost is that web app, Key Vault, Storage, SQL server and Cosmos DB names are unique across all of Azure, and someone else (or a soft-deleted resource) may already hold one. See [naming rules](architecture.md#naming-rules) for the length limits.

1. **Check the global names are free.** Run each check for the new `<env>`; every name must come back available:

   ```powershell
   # Web apps: repeat with andes-softsol-ui-<env>
   az rest --method post --url "https://management.azure.com/subscriptions/<subscription-id>/providers/Microsoft.Web/checkNameAvailability?api-version=2023-12-01" --body '{\"name\":\"andes-softsol-api-<env>\",\"type\":\"Microsoft.Web/sites\"}'

   # Key Vault (not `az keyvault check-name`, which checks Managed HSM names)
   az rest --method post --url "https://management.azure.com/subscriptions/<subscription-id>/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01" --body '{\"name\":\"andes-softsol-kv-<env>\",\"type\":\"Microsoft.KeyVault/vaults\"}'

   # SQL server
   az rest --method post --url "https://management.azure.com/subscriptions/<subscription-id>/providers/Microsoft.Sql/checkNameAvailability?api-version=2023-08-01" --body '{\"name\":\"andes-softsol-sql-<env>\",\"type\":\"Microsoft.Sql/servers\"}'

   # Storage account
   az storage account check-name --name andessoftsolst<env>

   # Cosmos DB (prints true when the name is taken)
   az cosmosdb check-name-exists --name andes-softsol-cosmos-<env>
   ```

   The inner quotes in the `--body` JSON are escaped (`\"`) on purpose: `az` is a `.cmd` file, and PowerShell passes unescaped inner quotes to it as nothing, so the request fails with `Unsupported Media Type`. In Git Bash, drop the backslashes.

   The checks return `nameAvailable` (or `available`); `false` includes a reason. A Key Vault name held by a soft-deleted vault also shows as taken: purge it, or pick another name.

   On 2026-11-02, with the `andes-softsol` prefix, every global name was available for all five environments, so no environment needs an exception.

2. **Add an entry** to `environments` in `bootstrap/terraform/terraform.tfvars`:

   | Field | Meaning |
   | --- | --- |
   | `sql_admin_member_object_ids` | People added to the SQL admin group (the apply identity is always a member) |
   | `state_contributor_object_ids` | People who may run Terraform locally against this environment's state |

   Environment names are 2-7 lowercase letters.

3. **Apply the bootstrap** (`terraform -chdir=bootstrap/terraform apply`) and read the new outputs.
4. **Copy** `terraform/environments/dev/` to `terraform/environments/<env>/`. In the copy:
   - Change `container_name` in `backend.hcl` to `tfstate-<env>`.
   - In `terraform.tfvars`, set `environment`, `sql_admin_group_name`, `sql_admin_group_object_id` and `aspnetcore_environment` (the copy says `Development`; the others use `QA`, `UAT`, `Staging` and `Production`).
   - Set `vnet_address_space` to a free `/24` from the [address plan](architecture.md#address-plan).
   - Choose sizing.
   - Set `developer_principal_ids = []`.
   - Set `allowed_ip_addresses`, for example `["203.0.113.10"]`. Use `[]` for no IPs.
5. **Create the empty state:** `terraform -chdir=terraform init "-backend-config=environments/<env>/backend.hcl"`, run by someone in `state_contributor_object_ids`. If `terraform/.terraform` already exists from another environment, add `-reconfigure` once. Never use `-migrate-state`, because it would copy one environment's state into another.
6. **Add the template call** in `pipelines/infra-pipeline.yml` with both connection IDs from `service_connection_ids` and `dependsOn: [apply_<previous env>]` ([Pipeline](pipeline.md#add-an-environments-template-call)).
7. **Add the approval before the first merge.** The bootstrap created the Environment without approvers, and Terraform never manages them. In Azure DevOps, open **Pipelines → Environments → `andes-softsol-<env>` → Approvals and checks**, add **Approvals**, and choose the approvers. Leave **Allow approvers to approve their own runs** on while one person both merges and approves. Do this before you merge the pull request from step 6: until the approval exists, the environment's apply runs automatically, prod included.

## Add a role to `assignable_role_names`

Every Azure RBAC role `terraform/` assigns must be in `assignable_role_names` in `bootstrap/terraform/variables.tf`, because an ABAC condition on each apply identity allows only those roles ([Architecture](architecture.md#the-abac-constrained-apply-identity)). When `terraform/` needs a new role:

1. Add the role name to `assignable_role_names`.
2. Re-apply the bootstrap: `terraform -chdir=bootstrap/terraform apply`. The condition on every environment's apply identity updates.
3. Merge the `terraform/` change that assigns the role.

If you merge in the other order, the apply fails with an authorization error on the role assignment.

If `terraform/` starts using a resource whose refresh calls a POST list action, add that action to `azurerm_role_definition.plan_reader` in `bootstrap/terraform/rbac.tf` and re-apply the bootstrap. Otherwise PR plans fail with `AuthorizationFailed`. The role currently lists `*/read` plus these four actions:

- `Microsoft.DocumentDB/databaseAccounts/listConnectionStrings/action`
- `Microsoft.DocumentDB/databaseAccounts/listKeys/action`
- `Microsoft.DocumentDB/databaseAccounts/readonlykeys/action`
- `Microsoft.Web/sites/config/list/action`

## Troubleshooting

### First plan fails with `Error loading state: failed to lock azure state`

The environment's empty state was never created. Run the one-time `terraform init` from [Manual deployment, Part 5](manual-deployment.md#part-5-create-each-environments-empty-state).

### Plan fails with `AuthorizationFailed` on a `.../action`

A resource type you started using calls a POST list action during refresh, which the plan identity's `*/read` doesn't cover. Add the action to `azurerm_role_definition.plan_reader` in `bootstrap/terraform/rbac.tf` and re-apply the bootstrap.

### Apply fails with a quota or ProvisioningDisabled error

For example, the App Service plan fails with `Operation cannot be completed without additional quota ... Current Limit (B1 VMs): 0`, or the SQL server fails with `ProvisioningDisabled: Provisioning is restricted in this region`. These are per-subscription, per-region restrictions, not code problems (the first apply in East US 2 hit both, so every environment runs in Central US). Either open a support request with issue type **Service and subscription limits** (for SQL, choose region access), or move the environment to a region with capacity.

- **Check SQL before choosing a region.** `Available` means open; `Visible` with a "Provisioning is restricted" reason means closed.

  ```powershell
  az rest --method get --url "https://management.azure.com/subscriptions/<subscription-id>/providers/Microsoft.Sql/locations/<region>/capabilities?api-version=2021-11-01" --query "{status:status, reason:reason}"
  ```

- **Check App Service quota.** The quickest test is to create and immediately delete a throwaway plan with the same SKU: `az appservice plan create ... --sku B1 -l <region>`, then `az appservice plan delete ... --yes`. The **Quotas** page in the portal also shows it.
- **Move an environment that isn't in use yet.** The resource group stays where it is: `location` in `bootstrap/terraform/terraform.tfvars` only sets the group's metadata location, and changing it replaces the group, which `prevent_destroy` blocks.
  1. Change `location` in the environment's `terraform.tfvars`.
  2. An administrator destroys what exists, locally: `terraform -chdir=terraform destroy "-var-file=environments/<env>/terraform.tfvars"`.
  3. Free the soft-deleted names. Purge the Key Vault with `az keyvault purge --name <vault> --location <old region>` (only possible while purge protection is off, as in every environment today). Permanently delete the Log Analytics workspace with `az monitor log-analytics workspace recover ...`, then `az monitor log-analytics workspace delete ... --force true --yes`.
  4. Re-apply. If you skip step 3, the apply fails because the soft-deleted resources still reserve those names.

### Apply fails because a diagnostic setting already exists

This happens when you rebuild an environment after deleting it outside Terraform. Deleting the resource group with `az group delete` leaves behind things Terraform's state no longer knows about. Dev hit this once, and the next apply failed on `azurerm_monitor_diagnostic_setting.key_vault` with `a resource with the ID ".../vaults/andes-softsol-kv-dev|to-log-analytics" already exists - to be managed via Terraform this resource needs to be imported into the State`. Azure keeps a deleted resource's diagnostic settings and reattaches them when a resource with the same ID is recreated.

Two more leftovers: the deleted Key Vault stays soft-deleted and reserves its name, and a soft-deleted Log Analytics workspace is recovered automatically when you recreate it with the same name, resource group and region.

- **Prefer `terraform destroy`.** An administrator with state access runs `terraform -chdir=terraform destroy "-var-file=environments/<env>/terraform.tfvars"`, which removes diagnostic settings properly. The resource group and role assignments owned by `bootstrap/terraform` aren't affected. For a full teardown see [Manual deployment, Part 9](manual-deployment.md#part-9-proper-teardown).
- **If the group is already gone, purge the vault before the next run.** This works only while purge protection is off, as in every environment today:

  ```powershell
  az keyvault purge --name andes-softsol-kv-<env> --location <region>
  ```

- **If the apply still fails on the diagnostic setting, import it instead of deleting it,** then re-run the pipeline. In Git Bash on Windows, prefix the command with `MSYS_NO_PATHCONV=1` so the path isn't rewritten.

  ```powershell
  terraform -chdir=terraform import "-var-file=environments/<env>/terraform.tfvars" azurerm_monitor_diagnostic_setting.key_vault "/subscriptions/<subscription-id>/resourceGroups/andes-softsol-rg-<env>/providers/Microsoft.KeyVault/vaults/andes-softsol-kv-<env>|to-log-analytics"
  ```

### The SQL grant didn't run after a failed apply

The `grant` job runs inside the apply stage, and the apply stage runs only when the plan has changes. If an apply fails after the database was created, fixing the cause usually leaves a no-change plan, so the next run skips the grant and the API identity has no database user. **Rerun failed jobs** doesn't help either, because the saved plan is stale.

A member of the SQL admin group runs the script locally, from a machine whose IP is in `allowed_ip_addresses`. It needs the `Az.Accounts`, `Az.Sql` and `SqlServer` PowerShell modules (`Install-PSResource -Name Az.Sql, SqlServer -Scope CurrentUser`).

Point Terraform at the broken environment first, or `sql_access` comes from whichever environment `terraform/.terraform` last used, and the script fixes the wrong one.

```powershell
az login
terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
Connect-AzAccount
$access = terraform -chdir=terraform output -json sql_access | ConvertFrom-Json
./scripts/Grant-SqlManagedIdentityAccess.ps1 `
    -ResourceGroupName $access.resource_group_name `
    -SqlServerName $access.server_name `
    -DatabaseName $access.database_name `
    -PrincipalName $access.principal_name `
    -PrincipalClientId $access.principal_client_id
```

Expected output: `Database user andes-softsol-id-api-<env> has roles: db_datareader, db_datawriter.` Check that the name ends in the environment you meant. The script is idempotent, so running it when the user already exists is harmless. Add `-AddRunnerFirewallRule` when your IP isn't in `allowed_ip_addresses`.

### Local SQL grant fails to log in

If the login fails right after the bootstrap added you to the environment's SQL admin group, then your access token probably predates the membership and doesn't carry it yet. Sign in again with `Connect-AzAccount`, then re-run the script. This hasn't been reproduced, so treat it as the first thing to try, not a confirmed cause. If it still fails, check that you're a member of `andes-softsol-sg-sql-admins-<env>` and that your IP is allowlisted.

### A run stops at "needs permission"

The pipeline isn't authorized for a service connection or Environment. Set `infra_pipeline_name` in the bootstrap tfvars and re-apply.

### A qa or prod run fails because a service connection is disabled

Azure DevOps may automatically disable connections unused for 100 days ([Connect to Azure](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)). Re-enable it in **Project settings → Service connections**, or run the pipeline regularly.

### Legacy Azure DevOps OIDC issuer

It retires on July 1, 2027. The bootstrap reads each federated credential's issuer and subject from the Azure DevOps service connection, so if you convert a connection to the Microsoft Entra issuer, re-applying the bootstrap updates the credential ([Manually set an ARM WIF service connection](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity)).

### Validate fails with no such host

`terraform validate` fails with `Error loading state: ... lookup <account>.blob.core.windows.net: no such host`, even after `init -backend=false`. The module's local `.terraform/` cache still points at a state account that no longer exists. That happens after a teardown, or after the prefix rename, when the cached `terraform/` backend still names the old `andessttfstate`.

Pick one fix. Don't delete `.terraform/`.

- **Validate offline in a throwaway data directory.** This never touches the cached backend:

  ```powershell
  $env:TF_DATA_DIR = "$env:TEMP\tfdata"
  terraform -chdir=terraform init -backend=false
  terraform -chdir=terraform validate
  $env:TF_DATA_DIR = $null
  ```

  Repeat with `-chdir=bootstrap/terraform` to validate the bootstrap module.

- **Reconnect to the real backend once it exists again.** Run `init -reconfigure` with the backend file for the module:

  ```powershell
  terraform -chdir=<module> init -reconfigure "-backend-config=<backend.hcl>"
  ```

  For `terraform/`, use `environments/<env>/backend.hcl`. For `bootstrap/terraform`, use `backend.hcl`.
