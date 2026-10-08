Set-StrictMode -Version Latest

function Get-TfStateResourceGroupName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NamePrefix)

    "$NamePrefix-rg-tfstate"
}

function Get-TfStateStorageAccountName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$NamePrefix,
        [Parameter(Mandatory)][string]$SubscriptionId
    )

    # Derived from the subscription so both bootstrap scripts and every backend.hcl agree on the name
    # without passing it around, while staying globally unique.
    $hash = [System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant()))
    "$($NamePrefix)sttfstate$([Convert]::ToHexString($hash).Substring(0, 6).ToLowerInvariant())"
}

function Set-BootstrapAzContext {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not (Get-AzContext)) {
        throw 'No Azure session found. Run Connect-AzAccount with an account that is Owner on the subscription.'
    }

    if ($PSCmdlet.ShouldProcess($SubscriptionId, 'Select subscription')) {
        Set-AzContext -Subscription $SubscriptionId -WarningAction SilentlyContinue | Out-Null
    }
}

function Register-RequiredResourceProvider {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$ProviderNamespace)

    foreach ($namespace in $ProviderNamespace) {
        $provider = Get-AzResourceProvider -ProviderNamespace $namespace | Select-Object -First 1
        if ($provider -and $provider.RegistrationState -eq 'Registered') {
            continue
        }

        if ($PSCmdlet.ShouldProcess($namespace, 'Register resource provider')) {
            Register-AzResourceProvider -ProviderNamespace $namespace | Out-Null
            Write-Information "Registering resource provider $namespace." -InformationAction Continue
        }
    }
}

function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 6,
        [int]$DelaySeconds = 15
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            # Entra replication: a principal created seconds ago is often not yet visible to Azure RBAC or Graph.
            Write-Verbose "Attempt $attempt failed: $($_.Exception.Message). Retrying in $DelaySeconds s."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Set-RoleAssignment {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ObjectId,
        [Parameter(Mandatory)][string]$RoleDefinitionName,
        [Parameter(Mandatory)][string]$Scope,
        [string]$Condition
    )

    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleDefinitionName -Scope $Scope -ErrorAction SilentlyContinue |
        Where-Object Scope -EQ $Scope |
        Select-Object -First 1

    if ($existing) {
        if ($Condition -and $existing.Condition -ne $Condition -and
            $PSCmdlet.ShouldProcess("$RoleDefinitionName @ $Scope", 'Update role assignment condition')) {
            $existing.Condition = $Condition
            $existing.ConditionVersion = '2.0'
            Set-AzRoleAssignment -InputObject $existing | Out-Null
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$RoleDefinitionName @ $Scope for $ObjectId", 'Create role assignment')) {
        return
    }

    $parameters = @{
        ObjectId           = $ObjectId
        RoleDefinitionName = $RoleDefinitionName
        Scope              = $Scope
    }
    if ($Condition) {
        $parameters.Condition = $Condition
        $parameters.ConditionVersion = '2.0'
    }

    Invoke-WithRetry { New-AzRoleAssignment @parameters | Out-Null }
}
