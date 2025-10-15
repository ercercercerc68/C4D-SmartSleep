# ==============================
# C4D Smart Sleep - Installer (v3.1)
# Installs the SmartSleep scripts and creates a hidden elevated scheduled task
# Requirements: Windows PowerShell 5.1+, NVIDIA driver (for nvidia-smi)
# ==============================

# --- Ensure admin privileges ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$ErrorActionPreference = 'Stop'
$TargetDir = 'C:\Scripts'
$PsPath    = Join-Path $TargetDir 'C4D-SmartSleep.ps1'
$VbsPath   = Join-Path $TargetDir 'C4D-SmartSleep.vbs'
$Uninst    = Join-Path $TargetDir 'C4D-SmartSleep-Uninstall.ps1'
$TaskName  = 'C4D Smart Sleep'
$User      = $env:USERNAME

# --- Create target folder ---
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

# --- Copy latest PowerShell script from repo ---
if (Test-Path ".\C4D-SmartSleep.ps1") {
    Copy-Item ".\C4D-SmartSleep.ps1" -Destination $PsPath -Force
} else {
    Write-Host "❌ C4D-SmartSleep.ps1 not found in current directory." -ForegroundColor Red
    exit 1
}

# --- Hidden VBS launcher ---
$vbsContent = @'
Set sh = CreateObject("Wscript.Shell")
sh.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\Scripts\C4D-SmartSleep.ps1""", 0, False
'@
Set-Content -Path $VbsPath -Value $vbsContent -Encoding ASCII

# --- Uninstaller with cleanup of Windows Update restore task ---
$unContent = @'
# C4D Smart Sleep - Uninstaller
$TaskName = "C4D Smart Sleep"
try { schtasks /Delete /TN "$TaskName" /F | Out-Null } catch {}
try { schtasks /Delete /TN "Restore-WindowsUpdate" /F | Out-Null } catch {}
Write-Host "Scheduled tasks removed."
Write-Host "Leaving files in C:\Scripts (log + scripts). Delete manually if you wish."
'@
Set-Content -Path $Uninst -Value $unContent -Encoding UTF8

# --- (Re)create scheduled task ---
try { schtasks /Delete /TN "$TaskName" /F | Out-Null } catch {}

schtasks /Create `
    /TN "$TaskName" `
    /TR "wscript.exe ""$VbsPath""" `
    /SC MINUTE /MO 5 `
    /RU "$User" `
    /RL HIGHEST `
    /F | Out-Null

# --- Kick it once immediately ---
schtasks /Run /TN "$TaskName" | Out-Null

# --- Done ---
Write-Host "✅ Installed C4D Smart Sleep (v3.1)"
Write-Host "   Folder:  $TargetDir"
Write-Host "   Task:    $TaskName (every 5 min, hidden, elevated)"
Write-Host "   Log:     C:\Scripts\C4D-SmartSleep.log"
Write-Host ""
Write-Host "To uninstall later:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Uninst`""
