# Andes Azure infrastructure

Terraform for the Andes application environments, run by an Azure DevOps pipeline. Each environment (dev today; qa, uat, staging and prod later) gets:

| Component | Resource | Notes |
| --- | --- | --- |
| .NET 10 API | Windows web app `andes-api-<env>-<sfx>` | .NET 10 on a 64-bit worker, user-assigned identity, outbound VNet integration, health check `/health` |
| Angular 22 UI | Windows web app `andes-ui-<env>-<sfx>` | Static build served by IIS (needs `web.config`, see [Application integration](#application-integration)) |
| Hosting plan | `andes-asp-<env>` | Windows, B1 in dev, shared by both apps |
| API identity | `andes-id-api-<env>` | The only credential the API uses: no keys, passwords or connection-string secrets |
| Secrets | Key Vault `andes-kv-<env>-<sfx>` | RBAC mode, for third-party secrets you add |
| Relational data | Azure SQL `andes-sql-<env>-<sfx>` / `andes-sqldb-<env>` | Basic tier in dev; Entra-only authentication |
| Documents | Cosmos DB `andes-cosmos-<env>-<sfx>` | NoSQL API, serverless in dev, keys disabled |
| Files | Storage `andesst<env><sfx>` | Geo-redundant (GRS), shared keys disabled |
| Telemetry | Application Insights `andes-appi-<env>` + Log Analytics `andes-log-<env>` | One instance shared by the API and the UI |
| Network | `andes-vnet-<env>` / `andes-snet-api-<env>` | Outbound path from the API to the data services only |

`<sfx>` is a 4-character hash of the resource group ID that keeps globally unique names unique.

The environments themselves (resource group, state container, pipeline identities, service connections, SQL admin group, variable group) are created by a second Terraform module, `bootstrap/terraform/`, which an administrator runs. The pipeline never runs it.

## Security model

Each environment has two pipeline identities, and the split is the main control. Pull request branches run their own pipeline YAML before anyone reviews it, so anyone who can push a branch can run code as whatever identity PR plans use. PR plans therefore get a read-only identity; only `main` runs get the write-capable one. Microsoft's guidance says the same: use a separate read-only identity for plan, and put approvals on the service connection, not the environment, because environment checks "can be bypassed in code" ([CAF: DevOps security](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview)).

| Who | Can do | Scope |
| --- | --- | --- |
| Azure administrator | Runs `New-TfStateBackend.ps1` and `bootstrap/terraform`: creates resource groups, identities, service connections, checks, Entra groups and role assignments | Subscription Owner, Entra Groups Administrator (or higher), Azure DevOps project administrator |
| Plan identity `andes-id-ado-<env>-plan` | Read everything Terraform refreshes (custom role `andes-terraform-plan-reader`: `*/read` plus four list actions the azurerm provider calls) and read state (Storage Blob Data Reader). Can't write resources or take the state lease | `andes-rg-<env>` and `tfstate-<env>` only |
| Apply identity `andes-id-ado-<env>-apply` | Contributor; Role Based Access Control Administrator limited by an ABAC condition (below); Storage Blob Data Contributor on state; member of the SQL admin group | `andes-rg-<env>` and `tfstate-<env>` only |
| State contributors (`state_contributor_object_ids`) | Read/write Terraform state, to run Terraform locally | That environment's `tfstate-<env>` container |
| API identity `andes-id-api-<env>` | Key Vault Secrets User, Storage Blob Data Contributor, Cosmos DB Data Contributor, SQL `db_datareader` + `db_datawriter` | That environment's resources |
| Developers (`developer_principal_ids`, dev only) | Key Vault Secrets Officer, Blob Data Contributor, Cosmos DB Data Contributor | Dev resources |
| SQL admins (`andes-sg-sql-admins-<env>`) | SQL Entra admin | That environment's SQL server |

Each identity is used through its own Azure DevOps service connection:

| Connection | Identity | Used by | Checks |
| --- | --- | --- | --- |
| `andes-sc-<env>-plan` | Plan | PR plans and `main` plans | None |
| `andes-sc-<env>-apply` | Apply | Apply and SQL grant (`main` only) | Branch control (`refs/heads/main` only), exclusive lock, and an approval when `approver_emails` is set |

- **The pipeline can't escalate.** The apply identity's *Role Based Access Control Administrator* assignment has an ABAC condition. It allows assigning or removing only the roles in `assignable_role_names` (`bootstrap/terraform/variables.tf`) and never for the environment's own plan or apply identity. So it can't grant Owner, Contributor or User Access Administrator, and it can't give itself data-plane access. See [Delegate Azure access management](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview).
- **PR branches can't run code with write access.** Plans use the read-only connection, which carries no checks, so PR runs aren't blocked. The checks sit on the apply connection, where pipeline YAML can't remove them ([Define approvals and checks](https://learn.microsoft.com/azure/devops/pipelines/process/approvals)). The Azure DevOps Environment `andes-<env>` has no checks and only records deployment history.
- **The pipeline can't touch its own identity or other environments.** Both identities live in `andes-rg-tfstate`, outside the resource group they manage, and have no rights at subscription scope.
- **No pipeline identity can tamper with admin state.** `bootstrap/terraform` keeps its state in the `tfstate-bootstrap` container, writable only by `-BootstrapAdminObjectIds`.
- **No secrets exist.** The pipeline signs in with workload identity federation, the admin signs in with `az login` (no personal access token), and the API uses its managed identity everywhere. Storage shared keys, Cosmos DB keys and SQL authentication are all disabled.
- **Network:**
  - Key Vault, Storage, SQL and Cosmos DB keep public endpoints, but their firewalls deny everything except `allowed_ip_addresses` and the API's subnet. Prod moves to private endpoints (see the [production checklist](#production-checklist)).
  - `allowed_ip_addresses` is `sensitive` and kept out of the repo, so developers' public IPs aren't committed. See [Where the IP allowlist lives](#where-the-ip-allowlist-lives).
  - The web apps themselves are public.
  - The API uses VNet integration with service endpoints because Azure Storage IP rules can't admit an App Service in the same region.

## How the pipeline runs

Per environment, `pipelines/infra-pipeline.yml` calls `pipelines/templates/terraform-environment.yml`:

1. **`plan_<env>`** (PRs and `main`): runs `fmt -check`, `validate` and `terraform plan -lock=false` on the plan connection. The plan identity can read state but not lease it; apply still locks and Terraform rejects a stale saved plan. The plan artifact `tfplan-<env>` is published only on `main`, because saved plans hold variable values in cleartext and PR plans are never applied.
2. **`apply_<env>`** (`main` only, and only when the plan has changes): uses the apply connection, so its checks run once for the whole stage. Two jobs:
   - `apply` is a deployment job targeting the `andes-<env>` Environment. It applies the saved plan.
   - `grant` creates the API identity's SQL contained user. It's a separate job so **Rerun failed jobs** retries a failed grant without re-applying a stale plan. One approval covers both jobs.

The template takes `environment`, `planServiceConnectionId`, `applyServiceConnectionId`, `dependsOn` and an optional `namePrefix`. Service connection, variable group and Environment names follow the `andes-*` convention.

## First-time setup (per subscription, then per environment)

1. **Prerequisites:**
   - PowerShell 7.4+ with the `Az.Accounts`, `Az.Resources` and `Az.Storage` modules, Terraform, and the Azure CLI.
   - An Azure DevOps organization and project.
   - An administrator account with all of these, used through one `az login`: Owner on the subscription (role assignments, the custom role definition, resource provider registration), Entra Groups Administrator or higher, and Azure DevOps project administrator rights (service connections, variable groups, environments, checks).
   - A new Azure DevOps organization has no Microsoft-hosted parallel jobs by default. Request the free grant at <https://aka.ms/azpipelines-parallelism-request> before the first run.

2. **State backend (once per subscription):**

   ```powershell
   Connect-AzAccount
   ./bootstrap/New-TfStateBackend.ps1 -SubscriptionId <subscription-id> -Location eastus2 `
       -BootstrapAdminObjectIds <your-entra-object-id>
   ```

   Find your object ID with `az ad signed-in-user show --query id -o tsv`.

   This creates `andes-rg-tfstate` (with a delete lock) and `andessttfstate<hash>`. The account is geo-redundant (RA-GRS), uses Entra auth only, and has versioning and 30-day soft delete. It also creates the `tfstate-bootstrap` container for the bootstrap module's own state. Only `-BootstrapAdminObjectIds` get Storage Blob Data Contributor on it. The script prints the account name.

3. **Fill in `bootstrap/terraform/terraform.tfvars`:**
   - `azure_devops_org_url` (`https://dev.azure.com/<organization>`) and `azure_devops_project`.
   - `entra_group_owner_object_ids`: owners of the SQL admin groups (required).
   - The `environments` map, one entry per environment (see [Adding an environment](#adding-an-environment-qa-uat-staging-prod) for the fields).

   Check that `storage_account_name` in `bootstrap/terraform/backend.hcl` matches the account name the script printed.

4. **Apply the bootstrap:**

   ```powershell
   az login
   terraform -chdir=bootstrap/terraform init -backend-config=backend.hcl
   terraform -chdir=bootstrap/terraform plan
   terraform -chdir=bootstrap/terraform apply
   ```

   One apply registers the resource providers and creates, for each environment:
   - Resource group `andes-rg-<env>` and state container `tfstate-<env>` (both `prevent_destroy`).
   - Identities `andes-id-ado-<env>-plan` and `andes-id-ado-<env>-apply` in `andes-rg-tfstate`, with their role assignments.
   - Service connections `andes-sc-<env>-plan` and `andes-sc-<env>-apply`, and their federated credentials. The credential's subject embeds the connection's GUID, so Terraform reads the issuer and subject from the connection and creates the credential in the same apply.
   - The apply connection's checks: branch control, exclusive lock and, when `approver_emails` is set, approval.
   - Entra group `andes-sg-sql-admins-<env>` (the apply identity plus `sql_admin_member_object_ids`).
   - Variable group `andes-vg-<env>` with a secret `allowedIpAddresses` set to `[]`, and the Azure DevOps Environment `andes-<env>`.

5. **Wire up the repo** from the outputs (`terraform -chdir=bootstrap/terraform output`):
   - `sql_admin_group_object_ids`: set `sql_admin_group_object_id` in `terraform/environments/dev/terraform.tfvars`.
   - `service_connection_ids`: set `planServiceConnectionId` and `applyServiceConnectionId` in `pipelines/infra-pipeline.yml`.

   Neither is a secret.

6. **Set your IPs.** In **Pipelines → Library**, open `andes-vg-dev` and replace the `allowedIpAddresses` value with a JSON list, for example `["203.0.113.10"]` (see [Where the IP allowlist lives](#where-the-ip-allowlist-lives)).

7. **Create the empty state (once per environment).** The read-only plan identity can't create the initial state, because the azurerm backend takes a lease to do it. Someone in `state_contributor_object_ids` runs:

   ```powershell
   az login
   terraform -chdir=terraform init -backend-config=environments/dev/backend.hcl
   ```

   If you skip this, the first pipeline plan fails with `Error loading state: failed to lock azure state`.

8. **Create the pipeline.** In Azure DevOps, select **Pipelines → New pipeline → GitHub**, choose this repo and the existing file `/pipelines/infra-pipeline.yml`, and name it (for example `andes-infra`). Then uncomment `infra_pipeline_name = "andes-infra"` in `bootstrap/terraform/terraform.tfvars` and re-apply the bootstrap. That authorizes the pipeline to use both service connections, the variable group and the Environment, so runs don't stop at "needs permission". A run started before this re-apply fails or waits for permission; re-run it afterwards.

9. **Run it.** A PR plans on the plan connection (the `pr:` trigger in `infra-pipeline.yml` starts it; no branch policy is needed). Merging to `main` plans again, then applies when there are changes (after approval, if configured), then runs `scripts/Grant-SqlManagedIdentityAccess.ps1`. That script creates the API identity's contained database user (`CREATE USER … WITH SID … TYPE = E`, so the SQL server doesn't need the Directory Readers role) and grants `db_datareader` and `db_datawriter`.

## Adding an environment (qa, uat, staging, prod)

1. **Add an entry** to `environments` in `bootstrap/terraform/terraform.tfvars`:

   | Field | Meaning |
   | --- | --- |
   | `sql_admin_member_object_ids` | People added to the SQL admin group (the apply identity is always a member) |
   | `state_contributor_object_ids` | People who may run Terraform locally against this environment's state |
   | `approver_emails` | Azure DevOps users who must approve each apply; empty means no approval (fine for dev) |
   | `requester_can_approve` | Let whoever triggered the run approve it; needed when one person both merges and approves |

   Environment names are 2-7 lowercase letters.
2. **Apply the bootstrap** (`terraform -chdir=bootstrap/terraform apply`) and read the new outputs.
3. **Copy** `terraform/environments/dev/` to `terraform/environments/<env>/`. In the copy:
   - Change `container_name` in `backend.hcl` to `tfstate-<env>`.
   - In `terraform.tfvars`, set `environment` and `sql_admin_group_object_id`.
   - Set `vnet_address_space` from the [address plan](#address-plan).
   - Choose sizing.
   - Set `developer_principal_ids = []`.
   - Don't add `allowed_ip_addresses`; it comes from the variable group (next step).
4. **Set the variable group.** In **Pipelines → Library**, edit `andes-vg-<env>` and set `allowedIpAddresses` (a JSON list; leave `[]` for no IPs, e.g. prod).
5. **Create the empty state:** `terraform -chdir=terraform init -backend-config=environments/<env>/backend.hcl`, run by someone in `state_contributor_object_ids`.
6. **Add the template call** in `pipelines/infra-pipeline.yml` with both connection IDs from `service_connection_ids` and `dependsOn: [apply_<previous env>]`:

   ```yaml
   - template: templates/terraform-environment.yml
     parameters:
       environment: qa
       planServiceConnectionId: <plan id>
       applyServiceConnectionId: <apply id>
       dependsOn: [apply_dev]
   ```

No Terraform code changes are needed.

### Address plan

Windows App Service workers on B1, S1 and P1 use `10.10.0.0/19` and `10.11.0.0/19` (other SKUs use other ranges) as infrastructure IPs, and a Windows app can't reach a destination in those ranges through VNet integration ([Windows worker IP overlap](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#windows-worker-ip-address-overlap)). That's harmless with service endpoints but fatal for the first private endpoint. The plan below is clear of every range Microsoft lists for any SKU. Microsoft says the ranges can change, so re-check the table when you change SKU.

| Environment | `vnet_address_space` |
| --- | --- |
| dev | `10.100.0.0/24` |
| qa | `10.101.0.0/24` |
| uat | `10.102.0.0/24` |
| staging | `10.103.0.0/24` |
| prod | `10.104.0.0/24` |

## Where the IP allowlist lives

The firewall allowlist (`allowed_ip_addresses`) is the one input that isn't in `terraform.tfvars`, so developers' personal public IPs stay out of the repo. It is a `sensitive` variable, so plan output and pipeline logs show `(sensitive value)` instead of addresses.

- **No default, on purpose.** A run that forgets it fails with "No value for required variable" instead of silently removing everyone's firewall access. Pass `[]` to allow no IPs.
- **Pipeline:** `bootstrap/terraform` creates the variable group `andes-vg-<env>` with a secret `allowedIpAddresses` set to `[]`. Terraform ignores later value edits, so admins set the real JSON list in **Pipelines → Library** and the IPs never pass through bootstrap state. The plan job links the group and maps the secret to `TF_VAR_allowed_ip_addresses`. Secret variables aren't exposed to steps automatically, so `steps-terraform.yml` takes an `env` parameter for the mapping. Apply uses the saved plan and needs nothing.
- **Locally:** set `TF_VAR_allowed_ip_addresses` to the same JSON list before you plan or apply (see [Day-to-day](#day-to-day)). A local apply with a different list is reverted by the next pipeline run.
- **It's one JSON secret.** Azure DevOps never masks substrings of a secret, so individual addresses can appear unmasked if a step echoes part of the list. That's accepted: developer IPs are low-sensitivity values kept out of the repo, not credentials, and Terraform marks the variable sensitive ([Set secret variables](https://learn.microsoft.com/azure/devops/pipelines/process/set-secret-variables)).
- **SQL firewall rules are indexed** (`azurerm_mssql_firewall_rule.allowed[0]`, named `allow-ip-0`, `allow-ip-1`, …) because sensitive values can't be `for_each` keys, and address-based keys would leak the IPs into resource addresses. On an environment deployed before this change, the first apply replaces the existing SQL firewall rule with `allow-ip-0`. Reordering the list renames rules the same way. Both are harmless.
- **`sensitive` only hides values from console output.** Terraform state and the saved plan still contain them, so keep access to both restricted. The plan artifact `tfplan-<env>` is published only on `main`, so PR runs don't leave the allowlist downloadable.

## Production checklist

- **App Service:** P0v3 or higher (or S1+ for deployment slots). Consider slots for zero-downtime deploys.
- **Key Vault:** `key_vault_purge_protection_enabled = true`, `key_vault_soft_delete_retention_days = 90` (these are the defaults).
- **SQL:** S0 or higher (or General Purpose); `sql_backup_storage_redundancy = "Geo"` (the default).
- **Cosmos DB:** decide between serverless and autoscale (`cosmos_serverless = false`, `cosmos_autoscale_max_throughput`). Switching capacity mode may require recreating the account, so decide before data lands.
- **Name suffix:** decide whether the 4-character `<sfx>` is long enough before prod. Changing it later recreates resources.
- **Approvals:** set `approver_emails` (and `requester_can_approve` if one person merges and approves) for qa and prod in `bootstrap/terraform/terraform.tfvars`, then re-apply the bootstrap.
- **Admin hardening:**
  - The administrator adds a `CanNotDelete` lock on `andes-rg-prod`. The pipeline identities can't manage locks.
  - Enable Microsoft Defender for Cloud plans for SQL, Storage, Key Vault and App Service.
- **Network:**
  - Prod uses private endpoints with public network access disabled for Key Vault, Storage, SQL and Cosmos DB. Microsoft's networking guide maps production workloads to private endpoints ([Private access to Azure PaaS services](https://learn.microsoft.com/azure/networking/design-guide/private-platform-as-a-service)), and the Microsoft cloud security benchmark rates it a must-have ([NS-2](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-network-security#ns-2-secure-cloud-native-services-with-network-controls)).
  - That changes the prod pipeline. Microsoft-hosted agents can't reach private endpoints, and the SQL grant's temporary firewall rule stops working once SQL refuses public traffic. Prod needs [Managed DevOps Pools with VNet injection](https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking?view=azure-devops#agents-injected-into-existing-virtual-network): a subnet delegated to `Microsoft.DevOpsInfrastructure/pools`, the pool and VNet in the same region, and an address plan that avoids `172.17.0.0/16`.
  - Staging mirrors prod's network setup, so private DNS, agents and the SQL grant are tested before prod.
- **Prod shares the subscription (accepted trade-off).** The team keeps prod in the same subscription as the other environments, against CAF's guidance to use separate subscriptions for production and nonproduction ([CAF: Create and scale Azure subscriptions](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-setup-guide/initial-subscriptions#start-with-subscription-policies)). What that means:
  - Subscription Owners and Contributors, and subscription-scope policy, also control prod.
  - Defender for Cloud plans enabled at subscription level cover (and bill) every environment.
  - Prod and non-prod share `andes-rg-tfstate` and the state account.

  Mitigations in place: per-environment identities scoped to their own resource group and state container, approval on prod's apply connection, and the `CanNotDelete` lock on `andes-rg-prod`. Keep the subscription Owner list short.

## Day-to-day

- **Change your IP:** update the `allowedIpAddresses` secret in the `andes-vg-<env>` variable group (**Pipelines → Library**) and re-run the pipeline. No PR is needed. The SQL, Key Vault, Storage and Cosmos DB firewalls follow.
- **Add blob containers or Cosmos DB containers:** edit `storage_containers` or `cosmos_containers` in tfvars. Cosmos DB containers must be declared here, because Entra data-plane roles can't create databases or containers.
- **Retry a failed SQL grant:** use **Rerun failed jobs** on the run. It re-runs `grant` without re-applying.
- **Run Terraform locally:** you need `Storage Blob Data Contributor` on the `tfstate-<env>` container, which listing your object ID in `state_contributor_object_ids` (bootstrap tfvars) grants. Set the IP allowlist first, using the same list as the pipeline's `allowedIpAddresses` so the next pipeline run doesn't revert the firewalls:

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
- **Add an Azure role to the pipeline's allowlist:** when `terraform/` assigns a new role, add it to `assignable_role_names` in `bootstrap/terraform/variables.tf` and re-apply the bootstrap first.

## Troubleshooting

- **First plan fails with `Error loading state: failed to lock azure state`.** The environment's empty state was never created. Run the one-time `terraform init` from [First-time setup](#first-time-setup-per-subscription-then-per-environment) step 7.
- **Plan fails with `AuthorizationFailed` on a `.../action`.** A resource type you started using calls a POST list action during refresh, which the plan identity's `*/read` doesn't cover. Add the action to `azurerm_role_definition.plan_reader` in `bootstrap/terraform/rbac.tf` and re-apply the bootstrap.
- **A run stops at "needs permission".** The pipeline isn't authorized for a service connection, variable group or Environment. Set `infra_pipeline_name` in the bootstrap tfvars and re-apply.
- **A qa or prod run fails because a service connection is disabled.** Azure DevOps may automatically disable connections unused for 100 days ([Connect to Azure](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)). Re-enable it in **Project settings → Service connections**, or run the pipeline regularly.
- **Legacy Azure DevOps OIDC issuer.** It retires on July 1, 2027. The bootstrap reads each federated credential's issuer and subject from the Azure DevOps service connection, so if you convert a connection to the Microsoft Entra issuer, re-applying the bootstrap updates the credential ([Manually set an ARM WIF service connection](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity)).
- **Optional defense in depth.** Azure DevOps can require a team member's comment before PR builds from same-repo branches run ([Sprint 275](https://learn.microsoft.com/azure/devops/release-notes/2026/pipelines/sprint-275-update#features)). The plan/apply split already keeps those builds read-only.

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
  - **API:** publish framework-dependent or `win-x64`. The worker is 64-bit (`use_32_bit_worker = false`, because the provider defaults Windows workers to 32-bit and a `win-x64` publish fails to start on one).
  - **UI:** IIS serves the static Angular build directly, so no Node process runs. The deployed package must include a `web.config` whose URL Rewrite rule sends paths that aren't files or directories to `/index.html`. Without it, deep links and page refreshes return 404. Put the file in the Angular project's `public/` folder so the build copies it next to `index.html`:

    ```xml
    <?xml version="1.0" encoding="utf-8"?>
    <configuration>
      <system.webServer>
        <rewrite>
          <rules>
            <rule name="Angular routes" stopProcessing="true">
              <match url=".*" />
              <conditions logicalGrouping="MatchAll">
                <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
                <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
              </conditions>
              <action type="Rewrite" url="/index.html" />
            </rule>
          </rules>
        </rewrite>
      </system.webServer>
    </configuration>
    ```
