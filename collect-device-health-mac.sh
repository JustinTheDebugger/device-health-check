#!/bin/bash
# macOS built-in tools only. Read-only; outputs JSON. Optional PURCHASE_DATE=YYYY-MM-DD.
set -u
OUT_DIR="${OUTPUT_DIR:-$HOME/Desktop/DeviceHealthReports}"
PURCHASE_DATE="${PURCHASE_DATE:-}"
mkdir -p "$OUT_DIR"
python3_bin="$(command -v python3 || true)"
# Python 3 is not guaranteed on macOS. Use osascript JavaScript for JSON serialization instead.
get() { "$@" 2>/dev/null || true; }
sp="$(get system_profiler SPHardwareDataType SPPowerDataType)"
model="$(printf '%s\n' "$sp" | awk -F': ' '/Model Name:/ {print $2;exit}')"
serial="$(printf '%s\n' "$sp" | awk -F': ' '/Serial Number \(system\):/ {print $2;exit}')"
chip="$(printf '%s\n' "$sp" | awk -F': ' '/Chip:|Processor Name:/ {print $2;exit}')"
mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo '')"
# CPU sampled from top's overall CPU line; locale is expected to use English labels.
cpu_line="$(top -l 2 -n 0 -s 1 2>/dev/null | grep 'CPU usage:' | tail -1)"
cpu_pct="$(printf '%s' "$cpu_line" | sed -nE 's/.* ([0-9]+([.][0-9]+)?)% idle.*/\1/p' | awk '{if(NF)printf "%.1f",100-$1}')"
# vm_stat gives page statistics, but macOS memory pressure is more meaningful than naive percent-used.
mem_pressure="$(memory_pressure 2>/dev/null | awk -F': ' '/System-wide free memory percentage:/ {gsub(/%/,"",$2); print $2; exit}')"
free_mem_pct="${mem_pressure:-}"
used_mem_pct="" # Do not equate macOS free memory percentage with RAM utilisation.
disk_line="$(df -kP / | tail -1)"
disk_total_kb="$(printf '%s' "$disk_line" | awk '{print $2}')"
disk_free_kb="$(printf '%s' "$disk_line" | awk '{print $4}')"
boot_seconds="$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/.*sec = ([0-9]+).*/\1/p')"
now_seconds="$(date +%s)"
uptime_days="$(awk -v n="$now_seconds" -v b="${boot_seconds:-0}" 'BEGIN{if(b>0)printf "%.1f",(n-b)/86400}')"
# ioreg battery fields use mAh on many Macs; use ratio only and avoid mislabelling units.
batt="$(ioreg -r -c AppleSmartBattery 2>/dev/null)"
design="$(printf '%s\n' "$batt" | sed -nE 's/.*"DesignCapacity" = ([0-9]+).*/\1/p' | head -1)"
full="$(printf '%s\n' "$batt" | sed -nE 's/.*"AppleRawMaxCapacity" = ([0-9]+).*/\1/p' | head -1)"
[ -n "$full" ] || full="$(printf '%s\n' "$batt" | sed -nE 's/.*"MaxCapacity" = ([0-9]+).*/\1/p' | head -1)"
cycles="$(printf '%s\n' "$batt" | sed -nE 's/.*"CycleCount" = ([0-9]+).*/\1/p' | head -1)"
health="$(awk -v a="${full:-0}" -v b="${design:-0}" 'BEGIN{if(b>0 && a>0)printf "%.1f",100*a/b}')"
macos="$(sw_vers -productVersion)"
host="$(scutil --get ComputerName 2>/dev/null || hostname)"
# Save raw values in environment; JXA JSON.stringify provides safe escaping.
export DH_HOST="$host" DH_MODEL="$model" DH_SERIAL="$serial" DH_CHIP="$chip" DH_OS="$macos" DH_RAM="$mem_bytes" DH_CPU="$cpu_pct" DH_RAM_USED="$used_mem_pct" DH_DISK_TOTAL="$disk_total_kb" DH_DISK_FREE="$disk_free_kb" DH_UPTIME="$uptime_days" DH_DESIGN="$design" DH_FULL="$full" DH_CYCLES="$cycles" DH_HEALTH="$health" DH_PURCHASE="$PURCHASE_DATE"
file="$OUT_DIR/health_$(hostname | tr -cd 'A-Za-z0-9_-')_$(date +%Y%m%d_%H%M%S).json"
# Top process groups by resident set size (RSS). ps reports KiB on macOS.
ram_report="${file%.json}_ram.txt"
ram_rows="$(ps -axo rss=,comm= 2>/dev/null | awk '
  $1 ~ /^[0-9]+$/ && NF >= 2 {
    rss=$1; $1=""; sub(/^[[:space:]]+/, "", $0);
    name=$0; sub(/^.*\//,"",name);
    if(name=="") name="Unknown";
    total[name]+=rss; count[name]++;
  }
  END { for(n in total) printf "%.1f\t%d\t%s\n",total[n]/1024,count[n],n }
' | sort -nr | head -15)"
{
 printf 'RAM UTILISATION - PROCESS SUMMARY\n==========================================\n'
 printf 'Hostname       : %s\nCollected      : %s\n' "$host" "$(date)"
 printf 'Installed RAM  : %s GB\n' "$(awk -v b="${mem_bytes:-0}" 'BEGIN{if(b>0)printf "%.1f",b/1073741824;else printf "Unknown"}')"
 printf 'System RAM used: Unknown (use Activity Monitor > Memory Pressure)\n\n'
 printf 'TOP 15 APPLICATION / PROCESS GROUPS (resident set size)\n----------------------------------------------------------\n'
 printf '%-5s %-35s %10s %10s\n' Rank Process 'RAM (MB)' Instances
 printf '%s\n' "$ram_rows" | awk -F '\t' 'NF==3 {printf "%-5d %-35.35s %10.1f %10d\n",NR,$3,$1,$2}'
 printf '\nINTERPRETATION\n----------------------------------------------------------\n'
 printf 'RSS is resident process memory, not total system memory usage.\n'
 printf 'Shared pages can be counted in multiple processes.\n'
 printf 'macOS uses compressed memory and file cache; inspect Activity Monitor\n'
 printf 'Memory Pressure and Swap Used to diagnose memory bottlenecks.\n'
 printf 'A process name may represent many browser tabs or app helpers.\n'
 printf 'Do not terminate unfamiliar system or security processes.\n'
} > "$ram_report"
export DH_RAM_ROWS="$ram_rows"
/usr/bin/osascript -l JavaScript -e '
ObjC.import("stdlib");
function env(k){var v=$.getenv(k);return v?ObjC.unwrap(v):"";}
function num(k){var v=env(k);return v!=="" && isFinite(Number(v))?Number(v):null;}
function high(n,a,b){return n===null?"unknown":n<a?"good":n<b?"warning":"critical";}
function low(n,a,b){return n===null?"unknown":n>=a?"good":n>=b?"warning":"critical";}
function run(){
 var free=num("DH_DISK_FREE"),total=num("DH_DISK_TOTAL");var freePct=total?Math.round(1000*free/total)/10:null;
 var age=null,p=env("DH_PURCHASE");if(/^\d{4}-\d{2}-\d{2}$/.test(p)){var d=new Date(p+"T00:00:00Z");if(!isNaN(d)&&d.toISOString().slice(0,10)===p&&d<=new Date())age=Math.round((Date.now()-d.getTime())/86400000/365.2425*10)/10;}
 var r={age:age===null?"unknown":age<3?"good":age<5?"warning":"review",cpu:high(num("DH_CPU"),20,50),memory:high(num("DH_RAM_USED"),75,90),storage:low(freePct,20,10),battery:low(num("DH_HEALTH"),85,80),uptime:num("DH_UPTIME")===null?"unknown":num("DH_UPTIME")<7?"good":"warning"};
 var cycles=num("DH_CYCLES"),health=num("DH_HEALTH");
 var cycleLevel=cycles===null?"unknown":cycles<300?"low":cycles<700?"medium":cycles<1000?"high":"limit_reached";
 var cycleAssessment=cycleLevel==="unknown"?"Unknown":cycleLevel==="low"?"Acceptable":cycleLevel==="medium"?"Acceptable - monitor":cycleLevel==="high"?"Aging - monitor closely":"Review replacement eligibility";
 var batteryAdvice=health===null?"Unknown - inspect battery report":health<80?"Replacement evaluation recommended":cycleLevel==="limit_reached"?"Review manufacturer cycle limit and runtime":health<85?"Monitor capacity and runtime":"Acceptable if runtime and service condition are normal";
 var checks=[r.cpu,r.memory,r.storage,r.battery];var overall=checks.includes("critical")?"critical":checks.includes("warning")?"warning":checks.includes("good")?"good":"unknown";
 var reasons=["cpu","memory","storage","battery"].filter(function(k){return r[k]==="critical"||r[k]==="warning";}).map(function(k){return k+": "+r[k];});if(!reasons.length)reasons=["No warning or critical measurements detected (unknown metrics not evaluated)."];
 var o={schema_version:"1.0",collected_at_utc:new Date().toISOString(),platform:"macos",hostname:env("DH_HOST"),device:{manufacturer:"Apple",model:env("DH_MODEL"),serial_number:env("DH_SERIAL"),os_name:"macOS",os_version:env("DH_OS"),cpu_model:env("DH_CHIP"),bios_release_date:null,purchase_date:age===null?null:p,age_years:age,age_source:age===null?"unknown":"purchase_date"},metrics:{cpu_percent:num("DH_CPU"),ram_total_gb:num("DH_RAM")===null?null:Math.round(num("DH_RAM")/1073741824*10)/10,ram_used_percent:num("DH_RAM_USED"),storage_total_gb:total===null?null:Math.round(total/1048576*10)/10,storage_free_gb:free===null?null:Math.round(free/1048576*10)/10,storage_free_percent:freePct,battery_design_mwh:null,battery_full_charge_mwh:null,battery_health_percent:num("DH_HEALTH"),battery_cycle_count:cycles,battery_cycle_level:cycleLevel,battery_cycle_assessment:cycleAssessment,battery_recommendation:batteryAdvice,battery_cycle_rated_limit_assumed:1000,uptime_days:num("DH_UPTIME")},ratings:r,overall_status:overall,overall_reasons:reasons,processes:{top_cumulative_cpu:[],top_memory:[],memory_groups:env("DH_RAM_ROWS").split("\n").filter(Boolean).map(function(line){var p=line.split("\t");return {name:p.slice(2).join("\t"),resident_mb:Number(p[0]),instances:Number(p[1])};})},notes:["macOS memory percentage is an approximation from memory_pressure, not Activity Monitor memory pressure color.","Battery capacity values are not exported because their units vary by hardware.","Device age requires an explicitly provided purchase date.","Some battery values may be unavailable on newer hardware."]};return JSON.stringify(o,null,2);
}' > "$file"
stem="${file%.json}"
summary="${stem}.txt"
battery_txt="${stem}_battery.txt"
system_profiler SPPowerDataType > "$battery_txt" 2>&1 || printf 'Battery report unavailable on this device.\n' > "$battery_txt"
# Derive summary ratings from the same thresholds as the JSON collector.
rate_high() { if [ -z "$1" ]; then echo UNKNOWN; elif awk -v v="$1" -v t="$2" 'BEGIN{exit !(v<t)}'; then echo GOOD; elif awk -v v="$1" -v t="$3" 'BEGIN{exit !(v<t)}'; then echo WARNING; else echo CRITICAL; fi; }
rate_low() { if [ -z "$1" ]; then echo UNKNOWN; elif awk -v v="$1" -v t="$2" 'BEGIN{exit !(v>=t)}'; then echo GOOD; elif awk -v v="$1" -v t="$3" 'BEGIN{exit !(v>=t)}'; then echo WARNING; else echo CRITICAL; fi; }
free_pct="$(awk -v f="${disk_free_kb:-0}" -v t="${disk_total_kb:-0}" 'BEGIN{if(t>0)printf "%.1f",100*f/t}')"
cpu_rating="$(rate_high "$cpu_pct" 20 50)"
ram_rating='UNKNOWN'
storage_rating="$(rate_low "$free_pct" 20 10)"
battery_rating="$(rate_low "$health" 85 80)"
overall='UNKNOWN'
for rating in "$cpu_rating" "$ram_rating" "$storage_rating" "$battery_rating"; do
 if [ "$rating" = CRITICAL ]; then overall=CRITICAL; break; fi
 if [ "$rating" = WARNING ]; then overall=WARNING; fi
 if [ "$rating" = GOOD ] && [ "$overall" = UNKNOWN ]; then overall=GOOD; fi
done
if [ -z "$cycles" ]; then cycle_level='Unknown'; cycle_assessment='Unknown'; elif [ "$cycles" -lt 300 ]; then cycle_level='Low'; cycle_assessment='Acceptable'; elif [ "$cycles" -lt 700 ]; then cycle_level='Medium'; cycle_assessment='Acceptable - monitor'; elif [ "$cycles" -lt 1000 ]; then cycle_level='High'; cycle_assessment='Aging - monitor closely'; else cycle_level='Limit reached'; cycle_assessment='Review replacement eligibility'; fi
if [ -z "$health" ]; then advice='Unknown - inspect battery report'; elif awk -v h="$health" 'BEGIN{exit !(h<80)}'; then advice='Replacement evaluation recommended'; elif [ "${cycles:-0}" -ge 1000 ]; then advice='Review manufacturer cycle limit and runtime'; elif awk -v h="$health" 'BEGIN{exit !(h<85)}'; then advice='Monitor capacity and runtime'; else advice='Acceptable if runtime and service condition are normal'; fi
{
 printf 'DEVICE HEALTH CHECK - MACOS\n==========================================\n\n'
 printf 'DEVICE INFORMATION\n------------------------------------------\n'
 printf 'Collected      : %s\nHostname       : %s\nDevice         : %s\nSerial         : %s\nmacOS          : %s\n' "$(date)" "$host" "$model" "$serial" "$macos"
 printf 'Device age     : Unknown - add purchase date in dashboard\n\n'
 printf 'OVERALL DEVICE HEALTH\n------------------------------------------\nOverall Status : %s\n\nReasons:\n' "$overall"
 printf '  [%s] Battery health: %s%% (critical <80%%; warning 80-84.9%%; good >=85%%)\n' "$battery_rating" "${health:-Unknown}"
 printf '  [%s] Free storage: %s%% (critical <10%%; warning 10-19.9%%; good >=20%%)\n' "$storage_rating" "${free_pct:-Unknown}"
 printf '  [%s] RAM utilisation: Unknown (check Activity Monitor memory pressure)\n' "$ram_rating"
 printf '  [%s] CPU utilisation: %s%% (critical >=50%%; warning 20-49.9%%; good <20%%)\n' "$cpu_rating" "${cpu_pct:-Unknown}"
 printf '\nRecommended Actions:\n'
 action_count=0
 add_action() { action_count=$((action_count+1)); printf '  %s. %s\n' "$action_count" "$1"; }
 if [ "$battery_rating" = CRITICAL ]; then add_action 'Evaluate battery replacement and verify runtime/service condition.'; elif [ "$battery_rating" = WARNING ]; then add_action 'Monitor battery capacity and runtime.'; fi
 if [ "$cycle_level" = 'Limit reached' ]; then add_action 'Check manufacturer cycle limit and battery service status.'; fi
 if [ "$storage_rating" = CRITICAL ] || [ "$storage_rating" = WARNING ]; then add_action 'Free up disk space and review large files.'; fi
 if [ "$cpu_rating" = CRITICAL ] || [ "$cpu_rating" = WARNING ]; then add_action 'Review high-CPU processes; recheck while idle.'; fi
 if [ "$action_count" -eq 0 ]; then add_action 'No immediate action from available measurements; monitor routinely.'; fi
 printf '\nPERFORMANCE AND STORAGE\n------------------------------------------\n'
 printf 'CPU usage       : %s%%\nRAM utilisation : Unknown\nFree storage    : %s%%\nUptime          : %s days\n' "${cpu_pct:-Unknown}" "${free_pct:-Unknown}" "${uptime_days:-Unknown}"
 printf 'RAM process detail: %s\n' "$ram_report"
 printf '\nBATTERY HEALTH\n------------------------------------------\n'
 printf 'Design Capacity      : %s (ioreg units; may vary by model)\nFull Charge Capacity : %s (same source)\n' "${design:-Unknown}" "${full:-Unknown}"
 printf 'Battery Health Estimate:\n  (Full Charge Capacity / Design Capacity) x 100%%\n'
 if [ -n "$design" ] && [ -n "$full" ] && [ -n "$health" ]; then printf '  %s / %s x 100%% = %s%%\n' "$full" "$design" "$health"; else printf '  Unavailable (capacity data missing)\n'; fi
 printf 'Battery Health Rating : %s\nBattery Cycle Count   : %s\nBattery Cycle Level   : %s\nCycle Assessment      : %s\nBattery Recommendation: %s\n' "$battery_rating" "${cycles:-Unknown}" "$cycle_level" "$cycle_assessment" "$advice"
 printf 'Cycle rating assumes 1000 cycles; confirm the model-specific rated limit.\n'
 printf '\nREPORT FILES\n------------------------------------------\nBattery details : %s\nRAM report      : %s\nJSON report     : %s\n' "$battery_txt" "$ram_report" "$file"
 printf '\nNOTES\n------------------------------------------\nRatings are IT triage thresholds, not manufacturer diagnostics.\nUnknown measurements do not count as good. CPU is a short sample.\n'
} > "$summary"
if [ -n "${DEVICE_HEALTH_API_URL:-}" ] && [ -n "${DEVICE_HEALTH_API_TOKEN:-}" ]; then
 case "$DEVICE_HEALTH_API_URL" in
 https://*) if ! curl --fail --silent --show-error --max-time 15 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $DEVICE_HEALTH_API_TOKEN" --data-binary "@$file" "$DEVICE_HEALTH_API_URL" >/dev/null; then echo 'WARNING: API upload failed; local reports retained.' >&2; fi ;;
 *) echo 'WARNING: API URL must use HTTPS; skipped upload.' >&2 ;;
 esac
fi
printf 'TXT summary: %s\nRAM report: %s\nBattery details: %s\n' "$summary" "$ram_report" "$battery_txt"
echo "Saved: $file"
echo "Battery health: ${health:-unknown}% | Free storage: ${disk_free_kb:-unknown} KB | Overall status in JSON"
