#requires -Version 5.1
# Revision 2.6: Phase I bridges LegacyEdge directly to NewEdge; Phase II retains NewEdge and creates final NewEdge-active/NewHub-standby failover.
# Revision 2.6: Accepts detached Phase I restart state and approved stale source relationships to LegacyHub or NewHub, while retaining LegacyEdge.
# Revision 2.3: Phase II creates the NewHub as Standby and the NewEdge as Active, with role validation.
# Revision 2.2: Continue-on-row-error is enabled by default and honors ContinueOnError/ContinueOnErrors CSV columns.
# Revision 2.1: Flexible source states, shared relationships, retry/replication, and configurable row delays.
# Revision 1.7: Support explicitly approved zero-lease scopes with end-to-end validation.
# Revision 1.6: Robust lease capture, per-scope recovery exports, and validated replication.
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)][ValidateScript({Test-Path $_ -PathType Leaf})][string]$ConfigFile,
    [switch]$PreflightOnly,
    [ValidateRange(0,600)][int]$RowDelaySeconds = 15,
    [ValidateRange(1,20)][int]$RelationshipUpdateAttempts = 6,
    [ValidateRange(1,300)][int]$RelationshipRetryDelaySeconds = 15,
    [switch]$StopBatchOnRowError
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
        TempRelationship=$Row.TempRelationship; TempRelationshipAction=(Get-TempRelationshipAction $Row); FinalRelationship=$Row.FinalRelationship; RelationshipAction=(Get-RelationshipAction $Row)
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
    $required=@('Get-DhcpServerv4Scope','Get-DhcpServerv4ScopeStatistics','Get-DhcpServerv4Lease','Get-DhcpServerv4Reservation','Get-DhcpServerv4Failover','Add-DhcpServerv4Failover','Add-DhcpServerv4FailoverScope','Remove-DhcpServerv4FailoverScope','Backup-DhcpServer','Invoke-DhcpServerv4FailoverReplication','Get-DhcpServerDatabase','Export-DhcpServer')
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
    Set-StrictMode -Off
    $leases=@(Get-DhcpServerv4Lease -ComputerName $Server -ScopeId $ScopeId -AllLeases -ErrorAction Stop)
    Write-Output $leases
}
function Export-Leases { param([string]$Server,[string]$ScopeId,[string]$Path)
    $raw=@(Get-DhcpLeasesSafe -Server $Server -ScopeId $ScopeId)
    $x=@($raw | ForEach-Object {
        $lease=$_
        [pscustomobject]@{
            Server=$Server; ScopeId=$ScopeId
            IPAddress=if($lease.PSObject.Properties['IPAddress']){[string]$lease.PSObject.Properties['IPAddress'].Value}else{''}
            ClientId=if($lease.PSObject.Properties['ClientId']){[string]$lease.PSObject.Properties['ClientId'].Value}else{''}
            HostName=if($lease.PSObject.Properties['HostName']){[string]$lease.PSObject.Properties['HostName'].Value}else{''}
            AddressState=if($lease.PSObject.Properties['AddressState']){[string]$lease.PSObject.Properties['AddressState'].Value}elseif($lease.PSObject.Properties['State']){[string]$lease.PSObject.Properties['State'].Value}else{''}
            LeaseExpiryTime=if($lease.PSObject.Properties['LeaseExpiryTime']){$lease.PSObject.Properties['LeaseExpiryTime'].Value}else{$null}
            Description=if($lease.PSObject.Properties['Description']){[string]$lease.PSObject.Properties['Description'].Value}else{''}
        }
    })
    $invalid=@($x | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.IPAddress) -or [string]::IsNullOrWhiteSpace([string]$_.ClientId)})
    if($invalid.Count){throw "Lease query for $ScopeId on $Server returned $($invalid.Count) invalid object(s)."}
    $x | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path
    Write-Output -NoEnumerate $x
}
function Export-Reservations { param([string]$Server,[string]$ScopeId,[string]$Path)
    $x=@(Get-DhcpServerv4Reservation -ComputerName $Server -ScopeId $ScopeId -ErrorAction Stop | Select-Object @{n='Server';e={$Server}},ScopeId,IPAddress,ClientId,Name,Description,Type)
    $x | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $Path; Write-Output -NoEnumerate $x
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
    return @($rows)
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
function Assert-FailoverServerRole { param([string]$Server,[string]$Name,[string]$ExpectedRole)
    $fo=Get-DhcpServerv4Failover -ComputerName $Server -Name $Name -ErrorAction Stop
    $reportedRole=''
    foreach($propertyName in @('ServerRole','Role')){
        if($fo.PSObject.Properties[$propertyName]){$reportedRole=[string]$fo.$propertyName; break}
    }
    if([string]::IsNullOrWhiteSpace($reportedRole)){
        Write-Log "DHCP module did not expose ServerRole or Role for relationship '$Name' on $Server. Partner and HotStandby validation will continue." 'WARN'
        return $fo
    }
    if($reportedRole -ine $ExpectedRole){
        throw "Failover role validation failed for relationship '$Name' on $Server. Expected=$ExpectedRole; Reported=$reportedRole."
    }
    Write-Log "Relationship '$Name' role validation passed on $Server. Role=$reportedRole." 'PASS'
    return $fo
}
function Backup-LocalDhcp { param([string]$Root,[string]$ScopeTag)
    $p=Join-Path $Root ('DHCP_'+$env:COMPUTERNAME+'_'+$ScopeTag+'_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force -Path $p | Out-Null
    Backup-DhcpServer -Path $p -ErrorAction Stop; if(-not (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue)){throw "Backup did not create files in $p"}; return $p
}
function Export-ScopeRecoveryPackage { param([string]$Root,[string]$Server,[string]$ScopeId,[string]$ScopeName,[bool]$AllowZeroLeases=$false)
    $stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
    $package=Join-Path $Root ('ScopeExport_'+(Safe-Name $ScopeId)+'_'+(Safe-Name $ScopeName)+'_'+$stamp)
    New-Item -ItemType Directory -Force -Path $package | Out-Null
    $xml=Join-Path $package ('DHCP-Scope-'+(Safe-Name $ScopeId)+'-WithLeases.xml')
    $leaseCsv=Join-Path $package ('DHCP-Scope-'+(Safe-Name $ScopeId)+'-Leases.csv')
    $reservationCsv=Join-Path $package ('DHCP-Scope-'+(Safe-Name $ScopeId)+'-Reservations.csv')
    Export-DhcpServer -ComputerName $Server -File $xml -ScopeId $ScopeId -Leases -Force -ErrorAction Stop
    if(-not (Test-Path $xml -PathType Leaf) -or (Get-Item $xml).Length -le 0){throw "Per-scope XML export was not created for $ScopeId."}
    # Do not wrap these calls in @(). They return a non-enumerated array.
    $leases=Export-Leases -Server $Server -ScopeId $ScopeId -Path $leaseCsv
    $reservations=Export-Reservations -Server $Server -ScopeId $ScopeId -Path $reservationCsv
    $leaseCount=@($leases).Count; $reservationCount=@($reservations).Count
    $reimported=@(Import-Csv $leaseCsv); $reimportedReservations=@(Import-Csv $reservationCsv)
    if($leaseCount -le 0 -and -not $AllowZeroLeases){throw "Per-scope recovery package for $ScopeId contains no valid leases. Set AllowZeroLeases=TRUE in the approved CSV row only when an empty scope is expected."}
    if($leaseCount -eq 0 -and $AllowZeroLeases){Write-Log "Scope $ScopeId is explicitly approved with zero leases. Recovery XML and scope configuration will be retained; lease CSV is expected to be empty." 'WARN'}
    if($reimported.Count -ne $leaseCount){throw "Per-scope lease CSV validation failed for $ScopeId. Exported=$leaseCount; reimported=$($reimported.Count)."}
    if($reimportedReservations.Count -ne $reservationCount){throw "Per-scope reservation CSV validation failed for $ScopeId. Exported=$reservationCount; reimported=$($reimportedReservations.Count)."}
    $bad=@($reimported | Where-Object {[string]::IsNullOrWhiteSpace([string]$_.IPAddress) -or [string]::IsNullOrWhiteSpace([string]$_.ClientId)})
    if($bad.Count){throw "Per-scope recovery package for $ScopeId contains $($bad.Count) invalid lease row(s)."}
    $manifest=[pscustomobject]@{Created=Get-Date;SourceServer=$Server;ScopeId=$ScopeId;ScopeName=$ScopeName;LeaseCount=$leaseCount;ReservationCount=$reservationCount;XmlFile=(Split-Path $xml -Leaf);LeaseCsv=(Split-Path $leaseCsv -Leaf);ReservationCsv=(Split-Path $reservationCsv -Leaf);XmlSHA256=(Get-FileHash $xml -Algorithm SHA256).Hash;LeaseCsvSHA256=(Get-FileHash $leaseCsv -Algorithm SHA256).Hash;ReservationCsvSHA256=(Get-FileHash $reservationCsv -Algorithm SHA256).Hash}
    $manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $package 'Manifest.csv')
    $manifest | Format-List * | Out-File -Width 300 -FilePath (Join-Path $package 'Manifest.txt')
    [pscustomobject]@{Path=$package;LeaseCount=$leaseCount;ReservationCount=$reservationCount}
}
function Get-BaselinePath([string]$Root,[string]$ScopeId){Join-Path $Root ('Baseline_'+(Safe-Name $ScopeId)+'.csv')}
function Assert-LocalServer([string]$Expected,[string]$Phase){if($env:COMPUTERNAME -ine (($Expected -split '\.')[0])){throw "$Phase must run locally on $Expected. Current server: $env:COMPUTERNAME"}}
function Validate-Row($r){
    $requiredColumns = @('Enabled','Phase','ScopeId','ScopeName','LegacyHub','LegacyEdge','NewHub','NewEdge','ReservePercent','MCLT','TempRelationship','FinalRelationship','BackupRoot','OutputRoot')
    foreach($n in $requiredColumns){
        if(-not $r.PSObject.Properties[$n]){throw "CSV missing required column '$n'."}
    }
    if($r.PSObject.Properties['AllowZeroLeases'] -and -not [string]::IsNullOrWhiteSpace([string]$r.AllowZeroLeases)){
        $zeroText=([string]$r.AllowZeroLeases).Trim().ToLowerInvariant()
        if($zeroText -notin @('1','0','true','false','yes','no','y','n')){throw "AllowZeroLeases '$($r.AllowZeroLeases)' is invalid. Use TRUE or FALSE."}
    }
    Assert-RelationshipAction (Get-TempRelationshipAction $r) 'TempRelationshipAction' $r.ScopeId
    Assert-RelationshipAction (Get-RelationshipAction $r) 'RelationshipAction' $r.ScopeId
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

function Get-ContinueOnRowError { param($Row)
    foreach($column in @('ContinueOnError','ContinueOnErrors','ContinueOnRowError')){
        if($Row.PSObject.Properties[$column] -and -not [string]::IsNullOrWhiteSpace([string]$Row.$column)){
            return To-Bool $Row.$column $true
        }
    }
    # Backward compatibility: StopOnValidationFailure=TRUE means stop. If absent, continue.
    if($Row.PSObject.Properties['StopOnValidationFailure'] -and -not [string]::IsNullOrWhiteSpace([string]$Row.StopOnValidationFailure)){
        return -not (To-Bool $Row.StopOnValidationFailure $false)
    }
    return $true
}
function Get-RelationshipActionValue { param($Row,[string]$ColumnName)
    if(-not $Row.PSObject.Properties[$ColumnName] -or [string]::IsNullOrWhiteSpace([string]$Row.$ColumnName)){return 'Auto'}
    return ([string]$Row.$ColumnName).Trim()
}
function Get-TempRelationshipAction($Row){return Get-RelationshipActionValue $Row 'TempRelationshipAction'}
function Get-RelationshipAction($Row){return Get-RelationshipActionValue $Row 'RelationshipAction'}
function Assert-RelationshipAction { param([string]$Value,[string]$Column,[string]$ScopeId)
    if($Value -notin @('Auto','Reuse','Create')){throw "$Column '$Value' is invalid for scope $ScopeId. Use Auto, Reuse, or Create."}
}
function Test-SharedRelationshipPlans { param([array]$Rows)
    foreach($plan in @(
        [pscustomobject]@{Phase=1;NameColumn='TempRelationship';ActionColumn='TempRelationshipAction';Left='LegacyEdge';Right='NewEdge'},
        [pscustomobject]@{Phase=2;NameColumn='FinalRelationship';ActionColumn='RelationshipAction';Left='NewEdge';Right='NewHub'}
    )){
        $planRows=@($Rows | Where-Object {[int]$_.Phase -eq $plan.Phase})
        foreach($group in @($planRows | Group-Object {([string]$_.$($plan.NameColumn)).Trim().ToLowerInvariant()})){
            $pairs=@($group.Group | ForEach-Object {'{0}|{1}' -f (([string]$_.$($plan.Left)).Trim().ToLowerInvariant()),(([string]$_.$($plan.Right)).Trim().ToLowerInvariant())} | Select-Object -Unique)
            if($pairs.Count -ne 1){throw "Shared $($plan.NameColumn) '$($group.Group[0].$($plan.NameColumn))' is assigned to multiple server pairs: $($pairs -join ', ')."}
            $actions=@($group.Group | ForEach-Object {Get-RelationshipActionValue $_ $plan.ActionColumn} | Select-Object -Unique)
            foreach($action in $actions){Assert-RelationshipAction $action $plan.ActionColumn $group.Group[0].ScopeId}
            if($actions.Count -gt 1){throw "Shared $($plan.NameColumn) '$($group.Group[0].$($plan.NameColumn))' has conflicting actions: $($actions -join ', ')."}
        }
    }
    Write-Log 'Shared temporary and final relationship plans passed validation.' 'PASS'
}
function Add-DhcpFailoverScopeWithRetry { param(
    [string]$Server,[string]$RelationshipName,[string]$ScopeId,
    [int]$MaximumAttempts=6,[int]$RetryDelaySeconds=15
)
    for($attempt=1;$attempt -le $MaximumAttempts;$attempt++){
        $assigned=Get-DhcpServerv4Failover -ComputerName $Server -ScopeId $ScopeId -ErrorAction SilentlyContinue
        if($assigned){
            if([string]$assigned.Name -ieq $RelationshipName){return $assigned}
            throw "Scope $ScopeId is assigned to unexpected relationship '$($assigned.Name)'."
        }
        try{
            Write-Log "Adding scope $ScopeId to relationship '$RelationshipName' (attempt $attempt of $MaximumAttempts)." $(if($attempt -eq 1){'INFO'}else{'WARN'})
            Add-DhcpServerv4FailoverScope -ComputerName $Server -Name $RelationshipName -ScopeId $ScopeId -ErrorAction Stop | Out-Null
            $verified=Get-DhcpServerv4Failover -ComputerName $Server -ScopeId $ScopeId -ErrorAction Stop
            if([string]$verified.Name -ine $RelationshipName){throw "Verification returned relationship '$($verified.Name)'."}
            try{Invoke-DhcpServerv4FailoverReplication -ComputerName $Server -Name $RelationshipName -Force -ErrorAction Stop}catch{Write-Log "Post-add replication warning: $($_.Exception.Message)" 'WARN'}
            return $verified
        }catch{
            $lastError=$_.Exception.Message
            if($attempt -ge $MaximumAttempts){throw "Failed to add scope $ScopeId to '$RelationshipName' after $MaximumAttempts attempts. Last error: $lastError"}
            Write-Log "Attempt $attempt failed for scope $ScopeId on '$RelationshipName': $lastError" 'WARN'
            try{Invoke-DhcpServerv4FailoverReplication -ComputerName $Server -Name $RelationshipName -Force -ErrorAction Stop}catch{Write-Log "Replication before retry warning: $($_.Exception.Message)" 'WARN'}
            Write-Log "Waiting $RetryDelaySeconds seconds before retrying relationship update." 'WARN'
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}
function Get-Phase2BaselinePath([string]$Root,[string]$ScopeId){
    Join-Path $Root ('Phase2Baseline_'+(Safe-Name $ScopeId)+'.csv')
}
function Test-Phase2RelationshipPlan { param([array]$Rows)
    $phase2Rows=@($Rows | Where-Object {[int]$_.Phase -eq 2})
    if(-not $phase2Rows.Count){return}

    foreach($row in $phase2Rows){
        if(([string]$row.FinalRelationship).Trim() -ieq ([string]$row.TempRelationship).Trim()){
            throw "Phase II CSV validation failed before any DHCP changes. Scope $($row.ScopeId) uses the same name for TempRelationship and FinalRelationship: $($row.FinalRelationship)."
        }
    }

    Write-Log "Phase II relationship-name validation passed; shared final names are allowed for one server pair." 'PASS'

    foreach($row in $phase2Rows){
        $scopeId=([string]$row.ScopeId).Trim()
        $finalName=([string]$row.FinalRelationship).Trim()
        $newHub=([string]$row.NewHub).Trim()
        foreach($server in @($env:COMPUTERNAME,$newHub) | Select-Object -Unique){
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
Write-Log "Loaded $($rows.Count) enabled scope(s) from $ConfigFile. PreflightOnly=$PreflightOnly WhatIf=$WhatIfPreference StopBatchOnRowError=$StopBatchOnRowError"
Write-Log 'Default batch behavior is continue-on-row-error. Each failed row is recorded and remaining enabled rows are attempted.' 'INFO'
Test-SharedRelationshipPlans $rows
if(@($rows | Where-Object {[int]$_.Phase -eq 2}).Count){
    Assert-LocalServer $rows[0].NewEdge 'Phase II batch validation'
    Test-Phase2RelationshipPlan $rows
}
$csvIndex=0
foreach($r in $rows){
    $csvIndex++; $script:CurrentStep='Initialization'; $script:LastCompletedStep='None'
    $scope=([string]$r.ScopeId).Trim(); $scopeName=([string]$r.ScopeName).Trim(); $phase=[int]$r.Phase; $continueOnRowError=Get-ContinueOnRowError $r; $tempRelationshipAction=Get-TempRelationshipAction $r; $relationshipAction=Get-RelationshipAction $r; $allowZeroLeases=if($r.PSObject.Properties['AllowZeroLeases']){To-Bool $r.AllowZeroLeases $false}else{$false}; $rp=if([string]::IsNullOrWhiteSpace([string]$r.ReservePercent)){10}else{[int]$r.ReservePercent}; $mclt=if([string]::IsNullOrWhiteSpace([string]$r.MCLT)){'00:05:00'}else{([string]$r.MCLT).Trim()}
    $dir=Join-Path $runDir (('Phase{0}_{1}_{2}' -f $phase,(Safe-Name $scopeName),(Safe-Name $scope))); New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $result='FAIL'; $message=''; $scopeStart=Get-Date; Write-Host ''; Write-Host ('='*72) -ForegroundColor Cyan; Write-Host " DHCP MIGRATION | CSV Row $csvIndex of $($rows.Count) | Phase $phase | Scope $scopeName ($scope)" -ForegroundColor Cyan; Write-Host ('='*72) -ForegroundColor Cyan; Write-Log "BEGIN CSV Row $csvIndex/$($rows.Count), Phase $phase, Scope $scopeName ($scope), AllowZeroLeases=$allowZeroLeases, ContinueOnRowError=$continueOnRowError" 'STEP'
    try {
        if($phase -eq 1){
            Start-Step 1 13 'Validate local execution server'; Assert-LocalServer $r.LegacyEdge 'Phase I'; Complete-Step "Server=$env:COMPUTERNAME"; $script:LastCompletedStep=$script:CurrentStep
            Start-Step 2 13 'Validate DHCP service'; Get-Service DHCPServer -ErrorAction Stop | Out-Null; Complete-Step 'DHCPServer service located'; $script:LastCompletedStep=$script:CurrentStep
            Start-Step 3 13 'Validate scope ID and name'; $s=Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction Stop
            if(([string]$s.Name).Trim() -ine $scopeName){throw "ScopeId $scope exists, but its DHCP name '$($s.Name)' does not match CSV ScopeName '$scopeName'."}
            Complete-Step "ScopeName=$scopeName; ScopeId=$scope"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 4 13 'Detect Phase I resume state'
            $fo = Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
            $phase1State = 'Detached'
            if($fo){
                $partnerShort = (([string]$fo.PartnerServer -split '\.')[0])
                $legacyHubShort = (([string]$r.LegacyHub -split '\.')[0])
                $oldNewHubShort = (([string]$r.NewHub -split '\.')[0])
                $newEdgeShort = (([string]$r.NewEdge -split '\.')[0])
                if(($partnerShort -in @($legacyHubShort,$oldNewHubShort)) -and ([string]$fo.Mode -in @('LoadBalance','HotStandby'))){
                    $phase1State='SourceFailoverToDetach'
                    Write-Log "Accepted removable source relationship. Name=$($fo.Name); Mode=$($fo.Mode); Partner=$($fo.PartnerServer). LegacyEdge will be retained." 'WARN'
                } elseif(([string]$fo.Mode -eq 'HotStandby') -and ($partnerShort -ieq $newEdgeShort) -and ([string]$fo.Name -ieq [string]$r.TempRelationship)){
                    $phase1State='TemporaryNewEdgeFailoverEstablished'
                    Write-Log "Expected LegacyEdge-to-NewEdge temporary relationship already exists." 'PASS'
                } else {throw "Scope $scope is in an unapproved relationship. Name=$($fo.Name); Mode=$($fo.Mode); Partner=$($fo.PartnerServer). Approved removable partners are LegacyHub=$($r.LegacyHub) or prior NewHub=$($r.NewHub); expected temporary partner is NewEdge=$($r.NewEdge)."}
            }
            if($phase1State -eq 'Detached'){Write-Log "Scope $scope has no relationship; continuing from LegacyEdge." 'WARN'}
            Complete-Step "ResumeState=$phase1State"; $script:LastCompletedStep=$script:CurrentStep

            $baseline=Get-BaselinePath $r.OutputRoot $scope
            Start-Step 5 13 'Capture legacy Edge lease baseline'
            $edge=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-Leases-Before.csv')
            Complete-Step "Edge leases=$($edge.Count)"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 6 13 'Load or capture consolidated lease baseline'
            if($phase1State -eq 'SourceFailoverToDetach'){
                $sourcePartner=[string]$fo.PartnerServer
                $hub=Export-Leases $sourcePartner $scope (Join-Path $dir 'SourcePartner-Leases-Before.csv')
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
            if(-not $combined.Count -and -not $allowZeroLeases){throw "No lease baseline is available for scope $scope. Set AllowZeroLeases=TRUE only if the approved scope is expected to contain zero leases."}
            if(-not $combined.Count -and $allowZeroLeases){Write-Log "Scope $scope is explicitly approved with zero leases. Phase I will validate that the scope remains empty through migration." 'WARN'}
            $script:LastCompletedStep=$script:CurrentStep

            Start-Step 7 13 'Capture reservations and preserve baseline'
            Export-Reservations $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-Reservations-Before.csv') | Out-Null
            if($phase1State -eq 'SourceFailoverToDetach'){
                Export-Reservations ([string]$fo.PartnerServer) $scope (Join-Path $dir 'SourcePartner-Reservations-Before.csv') | Out-Null
            } else {
                Write-Log "Legacy Hub reservation export skipped for scope $scope because the original relationship is already detached." 'WARN'
            }
            $combined | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $baseline
            Complete-Step "Baseline=$baseline"; $script:LastCompletedStep=$script:CurrentStep

            if($PreflightOnly){
                Write-Log "PRECHECK PASS Phase I $scope; ResumeState=$phase1State"; $result='PREFLIGHT_PASS'
            } else {
                Start-Step 8 13 'Export individual scope recovery package'
                $scopePackage=Export-ScopeRecoveryPackage -Root $r.BackupRoot -Server $env:COMPUTERNAME -ScopeId $scope -ScopeName $scopeName -AllowZeroLeases $allowZeroLeases
                Complete-Step "Package=$($scopePackage.Path); leases=$($scopePackage.LeaseCount); reservations=$($scopePackage.ReservationCount)"; $script:LastCompletedStep=$script:CurrentStep
                Start-Step 9 13 'Backup local DHCP database'
                $bk=Backup-LocalDhcp $r.BackupRoot (Safe-Name $scope)
                Complete-Step "Backup=$bk"; $script:LastCompletedStep=$script:CurrentStep
                Start-Step 10 13 'Detach existing source failover, retain LegacyEdge'
                if($phase1State -eq 'SourceFailoverToDetach'){
                    if($PSCmdlet.ShouldProcess("Scope $scope","Detach current partner $($fo.PartnerServer), retain LegacyEdge")){
                        Remove-DhcpServerv4FailoverScope -Name $fo.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                    $phase1State='Detached'
                    Complete-Step 'Existing source failover detached; LegacyEdge retained'
                } else {
                    Complete-Step "No detach needed; ResumeState=$phase1State"
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 11 13 'Validate scope and leases retained on LegacyEdge'
                $after=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'LegacyEdge-AfterDetach.csv')
                $cmp=Compare-Leases $combined $after (Join-Path $dir 'Compare-AfterDetach.csv')
                $missingAfterDetach=@($cmp|Where-Object {$_.Result -eq 'MISSING'})
                if($missingAfterDetach.Count){throw "$($missingAfterDetach.Count) baseline lease(s) are missing on legacy Edge before EQB failover creation."}
                Complete-Step "Expected=$($combined.Count); actual=$($after.Count); missing=0"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 12 13 'Create or join temporary NewEdge Hot Standby relationship'
                $scopeFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                if($scopeFo){
                    $scopePartnerShort=(([string]$scopeFo.PartnerServer -split '\.')[0])
                    $newEdgeShort=(([string]$r.NewEdge -split '\.')[0])
                    if(([string]$scopeFo.Name -ine [string]$r.TempRelationship -or [string]$scopeFo.Mode -ne 'HotStandby' -or $scopePartnerShort -ine $newEdgeShort)){
                        throw "Scope $scope acquired an unexpected failover relationship before NewEdge configuration."
                    }
                    Complete-Step "Already joined relationship=$($scopeFo.Name)"
                } else {
                    $tempFo=Get-DhcpServerv4Failover -Name $r.TempRelationship -ErrorAction SilentlyContinue
                    if($tempRelationshipAction -eq 'Reuse' -and -not $tempFo){throw "TempRelationshipAction=Reuse requires existing relationship '$($r.TempRelationship)'."}
                    if($tempRelationshipAction -eq 'Create' -and $tempFo){throw "TempRelationshipAction=Create requires a new name, but '$($r.TempRelationship)' exists."}
                    if($tempFo){
                        $tempPartnerShort=(([string]$tempFo.PartnerServer -split '\.')[0])
                        $newEdgeShort=(([string]$r.NewEdge -split '\.')[0])
                        if([string]$tempFo.Mode -ne 'HotStandby' -or $tempPartnerShort -ine $newEdgeShort){
                            throw "Existing relationship $($r.TempRelationship) does not match required HotStandby partner $($r.NewEdge)."
                        }
                        if($PSCmdlet.ShouldProcess("Scope $scope","Add scope to existing relationship $($r.TempRelationship)")){
                            Add-DhcpFailoverScopeWithRetry -Server $env:COMPUTERNAME -RelationshipName $r.TempRelationship -ScopeId $scope -MaximumAttempts $RelationshipUpdateAttempts -RetryDelaySeconds $RelationshipRetryDelaySeconds | Out-Null
                        }
                        Complete-Step "Added scope to existing relationship=$($r.TempRelationship)"
                    } else {
                        if($PSCmdlet.ShouldProcess("Scope $scope","Create temporary Hot Standby to $($r.NewEdge)")){
                            Add-DhcpServerv4Failover -Name $r.TempRelationship -PartnerServer $r.NewEdge -ScopeId $scope -ServerRole Active -ReservePercent $rp -MaxClientLeadTime ([timespan]$mclt) -Force -ErrorAction Stop | Out-Null
                        }
                        Complete-Step "Created relationship=$($r.TempRelationship); Reserve=$rp%; Active=LegacyEdge; Standby=$($r.NewEdge)"
                    }
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 13 13 'Validate NewEdge relationship and lease replication'
                $newfo=Wait-FailoverNormal $env:COMPUTERNAME $r.TempRelationship
                $newfo|Format-List *|Out-File (Join-Path $dir 'TemporaryFailover.txt') -Width 300
                $scopeFoFinal=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction Stop
                if([string]$scopeFoFinal.Name -ine [string]$r.TempRelationship -or [string]$scopeFoFinal.Mode -ne 'HotStandby'){
                    throw "Final Phase I relationship validation failed for scope $scope."
                }
                $eqb=Export-Leases $r.NewEdge $scope (Join-Path $dir 'NewEdge-Leases-AfterSync.csv')
                $cmp2=Compare-Leases $combined $eqb (Join-Path $dir 'Compare-EQB.csv')
                $missingOnEqb=@($cmp2|Where-Object {$_.Result -eq 'MISSING'})
                if($missingOnEqb.Count){throw "$($missingOnEqb.Count) baseline lease(s) are missing on NewEdge."}
                Complete-Step "EQB=$($eqb.Count); baseline=$($combined.Count); missing=0; relationship=$($scopeFoFinal.Name); mode=$($scopeFoFinal.Mode)"
                $script:LastCompletedStep=$script:CurrentStep; $result='PASS'
            }
        } else {
            Assert-LocalServer $r.NewEdge 'Phase II'
            Start-Step 1 10 'Validate local NewEdge scope'
            $phase2Scope=Get-DhcpServerv4Scope -ScopeId $scope -ErrorAction Stop
            if(([string]$phase2Scope.Name).Trim() -ine $scopeName){throw "ScopeId $scope exists, but its DHCP name '$($phase2Scope.Name)' does not match CSV ScopeName '$scopeName'."}
            Complete-Step "ScopeName=$scopeName; ScopeId=$scope; Server=$env:COMPUTERNAME"; $script:LastCompletedStep=$script:CurrentStep

            Start-Step 2 10 'Detect Phase II resume state'
            $scopeFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
            $phase2State='DetachedFromLegacyEdge'
            if($scopeFo){
                $partnerShort=(([string]$scopeFo.PartnerServer -split '\.')[0])
                $legacyEdgeShort=(([string]$r.LegacyEdge -split '\.')[0])
                $newHubShort=(([string]$r.NewHub -split '\.')[0])
                if(([string]$scopeFo.Name -ieq [string]$r.TempRelationship -and [string]$scopeFo.Mode -eq 'HotStandby' -and $partnerShort -ieq $legacyEdgeShort)){
                    $phase2State='TemporaryLegacyEdgeFailover'
                } elseif(([string]$scopeFo.Name -ieq [string]$r.FinalRelationship -and [string]$scopeFo.Mode -eq 'HotStandby' -and $partnerShort -ieq $newHubShort)){
                    $phase2State='FinalNewHubFailoverEstablished'
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
                if(-not $currentEqb.Count -and -not $allowZeroLeases){throw "Cannot create Phase II baseline because scope $scope has no leases on $env:COMPUTERNAME. Set AllowZeroLeases=TRUE only if zero leases are expected."}
                if(-not $currentEqb.Count -and $allowZeroLeases){Write-Log "Scope $scope is explicitly approved with zero leases. Creating an empty Phase II baseline." 'WARN'}
                $base=@($currentEqb)
                $base | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $phase2Baseline
                Write-Log "Phase I baseline was not present on the new server. Created local Phase II baseline from $($base.Count) leases on $env:COMPUTERNAME." 'WARN'
                Complete-Step "Created local Phase II baseline=$($base.Count); Path=$phase2Baseline"
            }
            if(-not $base.Count -and -not $allowZeroLeases){throw "Phase II baseline is empty for scope $scope."}
            if(-not $base.Count -and $allowZeroLeases){Write-Log "Scope $scope has an approved empty Phase II baseline. Final validation will require both partners to remain at zero leases." 'WARN'}
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
                Assert-FailoverServerRole -Server $env:COMPUTERNAME -Name $scopeFo.Name -ExpectedRole 'Active' | Out-Null
                Assert-FailoverServerRole -Server $r.NewHub -Name $scopeFo.Name -ExpectedRole 'Standby' | Out-Null
                Complete-Step "Final relationship already established=$($scopeFo.Name); state=Normal; NewEdge=Active; NewHub=Standby"
            } else {
                Complete-Step 'Temporary relationship already detached; final relationship still required'
            }
            $script:LastCompletedStep=$script:CurrentStep

            if($PreflightOnly){
                Write-Log "PRECHECK PASS Phase II $scope; ResumeState=$phase2State"; $result='PREFLIGHT_PASS'
            } else {
                Start-Step 6 10 'Backup local NewEdge DHCP database'
                $bk=Backup-LocalDhcp $r.BackupRoot (Safe-Name $scope)
                Complete-Step "Backup=$bk"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 7 10 'Detach temporary LegacyEdge relationship and retain NewEdge'
                if($phase2State -eq 'TemporaryLegacyEdgeFailover'){
                    if($PSCmdlet.ShouldProcess("Scope $scope","Detach LegacyEdge $($r.LegacyEdge), retain NewEdge")){
                        Remove-DhcpServerv4FailoverScope -Name $scopeFo.Name -ScopeId $scope -Force -ErrorAction Stop
                    }
                    $phase2State='DetachedFromLegacyEdge'
                    Complete-Step 'Temporary Legacy Edge relationship detached'
                } else {
                    Complete-Step "No detach needed; ResumeState=$phase2State"
                }
                $script:LastCompletedStep=$script:CurrentStep

                Start-Step 8 10 'Validate leases retained on NewEdge'
                $retained=Export-Leases $env:COMPUTERNAME $scope (Join-Path $dir 'NewEdge-Leases-AfterDetach.csv')
                $rc=Compare-Leases $base $retained (Join-Path $dir 'Compare-EQB-AfterDetach.csv')
                $missingRetained=@($rc|Where-Object {$_.Result -eq 'MISSING'})
                if($missingRetained.Count){throw "$($missingRetained.Count) baseline lease(s) are missing on NewEdge after temporary detach."}
                Complete-Step "Baseline=$($base.Count); retained=$($retained.Count); missing=0"; $script:LastCompletedStep=$script:CurrentStep

                Start-Step 9 10 'Create or validate final NewHub Hot Standby relationship'
                $currentFo=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                if($currentFo){
                    $currentPartnerShort=(([string]$currentFo.PartnerServer -split '\.')[0])
                    $newHubShort=(([string]$r.NewHub -split '\.')[0])
                    if([string]$currentFo.Name -ine [string]$r.FinalRelationship -or [string]$currentFo.Mode -ne 'HotStandby' -or $currentPartnerShort -ine $newHubShort){
                        throw "Scope $scope acquired an unexpected relationship before final configuration. Name=$($currentFo.Name); Mode=$($currentFo.Mode); Partner=$($currentFo.PartnerServer)."
                    }
                    Complete-Step "Final relationship already exists=$($currentFo.Name)"
                } else {
                    $nameCollision=Get-DhcpServerv4Failover -Name $r.FinalRelationship -ErrorAction SilentlyContinue
                    if($relationshipAction -eq 'Reuse' -and -not $nameCollision){throw "RelationshipAction=Reuse requires existing relationship '$($r.FinalRelationship)'."}
                    if($relationshipAction -eq 'Create' -and $nameCollision){throw "RelationshipAction=Create requires a new name, but '$($r.FinalRelationship)' exists."}
                    if($nameCollision){
                        $scopeAssignment=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction SilentlyContinue
                        if($scopeAssignment -and [string]$scopeAssignment.Name -ieq [string]$r.FinalRelationship){
                            $currentFo=$scopeAssignment
                            Complete-Step "Final relationship already exists for intended scope=$($scopeAssignment.Name)"
                        } else {
                            $collisionPartnerShort=(([string]$nameCollision.PartnerServer -split '\.')[0])
                            $newHubShort=(([string]$r.NewHub -split '\.')[0])
                            if([string]$nameCollision.Mode -ne 'HotStandby' -or $collisionPartnerShort -ine $newHubShort){
                                throw "FinalRelationship '$($r.FinalRelationship)' exists with unexpected Mode or Partner. Mode=$($nameCollision.Mode); Partner=$($nameCollision.PartnerServer)."
                            }
                            # The final relationship exists but currently has no locally assigned scope.
                            # This is a recoverable partial state left by an earlier interrupted run.
                            if($PSCmdlet.ShouldProcess("Scope $scope","Add scope to existing final relationship $($r.FinalRelationship)")){
                                Add-DhcpFailoverScopeWithRetry -Server $env:COMPUTERNAME -RelationshipName $r.FinalRelationship -ScopeId $scope -MaximumAttempts $RelationshipUpdateAttempts -RetryDelaySeconds $RelationshipRetryDelaySeconds | Out-Null
                            }
                            $scopeAssignment=Get-DhcpServerv4Failover -ScopeId $scope -ErrorAction Stop
                            if([string]$scopeAssignment.Name -ine [string]$r.FinalRelationship){
                                throw "Scope $scope was not assigned to existing final relationship '$($r.FinalRelationship)' after Add-DhcpServerv4FailoverScope."
                            }
                            $currentFo=$scopeAssignment
                            Complete-Step "Recovered partial relationship by adding scope $scope to $($r.FinalRelationship)"
                        }
                    } else {
                        if($PSCmdlet.ShouldProcess("Scope $scope","Create final Hot Standby with NewHub $($r.NewHub)")){
                            Add-DhcpServerv4Failover -Name $r.FinalRelationship -PartnerServer $r.NewHub -ScopeId $scope -ServerRole Active -ReservePercent $rp -MaxClientLeadTime ([timespan]$mclt) -Force -ErrorAction Stop | Out-Null
                        }
                        Complete-Step "Created final relationship=$($r.FinalRelationship); Active=$env:COMPUTERNAME; Standby=$($r.NewHub)"
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
                Assert-FailoverServerRole -Server $env:COMPUTERNAME -Name $r.FinalRelationship -ExpectedRole 'Active' | Out-Null
                Assert-FailoverServerRole -Server $r.NewHub -Name $r.FinalRelationship -ExpectedRole 'Standby' | Out-Null
                $new=Export-Leases $r.NewHub $scope (Join-Path $dir 'NewHub-Leases-Final.csv')
                Export-Reservations $r.NewHub $scope (Join-Path $dir 'NewHub-Reservations-Final.csv')|Out-Null
                $fc=Compare-Leases $base $new (Join-Path $dir 'Compare-NewHub-Final.csv')
                $miss=@($fc|Where-Object {$_.Result -eq 'MISSING'})
                if($miss.Count){throw "$($miss.Count) baseline lease(s) missing on NewHub."}
                $unknown=@($new|Where-Object {[string]::IsNullOrWhiteSpace([string]$_.AddressState) -or [string]$_.AddressState -match 'Unknown'})
                if($unknown.Count){throw "$($unknown.Count) lease(s) have unknown/empty state."}
                $health=Get-LocalDhcpHealth $dir $scope
                if([string]$health.ServiceStatus -ne 'Running'){throw 'DHCPServer service is not running on EQB.'}
                Complete-Step "NewHub=$($new.Count); baseline=$($base.Count); missing=0; relationship=$($scopeFoFinal.Name); mode=$($scopeFoFinal.Mode); NewEdge=Active; NewHub=Standby"
                $script:LastCompletedStep=$script:CurrentStep
                $result='PASS'
                $message="Final leases=$($new.Count); baseline=$($base.Count); new/nonbaseline=$(@($fc|Where-Object Result -eq 'NEW_LEASE').Count); warning/error events=$($health.WarningErrorEvents)"
            }
        }
    } catch {$err=$_; $message=$err.Exception.Message; Write-Log "CSV Row $csvIndex Scope $scope FAILED at step '$($script:CurrentStep)': $message" 'ERROR'; Write-FailureRecord $r $csvIndex $scope $phase $message $dir $err; $result='FAIL'}
    [void]$summary.Add([pscustomobject]@{Time=Get-Date;Phase=$phase;ScopeId=$scope;ScopeName=$scopeName;LegacyEdge=$r.LegacyEdge;NewHub=$r.NewHub;NewEdge=$r.NewEdge;ReservePercent=$rp;TempRelationshipAction=$tempRelationshipAction;RelationshipAction=$relationshipAction;AllowZeroLeases=$allowZeroLeases;ContinueOnRowError=$continueOnRowError;Result=$result;Message=$message})
    $summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $runDir 'MigrationSummary.csv')
    $scopeElapsed=(Get-Date)-$scopeStart; Write-Log "END CSV Row $csvIndex/$($rows.Count), Phase $phase, Scope $scopeName ($scope), Result=$result, Elapsed=$($scopeElapsed.ToString('hh\:mm\:ss'))" $(if($result -eq 'PASS'){'PASS'}elseif($result -eq 'PREFLIGHT_PASS'){'PASS'}else{'ERROR'})
    if($result -eq 'FAIL'){
        if($StopBatchOnRowError -or -not $continueOnRowError){
            Write-Log "CSV row $csvIndex failed and batch-stop behavior was explicitly requested. Summary and failure evidence were saved; remaining rows will not run." 'STOP'
            break
        }
        Write-Log "CSV row $csvIndex failed. ContinueOnRowError=True, so the batch will attempt every remaining enabled row." 'WARN'
    }
    if($csvIndex -lt $rows.Count -and $RowDelaySeconds -gt 0){
        Write-Log "CSV row $csvIndex finished with Result=$result. Waiting $RowDelaySeconds seconds before starting row $($csvIndex + 1)." 'STEP'
        Start-Sleep -Seconds $RowDelaySeconds
    }
}
Write-Log "Run complete. Evidence: $runDir"
$summary | Format-Table -AutoSize
