#requires -Version 5.1
#requires -RunAsAdministrator
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

function To-Bool([object]$Value, [bool]$Default = $false) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $Default }
    return @('1','true','yes','y') -contains ([string]$Value).Trim().ToLowerInvariant()
}
function ShortName([string]$Name) { return (($Name -split '\.')[0]).Trim() }
function SafeName([string]$Name) { return ($Name -replace '[^A-Za-z0-9_.-]', '_') }
function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $(switch ($Level) { 'PASS' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} 'STEP' {'Cyan'} default {'Gray'} })
    Add-Content -Path $script:LogFile -Value $line
}
function Get-LeaseSnapshot([string]$Server, [string]$ScopeId, [string]$Path) {
    $leases = @(Get-DhcpServerv4Lease -ComputerName $Server -ScopeId $ScopeId -AllLeases -ErrorAction Stop |
        Select-Object @{n='Server';e={$Server}}, ScopeId, IPAddress, ClientId, HostName, AddressState, LeaseExpiryTime)
    $leases | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    return $leases
}
function LeaseKey($Lease) { return '{0}|{1}' -f [string]$Lease.IPAddress, ([string]$Lease.ClientId).ToLowerInvariant() }
function Assert-LeasesPresent([array]$Baseline, [array]$Actual, [string]$Context) {
    $map = @{}; foreach ($item in $Actual) { $map[(LeaseKey $item)] = $true }
    $missing = @($Baseline | Where-Object { -not $map.ContainsKey((LeaseKey $_)) })
    if ($missing.Count) { throw "$($missing.Count) baseline lease(s) are missing $Context." }
}
function Wait-RelationshipNormal([string]$Server, [string]$Name, [int]$TimeoutSeconds) {
    $end = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $fo = Get-DhcpServerv4Failover -ComputerName $Server -Name $Name -ErrorAction Stop
        $state = if ($fo.PSObject.Properties['State']) { [string]$fo.State } elseif ($fo.PSObject.Properties['RelationshipState']) { [string]$fo.RelationshipState } else { '' }
        if ($state -eq 'Normal' -or [string]::IsNullOrWhiteSpace($state)) { return $fo }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $end)
    throw "Relationship '$Name' did not reach Normal within $TimeoutSeconds seconds. Last state='$state'."
}
function Assert-Role([object]$Failover, [string]$ExpectedRole, [string]$Server) {
    $role = ''
    foreach ($property in @('ServerRole','Role')) {
        if ($Failover.PSObject.Properties[$property]) { $role = [string]$Failover.$property; break }
    }
    if (-not [string]::IsNullOrWhiteSpace($role) -and $role -ine $ExpectedRole) {
        throw "Role validation failed on $Server. Expected=$ExpectedRole; Reported=$role."
    }
    if ([string]::IsNullOrWhiteSpace($role)) {
        Write-Log "The local DHCP module did not expose ServerRole/Role on $Server; partner and mode will still be validated." 'WARN'
    }
}

$required = @('Enabled','ScopeId','ScopeName','NewHub','NewEdge','CurrentRelationship','NewRelationship','ReservePercent','MCLT','BackupRoot','OutputRoot')
$rows = @(Import-Csv $ConfigFile | Where-Object { To-Bool $_.Enabled $true })
if (-not $rows.Count) { throw 'No enabled rows were found in the CSV.' }
foreach ($row in $rows) {
    foreach ($column in $required) {
        if (-not $row.PSObject.Properties[$column] -or [string]::IsNullOrWhiteSpace([string]$row.$column)) { throw "Missing or blank CSV column '$column'." }
    }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse(([string]$row.ScopeId).Trim(), [ref]$ip)) { throw "Invalid ScopeId '$($row.ScopeId)'." }
    if ([int]$row.ReservePercent -lt 1 -or [int]$row.ReservePercent -gt 50) { throw "ReservePercent must be 1 through 50 for $($row.ScopeId)." }
    $ts = [timespan]::Zero
    if (-not [timespan]::TryParse(([string]$row.MCLT).Trim(), [ref]$ts) -or $ts -le [timespan]::Zero) { throw "Invalid MCLT '$($row.MCLT)'." }
    if ((ShortName $row.NewEdge) -ine $env:COMPUTERNAME) { throw "This script must run on NewEdge '$($row.NewEdge)'. Current server='$env:COMPUTERNAME'." }
}

$pairGroups = @($rows | Group-Object { '{0}|{1}|{2}' -f (ShortName $_.NewHub).ToLowerInvariant(), (ShortName $_.NewEdge).ToLowerInvariant(), ([string]$_.NewRelationship).Trim().ToLowerInvariant() })
if ($pairGroups.Count -ne 1) { throw 'All enabled rows in one run must use the same NewHub, NewEdge, and NewRelationship.' }
$duplicates = @($rows | Group-Object { ([string]$_.ScopeId).Trim() } | Where-Object Count -gt 1)
if ($duplicates.Count) { throw 'Duplicate enabled ScopeId rows were found.' }

$outputRoot = $rows[0].OutputRoot
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$runDir = Join-Path $outputRoot ('EdgeActiveRepair_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$script:LogFile = Join-Path $runDir 'Repair.log'
$summary = New-Object System.Collections.ArrayList
Write-Log "Loaded $($rows.Count) enabled scope(s). Local NewEdge=$env:COMPUTERNAME. PreflightOnly=$PreflightOnly; WhatIf=$WhatIfPreference."

$index = 0
foreach ($row in $rows) {
    $index++
    $scope = ([string]$row.ScopeId).Trim()
    $scopeName = ([string]$row.ScopeName).Trim()
    $hub = ([string]$row.NewHub).Trim()
    $edge = ([string]$row.NewEdge).Trim()
    $oldName = ([string]$row.CurrentRelationship).Trim()
    $newName = ([string]$row.NewRelationship).Trim()
    $scopeDir = Join-Path $runDir ((SafeName $scope) + '_' + (SafeName $scopeName))
    New-Item -ItemType Directory -Force -Path $scopeDir | Out-Null
    $result = 'FAIL'; $message = ''
    try {
        Write-Log "[$index/$($rows.Count)] Processing $scopeName ($scope)." 'STEP'
        $localScope = Get-DhcpServerv4Scope -ComputerName $edge -ScopeId $scope -ErrorAction Stop
        if (([string]$localScope.Name).Trim() -ine $scopeName) { throw "Scope name mismatch. DHCP='$($localScope.Name)'; CSV='$scopeName'." }

        $assigned = Get-DhcpServerv4Failover -ComputerName $edge -ScopeId $scope -ErrorAction SilentlyContinue
        if ($assigned) {
            $partner = ShortName ([string]$assigned.PartnerServer)
            if (([string]$assigned.Name -ine $oldName) -and ([string]$assigned.Name -ine $newName)) { throw "Unexpected relationship '$($assigned.Name)' for scope $scope." }
            if ($partner -ine (ShortName $hub)) { throw "Unexpected partner '$($assigned.PartnerServer)' for scope $scope." }
            if ([string]$assigned.Mode -ne 'HotStandby') { throw "Scope $scope is not in HotStandby mode." }
        }

        $before = Get-LeaseSnapshot $edge $scope (Join-Path $scopeDir 'NewEdge-Leases-Before.csv')
        Get-DhcpServerv4Reservation -ComputerName $edge -ScopeId $scope -ErrorAction Stop |
            Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $scopeDir 'NewEdge-Reservations-Before.csv')
        $backupPath = Join-Path $row.BackupRoot ('DHCP_' + (SafeName $edge) + '_' + (SafeName $scope) + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))

        if ($PreflightOnly) {
            Write-Log "Preflight passed for $scope. Current relationship=$(if($assigned){$assigned.Name}else{'None'})." 'PASS'
            $result = 'PREFLIGHT_PASS'
        } else {
            if ($PSCmdlet.ShouldProcess($edge, "Back up DHCP and reverse failover role for scope $scope")) {
                New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
                Backup-DhcpServer -ComputerName $edge -Path $backupPath -ErrorAction Stop
            }

            if ($assigned -and [string]$assigned.Name -ieq $newName) {
                Assert-Role $assigned 'Active' $edge
                Write-Log "Scope $scope is already on '$newName'; treating as a resumable completed row." 'WARN'
            } else {
                if ($assigned) {
                    if ($PSCmdlet.ShouldProcess("$oldName / $scope", "Remove failover scope while retaining local NewEdge copy")) {
                        Remove-DhcpServerv4FailoverScope -ComputerName $edge -Name $assigned.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                }

                $afterDetach = Get-LeaseSnapshot $edge $scope (Join-Path $scopeDir 'NewEdge-Leases-AfterDetach.csv')
                Assert-LeasesPresent $before $afterDetach 'on NewEdge after detach'

                $hubScope = Get-DhcpServerv4Scope -ComputerName $hub -ScopeId $scope -ErrorAction SilentlyContinue
                if ($hubScope) { throw "Scope $scope still exists independently on NewHub $hub after detach. Stopping to avoid overwriting it. Review the old relationship removal before retrying." }

                $existingNew = Get-DhcpServerv4Failover -ComputerName $edge -Name $newName -ErrorAction SilentlyContinue
                if ($existingNew) {
                    if ([string]$existingNew.Mode -ne 'HotStandby' -or (ShortName ([string]$existingNew.PartnerServer)) -ine (ShortName $hub)) {
                        throw "New relationship '$newName' exists with the wrong mode or partner."
                    }
                    Assert-Role $existingNew 'Active' $edge
                    if ($PSCmdlet.ShouldProcess("$newName / $scope", 'Add scope to existing Edge-active relationship')) {
                        Add-DhcpServerv4FailoverScope -ComputerName $edge -Name $newName -ScopeId $scope -ErrorAction Stop | Out-Null
                    }
                } else {
                    if ($PSCmdlet.ShouldProcess("$newName / $scope", "Create HotStandby with NewEdge active and NewHub standby")) {
                        Add-DhcpServerv4Failover -ComputerName $edge -Name $newName -PartnerServer $hub -ScopeId $scope -ServerRole Active -ReservePercent ([int]$row.ReservePercent) -MaxClientLeadTime ([timespan]$row.MCLT) -Force -ErrorAction Stop | Out-Null
                    }
                }
            }

            Invoke-DhcpServerv4FailoverReplication -ComputerName $edge -Name $newName -Force -ErrorAction Stop
            $final = Wait-RelationshipNormal $edge $newName $ReplicationTimeoutSeconds
            $scopeFo = Get-DhcpServerv4Failover -ComputerName $edge -ScopeId $scope -ErrorAction Stop
            if ([string]$scopeFo.Name -ine $newName -or [string]$scopeFo.Mode -ne 'HotStandby' -or (ShortName ([string]$scopeFo.PartnerServer)) -ine (ShortName $hub)) { throw 'Final relationship validation failed.' }
            Assert-Role $scopeFo 'Active' $edge
            $hubFo = Get-DhcpServerv4Failover -ComputerName $hub -ScopeId $scope -ErrorAction Stop
            Assert-Role $hubFo 'Standby' $hub
            $hubLeases = Get-LeaseSnapshot $hub $scope (Join-Path $scopeDir 'NewHub-Leases-Final.csv')
            Assert-LeasesPresent $before $hubLeases 'on NewHub after replication'
            $final | Format-List * | Out-File -Width 300 -FilePath (Join-Path $scopeDir 'FinalRelationship.txt')
            Write-Log "PASS $scope: NewEdge $edge is Active; NewHub $hub is Standby; relationship='$newName'." 'PASS'
            $result = 'PASS'
        }
    } catch {
        $message = $_.Exception.Message
        Write-Log "FAIL $scope: $message" 'ERROR'
        $result = 'FAIL'
    }
    [void]$summary.Add([pscustomobject]@{Time=Get-Date;ScopeId=$scope;ScopeName=$scopeName;NewEdge=$edge;NewHub=$hub;OldRelationship=$oldName;NewRelationship=$newName;Result=$result;Message=$message})
    $summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $runDir 'RepairSummary.csv')
    if ($result -eq 'FAIL' -and $StopOnError) { break }
    if ($index -lt $rows.Count -and $RowDelaySeconds -gt 0) { Start-Sleep -Seconds $RowDelaySeconds }
}
Write-Log "Run complete. Evidence directory: $runDir"
$summary | Format-Table -AutoSize
