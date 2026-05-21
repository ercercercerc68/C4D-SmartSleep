# C4D-SmartSleep.ps1  (v6: based on stable v3.3 + targeted bugfixes only)
# Sleep after idle unless Cinema 4D is actually rendering.
# Works with Windows PowerShell 5.1 and NVIDIA GPUs.

# ===== CONFIG =====
$IdleMinutesThreshold   = 15
$GpuIdleThresholdPct    = 10
$CpuIdleThresholdPct    = 8
$Samples                = 3
# Per-sample CPU window (seconds). De-synced to avoid alignment with fixed-length render frames.
$SampleIntervalsSecs    = @(59, 45, 76)
$C4DNames               = @('cinema4d','cinema4d.exe','Cinema 4D','Cinema 4D.exe','Commandline','Commandline.exe')

# ===== LOGGING =====
$LogDir  = 'C:\Scripts'
$LogFile = Join-Path $LogDir 'C4D-SmartSleep.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
function Log([string]$msg){ try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
Log "----- Script start ----- (user=$env:USERNAME, ver=v6)"

# ===== WINDOWS UPDATE SAFETY LATCH =====
# Note: requires the scheduled task to run with "Run with highest privileges" enabled.
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

# ===== DEADLINE HELPERS =====
function Get-DeadlineCommandPath {
  $cmd = Get-Command deadlinecommand.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    'C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe',
    'C:\Program Files\Deadline10\bin\deadlinecommand.exe',
    'C:\Program Files\Thinkbox\Deadline\bin\deadlinecommand.exe',
    'C:\Program Files\Deadline\bin\deadlinecommand.exe'
  )
  foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
  return $null
}

function Get-DeadlineStatusString {
  try {
    $dc = Get-DeadlineCommandPath
    if (-not $dc) { Log "deadlinecommand.exe not found"; return $null }
    # Use the direct field query — confirmed working on this install
    $out = & $dc -GetSlaveInfo $env:COMPUTERNAME SlaveStatus 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return ($out | Select-Object -Last 1).Trim()
  } catch {
    Log "deadlinecommand query failed: $($_.Exception.Message)"
    return $null
  }
}

function Is-DeadlineIdle {
  $status = Get-DeadlineStatusString
  if (-not $status) { Log "Deadline status=unknown"; return $null }
  Log ("Deadline status={0}" -f $status)
  if ($status -match '(?i)\bidle\b') { return $true }
  if ($status -match '(?i)render|busy|starting|initializ|processing|encoding') { return $false }
  return $null
}

# ===== C4D CPU% (delta method, robust to process exit mid-sample) =====
function Get-C4D-CPUPercent([int]$intervalSeconds){
  try {
    $procsA = @()
    foreach ($n in $C4DNames){ $procsA += Get-Process -Name $n -ErrorAction SilentlyContinue }
    if (-not $procsA){ return $null }
    $logical = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $tA = @{}
    foreach ($p in $procsA){ try { $tA[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch {} }

    Start-Sleep -Seconds $intervalSeconds

    $procsB = @()
    foreach ($n in $C4DNames){ $procsB += Get-Process -Name $n -ErrorAction SilentlyContinue }
    if (-not $procsB){ return $null }
    $cpuDelta = 0.0; $matched = 0
    foreach ($p in $procsB){
      try {
        if ($tA.ContainsKey($p.Id)){
          $cpuDelta += [math]::Max(0, $p.TotalProcessorTime.TotalSeconds - $tA[$p.Id])
          $matched++
        }
      } catch {}
    }
    if ($matched -eq 0){ return $null }
    $pct = ($cpuDelta / ($intervalSeconds * [double]$logical)) * 100.0
    return [int][math]::Round([math]::Min([math]::Max($pct,0),1000))
  } catch { return $null }
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

  $dlIdle = Is-DeadlineIdle
  if ($dlIdle -ne $true) {
    if ($dlIdle -eq $false) { Log "Deadline busy -> stay awake" } else { Log "Deadline status unknown -> stay awake" }
    return $false
  }

  $isC4D = Is-C4DRunning
  Log ("C4D running={0}" -f $isC4D)
  if (-not $isC4D){ Log "C4D not running -> OK to sleep"; return $true }

  $intervals = @() + $SampleIntervalsSecs
  while ($intervals.Count -lt $Samples){ $intervals += (Get-Random -Minimum 20 -Maximum 90) }

  $okCount = 0
  for ($i=1; $i -le $Samples; $i++){
    $interval = [int]$intervals[$i-1]
    $cpuPct = Get-C4D-CPUPercent -intervalSeconds ([math]::Max($interval, 5))
    $gpuArr = Get-NV-GpuUtils
    $gpuTxt = if ($gpuArr) { ($gpuArr -join ',') } else { 'null' }
    Log ("Sample {0}/{1} (win={2}s): CPU={3}%  GPUs=[{4}]" -f $i, $Samples, $interval, ($cpuPct -as [string]), $gpuTxt)

    if ($cpuPct -eq $null -or $gpuArr -eq $null) {
      Log "  Null metric -> conservative: stay awake"
    } else {
      $allGpuIdle = ($gpuArr | Where-Object { $_ -ge $GpuIdleThresholdPct }).Count -eq 0
      if ($allGpuIdle -and ($cpuPct -lt $CpuIdleThresholdPct)) { $okCount++ }
    }
  }

  if ($okCount -lt $Samples){ Log "Activity detected ($okCount/$Samples idle) -> stay awake"; return $false }

  # Re-check idle — user may have become active during the ~3 min sampling window
  $idleNow = Get-UserIdleMinutes
  if ($idleNow -lt $IdleMinutesThreshold){
    Log "User active during sampling (idle now=$idleNow min) -> stay awake"
    return $false
  }

  Log "All $Samples samples idle -> OK to sleep"
  return $true
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
  if (-not (Is-C4DRunning)) {
    Restore-WindowsUpdate
  } else {
    Log "[INFO] Cinema 4D active -> keeping Windows Update service stopped."
  }
}
