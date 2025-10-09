# C4D Smart Sleep 💤
Automatically puts your PC to sleep after being idle. **except when Cinema 4D is actually rendering**.

---

## What it does
- Monitors **user idle time**
- Detects if **Cinema 4D is running**
- Samples **CPU usage and all NVIDIA GPUs** via `nvidia-smi`
- If everything is idle → PC goes to sleep automatically  
- Runs invisibly every 5 minutes (no pop-ups)

Perfect if you render overnight but want your PC to rest when it’s done.

---

## Installation

1. **Open PowerShell as Administrator**
2. **Copy & paste:**
   ```powershell
   irm https://raw.githubusercontent.com/ercercercerc68/C4D-SmartSleep/main/install.ps1 | iex

**Or:**

1. Clone or download this repository:
   - Click **Code → Download ZIP**, or  
   - Run `git clone https://github.com/ercercercerc68/C4D-SmartSleep.git`
   
2. Unzip (if downloaded as ZIP) and run:
   ```powershell
   PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1"

Done. It will check every 5 minutes whether to sleep or not.



## Requirements: 
NVIDIA GPUs + drivers (so nvidia-smi exists), PowerShell 5.1 (default on Win10/11).

## Default behavior: 
Sleeps after 15 min idle, unless Cinema4D is open and busy (CPU+GPU activity sampled 3×).

## Logs: 
C:\Scripts\C4D-SmartSleep.log shows decisions and samples, e.g:

Sample 1: CPU=12%  GPUs=[77,76]
Activity detected -> stay awake

## Tuning: 
Edit the first few lines of C:\Scripts\C4D-SmartSleep.ps1 to adjust thresholds/intervals.

## Troubleshooting
- Turn off Fast Startup: powercfg /hibernate off
- Check blockers: powercfg /requests
- Log location: C:\Scripts\C4D-SmartSleep.log

## About
Created by Eric Smilde.
Inspired by the need to let your PC rest, but never mid-render.
Tested with dual RTX 3080 + Redshift.
