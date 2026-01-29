# C4D Smart Sleep 💤
Automatically puts your PC to sleep after being idle. **except when Cinema 4D is actually rendering**.

---

## What it does
- Monitors **user idle time**
- Detects if **Cinema 4D is running**
- Samples **CPU usage and all NVIDIA GPUs** via `nvidia-smi`
- (Optional safety) If **Deadline Worker is running and not idle**, the script will **never** sleep the machine
- If everything is idle → PC goes to sleep automatically  
- Runs invisibly every 5 minutes (no pop-ups)

Perfect if you render overnight but want your PC to rest when it’s done.

---

## Installation

1. **Open PowerShell as Administrator**
2. **Copy & paste:**
   ```powershell
   irm https://raw.githubusercontent.com/ercercercerc68/C4D-SmartSleep/main/install.ps1 | iex

This installs everything under C:\Scripts\, including:
- C4D-SmartSleep.ps1 (main logic)
- C4D-SmartSleep.vbs (runs hidden)
- C4D-SmartSleep.log (activity log)
- C4D-SmartSleep-Uninstall.ps1
A hidden scheduled task named “C4D Smart Sleep” will run every 5 minutes automatically.   

**Or:**

1. Clone or download this repository:
   - Click **Code → Download ZIP**, or  
   - Run `git clone https://github.com/ercercercerc68/C4D-SmartSleep.git`
   
2. Unzip (if downloaded as ZIP) and run:
   ```powershell
   PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"

Done. It will check every 5 minutes whether to sleep or not.



## Requirements: 
- Windows 10 or 11;
- NVIDIA GPU with drivers installed (so nvidia-smi works);
- PowerShell 5.1 or newer (included in Windows)

## Default behavior: 
Sleeps after 15 min idle, unless Cinema4D is open and busy (CPU+GPU activity sampled 3×).

If the **Deadline Worker** is running, the script also requires it to be **Idle** before it will sleep. If the worker is **not running** (or Deadline isn't installed), Deadline is ignored and the script behaves normally.
If the Worker is running but its status can’t be determined, it stays awake (conservative).

CPU sampling uses **per-sample intervals** by default (6s, 45s, 75s) to avoid accidental alignment with fixed-length renders.

## Logs: 
C:\Scripts\C4D-SmartSleep.log shows decisions and samples, e.g:

Sample 1: CPU=12%  GPUs=[77,76]
Activity detected -> stay awake

## Tuning: 
Edit the first few lines of C:\Scripts\C4D-SmartSleep.ps1 to adjust thresholds/intervals.

Tip: To avoid “perfect alignment” with fixed-length renders, the CPU sampling uses per-sample windows (defaults to 6s, 45s, 75s). You can change those in `$SampleIntervalsSecs`.

## Troubleshooting
- Turn off Fast Startup: powercfg /hibernate off
- Check blockers: powercfg /requests
- Log location: C:\Scripts\C4D-SmartSleep.log

## About
Created by Eric Smilde.
Inspired by the need to let your PC rest, but never mid-render.
Tested with dual RTX 3080 + Redshift.
