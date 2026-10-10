#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage

<#
.SYNOPSIS
    Creates the shared Terraform state backend: a locked resource group and a geo-redundant storage account.

.DESCRIPTION
    Run once per subscription by an Azure administrator (Owner on the subscription). Safe to re-run: existing
    resources are converged to the settings below rather than recreated.

    The storage account accepts Microsoft Entra authentication only (shared keys disabled). Its network stays
    open because Microsoft-hosted Azure DevOps agents use dynamic IPs; access is controlled by RBAC that
    bootstrap/New-AppEnvironment.ps1 grants per environment container. Pass -AllowedIpAddresses only when every
    Terraform run comes from known IPs (for example, self-hosted agents).

.EXAMPLE
    Connect-AzAccount
    ./bootstrap/New-TfStateBackend.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus2
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$Location,

    [ValidatePattern('^[a-z0-9]{2,8}$')]
    [string]$NamePrefix = 'andes',

    [ValidateSet('Standard_RAGRS', 'Standard_GRS', 'Standard_RAGZRS', 'Standard_GZRS')]
    [string]$SkuName = 'Standard_RAGRS',

    [string[]]$AllowedIpAddresses = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/BootstrapCommon.ps1"

$resourceGroupName = Get-TfStateResourceGroupName -NamePrefix $NamePrefix
$storageAccountName = Get-TfStateStorageAccountName -NamePrefix $NamePrefix -SubscriptionId $SubscriptionId
$tags = @{ company = $NamePrefix; purpose = 'terraform-state'; 'managed-by' = 'bootstrap' }

Set-BootstrapAzContext -SubscriptionId $SubscriptionId
Register-RequiredResourceProvider -ProviderNamespace 'Microsoft.Storage', 'Microsoft.ManagedIdentity'

if (-not (Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($resourceGroupName, 'Create resource group')) {
    New-AzResourceGroup -Name $resourceGroupName -Location $Location -Tag $tags | Out-Null
}

$accountSettings = @{
    ResourceGroupName           = $resourceGroupName
    Name                        = $storageAccountName
    SkuName                     = $SkuName
    MinimumTlsVersion           = 'TLS1_2'
    EnableHttpsTrafficOnly      = $true
    AllowBlobPublicAccess       = $false
    AllowSharedKeyAccess        = $false
    AllowCrossTenantReplication = $false
    PublicNetworkAccess         = 'Enabled'
    Tag                         = $tags
}

if (-not (Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($storageAccountName, 'Create storage account')) {
        New-AzStorageAccount @accountSettings -Location $Location -Kind StorageV2 -AccessTier Hot | Out-Null
    }
}
elseif ($PSCmdlet.ShouldProcess($storageAccountName, 'Enforce storage account settings')) {
    Set-AzStorageAccount @accountSettings | Out-Null
}

if ($PSCmdlet.ShouldProcess($storageAccountName, 'Configure network rules, versioning and soft delete')) {
    if ($AllowedIpAddresses.Count -gt 0) {
        $ipRules = $AllowedIpAddresses | ForEach-Object { @{ IPAddressOrRange = $_ -replace '/32$', ''; Action = 'allow' } }
        Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $resourceGroupName -Name $storageAccountName `
            -DefaultAction Deny -Bypass AzureServices -IPRule $ipRules | Out-Null
    }
    else {
        Update-AzStorageAccountNetworkRuleSet -ResourceGroupName $resourceGroupName -Name $storageAccountName `
            -DefaultAction Allow | Out-Null
    }

    Update-AzStorageBlobServiceProperty -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName `
        -IsVersioningEnabled $true | Out-Null
    Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName `
        -RetentionDays 30 | Out-Null
    Enable-AzStorageContainerDeleteRetentionPolicy -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName `
        -RetentionDays 30 | Out-Null
}

$lockName = 'protect-terraform-state'
if (-not (Get-AzResourceLock -ResourceGroupName $resourceGroupName -LockName $lockName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($resourceGroupName, 'Add CanNotDelete lock')) {
    New-AzResourceLock -ResourceGroupName $resourceGroupName -LockName $lockName -LockLevel CanNotDelete `
        -LockNotes 'Holds Terraform state and pipeline identities for every environment.' -Force | Out-Null
}

[pscustomobject]@{
    ResourceGroupName  = $resourceGroupName
    StorageAccountName = $storageAccountName
    Sku                = $SkuName
    NextStep           = "Run bootstrap/New-AppEnvironment.ps1 for each environment; backend.hcl uses storage_account_name = `"$storageAccountName`"."
}
