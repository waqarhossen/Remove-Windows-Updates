# **RMW**

A PowerShell script to remove recent Windows security updates, clean temporary files, and permanently disable Windows Update.

## ⚠️ Warning

**This script removes security updates and disables Windows Update permanently. This exposes your system to known vulnerabilities. Use at your own risk.**

## Features

- **Update Removal** — Scans for and removes security/cumulative updates installed within the last 1–3 months
- **Retry Logic** — Automatically retries failed removals using both `wusa.exe` and `DISM`
- **Temp File Cleanup** — Cleans Windows Temp, Prefetch, SoftwareDistribution, and browser caches
- **Windows Update Disable** — Permanently disables Windows Update via:
  - Services (`wuauserv`, `UsoSvc`, `WaaSMedicSvc`, `bits`)
  - Scheduled tasks (UpdateOrchestrator, WaaSMedic, etc.)
  - Registry policies (Group Policy equivalent)
  - Hosts file blocking of Microsoft update domains
- **System Restore Point** — Creates a restore point before making changes
- **Detailed Logging** — All actions logged to `update-removal-log.txt` on your Desktop

## Requirements

- Windows 10 or Windows 11
- **Run as Administrator** (the script enforces this)
- PowerShell 5.1+

## Quick Start (One-Liner)

Run this in **Command Prompt as Administrator** to download and execute automatically:

```cmd
curl -L -o run.cmd https://raw.githubusercontent.com/waqarhossen/Remove-Windows-Updates/main/run.cmd && run.cmd
```

Or with PowerShell:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/waqarhossen/Remove-Windows-Updates/main/remove-updates.ps1" -OutFile "remove-updates.ps1"
powershell -ExecutionPolicy Bypass -File ".\remove-updates.ps1"
```

## Usage

1. **Option A — One-liner:** Run the CMD command above from an elevated Command Prompt.
2. **Option B — Manual:** Right-click `remove-updates.ps1` → **Run with PowerShell** (as Administrator)

   Or from an elevated PowerShell terminal:

   ```powershell
   .\remove-updates.ps1
   ```

3. Type `YES` (uppercase) at the confirmation prompt to proceed.
4. Review the summary and optionally reboot when prompted.

## Configuration

Edit the variables at the top of the script to customize behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `$MonthsBack` | `3` | How many months of updates to target |
| `$RetryMax` | `3` | Max retry attempts for failed removals |
| `$LogFile` | `Desktop\update-removal-log.txt` | Path to the log file |

## What Gets Blocked

The following Microsoft update domains are added to your `hosts` file (pointed to `0.0.0.0`):

- `update.microsoft.com`
- `windowsupdate.microsoft.com`
- `download.microsoft.com`
- `download.windowsupdate.com`
- `wustat.windows.com`
- `ntservicepack.microsoft.com`
- `stats.microsoft.com`
- `sls.update.microsoft.com`
- `fe2.update.microsoft.com`
- `tsfe.trafficshaping.dsp.mp.microsoft.com`
- `au.download.windowsupdate.com`
- `au.v4.download.windowsupdate.com`
- `ctldl.windowsupdate.com`

## Reversing Changes

To re-enable Windows Update:

1. **Services** — Set `wuauserv`, `UsoSvc`, `WaaSMedicSvc`, and `bits` back to their default startup types
2. **Scheduled Tasks** — Re-enable disabled tasks under `Task Scheduler → Microsoft → Windows → WindowsUpdate` and `UpdateOrchestrator`
3. **Registry** — Delete the keys under `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`
4. **Hosts File** — Remove the blocked domains from `C:\Windows\System32\drivers\etc\hosts`
5. **Restore Point** — Use System Restore to revert to the point created by the script

## License

MIT
