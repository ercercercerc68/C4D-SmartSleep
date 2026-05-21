# C4D-SmartSleep.ps1  (v5: simplified - GPU util% + CPU% + Deadline status)
# Sleep after idle only when Cinema 4D is not actively rendering.

# ===== CONFIG =====
$IdleMinutesThreshold   = 15     # minutes of user idle before checking
$GpuIdleThresholdPct    = 10     # all GPUs must be below this util%
$CpuIdleThresholdPct    = 8      # C4D process CPU% must be below this
$Samples                = 5      # samples to take (all must be idle to sleep)
$SampleIntervalsSecs    = @(59, 45, 76, 52, 68)  # de-synced to avoid frame-boundary alignment
$C4DNames               = @('cinema4d','cinema4d.exe','Cinema 4D','Cinema 4D.exe','Commandline','Commandline.exe')

# ===== LOGGING =====
$LogDir  = 'C:\Scripts'
$LogFile = Join-Path $LogDir 'C4D-SmartSleep.log'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if (-not (Test-Path $LogFile)) { New-Item -ItemType File -Path $LogFile -Force | Out-Null }
function Log([string]$msg){ try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $LogFile -Append -Encoding utf8 } catch {} }
Log "----- Script start ----- (user=$env:USERNAME, ver=v5)"

# ===== WINDOWS UPDATE SAFETY LATCH =====
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
    foreach ($n in $names){
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue
        if ($p){ return $p }
    }
    return $null
}
function Test-C4DRunning { $null -ne (Get-AnyProcess $C4DNames) }

# ===== DEADLINE STATUS =====
function Get-DeadlineSlaveStatus {
    try {
        $candidates = @(
            'C:\Program Files\Thinkbox\Deadline10\bin\deadlinecommand.exe',
            'C:\Program Files\Deadline10\bin\deadlinecommand.exe',
            'C:\Program Files\Thinkbox\Deadline\bin\deadlinecommand.exe',
            'C:\Program Files\Deadline\bin\deadlinecommand.exe'
        )
        $dcCmd = Get-Command deadlinecommand.exe -ErrorAction SilentlyContinue
        $dc = if ($dcCmd) { $dcCmd.Source } else { $null }
        if (-not $dc) { $dc = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1 }
        if (-not $dc) { return $null }

        $out = & $dc -GetSlaveInfo $env:COMPUTERNAME SlaveStatus 2>&1
        if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
        return ($out | Select-Object -Last 1).Trim()
    } catch {
        return $null
    }
}

# ===== C4D CPU% (delta method, robust to process exit mid-sample) =====
function Get-C4DCpuPercent([int]$intervalSeconds){
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

# ===== GPU UTILIZATION via nvidia-smi =====
function Get-GpuUtils {
    try {
        $cmd = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if (-not $cmd){ Log "nvidia-smi not found"; return $null }
        $out = & $cmd.Source --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>&1
        if (-not $out){ return $null }
        $vals = @()
        foreach ($line in ($out -split "`n")){
            $s = $line.Trim()
            if ($s -match '^\d+$'){ $vals += [int]$s }
        }
        if ($vals.Count -gt 0){ return ,$vals }
        return $null
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

    # Deadline: only block when clearly rendering or starting a job
    $dlStatus = Get-DeadlineSlaveStatus
    if ($dlStatus) {
        Log ("Deadline status={0}" -f $dlStatus)
        if ($dlStatus -match '(?i)render|starting|busy|initializ|processing'){
            Log "Deadline busy -> stay awake"
            return $false
        }
    } else {
        Log "Deadline status=unknown"
    }

    $isC4D = Test-C4DRunning
    Log ("C4D running={0}" -f $isC4D)
    if (-not $isC4D){
        Log "C4D not running -> OK to sleep"
        return $true
    }

    # C4D is running — sample GPU util% and CPU%
    $intervals = @() + $SampleIntervalsSecs
    while ($intervals.Count -lt $Samples){ $intervals += (Get-Random -Minimum 20 -Maximum 90) }

    $okCount = 0
    for ($i = 1; $i -le $Samples; $i++){
        $interval = [int]$intervals[$i - 1]
        $cpuPct   = Get-C4DCpuPercent -intervalSeconds $interval
        $gpuUtils = Get-GpuUtils
        $gpuTxt   = if ($gpuUtils) { $gpuUtils -join ',' } else { 'null' }
        Log ("Sample {0}/{1} (win={2}s): CPU={3}%  GPUs=[{4}]" -f $i, $Samples, $interval, ($cpuPct -as [string]), $gpuTxt)

        if ($null -eq $cpuPct -or $null -eq $gpuUtils){
            Log "  Null metric -> conservative: stay awake"
            continue
        }

        $anyGpuBusy = ($gpuUtils | Where-Object { $_ -ge $GpuIdleThresholdPct }).Count -gt 0
        if (-not $anyGpuBusy -and ($cpuPct -lt $CpuIdleThresholdPct)){
            $okCount++
            Log ("  -> idle (okCount={0}/{1})" -f $okCount, $Samples)
        } else {
            Log ("  -> active (gpuBusy={0}, cpuHigh={1})" -f $anyGpuBusy, ($cpuPct -ge $CpuIdleThresholdPct))
        }
    }

    if ($okCount -eq $Samples){
        Log "All $Samples samples idle -> OK to sleep"
        return $true
    } else {
        Log "Activity detected ($okCount/$Samples idle) -> stay awake"
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
