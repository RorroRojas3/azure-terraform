# Manual deployment

This is the DevOps runbook for taking the repo from nothing to running environments, for deploying by hand when you have to, and for rebuilding after a teardown. Commands are PowerShell. If you've never used Terraform, read the [Terraform primer](terraform-primer.md) first.

> **Why some arguments are quoted:** PowerShell splits a native-command argument that starts with `-` and contains a `.`, so `-backend-config=backend.hcl` reaches Terraform as `-backend-config=backend` and `.hcl`, and `init` fails with "Too many command line arguments". Quoting the whole argument, as in `"-backend-config=backend.hcl"`, passes it through intact. Keep the quotes on `-backend-config`, `-var-file`, `-out` and `-target` values that contain a dot; the Linux pipeline agents use bash and aren't affected.

## Why there is manual work at all

The pipeline builds each environment's resources (Part 6a), but it can't build itself:

- It can't sign in until its identities and service connections exist.
- It has nowhere to keep state until the state account and container exist.
- Its identities have no rights at subscription scope, so it can't create the resource group.

That is by design: a pipeline that could create its own identities could grant itself more access ([Architecture](architecture.md#identity-and-rbac-model)). So an administrator does Parts 1 to 5 by hand, once per subscription and then once per environment.

| Who | Creates |
| --- | --- |
| You, with `New-TfStateBackend.ps1` (Part 2) | `andes-softsol-rg-tfstate`, `andessoftsolsttfstate`, `tfstate-bootstrap` |
| You, with `bootstrap/terraform` (Part 3) | `andes-softsol-rg-<env>`, `tfstate-<env>`, plan and apply identities, service connections (the apply one with branch control and the exclusive lock), SQL admin group, `andes-softsol-<env>` Environment without approvers |
| You, in Azure DevOps (Part 4) | The approvers on each Environment (qa, uat, staging, prod). Terraform doesn't manage them, so a recreated Environment has none until you add them |
| You, in Azure DevOps (Part 3, [pipeline definition](#the-pipeline-definition)) | The `andes-infra` pipeline definition, once per Azure DevOps project. It persists and isn't rebuilt with an environment |
| The pipeline (Part 6a) | Everything else in the environment (web apps, plan, SQL, Cosmos DB, Storage, Key Vault, networking, monitoring), plus the API's SQL contained user |

## Part 1: Prerequisites and permissions

**Tools**

- PowerShell 7.4 or later with the `Az.Accounts`, `Az.Resources` and `Az.Storage` modules, Terraform (`>= 1.15.0, < 2.0.0`), and the Azure CLI.

  ```powershell
  Install-PSResource -Name Az.Accounts, Az.Resources, Az.Storage -Scope CurrentUser
  ```

- An Azure DevOps organization and project.
- A new Azure DevOps organization has no Microsoft-hosted parallel jobs by default. Request the free grant at <https://aka.ms/azpipelines-parallelism-request> before the first run.
- SQL and App Service capacity in the region you'll deploy to. The state account and each resource group's metadata stay in East US 2, but every environment's resources run in Central US (`location = "centralus"` in each `terraform.tfvars`), because East US 2 refused SQL servers and had no B1 quota on this subscription. On a different subscription, check both before the first deploy; see [Apply fails with a quota or ProvisioningDisabled error](operations.md#apply-fails-with-a-quota-or-provisioningdisabled-error).

**Permissions.** One administrator account needs all four:

| Permission | Needed for |
| --- | --- |
| Owner on the subscription | Role assignments, the custom role definition, resource provider registration |
| Microsoft Entra Groups Administrator or higher | Creating the SQL admin groups |
| Azure DevOps project administrator | Service connections, Environments, checks, the pipeline definition |
| GitHub repository admin | Installing the Azure Pipelines GitHub app when you create the pipeline, and branch protection on `main` (`gh auth login` first) |

**Two sign-ins.** You sign in with the same account twice, because Az PowerShell and the Azure CLI keep separate sessions. `Connect-AzAccount` doesn't sign in the Azure CLI, and `az login` doesn't sign in Az PowerShell.

```powershell
Connect-AzAccount            # New-TfStateBackend.ps1 uses this session
az login                     # Terraform and the object ID lookups use this session
```

Terraform's providers and backend authenticate through the Azure CLI session. The bootstrap's Azure DevOps provider uses it too (`use_cli = true`), so there is no personal access token.

## Part 2: State backend (once per subscription)

`New-TfStateBackend.ps1` creates the shared Terraform state backend. Run it once per subscription.

```powershell
$me = az ad signed-in-user show --query id -o tsv
./bootstrap/New-TfStateBackend.ps1 -SubscriptionId <subscription-id> -Location eastus2 `
    -BootstrapAdminObjectIds $me
```

It creates:

- Resource group `andes-softsol-rg-tfstate`, with a `CanNotDelete` lock named `protect-terraform-state`.
- Storage account `andessoftsolsttfstate`: geo-redundant (RA-GRS by default), Entra authentication only, versioning, and 30-day blob and container soft delete.
- Container `tfstate-bootstrap` for the bootstrap module's own state. Only `-BootstrapAdminObjectIds` get Storage Blob Data Contributor on it, because a pipeline identity that could edit that state could steer the next admin-run apply.

The script also registers the `Microsoft.Storage` and `Microsoft.ManagedIdentity` resource providers. It is safe to re-run: it converges existing resources to the settings above instead of recreating them. Add `-WhatIf` to preview.

Expected output:

```text
ResourceGroupName  : andes-softsol-rg-tfstate
StorageAccountName : andessoftsolsttfstate
Sku                : Standard_RAGRS
BootstrapContainer : tfstate-bootstrap
NextStep           : Set storage_account_name = "andessoftsolsttfstate" in every backend.hcl, then apply bootstrap/terraform.
```

Storage account names are global across Azure, so a second subscription needs a different `-NamePrefix`. A new prefix touches more than the script:

- `storage_account_name` in all six `backend.hcl` files (`bootstrap/terraform/` and each `terraform/environments/<env>/`).
- `name_prefix` in `bootstrap/terraform/terraform.tfvars`, and in each environment's `terraform.tfvars` (they rely on the `andes-softsol` default today).
- `sql_admin_group_name` in each environment's `terraform.tfvars`.
- `namePrefix` on each template call in `pipelines/infra-pipeline.yml` (the template defaults to `andes-softsol`).
- The global-name checks in [Operations](operations.md#add-an-environment), for every environment.

## Part 3: Bootstrap

`bootstrap/terraform` creates each environment's foundations from one `environments` entry. You run it, never the pipeline.

### Fill in the tfvars

Edit `bootstrap/terraform/terraform.tfvars`:

| Variable | Value |
| --- | --- |
| `subscription_id` | The subscription ID |
| `location` | `eastus2`: where each environment's resource-group metadata lives. The pipeline identities follow the state account's region instead |
| `azure_devops_org_url` | `https://dev.azure.com/<organization>` |
| `azure_devops_project` | The Azure DevOps project that runs `pipelines/infra-pipeline.yml` |
| `infra_pipeline_name` | `andes-infra`. The bootstrap looks the pipeline definition up by this name and authorizes it to use the service connections and Environments in the same apply (see [The pipeline definition](#the-pipeline-definition)) |
| `entra_group_owner_object_ids` | Owners of the SQL admin groups (required) |
| `environments` | One entry per environment (fields below) |

Each `environments` entry takes:

| Field | Meaning |
| --- | --- |
| `sql_admin_member_object_ids` | People added to the SQL admin group (the apply identity is always a member). Members become SQL admins on that environment |
| `state_contributor_object_ids` | People who may run Terraform locally against this environment's state |

Environment names are 2-7 lowercase letters. Check that `storage_account_name` in `bootstrap/terraform/backend.hcl` matches the account name the script printed.

### The pipeline definition

The bootstrap looks up the `andes-infra` pipeline by name (`infra_pipeline_name`, data source in `bootstrap/terraform/data.tf`), and the plan fails if it doesn't exist. You create the pipeline by hand once per Azure DevOps project. It normally exists already, so check under **Pipelines** and skip ahead if `andes-infra` is there.

If it's missing (a new Azure DevOps project, say), create it before the bootstrap plan:

1. Open **Pipelines → New pipeline → GitHub**. Approve the Azure Pipelines GitHub app for the repository if asked (this needs GitHub repository admin).
2. Pick the repository, choose **Existing Azure Pipelines YAML file**, and select `/pipelines/infra-pipeline.yml`.
3. On the review page, open the **Run** dropdown and select **Save**. Don't select **Run**: the service connections don't exist yet, so the run would fail.
4. The pipeline is named after the repository. Rename it: open the pipeline, select **⋮ → Rename/move**, and enter `andes-infra`.

The bootstrap apply then authorizes the pipeline to use the service connections and Environments, so runs don't stop at "needs permission".

If Azure DevOps refuses to save because the service connections the YAML names don't exist yet, fall back to two applies: comment out `infra_pipeline_name` in `bootstrap/terraform/terraform.tfvars`, apply the bootstrap (next section), create and rename the pipeline, then uncomment `infra_pipeline_name` and apply again.

### Initialize, plan, apply

```powershell
az login
terraform -chdir=bootstrap/terraform init "-backend-config=backend.hcl"
terraform -chdir=bootstrap/terraform plan
terraform -chdir=bootstrap/terraform apply
```

Read the plan before you type `yes`. One apply registers the resource providers and creates, for each environment:

- Resource group `andes-softsol-rg-<env>` and state container `tfstate-<env>` (both `prevent_destroy`).
- Identities `andes-softsol-id-ado-<env>-plan` and `andes-softsol-id-ado-<env>-apply` in `andes-softsol-rg-tfstate`, with their role assignments. Plus, once for all environments, the custom role `andes-softsol-terraform-plan-reader`.
- Service connections `andes-softsol-sc-<env>-plan` and `andes-softsol-sc-<env>-apply`, and their federated credentials. The credential's subject embeds the connection's GUID, so Terraform reads the issuer and subject from the connection and creates the credential in the same apply.
- The apply connection's checks: branch control and the exclusive lock. Approvals aren't created here; you add them in Part 4.
- Entra group `andes-softsol-sg-sql-admins-<env>` (the apply identity plus `sql_admin_member_object_ids`).
- The Azure DevOps Environment `andes-softsol-<env>`, with no approvers.

### Copy the outputs into the repo

```powershell
terraform -chdir=bootstrap/terraform output
```

Make these changes on a branch; it becomes the pull request in Part 6a. The group object IDs and connection IDs are new on every fresh build, so always copy them from the current outputs, never from an earlier build.

| Output | Copy it to |
| --- | --- |
| `service_connection_ids` | `planServiceConnectionId` and `applyServiceConnectionId` for each environment's template call in `pipelines/infra-pipeline.yml` |
| `sql_admin_group_object_ids` | `sql_admin_group_object_id` in each `terraform/environments/<env>/terraform.tfvars` |

Then check the rest of each environment's `terraform.tfvars`. None of these values is a secret.

| Variable | Set it to |
| --- | --- |
| `subscription_id` | The subscription you're deploying to. Every file has it on line 1; on a new subscription it still names the old one |
| `location` | A region with SQL and App Service capacity (`centralus` today; see Part 1) |
| `allowed_ip_addresses` | The public IPs that need firewall access, for example `["203.0.113.10"]`. Use `[]` for none |
| `developer_principal_ids` | Object IDs that exist in your tenant (dev only; `[]` elsewhere). An ID from another tenant fails the apply |

## Part 4: Add approvers (qa, uat, staging, prod)

Do this **before the first merge**. The bootstrap creates each Environment with no approvers, and an Environment with none applies automatically. A merge before you add them applies to qa, uat, staging and prod unapproved. Skip dev, which applies automatically by design.

For each of qa, uat, staging and prod:

1. In Azure DevOps, open **Pipelines → Environments → `andes-softsol-<env>` → Approvals and checks**.
2. Select **+**, then **Approvals**, then **Next**.
3. Choose the approvers.
4. Leave **Allow approvers to approve their own runs** on while one person both merges and approves.
5. Leave the timeout at the 30-day default, or set your own.
6. Select **Create**.

Approvers are never set in Terraform. See [Accepted trade-offs](architecture.md#approvals-live-on-azure-devops-environments-never-in-terraform).

## Part 5: Create each environment's empty state

The read-only plan identity can't create the initial state, because the azurerm backend takes a lease to do it. Someone listed in that environment's `state_contributor_object_ids` runs this once per environment:

```powershell
az login
terraform -chdir=terraform init "-backend-config=environments/<env>/backend.hcl"
```

If `terraform/.terraform` already exists from another environment, add `-reconfigure`:

```powershell
terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
```

Never use `-migrate-state` here, because it would copy one environment's state into another.

If you skip this, the first pipeline plan fails with `Error loading state: failed to lock azure state`.

If `init` fails with a 403 (`AuthorizationPermissionMismatch`) right after the bootstrap apply, the role assignment that lets you write state hasn't taken effect yet. Azure role assignments can take a few minutes to apply; wait, then run `init` again.

## Part 6a: Deploy through the pipeline

This is the normal route, and the step that creates the environment's resources.

0. **Once per repository, lock down GitHub and fork builds.**
   - Protect `main` with the command in [Pipeline, Branch protection](pipeline.md#branch-protection-on-main). It requires a PR and a passing `andes-infra` check, admins included. Apply it once the check can pass, that is after Parts 3 to 5; during a rebuild, see [When the pipeline can't run](pipeline.md#when-the-pipeline-cant-run).
   - Confirm that building PRs from forks is off in Azure DevOps (**Project settings → Pipelines → Settings**). The repo is public, and a fork PR would run its own YAML ([Fork safety](pipeline.md#fork-safety)).
1. **Open a pull request** from the branch with the Part 3 changes into `main`. The `pr:` trigger in `infra-pipeline.yml` starts the run. It plans only, on the read-only connection, so nothing is created or changed.
2. **Merge to `main` once the `andes-infra` check passes.** The run plans again, then applies where there are changes (after approval, for every environment except dev), then runs `scripts/Grant-SqlManagedIdentityAccess.ps1`. That script creates the API identity's contained database user (`CREATE USER ... WITH SID ... TYPE = E`, so the SQL server doesn't need the Directory Readers role) and grants `db_datareader` and `db_datawriter`.
3. **Approve each promotion** as it reaches you. See [Pipeline](pipeline.md#promotion-and-approvals).

Then deploy the application from its own pipelines ([Application integration](application-integration.md#application-deployment-pipelines)). This repo holds infrastructure only.

## Part 6b: Deploy by hand from a workstation

This is break-glass. **A local apply bypasses approvals, the apply identity's ABAC limit and PR review.** Use it only when the pipeline can't run, and prefer to fix the pipeline.

**Who can.** You need Owner (or Contributor plus Role Based Access Control Administrator) on `andes-softsol-rg-<env>`, and your object ID in that environment's `state_contributor_object_ids`.

**1. Point Terraform at the environment's state.**

```powershell
az login
terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
```

**2. Plan to a file and read it.**

```powershell
terraform -chdir=terraform plan "-var-file=environments/<env>/terraform.tfvars" "-out=<env>.tfplan"
```

**3. Apply that exact plan.**

```powershell
terraform -chdir=terraform apply <env>.tfplan
```

**4. Delete the plan file.** `*.tfplan` is gitignored but holds variable values in cleartext. The file sits in `terraform/` because of `-chdir`.

```powershell
Remove-Item terraform/<env>.tfplan
```

**5. Grant the API identity SQL access.** The pipeline does this after every apply; by hand, you do it. You must be a member of the environment's SQL admin group (`sql_admin_member_object_ids`) and have these modules: `Az.Accounts`, `Az.Sql` and `SqlServer`.

```powershell
Install-PSResource -Name Az.Sql, SqlServer -Scope CurrentUser
Connect-AzAccount
$access = terraform -chdir=terraform output -json sql_access | ConvertFrom-Json
./scripts/Grant-SqlManagedIdentityAccess.ps1 `
    -ResourceGroupName $access.resource_group_name `
    -SqlServerName $access.server_name `
    -DatabaseName $access.database_name `
    -PrincipalName $access.principal_name `
    -PrincipalClientId $access.principal_client_id
```

Expected output: `Database user andes-softsol-id-api-<env> has roles: db_datareader, db_datawriter.` The script is idempotent, so running it when the user already exists is harmless.

If your public IP isn't in `allowed_ip_addresses`, add `-AddRunnerFirewallRule`. The script then opens the SQL firewall to your IP for the run and always removes the rule afterwards. Creating that rule needs SQL write rights on the resource group, which Owner and Contributor have.

If the login fails right after the bootstrap added you to the SQL admin group, see [Local SQL grant fails to log in](operations.md#local-sql-grant-fails-to-log-in).

## Part 7: Verify

**1. List the resources.**

```powershell
az resource list --resource-group andes-softsol-rg-<env> --query "[].{name:name, type:type}" -o table
```

You should see the web apps `andes-softsol-api-<env>` and `andes-softsol-ui-<env>`, the plan `andes-softsol-asp-<env>`, the identity `andes-softsol-id-api-<env>`, Key Vault `andes-softsol-kv-<env>`, SQL server `andes-softsol-sql-<env>` and database `andes-softsol-sqldb-<env>`, Cosmos DB `andes-softsol-cosmos-<env>`, storage `andessoftsolst<env>`, Application Insights `andes-softsol-appi-<env>`, Log Analytics `andes-softsol-log-<env>` and the VNet `andes-softsol-vnet-<env>`. Azure can add companion resources of its own, so the list may be longer.

**2. Read the outputs.** Initialize against the environment first (Part 5).

```powershell
terraform -chdir=terraform output
```

**3. Check the pipeline run.** It should be green, including the **Grant API identity database access** job in the apply stage. The `/health` endpoint on `api_url` answers once the API is deployed; infrastructure alone has no application to answer it.

## Part 8: Rebuild after a teardown or lost bootstrap state

Use this when the resource groups, including `andes-softsol-rg-tfstate`, were deleted with `az group delete`. That deletes the state account, so Terraform loses the record of everything the bootstrap created. [Part 9](#part-9-proper-teardown) explains the safe order.

Objects outside any resource group survive and become orphans Terraform no longer tracks: the service connections, the Azure DevOps Environments (with their approvers), the Entra SQL admin groups and the custom role `andes-softsol-terraform-plan-reader`. Key Vaults become soft-deleted and keep their names.

You have two options. Try A first. It keeps those surviving objects and their IDs.

### Option A: Recover the state account (best effort, within 14 days of deletion)

If you recover the state account, the bootstrap state comes back, Terraform sees which objects are missing, and recreates only those. The service connections, Environments (with their approvers) and Entra groups stay, so the IDs already in the repo stay valid and you add no approvers.

Microsoft's conditions ([Recover a deleted storage account](https://learn.microsoft.com/azure/storage/common/storage-account-recover)): the account was deleted in the past 14 days, no new account with the same name was created since, the resource group exists, and you hold a role with `Microsoft.Storage/storageAccounts/write`. Recovery isn't guaranteed.

**Do not run `New-TfStateBackend.ps1` before you restore.** It would create a new account with that name and rule recovery out.

1. **Recreate the empty state resource group in the same region.**

   ```powershell
   az group create --name andes-softsol-rg-tfstate --location eastus2
   ```

2. **Restore the account in the portal.** Open **Storage accounts**, select **Restore**, pick the subscription, then select `andessoftsolsttfstate` and **Restore**. If the account isn't in the dropdown, it can't be recovered: go to Option B.
3. **Run the script** with the same arguments as in Part 2. It converges the account's settings, re-adds the `protect-terraform-state` lock and the bootstrap admin's role assignment on `tfstate-bootstrap`.

   ```powershell
   $me = az ad signed-in-user show --query id -o tsv
   ./bootstrap/New-TfStateBackend.ps1 -SubscriptionId <subscription-id> -Location eastus2 `
       -BootstrapAdminObjectIds $me
   ```

4. **Check the state came back.** The bootstrap container should hold `bootstrap.tfstate`, and each `tfstate-<env>` container should still exist.

   ```powershell
   az storage blob list --account-name andessoftsolsttfstate --container-name tfstate-bootstrap --auth-mode login -o table
   ```

5. **Plan and apply the bootstrap.**

   ```powershell
   az login
   terraform -chdir=bootstrap/terraform init -reconfigure "-backend-config=backend.hcl"
   terraform -chdir=bootstrap/terraform plan
   terraform -chdir=bootstrap/terraform apply
   ```

   Terraform finds the deleted resource groups, identities, federated credentials and role assignments missing and recreates them. It updates the surviving service connections to the new identities. Read the plan: expect creates for the missing objects and in-place updates for the survivors. Question any replacement of a service connection or an Entra group, because a replacement changes the IDs the repo depends on.

6. **Run the pipeline on `main` by hand.** Nothing changed in the repo, so no merge triggers a run. In Azure DevOps, open **Pipelines → `andes-infra` → Run pipeline**, keep the branch at `main` and select **Run**, then approve each promotion (Part 6a, step 3). The environment states in the restored account describe resources that no longer exist, so the run plans to recreate them. If the apply fails on `azurerm_monitor_diagnostic_setting.key_vault`, use [the import fix](operations.md#apply-fails-because-a-diagnostic-setting-already-exists). If a Key Vault name is held by a soft-deleted vault, purge it (Option B, list and purge commands).

### Option B: Rebuild from zero

Use this when the account isn't in the Restore list. The lost state no longer tracks the orphans, so first delete them. If you skip this, the next bootstrap apply fails: the Entra groups use `prevent_duplicate_names`, and Azure DevOps rejects duplicate service connection and Environment names.

**Deleting an Environment deletes its approvers.** You add them again in Part 4.

Run these in PowerShell. Two things matter:

- The `az devops` extension fails for this account (`TF400813: not authorized`), so the commands call Azure DevOps through `az rest`.
- `az` is a `.cmd` batch file, so an `&` inside a URL breaks the command in PowerShell. Pass query values with `--url-parameters` instead of putting them in the URL.

**Set up variables.**

```powershell
$prefix = 'andes-softsol'; $sub = '<subscription-id>'
$org = 'https://dev.azure.com/<organization>'; $project = '<project>'
$ado = '499b84ac-1321-427f-aa17-267ca6975798'   # Azure DevOps resource ID for az rest tokens
$projectId = az rest --method get --url "$org/_apis/projects/$project" --url-parameters api-version=7.1 --resource $ado --query id -o tsv
```

**List the orphans (read-only).** Each command prints names and IDs; note them down.

```powershell
# Service connections <prefix>-sc-<env>-plan and -apply
az rest --method get --url "$org/$project/_apis/serviceendpoint/endpoints" --url-parameters api-version=7.1 --resource $ado --query "value[?starts_with(name, '$prefix-sc-')].{name:name, id:id}" -o tsv

# Azure DevOps Environments <prefix>-<env>
az rest --method get --url "$org/$project/_apis/distributedtask/environments" --url-parameters api-version=7.1 --resource $ado --query "value[?starts_with(name, '$prefix-')].{name:name, id:id}" -o tsv

# Entra groups <prefix>-sg-sql-admins-<env>
az ad group list --query "[?starts_with(displayName, '$prefix-sg-sql-admins-')].{name:displayName, id:id}" -o tsv

# Custom role <prefix>-terraform-plan-reader
az role definition list --custom-role-only true --scope "/subscriptions/$sub" --query "[?roleName=='$prefix-terraform-plan-reader'].roleName" -o tsv

# Soft-deleted Key Vaults
az keyvault list-deleted --query "[].{name:name, location:properties.location}" -o table

# Soft-deleted Log Analytics workspaces
az monitor log-analytics workspace list-deleted-workspaces --query "[].name" -o tsv
```

**Delete the orphans.** Run each command once per ID the list returned, or loop over the IDs.

```powershell
# Service connection (one ID at a time)
az rest --method delete --url "$org/_apis/serviceendpoint/endpoints/<id>" --url-parameters projectIds=$projectId api-version=7.1 --resource $ado

# Azure DevOps Environment (deletes its approvers)
az rest --method delete --url "$org/$project/_apis/distributedtask/environments/<id>" --url-parameters api-version=7.1 --resource $ado

# Entra group
az ad group delete --group <object-id>

# Custom role
az role definition delete --name "$prefix-terraform-plan-reader" --scope "/subscriptions/$sub"

# Soft-deleted Key Vault (possible because purge protection is off today)
az keyvault purge --name <vault> --location <location>
```

A soft-deleted Log Analytics workspace needs no action: Azure recovers it automatically when you recreate a workspace with the same name, resource group and region.

**Then rebuild.** Follow Parts 2 to 6 in order, with these differences:

- Every ID is new. Copy the new `service_connection_ids` into `pipelines/infra-pipeline.yml` and the new `sql_admin_group_object_ids` into each environment's `terraform.tfvars`.
- Add the approvers again in Part 4, before the first merge.
- Create each empty state again in Part 5. The new account has none.
- While the identities don't exist yet, PR plans fail at sign-in. See [the note in Pipeline](pipeline.md#when-the-pipeline-cant-run).
- If the apply fails on `azurerm_monitor_diagnostic_setting.key_vault` with `already exists`, import the setting. Azure keeps a deleted resource's diagnostic settings and reattaches them when a resource with the same ID is recreated. See [the import fix](operations.md#apply-fails-because-a-diagnostic-setting-already-exists).

## Part 9: Proper teardown

Do this in order. Each step depends on the one before it.

**1. Destroy each environment's resources with Terraform.** This removes diagnostic settings cleanly. State access alone isn't enough, because destroy also deletes role assignments: run it per environment as someone in `state_contributor_object_ids` who also has Owner (or Contributor plus Role Based Access Control Administrator) on `andes-softsol-rg-<env>`:

```powershell
az login
terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
terraform -chdir=terraform destroy "-var-file=environments/<env>/terraform.tfvars"
```

Key Vaults and Log Analytics workspaces are soft-deleted rather than removed, and the Key Vault keeps its name until you purge it (`az keyvault purge`, Part 8, Option B).

**2. Delete the bootstrap-owned objects by hand.** The resource groups, state containers, identities and Entra groups have `prevent_destroy`, so `terraform destroy` in `bootstrap/terraform` refuses. Delete them with the commands in [Part 8, Option B](#option-b-rebuild-from-zero):

- The service connections and Azure DevOps Environments.
- The Entra SQL admin groups.
- Each environment's now-empty resource group: `az group delete --name andes-softsol-rg-<env> --yes`.
- The custom role `andes-softsol-terraform-plan-reader`, last. It's assigned at each environment's resource group, and Azure refuses to delete a role that still has assignments (`RoleDefinitionHasAssignments`).

**3. Delete the state group last,** after you remove its lock:

```powershell
az lock delete --name protect-terraform-state --resource-group andes-softsol-rg-tfstate
az group delete --name andes-softsol-rg-tfstate --yes
```

This deletes the state account, the containers and the pipeline identities with it.

**Why not `az group delete` on everything?** It removes the state account first or at the same time as the things the state tracked. Terraform then loses its record while the service connections, Environments, Entra groups, custom role and soft-deleted Key Vaults survive as orphans. Rebuilding then needs [Part 8](#part-8-rebuild-after-a-teardown-or-lost-bootstrap-state).
