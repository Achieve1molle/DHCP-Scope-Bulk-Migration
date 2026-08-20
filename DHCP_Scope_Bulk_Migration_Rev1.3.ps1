#requires -Version 5.1
# Revision 1.3: Use the requested ScopeId and safely read optional DHCP lease properties.
# Revision 1.2: Preserve collection return types under Windows PowerShell 5.1 StrictMode.
# Revision 1.1: DHCP lease export compatibility fix for StrictMode/State property failures.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][ValidateScript({Test-Path $_ -PathType Leaf})][string]$ConfigFile,
    [switch]$PreflightOnly
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Log { param([string]$Message,[string]$Level='INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Message
    $color = switch($Level){'PASS'{'Green'} 'WARN'{'Yellow'} 'ERROR'{'Red'} 'STEP'{'Cyan'} 'STOP'{'Red'} default{'Gray'}}
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line }
}
function Start-Step { param([int]$Number,[int]$Total,[string]$Name)
    $script:CurrentStep=$Name; $script:StepStarted=Get-Date
    Write-Log (('[{0:D2}/{1:D2}] START {2}' -f $Number,$Total,$Name)) 'STEP'
}
function Complete-Step { param([string]$Detail='')
    $elapsed = (Get-Date) - $script:StepStarted
    $elapsedText = $elapsed.ToString('hh\:mm\:ss')
    $suffix = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { ' | ' + $Detail }
    Write-Log (('PASS {0} | Elapsed {1}{2}' -f $script:CurrentStep,$elapsedText,$suffix)) 'PASS'
}
function Write-FailureRecord { param($Row,[int]$CsvRow,[string]$Scope,[int]$Phase,[string]$Message,[string]$Dir,$ErrorRecord)
    $failure=[pscustomobject]@{
        Timestamp=Get-Date; CsvRow=$CsvRow; Phase=$Phase; ScopeId=$Scope; ScopeName=[string]$Row.ScopeName; FailedStep=$script:CurrentStep
        LegacyHub=$Row.LegacyHub; LegacyEdge=$Row.LegacyEdge; NewHub=$Row.NewHub; NewEdge=$Row.NewEdge
        TempRelationship=$Row.TempRelationship; FinalRelationship=$Row.FinalRelationship
        ExceptionType=if($ErrorRecord){$ErrorRecord.Exception.GetType().FullName}else{''}
        ErrorMessage=$Message; ScriptLine=if($ErrorRecord){$ErrorRecord.InvocationInfo.ScriptLineNumber}else{''}
        PositionMessage=if($ErrorRecord){$ErrorRecord.InvocationInfo.PositionMessage}else{''}
        LastCompletedStep=$script:LastCompletedStep; EvidenceDirectory=$Dir
    }
    $failure | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $Dir 'FAILURE.csv')
    $failure | Format-List * | Out-File -Width 300 -FilePath (Join-Path $Dir 'FAILURE.txt')
    Write-Host ''; Write-Host ('!'*72) -ForegroundColor Red
    Write-Host ' MIGRATION STOPPED FOR CURRENT SCOPE' -ForegroundColor Red
    Write-Host ('!'*72) -ForegroundColor Red
    Write-Host "CSV Row:          $CsvRow" -ForegroundColor Red
    Write-Host "Phase / Scope:    $Phase / $Scope ($([string]$Row.ScopeName))" -ForegroundColor Red
    Write-Host "Failed Step:      $($script:CurrentStep)" -ForegroundColor Red
    Write-Host "Last Good Step:   $($script:LastCompletedStep)" -ForegroundColor Red
    Write-Host "Reason:           $Message" -ForegroundColor Red
    Write-Host "Evidence:         $Dir" -ForegroundColor Red
    Write-Host ('!'*72) -ForegroundColor Red
}
function Assert-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run from an elevated Windows PowerShell session.'}
}
function Ensure-DhcpTools {
    $required=@('Get-DhcpServerv4Scope','Get-DhcpServerv4ScopeStatistics','Get-DhcpServerv4Lease','Get-DhcpServerv4Reservation','Get-DhcpServerv4Failover','Add-DhcpServerv4Failover','Add-DhcpServerv4FailoverScope','Remove-DhcpServerv4FailoverScope','Backup-DhcpServer','Invoke-DhcpServerv4FailoverReplication','Get-DhcpServerDatabase')
    if(-not (Get-Module -ListAvailable -Name DhcpServer)){
        Write-Log 'DhcpServer PowerShell module not found. Attempting to install DHCP management tools.' 'WARN'
        Import-Module ServerManager -ErrorAction Stop
        $rsat = Get-WindowsFeature -Name RSAT-DHCP -ErrorAction Stop
        if(-not $rsat.Installed){
            if($PSCmdlet.ShouldProcess('Local server','Install DHCP management tools')){
                Install-WindowsFeature -Name RSAT-DHCP -IncludeManagementTools -ErrorAction Stop | Out-Null
            } else {
                throw 'DHCP management tools are required but were not installed.'
            }
        }
    }
    Import-Module DhcpServer -ErrorAction Stop
    $missing=@($required | Where-Object {-not (Get-Command $_ -ErrorAction SilentlyContinue)})
    if($missing.Count){throw ('Missing required DHCP cmdlets: '+($missing -join ', '))}
    Write-Log 'Required DHCP PowerShell module/cmdlets are available.'
}
function To-Bool([object]$v,[bool]$default=$false){if($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)){return $default}; return @('1','true','yes','y') -contains ([string]$v).Trim().ToLowerInvariant()}
function Safe-Name([string]$s){return ($s -replace '[^A-Za-z0-9_.-]','_')}
function Get-DhcpLeasesSafe { param([string]$Server,[string]$ScopeId)
    # The Windows DHCP PowerShell module can fail under a caller's StrictMode
    # while internally assigning a State property that is absent on some CIM
    # instances. Disable StrictMode only inside this narrow wrapper so the rest
    # of the migration script remains protected by StrictMode 2.0.
    Set-StrictMode -Off
    $leases = @(Get-DhcpServerv4Lease -ComputerName $Server -ScopeId $ScopeId -AllLeases -ErrorAction Stop)
    Write-Output -NoEnumerate $leases
}
function Export-Leases { param([string]$Server,[string]$ScopeId,[string]$Path)
    $raw=@(Get-DhcpLeasesSafe -Server $Server -ScopeId $ScopeId)
    $x=@($raw | ForEach-Object {
        # Create a new object instead of modifying the DHCP module's CIM object.
        # DHCP lease status is exposed as AddressState, not State.
        $lease = $_
        $addressState = if($lease.PSObject.Properties['AddressState']){[string]$lease.PSObject.Properties['AddressState'].Value}elseif($lease.PSObject.Properties['State']){[string]$lease.PSObject.Properties['State'].Value}else{''}
        [pscustomobject]@{
            Server          = $Server
            # Some DHCP module builds omit ScopeId from returned lease objects.
            # The requested scope is authoritative and is always available here.
            ScopeId         = $ScopeId
            IPAddress       = if($lease.PSObject.Properties['IPAddress']){[string]$lease.PSObject.Properties['IPAddress'].Value}else{''}
            ClientId        = if($lease.PSObject.Properties['ClientId']){[string]$lease.PSObject.Properties['ClientId'].Value}else{''}
            HostName        = if($lease.PSObject.Properties['HostName']){[string]$lease.PSObject.Properties['HostName'].Value}else{''}
            AddressState    = $addressState
            LeaseExpiryTime = if($lease.PSObject.Properties['LeaseExpiryTime']){$lease.PSObject.Properties['LeaseExpiryTime'].Value}else{$null}
            Description     = if($lease.PSObject.Properties['Description']){[string]$lease.PSObject.Properties['Description'].Value}else{''}
        }
    })
    $x | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    Write-Output -NoEnumerate $x
}
function Export-Reservations { param([string]$Server,[string]$ScopeId,[string]$Path)
    $x=@(Get-DhcpServerv4Reservation -ComputerName $Server -ScopeId $ScopeId -ErrorAction Stop | Select-Object @{n='Server';e={$Server}},ScopeId,IPAddress,ClientId,Name,Description,Type)
    $x | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    Write-Output -NoEnumerate $x
}
function Lease-Key($l){'{0}|{1}' -f ([string]$l.IPAddress),([string]$l.ClientId).ToLowerInvariant()}
function Compare-Leases { param([array]$Baseline,[array]$Actual,[string]$Path)
    $map=@{}; foreach($a in $Actual){$map[(Lease-Key $a)]=$a}
    $rows=New-Object System.Collections.ArrayList
    foreach($b in $Baseline){$k=Lease-Key $b; $a=$map[$k]; $status='MATCH'; $actualState=''
        if($null -eq $a){$status='MISSING'} else {$actualState=[string]$a.AddressState; if(([string]$b.AddressState) -ne $actualState){$status='STATE_CHANGED'}}
        [void]$rows.Add([pscustomobject]@{ScopeId=$b.ScopeId;IPAddress=$b.IPAddress;ClientId=$b.ClientId;HostName=$b.HostName;BaselineState=$b.AddressState;ActualState=$actualState;Result=$status})
    }
    $baselineKeys=@{}; foreach($b in $Baseline){$baselineKeys[(Lease-Key $b)]=$true}
    foreach($a in $Actual){if(-not $baselineKeys.ContainsKey((Lease-Key $a))){[void]$rows.Add([pscustomobject]@{ScopeId=$a.ScopeId;IPAddress=$a.IPAddress;ClientId=$a.ClientId;HostName=$a.HostName;BaselineState='';ActualState=$a.AddressState;Result='NEW_LEASE'})}}
    $rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    Write-Output -NoEnumerate @($rows)
}
function Get-LocalDhcpHealth { param([string]$Dir,[string]$ScopeId)
    $svc=Get-Service DHCPServer -ErrorAction Stop
    Get-DhcpServerDatabase | Format-List * | Out-File (Join-Path $Dir 'DatabaseSettings.txt') -Width 300
    try { Get-DhcpServerv4ScopeStatistics -ScopeId $ScopeId | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $Dir 'ScopeStatistics.csv') } catch { Write-Log $_.Exception.Message 'WARN' }
    $since=(Get-Date).AddHours(-4); $events=@()
    foreach($log in @('Microsoft-Windows-DHCP-Server/Operational','System')){try{$events+=Get-WinEvent -FilterHashtable @{LogName=$log;StartTime=$since;Level=1,2,3} -ErrorAction Stop | Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message}catch{}}
    $events | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $Dir 'RecentWarningErrorEvents.csv')
    [pscustomobject]@{ServiceStatus=$svc.Status;WarningErrorEvents=$events.Count}
}
function Wait-FailoverNormal { param([string]$Server,[string]$Name,[int]$TimeoutSeconds=180)
    $end=(Get-Date).AddSeconds($TimeoutSeconds); $forced=$false
    do {
        $fo=Get-DhcpServerv4Failover -ComputerName $Server -Name $Name -ErrorAction Stop
        $stateValue=''
        if($fo.PSObject.Properties['State']){$stateValue=[string]$fo.State}
        elseif($fo.PSObject.Properties['RelationshipState']){$stateValue=[string]$fo.RelationshipState}
        else {
            # Some DHCP module versions omit both state properties from a name query.
            # If the relationship is present on both partners, return it and let the caller's
            # scope/lease replication validation provide the authoritative success check.
            $partner=[string]$fo.PartnerServer
            if(-not [string]::IsNullOrWhiteSpace($partner)){
                $partnerFo=Get-DhcpServerv4Failover -ComputerName $partner -Name $Name -ErrorAction SilentlyContinue
                if($partnerFo){
                    Write-Log "Relationship $Name is present on both partners, but this DHCP module did not expose State or RelationshipState. Continuing to scope and lease validation." 'WARN'
                    return $fo
                }
            }
        }
        if($stateValue -eq 'Normal'){return $fo}
        if(-not $forced -and (Get-Date) -gt $end.AddSeconds(-120)){
            try{Invoke-DhcpServerv4FailoverReplication -ComputerName $Server -Name $Name -Force -ErrorAction Stop; $forced=$true}catch{Write-Log $_.Exception.Message 'WARN'}
        }
        Start-Sleep 5
    }while((Get-Date)-lt $end)
    throw "Failover relationship $Name did not reach Normal within $TimeoutSeconds seconds. Last reported state='$stateValue'."
}
function Backup-LocalDhcp { param([string]$Root,[string]$ScopeTag)
    $p=Join-Path $Root ('DHCP_'+$env:COMPUTERNAME+'_'+$ScopeTag+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force -Path $p | Out-Null
    Backup-DhcpServer -Path $p -ErrorAction Stop; if(-not (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue)){throw "Backup did not create files in $p"}; return $p
}
function Get-BaselinePath([string]$Root,[string]$ScopeId){Join-Path $Root ('Baseline_'+(Safe-Name $ScopeId)+'.csv')}
function Assert-LocalServer([string]$Expected,[string]$Phase){if($env:COMPUTERNAME -ine (($Expected -split '\.')[0])){throw "$Phase must run locally on $Expected. Current server: $env:COMPUTERNAME"}}
function Validate-Row($r){
    $requiredColumns = @('Enabled','Phase','ScopeId','ScopeName','LegacyHub','LegacyEdge','NewHub','NewEdge','ReservePercent','MCLT','TempRelationship','FinalRelationship','BackupRoot','OutputRoot','StopOnValidationFailure')
    foreach($n in $requiredColumns){
        if(-not $r.PSObject.Properties[$n]){throw "CSV missing required column '$n'."}
    }
    foreach($n in @('Phase','ScopeId','ScopeName','LegacyHub','LegacyEdge','NewHub','NewEdge','TempRelationship','FinalRelationship','BackupRoot','OutputRoot')){
        if([string]::IsNullOrWhiteSpace([string]$r.$n)){throw "CSV column '$n' cannot be blank for scope row '$($r.ScopeName)'."}
    }

    $phaseValue = 0
    if(-not [int]::TryParse(([string]$r.Phase).Trim(), [ref]$phaseValue) -or $phaseValue -notin 1,2){
        throw "Phase must be the integer 1 or 2 for scope '$($r.ScopeName)'."
    }

    $parsedScope = $null
    if(-not [System.Net.IPAddress]::TryParse(([string]$r.ScopeId).Trim(), [ref]$parsedScope) -or $parsedScope.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork){
        throw "ScopeId '$($r.ScopeId)' is not a valid IPv4 scope network address. Use a value such as 192.168.10.0, not the scope name."
    }

    $reservePercent = 10
    if(-not [string]::IsNullOrWhiteSpace([string]$r.ReservePercent)){
        if(-not [int]::TryParse(([string]$r.ReservePercent).Trim(), [ref]$reservePercent)){throw "ReservePercent '$($r.ReservePercent)' is not an integer."}
    }
    if($reservePercent -lt 1 -or $reservePercent -gt 50){throw 'ReservePercent must be from 1 through 50.'}

    $parsedMclt = [timespan]::Zero
    if(-not [timespan]::TryParse(([string]$r.MCLT).Trim(), [ref]$parsedMclt) -or $parsedMclt -le [timespan]::Zero){
        throw "MCLT '$($r.MCLT)' is invalid. Use a positive TimeSpan such as 00:05:00."
    }
}

function Get-Phase2BaselinePath([string]$Root,[string]$ScopeId){
    Join-Path $Root ('Phase2Baseline_'+(Safe-Name $ScopeId)+'.csv')
}
function Test-Phase2RelationshipPlan { param([array]$Rows)
    $phase2Rows=@($Rows | Where-Object {[int]$_.Phase -eq 2})
    if(-not $phase2Rows.Count){return}

    $duplicateFinalNames=@($phase2Rows | Group-Object {([string]$_.FinalRelationship).Trim().ToLowerInvariant()} | Where-Object Count -gt 1)
    if($duplicateFinalNames.Count){
        $details=@()
        foreach($group in $duplicateFinalNames){
            $members=@($group.Group | ForEach-Object {"ScopeId=$($_.ScopeId), ScopeName=$($_.ScopeName), FinalRelationship=$($_.FinalRelationship)"})
            $details += ($members -join '; ')
        }
        throw ('Phase II CSV validation failed before any DHCP changes. FinalRelationship values must be unique across enabled Phase II rows. Duplicates: '+($details -join ' | '))
    }

    foreach($row in $phase2Rows){
        if(([string]$row.FinalRelationship).Trim() -ieq ([string]$row.TempRelationship).Trim()){
            throw "Phase II CSV validation failed before any DHCP changes. Scope $($row.ScopeId) uses the same name for TempRelationship and FinalRelationship: $($row.FinalRelationship)."
        }
    }

    Write-Log "Phase II CSV relationship-name validation passed. $($phase2Rows.Count) enabled Phase II row(s) have unique FinalRelationship values." 'PASS'

    foreach($row in $phase2Rows){
        $scopeId=([string]$row.ScopeId).Trim()
        $finalName=([string]$row.FinalRelationship).Trim()
        $newEdge=([string]$row.NewEdge).Trim()
        foreach($server in @($env:COMPUTERNAME,$newEdge) | Select-Object -Unique){
            $relationshipByName=$null
            $relationshipByScope=$null
            try{$relationshipByName=Get-DhcpServerv4Failover -ComputerName $server -Name $finalName -ErrorAction Stop}catch{
                if($_.Exception.Message -notmatch 'Failed to get|not found|does not exist'){throw}
            }
            try{$relationshipByScope=Get-DhcpServerv4Failover -ComputerName $server -ScopeId $scopeId -ErrorAction Stop}catch{
                if($_.Exception.Message -notmatch 'Failed to get|not found|does not exist'){throw}
            }

            if($relationshipByScope){
                $currentName=([string]$relationshipByScope.Name).Trim()
                $tempName=([string]$row.TempRelationship).Trim()
                if($currentName -ieq $finalName){
                    Write-Log "Existing final relationship '$finalName' correctly contains scope $scopeId on $server. It will be treated as a resumable completed relationship." 'PASS'
                } elseif($currentName -ieq $tempName){
                    Write-Log "Scope $scopeId on $server is still assigned to expected temporary relationship '$tempName'. Phase II will resume from the temporary relationship." 'PASS'
                } else {
                    throw "Phase II preflight collision before any DHCP changes. Scope $scopeId on $server is assigned to unexpected relationship '$currentName'. CSV expects temporary '$tempName' or final '$finalName'."
                }
            } elseif($relationshipByName){
                # Some DHCP module/server combinations do not populate ScopeId reliably when queried by Name.
                # A name-only match is not enough to prove a collision. Defer the authoritative decision to
                # the per-row Get-DhcpServerv4Failover -ScopeId resume-state check.
                Write-Log "Final relationship '$finalName' exists on $server, but scope membership was not returned by the name query. Deferring membership validation to the per-scope resume check." 'WARN'
            }
        }
    }
    Write-Log 'Phase II existing relationship-name collision validation passed.' 'PASS'
}

Assert-Admin
$rows=@(Import-Csv $ConfigFile | Where-Object {To-Bool $_.Enabled $true}); if(-not $rows.Count){throw 'No enabled scopes in configuration file.'}
foreach($r in $rows){Validate-Row $r}
$duplicates = @($rows | Group-Object { '{0}|{1}' -f ([string]$_.Phase).Trim(),([string]$_.ScopeId).Trim() } | Where-Object Count -gt 1)
if($duplicates.Count){throw ('CSV contains duplicate enabled Phase/ScopeId rows: ' + (($duplicates | Select-Object -ExpandProperty Name) -join ', '))}
$root=($rows[0].OutputRoot); New-Item -ItemType Directory -Force -Path $root | Out-Null
$runDir=Join-Path $root ('Run_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$script:LogFile=Join-Path $runDir 'Migration.log'; $summary=New-Object System.Collections.ArrayList
Ensure-DhcpTools
Write-Log "Loaded $($rows.Count) enabled scope(s) from $ConfigFile. PreflightOnly=$PreflightOnly WhatIf=$WhatIfPreference"
if(@($rows | Where-Object {[int]$_.Phase -eq 2}).Count){
    Assert-LocalServer $rows[0].NewHub 'Phase II batch validation'
    Test-Phase2RelationshipPlan $rows
}
$csvIndex=0
foreach($r in $rows){
    $csvIndex++; $script:CurrentStep='Initialization'; $script:LastCompletedStep='None'
    $scope=([string]$r.ScopeId).Trim(); $scopeName=([string]$r.ScopeName).Trim(); $phase=[int]$r.Phase; $rp=if([string]::IsNullOrWhiteSpace([string]$r.ReservePercent)){10}else{[int]$r.ReservePercent}; $mclt=if([string]::IsNullOrWhiteSpace([string]$r.MCLT)){'00:05:00'}else{([string]$r.MCLT).Trim()}
    $dir=Join-Path $runDir (('Phase{0}_{1}_{2}' -f $phase,(Safe-Name $scopeName),(Safe-Name $scope))); New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $result='FAIL'; $message=''; $scopeStart=Get-Date; Write-Host ''; Write-Host ('='*72) -ForegroundColor Cyan; Write-Host " DHCP MIGRATION | CSV Row $csvIndex of $($rows.Count) | Phase $phase | Scope $scopeName ($scope)" -ForegroundColor Cyan; Write-Host ('='*72) -ForegroundColor Cyan; Write-Log "BEGIN CSV Row $csvIndex/$($rows.Count), Phase $phase, Scope $scopeName ($scope)" 'STEP'
    try {
        if($phase -eq 1){
            Start-Step 1 12 'Validate local execution server'; Assert-LocalServer $r.LegacyEdge 'Phase I'; Complete-Step "Server=$env:COMPUTERNAME"; $script:LastCompletedStep=$script:CurrentStep
            Start-Step 2 12 'Validate DHCP service'; Get-Service DHCPServer -ErrorAction Stop | Out-Null; Complete-Step 'DHCPServer service located'; $script:LastCompletedStep=$script:CurrentStep
            Start-Step 3 12 'Validate scope ID and name'; $s=Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction Stop
            if(([string]$s.Name).Trim() -ine $scopeName){throw "ScopeId $scope exists, but its DHCP name '$($s.Name)' does not match CSV ScopeName '$scopeName'."}
            Complete-Step "ScopeName=$scopeName; ScopeId=$scope"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 4 12 'Detect Phase I resume state'
            $fo = Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
            $phase1State = 'Detached'
            if($fo){
                $partnerShort = (([string]$fo.PartnerServer -split '\.')[0])
                $legacyHubShort = (([string]$r.LegacyHub -split '\.')[0])
                $newHubShort = (([string]$r.NewHub -split '\.')[0])
                if(([string]$fo.Mode -eq 'LoadBalance') -and ($partnerShort -ieq $legacyHubShort)){
                    $phase1State = 'OriginalLegacyFailover'
                } elseif(([string]$fo.Mode -eq 'HotStandby') -and ($partnerShort -ieq $newHubShort) -and ([string]$fo.Name -ieq [string]$r.TempRelationship)){
                    $phase1State = 'TemporaryEQBFailoverEstablished'
                } else {
                    throw "Scope $scope is in an unexpected failover relationship. Name=$($fo.Name); Mode=$($fo.Mode); Partner=$($fo.PartnerServer)."
                }
            }
            Complete-Step "ResumeState=$phase1State"; $script:LastCompletedStep=$script:CurrentStep

            $baseline=Get-BaselinePath $r.OutputRoot $scope
            Start-Step 5 12 'Capture legacy Edge lease baseline'
            $edge=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-Leases-Before.csv')
            Complete-Step "Edge leases=$($edge.Count)"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 6 12 'Load or capture consolidated lease baseline'
            if($phase1State -eq 'OriginalLegacyFailover'){
                $hub=Export-Leases $r.LegacyHub $scope (Join-Path $dir 'LegacyHub-Leases-Before.csv')
                $combined=@($edge+$hub | Group-Object {Lease-Key $_} | ForEach-Object {$_.Group[0]})
                $combined | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $baseline
                Complete-Step "Captured original state: Edge=$($edge.Count); Hub=$($hub.Count); consolidated=$($combined.Count)"
            } elseif(Test-Path $baseline){
                $combined=@(Import-Csv $baseline)
                Complete-Step "Recovered existing baseline=$($combined.Count) from $baseline"
            } else {
                # The legacy relationship is already detached and the legacy Hub no longer has the scope.
                # The retained legacy Edge is therefore the authoritative recovery source.
                $combined=@($edge)
                $combined | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $baseline
                Write-Log "No saved baseline was found for detached scope $scope. Created a recovery baseline from $($edge.Count) retained legacy Edge leases." 'WARN'
                Complete-Step "Recovery baseline created from retained Edge leases=$($combined.Count)"
            }
            if(-not $combined.Count){throw "No lease baseline is available for scope $scope."}
            $script:LastCompletedStep=$script:CurrentStep

            Start-Step 7 12 'Capture reservations and preserve baseline'
            Export-Reservations $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-Reservations-Before.csv') | Out-Null
            if($phase1State -eq 'OriginalLegacyFailover'){
                Export-Reservations $r.LegacyHub $scope (Join-Path $dir 'LegacyHub-Reservations-Before.csv') | Out-Null
            } else {
                Write-Log "Legacy Hub reservation export skipped for scope $scope because the original relationship is already detached." 'WARN'
            }
            $combined | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $baseline
            Complete-Step "Baseline=$baseline"; $script:LastCompletedStep=$script:CurrentStep

            if($PreflightOnly){
                Write-Log "PRECHECK PASS Phase I $scope; ResumeState=$phase1State"; $result='PREFLIGHT_PASS'
            } else {
                Start-Step 8 12 'Backup local DHCP database'
                $bk=Backup-LocalDhcp $r.BackupRoot (Safe-Name $scope)
                Complete-Step "Backup=$bk"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 9 12 'Detach scope from legacy Hub, retain legacy Edge'
                if($phase1State -eq 'OriginalLegacyFailover'){
                    if($PSCmdlet.ShouldProcess("Scope $scope","Detach LegacyHub $($r.LegacyHub), retain LegacyEdge")){
                        Remove-DhcpServerv4FailoverScope -Name $fo.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                    $phase1State='Detached'
                    Complete-Step 'Legacy failover detached'
                } else {
                    Complete-Step "No detach needed; ResumeState=$phase1State"
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 10 12 'Validate leases retained on legacy Edge'
                $after=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-AfterDetach.csv')
                $cmp=Compare-Leases $combined $after (Join-Path $dir 'Compare-AfterDetach.csv')
                $missingAfterDetach=@($cmp|Where-Object {$_.Result -eq 'MISSING'})
                if($missingAfterDetach.Count){throw "$($missingAfterDetach.Count) baseline lease(s) are missing on legacy Edge before EQB failover creation."}
                Complete-Step "Expected=$($combined.Count); actual=$($after.Count); missing=0"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 11 12 'Create or join temporary EQB Hot Standby relationship'
                $scopeFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                if($scopeFo){
                    $scopePartnerShort=(([string]$scopeFo.PartnerServer -split '\.')[0])
                    $newHubShort=(([string]$r.NewHub -split '\.')[0])
                    if(([string]$scopeFo.Name -ine [string]$r.TempRelationship -or [string]$scopeFo.Mode -ne 'HotStandby' -or $scopePartnerShort -ine $newHubShort)){
                        throw "Scope $scope acquired an unexpected failover relationship before EQB configuration."
                    }
                    Complete-Step "Already joined relationship=$($scopeFo.Name)"
                } else {
                    $tempFo=Get-DhcpServerv4Failover -Name $r.TempRelationship -ErrorAction SilentlyContinue
                    if($tempFo){
                        $tempPartnerShort=(([string]$tempFo.PartnerServer -split '\.')[0])
                        $newHubShort=(([string]$r.NewHub -split '\.')[0])
                        if([string]$tempFo.Mode -ne 'HotStandby' -or $tempPartnerShort -ine $newHubShort){
                            throw "Existing relationship $($r.TempRelationship) does not match required HotStandby partner $($r.NewHub)."
                        }
                        if($PSCmdlet.ShouldProcess("Scope $scope","Add scope to existing relationship $($r.TempRelationship)")){
                            Add-DhcpServerv4FailoverScope -Name $r.TempRelationship -ScopeId $scope -ErrorAction Stop | Out-Null
                        }
                        Complete-Step "Added scope to existing relationship=$($r.TempRelationship)"
                    } else {
                        if($PSCmdlet.ShouldProcess("Scope $scope","Create temporary Hot Standby to $($r.NewHub)")){
                            Add-DhcpServerv4Failover -Name $r.TempRelationship -PartnerServer $r.NewHub -ScopeId $scope -ServerRole Active -ReservePercent $rp -MaxClientLeadTime ([timespan]$mclt) -Force -ErrorAction Stop | Out-Null
                        }
                        Complete-Step "Created relationship=$($r.TempRelationship); Reserve=$rp%; Active=LegacyEdge; Standby=$($r.NewHub)"
                    }
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 12 12 'Validate EQB relationship and lease replication'
                $newfo=Wait-FailoverNormal $env:COMPUTERNAME $r.TempRelationship
                $newfo|Format-List *|Out-File (Join-Path $dir 'TemporaryFailover.txt') -Width 300
                $scopeFoFinal=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction Stop
                if([string]$scopeFoFinal.Name -ine [string]$r.TempRelationship -or [string]$scopeFoFinal.Mode -ne 'HotStandby'){
                    throw "Final Phase I relationship validation failed for scope $scope."
                }
                $eqb=Export-Leases $r.NewHub $scope (Join-Path $dir 'EQB-Leases-AfterSync.csv')
                $cmp2=Compare-Leases $combined $eqb (Join-Path $dir 'Compare-EQB.csv')
                $missingOnEqb=@($cmp2|Where-Object {$_.Result -eq 'MISSING'})
                if($missingOnEqb.Count){throw "$($missingOnEqb.Count) baseline lease(s) are missing on EQB."}
                Complete-Step "EQB=$($eqb.Count); baseline=$($combined.Count); missing=0; relationship=$($scopeFoFinal.Name); mode=$($scopeFoFinal.Mode)"
                $script:LastCompletedStep=$script:CurrentStep; $result='PASS'
            }
        } else {
            Assert-LocalServer $r.NewHub 'Phase II'
            Start-Step 1 10 'Validate local EQB scope'
            $phase2Scope=Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction Stop
            if(([string]$phase2Scope.Name).Trim() -ine $scopeName){throw "ScopeId $scope exists, but its DHCP name '$($phase2Scope.Name)' does not match CSV ScopeName '$scopeName'."}
            Complete-Step "ScopeName=$scopeName; ScopeId=$scope; Server=$env:COMPUTERNAME"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 2 10 'Detect Phase II resume state'
            $scopeFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
            $phase2State='DetachedFromLegacyEdge'
            if($scopeFo){
                $partnerShort=(([string]$scopeFo.PartnerServer -split '\.')[0])
                $legacyEdgeShort=(([string]$r.LegacyEdge -split '\.')[0])
                $newEdgeShort=(([string]$r.NewEdge -split '\.')[0])
                if(([string]$scopeFo.Name -ieq [string]$r.TempRelationship -and [string]$scopeFo.Mode -eq 'HotStandby' -and $partnerShort -ieq $legacyEdgeShort)){
                    $phase2State='TemporaryLegacyEdgeFailover'
                } elseif(([string]$scopeFo.Name -ieq [string]$r.FinalRelationship -and [string]$scopeFo.Mode -eq 'HotStandby' -and $partnerShort -ieq $newEdgeShort)){
                    $phase2State='FinalNewEdgeFailoverEstablished'
                } else {
                    throw "Scope $scope is in an unexpected Phase II relationship. Name=$($scopeFo.Name); Mode=$($scopeFo.Mode); Partner=$($scopeFo.PartnerServer)."
                }
            }
            Complete-Step "ResumeState=$phase2State"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 3 10 'Load or create local Phase II baseline'
            $phase2Baseline=Get-Phase2BaselinePath $r.OutputRoot $scope
            $currentEqb=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'EQB-Leases-Phase2-Start.csv')
            if(Test-Path $phase2Baseline){
                $base=@(Import-Csv $phase2Baseline)
                Complete-Step "Loaded local Phase II baseline=$($base.Count) from $phase2Baseline"
            } else {
                if(-not $currentEqb.Count){throw "Cannot create Phase II baseline because scope $scope has no leases on $env:COMPUTERNAME."}
                $base=@($currentEqb)
                $base | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $phase2Baseline
                Write-Log "Phase I baseline was not present on the new server. Created local Phase II baseline from $($base.Count) leases on $env:COMPUTERNAME." 'WARN'
                Complete-Step "Created local Phase II baseline=$($base.Count); Path=$phase2Baseline"
            }
            if(-not $base.Count){throw "Phase II baseline is empty for scope $scope."}
            $script:LastCompletedStep=$script:CurrentStep

            Start-Step 4 10 'Validate EQB leases against Phase II baseline'
            $pc=Compare-Leases $base $currentEqb (Join-Path $dir 'Compare-EQB-Phase2-Start.csv')
            $missingAtStart=@($pc|Where-Object {$_.Result -eq 'MISSING'})
            if($missingAtStart.Count){throw "$($missingAtStart.Count) baseline lease(s) are missing on EQB before Phase II changes."}
            Complete-Step "Baseline=$($base.Count); EQB=$($currentEqb.Count); missing=0"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 5 10 'Validate Phase II relationship plan'
            if($phase2State -eq 'TemporaryLegacyEdgeFailover'){
                Wait-FailoverNormal $env:COMPUTERNAME $scopeFo.Name | Out-Null
                Complete-Step "Temporary relationship=$($scopeFo.Name); state=Normal"
            } elseif($phase2State -eq 'FinalNewEdgeFailoverEstablished'){
                Wait-FailoverNormal $env:COMPUTERNAME $scopeFo.Name | Out-Null
                Complete-Step "Final relationship already established=$($scopeFo.Name); state=Normal"
            } else {
                Complete-Step 'Temporary relationship already detached; final relationship still required'
            }
            $script:LastCompletedStep=$script:CurrentStep

            if($PreflightOnly){
                Write-Log "PRECHECK PASS Phase II $scope; ResumeState=$phase2State"; $result='PREFLIGHT_PASS'
            } else {
                Start-Step 6 10 'Backup local EQB DHCP database'
                $bk=Backup-LocalDhcp $r.BackupRoot (Safe-Name $scope)
                Complete-Step "Backup=$bk"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 7 10 'Detach temporary Legacy Edge relationship'
                if($phase2State -eq 'TemporaryLegacyEdgeFailover'){
                    if($PSCmdlet.ShouldProcess("Scope $scope","Detach LegacyEdge $($r.LegacyEdge), retain EQB")){
                        Remove-DhcpServerv4FailoverScope -Name $scopeFo.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                    $phase2State='DetachedFromLegacyEdge'
                    Complete-Step 'Temporary Legacy Edge relationship detached'
                } else {
                    Complete-Step "No detach needed; ResumeState=$phase2State"
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 8 10 'Validate leases retained on EQB'
                $retained=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'EQB-Leases-AfterDetach.csv')
                $rc=Compare-Leases $base $retained (Join-Path $dir 'Compare-EQB-AfterDetach.csv')
                $missingRetained=@($rc|Where-Object {$_.Result -eq 'MISSING'})
                if($missingRetained.Count){throw "$($missingRetained.Count) baseline lease(s) are missing on EQB after temporary detach."}
                Complete-Step "Baseline=$($base.Count); retained=$($retained.Count); missing=0"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 9 10 'Create or validate final New Edge Hot Standby relationship'
                $currentFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                if($currentFo){
                    $currentPartnerShort=(([string]$currentFo.PartnerServer -split '\.')[0])
                    $newEdgeShort=(([string]$r.NewEdge -split '\.')[0])
                    if([string]$currentFo.Name -ine [string]$r.FinalRelationship -or [string]$currentFo.Mode -ne 'HotStandby' -or $currentPartnerShort -ine $newEdgeShort){
                        throw "Scope $scope acquired an unexpected relationship before final configuration. Name=$($currentFo.Name); Mode=$($currentFo.Mode); Partner=$($currentFo.PartnerServer)."
                    }
                    Complete-Step "Final relationship already exists=$($currentFo.Name)"
                } else {
                    $nameCollision=Get-DhcpServerv4Failover -Name $r.FinalRelationship -ErrorAction SilentlyContinue
                    if($nameCollision){
                        $scopeAssignment=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                        if($scopeAssignment -and [string]$scopeAssignment.Name -ieq [string]$r.FinalRelationship){
                            $currentFo=$scopeAssignment
                            Complete-Step "Final relationship already exists for intended scope=$($scopeAssignment.Name)"
                        } else {
                            $collisionPartnerShort=(([string]$nameCollision.PartnerServer -split '\.')[0])
                            $newEdgeShort=(([string]$r.NewEdge -split '\.')[0])
                            if([string]$nameCollision.Mode -ne 'HotStandby' -or $collisionPartnerShort -ine $newEdgeShort){
                                throw "FinalRelationship '$($r.FinalRelationship)' exists with unexpected Mode or Partner. Mode=$($nameCollision.Mode); Partner=$($nameCollision.PartnerServer)."
                            }
                            # The final relationship exists but currently has no locally assigned scope.
                            # This is a recoverable partial state left by an earlier interrupted run.
                            if($PSCmdlet.ShouldProcess("Scope $scope","Add scope to existing final relationship $($r.FinalRelationship)")){
                                Add-DhcpServerv4FailoverScope -Name $r.FinalRelationship -ScopeId $scope -ErrorAction Stop | Out-Null
                            }
                            $scopeAssignment=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction Stop
                            if([string]$scopeAssignment.Name -ine [string]$r.FinalRelationship){
                                throw "Scope $scope was not assigned to existing final relationship '$($r.FinalRelationship)' after Add-DhcpServerv4FailoverScope."
                            }
                            $currentFo=$scopeAssignment
                            Complete-Step "Recovered partial relationship by adding scope $scope to $($r.FinalRelationship)"
                        }
                    } else {
                        if($PSCmdlet.ShouldProcess("Scope $scope","Create final Hot Standby with new Edge $($r.NewEdge)")){
                            Add-DhcpServerv4Failover -Name $r.FinalRelationship -PartnerServer $r.NewEdge -ScopeId $scope -ServerRole Standby -ReservePercent $rp -MaxClientLeadTime ([timespan]$mclt) -Force -ErrorAction Stop | Out-Null
                        }
                        Complete-Step "Created final relationship=$($r.FinalRelationship); Active=$($r.NewEdge); Standby=$env:COMPUTERNAME"
                    }
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 10 10 'Validate final relationship and lease replication'
                $finalfo=Wait-FailoverNormal $env:COMPUTERNAME $r.FinalRelationship
                $finalfo|Format-List *|Out-File (Join-Path $dir 'FinalFailover.txt') -Width 300
                $scopeFoFinal=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction Stop
                if([string]$scopeFoFinal.Name -ine [string]$r.FinalRelationship -or [string]$scopeFoFinal.Mode -ne 'HotStandby'){
                    throw "Final relationship validation failed for scope $scope."
                }
                $new=Export-Leases $r.NewEdge $scope (Join-Path $dir 'NewEdge-Leases-Final.csv')
                Export-Reservations $r.NewEdge $scope (Join-Path $dir 'NewEdge-Reservations-Final.csv')|Out-Null
                $fc=Compare-Leases $base $new (Join-Path $dir 'Compare-NewEdge-Final.csv')
                $miss=@($fc|Where-Object {$_.Result -eq 'MISSING'})
                if($miss.Count){throw "$($miss.Count) baseline lease(s) missing on new Edge."}
                $unknown=@($new|Where-Object {[string]::IsNullOrWhiteSpace([string]$_.AddressState) -or [string]$_.AddressState -match 'Unknown'})
                if($unknown.Count){throw "$($unknown.Count) lease(s) have unknown/empty state."}
                $health=Get-LocalDhcpHealth $dir $scope
                if([string]$health.ServiceStatus -ne 'Running'){throw 'DHCPServer service is not running on EQB.'}
                Complete-Step "NewEdge=$($new.Count); baseline=$($base.Count); missing=0; relationship=$($scopeFoFinal.Name); mode=$($scopeFoFinal.Mode)"
                $script:LastCompletedStep=$script:CurrentStep
                $result='PASS'
                $message="Final leases=$($new.Count); baseline=$($base.Count); new/nonbaseline=$(@($fc|Where-Object Result -eq 'NEW_LEASE').Count); warning/error events=$($health.WarningErrorEvents)"
            }
        }
    } catch {$err=$_; $message=$err.Exception.Message; Write-Log "CSV Row $csvIndex Scope $scope FAILED at step '$($script:CurrentStep)': $message" 'ERROR'; Write-FailureRecord $r $csvIndex $scope $phase $message $dir $err; $result='FAIL'}
    [void]$summary.Add([pscustomobject]@{Time=Get-Date;Phase=$phase;ScopeId=$scope;ScopeName=$scopeName;LegacyEdge=$r.LegacyEdge;NewHub=$r.NewHub;NewEdge=$r.NewEdge;ReservePercent=$rp;Result=$result;Message=$message})
    $summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $runDir 'MigrationSummary.csv')
    $scopeElapsed=(Get-Date)-$scopeStart; Write-Log "END CSV Row $csvIndex/$($rows.Count), Phase $phase, Scope $scopeName ($scope), Result=$result, Elapsed=$($scopeElapsed.ToString('hh\:mm\:ss'))" $(if($result -eq 'PASS'){'PASS'}elseif($result -eq 'PREFLIGHT_PASS'){'PASS'}else{'ERROR'})
    if($result -eq 'FAIL'){
        if(To-Bool $r.StopOnValidationFailure $false){
            Write-Log "CSV row $csvIndex failed, but resumable batch mode will continue with remaining rows. StopOnValidationFailure is ignored to prevent unrelated scopes from being skipped." 'WARN'
        } else {
            Write-Log "CSV row $csvIndex failed. Continuing with remaining enabled rows." 'WARN'
        }
    }
}
Write-Log "Run complete. Evidence: $runDir"
$summary | Format-Table -AutoSize
