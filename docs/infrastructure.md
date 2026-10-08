# Andes Azure infrastructure

Terraform for the Andes application environments, run by an Azure DevOps pipeline. Each environment (dev today; qa, uat, staging and prod later) gets:

| Component | Resource | Notes |
| --- | --- | --- |
| .NET 10 API | Linux web app `andes-api-<env>-<sfx>` | User-assigned identity, outbound VNet integration, health check `/health` |
| Angular 22 UI | Linux web app `andes-ui-<env>-<sfx>` | Node 24 LTS, served by `pm2 serve --spa` |
| Hosting plan | `andes-asp-<env>` | B1 in dev, shared by both apps |
| API identity | `andes-id-api-<env>` | The only credential the API uses: no keys, passwords or connection-string secrets |
| Secrets | Key Vault `andes-kv-<env>-<sfx>` | RBAC mode, for third-party secrets you add |
| Relational data | Azure SQL `andes-sql-<env>-<sfx>` / `andes-sqldb-<env>` | Basic tier in dev; Entra-only authentication |
| Documents | Cosmos DB `andes-cosmos-<env>-<sfx>` | NoSQL API, serverless in dev, keys disabled |
| Files | Storage `andesst<env><sfx>` | Geo-redundant (GRS), shared keys disabled |
| Telemetry | Application Insights `andes-appi-<env>` + Log Analytics `andes-log-<env>` | One instance shared by the API and the UI |
| Network | `andes-vnet-<env>` / `andes-snet-api-<env>` | Outbound path from the API to the data services only |

`<sfx>` is a 4-character hash of the resource group ID that keeps globally unique names unique.

## Security model

Privileges are split between the people and identities involved:

| Who | Can do | Scope |
| --- | --- | --- |
| Azure administrator | Runs the bootstrap scripts: creates resource groups, identities, Entra groups and role assignments | Subscription Owner + Entra group creation |
| Pipeline identity `andes-id-ado-<env>` | Contributor, plus role assignments limited to an allowlist of data roles | `andes-rg-<env>` only |
| Pipeline identity `andes-id-ado-<env>` | Read/write Terraform state | Its own `tfstate-<env>` container only |
| API identity `andes-id-api-<env>` | Key Vault Secrets User, Storage Blob Data Contributor, Cosmos DB Data Contributor, SQL `db_datareader` + `db_datawriter` | That environment's resources |
| Developers (`developer_principal_ids`, dev only) | Key Vault Secrets Officer, Blob Data Contributor, Cosmos DB Data Contributor | Dev resources |
| SQL admins (`andes-sg-sql-admins-<env>`) | SQL Entra admin | That environment's SQL server |

- **The pipeline can't escalate.** Its *Role Based Access Control Administrator* assignment has an ABAC condition that only allows the roles in `-AssignableRoleNames`, so it can never grant Owner, Contributor or User Access Administrator.
- **The pipeline can't touch its own identity or other environments.** Its identity lives in `andes-rg-tfstate`, outside the resource group it manages, and has no rights at subscription scope.
- **No secrets exist.** The pipeline signs in with workload identity federation, and the API uses its managed identity everywhere. Storage shared keys, Cosmos DB keys and SQL authentication are all disabled.
- **Network:**
  - Key Vault, Storage, SQL and Cosmos DB keep public endpoints, but their firewalls deny everything except `allowed_ip_addresses` and the API's subnet.
  - `allowed_ip_addresses` is `sensitive` and kept out of the repo, so developers' public IPs aren't committed. See [Where the IP allowlist lives](#where-the-ip-allowlist-lives).
  - The web apps themselves are public.
  - The API uses VNet integration with service endpoints because Azure Storage IP rules can't admit an App Service in the same region.

## First-time setup (per subscription, then per environment)

Prerequisites:
- PowerShell 7.4+ with the `Az` modules.
- `Connect-AzAccount` as an account that is Owner on the subscription and can create Entra security groups.

1. **State backend (once per subscription):**

   ```powershell
   ./bootstrap/New-TfStateBackend.ps1 -SubscriptionId <subscription-id> -Location eastus2
   ```

   This creates `andes-rg-tfstate` (with a delete lock) and `andessttfstate<hash>`. The account is geo-redundant (RA-GRS), uses Entra auth only, and has versioning and 30-day soft delete.

2. **Environment, first pass:**

   ```powershell
   ./bootstrap/New-AppEnvironment.ps1 -SubscriptionId <subscription-id> -Environment dev -Location eastus2 `
       -SqlAdminMemberObjectIds <your-entra-object-id>
   ```

   Note `PipelineIdentityClientId`, `TenantId` and `SqlAdminGroupObjectId` from the output.

3. **Azure DevOps service connection.**
   1. In **Project settings → Service connections**, create **Azure Resource Manager**, **App registration or managed identity (manual)**, **Workload identity federation**, named `andes-sc-dev`.
   2. Use the tenant ID, subscription, and the pipeline identity's client ID.
   3. Don't grant access to all pipelines.
   4. Save it as a **draft** and copy its **Issuer** and **Subject identifier**.

4. **Environment, second pass** (adds the federated credential):

   ```powershell
   ./bootstrap/New-AppEnvironment.ps1 -SubscriptionId <subscription-id> -Environment dev -Location eastus2 `
       -SqlAdminMemberObjectIds <your-entra-object-id> `
       -AdoFederationIssuer '<issuer>' -AdoFederationSubject '<subject>'
   ```

   Then select **Verify and save** on the service connection.

5. **Wire up the repo:**
   - In `terraform/environments/dev/terraform.tfvars`, set `sql_admin_group_object_id` to `SqlAdminGroupObjectId`.
   - In `pipelines/infra-pipeline.yml`, set `serviceConnectionId` to the service connection's ID (shown in its URL/details).

6. **Azure DevOps pipeline and environment:**
   1. Create the pipeline from `pipelines/infra-pipeline.yml`.
   2. Create the Environment `andes-dev`. Add approvals and an exclusive lock for qa and prod.
   3. Authorize the pipeline to use the service connection and the environment.
   4. Create the variable group `andes-vg-dev` (see [Where the IP allowlist lives](#where-the-ip-allowlist-lives)):
      1. In **Pipelines → Library**, select **+ Variable group** and name it `andes-vg-dev`.
      2. Add the variable `allowedIpAddresses` with a JSON list as its value, for example `["203.0.113.10"]`. Select the lock icon to make it secret.
      3. Under **Pipeline permissions**, authorize the infra pipeline.
   5. With Azure Repos, add the pipeline as a **build validation** branch policy on `main`, so PRs get a plan.

   The group must exist and the pipeline must be authorized to use it before the first run, or the run fails at queue time.

7. **Run the pipeline.** PR runs plan only. Runs on `main` plan, apply when there are changes, then run `scripts/Grant-SqlManagedIdentityAccess.ps1`. That script creates the API identity's contained database user (`CREATE USER … WITH SID … TYPE = E`, so the SQL server doesn't need the Directory Readers role) and grants `db_datareader` and `db_datawriter`.

## Adding an environment (qa, uat, staging, prod)

1. Run `New-AppEnvironment.ps1 -Environment <env>` (both passes) and create `andes-sc-<env>`.
2. Copy `terraform/environments/dev/` to `terraform/environments/<env>/`. In the copy:
   - Change `container_name` in `backend.hcl` to `tfstate-<env>`.
   - In `terraform.tfvars`, set `environment` and `sql_admin_group_object_id`.
   - Use a new `vnet_address_space` (e.g. qa `10.11.0.0/24`, uat `10.12.0.0/24`, staging `10.13.0.0/24`, prod `10.14.0.0/24`).
   - Choose sizing.
   - Set `developer_principal_ids = []` outside dev.
   - Don't add `allowed_ip_addresses`; it comes from the variable group (next step).
3. Create the Azure DevOps Environment `andes-<env>` with approvals.
4. Create the variable group `andes-vg-<env>` with a secret `allowedIpAddresses` (a JSON list, `[]` for no IPs, e.g. prod) and authorize the pipeline to use it.
5. Uncomment or add the template call in `pipelines/infra-pipeline.yml` with `variableGroup: andes-vg-<env>` and `dependsOn: [sql_<previous env>]`.

No Terraform code changes are needed.

## Where the IP allowlist lives

The firewall allowlist (`allowed_ip_addresses`) is the one input that isn't in `terraform.tfvars`, so developers' personal public IPs stay out of the repo. It is a `sensitive` variable, so plan output and pipeline logs show `(sensitive value)` instead of addresses.

- **No default, on purpose.** A run that forgets it fails with "No value for required variable" instead of silently removing everyone's firewall access. Pass `[]` to allow no IPs.
- **Pipeline:** the plan job links the variable group `andes-vg-<env>` (the `variableGroup` template parameter in `pipelines/infra-pipeline.yml`) and maps its secret `allowedIpAddresses` to `TF_VAR_allowed_ip_addresses`. Secret variables aren't exposed to steps automatically, so `steps-terraform.yml` takes an `env` parameter for the mapping. Apply uses the saved plan and needs nothing.
- **Locally:** set `TF_VAR_allowed_ip_addresses` to the same JSON list before you plan or apply (see [Day-to-day](#day-to-day)). A local apply with a different list is reverted by the next pipeline run.
- **SQL firewall rules are indexed** (`azurerm_mssql_firewall_rule.allowed[0]`, named `allow-ip-0`, `allow-ip-1`, …) because sensitive values can't be `for_each` keys, and address-based keys would leak the IPs into resource addresses. On an environment deployed before this change, the first apply replaces the existing SQL firewall rule with `allow-ip-0`. Reordering the list renames rules the same way. Both are harmless.
- **`sensitive` only hides values from console output.** Terraform state and the saved plan file (the `tfplan-<env>` pipeline artifact) still contain them, so keep access to both restricted.

## Production checklist

- **App Service:** P0v3 or higher (or S1+ for deployment slots). Consider slots for zero-downtime deploys.
- **Key Vault:** `key_vault_purge_protection_enabled = true`, `key_vault_soft_delete_retention_days = 90` (these are the defaults).
- **SQL:** S0 or higher (or General Purpose); `sql_backup_storage_redundancy = "Geo"` (the default).
- **Cosmos DB:** decide between serverless and autoscale (`cosmos_serverless = false`, `cosmos_autoscale_max_throughput`). Switching capacity mode may require recreating the account, so decide before data lands.
- **Admin hardening:**
  - The administrator adds a `CanNotDelete` lock on `andes-rg-prod`. The pipeline identity can't manage locks.
  - Enable Microsoft Defender for Cloud plans for SQL, Storage, Key Vault and App Service.
- **Network:** consider private endpoints if public endpoints must be disabled entirely. Pipeline agents then need network line-of-sight (self-hosted agents or Managed DevOps Pools).
- **PR safety:** PR plans run with the same identity as applies, so protect `main` with required reviewers. A separate read-only service connection for PR plans is a future improvement.

## Day-to-day

- **Change your IP:** update the `allowedIpAddresses` secret in the `andes-vg-<env>` variable group (**Pipelines → Library**) and re-run the pipeline. No PR is needed. The SQL, Key Vault, Storage and Cosmos DB firewalls follow.
- **Add blob containers or Cosmos DB containers:** edit `storage_containers` or `cosmos_containers` in tfvars. Cosmos DB containers must be declared here, because Entra data-plane roles can't create databases or containers.
- **Run Terraform locally:** you need `Storage Blob Data Contributor` on the `tfstate-<env>` container (`New-AppEnvironment.ps1 -StateContributorObjectIds`). Set the IP allowlist first, using the same list as the pipeline's `allowedIpAddresses` so the next pipeline run doesn't revert the firewalls:

  ```powershell
  # One or more addresses, as a JSON list
  $env:TF_VAR_allowed_ip_addresses = '["203.0.113.10","203.0.113.11"]'

  # Or only your current public IP
  $env:TF_VAR_allowed_ip_addresses = "[`"$(Invoke-RestMethod https://api.ipify.org)`"]"
  ```

  The second form yields `["203.0.113.10"]` when the lookup returns `203.0.113.10`. Avoid piping a single address into `ConvertTo-Json`: it unwraps the array to a bare string, which Terraform rejects. Then run:

  ```powershell
  az login
  terraform -chdir=terraform init -backend-config=environments/dev/backend.hcl
  terraform -chdir=terraform plan -var-file=environments/dev/terraform.tfvars
  ```

  Prefer applying through the pipeline.
- **Let the API run EF Core migrations itself:** run `Grant-SqlManagedIdentityAccess.ps1` with `-Roles db_datareader, db_datawriter, db_ddladmin`. Running migrations from the application pipeline as a SQL admin group member is the tighter option.

## Application integration

The API web app gets these app settings (none are secrets):

| Setting | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | API identity client ID; `DefaultAzureCredential` / `ManagedIdentityCredential` uses it |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Shared Application Insights |
| `KeyVault__Uri` | Key Vault URI. Load secrets with the Azure Key Vault configuration provider |
| `Storage__BlobEndpoint` | Blob endpoint |
| `Cosmos__Endpoint`, `Cosmos__DatabaseName` | Cosmos DB endpoint and database |
| Connection string `Sql` (`SQLAzure`) | `Authentication=Active Directory Managed Identity;User Id=<client id>`, with no password |

- **Angular telemetry:** the Angular app needs the Application Insights connection string at build time. Read it with `terraform output -raw application_insights_connection_string`; Microsoft doesn't treat it as a secret.
- **Application deployment pipelines:**
  - Deploy with Entra-authenticated zip deploy (for example `AzureWebApp@1` with a workload identity federation service connection). FTP and basic-auth publishing are disabled.
  - Terraform ignores `WEBSITE_RUN_FROM_PACKAGE`, so zip deploys don't fight it.
  - That pipeline's identity needs **Website Contributor** on the two web apps.
