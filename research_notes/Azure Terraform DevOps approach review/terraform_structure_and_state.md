# Terraform multi-environment structure and state on Azure (as of October 2026)

Scope: whether the repo's design matches current HashiCorp and Microsoft guidance. The design is one shared root module with per-env `terraform.tfvars` and `backend.hcl`, no CLI workspaces, raw `azurerm` 5.8 resources, and one RA-GRS state account per subscription with a container per env, Entra-only, public network. The pipeline publishes a saved plan as an artifact and supplies a sensitive IP allowlist through `TF_VAR_`.

Note on quotes: HashiCorp and azure.github.io pages were retrieved through a fetch tool that extracts quotes, so a quote may differ slightly in punctuation from the live page. Microsoft Learn pages were retrieved as full markdown, and those quotes are exact. HashiCorp docs pages served the "v1.16.x (latest)" version at retrieval time, 2026-10-10.

## Q1. Multi-environment layout: single root + per-env tfvars/backend vs. CLI workspaces vs. per-env root directories vs. Terragrunt/Stacks

### Takeaway
**Verdict: partially confirms.** Microsoft's Well-Architected guidance directly endorses the repo's model: one set of Terraform files for every environment, with differences parameterized. HashiCorp's style guide recommends something slightly different for CLI (non-HCP) users. It calls for reusable modules plus a directory per environment, each with its own variable and backend configuration.

The repo meets the "separate variable and backend config per environment" half of that advice. It does not meet the "modules + thin per-env root" half. Neither vendor recommends CLI workspaces for this case. Terraform Stacks is GA but only on HCP Terraform, so it doesn't apply here. I found no vendor guidance on Terragrunt.

### Cited Findings
**HashiCorp style guide, "Multiple environments" section**
- "We recommend that your repository's `main` branch be the source of truth for all environments." — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)
- "For HCP Terraform and Terraform Enterprise users, we recommend that you use separate workspaces for each environment." — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)
- "If you do not use HCP Terraform or Terraform Enterprise, we recommend that you use modules to encapsulate your configuration, and use a directory for each environment … This also lets you maintain separate variable and backend configurations for each environment." — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)
- The style guide also recommends storing infrastructure configuration separately from module code, defining local child modules under `./modules/<module_name>`, and pinning module versions to a major and minor version. — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)

**HashiCorp CLI workspaces documentation: the recommended alternative to workspaces**
- "Instead of creating CLI workspaces, you can use one or more re-usable modules to represent the common elements, … represent each instance as a separate configuration that instantiates those common elements in the context of a different backend." — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- "The root module of each configuration consists only of a backend configuration and a small number of module blocks" with arguments for the differences between deployments. — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- Separate working directories give separate state. The trade-off it documents is that "Terraform installs a separate cache of plugins and modules for each working directory," which wastes bandwidth and disk. — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)

**HashiCorp "Running Terraform in automation" tutorial (older; conflicts with the docs above)**
- It names `terraform init` and `terraform workspace` as "the two most interesting commands for multi-environment orchestration."
- It recommends, where possible, one backend configuration for all environments, switching with `terraform workspace`.
- When environments are in separate accounts, it says "backend configuration settings can be overridden via the `-backend-config` option to `terraform init`."
- It warns that `TF_WORKSPACE` should be used only for non-interactive runs, because someone can forget it is set and apply to the wrong state.
- Source: [HashiCorp tutorial: Running Terraform in automation](https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform)

**Partial backend configuration**
- Omitting backend arguments is supported and "may be desirable if some arguments are provided automatically by an automation script." — [Terraform: Backend configuration](https://developer.hashicorp.com/terraform/language/backend)
- "`*.backendname.tfbackend` (e.g. `config.consul.tfbackend`) is the recommended naming pattern," though "Terraform will not prevent you from using other names." — [Terraform: Backend configuration](https://developer.hashicorp.com/terraform/language/backend)
- "If you use `-backend-config` or hardcode these values directly in your configuration, Terraform will include these values in both the `.terraform` subdirectory and in plan files … This can leak sensitive credentials." — [Terraform: Backend configuration](https://developer.hashicorp.com/terraform/language/backend)

**Microsoft Well-Architected Framework OE:05 (infrastructure as code)**
- "Use parameters, variables, and configuration files to deploy a standard set of resources that can be modified to deploy any environment in your code promotion stack." — [WAF: Architecture strategies for using IaC](https://learn.microsoft.com/azure/well-architected/operational-excellence/infrastructure-as-code-design)
- "For consistency, use the same IaC assets in various environments as much as possible. For example, avoid using different Terraform files in production and test environments. All environments should use a single file that you can adapt to different environments." — [WAF: Architecture strategies for using IaC](https://learn.microsoft.com/azure/well-architected/operational-excellence/infrastructure-as-code-design)

**Other Microsoft sources**
- CAF modernization guidance says to "Parameterize these templates so they can be reused for different stages, like dev, test, prod with small tweaks like names or sizes." — [CAF: Execute modernizations](https://learn.microsoft.com/azure/cloud-adoption-framework/modernize/execute-cloud-modernization#create-reusable-infrastructure)
- Contrary or ambiguous signal: Microsoft's Fabric CI/CD guidance says "When using Terraform, it's recommended that you create a separate configuration for each environment … you don't want a problem in the configuration for the dev environment or the test environment to affect the prod environment." — [Fabric CI/CD concepts and best practices](https://learn.microsoft.com/fabric/fundamentals/understand-best-practices-fabric-cicd#how-can-you-automate-fabric-ci-cd)
- Microsoft's own AVM Terraform solution-development lab uses a single root with per-env var files, for example `terraform destroy -var-file=development.tfvars`. The page was last committed Aug 20, 2026. — [AVM: Terraform solution development](https://azure.github.io/Azure-Verified-Modules/usage/solution-development/terraform/)

**Azure Landing Zones (ALZ) accelerator for Azure DevOps**
- It bootstraps a "Starter Terraform module with tfvars" plus an "Environment for Plan" and an "Environment for Apply."
- It creates "User Assigned Managed Identities (UAMI) with Federated Credentials for Plan and Apply" and "Service Connection Approvals, Template Validation and Concurrency Control."
- Source: [ALZ accelerator docs](https://azure.github.io/Azure-Landing-Zones/accelerator/)
- The ALZ application-landing-zone CI/CD bootstrap (an AVM pattern module) "creates the per-environment UAMIs used by the service connections" and "one Workload Identity Federation service connection per environment." Its read identity defaults to Reader and its write identity to Contributor. — [AVM ptn: ALZ application LZ CI/CD bootstrap (Azure DevOps) README](https://raw.githubusercontent.com/Azure/terraform-azure-avm-ptn-alz-application-landing-zone-cicd-bootstrap-azure-devops/refs/heads/main/README.md)

**Terraform Stacks**
- HashiCorp announced Stacks GA on Sept 25, 2025, "for all new HCP Terraform plans based on resources under management (RUM)."
- Stacks let users "rapidly create and modify consistent infrastructure setups with differing inputs," with deployments repeated across dev, staging and prod.
- The post does not mention Stacks for the standalone CLI or Terraform Enterprise.
- Source: [HashiCorp blog, HashiConf 2025](https://www.hashicorp.com/blog/scale-infrastructure-with-new-terraform-and-packer-features-at-hashiconf-2025)

### Inferences
- The repo's layout (`terraform/` root shared by all environments, plus `terraform/environments/<env>/{backend.hcl,terraform.tfvars}`) is a recognized middle path.
  - It matches WAF's "single file … adapt to different environments" directly.
  - It matches the "separate variable and backend configurations for each environment" part of the HashiCorp style guide.
  - It departs from HashiCorp's preferred CLI pattern of a thin per-env root module calling a shared module. With only one app stack and identical topology per environment, that pattern would add indirection without much benefit. It becomes more attractive if environments start to differ structurally, not just in values.
- The main documented risk of a single root is the one HashiCorp raises for `TF_WORKSPACE`: applying the wrong variables or backend to the wrong environment. The repo's pipeline template passes `environments/<env>/` paths per stage, which mitigates this. Each env also has its own identity, RBAC-scoped to its own container, so a mismatch would fail authorization rather than overwrite another env's state.
- Naming `backend.hcl` instead of `*.azurerm.tfbackend` diverges cosmetically from HashiCorp's recommended pattern, not functionally.
- The automation tutorial's "single backend + `terraform workspace`" advice is older and conflicts with the current CLI workspace docs and style guide. Treat the docs and style guide as authoritative.
- Stacks do not apply: they need HCP Terraform, and this repo uses the OSS CLI with the `azurerm` backend.
- Neither vendor ships Terragrunt guidance, and the repo's Azure DevOps pipeline templates already give per-env orchestration.

### Gaps
- I did not find a current Microsoft Learn page specifically titled "Terraform on Azure best practices" for multi-environment layout. Microsoft's guidance comes from WAF, CAF, AVM and the ALZ accelerators.
- I found no HashiCorp or Microsoft primary guidance on Terragrunt, and did not research practitioner sources for it.
- The HashiCorp style guide page shows no last-updated date.

## Q2. Is HashiCorp still advising against CLI workspaces when environments need different credentials/access?

### Takeaway
**Verdict: confirms the design (no CLI workspaces).** Current HashiCorp docs (v1.16.x) still say plainly that CLI workspaces are not appropriate for deployments that need separate credentials and access controls. They also say workspaces are not an isolation mechanism, because all workspaces in a working directory share one backend.

### Cited Findings
- "Workspaces are not appropriate for system decomposition or deployments requiring separate credentials and access controls." — [Terraform language: State > Workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces)
- Organizations "commonly want to create a strong separation between multiple deployments of the same infrastructure serving different development stages or different internal teams. In this case, the backend for each deployment often has different credentials and access controls. CLI workspaces within a working directory use the same backend, so they are not a suitable isolation mechanism for this scenario." — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- "We recommend using alternative approaches for complex deployments requiring separate credentials and access controls." — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- Workspaces are positioned for "a parallel, distinct copy of a set of infrastructure" to test changes, often tied to feature branches. — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- HCP Terraform workspaces are a different concept. HashiCorp does recommend "separate workspaces for each environment" for HCP Terraform and Terraform Enterprise users. — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)

### Inferences
- The repo gives each environment its own pipeline identity, with Storage Blob Data Contributor scoped to its own `tfstate-<env>` container ([bootstrap/New-AppEnvironment.ps1](C:/Users/Rorro/source/repos/azure-terraform/bootstrap/New-AppEnvironment.ps1), lines 131 and 167). That is exactly the "different credentials and access controls" scenario HashiCorp describes. Choosing per-env backend config over CLI workspaces is aligned.

### Gaps
- Neither workspaces page shows a last-updated date.

## Q3. Should a small app environment use Azure Verified Modules (AVM) instead of raw azurerm resources? AVM Terraform maturity in 2026

### Takeaway
**Verdict: partially confirms (raw azurerm is acceptable, but drifts from Microsoft's IaC direction).** Microsoft promotes AVM and says it is usable in production. Neither Microsoft nor HashiCorp mandates it, or says raw provider resources are discouraged for workload code.

In 2026 the AVM Terraform catalog is broad (119 published modules). Most relevant modules are still 0.x, and one of them (Key Vault) is "Orphaned." AVM now requires new Terraform modules to be built on the AzAPI provider, not azurerm. Adopting AVM would therefore mean taking on a second provider and 0.x modules that may change in breaking ways.

### Cited Findings
**What AVM is and how it is supported**
- AVM is "an initiative to consolidate and set the standards for what a good Infrastructure-as-Code module looks like" and "codif[ies] Microsoft guidance (WAF), with best practice configurations." — [Azure Verified Modules home](https://azure.github.io/Azure-Verified-Modules/)
- "AVM is owned, developed & supported by Microsoft." — [Azure Verified Modules home](https://azure.github.io/Azure-Verified-Modules/)
- The AVM FAQ calls AVM "an officially supported OSS project from Microsoft." If Microsoft support (CSS) can't resolve an issue, "they will pass the ticket to the module owner(s) to resolve." The page states no SLA. — [AVM FAQ](https://azure.github.io/Azure-Verified-Modules/resources/faq/)

**Versioning and production readiness**
- Modules are published as "`0.x.y` minor versions." Once a module reaches v1.0, "semantic versioning will apply fully: breaking changes will be avoided whenever possible." — [AVM FAQ](https://azure.github.io/Azure-Verified-Modules/resources/faq/)
- "Consumers can use these modules in any environment, including production." — [AVM FAQ](https://azure.github.io/Azure-Verified-Modules/resources/faq/)
- On timing: "there's no specific timeline available for the publication of Terraform modules" because module owners, many of them volunteers, build them. — [AVM FAQ](https://azure.github.io/Azure-Verified-Modules/resources/faq/)

**Catalog status at retrieval (Oct 2026)**
- 119 published modules (Available or Orphaned), 43 proposed, 162 in total. — [AVM Terraform resource module index](https://azure.github.io/Azure-Verified-Modules/indexes/terraform/tf-resource-modules/)
- Relevant modules from the same index:

| Module | Status | Version |
|---|---|---|
| `avm-res-web-site` | Available | 0.23.0 |
| `avm-res-web-serverfarm` | Available | 2.0.8 |
| `avm-res-keyvault-vault` | **Orphaned** | 0.11.0 |
| `avm-res-storage-storageaccount` | Available | 0.10.0 |
| `avm-res-sql-server` | Available | 0.2.1 |
| `avm-res-documentdb-databaseaccount` | Available | 0.11.0 |
| `avm-res-operationalinsights-workspace` | Available | 0.5.1 |
| `avm-res-insights-component` | Available | 0.4.0 |
| `avm-res-managedidentity-userassignedidentity` | Available | 0.5.3 |
| `avm-res-network-virtualnetwork` | Available | 0.22.2 |

**AzAPI requirement**
- AVM Terraform modules "MUST use the AzAPI provider for every control-plane resource and supported data-plane operation." — [AVM Terraform specifications](https://azure.github.io/Azure-Verified-Modules/specs/tf/)
- AzureRM "is never permitted for an ARM control-plane resource or as a convenience alternative to AzAPI."
- Rationale given: retry and timeout handling, plan-time pre-flight validation, same-day access to new Azure features, and alignment with Bicep and ARM resource identifiers.
- The spec page was last committed Aug 20, 2026. It does not say when the requirement started.
- The AVM solution-development lab warns: "This lab demonstrates older AVM Terraform modules built on the AzureRM provider." It also says "A solution root may configure AzureRM only when a currently published AVM dependency requires it; direct supporting Azure resources must still use AzAPI." — [AVM: Terraform solution development](https://azure.github.io/Azure-Verified-Modules/usage/solution-development/terraform/)

**Microsoft's stated advantages of AVM**
- The lab says AVM modules offer "Simplified Resource Configuration," "Built-in Recommended Practices," "Consistent Outputs," and "Reduced Boilerplate Code" compared with "writing raw Terraform templates." — [AVM: Terraform solution development](https://azure.github.io/Azure-Verified-Modules/usage/solution-development/terraform/)
- Microsoft Learn has AVM-based Terraform quickstarts, such as a production-ready AKS cluster. — [Deploy AKS using Terraform with AVM](https://learn.microsoft.com/azure/aks/deploy-cluster-terraform-verified-module)

**HashiCorp position**
- HashiCorp's style guide recommends modules for grouping related resources and pinning module versions. It says nothing about AVM, and does not discourage raw resources in a root module. — [Terraform style guide](https://developer.hashicorp.com/terraform/language/style)

### Inferences
- For a small, single-stack app environment written directly with `azurerm` 5.8, neither vendor's guidance says the approach is wrong.
- AVM's selling point is pre-baked WAF defaults: diagnostics, locks, RBAC and private endpoint interfaces. The repo already hand-codes most of the security-relevant defaults: managed identity, shared keys off, Entra-only SQL and Cosmos DB.
- Switching to AVM in 2026 means four things:
  1. Adding the AzAPI provider, since new and current AVM modules are AzAPI-first.
  2. Accepting 0.x modules where minor bumps may break.
  3. Depending on an orphaned Key Vault module.
  4. Changing the call surface, since current modules use `parent_id`, not `resource_group_name`.
- A defensible position: keep raw `azurerm` for this repo and use AVM module source as a reference for WAF-aligned settings. Revisit when the relevant modules reach 1.0.
- If the team wants to follow Microsoft's direction strictly, the AzAPI-first AVM spec is a signal that Microsoft's own IaC tooling is moving away from AzureRM-only code. That is an inference; I found no Microsoft statement deprecating azurerm for customer workloads.

### Gaps
- I found no explicit Microsoft or HashiCorp statement recommending AVM over raw provider resources for a small workload.
- I found no statement on when the AVM AzAPI-only requirement took effect, or whether existing azurerm-based AVM modules will be migrated or deprecated.
- I could not confirm whether the specific modules listed above are already AzAPI-based or still azurerm-based.
- I did not verify that `azurerm` 5.8.0 exists or what its feature set is.

## Q4. Microsoft best practice for Terraform state in Azure Storage (auth, versioning, soft delete, locks, network, account topology); is a public, Entra-only state account acceptable with Microsoft-hosted agents?

### Takeaway
**Verdict: partially confirms.** The data-plane and data-protection settings match or exceed vendor guidance:
- Entra ID auth with shared keys disabled
- container-scoped RBAC
- blob versioning
- blob and container soft delete at 30 days
- a CanNotDelete lock

The deliberate divergence is network exposure. Microsoft's state tutorial says to restrict network access "in a production deployment," and both ALZ bootstraps default to private endpoints with self-hosted agents. However, Microsoft's own ALZ accelerator leaves the state account publicly reachable (with shared keys disabled) when Microsoft-hosted agents are chosen. So a public, Entra-only account is a supported, documented trade-off, not an anti-pattern.

Microsoft's recommended alternative is Managed DevOps Pools (or self-hosted or scale-set agents) with private networking.

### Cited Findings
**Authentication**
- In the HashiCorp `azurerm` backend docs, Entra ID (`use_azuread_auth = true`) is labeled "(Recommended)," and OpenID Connect / workload identity federation is also marked recommended.
- For Access Key and SAS Token: "Terraform retains this method for backwards compatibility, we do not recommend it for new workloads."
- Source: [Terraform: azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- Microsoft's state tutorial uses an access key, but adds: "In a production deployment, evaluate the available authentication options supported by the azurerm backend and use the most secure option for your use case." — [Learn: Store Terraform state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage)
- **Dated:** the tutorial's samples pin `azurerm ~>3.0`, use `Standard_LRS`, and show a single `tfstate` container. It is a getting-started sample, not a production reference.

**Network**
- The same tutorial: "In this example, public network access is allowed to this Azure storage account. In a production deployment, restrict access to this storage account by using a storage firewall, service endpoint, or private endpoint." — [Learn: Store Terraform state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage)
- It also says: "Terraform state is stored in plain text and might contain secrets. If you don't secure the state correctly, unauthorized users can access systems and cause data loss." — [Learn: Store Terraform state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage)

**Locking**
- "This backend supports state locking and consistency checking with Azure Blob Storage native capabilities." — [Terraform: azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- "Azure Storage blobs are automatically locked before any operation that writes state." — [Learn: Store Terraform state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage)
- The backend also offers an optional `snapshot = true` setting, which snapshots the state blob before use. — [Terraform: azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)

**Data protection**
- Microsoft's basic recommendations: (1) an Azure Resource Manager lock on the storage account, (2) container soft delete, (3) blob soft delete. — [Learn: Blob data protection overview](https://learn.microsoft.com/azure/storage/blobs/data-protection-overview)
- "Blob storage customers storing critical data should enable soft delete and versioning for layered protection against unintended deletions and overwrites." — [Learn: Choosing between blob soft delete and versioning](https://learn.microsoft.com/azure/storage/blobs/soft-delete-vs-versioning-options)
- "Microsoft recommends a minimum retention period of seven days." — [Learn: Enable soft delete for blobs](https://learn.microsoft.com/azure/storage/blobs/soft-delete-blob-enable)
- An ARM lock "Doesn't protect containers or blobs in the account from being deleted or overwritten." — [Learn: Azure Storage data protection best practices](https://learn.microsoft.com/troubleshoot/azure/azure-storage/blobs/recovery/data-protection-backup-recovery)
- Versioning "Doesn't protect against container or account deletion … Recovering from that deletion requires container soft delete. Protecting against account deletion requires a resource lock." — [Learn: Blob versioning](https://learn.microsoft.com/azure/storage/blobs/versioning-overview#known-limitations)

**ALZ platform accelerator bootstrap (Azure DevOps): defaults from the source code**
- `use_private_networking` defaults to `true`: "Whether to use private networking for agent-to-storage communication … When true, configures private endpoints."
- `use_self_hosted_agents` defaults to `true`. When it is false, Microsoft-hosted agents are used.
- `allow_storage_access_from_my_ip` defaults to `false`: "We recommend this is kept off for security."
- `storage_account_replication_type` defaults to `"ZRS"`, described as "recommended for high availability."
- Source: [accelerator-bootstrap-modules: alz/azuredevops/variables.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/alz/azuredevops/variables.tf)
- The same bootstrap's storage account sets `shared_access_key_enabled = false` and:
  `public_network_access_enabled = var.use_private_networking && var.use_self_hosted_agents && !var.allow_storage_access_from_my_ip ? false : true`
  With private networking it adds network rules `default_action = "Deny"` and `bypass = ["None"]`. It creates one state container and grants "Storage Blob Data Contributor" on the container to each identity. That file defines no resource lock; versioning and soft delete are configurable variables. — [accelerator-bootstrap-modules: modules/azure/storage.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/modules/azure/storage.tf)
- The ALZ docs list "[Optional] Virtual network, subnets, private DNS zone and private endpoint" and "[Optional] Container Instances hosting Azure DevOps Agents" as bootstrap components. — [ALZ accelerator docs](https://azure.github.io/Azure-Landing-Zones/accelerator/)

**ALZ application landing zone CI/CD bootstrap (AVM pattern)**
- It "provisions a hardened storage account (private endpoint, no public access) for Terraform remote state per environment."
- It "deploys self-hosted agents on either" Azure Container Instances (the default) or Azure Container Apps.
- "set `agent_use_self_hosted = false` to use Microsoft-hosted agents."
- Source: [AVM ptn: ALZ application LZ CI/CD bootstrap (Azure DevOps) README](https://raw.githubusercontent.com/Azure/terraform-azure-avm-ptn-alz-application-landing-zone-cicd-bootstrap-azure-devops/refs/heads/main/README.md)

**Microsoft-hosted agents and network restrictions**
- "You can't use private connections such as ExpressRoute or VPN to connect Microsoft-hosted agents to your corporate network. The traffic between Microsoft-hosted agents and your servers will be over public network." — [Learn: Microsoft-hosted agents, Networking](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#networking)
- Agent IP ranges change weekly. To get the complete list, you must "allow list the IP ranges for *all* of the regions mapped to your geography." — [Learn: Microsoft-hosted agents, Networking](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#networking)
- Allowing that range "may increase your exposure as the range of IP addresses is rather large and since machines in this range can belong to other customers as well." — [Learn: Microsoft-hosted agents, Security](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#security)
- "If allowing the entire geography is a concern, we recommend using the Microsoft Managed DevOps Pools. Alternatively, you can also use Azure Virtual Machine Scale Set agents." — [Learn: Allowed IP addresses and domain URLs](https://learn.microsoft.com/azure/devops/organizations/security/allow-list-ip-url?view=azure-devops#ip-addresses-and-range-restrictions)
- For Storage firewall errors with hosted agents, Microsoft lists three workarounds: add the hosted-agent IP ranges; "use Azure CLI to update the network ruleset for your Azure Storage account right before you access storage, and then restore the previous ruleset"; or use self-hosted, scale-set or Managed DevOps Pools agents. — [Learn: Microsoft-hosted agents FAQ](https://learn.microsoft.com/azure/devops/pipelines/agents/hosted?view=azure-devops#faq)

**Managed DevOps Pools (MDP)**
- MDP "Can access resources in your company network or isolate your workload to only access specific endpoints." Its VMs "live in a Microsoft Azure subscription. They don't live in your own Azure subscription." — [Learn: Managed DevOps Pools overview](https://learn.microsoft.com/azure/devops/managed-devops-pools/overview?view=azure-devops)
- MDP pricing is the Azure resources it uses plus "the standard Azure DevOps Services parallel jobs pricing for self-hosted agents." — [Learn: Managed DevOps Pools pricing](https://learn.microsoft.com/azure/devops/managed-devops-pools/pricing?view=azure-devops)

**Account topology**
- HashiCorp notes that per-deployment backends "often [have] different credentials and access controls." — [Terraform CLI: Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- The ALZ platform bootstrap uses one account and one container. — [modules/azure/storage.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/modules/azure/storage.tf)
- The ALZ application-LZ bootstrap uses a state storage account per environment. — [README](https://raw.githubusercontent.com/Azure/terraform-azure-avm-ptn-alz-application-landing-zone-cicd-bootstrap-azure-devops/refs/heads/main/README.md)

**Repo facts, for comparison**
- [bootstrap/New-TfStateBackend.ps1](C:/Users/Rorro/source/repos/azure-terraform/bootstrap/New-TfStateBackend.ps1) sets:
  - `AllowSharedKeyAccess = $false`, `MinimumTlsVersion = 'TLS1_2'`, `Standard_RAGRS`, `PublicNetworkAccess = 'Enabled'`
  - network `DefaultAction Allow`, or `Deny` plus optional IP rules when IPs are supplied
  - blob versioning on, blob soft delete at 30 days, container soft delete at 30 days
  - a `CanNotDelete` lock on the resource group
- [bootstrap/New-AppEnvironment.ps1](C:/Users/Rorro/source/repos/azure-terraform/bootstrap/New-AppEnvironment.ps1) grants Storage Blob Data Contributor scoped to `.../containers/tfstate-<env>`.

### Inferences
- **Where the repo matches or exceeds guidance:**
  - Entra auth with shared keys disabled: matches HashiCorp "Recommended" and the ALZ bootstrap.
  - Container-scoped RBAC: matches the ALZ bootstrap.
  - Blob versioning plus blob and container soft delete at 30 days: exceeds Microsoft's 7-day minimum and matches the "critical data" advice.
  - Resource-group `CanNotDelete` lock: covers Microsoft's "lock the storage account" step, since locks inherit.
  - TLS 1.2 minimum: good practice.
  - RA-GRS: diverges from the ALZ default (ZRS) but gives cross-region read access. This is a resilience choice, not a guidance violation. ZRS protects against zone failure within a region; RA-GRS adds secondary-region read.
- **Where the repo diverges:**
  - The public network endpoint contradicts the Learn tutorial's "production deployment" advice and the default posture of both ALZ bootstraps.
  - Microsoft's accelerator does fall back to `public_network_access_enabled = true` whenever Microsoft-hosted agents are selected, with `shared_access_key_enabled = false`. That is the same posture as this repo, which makes the repo's choice consistent with a Microsoft-supported configuration.
  - The residual risk is that the data plane is reachable from the internet. Any leaked Entra token or misassigned role is then exploitable from anywhere, and Defender for Storage or logs become the main detective control.
- **Microsoft's documented upgrade path**, in order of effort:
  1. MDP with a VNet-injected pool plus a private endpoint on the state account. Microsoft-managed, billed as self-hosted parallel jobs plus Azure compute.
  2. Self-hosted agents on ACI or ACA, as the ALZ bootstraps do.
  3. A temporary firewall rule opened per job via Azure CLI. This is documented as a workaround, and the job identity needs network-rule write permission.
- **Per-subscription account with a container per env** gives per-env access isolation through container-scoped RBAC. Once prod sits in its own subscription it becomes effectively per-environment. If several environments share a subscription, it is weaker than ALZ application-LZ's per-environment account. Account-level settings (network, keys, lock) and the blast radius of a storage-account-scoped role assignment are shared across those environments.

### Gaps
- I found no Microsoft Learn page that sets a rule on one state account per environment vs. per subscription. The evidence is limited to the two ALZ bootstraps, which differ.
- The ALZ docs list private networking and self-hosted agents as "[Optional]" and give no rationale. The rationale ("kept off for security") appears only in variable descriptions.
- I did not research Azure Storage network security perimeter as an alternative network control for state accounts.
- I did not verify the ALZ bootstrap's default values for `storage_account_blob_versioning_enabled` and the soft-delete retention days.

## Q5. Do saved plan files contain sensitive values in plaintext? Guidance on publishing plan files as pipeline artifacts; ephemeral values / write-only arguments as mitigation

### Takeaway
**Verdict: partially confirms.** Marking the variable `sensitive = true` and passing it as an environment variable is correct for keeping it out of logs. However, the saved plan published as a pipeline artifact contains the IP allowlist in cleartext. It also contains the full configuration and the prior state.

HashiCorp says to treat saved plans as "potentially-sensitive artifacts." Ephemeral variables (Terraform 1.10+) and write-only arguments (1.11+) keep values out of plan and state. They cannot help here, because the allowlist feeds ordinary firewall-rule arguments that are persisted in state by design.

Microsoft's Azure Pipelines secret guidance also advises against storing structured data such as JSON as a single secret, which is how `allowedIpAddresses` is stored.

### Cited Findings
**What a saved plan contains**
- "If your plan includes any sort of sensitive data, even if obscured in Terraform's terminal output, it will be saved in cleartext in the plan file." — [Terraform CLI: plan](https://developer.hashicorp.com/terraform/cli/commands/plan)
- The plan file contains "your full configuration, all of the values associated with planned changes," plus "all of the plan options including the input variables." It adds: "You should therefore treat any saved plan files as potentially-sensitive artifacts." — [Terraform CLI: plan](https://developer.hashicorp.com/terraform/cli/commands/plan)
- "When using a saved plan, you cannot specify any additional planning modes or options." That means `-var` can't be passed at apply time; values come from the plan. — [Terraform CLI: apply](https://developer.hashicorp.com/terraform/cli/commands/apply)

**Passing plans between pipeline stages**
- HashiCorp's automation tutorial describes archiving the working directory and plan as "a 'build artifact' within the chosen orchestration tool."
- It also says: "The plan file contains a full copy of the configuration, the state that the plan applies to … the archived working directory containing the plan file should be protected accordingly." — [HashiCorp tutorial: Running Terraform in automation](https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform)

**What `sensitive = true` does and does not do**
- "If you add secret values directly to your configuration, Terraform stores those secrets in its state and plan files." — [Terraform: Manage sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- "Terraform stores values with the `sensitive` argument in both state and plan files, and anyone who can access those files can access your sensitive values." — [Terraform: Manage sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- From the variable block docs: `sensitive` "prevents Terraform from showing a variable block's value in CLI output," and it "redacts its value in plan and apply logs," but "Terraform still records sensitive values in state." — [Terraform: variable block](https://developer.hashicorp.com/terraform/language/block/variable)

**Ephemeral values and write-only arguments**
- "Ephemeral values are available at runtime, but Terraform omits them from state and plan files entirely." Ephemeral variables need Terraform 1.10 or later; write-only arguments need 1.11 or later. — [Terraform: Manage sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- Ephemeral variables can be referenced only from these places:
  - an ephemeral `output`
  - another ephemeral `variable`
  - a write-only argument in a resource
  - an `ephemeral` resource block
  - a `provider` block
  - a provisioner and its connection
  - "If another expression references a variable with the `ephemeral` argument, that expression also implicitly becomes ephemeral."
  - Source: [Terraform: variable block](https://developer.hashicorp.com/terraform/language/block/variable)
- "Write-only arguments are only available during the current Terraform operation, and Terraform does not store them in state or plan files." — [Terraform: Ephemeral resources and write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/ephemeral)

**Backend config in plans**
- `-backend-config` values are written into the `.terraform` directory and into plan files. — [Terraform: Backend configuration](https://developer.hashicorp.com/terraform/language/backend)

**Azure Pipelines secret handling**
- "Never echo secrets as output, and don't pass secrets on the command line. Instead, it's best to map your secrets into environment variables." — [Learn: Secrets in Azure Pipelines](https://learn.microsoft.com/azure/devops/pipelines/security/secrets?view=azure-devops)
- "Avoid using structured data formats like JSON, XML, or YAML to encapsulate secret values … Instead, create individual secrets for each sensitive value. This approach ensures better redaction accuracy." — [Learn: Secrets in Azure Pipelines](https://learn.microsoft.com/azure/devops/pipelines/security/secrets?view=azure-devops)

**Repo facts**
- [pipelines/templates/terraform-environment.yml](C:/Users/Rorro/source/repos/azure-terraform/pipelines/templates/terraform-environment.yml):
  - maps `TF_VAR_allowed_ip_addresses: $(allowedIpAddresses)` (a JSON list, per line 10's comment)
  - runs `terraform plan -out=tfplan`
  - publishes `terraform/tfplan` as artifact `tfplan-<env>`
  - downloads it in the apply stage
- In [terraform/variables.tf](C:/Users/Rorro/source/repos/azure-terraform/terraform/variables.tf), the variable is `sensitive = true`.
- In [terraform/locals.tf](C:/Users/Rorro/source/repos/azure-terraform/terraform/locals.tf), it feeds `local.allowed_cidrs` and `local.firewall_ip_rules` for the Key Vault, Storage, SQL and Cosmos DB firewalls.

### Inferences
- **The allowlist is in cleartext twice:**
  - In the `tfplan` artifact, as an input variable and in the planned firewall-rule values.
  - In the remote state, as firewall-rule attributes.
- **Ephemeral is not a mitigation for this variable.** Firewall `ip_rules` and `ip_range_filter` arguments are not write-only, and an ephemeral variable cannot be assigned to an ordinary managed-resource argument. Write-only and ephemeral features suit secrets that Terraform passes through without tracking, such as passwords (`*_wo` arguments). They don't suit configuration that Terraform must reconcile.
- **Practical options consistent with vendor guidance:**
  1. Treat the plan artifact as sensitive. Restrict who can view or download pipeline runs and artifacts, and shorten run retention.
  2. Re-run `plan` inside the approved apply job instead of shipping the plan file. This trades exact plan reuse for no plan artifact, and changes the reviewed-plan guarantee.
  3. Accept the exposure, because IP addresses are low sensitivity compared with credentials. They are already visible to anyone with Reader on the protected resources' firewall settings.
- The repo's state is already protected by Entra RBAC, so the plan artifact is the weaker of the two copies: it inherits Azure DevOps project permissions, not Azure RBAC.
- Storing the allowlist as one JSON-valued secret variable goes against Microsoft's "don't use structured data as secrets" advice, which exists because log redaction is less reliable for JSON. Masking matters less here, since `sensitive = true` already redacts Terraform output, but it is a documented divergence.

### Gaps
- I did not find a Microsoft Learn page that addresses Terraform plan files as Azure Pipelines artifacts specifically.
- I did not find authoritative documentation on which Azure DevOps roles can download pipeline artifacts by default. The default-permissions page I found shows Readers can view release pipelines but does not mention artifacts.
- I could not confirm from current docs whether ephemeral variables set at plan time must be re-supplied at apply time when using a saved plan.
- The `terraform plan` page doesn't say whether `TF_VAR_` values specifically are stored. It says "input variables" are stored without naming their source, and the apply page confirms planning options can't be re-specified.

## Q6. Is the "hash of resource group ID" suffix for globally unique names consistent with CAF naming guidance?

### Takeaway
**Verdict: partially confirms.** CAF itself doesn't prescribe a hash suffix; it uses an instance number (`001`). Microsoft's Bicep and ARM guidance does explicitly recommend combining a meaningful prefix with a deterministic hash seeded by the resource group ID, and calls the resource group ID "a good option for the seed value." That matches the repo's approach.

Two divergences from CAF's examples:
- **Component order:** CAF puts the resource-type abbreviation first (`app-workload1-prod-001`). The repo puts the workload first (`andes-api-dev-xxxx`).
- **Hash length:** the repo uses 4 hex characters, where Microsoft's `uniqueString()` produces 13. Microsoft warns that even 13 characters are not globally unique.

### Cited Findings
**CAF naming guidance**
- CAF's naming components are resource type, workload/application/project, environment, region, and instance number (`01`, `001`). — [CAF: Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- CAF says to "Standardize component order" and use hyphen delimiters where allowed. — [CAF: Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- CAF's example formats put the type first:
  - web app: `app-<workload>-<environment>-<###>`, e.g. `app-workload1-prod-001.azurewebsites.net`
  - Cosmos DB: `cosmos-<workload>-<environment>`
  - storage account: `st<workload><###>`, e.g. `stworkload1data001`
  - Source: [CAF: Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- "Understand name permanence. Most Azure resource names can't be changed after creation. Include only information that remains constant in the name." — [CAF: Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- CAF presents itself as "a foundation that you can adapt to align with your organizational requirements." — [CAF: Define your naming convention](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)

**Microsoft guidance on hash suffixes**
- Bicep best practices: `uniqueString()` "is useful for creating unique resource names … Passing in the resource group ID means the string is the same on every deployment to the same resource group, but different when you deploy to different resource groups or subscriptions." The example given is `'${shortAppName}-${shortEnvironmentName}-${uniqueString(resourceGroup().id)}'`. — [Learn: Best practices for Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/best-practices#variables)
- Bicep name generation pattern: "In most situations, the fully qualified resource group ID is a good option for the seed value for the `uniqueString` function." Also: "Avoid changing the seed values … after resources have been deployed." — [Learn: Name generation pattern](https://learn.microsoft.com/azure/azure-resource-manager/bicep/patterns-name-generation#considerations)
- The same pattern lists the name requirements as Unique, Deterministic, Meaningful, Distinct for each environment, and Valid. It notes: "If you have a strict naming convention to follow and the names it generates are distinctive and unique, you might not need to follow this pattern." It references CAF for organizational naming. — [Learn: Name generation pattern](https://learn.microsoft.com/azure/azure-resource-manager/bicep/patterns-name-generation)
- ARM `uniqueString`: "The returned value isn't a random string but rather the result of a hash function. The returned value is 13 characters long. It isn't globally unique. You might want to combine the value with a prefix from your naming convention." — [Learn: ARM template string functions](https://learn.microsoft.com/azure/azure-resource-manager/templates/template-functions-string#uniquestring)

**Other Microsoft naming conventions**
- The ALZ accelerator's naming templates are type-first, with region and a numeric postfix, e.g. `id-{{service_name}}-{{environment_name}}-{{azure_location}}-plan-{{postfix_number}}`. — [accelerator-bootstrap-modules: alz/azuredevops/variables.tf](https://raw.githubusercontent.com/Azure/accelerator-bootstrap-modules/main/alz/azuredevops/variables.tf)

**Repo facts**
- [terraform/locals.tf](C:/Users/Rorro/source/repos/azure-terraform/terraform/locals.tf) sets `suffix = substr(sha1(data.azurerm_resource_group.this.id), 0, 4)`.
- Example names: `${var.name_prefix}-api-${var.environment}-${local.suffix}` and `${var.name_prefix}st${var.environment}${local.suffix}`.

### Inferences
- **Deterministic suffix seeded by resource group ID:** directly aligned with Microsoft's Bicep and ARM guidance. It is stable across state loss and redeploys, and distinct per environment and subscription. This is the Terraform equivalent of `uniqueString(resourceGroup().id)`.
- **Four hex characters give 65,536 values,** compared with 13 base-32 characters from `uniqueString`. Combined with the `andes` prefix and the env token, collisions in the global namespace (web apps, storage, Key Vault, SQL, Cosmos DB) are unlikely but more plausible than with a longer hash.
  - Storage account names have room for more: `andesst` + `dev` + 4 characters is 14 of the 24 allowed. Longer env names like `staging` still fit.
  - Lengthening the suffix later would rename, and so recreate, existing resources. Microsoft warns against changing the seed or format after deployment.
- **Order `<prefix>-<type>-<env>`:** differs from CAF's type-first examples. CAF frames ordering as an organizational choice ("Standardize component order"), so this is a style divergence, not a violation.
- **Abbreviations:** the repo's type tokens (`kv`, `sql`, `cosmos`, `st`, `api`, `ui`) partly match CAF's abbreviation list. `api` and `ui` are workload components, not resource-type abbreviations, where CAF would use `app`.
- **No region token:** CAF lists region as optional. Adding it matters only if multi-region deployments are planned.

### Gaps
- CAF's naming page does not mention hash or random suffixes at all. Support for the pattern comes from the Bicep and ARM documentation, not CAF itself.
- I did not check the separate CAF abbreviations page for the exact recommended abbreviations for each resource type in the repo.
