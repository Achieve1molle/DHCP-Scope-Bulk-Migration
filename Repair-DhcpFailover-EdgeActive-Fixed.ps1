#requires -Version 5.1
#requires -RunAsAdministrator

<##
.SYNOPSIS
Repairs DHCP Hot Standby relationships so NewEdge is Active and NewHub is Standby.

.DESCRIPTION
Run this script locally from the server identified as NewEdge in the CSV.
For each enabled scope, the script captures lease and reservation evidence, backs up
DHCP, removes the existing scope failover assignment, verifies the scope and leases
remain on NewEdge, and creates or joins the replacement relationship from NewEdge
using -ServerRole Active.
##>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile,

    [switch]$PreflightOnly,
    [switch]$StopOnError,
    [ValidateRange(5,600)][int]$ReplicationTimeoutSeconds = 180,
    [ValidateRange(0,300)][int]$RowDelaySeconds = 10
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module DhcpServer -ErrorAction Stop

function ConvertTo-Bool {
    param([object]$Value, [bool]$Default = $false)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    return @('1','true','yes','y') -contains ([string]$Value).Trim().ToLowerInvariant()
}

function Get-ShortName {
    param([string]$Name)
    return (($Name -split '\.')[0]).Trim()
}

function Get-SafeName {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9_.-]', '_')
}

function Write-RepairLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'PASS'  { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $script:LogFile -Value $line
}

function Get-LeaseSnapshot {
    param([string]$Server, [string]$ScopeId, [string]$Path)
    $leases = @(Get-DhcpServerv4Lease -ComputerName $Server -ScopeId $ScopeId -AllLeases -ErrorAction Stop |
        Select-Object @{n='Server';e={$Server}}, ScopeId, IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime)
    $leases | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    return $leases
}

function Get-LeaseKey {
    param($Lease)
    return '{0}|{1}' -f [string]$Lease.IPAddress, ([string]$Lease.ClientId).ToLowerInvariant()
}

function Assert-LeasesPresent {
    param([array]$Baseline, [array]$Actual, [string]$Context)
    $actualMap = @{}
    foreach ($item in $Actual) { $actualMap[(Get-LeaseKey $item)] = $true }
    $missing = @($Baseline | Where-Object { -not $actualMap.ContainsKey((Get-LeaseKey $_)) })
    if ($missing.Count -gt 0) { throw "$($missing.Count) baseline lease(s) are missing $Context." }
}

function Wait-FailoverNormal {
    param([string]$Server, [string]$Name, [int]$TimeoutSeconds)
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = ''
    do {
        $relationship = Get-DhcpServerv4Failover -ComputerName $Server -Name $Name -ErrorAction Stop
        if ($relationship.PSObject.Properties['State']) {
            $lastState = [string]$relationship.State
        } elseif ($relationship.PSObject.Properties['RelationshipState']) {
            $lastState = [string]$relationship.RelationshipState
        } else {
            Write-RepairLog "DHCP module did not expose relationship state for '$Name'. Continuing with partner, mode, role, and lease validation." 'WARN'
            return $relationship
        }
        if ($lastState -eq 'Normal') { return $relationship }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $end)
    throw "Relationship '$Name' did not reach Normal within $TimeoutSeconds seconds. Last state='$lastState'."
}

function Assert-FailoverRole {
    param([object]$Relationship, [string]$ExpectedRole, [string]$Server)
    $reportedRole = ''
    foreach ($propertyName in @('ServerRole','Role')) {
        if ($Relationship.PSObject.Properties[$propertyName]) {
            $reportedRole = [string]$Relationship.$propertyName
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($reportedRole)) {
        Write-RepairLog "DHCP module did not expose ServerRole or Role on $Server. Partner and HotStandby mode were still validated." 'WARN'
        return
    }
    if ($reportedRole -ine $ExpectedRole) {
        throw "Role validation failed on ${Server}. Expected=$ExpectedRole; Reported=$reportedRole."
    }
}

$requiredColumns = @(
    'Enabled','ScopeId','ScopeName','NewHub','NewEdge','CurrentRelationship',
    'NewRelationship','ReservePercent','MCLT','BackupRoot','OutputRoot'
)

$rows = @(Import-Csv $ConfigFile | Where-Object { ConvertTo-Bool $_.Enabled $true })
if ($rows.Count -eq 0) { throw 'No enabled rows were found in the CSV.' }

foreach ($row in $rows) {
    foreach ($column in $requiredColumns) {
        if (-not $row.PSObject.Properties[$column] -or [string]::IsNullOrWhiteSpace([string]$row.$column)) {
            throw "Missing or blank CSV column '$column'."
        }
    }

    $parsedIp = $null
    if (-not [Net.IPAddress]::TryParse(([string]$row.ScopeId).Trim(), [ref]$parsedIp)) {
        throw "Invalid ScopeId '$($row.ScopeId)'."
    }

    $reservePercent = 0
    if (-not [int]::TryParse(([string]$row.ReservePercent).Trim(), [ref]$reservePercent) -or $reservePercent -lt 1 -or $reservePercent -gt 50) {
        throw "ReservePercent must be an integer from 1 through 50 for $($row.ScopeId)."
    }

    $mclt = [timespan]::Zero
    if (-not [timespan]::TryParse(([string]$row.MCLT).Trim(), [ref]$mclt) -or $mclt -le [timespan]::Zero) {
        throw "Invalid MCLT '$($row.MCLT)'."
    }

    if ((Get-ShortName $row.NewEdge) -ine $env:COMPUTERNAME) {
        throw "This script must run on NewEdge '$($row.NewEdge)'. Current server='$env:COMPUTERNAME'."
    }
}

$pairGroups = @($rows | Group-Object {
    '{0}|{1}|{2}' -f (Get-ShortName $_.NewHub).ToLowerInvariant(),
        (Get-ShortName $_.NewEdge).ToLowerInvariant(),
        ([string]$_.NewRelationship).Trim().ToLowerInvariant()
})
if ($pairGroups.Count -ne 1) {
    throw 'All enabled rows in one run must use the same NewHub, NewEdge, and NewRelationship.'
}

$duplicates = @($rows | Group-Object { ([string]$_.ScopeId).Trim() } | Where-Object Count -gt 1)
if ($duplicates.Count -gt 0) { throw 'Duplicate enabled ScopeId rows were found.' }

$outputRoot = ([string]$rows[0].OutputRoot).Trim()
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$runDir = Join-Path $outputRoot ('EdgeActiveRepair_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$script:LogFile = Join-Path $runDir 'Repair.log'
$summary = New-Object System.Collections.ArrayList

Write-RepairLog "Loaded $($rows.Count) enabled scope(s). Local NewEdge=$env:COMPUTERNAME. PreflightOnly=$PreflightOnly; WhatIf=$WhatIfPreference."

$index = 0
foreach ($row in $rows) {
    $index++
    $scope = ([string]$row.ScopeId).Trim()
    $scopeName = ([string]$row.ScopeName).Trim()
    $hub = ([string]$row.NewHub).Trim()
    $edge = ([string]$row.NewEdge).Trim()
    $oldName = ([string]$row.CurrentRelationship).Trim()
    $newName = ([string]$row.NewRelationship).Trim()
    $scopeDir = Join-Path $runDir ((Get-SafeName $scope) + '_' + (Get-SafeName $scopeName))
    New-Item -ItemType Directory -Force -Path $scopeDir | Out-Null
    $result = 'FAIL'
    $message = ''

    try {
        Write-RepairLog "[$index/$($rows.Count)] Processing $scopeName ($scope)." 'STEP'

        $localScope = Get-DhcpServerv4Scope -ComputerName $edge -ScopeId $scope -ErrorAction Stop
        if (([string]$localScope.Name).Trim() -ine $scopeName) {
            throw "Scope name mismatch. DHCP='$($localScope.Name)'; CSV='$scopeName'."
        }

        $assigned = Get-DhcpServerv4Failover -ComputerName $edge -ScopeId $scope -ErrorAction SilentlyContinue
        if ($assigned) {
            $partner = Get-ShortName ([string]$assigned.PartnerServer)
            if (([string]$assigned.Name -ine $oldName) -and ([string]$assigned.Name -ine $newName)) {
                throw "Unexpected relationship '$($assigned.Name)' for scope $scope."
            }
            if ($partner -ine (Get-ShortName $hub)) {
                throw "Unexpected partner '$($assigned.PartnerServer)' for scope $scope."
            }
            if ([string]$assigned.Mode -ne 'HotStandby') {
                throw "Scope $scope is not in HotStandby mode."
            }
        }

        $before = Get-LeaseSnapshot $edge $scope (Join-Path $scopeDir 'NewEdge-Leases-Before.csv')
        Get-DhcpServerv4Reservation -ComputerName $edge -ScopeId $scope -ErrorAction Stop |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $scopeDir 'NewEdge-Reservations-Before.csv')

        if ($PreflightOnly) {
            $currentName = if ($assigned) { [string]$assigned.Name } else { 'None' }
            Write-RepairLog "Preflight passed for $scope. Current relationship=$currentName." 'PASS'
            $result = 'PREFLIGHT_PASS'
        } else {
            $backupPath = Join-Path ([string]$row.BackupRoot) ('DHCP_' + (Get-SafeName $edge) + '_' + (Get-SafeName $scope) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            if ($PSCmdlet.ShouldProcess($edge, "Back up DHCP before correcting failover for scope $scope")) {
                New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
                Backup-DhcpServer -ComputerName $edge -Path $backupPath -ErrorAction Stop
            }

            if ($assigned -and [string]$assigned.Name -ieq $newName) {
                Assert-FailoverRole $assigned 'Active' $edge
                Write-RepairLog "Scope $scope is already assigned to '$newName'; validating the completed state." 'WARN'
            } else {
                if ($assigned) {
                    if ($PSCmdlet.ShouldProcess("$($assigned.Name) / $scope", 'Remove old failover scope while retaining NewEdge')) {
                        Remove-DhcpServerv4FailoverScope -ComputerName $edge -Name $assigned.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                }

                $afterDetach = Get-LeaseSnapshot $edge $scope (Join-Path $scopeDir 'NewEdge-Leases-AfterDetach.csv')
                Assert-LeasesPresent $before $afterDetach 'on NewEdge after detach'

                $hubScope = Get-DhcpServerv4Scope -ComputerName $hub -ScopeId $scope -ErrorAction SilentlyContinue
                if ($hubScope) {
                    throw "Scope $scope still exists independently on NewHub $hub after detach. Stopping to avoid overwriting it."
                }

                $existingNew = Get-DhcpServerv4Failover -ComputerName $edge -Name $newName -ErrorAction SilentlyContinue
                if ($existingNew) {
                    if ([string]$existingNew.Mode -ne 'HotStandby' -or
                        (Get-ShortName ([string]$existingNew.PartnerServer)) -ine (Get-ShortName $hub)) {
                        throw "New relationship '$newName' exists with the wrong mode or partner."
                    }
                    Assert-FailoverRole $existingNew 'Active' $edge
                    if ($PSCmdlet.ShouldProcess("$newName / $scope", 'Add scope to existing Edge-active relationship')) {
                        Add-DhcpServerv4FailoverScope -ComputerName $edge -Name $newName -ScopeId $scope -ErrorAction Stop | Out-Null
                    }
                } else {
                    if ($PSCmdlet.ShouldProcess("$newName / $scope", 'Create HotStandby with NewEdge Active and NewHub Standby')) {
                        Add-DhcpServerv4Failover `
                            -ComputerName $edge `
                            -Name $newName `
                            -PartnerServer $hub `
                            -ScopeId $scope `
                            -ServerRole Active `
                            -ReservePercent ([int]$row.ReservePercent) `
                            -MaxClientLeadTime ([timespan]$row.MCLT) `
                            -Force `
                            -ErrorAction Stop | Out-Null
                    }
                }
            }

            Invoke-DhcpServerv4FailoverReplication -ComputerName $edge -Name $newName -Force -ErrorAction Stop
            $final = Wait-FailoverNormal $edge $newName $ReplicationTimeoutSeconds

            $edgeRelationship = Get-DhcpServerv4Failover -ComputerName $edge -ScopeId $scope -ErrorAction Stop
            if ([string]$edgeRelationship.Name -ine $newName -or
                [string]$edgeRelationship.Mode -ne 'HotStandby' -or
                (Get-ShortName ([string]$edgeRelationship.PartnerServer)) -ine (Get-ShortName $hub)) {
                throw 'Final NewEdge relationship validation failed.'
            }
            Assert-FailoverRole $edgeRelationship 'Active' $edge

            $hubRelationship = Get-DhcpServerv4Failover -ComputerName $hub -ScopeId $scope -ErrorAction Stop
            if ([string]$hubRelationship.Name -ine $newName -or [string]$hubRelationship.Mode -ne 'HotStandby') {
                throw 'Final NewHub relationship validation failed.'
            }
            Assert-FailoverRole $hubRelationship 'Standby' $hub

            $hubLeases = Get-LeaseSnapshot $hub $scope (Join-Path $scopeDir 'NewHub-Leases-Final.csv')
            Assert-LeasesPresent $before $hubLeases 'on NewHub after replication'
            $final | Format-List * | Out-File -Width 300 -FilePath (Join-Path $scopeDir 'FinalRelationship.txt')

            Write-RepairLog "PASS ${scope}: NewEdge $edge is Active; NewHub $hub is Standby; relationship='$newName'." 'PASS'
            $result = 'PASS'
        }
    } catch {
        $message = $_.Exception.Message
        Write-RepairLog "FAIL ${scope}: $message" 'ERROR'
        $result = 'FAIL'
    }

    [void]$summary.Add([pscustomobject]@{
        Time = Get-Date
        ScopeId = $scope
        ScopeName = $scopeName
        NewEdge = $edge
        NewHub = $hub
        OldRelationship = $oldName
        NewRelationship = $newName
        Result = $result
        Message = $message
    })
    $summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $runDir 'RepairSummary.csv')

    if ($result -eq 'FAIL' -and $StopOnError) { break }
    if ($index -lt $rows.Count -and $RowDelaySeconds -gt 0) { Start-Sleep -Seconds $RowDelaySeconds }
}

Write-RepairLog "Run complete. Evidence directory: $runDir"
$summary | Format-Table -AutoSize
