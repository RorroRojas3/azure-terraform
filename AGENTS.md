<!-- andes:begin v1.5.0 -->
# Andes engineering standards

Shared by Claude Code and GitHub Copilot. The `andes-init` skill manages this block and replaces it on refresh — put project-specific instructions after the `andes:end` marker (`andes-init` scaffolds those sections on first install).

## Communication & comments

- Lead with the answer or the change; no preamble, no restating the request. Don't re-summarize what the user already saw — report only what changed or went wrong. Match length to substance.
- Comment only what code cannot say: why a decision was made, constraints, non-obvious invariants, workarounds with links. Never narrate what code does or what changed. XML doc comments on public APIs are API documentation, not comments.

## Load the standards before you edit

Detailed standards live in skills that load on demand. Load the matching skill before writing or reviewing code:

| Working on | Load |
| --- | --- |
| Any `*.cs` | `csharp-standards`, plus `aspnet-rest-apis` (web APIs), `azure-functions-csharp` (Functions), `csharp-mcp-server` (MCP servers), `ef-core` (EF Core; `ef-core-base-entities` / `ef-core-enum-reference-tables` for entities and lookup tables), `csharp-async`, `csharp-docs` (public APIs) as the change needs; `dotnet-api-architecture` when adding, moving, renaming, or registering files, folders, or projects. Non-negotiables: Minimal APIs only (no controllers), FluentValidation only (no DataAnnotations), services query the `DbContext` directly (no repositories), primary constructors, collection expressions, `var`, and the `csharp-standards` file layout |
| .NET tests | `csharp-xunit` — xUnit v3 + NSubstitute only; never FluentAssertions, Shouldly, Moq, NUnit, or MSTest. Test databases: Testcontainers → SQLite in-memory → dedicated test database → EF Core InMemory as a last resort |
| `*.razor`, `*.razor.cs` | `blazor-wasm` |
| Angular code | `angular-standards`; `ngrx-signal-store` for any state; `angular-ui-architecture` when adding, moving, or naming files or wiring layer lint; `angular-developer` references for depth |
| `*.tf` | `terraform-conventions` |
| `.github/workflows/*.yml`, `action.yml` | `github-actions-hardening`, plus `github-actions-efficiency` / `github-actions-runtime-upgrade-conventions` when relevant |
| Microsoft Agent Framework | `microsoft-agent-framework` |

Ground version-specific answers in the MCP servers when they are installed — `microsoft-learn` (.NET, Azure), `angular-cli` (Angular), `context7` (any other library; ships with `andes-core`), `terraform` (providers, modules) — instead of memory.

## Review loop

After changing code, run the matching reviewer on the diff: `andes-csharp-code-reviewer` (C#, including Blazor), `andes-angular-code-reviewer` (Angular), `andes-github-actions-reviewer` (workflows, composite actions). Terraform has no reviewer — run `terraform fmt -check` and `terraform validate` instead.

1. Reviewers report only High and Medium findings plus a verdict. They never edit files or hand work back.
2. The implementer fixes every reported finding, then runs the reviewer once more on only the files changed since round 1.
3. Two rounds maximum. If High findings remain after round 2, stop and report them to the user instead of iterating; list any open Medium findings in the final summary.
4. After a passing verdict (**Approve** or **Approve with changes**), invoke `andes-se-technical-writer` to update `docs/` and add the `CHANGELOG.md` entry — unless your caller said it handles documentation.

## Docs, changelog & requirements

- `andes-se-technical-writer` owns `docs/` and the root `CHANGELOG.md` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)): one reader-facing entry per PR under `## [Unreleased]` in the matching subsection. Routine cleanups with no behavior change still get a one-line entry.
- To write a PRD, spec a feature, or break it into epics and user stories, delegate to `andes-prd-generator` (writes `docs/prd/`). If its report starts `PRD-STATUS: NEEDS-INPUT`, show its questions to the user verbatim and re-invoke it with the answers. It creates GitHub issues only after the user explicitly approves. PRDs and the implementation plans under `docs/plans/` get no changelog entry; plans reference story IDs (`US-xxx`). Plans are working files for following the implementation: never commit `docs/plans/`; keep it in `.gitignore`.
- When `andes-azure-devops` is installed, delegate creating, updating, or removing Azure DevOps epics, features, and stories (including from a PRD) to `andes-ado-backlog-manager`. It previews every change and always asks who to assign and which iteration; if its report starts `ADO-STATUS: NEEDS-INPUT` or `ADO-STATUS: NEEDS-SETUP`, show it to the user verbatim and re-invoke it with the answers and the user's explicit approval.
<!-- andes:end -->

## About this repository

Terraform and Azure DevOps pipelines for the Andes application environments (dev now; qa/uat/staging/prod later). It holds infrastructure only; application code and app deployment pipelines live elsewhere. Architecture and runbooks: `docs/infrastructure.md`.

## Layout

- `terraform/`: a single root module shared by every environment. Per-environment values live in `terraform/environments/<env>/{backend.hcl,terraform.tfvars}`.
- `bootstrap/`: admin-only, never run by the pipeline. `New-TfStateBackend.ps1` creates the state backend once per subscription. `bootstrap/terraform/` is a separate root module with its own admin-only state; one `environments` entry creates an environment's resource group, state container, plan and apply pipeline identities, SQL admin group, and Azure DevOps service connections, checks and environment.
- `scripts/`: scripts the pipeline runs after apply (SQL contained user for the API identity).
- `pipelines/`: Azure DevOps YAML (`infra-pipeline.yml` plus `templates/`).

## Build, test, run

```powershell
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
terraform -chdir=bootstrap/terraform fmt -check
terraform -chdir=bootstrap/terraform init -backend=false
terraform -chdir=bootstrap/terraform validate
Invoke-ScriptAnalyzer -Path bootstrap -Recurse; Invoke-ScriptAnalyzer -Path scripts -Recurse
```

After changing provider versions, run `terraform providers lock -platform=linux_amd64 -platform=windows_amd64` in both `terraform/` and `bootstrap/terraform/` and commit each `.terraform.lock.hcl`. Keep the azurerm version the same in both.

## Conventions

- Name every resource `andes-<type>-<env>`; storage accounts drop the dashes (`andesst<env>`). Names come from `local.names` in `terraform/locals.tf`; don't hard-code them elsewhere. Web app, Key Vault, Storage, SQL and Cosmos DB names are global, so check they're free before adding an environment.
- No secrets anywhere: data services use managed identity and Entra RBAC. Keep shared keys, Cosmos DB keys and SQL authentication disabled.
- Every Azure RBAC role `terraform/` assigns must be in `assignable_role_names` in `bootstrap/terraform/variables.tf`. That list is enforced by an ABAC condition on each apply identity.
- PR and plan stages use the read-only `<prefix>-sc-<env>-plan` connection; only apply and the SQL grant use `<prefix>-sc-<env>-apply`, which carries the branch control, exclusive lock and approval checks. Never point a plan step at the apply connection.
- If `terraform/` starts using a resource whose refresh calls a POST list action, add that action to `azurerm_role_definition.plan_reader` in `bootstrap/terraform/rbac.tf`, or plans fail with AuthorizationFailed.
- Add environments through an `environments` entry in `bootstrap/terraform/terraform.tfvars`, a `terraform/environments/<env>/` folder and a pipeline template call, not by forking Terraform code.
- Never commit `docs/plans/` or `*.tfvars` other than `terraform/environments/*/terraform.tfvars` and `bootstrap/terraform/terraform.tfvars`, which must stay secret-free.
