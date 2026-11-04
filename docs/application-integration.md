# Application integration

This guide is for engineers building the API and the UI that run on these environments. It tells you which settings Terraform gives your app, how the app signs in to each data service without a secret, who can read and write data, and what the application deployment pipelines need.

The model in one sentence: **the API authenticates as a user-assigned managed identity everywhere, so your code holds no keys, passwords or connection-string secrets.**

## App settings the API receives

Terraform sets these on `andes-softsol-api-<env>` (`terraform/app_service.tf`). None is a secret.

| Setting | Value | How to use it |
| --- | --- | --- |
| `AZURE_CLIENT_ID` | The API identity's client ID | `DefaultAzureCredential` reads it to pick the user-assigned identity. A bare `new ManagedIdentityCredential()` doesn't; it would use a system-assigned identity, which the API doesn't have |
| `ASPNETCORE_ENVIRONMENT` | `Development`, `QA`, `UAT`, `Staging` or `Production` | Standard ASP.NET Core environment name, set per environment from `aspnetcore_environment` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | The shared Application Insights connection string | Read by the Application Insights SDK |
| `KeyVault__Uri` | The Key Vault URI | Load secrets with the Azure Key Vault configuration provider |
| `Storage__BlobEndpoint` | The Blob service endpoint | Create a `BlobServiceClient` with the credential |
| `Cosmos__Endpoint`, `Cosmos__DatabaseName` | The Cosmos DB endpoint and database (`andes`) | Create a `CosmosClient` with the credential |
| Connection string `Sql` (type `SQLAzure`) | `Server=tcp:<server>.database.windows.net,1433;Database=<db>;Authentication=Active Directory Managed Identity;User Id=<client id>;Encrypt=True;...` | Read it as `ConnectionStrings:Sql`. It has no password |

The double underscore in `KeyVault__Uri` is how App Service environment variables express a colon, so your code reads `KeyVault:Uri`, `Storage:BlobEndpoint`, `Cosmos:Endpoint` and `Cosmos:DatabaseName`. App Service exposes the `Sql` connection string with a `SQLAZURECONNSTR_` prefix, which ASP.NET Core maps to `ConnectionStrings:Sql`.

The UI app receives only `APPLICATIONINSIGHTS_CONNECTION_STRING`. It has no identity and no access to the data services.

**Settings you add by hand don't last.** `app_service.tf` owns the app settings. Anything you add in the portal isn't in the code, so the next apply can remove it. Only `WEBSITE_RUN_FROM_PACKAGE` is ignored, because zip deploys set it. To keep a new setting, add it to `terraform/app_service.tf` through a PR.

### Sign in with `DefaultAzureCredential`

A single credential object covers every data service. In App Service it uses the managed identity named by `AZURE_CLIENT_ID`. On your machine it falls back to your developer sign-in (Azure CLI or Visual Studio), so don't set `AZURE_CLIENT_ID` locally.

The examples below are illustrative. They assume the `Azure.Identity`, `Azure.Extensions.AspNetCore.Configuration.Secrets`, `Azure.Storage.Blobs`, `Microsoft.Azure.Cosmos` and `Microsoft.Data.SqlClient` (or EF Core SQL Server) packages.

```csharp
using Azure.Identity;

var credential = new DefaultAzureCredential();

// Key Vault: secrets become configuration values.
builder.Configuration.AddAzureKeyVault(
    new Uri(builder.Configuration["KeyVault:Uri"]!), credential);

// Blob Storage.
var blobs = new BlobServiceClient(
    new Uri(builder.Configuration["Storage:BlobEndpoint"]!), credential);

// Cosmos DB. Containers must already exist (see below).
var cosmos = new CosmosClient(builder.Configuration["Cosmos:Endpoint"], credential);
var database = cosmos.GetDatabase(builder.Configuration["Cosmos:DatabaseName"]);

// SQL: the managed identity is in the connection string, so there is no credential to pass.
var sqlConnection = builder.Configuration.GetConnectionString("Sql");
```

**Key Vault references.** App settings written as `@Microsoft.KeyVault(...)` resolve because the API web app sets `key_vault_reference_identity_id` to the API identity, which holds Key Vault Secrets User. Without that setting, App Service would try its own system identity, which this app doesn't have. A reference setting still has to be added to `app_service.tf`, per the note above.

## CORS

The API allows the UI's own origin, `https://andes-softsol-ui-<env>.azurewebsites.net`, plus anything listed in `api_cors_allowed_origins` in the environment's `terraform.tfvars`. To call a deployed API from a local UI (for example `http://localhost:4200`), add that origin to `api_cors_allowed_origins` through a PR.

## Health check

App Service probes `/health` on the API (`api_health_check_path`), with an eviction time of 10 minutes. Expose an unauthenticated `/health` endpoint that returns a 2xx status when the app is healthy. If the API has no such endpoint, App Service reports the instance as unhealthy. Setting `api_health_check_path = null` disables the probe.

## Cosmos DB and blob containers must be declared

Entra data-plane roles can't create Cosmos DB databases or containers, so Terraform creates them. It creates the database `andes` for you. You declare the containers, and blob containers too so every environment gets the same set, in the environment's `terraform.tfvars` and merge:

```hcl
storage_containers = ["uploads"]

cosmos_containers = {
  orders = { partition_key_paths = ["/customerId"] }
}
```

Cosmos DB code that creates a container at runtime (for example `CreateContainerIfNotExistsAsync`) can't work with these roles. Declare the container instead.

## Who can read and write data

| Principal | Key Vault | Blob Storage | Cosmos DB | Azure SQL |
| --- | --- | --- | --- | --- |
| API identity `andes-softsol-id-api-<env>` | Key Vault Secrets User (read secrets) | Storage Blob Data Contributor | Cosmos DB Data Contributor at database scope | `db_datareader` and `db_datawriter` on the contained user |
| Developers in `developer_principal_ids` (dev only) | Key Vault Secrets Officer | Storage Blob Data Contributor | Cosmos DB Data Contributor at database scope | None |
| SQL admin group `andes-softsol-sg-sql-admins-<env>` | None | None | None | Entra admin of the server |

Notes:

- **`developer_principal_ids` is set for dev only,** and is `[]` in the other environments.
- **SQL access runs only through the SQL admin group.** There is no developer role for SQL. If you need to query the dev database, your object ID must be in `sql_admin_member_object_ids` for dev in `bootstrap/terraform/terraform.tfvars`, which makes you an administrator of that SQL server, not just a reader. Ask a DevOps engineer to add you; the bootstrap applies it.
- **Local access also needs your IP.** Every data service denies by default. Your public IP must be in `allowed_ip_addresses` in the environment's `terraform.tfvars` ([Operations](operations.md#change-your-ip)).
- **The API's SQL user is created by a script,** after each apply that has changes. T-SQL is outside what Terraform can manage ([Pipeline](pipeline.md#stage-and-job-detail)).

## Terraform outputs you can read

Run these against an initialized environment (you need your object ID in `state_contributor_object_ids`; see [Operations](operations.md#run-terraform-locally)):

| Output | Contents |
| --- | --- |
| `api_url` | `https://` URL of the API web app |
| `ui_url` | `https://` URL of the UI web app |
| `api_web_app_name` | API web app name, for the deployment pipeline |
| `ui_web_app_name` | UI web app name, for the deployment pipeline |
| `api_identity` | `name`, `client_id` and `principal_id` of the API identity |
| `key_vault_uri` | Key Vault URI |
| `storage_blob_endpoint` | Blob endpoint of the environment storage account |
| `cosmos` | `endpoint` and `database_name` |
| `sql` | `server_fqdn` and `database_name` |
| `application_insights_connection_string` | Sensitive. Terraform hides it unless you ask for it by name |

```powershell
terraform -chdir=terraform output api_url
terraform -chdir=terraform output -raw application_insights_connection_string
```

The Angular app needs the Application Insights connection string at build time. Microsoft doesn't treat that connection string as a secret, and the browser SDK can only send telemetry with it.

There are two more outputs: `resource_group_name`, and `sql_access`, which feeds the SQL grant script.

## Application deployment pipelines

This repo creates the web apps. Your application pipelines deploy into them.

- **Zip deploy with Entra authentication.** For example, `AzureWebApp@1` with a workload identity federation service connection. FTP and basic-auth publishing are disabled (`ftp_publish_basic_authentication_enabled` and `webdeploy_publish_basic_authentication_enabled` are `false`, FTPS is off).
- **Terraform ignores `WEBSITE_RUN_FROM_PACKAGE`,** so zip deploys don't fight it.
- **The deploying identity needs Website Contributor** on both web apps (`api_web_app_name` and `ui_web_app_name`). `terraform/` doesn't grant it today. *Website Contributor* isn't in `assignable_role_names`, so granting it from `terraform/` would first need the role added there and the bootstrap re-applied ([Operations](operations.md#add-a-role-to-assignable_role_names)). Otherwise an administrator grants it by hand:

  ```powershell
  az role assignment create --assignee <deploy-identity-object-id> --role "Website Contributor" `
      --scope /subscriptions/<subscription-id>/resourceGroups/andes-softsol-rg-<env>/providers/Microsoft.Web/sites/andes-softsol-api-<env>
  ```

  Repeat for the UI web app. Under Git Bash on Windows, prefix with `MSYS_NO_PATHCONV=1`.

### API: publish 64-bit

The worker is 64-bit (`use_32_bit_worker = false`), because the provider defaults Windows workers to 32-bit and a `win-x64` publish fails to start on one. Publish framework-dependent or `win-x64`.

### UI `web.config`

IIS serves the static Angular build directly, so no Node process runs. The deployed package must include a `web.config` whose URL Rewrite rule sends paths that aren't files or directories to `/index.html`. Without it, deep links and page refreshes return 404. Put the file in the Angular project's `public/` folder so the build copies it next to `index.html`:

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

### EF Core migrations

The API's database user gets `db_datareader` and `db_datawriter`, which can't change the schema. Pick one of these options:

- **Run migrations from the application pipeline as a SQL admin group member (tighter, preferred).** Generate an idempotent script or a migration bundle, and run it as an identity that belongs to `andes-softsol-sg-sql-admins-<env>`. The API stays low-privilege.
- **Let the API run migrations itself.** Run `Grant-SqlManagedIdentityAccess.ps1` with the extra role, as a SQL admin group member. Initialize against the right environment first, so `sql_access` describes it:

  ```powershell
  az login
  terraform -chdir=terraform init -reconfigure "-backend-config=environments/<env>/backend.hcl"
  Connect-AzAccount
  $access = terraform -chdir=terraform output -json sql_access | ConvertFrom-Json
  ./scripts/Grant-SqlManagedIdentityAccess.ps1 `
      -ResourceGroupName $access.resource_group_name `
      -SqlServerName $access.server_name `
      -DatabaseName $access.database_name `
      -PrincipalName $access.principal_name `
      -PrincipalClientId $access.principal_client_id `
      -Roles db_datareader, db_datawriter, db_ddladmin
  ```

  The script only adds roles, so the pipeline's later grant never removes `db_ddladmin`. This gives the API identity schema-change rights for good.
