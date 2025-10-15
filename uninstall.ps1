# C4D Smart Sleep - Uninstaller
$TaskName = "C4D Smart Sleep"

try { schtasks /Delete /TN "$TaskName" /F | Out-Null } catch {}
try { schtasks /Delete /TN "Restore-WindowsUpdate" /F | Out-Null } catch {}

Write-Host "Scheduled tasks removed."
Write-Host "Leaving files in C:\Scripts (log + scripts). Delete manually if you wish."
