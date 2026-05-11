# C4D-SmartSleep.ps1  (v4: GPU P-state + robust CPU sampling + between-job guard)
# Sleep after idle only when neither Cinema 4D nor Deadline is rendering.
# Works with Windows PowerShell 5.1 and NVIDIA GPUs.

# ===== CONFIG =====
$IdleMinutesThreshold   = 15
$GpuIdleThresholdPct    = 10
$CpuIdleThresholdPct    = 8
$Samples                = 5
$GpuPStateMaxIdle       = 1      # P0/P1 = truly idle; P2+ = active compute
# Per-sample CPU window (seconds). De-synced to avoid aligning with fixed-length render frames.
# If you add more $Samples, add matching entries here (or the script auto-fills with random intervals).
$SampleIntervalsSecs    = @(59, 45, 76, 52, 68)
$C4DNames               = @('cinema4d','cinema4d.exe','Cinema 4D','Cinema 4D.exe','Commandline','Commandline.exe')

# ===== LOGGING =====
$LogDir  = 'C:\Scripts'
$LogFile = Join-Path $LogDir 'C4D-SmartSleep.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
function Log([string]$msg){ try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
Log "----- Script start ----- (user=$env:USERNAME, ver=v4 pstate+deadline)"

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
function Test-C4DRunning { $null -ne (Get-AnyProcess $C4DNames) }

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

function Test-DeadlineWorkerRunning {
  try {
    $p = Get-Process -Name "deadlineworker" -ErrorAction SilentlyContinue
    return ($null -ne $p)
  } catch {
    return $false
  }
}

function Get-DeadlineWorkerInfoText {
  try {
    $dc = Get-DeadlineCommandPath
    if (-not $dc) { Log "deadlinecommand.exe not found"; return $null }
    $workerName = $env:COMPUTERNAME
    $out = & $dc -GetSlaveInfo $workerName 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) {
      $out = & $dc -GetWorkerInfo $workerName 2>$null
    }
    if (-not $out) { return $null }
    return ($out -join "`n")
  } catch {
    Log "deadlinecommand query failed: $($_.Exception.Message)"
    return $null
  }
}

function Get-DeadlineStatusString {
  $txt = Get-DeadlineWorkerInfoText
  if (-not $txt) { return $null }

  if ($txt -match '(?im)^\s*(SlaveStatus|WorkerStatus)\s*=\s*(.+?)\s*$') { return $matches[2].Trim() }
  if ($txt -match '(?im)^\s*Status\s*=\s*(.+?)\s*$') { return $matches[1].Trim() }
  if ($txt -match '(?im)^\s*State\s*=\s*(.+?)\s*$') { return $matches[1].Trim() }

  foreach ($line in ($txt -split "`n")) {
    if ($line -match '(?i)rendering|idle') { return $line.Trim() }
  }
  return $null
}

function Test-DeadlineIdle {
  # If Worker is not running at all, Deadline is not active -> don't gate sleep.
  if (-not (Test-DeadlineWorkerRunning)) { return $true }

  # Worker IS running. Block sleep only when status is clearly busy.
  $status = Get-DeadlineStatusString
  if (-not $status) {
    Log "Deadline Worker running but status=unknown -> stay awake (conservative)"
    # Unknown status while Worker is up: conservative stay-awake.
    return $false
  }

  Log ("Deadline status={0}" -f $status)
  if ($status -match '(?i)render|busy|starting|running|initializ|processing|encoding') { return $false }
  return $true
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

    $cpuDelta = 0.0
    $matched  = 0
    foreach ($p in $procsB){
      try {
        $tB = $p.TotalProcessorTime.TotalSeconds
        if ($tA.ContainsKey($p.Id)){
          $cpuDelta += [math]::Max(0, $tB - $tA[$p.Id])
          $matched++
        }
      } catch {}
    }
    if ($matched -eq 0){ return $null }
    $pct = ($cpuDelta / ($intervalSeconds * [double]$logical)) * 100.0
    return [int][math]::Round([math]::Min([math]::Max($pct, 0), 1000))
  } catch {
    return $null
  }
}

# ===== GPU util + P-state via nvidia-smi =====
function Get-NV-GpuInfo {
  # Returns hashtable with .Utils (int[]) and .PStates (int[])
  # P-state: 0/1 = idle, 2+ = active compute (GPU is working even if util% briefly dips to 0)
  try {
    $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if (-not $cmd){ Log "nvidia-smi not found"; return $null }

    $out = & $cmd.Source --query-gpu=utilization.gpu,pstate --format=csv,noheader,nounits 2>&1
    if (-not $out){ Log "nvidia-smi returned empty output"; return $null }

    $utils   = @()
    $pstates = @()
    foreach ($line in ($out -split "`n")) {
      $s = $line.Trim()
      if (-not $s){ continue }
      # Expected format per GPU: "45, P2"
      if ($s -match '^(\d+)\s*,\s*P(\d+)$'){
        $utils   += [int]$Matches[1]
        $pstates += [int]$Matches[2]
      }
    }
    if ($utils.Count -gt 0){
      return @{ Utils = $utils; PStates = $pstates }
    } else {
      Log "nvidia-smi parsed no GPU data from: $($out -join '|')"
      return $null
    }
  } catch {
    Log ("nvidia-smi failed: {0}" -f $_.Exception.Message)
    return $null
  }
}

# ===== DECISION =====
function Should-Sleep {
  $idle = Get-UserIdleMinutes
  Log ("Idle={0} min" -f $idle)
  if ($idle -lt $IdleMinutesThreshold){ Log "Not enough idle time"; return $false }

  # Deadline safety check (uses deadlinecommand.exe for authoritative status).
  $dlIdle = Test-DeadlineIdle
  if (-not $dlIdle) { Log "Deadline busy -> stay awake"; return $false }

  $isC4D          = Test-C4DRunning
  $isDeadlineProc = Test-DeadlineWorkerRunning
  Log ("C4D running={0}  DeadlineWorker running={1}" -f $isC4D, $isDeadlineProc)

  # If Deadline Worker is up but C4D hasn't launched yet -> between-job gap, stay awake.
  if ($isDeadlineProc -and -not $isC4D){
    Log "Deadline Worker running but C4D not yet launched (between jobs) -> stay awake"
    return $false
  }

  if (-not $isC4D){
    Log "C4D not running -> OK to sleep"
    return $true
  }

  # Build per-sample intervals; auto-fill with random values if $Samples > list length.
  $intervals = @()
  if ($SampleIntervalsSecs) { $intervals += $SampleIntervalsSecs }
  while ($intervals.Count -lt $Samples) {
    $intervals += (Get-Random -Minimum 20 -Maximum 90)
  }

  $okCount = 0
  for ($i = 1; $i -le $Samples; $i++){
    $interval = [int]$intervals[$i - 1]
    $cpuPct   = Get-C4D-CPUPercent -intervalSeconds ([math]::Max($interval, 5))
    $gpuInfo  = Get-NV-GpuInfo

    $gpuUtilTxt   = if ($gpuInfo) { ($gpuInfo.Utils   -join ',') } else { 'null' }
    $gpuPStateTxt = if ($gpuInfo) { ($gpuInfo.PStates | ForEach-Object { "P$_" }) -join ',' } else { 'null' }
    Log ("Sample {0}/{1} (win={2}s): CPU={3}%  GPUs=[{4}]  PStates=[{5}]" -f $i, $Samples, $interval, ($cpuPct -as [string]), $gpuUtilTxt, $gpuPStateTxt)

    if ($null -eq $cpuPct -or $null -eq $gpuInfo){
      Log "  Null metric -> conservative: stay awake"
      continue
    }

    # GPU is idle only if: util% all below threshold AND all P-states <= GpuPStateMaxIdle (P0/P1)
    $anyGpuBusy    = ($gpuInfo.Utils   | Where-Object { $_ -ge $GpuIdleThresholdPct }).Count -gt 0
    $anyGpuCompute = ($gpuInfo.PStates | Where-Object { $_ -gt $GpuPStateMaxIdle     }).Count -gt 0

    if (-not $anyGpuBusy -and -not $anyGpuCompute -and ($cpuPct -lt $CpuIdleThresholdPct)){
      $okCount++
      Log ("  -> idle (okCount={0}/{1})" -f $okCount, $Samples)
    } else {
      Log ("  -> active (gpuBusy={0}, gpuCompute={1}, cpuHigh={2})" -f $anyGpuBusy, $anyGpuCompute, ($cpuPct -ge $CpuIdleThresholdPct))
    }
  }

  if ($okCount -eq $Samples){
    Log "All $Samples samples idle (CPU<$CpuIdleThresholdPct% & GPUs<$GpuIdleThresholdPct% & P-state<=P$GpuPStateMaxIdle) -> OK to sleep"
    return $true
  } else {
    Log "Activity detected ($okCount/$Samples idle samples) -> stay awake"
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
  if (-not (Test-C4DRunning)) {
    Restore-WindowsUpdate
  } else {
    Log "[INFO] Cinema 4D active -> keeping Windows Update service stopped."
  }
}
