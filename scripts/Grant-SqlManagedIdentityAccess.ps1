#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Sql, SqlServer

<#
.SYNOPSIS
    Creates (idempotently) the contained database user for a managed identity and grants it database roles.

.DESCRIPTION
    Terraform cannot run T-SQL, so the infrastructure pipeline runs this after apply. It must run as a member of
    the SQL server's Microsoft Entra admin group (<prefix>-sg-sql-admins-<env>).

    The user is created WITH SID/TYPE = E from the identity's client ID instead of FROM EXTERNAL PROVIDER. That
    avoids a Microsoft Graph lookup, so the SQL server does not need the Directory Readers role when a service
    principal runs this.

    -AddRunnerFirewallRule opens the SQL firewall to this machine's public IP for the duration of the run and
    always removes the rule afterwards. Use it on Microsoft-hosted agents, whose IPs are not allowlisted.

.EXAMPLE
    ./scripts/Grant-SqlManagedIdentityAccess.ps1 -ResourceGroupName andes-rg-dev -SqlServerName andes-sql-dev-1a2b `
        -DatabaseName andes-sqldb-dev -PrincipalName andes-id-api-dev -PrincipalClientId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9-]{1,63}$')]
    [string]$SqlServerName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')]
    [string]$DatabaseName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]{1,128}$')]
    [string]$PrincipalName,

    [Parameter(Mandatory)]
    [guid]$PrincipalClientId,

    [ValidateSet('db_datareader', 'db_datawriter', 'db_ddladmin')]
    [string[]]$Roles = @('db_datareader', 'db_datawriter'),

    [switch]$AddRunnerFirewallRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Inputs are pattern-validated above and quoted with QUOTENAME below; T-SQL DDL cannot take parameters.
$roleStatements = foreach ($role in $Roles | Sort-Object -Unique) {
    @"
IF IS_ROLEMEMBER(N'$role', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE ' + QUOTENAME(N'$role') + N' ADD MEMBER ' + QUOTENAME(@name) + N';';
    EXEC sp_executesql @sql;
END;
"@
}

$query = @"
SET NOCOUNT ON;
DECLARE @name sysname = N'$PrincipalName';
DECLARE @sid varbinary(16) = CAST(CAST('$PrincipalClientId' AS uniqueidentifier) AS varbinary(16));
DECLARE @sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' WITH SID = ' + CONVERT(nvarchar(34), @sid, 1) + N', TYPE = E;';
    EXEC sp_executesql @sql;
END
ELSE IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name AND sid = @sid)
BEGIN
    THROW 50000, 'A database principal with this name already exists for a different identity.', 1;
END;

$($roleStatements -join [Environment]::NewLine)
"@

$firewallRuleName = $null
try {
    if ($AddRunnerFirewallRule -and $PSCmdlet.ShouldProcess($SqlServerName, 'Add temporary firewall rule for this machine')) {
        $runnerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 30).Trim()
        $firewallRuleName = "tmp-runner-$($env:BUILD_BUILDID ?? [guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName `
            -FirewallRuleName $firewallRuleName -StartIpAddress $runnerIp -EndIpAddress $runnerIp | Out-Null
    }

    if (-not $PSCmdlet.ShouldProcess("$SqlServerName/$DatabaseName", "Ensure user $PrincipalName with roles $($Roles -join ', ')")) {
        return
    }

    $token = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/').Token
    if ($token -is [securestring]) {
        $token = ConvertFrom-SecureString -SecureString $token -AsPlainText
    }

    # New firewall rules can take a short while to apply.
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-Sqlcmd -ServerInstance "$SqlServerName.database.windows.net" -Database $DatabaseName `
                -AccessToken $token -Query $query -Encrypt Mandatory -ConnectionTimeout 30 -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -ge 5) { throw }
            Write-Verbose "SQL connection attempt $attempt failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    }

    Write-Information "Database user $PrincipalName has roles: $($Roles -join ', ')." -InformationAction Continue
}
finally {
    if ($firewallRuleName) {
        Remove-AzSqlServerFirewallRule -ResourceGroupName $ResourceGroupName -ServerName $SqlServerName `
            -FirewallRuleName $firewallRuleName -Force | Out-Null
    }
}
