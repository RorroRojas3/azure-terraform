# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Terraform for the dev environment:
  - Linux web apps for the .NET 10 API and the Angular 22 UI.
  - Key Vault, Azure SQL (Basic), Cosmos DB (serverless), geo-redundant Blob Storage, and shared Application Insights.
  - The API reaches every data service through its user-assigned managed identity, with no keys or passwords.
  - Data services accept only allowlisted IPs and the API's subnet.
- Admin bootstrap scripts:
  - One creates the geo-redundant Terraform state backend.
  - One creates each environment with a pipeline identity limited to that environment's resource group and state container.
- An Azure DevOps pipeline that plans on pull requests and applies on `main` through Azure DevOps Environments. It authenticates with workload identity federation and grants the API identity SQL access.
- Infrastructure guide: setup, adding environments, and a production checklist (`docs/infrastructure.md`).

### Security

- The firewall IP allowlist (`allowed_ip_addresses`) is no longer committed in `terraform.tfvars`, so developers' public IPs stay out of the repo.
  - The variable is `sensitive`: plan output and pipeline logs show `(sensitive value)`. It still has no default, so a run that omits it fails instead of removing everyone's firewall access. Because plans no longer show the addresses, validation now rejects `0.0.0.0` (which SQL and Cosmos DB treat as "all Azure datacenters"), loopback, link-local and private ranges.
  - The pipeline reads it from the secret `allowedIpAddresses` in a per-environment variable group, `andes-vg-<env>`, which must exist and be authorized before the next run. Locally, set `TF_VAR_allowed_ip_addresses`.
  - SQL firewall rules are now indexed (`allow-ip-0`, `allow-ip-1`, …), so the first apply on an existing environment replaces the current rule.
  - State and the saved plan artifact still contain the values.
