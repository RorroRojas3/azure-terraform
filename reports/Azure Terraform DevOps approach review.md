# Andes' Azure design holds, but PR plans overreach

Most of the Andes approach matches current Microsoft and HashiCorp guidance, and some of it is stricter than Microsoft's own accelerators. One part of the pipeline contradicts that guidance and should be fixed first. These parts all fit current guidance:

- the single root module with per-environment tfvars and backend files
- the Entra-only state account with versioning and 30-day soft delete
- a user-assigned identity per environment, on workload identity federation, with Contributor plus an ABAC-constrained Role Based Access Control Administrator at resource-group scope
- VNet integration with service endpoints for non-production

The research confirms all three proposed improvements. The third, a read-only identity for PR plans, is not optional. Today any branch pushed to the repo runs its own YAML under the write-capable identity before anyone reviews it. The Environment approval guards only the apply job, and CAF says an approval placed there "can be bypassed in code." Microsoft's Azure Landing Zones accelerator already uses the proposed Terraform bootstrap pattern. But the provider docs it would be built from are out of date in two ways, and new service connections now carry a subject containing a GUID, which only values computed during the apply can supply. Giving prod its own subscription matches CAF's three-subscription minimum, and it has a hard deadline. An App Service using VNet integration can't change subscription, so the split has to happen before prod's first deploy. The research also found three further problems:

- Prod should default to private endpoints with public access disabled, which forces a move to Managed DevOps Pools agents.
- The dev and planned qa address ranges collide with Windows App Service worker ranges.
- PR runs publish plan files that contain the IP allowlist in cleartext.

## Scorecard: six design choices, three proposed improvements

The table gives the verdict on each part of the current approach and on each proposed improvement. The sections that follow give the evidence and sources.

| Element | Verdict | Deciding evidence |
|---|---|---|
| Single root module, per-environment `terraform.tfvars` and partial `backend.hcl`, no CLI workspaces | **Confirmed** | Microsoft's Well-Architected Framework (WAF) asks for one set of files adapted per environment. HashiCorp says CLI workspaces are wrong when environments need separate credentials. |
| Raw `azurerm` resources instead of Azure Verified Modules (AVM) | **Acceptable** | The relevant AVM modules are mostly 0.x, the Key Vault module has no owner ("Orphaned"), and new AVM modules must use the AzAPI provider. |
| State: one Entra-only account per subscription, one container per environment | **Confirmed, with a documented network trade-off** | Data protection exceeds Microsoft's minimums. The public endpoint matches the fallback Microsoft's ALZ accelerator uses with Microsoft-hosted agents. |
| User-assigned managed identity (UAMI) per environment with workload identity federation (WIF): Contributor plus ABAC-constrained RBAC Administrator on the resource group, no subscription rights | **Confirmed, stricter than ALZ** | Matches Microsoft's "constrained delegation" guidance. ALZ gives its apply identity Owner at management-group scope. |
| Admin-run PowerShell bootstrap and manual Azure DevOps setup | **Works, but is Microsoft's least-preferred path** | Microsoft says to use manual WIF setup only after the automatic option fails. The second pass exists only because the subject isn't known until the connection exists. |
| PR plans and main-branch applies through one service connection, approvals on the Azure DevOps Environment | **Contradicted** | CAF asks for a separate read-only plan identity, and for approvals on the service connection rather than the environment. |
| All environments in one subscription, isolated by resource group | **Confirmed for non-prod, contradicted for prod** | CAF: separate subscriptions for production, nonproduction and sandbox. |
| Windows App Service, VNet integration, service endpoints, public endpoints behind default-deny firewalls | **Confirmed for dev/test, too weak for prod** | Microsoft's networking design guide maps dev/test to service firewalls and production to private endpoints. |
| (1) Terraform bootstrap with the azurerm, azuread and azuredevops providers | **Confirmed, with four corrections** | The provider exports the federation issuer and subject, and Microsoft's ALZ bootstrap uses the same chain. |
| (2) Prod in its own subscription | **Confirmed, must happen before prod's first deploy** | CAF's three-subscription minimum, and VNet-integrated apps can't change subscription. |
| (3) Read-only identity for PR plans | **Confirmed; treat as required, not optional** | CAF, ALZ and Microsoft's sample all do it, and HashiCorp says plan permission equals write permission. |

## Layout, state backend and identity already meet the bar

### The single-root layout follows Microsoft almost word for word

Microsoft's guidance describes the repo's layout almost exactly. The Well-Architected Framework says to "avoid using different Terraform files in production and test environments. All environments should use a single file that you can adapt to different environments" ([WAF OE:05](https://learn.microsoft.com/azure/well-architected/operational-excellence/infrastructure-as-code-design)). Microsoft's own AVM solution-development lab runs one root module against per-environment var files ([AVM Terraform solution development](https://azure.github.io/Azure-Verified-Modules/usage/solution-development/terraform/)).

HashiCorp's style guide asks CLI users for a little more: "use modules to encapsulate your configuration, and use a directory for each environment," which "also lets you maintain separate variable and backend configurations for each environment" ([Terraform style guide](https://developer.hashicorp.com/terraform/language/style)). Andes meets the second half, separate variables and backend per environment. It doesn't meet the first half, a thin root directory per environment that calls a shared module. With one stack and the same topology everywhere, that wrapper would add indirection without adding isolation. It becomes worth adopting only if environments start to differ in structure rather than in values.

Rejecting CLI workspaces is correct. HashiCorp still says "Workspaces are not appropriate for system decomposition or deployments requiring separate credentials and access controls" ([Terraform: Workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces)). Each Andes environment has its own identity, with access only to its own state container, which is exactly that case. HashiCorp's older automation tutorial still suggests switching environments with `terraform workspace`. It conflicts with the current workspace docs and style guide, which take precedence. Terraform Stacks went GA in September 2025 only for HCP Terraform ([HashiCorp, HashiConf 2025](https://www.hashicorp.com/blog/scale-infrastructure-with-new-terraform-and-packer-features-at-hashiconf-2025)), so it doesn't apply to the open-source CLI with an azurerm backend.

The remaining differences are cosmetic:

- HashiCorp recommends naming partial backend files `*.azurerm.tfbackend` rather than `backend.hcl` ([Terraform: Backend configuration](https://developer.hashicorp.com/terraform/language/backend)).
- The 4-hex-character name suffix, derived from the resource group ID, follows Microsoft's Bicep name-generation pattern ([Name generation pattern](https://learn.microsoft.com/azure/azure-resource-manager/bicep/patterns-name-generation#considerations)). It is far shorter than the 13 characters of `uniqueString()`, which Microsoft says "isn't globally unique" even at that length ([ARM string functions](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-functions-string#uniquestring)). Changing the suffix now would rename, and so recreate, existing resources. Decide before prod whether to leave it.

### Raw azurerm is defensible while the needed AVM modules sit at 0.x

Staying on raw `azurerm` is defensible in 2026, although it now runs against the direction of Microsoft's own module program. AVM is Microsoft-owned, and "Consumers can use these modules in any environment, including production" ([AVM FAQ](https://azure.github.io/Azure-Verified-Modules/resources/faq/)). But the modules Andes would need are mostly pre-1.0: web site 0.23.0, storage 0.10.0, SQL server 0.2.1 and Cosmos DB 0.11.0. The Key Vault module is **"Orphaned"**, meaning it has no current owner ([AVM Terraform module index](https://azure.github.io/Azure-Verified-Modules/indexes/terraform/tf-resource-modules/)).

The AVM spec now says Terraform modules "MUST use the AzAPI provider for every control-plane resource" ([AVM Terraform specifications](https://azure.github.io/Azure-Verified-Modules/specs/tf/)). Adopting AVM would therefore mean a second provider and pre-1.0 interfaces that can break on a minor version bump. No Microsoft or HashiCorp source discourages raw provider resources for workload code. The practical stance is to keep `azurerm`, borrow WAF-aligned defaults from the AVM source code, and revisit once the relevant modules reach 1.0. The research did not independently verify the azurerm 5.8 feature set.

### The state backend's only gap is a network trade-off Microsoft's own tooling makes

The state backend exceeds vendor guidance on data protection. HashiCorp labels Entra ID authentication "(Recommended)" for the azurerm backend. Of access keys and SAS tokens it says "we do not recommend it for new workloads" ([Terraform: azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)). Microsoft's baseline is a resource lock plus container and blob soft delete ([Blob data protection overview](https://learn.microsoft.com/azure/storage/blobs/data-protection-overview)), with "a minimum retention period of seven days" ([Enable blob soft delete](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-enable)) and versioning on top for critical data ([Soft delete vs. versioning](https://learn.microsoft.com/azure/storage/blobs/soft-delete-vs-versioning-options)).

`New-TfStateBackend.ps1` covers all of that and more:

- blob versioning
- **30-day** blob and container soft delete
- a `CanNotDelete` lock
- shared keys disabled
- TLS 1.2 minimum

`New-AppEnvironment.ps1` also limits each identity's Storage Blob Data Contributor role to its own container.

The one difference from Microsoft's guidance is the public endpoint. Microsoft's state tutorial says "In a production deployment, restrict access to this storage account by using a storage firewall, service endpoint, or private endpoint" ([Store Terraform state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage)). Microsoft's ALZ bootstrap defaults to private endpoints and self-hosted agents. But the same bootstrap sets `public_network_access_enabled` to true, with shared keys disabled, whenever Microsoft-hosted agents are chosen ([ALZ bootstrap storage.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/modules/azure/storage.tf)). That is exactly the Andes posture.

There is no workable firewall alternative while the pipeline uses Microsoft-hosted agents, for two reasons:

- Their IP ranges change over time, a new list is published weekly, they span every region in the geography, and "machines in this range can belong to other customers as well" ([Microsoft-hosted agents](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#security)).
- Storage IP rules "have no effect on requests that originate from the same Azure region as the storage account" ([Storage firewall limitations](https://learn.microsoft.com/azure/storage/common/storage-network-security-limitations#restrictions-for-ip-network-rules)).

A public, Entra-only account is therefore a documented trade-off, not an anti-pattern. Its cost is that a leaked token or a misassigned role can be exploited from anywhere. Microsoft's upgrade path is Managed DevOps Pools plus a private endpoint, which it recommends when "allowing the entire geography is a concern" ([Allowed IP addresses and domain URLs](https://learn.microsoft.com/azure/devops/organizations/security/allow-list-ip-url?view=azure-devops#ip-addresses-and-range-restrictions)).

No Microsoft page says whether to use one state account per subscription or one per environment. The ALZ platform bootstrap uses one account. The ALZ application-landing-zone bootstrap uses one per environment ([AVM ALZ application LZ CI/CD bootstrap](https://raw.githubusercontent.com/Azure/terraform-azure-avm-ptn-alz-application-landing-zone-cicd-bootstrap-azure-devops/refs/heads/main/README.md)). Choosing RA-GRS over ALZ's default ZRS is a resilience choice, not a violation.

### The identity model is the design's strongest part, with three loose ends

Workload identity federation for Azure Resource Manager service connections went GA in Sprint 234, in early 2024 ([Sprint 234](https://learn.microsoft.com/azure/devops/release-notes/2024/sprint-234-update)). Microsoft now keeps secret-based and agent-assigned options only "for backwards compatibility and edge cases" ([Connect to Azure with an ARM service connection](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)). CAF prefers user-assigned managed identities because they "more easily integrate with your subscription vending process" ([CAF: DevOps security](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview)). Their tokens last about 24 hours, and Microsoft recommends a managed identity specifically to fix token-expiry errors that hit after about an hour ([Troubleshoot WIF](https://learn.microsoft.com/azure/devops/pipelines/release/troubleshoot-workload-identity?view=azure-devops#error-messages)).

The role design is what Microsoft calls **constrained delegation**. Microsoft treats delegating through Owner or User Access Administrator as a least-privilege violation, because the delegate "can assign any role to any user within their scope, including themselves." It recommends Role Based Access Control Administrator with ABAC conditions instead ([Delegate Azure access management](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview)), at "a narrow scope, such as resource group" ([Azure RBAC best practices](https://learn.microsoft.com/azure/role-based-access-control/best-practices)). That makes Andes stricter than Microsoft's own ALZ accelerator, whose apply identity holds Owner at the intermediate root management group ([ALZ permissions FAQ](https://azure.github.io/Azure-Landing-Zones/accelerator/faq/permissions/)).

Setting `ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID` and `SYSTEM_ACCESSTOKEN` lets the provider request fresh OIDC tokens during the run. That is HashiCorp's documented pattern ([azurerm OIDC guide](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/guides/service_principal_oidc.html.markdown)), and it handles long applies better than ALZ, which passes in a single token at the start.

Three loose ends remain:

1. **The pipeline can grant itself data access.** The ABAC condition limits which roles the pipeline can assign, but not to whom. The allowed roles include Key Vault Secrets Officer and Storage Blob Data Contributor. So the pipeline identity, or any code running as it, can give itself data-plane access to every vault and storage account in its resource group. Microsoft documents principal-type and specific-principal constraints for exactly this ([Delegate Azure access management](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview)). Excluding the pipeline's own principal is the simplest option. A principal-type rule would conflict with the role assignments dev makes to `developer_principal_ids`.
2. **The old federation issuer is retiring.** The Azure DevOps issuer `https://vstoken.dev.azure.com` "retires on July 1, 2027." New connections use the Microsoft Entra issuer, with a subject built from the service connection's GUID ([Manually set an ARM WIF service connection](https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity); [Sprint 253](https://learn.microsoft.com/azure/devops/release-notes/2025/pipelines/sprint-253-update#features)).
3. **Idle connections get disabled.** "Azure Pipelines might automatically disable connections that you didn't use for 100 days" ([Connect to Azure](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops)). Rarely deployed qa and prod connections will hit this unless the runbook covers it.

## PR plans run with apply rights, so improvement 3 is a fix, not a feature

### Any branch pusher can act as the write identity before review

The pipeline is where the repo departs from current guidance, and the problem is sharper than "PR plans should be read-only." For a PR from a branch in the same repo, Azure DevOps runs that branch's own YAML: "If the YAML file in the new branch is changed, the updated YAML runs the pipeline." Microsoft tells teams "to treat code and YAML files as potentially untrusted" ([Secure agents, projects, and containers](https://learn.microsoft.com/azure/devops/pipelines/security/misc)). Only PRs from forks are denied secrets and service connections by default ([Build GitHub repositories](https://learn.microsoft.com/azure/devops/pipelines/repos/github?view=azure-devops#pr-triggers)).

HashiCorp is blunt about what that means for Terraform: "plan and apply operations can execute arbitrary code," and "from a security perspective, the plan permission is equivalent to the write permission" ([HCP Terraform security model](https://developer.hashicorp.com/terraform/cloud-docs/architectural-details/security-model)). So anyone who can push a branch to the GitHub repo can, before any review, do any of the following:

- edit `steps-terraform.yml` to run arbitrary commands
- add an `external` data source or a malicious provider
- copy `SYSTEM_ACCESSTOKEN` out of the plan step and use it to mint tokens for the service connection

Each of these runs as an identity that holds Contributor, the conditioned RBAC Administrator role and write access to state. GitHub branch protection on `main` doesn't help, because the PR pipeline runs before the merge.

### CAF's fix has two coupled parts: the identity split and where the approvals sit

**A separate read-only identity.** CAF says to "create a separate identity per application and environment for read-only operations, such as Terraform plan or Bicep what-if" ([CAF: DevOps security](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview)). Both of Microsoft's reference implementations do this:

- The ALZ accelerator creates separate plan (Reader) and apply identities and service connections, and runs its PR-validation template on the plan connection ([ALZ ci-template.yaml](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/pipelines/terraform/templates/ci-template.yaml)).
- Microsoft's Azure DevOps Terraform OIDC sample gives the plan identity "read only access to the resource group" and the apply identity Contributor ([Azure-Samples OIDC sample](https://github.com/Azure-Samples/azure-devops-terraform-oidc-ci-cd)).

**Approvals on the service connection, not the Environment.** CAF says: "Create approvals on the service connection. Don't create them on environments, as that can be bypassed in code" ([CAF: DevOps security](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview)). Microsoft's pipeline security overview also asks for branch control checks on service connections ([Secure your Azure Pipelines](https://learn.microsoft.com/azure/devops/pipelines/security/overview?view=azure-devops#restrict-project,-repository,-and-service-connection-access)).

The difference matters because checks are configured on the resource itself, and "Users modifying the pipeline yaml file can't modify the checks" ([Define approvals and checks](https://learn.microsoft.com/azure/devops/pipelines/process/approvals)). An Environment approval, by contrast, gates only the jobs that reference that Environment. In Andes, the plan stage and the SQL-grant stage reference `andes-sc-<env>` directly and never touch `andes-<env>`. Microsoft's sample deliberately leaves its environment without checks, "to ensure that the approval is to use the identity and cannot be bypassed" ([Azure-Samples OIDC sample](https://github.com/Azure-Samples/azure-devops-terraform-oidc-ci-cd)).

The two parts depend on each other. A service connection that PR plans use can't carry an approval or a branch-control check for `refs/heads/main`, because PR runs would then be blocked. The identity split is what makes it possible to put the gates where CAF wants them.

The target model, per environment:

| Connection | Role on the environment's resource group | Used by | Checks on the connection |
|---|---|---|---|
| Plan | Reader (or a small custom read role) | PR plans and main-branch plans | Optional exclusive lock and required template |
| Apply | Contributor plus the conditioned RBAC Administrator role | Apply and the SQL grant | Approval, branch control for `refs/heads/main`, exclusive lock |

Both identities stay in the tfstate resource group, out of reach of the pipeline. The Environment can stay for deployment history.

### Two caveats keep the plan identity from being plain Reader

1. **It still needs write access to state.** Both ALZ and the Microsoft sample give the plan identity Storage Blob Data Contributor on the state container ([ALZ storage.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/modules/azure/storage.tf); [Azure-Samples OIDC sample](https://github.com/Azure-Samples/azure-devops-terraform-oidc-ci-cd)), because the azurerm backend takes a blob lease to lock state. The alternatives are Storage Blob Data Reader with `-lock=false` for PR plans only, or accepting ALZ's compromise. Neither is a documented Microsoft recommendation.
2. **Reader may not cover every refresh call.** Built-in Reader grants only `*/read` ([Azure built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/general)), so resources whose refresh calls `list*` actions may fail. Expect to need a small custom plan-reader role. The research inferred this but could not confirm it against a primary source.

Until the split ships, the per-source comment setting added in Sprint 275 can close the gap. It lets the project require a team member's comment before PR builds from same-repo branches run, so no plan runs before a trusted reviewer has looked ([Sprint 275](https://learn.microsoft.com/azure/devops/release-notes/2026/pipelines/sprint-275-update#features)).

### Plan artifacts and the JSON secret leak the IP allowlist

The plan artifact is a smaller, related leak. Terraform writes sensitive values "in cleartext in the plan file," along with "your full configuration" and the input variables. HashiCorp says to "treat any saved plan files as potentially-sensitive artifacts" ([terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)). The template publishes `tfplan-<env>` whenever the plan has changes, including on PR runs, where no apply ever uses it. So every such PR leaves the IP allowlist downloadable by anyone with artifact access in the Azure DevOps project, rather than only by people Azure RBAC allows.

Ephemeral variables and write-only arguments don't help here. Firewall `ip_rules` are ordinary arguments that must persist in state ([Manage sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)). Publishing the plan only on `main` and shortening retention closes most of the exposure. Once the plan identity exists, also decide whether PR runs need the secret at all.

The allowlist itself is stored as one JSON-valued secret, which Microsoft explicitly warns against: "We never mask substrings of secrets... secrets should not contain structured data" ([Set secret variables](https://learn.microsoft.com/azure/devops/pipelines/process/set-secret-variables)). Either store each address as its own secret, or record that developer IPs are low-sensitivity values that are kept out of the repo but not protected in logs.

## Microsoft's own accelerator validates the Terraform bootstrap, with four corrections

### Microsoft already ships the same single-apply pattern

The proposed Terraform bootstrap is not speculative. `azuredevops_serviceendpoint_azurerm` accepts `WorkloadIdentityFederation` with a UAMI's client ID. It exports `workload_identity_federation_issuer` and `workload_identity_federation_subject`, which feed `azurerm_federated_identity_credential` in the same apply ([azuredevops provider docs](https://github.com/microsoft/terraform-provider-azuredevops/blob/main/website/docs/r/serviceendpoint_azurerm.html.markdown)).

Microsoft's ALZ accelerator bootstrap wires exactly that chain: service connection outputs feed the plan and apply federated credentials, and UAMI client IDs feed back into the connections ([ALZ outputs.tf](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/modules/azure_devops/outputs.tf); [ALZ locals.tf](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/locals.tf)). It also creates environments, variable groups, and approval, exclusive-lock and required-template checks as code ([ALZ service_connections.tf](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/modules/azure_devops/service_connections.tf)).

Microsoft's scripting guide explains why the current flow takes two passes: "the federated credential can only be created after the service connection is created" ([Automate WIF service connections](https://learn.microsoft.com/azure/devops/pipelines/release/automate-service-connections?view=azure-devops)). Terraform orders those resources itself, so the second pass disappears.

### Stale provider docs and ALZ's design limits require four corrections

1. **The preview note is out of date.** The provider page still says WIF is "currently in private preview." WIF has been GA since early 2024.
2. **The documented issuer and subject formats are out of date, and this matters more.** New connections use the issuer `https://login.microsoftonline.com/<tenant id>/v2.0` and a subject of the form `<entra prefix>/sc/<organization id>/<service connection id>` ([Troubleshoot WIF](https://learn.microsoft.com/azure/devops/pipelines/release/troubleshoot-workload-identity?view=azure-devops)). The subject contains a GUID that exists only after the connection is created, so reading the provider's computed outputs is required, not just convenient. When Azure DevOps first rolled out the new format, infrastructure code that predicted the old `sc://org/project/name` subject broke. Microsoft then rolled the change back for "most" organizations in April 2025 ([provider issue #1361](https://github.com/microsoft/terraform-provider-azuredevops/issues/1361)). Only a test connection can show which issuer this organization gets, but reading computed outputs works either way.
3. **The provider's example code is wrong for current azurerm.** It targets an older azurerm and puts `resource_group_name` in quotes as a literal string. Current azurerm docs list `name`, `user_assigned_identity_id`, `audience`, `issuer` and `subject` as the required arguments ([azurerm federated_identity_credential](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/federated_identity_credential.html.markdown)). Copy the pattern, not the code.
4. **ALZ is a model to follow, not a module to adopt.** It targets the platform landing zone at management-group scope. It authenticates with a PAT whose expiry the docs say to set to "tomorrows date" ([ALZ Azure DevOps prerequisites](https://azure.github.io/Azure-Landing-Zones/accelerator/1_prerequisites/azuredevops/)). And it keeps its own state local because "The bootstrap is a one-time operation" ([ALZ upgrade FAQ](https://azure.github.io/Azure-Landing-Zones/accelerator/faq/upgrade/)).

### Keep the PowerShell state script and store the bootstrap's state remotely

Correction 4 is also why keeping `New-TfStateBackend.ps1` is right. The Andes bootstrap runs again for every new environment, and different admins may run it. Local state on one laptop doesn't fit that.

Store the bootstrap module's state in the account the PowerShell script creates, in a dedicated container that only an admin group can write. No pipeline identity should ever reach that container: a pipeline that could write the bootstrap state could steer the next Owner-level apply. With WIF and no secret variables, the state holds identifiers rather than credentials, but it still maps out who holds which privilege.

All three providers can authenticate through the admin's `az login`. The azuredevops provider defaults to `use_cli = true` ([provider authentication docs](https://github.com/microsoft/terraform-provider-azuredevops/blob/main/website/docs/index.html.markdown)), so no PAT is needed, which fits the repo's no-secrets rule.

The admin who runs the bootstrap needs:

- Groups Administrator or higher in Entra, to create the SQL admin groups ([azuread_group](https://github.com/hashicorp/terraform-provider-azuread/blob/main/docs/resources/group.md))
- Owner or equivalent on the subscription, for the role assignments
- project-level service connection rights in Azure DevOps

These are the same rights the scripts and manual steps already need, now used in one run.

`azurerm_role_assignment` supports the ABAC `condition` with `condition_version = "2.0"`. Its docs warn to set `principal_type` explicitly when the identity creating the assignment is itself constrained by ABAC ([azurerm_role_assignment](https://github.com/hashicorp/terraform-provider-azurerm/blob/main/website/docs/r/role_assignment.html.markdown)). Define the list of assignable roles once, as a Terraform variable, and use it for both the ABAC condition and the role assignments. The repo convention that every assigned role "must be in `-AssignableRoleNames`" would then be enforced by code instead of by memory.

### What the bootstrap should create, and its ongoing costs

Per environment, the module should create the plan and apply identities from the previous section. It should put the approval, the `refs/heads/main` branch control and the exclusive lock on the apply service connection, as ALZ does. Add these safeguards:

- Set explicit group `owners`. Otherwise the person running apply becomes the sole owner.
- Set `prevent_duplicate_names = true`, because Entra group names aren't unique.
- Add `prevent_destroy` on identities, groups and connections.

Existing hand-made objects need `import` blocks. The provider added import support for checks in 1.16.0 and for pipeline authorization in 1.14.0. But "Variable groups containing secret values cannot be imported" ([variable_group docs](https://github.com/microsoft/terraform-provider-azuredevops/blob/main/website/docs/r/variable_group.html.markdown); [provider CHANGELOG](https://github.com/microsoft/terraform-provider-azuredevops/blob/main/CHANGELOG.md)), so the variable group holding the allowlist has to be recreated.

The ongoing cost is provider churn. Issue #1573, opened in July 2026 with no maintainer response yet, notes that the issuer and subject are computed values and can't be converted in place ([issue #1573](https://github.com/microsoft/terraform-provider-azuredevops/issues/1573)). Even so, Terraform handles the 2027 issuer migration better than PowerShell: when a connection's subject changes, the next apply updates the federated credential automatically.

### Alternatives considered

- **`az devops` CLI scripts.** If the team would rather stay imperative, Microsoft's documented sequence also removes the second pass: create the service connection with `az devops service-endpoint create`, read its issuer and subject, then run `az identity federated-credential create` ([Automate WIF service connections](https://learn.microsoft.com/azure/devops/pipelines/release/automate-service-connections?view=azure-devops)). You lose drift detection.
- **`azd pipeline config`.** A poor fit: it needs a PAT and falls back to client secrets for Terraform ([azd FAQ](https://learn.microsoft.com/azure/developer/azure-developer-cli/tooling-environment-faq#pipeline-configuration)).
- **GitHub Actions instead of Azure DevOps.** This would remove service connections entirely, because the federated subject becomes predictable ([Azure Login with OIDC](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect)). It is a pipeline migration, though, and deserves its own architecture decision record.

## Prod needs its own subscription and private endpoints before its first deploy

### CAF wants prod in its own subscription and lets non-prod share one

CAF's current setup guide is unambiguous: "Avoid placing multiple workload environments in the same subscription. Create separate subscriptions for production, nonproduction, and sandbox environments." Small organizations should "Start with three core subscriptions" ([CAF: Create and scale Azure subscriptions](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-setup-guide/initial-subscriptions#start-with-subscription-policies)). CAF also allows environments to share one subscription when they have "the same teams assigned to functional roles" and "can use the same policies" ([Manage application development environments](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/design-area/management-application-environments)). That covers dev, qa, uat and staging. Resource-group isolation is fine for non-prod and wrong for prod.

The strongest counterargument doesn't apply. On the same page, CAF recommends a single subscription for an App Service workload so that deployment slots can span environments. Each Andes environment already has its own App Service plan, so slots can't cross environments anyway.

### The reasons to split are control boundaries, not subscription limits

Subscription limits aren't a reason. A subscription allows 980 resource groups and 5,000 role assignments, far beyond this workload ([Azure subscription limits](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#general-limits)), and budgets and policy both work at resource-group scope. The real reasons are these four:

1. **Owners and subscription-level controls are shared.** A subscription Owner is also Owner of prod. CAF warns that subscription-scoped policies and tags "can be changed by individuals with elevated permissions to the subscription" ([Manage application development environments](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/design-area/management-application-environments)).
2. **Defender plans are subscription-wide.** Microsoft recommends enabling Defender for SQL "at the subscription level so that new resources are automatically protected" ([Defender for SQL](https://learn.microsoft.com/azure/azure-sql/database/azure-defender-for-sql?view=azuresql#enable-microsoft-defender-for-sql)). In a shared subscription, the prod checklist would then also cover, and bill, every non-prod environment.
3. **Dev/Test pricing needs its own subscription.** Dev/Test pricing requires a separate Dev/Test offer subscription, and that subscription shouldn't host customer-facing services because it has no financially backed SLA ([Azure Dev/Test reliability](https://learn.microsoft.com/azure/devtest/offer/how-to-manage-reliability-performance)).
4. **Prod and non-prod share state and identity infrastructure today.** Every environment's pipeline identity lives in `andes-rg-tfstate`, next to one shared state account. A prod subscription gets its own state backend and identity resource group, because the bootstrap already runs once per subscription.

Timing is the critical detail. "You can't change the subscription of an app or a plan while there's an app that's using virtual network integration" ([App Service VNet integration limitations](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#limitations)). The split must happen before prod's first deploy, not after.

### Service endpoints are fine for non-prod; prod should default to private endpoints

The network design fits the guidance for non-prod and is too weak for prod. Microsoft's networking design guide maps three cases to three approaches ([Private access to Azure PaaS services](https://learn.microsoft.com/azure/networking/design-guide/private-platform-as-a-service)):

| Case in Microsoft's guide | Recommended approach |
|---|---|
| "Dev/test, low data sensitivity" | Public endpoint with service firewall |
| "Simple VNet restriction, low exfiltration risk" | Service endpoints |
| "Production workloads, sensitive data, compliance" | Private endpoints, "Preferred over Service Endpoints for new designs" |

The Microsoft cloud security benchmark rates control NS-2 (deploy private endpoints, then disable public access) as "Must have" ([MCSB v2 NS-2](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-network-security#ns-2-secure-cloud-native-services-with-network-controls)). Service endpoints aren't deprecated. Microsoft is adding a paid "standard service endpoint," now in preview, for exactly Storage, Key Vault, SQL and Cosmos DB ([Standard service endpoint](https://learn.microsoft.com/azure/private-link/service-endpoint-standard-overview)).

The design's own rationale holds. Storage IP rules can't admit an App Service in the same region, so VNet rules are required. Regional VNet integration on the Basic tier carries "no extra charge" ([App Service VNet integration](https://learn.microsoft.com/azure/app-service/overview-vnet-integration)).

What should change is the production checklist line in `docs/infrastructure.md` that says "consider private endpoints." Given Microsoft's wording, private endpoints with public access disabled should be the prod default, and any exception should be written down as a risk acceptance. CAF also says SDLC environments shouldn't differ in policy, and gives the example of a storage account that fails on promotion because prod enforces private endpoints and dev doesn't ([Manage application development environments](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/design-area/management-application-environments)). Staging should run the prod network setup, so that private DNS, agent connectivity and the SQL grant step are tested before they reach prod.

### Private endpoints in prod require Managed DevOps Pools agents

Private endpoints in prod change the pipeline. Microsoft-hosted agents can't use private connections ([Microsoft-hosted agents networking](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#networking)). The SQL grant step's temporary firewall rule also stops working once SQL refuses public traffic.

The prod pipeline therefore needs Managed DevOps Pools (MDP) with VNet injection, which requires:

- a subnet delegated to `Microsoft.DevOpsInfrastructure/pools`
- the pool and the VNet in the same region
- an address plan that avoids `172.17.0.0/16`, which MDP uses internally

([MDP networking](https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking?view=azure-devops#agents-injected-into-existing-virtual-network))

MDP bills Azure compute, storage and egress plus self-hosted parallel jobs, and "Azure DevOps Services provides organizations one free self-hosted parallel job" ([MDP pricing](https://learn.microsoft.com/azure/devops/managed-devops-pools/pricing?view=azure-devops)). Microsoft's worked example comes to about $480 a month at 4,000 job-hours, far more usage than a small team's infrequent applies. Non-prod can stay on Microsoft-hosted agents.

### Dev and planned qa address ranges collide with Windows worker infrastructure

The research also found a latent bug. Microsoft's App Service docs, in a table dated October 2026, say a Windows app's outbound connection through VNet integration fails "if the destination IP address matches an infrastructure IP address of the App Service worker." For the B1, S1 and P1 tiers, the listed ranges include `10.10.0.0/19` and `10.11.0.0/19` ([Windows worker IP overlap](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#windows-worker-ip-address-overlap)).

Dev's VNet is `10.10.0.0/24` and the planned qa range is `10.11.0.0/24`. Nothing breaks today, because service-endpoint traffic goes to the services' public IPs. The first private endpoint in either VNet would break. The planned uat, staging and prod ranges (`10.12` to `10.14`) are clear, although Microsoft says the ranges "can change." Moving qa costs nothing because it doesn't exist yet. Moving dev means recreating its VNet and integration subnet.

### Two smaller hosting notes

- **Route-all setting.** `vnet_route_all_enabled` maps to the legacy route-all setting. Microsoft now recommends `outboundVnetRouting.allTraffic` ([VNet integration routing](https://learn.microsoft.com/azure/app-service/configure-vnet-integration-routing)). The research didn't confirm whether azurerm exposes the newer property.
- **Windows hosting and the SPA.** Windows App Service is a supported .NET 10 host: "the Windows instances already have all the supported .NET Core versions installed" ([Configure ASP.NET Core on App Service](https://learn.microsoft.com/azure/app-service/configure-language-dotnetcore)). For client-rendered Angular apps, though, Microsoft names Static Web Apps ([Hosting applications on Azure](https://learn.microsoft.com/azure/developer/intro/hosting-apps-on-azure)). Serving the SPA from the same B1 plan is a defensible cost trade-off worth recording, not a required change. The research found no Microsoft guidance preferring Linux over Windows for new .NET apps.

## Thirteen changes ranked by risk and deadline

The order follows two rules. First, close the window in which unreviewed code runs as the write identity. Second, make every change that has a structural deadline before the event that makes it expensive. Improvements 1 and 3 should ship together: the Terraform bootstrap is the natural place to create the plan and apply identities and to attach checks to the apply connection, so qa can be created entirely from code.

| Priority | Change | When | Basis |
|---|---|---|---|
| 1 (High) | Require a team-member comment before PR builds from same-repo branches run | This week, as a stopgap | [Sprint 275](https://learn.microsoft.com/azure/devops/release-notes/2026/pipelines/sprint-275-update#features) |
| 1 (High) | Split each environment into a plan identity and connection (read-only plus state lease) and an apply identity and connection. PR and plan stages use plan; apply and the SQL grant use apply. | Now, before qa | [CAF](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview); [HCP security model](https://developer.hashicorp.com/terraform/cloud-docs/architectural-details/security-model) |
| 1 (High) | Move the approval, `refs/heads/main` branch control and exclusive lock to the apply service connection. Keep the Environment for history. | With the split | [CAF](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/considerations/security-considerations-overview); [Secure your Azure Pipelines](https://learn.microsoft.com/azure/devops/pipelines/security/overview?view=azure-devops#restrict-project,-repository,-and-service-connection-access) |
| 2 (Medium) | Publish `tfplan` only on `main` and shorten artifact retention | Now; a one-line condition change | [terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan) |
| 2 (Medium) | Move planned qa off `10.11.0.0/24`; schedule dev's move off `10.10.0.0/24` | qa: before it's created. Dev: before any private endpoint. | [Windows worker IP overlap](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#windows-worker-ip-address-overlap) |
| 2 (Medium) | Build the Terraform bootstrap: remote admin-only state, `az login` authentication, `import` blocks, `prevent_destroy` | Before qa | [ALZ bootstrap](https://github.com/Azure/accelerator-bootstrap-modules/blob/main/alz/azuredevops/locals.tf); [provider docs](https://github.com/microsoft/terraform-provider-azuredevops/blob/main/website/docs/r/serviceendpoint_azurerm.html.markdown) |
| 2 (Medium) | Create the prod subscription with its own state backend and identity resource group | Before prod's first deploy (hard constraint) | [CAF subscriptions](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-setup-guide/initial-subscriptions#start-with-subscription-policies); [VNet integration limitations](https://learn.microsoft.com/azure/app-service/overview-vnet-integration#limitations) |
| 2 (Medium) | Put prod on private endpoints with public access disabled, add an MDP pool for the prod pipeline, and run staging on the same network setup | Before prod's first deploy | [Networking design guide](https://learn.microsoft.com/azure/networking/design-guide/private-platform-as-a-service); [MCSB NS-2](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-network-security#ns-2-secure-cloud-native-services-with-network-controls) |
| Deadline | Confirm every WIF service connection uses the Entra issuer | Before July 1, 2027 | [Connect to Azure](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops) |
| 3 (Low) | Add a principal constraint to the ABAC condition that excludes the pipeline's own principal | With the bootstrap | [Delegate Azure access management](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview) |
| 3 (Low) | Split the JSON allowlist into individual secrets, or document it as low-sensitivity | Any time | [Set secret variables](https://learn.microsoft.com/azure/devops/pipelines/process/set-secret-variables) |
| 3 (Low) | Add a runbook entry for the 100-day auto-disable of idle service connections | Before qa or prod go quiet | [Connect to Azure](https://learn.microsoft.com/azure/devops/pipelines/library/connect-to-azure?view=azure-devops) |
| 4 (Optional) | Adopt `outboundVnetRouting.allTraffic`, rename backend files to `*.azurerm.tfbackend`, evaluate Static Web Apps for the SPA, revisit AVM at 1.0, decide on the name-suffix length before prod | When convenient | As cited in earlier sections |

## Conclusion

Andes' static controls (who holds which role, which networks reach which data) already meet or beat Microsoft's bar. The gap is in what runs before review: which code gets to execute under which identity before a person has looked at it. That turns the three improvements into one project. The read-only plan identity is the piece everything else depends on, because it is what lets approvals and branch control move onto the service connection. The Terraform bootstrap is the natural way to create both identities and those checks as code. The July 2027 issuer retirement favors Terraform further, because it updates federated credentials automatically when subjects change.

Timing matters for everything prod-related: its own subscription, private endpoints with public access off, an MDP pool, a staging environment that tests that network setup, and address ranges clear of Windows worker infrastructure. Each becomes expensive the moment prod is first deployed, because a VNet-integrated app can't change subscription and renaming or renumbering means recreating resources. None of it is urgent today, and all of it is cheap now. Three questions the research couldn't settle can each be answered with one test rather than more reading: which issuer this organization's new connections get, whether Reader covers every refresh call the plan makes, and who can download pipeline artifacts by default.
