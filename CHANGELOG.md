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
  - The `bootstrap/terraform` module creates each environment from one `environments` entry: resource group, state container, a read-only plan identity and a write-capable apply identity (each scoped to that environment), Azure DevOps service connections with their federated credentials, the apply connection's checks (main-only branch control and exclusive lock), the Azure DevOps Environment and the SQL admin group. One `terraform apply` does it all, signed in with `az login` and no secrets.
- An Azure DevOps pipeline that plans on pull requests with the read-only identity. Applies run on `main` only, through a lockable apply service connection that only `main` can use, and then grant the API identity SQL access. It authenticates with workload identity federation.
- Four more environments, qa, uat, staging and prod, all in Central US with dev's sizing. The pipeline promotes a merge through dev, qa, uat, staging and prod in order: dev applies automatically, and each later environment waits for approval. Approvers are set by hand on each Azure DevOps Environment, not in Terraform, so a new or recreated Environment has none until you add them.
- Documentation set that replaces the single infrastructure guide, written for readers who don't know Terraform:
  - A `README.md` landing page with architecture diagrams, an environment table, a start-here table by role, prerequisites, validation commands and the contribution flow.
  - `docs/terraform-primer.md`, `docs/architecture.md`, `docs/manual-deployment.md`, `docs/pipeline.md`, `docs/operations.md`, `docs/application-integration.md` and `docs/production-readiness.md`.
  - New runbooks for deploying by hand from a workstation, recovering the state account after a teardown or lost bootstrap state, tearing an environment down in the right order, and restoring earlier state versions.
  - A production-readiness page: prod uses dev's settings, and it lists each control, what it takes to harden and an ordered go-live checklist. It also corrects the old claim that a `CanNotDelete` lock protects `andes-softsol-rg-prod`; none exists.

### Changed

- The first-time setup guide now shows who creates what and covers the steps that were easy to miss.
- Resources are now named with the `andes-softsol` company prefix (for example `andes-softsol-kv-dev`, `andessoftsolst<env>`, `andes-softsol-sc-<env>-apply`). Nothing was migrated; every environment was rebuilt from scratch. `name_prefix` now accepts 2-13 lowercase letters, digits or single dashes so Key Vault names fit 24 characters.
- Every pull request into `main` now runs the plans, because the PR trigger no longer filters by path. This lets every PR report the `andes-infra` check that branch protection requires.
- The infrastructure pipeline no longer batches CI runs. A run waiting at an approval still counts as running, so batching would have held every later merge back from dev.

### Security

- Plan and apply use separate identities per environment, so a pull request branch can no longer run code with write access. Previously PR plans ran as the write-capable identity, and a same-repo branch runs its own pipeline YAML before review. PR plans now run as a read-only identity with no checks. The apply identity is reachable only through a `main`-only service connection with an exclusive lock, and it can't assign roles to itself or to the plan identity. Approvals sit on each Azure DevOps Environment rather than the service connection, so a YAML change merged to `main` could skip them; branch protection on `main` is the safeguard, and reviews are optional while there is one maintainer.
- `main` now requires a pull request and a passing `andes-infra` check, and the rule applies to administrators too. Force pushes and deletions are blocked.
- The saved plan artifact is published only on `main`, because saved plans contain configuration and state values in cleartext and only `main` plans are applied.
