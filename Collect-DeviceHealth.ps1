# Windows PowerShell 5.1+; read-only inventory and performance sampling.
param([string]$PurchaseDate = '', [string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
$script:healthErrorLog = Join-Path $env:TEMP 'DeviceHealthCollector-last-error.txt'
try {
    if (Test-Path -LiteralPath $script:healthErrorLog) { Remove-Item -LiteralPath $script:healthErrorLog -Force }
    Write-Host 'Starting Device Health Check...'

function Safe($block) { try { & $block } catch { $null } }
function RoundOrNull($n, $digits=1) { if ($null -eq $n) { return $null }; [math]::Round([double]$n,$digits) }
function RateHigh($n,$good,$warn) { if ($null -eq $n) { return 'unknown' }; if ($n -lt $good) { 'good' } elseif ($n -lt $warn) { 'warning' } else { 'critical' } }
function RateLow($n,$good,$warn) { if ($null -eq $n) { return 'unknown' }; if ($n -ge $good) { 'good' } elseif ($n -ge $warn) { 'warning' } else { 'critical' } }
function GetAge($date) { if (-not $date) { return $null }; try { $d=[datetime]::ParseExact($date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture); if ($d -gt (Get-Date)) {return $null}; return [math]::Round(((Get-Date)-$d).TotalDays/365.2425,1) } catch { return $null } }
$computer=Safe { Get-CimInstance Win32_ComputerSystem }
$bios=Safe { Get-CimInstance Win32_BIOS }
$os=Safe { Get-CimInstance Win32_OperatingSystem }
$cpu=Safe { Get-CimInstance Win32_Processor | Select-Object -First 1 }
$disk=Safe { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" }
if (-not $disk) { $disk=Safe { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object -First 1 } }
$ramTotal=if($computer){[double]$computer.TotalPhysicalMemory}else{$null}
$ramFree=if($os){[double]$os.FreePhysicalMemory*1024}else{$null}
$ramPct=if($ramTotal -and $null -ne $ramFree){RoundOrNull (100*($ramTotal-$ramFree)/$ramTotal)}else{$null}
$cpuPct=Safe { $samples=1..3 | ForEach-Object { (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; Start-Sleep -Seconds 1 }; RoundOrNull (($samples | Measure-Object -Average).Average) }
$diskFreePct=if($disk -and $disk.Size -gt 0){RoundOrNull (100*$disk.FreeSpace/$disk.Size)}else{$null}
$uptime=if($os){RoundOrNull (((Get-Date)-$os.LastBootUpTime).TotalDays)}else{$null}
$battery=Safe { Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData | Select-Object -First 1 }
$full=Safe { Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1 }
$design=if($battery -and $battery.DesignedCapacity -gt 0){[double]$battery.DesignedCapacity}else{$null}
$fullCap=if($full -and $full.FullChargedCapacity -gt 0){[double]$full.FullChargedCapacity}else{$null}
# Generate the official Windows battery report BEFORE rating or JSON export.
# Some OEMs expose capacities in powercfg even when root/wmi battery classes are absent.
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([Environment]::GetFolderPath('Desktop')) 'DeviceHealthReports'}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$reportStem = "health_{0}_{1}" -f ($env:COMPUTERNAME -replace '[^A-Za-z0-9_-]','_'),(Get-Date -Format 'yyyyMMdd_HHmmss')
$batReport = Join-Path $OutputDirectory ($reportStem + '_battery.html')
$batteryResult = Safe { & powercfg.exe /batteryreport /output $batReport 2>&1 | Out-String }
$cycles=Safe { (Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount | Select-Object -First 1).CycleCount }
function ReadBatteryReportCapacity($html, $label) {
    # Extract the matching row without scanning the entire report with nested regex.
    $rows = [regex]::Matches($html, '(?is)<tr\b[^>]*>.*?</tr>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($row in $rows) {
        $plain = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($row.Value, '<[^>]*>', ' '))
        if ($plain -notmatch [regex]::Escape($label)) { continue }
        $m = [regex]::Match($plain, '(?i)([\d,\s\u00a0]+)\s*mWh')
        if ($m.Success) {
            $digits = [regex]::Replace($m.Groups[1].Value, '[^0-9]', '')
            if ($digits -and [double]$digits -gt 0) { return [double]$digits }
        }
    }
    return $null
}
if (Test-Path -LiteralPath $batReport) {
    Write-Host 'Battery report generated; reading battery capacities...'
    $html = Safe { [IO.File]::ReadAllText($batReport) }
    if ($html) {
        $reportDesign = ReadBatteryReportCapacity $html 'DESIGN CAPACITY'
        $reportFull = ReadBatteryReportCapacity $html 'FULL CHARGE CAPACITY'
        if ($null -ne $reportDesign) { $design = $reportDesign }
        if ($null -ne $reportFull) { $fullCap = $reportFull }
        if ($null -eq $cycles) {
            $rows = [regex]::Matches($html, '(?is)<tr\b[^>]*>.*?</tr>')
            foreach ($row in $rows) {
                $plain = [System.Net.WebUtility]::HtmlDecode([regex]::Replace($row.Value, '<[^>]*>', ' '))
                if ($plain -match '(?i)CYCLE COUNT\s*([\d,]+)') {
                    $cycles = [int]($Matches[1] -replace ',', '')
                    break
                }
            }
        }
    }
} else {
    $batReport = 'Unavailable (desktop, unsupported battery, or access restricted)'
}
Write-Host 'Battery extraction finished; preparing RAM and device reports...'
$batteryPct=if($design -gt 0 -and $fullCap -gt 0){RoundOrNull (100*$fullCap/$design)}else{$null}
$cycleLimit=1000 # Configurable assumption; confirm manufacturer-rated limit per model.
$cycleLevel=if($null -eq $cycles){'unknown'}elseif($cycles -lt 300){'low'}elseif($cycles -lt 700){'medium'}elseif($cycles -lt $cycleLimit){'high'}else{'limit_reached'}
$cycleAssessment=if($cycleLevel -eq 'unknown'){'Unknown'}elseif($cycleLevel -eq 'low'){'Acceptable'}elseif($cycleLevel -eq 'medium'){'Acceptable - monitor'}elseif($cycleLevel -eq 'high'){'Aging - monitor closely'}else{'Review replacement eligibility'}
$batteryAdvice=if($null -eq $batteryPct){'Unknown - inspect battery report'}elseif($batteryPct -lt 80){'Replacement evaluation recommended'}elseif($cycleLevel -eq 'limit_reached'){'Review manufacturer cycle limit and runtime'}elseif($batteryPct -lt 85){'Monitor capacity and runtime'}else{'Acceptable if runtime and service condition are normal'}
$biosDate=Safe { if($bios.ReleaseDate){([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd')} }
$purchaseAge=GetAge $PurchaseDate
$ageStatus=if($null -eq $purchaseAge){'unknown'}elseif($purchaseAge -lt 3){'good'}elseif($purchaseAge -lt 5){'warning'}else{'review'}
$ratings=[ordered]@{
 age=$ageStatus
 cpu=RateHigh $cpuPct 20 50
 memory=RateHigh $ramPct 75 90
 storage=RateLow $diskFreePct 20 10
 battery=RateLow $batteryPct 85 80
 uptime=if($null -eq $uptime){'unknown'}elseif($uptime -lt 7){'good'}elseif($uptime -lt 30){'warning'}else{'warning'}
}
$operational=@($ratings.cpu,$ratings.memory,$ratings.storage,$ratings.battery)
$overall=if($operational -contains 'critical'){'critical'}elseif($operational -contains 'warning'){'warning'}elseif(@($operational | Where-Object {$_ -eq 'good'}).Count -gt 0){'good'}else{'unknown'}
$overallReasons=@()
foreach($key in @('cpu','memory','storage','battery')) { if($ratings[$key] -eq 'critical' -or $ratings[$key] -eq 'warning') { $overallReasons+=('{0}: {1}' -f $key,$ratings[$key]) } }
if($overallReasons.Count -eq 0){$overallReasons=@('No warning or critical measurements detected (unknown metrics not evaluated).')}
$topCpu=Safe { @(Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object { @{ name=$_.ProcessName; cumulative_cpu_seconds=RoundOrNull $_.CPU } }) }
$topRam=Safe { @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object { @{ name=$_.ProcessName; working_set_mb=RoundOrNull ($_.WorkingSet64/1MB) } }) }
# Working set is resident memory per process, not total system RAM or private committed memory.
$allProcesses=Safe { @(Get-Process | Where-Object { $_.WorkingSet64 -gt 0 }) }
$ramGroups=@($allProcesses | Group-Object ProcessName | ForEach-Object {
 $sum=($_.Group | Measure-Object WorkingSet64 -Sum).Sum
 [pscustomobject]@{ name=$_.Name; instances=$_.Count; resident_mb=RoundOrNull ($sum/1MB) }
} | Sort-Object resident_mb -Descending)
$ramLeaders=@($ramGroups | Select-Object -First 15)
$ramTop5Mb=($ramLeaders | Select-Object -First 5 | Measure-Object resident_mb -Sum).Sum
$ramReport=Join-Path $OutputDirectory ($reportStem + '_ram.txt')
$ramLines=@('RAM UTILISATION - PROCESS SUMMARY','==========================================',('Hostname       : '+$env:COMPUTERNAME),('Collected UTC  : '+(Get-Date).ToUniversalTime().ToString('o')),('Installed RAM  : '+(RoundOrNull ($ramTotal/1GB))+' GB'),('System RAM used: '+$ramPct+'%'),'', 'TOP 15 APPLICATION / PROCESS GROUPS (resident working set)','----------------------------------------------------------',(' {0,-5} {1,-30} {2,10} {3,9}' -f 'Rank','Process','RAM (MB)','Instances'))
$i=0
foreach($g in $ramLeaders){$i++;$ramLines+=(' {0,-5} {1,-30} {2,10:N1} {3,9}' -f $i,$g.name,$g.resident_mb,$g.instances)}
$ramLines+=@('',('Top 5 process groups (sum of working sets): '+(RoundOrNull $ramTop5Mb)+' MB'),'', 'INTERPRETATION','----------------------------------------------------------','High system RAM usage does not necessarily mean a memory leak.','Windows also uses RAM for file cache, drivers, shared pages and the OS.','Working sets can double-count shared pages; do not sum them to infer total used RAM.','Multiple browser tabs or processes may be grouped under one process name.','For persistent high usage, inspect Task Manager > Processes and Details,','sort by Memory, and check the same device again after normal work.','Avoid terminating security, system or unfamiliar processes.')
$ramLines | Set-Content -LiteralPath $ramReport -Encoding UTF8
Write-Host ('RAM saved: ' + $ramReport)
$report=[ordered]@{
 schema_version='1.0'; collected_at_utc=(Get-Date).ToUniversalTime().ToString('o'); platform='windows'; hostname=$env:COMPUTERNAME
 device=[ordered]@{ manufacturer=$computer.Manufacturer; model=$computer.Model; serial_number=$bios.SerialNumber; os_name=$os.Caption; os_version=$os.Version; cpu_model=$cpu.Name; bios_release_date=$biosDate; purchase_date=if($purchaseAge -ne $null){$PurchaseDate}else{$null}; age_years=$purchaseAge; age_source=if($purchaseAge -ne $null){'purchase_date'}else{'unknown'} }
 metrics=[ordered]@{ cpu_percent=$cpuPct; ram_total_gb=RoundOrNull ($ramTotal/1GB); ram_used_percent=$ramPct; storage_total_gb=if($disk){RoundOrNull ($disk.Size/1GB)}else{$null}; storage_free_gb=if($disk){RoundOrNull ($disk.FreeSpace/1GB)}else{$null}; storage_free_percent=$diskFreePct; battery_design_mwh=$design; battery_full_charge_mwh=$fullCap; battery_health_percent=$batteryPct; battery_cycle_count=$cycles; battery_cycle_level=$cycleLevel; battery_cycle_assessment=$cycleAssessment; battery_recommendation=$batteryAdvice; battery_cycle_rated_limit_assumed=$cycleLimit; uptime_days=$uptime }
 ratings=$ratings; overall_status=$overall; overall_reasons=$overallReasons
 processes=[ordered]@{top_cumulative_cpu=$topCpu; top_memory=$topRam; memory_groups=$ramLeaders; memory_top5_working_set_mb=(RoundOrNull $ramTop5Mb)}
 notes=@('CPU usage is a short sample, not an idle-only benchmark.','Top CPU processes are ranked by cumulative CPU time, not instantaneous CPU usage.','Battery metrics may be unavailable on some devices.','Age is only calculated from an explicitly provided purchase date; BIOS release date is not device manufacture date.')
}
$file=Join-Path $OutputDirectory ($reportStem + '.json')
$json = $report | ConvertTo-Json -Depth 10
$json | Set-Content -LiteralPath $file -Encoding UTF8
Write-Host ('JSON saved: ' + $file)
$stem = [IO.Path]::GetFileNameWithoutExtension($file)
$txt = Join-Path $OutputDirectory ($stem + '.txt')
function DisplayValue($value, $suffix='') { if ($null -eq $value) { return 'Unknown' }; return "$value$suffix" }
$checks = @(
 @{ Name='Battery health'; Rating=$ratings.battery; Value=(DisplayValue $batteryPct '%'); Detail='below 80% is critical; 80-84.9% warning; 85%+ good' },
 @{ Name='Free storage'; Rating=$ratings.storage; Value=(DisplayValue $diskFreePct '%'); Detail='below 10% is critical; 10-19.9% warning; 20%+ good' },
 @{ Name='RAM utilisation'; Rating=$ratings.memory; Value=(DisplayValue $ramPct '%'); Detail='90%+ is critical; 75-89.9% warning; below 75% good' },
 @{ Name='CPU utilisation'; Rating=$ratings.cpu; Value=(DisplayValue $cpuPct '%'); Detail='50%+ is critical; 20-49.9% warning; below 20% good' }
)
$reasonLines = @(); $actions = @()
foreach ($c in $checks) {
 $reasonLines += ('  [{0}] {1}: {2} ({3})' -f $c.Rating.ToUpperInvariant(), $c.Name, $c.Value, $c.Detail)
}
if ($ratings.battery -eq 'critical') { $actions += 'Evaluate battery replacement and verify runtime/service condition.' }
elseif ($ratings.battery -eq 'warning') { $actions += 'Monitor battery capacity and runtime.' }
if ($cycleLevel -eq 'limit_reached') { $actions += 'Check manufacturer cycle limit and battery service status.' }
if ($ratings.storage -eq 'critical' -or $ratings.storage -eq 'warning') { $actions += 'Free up disk space and review large files.' }
if ($ratings.memory -eq 'critical' -or $ratings.memory -eq 'warning') { $actions += 'Review memory-intensive applications and startup items.' }
if ($ratings.cpu -eq 'critical' -or $ratings.cpu -eq 'warning') { $actions += 'Review high-CPU processes; recheck CPU while idle.' }
if ($actions.Count -eq 0) { $actions += 'No immediate action from available measurements; monitor routinely.' }
$actionLines = @(); for ($i=0; $i -lt $actions.Count; $i++) { $actionLines += ('  {0}. {1}' -f ($i+1),$actions[$i]) }
$lines = @(
 'DEVICE HEALTH CHECK - WINDOWS',
 '==========================================',
 '',
 'DEVICE INFORMATION',
 '------------------------------------------',
 ('Collected UTC  : ' + $report.collected_at_utc),
 ('Hostname       : ' + $report.hostname),
 ('Device         : ' + $computer.Manufacturer + ' ' + $computer.Model),
 ('Serial         : ' + $bios.SerialNumber),
 ('OS             : ' + $os.Caption + ' ' + $os.Version),
 ('Device age     : ' + $(if($null -eq $purchaseAge){'Unknown - add purchase date in dashboard'}else{"$purchaseAge years"})),
 '',
 'OVERALL DEVICE HEALTH',
 '------------------------------------------',
 ('Overall Status : ' + $overall.ToUpperInvariant()),
 '',
 'Reasons:'
) + $reasonLines + @(
 '',
 'Recommended Actions:'
) + $actionLines + @(
 '',
 'PERFORMANCE AND STORAGE',
 '------------------------------------------',
 ('CPU usage      : ' + (DisplayValue $cpuPct '%')),
 ('RAM utilisation: ' + (DisplayValue $ramPct '%')),
 ('Storage free   : ' + (DisplayValue $diskFreePct '%')),
 ('System uptime  : ' + (DisplayValue $uptime ' days')),
 ('Top RAM process: ' + $(if($ramLeaders.Count -gt 0){$ramLeaders[0].name + ' (' + $ramLeaders[0].resident_mb + ' MB)'}else{'Unknown'})),
 ('RAM detail     : ' + $ramReport),
 '',
 'BATTERY HEALTH',
 '------------------------------------------',
 ('Design Capacity      : ' + (DisplayValue $design ' mWh')),
 ('Full Charge Capacity : ' + (DisplayValue $fullCap ' mWh')),
 'Battery Health Estimate:',
 '  (Full Charge Capacity / Design Capacity) x 100%',
 ('  ' + $(if($null -eq $batteryPct){'Unavailable (capacity data missing)'}else{"$fullCap / $design x 100% = $batteryPct%"})),
 ('Battery Health Rating : ' + $ratings.battery.ToUpperInvariant()),
 ('Battery Cycle Count   : ' + (DisplayValue $cycles ' cycles')),
 ('Battery Cycle Level   : ' + $cycleLevel.ToUpperInvariant()),
 ('Cycle Assessment      : ' + $cycleAssessment),
 ('Battery Recommendation: ' + $batteryAdvice),
 ('Cycle rating assumes ' + $cycleLimit + ' cycles; confirm the model-specific rated limit.'),
 '',
 'REPORT FILES',
 '------------------------------------------',
 ('Battery report : ' + $batReport),
 ('RAM report     : ' + $ramReport),
 ('JSON report    : ' + $file),
 '',
 'NOTES',
 '------------------------------------------',
 'Ratings are configurable IT triage thresholds, not manufacturer diagnostics.',
 'Unknown measurements do not count as good. CPU is a short sample.',
 'Device age is unknown without a purchase date.'
)
$lines | Set-Content -LiteralPath $txt -Encoding UTF8
Write-Host ('TXT saved: ' + $txt)
# Portable deployment: fixed HTTPS endpoint, no persistent token or local Node.js required.
# During the initial supervised test, the operator enters the current API token once per run.
$apiUrl = 'https://device-health-api.onrender.com/api/ingest'
$uploadToken = $env:DEVICE_HEALTH_API_TOKEN
if ([string]::IsNullOrWhiteSpace($uploadToken)) {
 Write-Host 'Report saved locally. Enter the API token to upload (leave blank to skip).'
 $secureToken = Read-Host 'Device Health API token' -AsSecureString
 if ($secureToken.Length -gt 0) {
  $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
  try { $uploadToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
 }
 Remove-Variable secureToken -ErrorAction SilentlyContinue
}
if (-not [string]::IsNullOrWhiteSpace($uploadToken)) {
 try {
  $response = Invoke-RestMethod -Uri $apiUrl -Method Post -ContentType 'application/json; charset=utf-8' -Headers @{ Authorization = ('Bearer ' + $uploadToken) } -Body ([System.IO.File]::ReadAllText($file)) -TimeoutSec 45 -ErrorAction Stop
  Write-Host ('UPLOAD SUCCESSFUL. Device ID: ' + $response.deviceId) -ForegroundColor Green
 } catch {
  Write-Warning ('API upload failed: ' + $_.Exception.Message)
  Write-Host ('Local JSON report retained: ' + $file)
 }
} else {
 Write-Host ('Upload skipped; local JSON report retained: ' + $file)
}
Remove-Variable uploadToken -ErrorAction SilentlyContinue
Write-Host "RAM process report: $ramReport"; Write-Host "TXT summary: $txt"; Write-Host "Battery report: $batReport"
Write-Host "Saved: $file"; Write-Host "Overall status: $overall"; Write-Host "Battery health: $batteryPct% | Free storage: $diskFreePct% | RAM used: $ramPct%"

} catch {
    $message = "Device Health Check failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
    Write-Host $message -ForegroundColor Red
    Write-Host ('Error log: ' + $script:healthErrorLog)
    $message + [Environment]::NewLine + $_.ScriptStackTrace | Set-Content -LiteralPath $script:healthErrorLog -Encoding UTF8
    throw
}
