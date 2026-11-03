# Production readiness

**Prod is not production-hardened.** The owner chose not to harden it yet, so `prod` runs with dev's settings: the same B1 plan, the same Basic SQL database, the same short retention, and the same public endpoints behind an IP allowlist. Treat it as a fifth non-production environment until the work below is done. Don't put customer data in it that you can't afford to lose.

This page lists every control that differs from a hardened production setup, what each takes to change, and an ordered go-live checklist. It describes the design as coded, so check the tfvars if you need today's exact values.

## Control status

"Variable" means the change is a value in `terraform/environments/prod/terraform.tfvars`. "Code" means `terraform/` needs a new resource or variable first.

| Control | Status today | What it takes |
| --- | --- | --- |
| App Service | B1 in every environment: one instance, no deployment slots, no autoscale, no zone redundancy | Variable: `app_service_plan_sku` (P0v3 or higher, or S1+ for slots). Autoscale, slots and zone redundancy need code |
| SQL | Basic, 2 GB. Prod backups use `Local` redundancy, 7-day point-in-time restore, no long-term retention | Variable: `sql_database_sku` (S0 or higher, or General Purpose), `sql_database_max_size_gb`, `sql_backup_storage_redundancy = "Geo"` (the module default), `sql_short_term_retention_days`. Long-term retention has no variable, so it needs code |
| Key Vault | Purge protection off, 7-day soft-delete retention | Variable: `key_vault_purge_protection_enabled = true`, `key_vault_soft_delete_retention_days = 90` (both are the module defaults). Retention is fixed when the vault is created, so 90 days needs a new vault, and purge protection is **irreversible once turned on**. See [below](#key-vault-purge-protection) |
| Cosmos DB | Serverless, single region, `Continuous7Days` backup | Variable: `cosmos_serverless = false` and `cosmos_autoscale_max_throughput`. Switching capacity mode is hard later, so decide before data lands. Multi-region, zone redundancy and a longer backup tier need code |
| Storage | GRS, versioning on, blob and container soft delete 7 days (hard-coded in `storage.tf`) | Variable: `storage_replication_type` (for example `GZRS`). Longer soft-delete retention needs code |
| Log Analytics | 1 GB per day cap in prod, 30-day retention | Variable: `log_analytics_daily_quota_gb` (`-1` for no cap), `log_analytics_retention_days`. A hit cap stops ingestion for the rest of the day, audit logs included |
| Alerts and action groups | None | Code |
| Diagnostic settings | Key Vault audit logs only | Code: SQL, Cosmos DB, Storage and App Service need their own diagnostic settings |
| Network | Public endpoints behind an IP allowlist and service endpoints. Prod's allowlist holds a personal IP | Private endpoints, public access disabled, and Managed DevOps Pools with VNet injection. See [below](#network-and-private-endpoints) |
| Resource lock | **No `CanNotDelete` lock on `andes-softsol-rg-prod`** | An administrator adds it by hand. See [below](#resource-lock) |
| Approvals | One approver, who may approve their own runs | Add approvers; turn off self-approval once more than one person can merge |
| Branch protection | PR plus the `andes-infra` check, no required review (one maintainer) | Require at least one approving review when a second maintainer exists ([Pipeline](pipeline.md#branch-protection-on-main)) |
| Subscription | Prod shares the subscription and the state account with the other environments | See [below](#shared-subscription) |
| Defender for Cloud | Not enabled by code | An administrator enables plans for SQL, Storage, Key Vault and App Service at subscription level |
| Budget | Commented out in every tfvars file | Variable: `monthly_budget_amount`, `budget_start_date`, `budget_alert_emails` |
| Unused allowlisted roles | `Monitoring Metrics Publisher` and `Storage Blob Data Reader` are in `assignable_role_names`, but `terraform/` never assigns them | Remove them from `assignable_role_names` and re-apply the bootstrap (least-privilege cleanup), or start using them |
| Edge | No custom domain, WAF or Front Door. Both apps answer on `azurewebsites.net` | Code |
| Recovery objectives | No documented RTO or RPO. Single region | Define them, then design for them. Nothing in the repo implements failover |
| Secrets | None exist: workload identity federation for the pipeline, managed identity for the API | Met |

## Key Vault purge protection

Two settings, two different constraints:

- **Soft-delete retention is set once, at creation.** Azure (and the azurerm provider) won't change `soft_delete_retention_days` on an existing vault. To move prod from 7 to 90 days, set both variables in prod's `terraform.tfvars` *before* the vault is first created. If it already exists, the vault has to be recreated. Do it locally, as break-glass ([Manual deployment, Part 6b](manual-deployment.md#part-6b-deploy-by-hand-from-a-workstation)), after moving any secrets you added:

  1. Destroy only the vault. Never run a plain `terraform destroy` here; it would destroy all of prod, data included.

     ```powershell
     terraform -chdir=terraform init -reconfigure -backend-config=environments/prod/backend.hcl
     terraform -chdir=terraform destroy -target=azurerm_key_vault.this -var-file=environments/prod/terraform.tfvars
     ```

     A targeted destroy also destroys everything that references the vault. Read the plan: it includes the vault's diagnostic setting and role assignments, and the API web app, whose `KeyVault__Uri` setting comes from the vault. You redeploy the API afterwards.
  2. Purge the soft-deleted vault while purge protection is still off: `az keyvault purge --name andes-softsol-kv-prod --location centralus`. This step is mandatory. The provider recovers soft-deleted vaults (`recover_soft_deleted_key_vaults = true`), so without the purge the next apply silently brings back the old 7-day vault.
  3. Set both variables in prod's `terraform.tfvars`, merge, and let the pipeline apply. It creates a new vault and the API web app again.
- **Purge protection can't be turned off once enabled.** It also changes how a rebuild works: a deleted vault keeps its name for the full retention period and can't be purged, so [the purge steps in the rebuild runbook](manual-deployment.md#option-b-rebuild-from-zero) stop working. Turn it on when you are sure about the environment's names.

## Resource lock

No `CanNotDelete` lock protects `andes-softsol-rg-prod`. The pipeline identities can't manage locks, so an administrator adds it:

```powershell
az lock create --name protect-prod --lock-type CanNotDelete --resource-group andes-softsol-rg-prod
```

A lock also blocks Terraform from deleting any resource in the group. An apply that removes or replaces a resource (changing an IP removes the old SQL firewall rule, for example) fails until an administrator removes the lock. Plan for that before you add it.

Only the state group carries a lock today: `New-TfStateBackend.ps1` adds `protect-terraform-state` to `andes-softsol-rg-tfstate`.

## Network and private endpoints

Today Key Vault, Storage, SQL and Cosmos DB have public endpoints that admit only the API's subnet and allowlisted IPs. For prod, move to private endpoints with public network access disabled. Microsoft's networking guide maps production workloads to private endpoints ([Private access to Azure PaaS services](https://learn.microsoft.com/azure/networking/design-guide/private-platform-as-a-service)), and the Microsoft cloud security benchmark rates it a must-have ([NS-2](https://learn.microsoft.com/security/benchmark/azure/mcsb-v2-network-security#ns-2-secure-cloud-native-services-with-network-controls)).

That changes the prod pipeline:

- Microsoft-hosted agents can't reach private endpoints.
- The SQL grant's temporary firewall rule stops working once SQL refuses public traffic.
- Prod needs [Managed DevOps Pools with VNet injection](https://learn.microsoft.com/azure/devops/managed-devops-pools/configure-networking?view=azure-devops#agents-injected-into-existing-virtual-network): a subnet delegated to `Microsoft.DevOpsInfrastructure/pools`, the pool and VNet in the same region, and an address plan that avoids `172.17.0.0/16`.
- Staging should mirror prod's network setup, so private DNS, agents and the SQL grant are tested before prod.

The [address plan](architecture.md#address-plan) already avoids the Windows App Service ranges that would break private endpoints. None of this is implemented in code.

## Shared subscription

Prod shares the subscription, the resource group `andes-softsol-rg-tfstate` and the state account with the other environments. [The trade-off](architecture.md#prod-shares-the-subscription) is accepted, and it carries real exposure: subscription Owners and Contributors control prod, and subscription-level Defender plans cover and bill every environment.

Moving prod to its own subscription is a rebuild of the foundations, not a setting:

- The new subscription needs its own state backend (`New-TfStateBackend.ps1`) and its own bootstrap.
- Storage account names are global, so the second backend needs a different `-NamePrefix`, and with it different names everywhere.
- The prod pipeline connections and tfvars change to match.

## Go-live checklist

Work through these in order. Earlier items are decisions that later items depend on.

1. **Decide the recovery objectives.** Write down the RTO and RPO the business needs. Everything below follows from them.
2. **Decide the subscription.** Keep prod in the shared subscription or move it. Moving it is the largest change, so settle it first.
3. **Decide Cosmos DB capacity mode** (serverless or autoscale), before any data lands.
4. **Size prod.** Set a production App Service SKU, a SQL tier above Basic, and `sql_backup_storage_redundancy = "Geo"` in prod's tfvars.
5. **Turn on Key Vault protection:** 90-day retention and purge protection, once you accept that purge protection is irreversible. Retention only takes effect on a new vault, so set both before prod's vault is first created, or recreate it first ([details](#key-vault-purge-protection)).
6. **Raise storage redundancy** if the RPO needs it, and set Log Analytics retention and cap so audit logs aren't dropped.
7. **Add the missing code:** alerts and action groups, diagnostic settings for SQL, Cosmos DB, Storage and App Service, and SQL long-term retention if the RPO needs it.
8. **Harden the network.** If you choose private endpoints, stand up Managed DevOps Pools with VNet injection, test the whole path in staging, then apply to prod. Replace the personal IP in prod's `allowed_ip_addresses` (use `[]` once private endpoints are in).
9. **Do the administrator steps:** add the `CanNotDelete` lock on `andes-softsol-rg-prod`, enable Defender for Cloud plans, and set a prod budget.
10. **Clean up roles:** remove the two unused entries from `assignable_role_names`.
11. **Tighten governance.** Add a second approver for prod and reconsider self-approval. Require a review on `main` once a second maintainer exists. Confirm in **Pipelines → Environments → `andes-softsol-prod` → Approvals and checks** that an approver is listed, because a recreated Environment has none.
12. **Promote through the pipeline,** staging first, and read the prod plan before you approve it.
13. **Rehearse recovery.** Restore a SQL database to a point in time, restore an earlier state version ([Operations](operations.md#restore-an-earlier-state-version)), and walk through [the rebuild runbook](manual-deployment.md#part-8-rebuild-after-a-teardown-or-lost-bootstrap-state).
