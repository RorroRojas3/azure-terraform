# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Terraform for the dev environment:
  - Windows web apps for the .NET 10 API and the Angular 22 UI, which IIS serves as a static build.
  - Key Vault, Azure SQL (Basic), Cosmos DB (serverless), geo-redundant Blob Storage, and shared Application Insights.
  - The API reaches every data service through its user-assigned managed identity, with no keys or passwords.
  - Data services accept only the IPs in `allowed_ip_addresses` and the API's subnet. The variable has no default and rejects `0.0.0.0` and private ranges.
- Admin-only bootstrap:
  - `New-TfStateBackend.ps1` creates the geo-redundant Terraform state backend and an admin-only container for the bootstrap's own state.
  - The `bootstrap/terraform` module creates each environment from one `environments` entry: resource group, state container, a read-only plan identity and a write-capable apply identity (each scoped to that environment), Azure DevOps service connections with their federated credentials, the apply connection's checks (main-only branch control, exclusive lock, optional approval), the Azure DevOps Environment and the SQL admin group. One `terraform apply` does it all, signed in with `az login` and no secrets.
- An Azure DevOps pipeline that plans on pull requests with the read-only identity. Applies run on `main` only, through a lockable, approvable apply service connection, and then grant the API identity SQL access. It authenticates with workload identity federation.
- Infrastructure guide: setup, adding environments, and a production checklist (`docs/infrastructure.md`).

### Security

- Plan and apply use separate identities per environment, so a pull request branch can no longer run code with write access. Previously PR plans ran as the write-capable identity, and a same-repo branch runs its own pipeline YAML before review. PR plans now run as a read-only identity with no checks. The apply identity is reachable only through a `main`-only service connection with an exclusive lock and optional approval, and it can't assign roles to itself or to the plan identity.
- The saved plan artifact is published only on `main`, because saved plans contain configuration and state values in cleartext and only `main` plans are applied.
