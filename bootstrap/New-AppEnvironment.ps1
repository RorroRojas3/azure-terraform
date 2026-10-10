#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage, Az.ManagedServiceIdentity

<#
.SYNOPSIS
    Creates an application environment (dev, qa, uat, staging, prod) and its least-privilege pipeline identity.

.DESCRIPTION
    Run once per environment by an Azure administrator (Owner on the subscription, plus rights to create Entra
    security groups). Safe to re-run. It:

      1. Registers the resource providers Terraform needs (the pipeline identity cannot register them).
      2. Creates the environment resource group <prefix>-rg-<env>.
      3. Creates the pipeline identity <prefix>-id-ado-<env> in the tfstate resource group, outside the
         environment it manages, so the pipeline cannot modify or delete its own identity.
      4. Creates the state container tfstate-<env>.
      5. Grants the pipeline identity: Contributor on the environment resource group; Role Based Access Control
         Administrator on it, constrained to -AssignableRoleNames; and blob access to its own state container only.
      6. Creates the Entra group <prefix>-sg-sql-admins-<env> (pipeline identity + -SqlAdminMemberObjectIds),
         used as the SQL server's Entra admin.
      7. Adds the Azure DevOps federated credential when -AdoFederationIssuer and -AdoFederationSubject are given.

    Two-pass flow for the Azure DevOps service connection:
      a. Run this script without the federation parameters.
      b. In Azure DevOps, create the service connection <prefix>-sc-<env> (Azure Resource Manager, "App registration
         or managed identity (manual)", workload identity federation) with the client ID printed below, and save
         it as a draft.
      c. Re-run this script with the issuer and subject the draft shows, then verify and save the connection.

.EXAMPLE
    ./bootstrap/New-AppEnvironment.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Environment dev `
        -Location eastus2 -SqlAdminMemberObjectIds 11111111-1111-1111-1111-111111111111
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z]{2,7}$')]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$Location,

    [ValidatePattern('^[a-z0-9]{2,8}$')]
    [string]$NamePrefix = 'andes',

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string[]]$SqlAdminMemberObjectIds = @(),

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string[]]$StateContributorObjectIds = @(),

    [string[]]$AssignableRoleNames = @(
        'Key Vault Secrets User'
        'Key Vault Secrets Officer'
        'Storage Blob Data Contributor'
        'Storage Blob Data Reader'
        'Monitoring Metrics Publisher'
    ),

    [ValidatePattern('^https://')]
    [string]$AdoFederationIssuer,

    [string]$AdoFederationSubject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/BootstrapCommon.ps1"

if ([string]::IsNullOrEmpty($AdoFederationIssuer) -ne [string]::IsNullOrEmpty($AdoFederationSubject)) {
    throw 'Pass both -AdoFederationIssuer and -AdoFederationSubject, or neither.'
}

$stateResourceGroupName = Get-TfStateResourceGroupName -NamePrefix $NamePrefix
$stateStorageAccountName = Get-TfStateStorageAccountName -NamePrefix $NamePrefix -SubscriptionId $SubscriptionId
$resourceGroupName = "$NamePrefix-rg-$Environment"
$pipelineIdentityName = "$NamePrefix-id-ado-$Environment"
$sqlAdminGroupName = "$NamePrefix-sg-sql-admins-$Environment"
$stateContainerName = "tfstate-$Environment"
$serviceConnectionName = "$NamePrefix-sc-$Environment"
$tags = @{ company = $NamePrefix; environment = $Environment; 'managed-by' = 'bootstrap' }

Set-BootstrapAzContext -SubscriptionId $SubscriptionId

$stateAccount = Get-AzStorageAccount -ResourceGroupName $stateResourceGroupName -Name $stateStorageAccountName -ErrorAction SilentlyContinue
if (-not $stateAccount) {
    throw "State storage account $stateStorageAccountName not found in $stateResourceGroupName. Run bootstrap/New-TfStateBackend.ps1 first."
}

Register-RequiredResourceProvider -ProviderNamespace @(
    'Microsoft.AlertsManagement'
    'Microsoft.Consumption'
    'Microsoft.DocumentDB'
    'Microsoft.Insights'
    'Microsoft.KeyVault'
    'Microsoft.ManagedIdentity'
    'Microsoft.Network'
    'Microsoft.OperationalInsights'
    'Microsoft.Sql'
    'Microsoft.Storage'
    'Microsoft.Web'
)

$resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if (-not $resourceGroup -and $PSCmdlet.ShouldProcess($resourceGroupName, 'Create resource group')) {
    $resourceGroup = New-AzResourceGroup -Name $resourceGroupName -Location $Location -Tag $tags
}

$pipelineIdentity = Get-AzUserAssignedIdentity -ResourceGroupName $stateResourceGroupName -Name $pipelineIdentityName -ErrorAction SilentlyContinue
if (-not $pipelineIdentity -and $PSCmdlet.ShouldProcess($pipelineIdentityName, 'Create pipeline managed identity')) {
    $pipelineIdentity = New-AzUserAssignedIdentity -ResourceGroupName $stateResourceGroupName -Name $pipelineIdentityName `
        -Location $stateAccount.PrimaryLocation -Tag $tags
}

if (-not (Get-AzRmStorageContainer -ResourceGroupName $stateResourceGroupName -StorageAccountName $stateStorageAccountName -Name $stateContainerName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($stateContainerName, 'Create state container')) {
    New-AzRmStorageContainer -ResourceGroupName $stateResourceGroupName -StorageAccountName $stateStorageAccountName `
        -Name $stateContainerName -PublicAccess None | Out-Null
}

if (-not $resourceGroup -or -not $pipelineIdentity) {
    Write-Warning 'WhatIf: skipping role assignments, Entra group and federated credential because their prerequisites were not created.'
    return
}

$stateContainerScope = "$($stateAccount.Id)/blobServices/default/containers/$stateContainerName"
$assignableRoleIds = $AssignableRoleNames | ForEach-Object {
    # Only Id is read, which the announced PSRoleDefinition breaking change leaves intact.
    $definition = Get-AzRoleDefinition -Name $_ -WarningAction SilentlyContinue
    if (-not $definition) { throw "Role definition '$_' not found." }
    $definition.Id
}
$roleIdList = ($assignableRoleIds | Sort-Object) -join ', '

# The pipeline may create or delete role assignments only for the allowlisted roles, so it can never grant
# itself or anyone else Owner, Contributor or User Access Administrator.
$rbacAdminCondition = @"
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleIdList}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleIdList}
 )
)
"@

Set-RoleAssignment -ObjectId $pipelineIdentity.PrincipalId -RoleDefinitionName 'Contributor' -Scope $resourceGroup.ResourceId
Set-RoleAssignment -ObjectId $pipelineIdentity.PrincipalId -RoleDefinitionName 'Role Based Access Control Administrator' `
    -Scope $resourceGroup.ResourceId -Condition $rbacAdminCondition
Set-RoleAssignment -ObjectId $pipelineIdentity.PrincipalId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $stateContainerScope

foreach ($objectId in $StateContributorObjectIds) {
    Set-RoleAssignment -ObjectId $objectId -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $stateContainerScope
}

$sqlAdminGroup = Get-AzADGroup -DisplayName $sqlAdminGroupName | Select-Object -First 1
if (-not $sqlAdminGroup -and $PSCmdlet.ShouldProcess($sqlAdminGroupName, 'Create Entra security group')) {
    $sqlAdminGroup = New-AzADGroup -DisplayName $sqlAdminGroupName -MailNickname $sqlAdminGroupName -SecurityEnabled `
        -Description "Microsoft Entra admins of the $NamePrefix $Environment Azure SQL server."
}

if ($sqlAdminGroup) {
    $currentMemberIds = @(Get-AzADGroupMember -GroupObjectId $sqlAdminGroup.Id | ForEach-Object Id)
    $desiredMemberIds = @($pipelineIdentity.PrincipalId) + $SqlAdminMemberObjectIds
    foreach ($memberId in $desiredMemberIds | Where-Object { $_ -notin $currentMemberIds }) {
        if ($PSCmdlet.ShouldProcess($sqlAdminGroupName, "Add member $memberId")) {
            Invoke-WithRetry { Add-AzADGroupMember -TargetGroupObjectId $sqlAdminGroup.Id -MemberObjectId $memberId }
        }
    }
}

if ($AdoFederationIssuer) {
    $credentialName = "ado-$serviceConnectionName"
    $credential = Get-AzFederatedIdentityCredential -ResourceGroupName $stateResourceGroupName -IdentityName $pipelineIdentityName `
        -Name $credentialName -ErrorAction SilentlyContinue
    $credentialSettings = @{
        ResourceGroupName = $stateResourceGroupName
        IdentityName      = $pipelineIdentityName
        Name              = $credentialName
        Issuer            = $AdoFederationIssuer
        Subject           = $AdoFederationSubject
        Audience          = @('api://AzureADTokenExchange')
    }

    if (-not $credential) {
        if ($PSCmdlet.ShouldProcess($pipelineIdentityName, 'Add Azure DevOps federated credential')) {
            New-AzFederatedIdentityCredential @credentialSettings | Out-Null
        }
    }
    elseif (($credential.Issuer -ne $AdoFederationIssuer -or $credential.Subject -ne $AdoFederationSubject) -and
        $PSCmdlet.ShouldProcess($pipelineIdentityName, 'Update Azure DevOps federated credential')) {
        Update-AzFederatedIdentityCredential @credentialSettings | Out-Null
    }
}

$federatedCredentials = @(Get-AzFederatedIdentityCredential -ResourceGroupName $stateResourceGroupName `
        -IdentityName $pipelineIdentityName -ErrorAction SilentlyContinue)

[pscustomobject]@{
    Environment                = $Environment
    ResourceGroupName          = $resourceGroupName
    TenantId                   = (Get-AzContext).Tenant.Id
    SubscriptionId             = $SubscriptionId
    PipelineIdentityName       = $pipelineIdentityName
    PipelineIdentityClientId   = $pipelineIdentity.ClientId
    ServiceConnectionName      = $serviceConnectionName
    StateStorageAccountName    = $stateStorageAccountName
    StateContainerName         = $stateContainerName
    SqlAdminGroupName          = $sqlAdminGroupName
    SqlAdminGroupObjectId      = if ($sqlAdminGroup) { $sqlAdminGroup.Id } else { $null }
    FederatedCredentialPresent = $federatedCredentials.Count -gt 0
}
