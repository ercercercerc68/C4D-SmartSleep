# C4D-SmartSleep.ps1  (v3.1: nvidia-smi only + CPU+GPU gating + logging + Conditional Windows Update latch)
# Sleep after idle unless Cinema4D is actually rendering.
# Works with Windows PowerShell 5.1 and NVIDIA GPUs.

# ===== CONFIG =====
$IdleMinutesThreshold   = 15
$GpuIdleThresholdPct    = 10
$CpuIdleThresholdPct    = 8
$Samples                = 3
$SampleIntervalSecs     = 60
$C4DNames               = @('cinema4d','cinema4d.exe','Cinema 4D','Cinema 4D.exe','Commandline','Commandline.exe')

# ===== LOGGING =====
$LogDir  = 'C:\Scripts'
$LogFile = Join-Path $LogDir 'C4D-SmartSleep.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
function Log([string]$msg){ try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
Log "----- Script start ----- (user=$env:USERNAME, ver=v3.1 conditional WU latch)"

# ===== WINDOWS UPDATE SAFETY LATCH =====
function Ensure-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Host "Restarting as administrator..."
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
        exit
    }
}
Ensure-Admin

$global:WindowsUpdateWasRunning = $false

function Pause-WindowsUpdate {
    try {
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $global:WindowsUpdateWasRunning = $true
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            Log "[INFO] Windows Update service stopped."
        } else {
            Log "[INFO] Windows Update service already stopped."
        }

        # Safety task to restore service at next logon
        $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -WindowStyle Hidden -Command \"Start-Service wuauserv; Unregister-ScheduledTask -TaskName Restore-WindowsUpdate -Confirm:$false\"'
        $trg = New-ScheduledTaskTrigger -AtLogOn
        Register-ScheduledTask -TaskName "Restore-WindowsUpdate" -Action $act -Trigger $trg -RunLevel Highest -Force | Out-Null
    } catch {
        Log "[ERROR] Failed to stop Windows Update: $($_.Exception.Message)"
    }
}

function Restore-WindowsUpdate {
    try {
        if ($global:WindowsUpdateWasRunning) {
            Start-Service wuauserv -ErrorAction SilentlyContinue
            Log "[INFO] Windows Update service restored."
        }
        Unregister-ScheduledTask -TaskName "Restore-WindowsUpdate" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Log "[ERROR] Failed to restore Windows Update: $($_.Exception.Message)"
    }
}

# Stop Windows Update now to prevent mid-render reboots
Pause-WindowsUpdate

# ===== IDLE TIME =====
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class IdleTime {
  [StructLayout(LayoutKind.Sequential)]
  public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static uint GetIdleMillis() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(lii);
    GetLastInputInfo(ref lii);
    return ((uint)Environment.TickCount - lii.dwTime);
  }
}
"@
function Get-UserIdleMinutes { try { [math]::Floor([IdleTime]::GetIdleMillis() / 60000.0) } catch { 0 } }

# ===== PROCESS HELPERS =====
function Get-AnyProcess([string[]]$names){
  foreach ($n in $names){ $p = Get-Process -Name $n -ErrorAction SilentlyContinue; if ($p){ return $p } }
  return $null
}
function Is-C4DRunning { $null -ne (Get-AnyProcess $C4DNames) }

# ===== C4D CPU% (delta method) =====
function Get-C4D-CPUPercent([int]$intervalSeconds){
  $procsA = @(); foreach ($n in $C4DNames){ $procsA += Get-Process -Name $n -ErrorAction SilentlyContinue }
  if (-not $procsA){ return $null }
  $logical = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  $tA = @{}; foreach ($p in $procsA){ $tA[$p.Id] = $p.TotalProcessorTime.TotalSeconds }

  Start-Sleep -Seconds $intervalSeconds

  $procsB = @(); foreach ($n in $C4DNames){ $procsB += Get-Process -Name $n -ErrorAction SilentlyContinue }
  if (-not $procsB){ return $null }
  $cpuDelta = 0.0
  foreach ($p in $procsB){
    $tB = $p.TotalProcessorTime.TotalSeconds
    if ($tA.ContainsKey($p.Id)){ $cpuDelta += [math]::Max(0, $tB - $tA[$p.Id]) }
  }
  $pct = ($cpuDelta / ($intervalSeconds * [double]$logical)) * 100.0
  return [int][math]::Round([math]::Min([math]::Max($pct,0),1000))
}

# ===== GPU util via nvidia-smi =====
function Get-NV-GpuUtils {
  try {
    $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $cmd){ Log "nvidia-smi not found"; return $null }
    $out = & $cmd.Source --query-gpu=utilization.gpu --format=csv,noheader,nounits
    if (-not $out){ Log "nvidia-smi returned empty output"; return $null }
    $vals = @()
    foreach ($line in ($out -split "`n")) {
      $s = $line.Trim()
      if ($s -match '^\d+$'){ $vals += [int]$s }
    }
    if ($vals.Count -gt 0){ return ,$vals } else { Log "nvidia-smi parsed no numbers"; return $null }
  } catch { Log ("nvidia-smi failed: {0}" -f $_.Exception.Message); return $null }
}

# ===== DECISION =====
function Should-Sleep {
  $idle = Get-UserIdleMinutes
  Log ("Idle={0} min" -f $idle)
  if ($idle -lt $IdleMinutesThreshold){ Log "Not enough idle time"; return $false }

  $isC4D = Is-C4DRunning
  Log ("C4D running={0}" -f $isC4D)
  if (-not $isC4D){
    Log "C4D not running -> OK to sleep"
    return $true
  }

  $okCount = 0
  for ($i=1; $i -le $Samples; $i++){
    $cpuPct = Get-C4D-CPUPercent -intervalSeconds ([math]::Max([int]($SampleIntervalSecs/2), 5))
    $gpuArr = Get-NV-GpuUtils
    $gpuTxt = if ($gpuArr) { ($gpuArr -join ',') } else { 'null' }
    Log ("Sample {0}: CPU={1}%  GPUs=[{2}]" -f $i, ($cpuPct -as [string]), $gpuTxt)

    if ($cpuPct -eq $null -or $gpuArr -eq $null) {
      Log "Null metric -> conservative: stay awake"
    } else {
      $allGpuIdle = ($gpuArr | Where-Object { $_ -ge $GpuIdleThresholdPct }).Count -eq 0
      if ($allGpuIdle -and ($cpuPct -lt $CpuIdleThresholdPct)) { $okCount++ }
    }
    if ($i -lt $Samples){ Start-Sleep -Seconds ([math]::Max([int]($SampleIntervalSecs/2), 5)) }
  }

  if ($okCount -eq $Samples){
    Log "All samples below thresholds (CPU<$CpuIdleThresholdPct & ALL GPUs<$GpuIdleThresholdPct) -> OK to sleep"
    return $true
  } else {
    Log "Activity detected -> stay awake"
    return $false
  }
}

# ===== SLEEP =====
function Go-ToSleep {
  Log ">>> Going to sleep now"
  try {
    Start-Process -WindowStyle Hidden -FilePath "$env:WINDIR\System32\rundll32.exe" -ArgumentList "powrprof.dll,SetSuspendState Sleep"
  } catch { Log "Sleep call failed: $($_.Exception.Message)" }
}

# ===== MAIN =====
try {
  if (Should-Sleep) { Go-ToSleep } else { Log "Decision: stay awake" }
} catch { Log "FATAL: $($_.Exception.Message)" }
finally {
  # Only restore Windows Update if Cinema 4D is NOT running
  if (-not (Is-C4DRunning)) {
    Restore-WindowsUpdate
  } else {
    Log "[INFO] Cinema 4D active -> keeping Windows Update service stopped."
  }
}
