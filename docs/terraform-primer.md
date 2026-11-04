# Terraform primer for this repository

This repo builds Azure infrastructure with Terraform. You don't need to know Terraform to read the other guides, but you do need the handful of ideas below to run its commands safely. They're explained in terms of .NET projects, because the shapes are familiar.

The one idea to keep: **Terraform compares what the code says should exist against its record of what it already created, then changes Azure to close the gap.** The code is the desired state, the record is the state file, and Azure is reality.

## Concepts mapped to .NET

| Terraform | .NET analogy | In this repo |
| --- | --- | --- |
| `.tf` files | Source code, but declarative: you describe what should exist, not the steps to create it | `terraform/*.tf`, `bootstrap/terraform/*.tf` |
| Provider | An SDK that talks to one service | `azurerm` (Azure resources), `azuread` (Entra groups), `azuredevops` (service connections, Environments) |
| Root module | A project you build and run. A folder of `.tf` files you run commands in | Two: `terraform/` (the environments) and `bootstrap/terraform/` (the admin-only setup) |
| Resource | An object the code declares | `azurerm_windows_web_app.api` is one web app |
| Variable | A parameter of the project | `variables.tf` declares them, for example `allowed_ip_addresses` |
| `terraform.tfvars` | Per-environment `appsettings.<env>.json` | `terraform/environments/<env>/terraform.tfvars` |
| `backend.hcl` | The connection string for where state lives | `terraform/environments/<env>/backend.hcl` |
| State | The record of what Terraform created and the IDs Azure gave back, like an EF Core migrations history plus the row IDs | A JSON blob `infra.tfstate` in the `tfstate-<env>` container |
| Output | A return value | `terraform output api_url` |
| `.terraform.lock.hcl` | A package lock file (`packages.lock.json`) | One per root module; pins provider versions |
| `.terraform/` | The `obj/` folder: downloaded providers and the backend connection. Local only and gitignored | Created by `init` |

Three details worth knowing:

- **Two root modules, two separate states.** `bootstrap/terraform/` creates the identities, service connections and per-environment containers that let the pipeline run. `terraform/` creates the actual environment. They never share state. An administrator runs the first. The pipeline runs the second.
- **One code base, five states.** `terraform/` is a single set of `.tf` files. Each environment adds its own `terraform.tfvars` (values) and `backend.hcl` (where its state lives), so dev and prod run the same code with different inputs and different state.
- **State is sensitive.** It holds every attribute of every resource, including values you'd treat as secrets. That's why state lives in a private storage account reachable only with Entra RBAC, and why saved plan files (`*.tfplan`) are gitignored.

## The commands

Every command in this repo uses `-chdir=<folder>` to say which root module it runs in, so you can run everything from the repository root:

```powershell
terraform -chdir=terraform plan
```

`-chdir` is the same as `cd terraform` for that one command.

### `init`: restore and connect to state

`init` downloads the providers (like `dotnet restore`) and connects to the state described by `backend.hcl`. Run it first, and again whenever you switch environment.

```powershell
az login
terraform -chdir=terraform init "-backend-config=environments/dev/backend.hcl"
```

`-backend-config` supplies the per-environment settings (storage account, container, blob name) that `terraform/versions.tf` deliberately leaves blank. Terraform signs in to the state account with your `az login` session.

To switch to a different environment, add `-reconfigure`:

```powershell
terraform -chdir=terraform init -reconfigure "-backend-config=environments/qa/backend.hcl"
```

`-reconfigure` tells Terraform to forget the previous backend and use the new one, without moving any data.

**Never use `-migrate-state` between environments.** It copies the state you're leaving into the state you're joining. That would tell qa's state that it owns dev's resources, and the next apply would try to change or delete them. `-reconfigure` is the only switch you need.

### `plan`: a read-only preview

`plan` refreshes the state against Azure, compares it to the code and tfvars, and prints what it would change. It changes nothing.

```powershell
terraform -chdir=terraform plan "-var-file=environments/dev/terraform.tfvars"
```

`-var-file` supplies the environment's values. Terraform doesn't read `environments/<env>/terraform.tfvars` on its own, because the file isn't in the module's root folder.

How to read the output:

| Symbol | Meaning |
| --- | --- |
| `+` | Create |
| `~` | Update in place |
| `-` | Destroy |
| `-/+` | Replace: destroy, then create. Check why, because replacing a database or storage account loses its data |

The last line summarizes the counts: `Plan: 2 to add, 1 to change, 0 to destroy.` Treat any destroy you didn't expect as a stop sign.

### `apply`: make the change

`apply` runs a plan and, after you type `yes`, changes Azure and updates the state.

```powershell
terraform -chdir=terraform apply "-var-file=environments/dev/terraform.tfvars"
```

Normally you never do this by hand. The pipeline applies a **saved plan** (`plan -out`), which guarantees it applies exactly what was reviewed. If anything changed since, Terraform rejects the stale plan. [Manual deployment](manual-deployment.md#part-6b-deploy-by-hand-from-a-workstation) covers the break-glass local route.

### Outputs

```powershell
terraform -chdir=terraform output
terraform -chdir=terraform output -raw application_insights_connection_string
```

Sensitive outputs print as `<sensitive>` unless you ask for one by name; `-raw` prints a string without quotes.

## Protections Terraform gives you

### `prevent_destroy`

A `lifecycle { prevent_destroy = true }` block makes any plan that would destroy that resource fail with an error. `bootstrap/terraform/` sets it on resource groups, state containers, pipeline identities and the SQL admin groups. If you hit it, don't remove the block to get past it. Work out why the plan wants to destroy the resource.

`prevent_destroy` is a Terraform-level guard only. It doesn't stop `az group delete`, the portal, or anything else outside Terraform.

### `import`

Sometimes a real resource exists that Terraform doesn't know about, and the next apply fails with `a resource with the ID ... already exists - to be managed via Terraform this resource needs to be imported into the State`. `import` adopts the existing object into state instead of creating it:

```powershell
terraform -chdir=terraform import "-var-file=environments/dev/terraform.tfvars" <resource address> "<azure resource ID>"
```

[Operations](operations.md#apply-fails-because-a-diagnostic-setting-already-exists) has the one import this repo has needed. Under Git Bash on Windows, prefix `import` with `MSYS_NO_PATHCONV=1` so the leading `/subscriptions/...` isn't rewritten as a Windows path.

## Terraform only manages what's in its state

This is the rule behind most Terraform accidents.

- If a resource is in the code **and** in state, Terraform keeps it matched.
- If a resource is in the code but **not** in state, Terraform tries to create it, and fails if the name already exists.
- If a resource is in state but **gone from Azure** (someone deleted it by hand), Terraform plans to recreate it.
- If the **state is lost**, Terraform has no idea anything exists. The real resources keep running, but they're orphans: Terraform can't update or destroy them, and it fails when it tries to create new ones with the same names.

Deleting a state file or its storage account doesn't delete your infrastructure. It makes the infrastructure unmanageable. [Manual deployment, Part 8](manual-deployment.md#part-8-rebuild-after-a-teardown-or-lost-bootstrap-state) is the recovery path for exactly that.

This is also why the state account has versioning, 30-day soft delete and a `CanNotDelete` lock. [Operations](operations.md#state-care) explains how to restore an earlier state.

## What never to do

- **Don't edit or delete state by hand,** or delete the `tfstate-*` containers or the state account.
- **Don't use `-migrate-state`** to switch environments. Use `-reconfigure`.
- **Don't run `az group delete` on a resource group Terraform manages.** It leaves Terraform's records, diagnostic settings and soft-deleted vaults out of step. Use `terraform destroy`, then the [teardown order](manual-deployment.md#part-9-proper-teardown).
- **Don't apply locally to skip review.** A local apply bypasses PR review, approvals and the apply identity's ABAC limit.
- **Don't run apply with `-lock=false`,** and don't force-unlock state while a run is active. The lock stops two applies from corrupting the same state.
- **Don't commit `*.tfplan` files, state, or any `*.tfvars` outside the two allowed paths.** Saved plans hold values in cleartext.
- **Don't hard-code resource names.** They come from `local.names` in `terraform/locals.tf`.
- **Don't put approvers, approval checks or approval flags in Terraform.** They're set in Azure DevOps on each Environment.
- **Don't change the apply identity's role list or ABAC condition from `terraform/`.** Add roles to `assignable_role_names` in `bootstrap/terraform/variables.tf` and re-apply the bootstrap.

## Where to go next

| I want to... | Read |
| --- | --- |
| See what gets built and why | [Architecture](architecture.md) |
| Run the setup | [Manual deployment](manual-deployment.md) |
| Understand how the pipeline runs these commands | [Pipeline](pipeline.md) |
