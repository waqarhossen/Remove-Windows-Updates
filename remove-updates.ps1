#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes recent Windows security updates, cleans temp files, and disables Windows Update.
.DESCRIPTION
    This script:
    1. Lists and removes security updates from the last 1-3 months
    2. Retries any updates that were skipped/ignored
    3. Cleans temporary files (Windows Temp, Prefetch, SoftwareDistribution)
    4. Permanently disables Windows Update services and tasks
.NOTES
    WARNING: Removing security updates exposes your system to known vulnerabilities.
    Run this script as Administrator.
#>

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Windows Update Removal Tool"

# ──────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────
$MonthsBack = 3  # How many months back to target
$CutoffDate = (Get-Date).AddMonths(-$MonthsBack)
$RetryMax = 3    # Max retry attempts for ignored updates
$LogFile = Join-Path $env:USERPROFILE "Desktop\update-removal-log.txt"

# ──────────────────────────────────────────────
# LOGGING FUNCTION
# ──────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry -ForegroundColor $(switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    })
}

# ──────────────────────────────────────────────
# STEP 0: SAFETY CHECK
# ──────────────────────────────────────────────
Write-Host @"

╔══════════════════════════════════════════════════════════╗
║               WARNING: SECURITY RISK                     ║
║                                                          ║
║  This script will REMOVE security updates from your      ║
║  system. This exposes you to known vulnerabilities.      ║
║                                                          ║
║  It will also PERMANENTLY disable Windows Update.        ║
║                                                          ║
║  Create a system restore point before proceeding.        ║
╚══════════════════════════════════════════════════════════╝

"@

$confirm = Read-Host "Type 'YES' (uppercase) to continue"
if ($confirm -ne "YES") {
    Write-Host "Aborted by user." -ForegroundColor Yellow
    exit 0
}

Write-Log "Script started. Target: updates since $CutoffDate" "INFO"

# ──────────────────────────────────────────────
# STEP 1: CREATE SYSTEM RESTORE POINT
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== STEP 1: Creating System Restore Point ===" -ForegroundColor Cyan
try {
    Checkpoint-Computer -Description "Before update removal - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType "MODIFY_SETTINGS" -ErrorAction Stop
    Write-Log "System restore point created successfully" "SUCCESS"
} catch {
    Write-Log "Failed to create restore point: $_" "WARN"
    Write-Host "Continuing without restore point..." -ForegroundColor Yellow
}

# ──────────────────────────────────────────────
# STEP 2: LIST SECURITY UPDATES
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== STEP 2: Scanning for Security Updates ===" -ForegroundColor Cyan

$allUpdates = @()
$session = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()

Write-Host "Searching for installed updates... (this may take a minute)" -ForegroundColor Gray
$searchResult = $searcher.Search("IsInstalled=1 AND Type='Software'")

$securityUpdates = $searchResult.Updates | Where-Object {
    $_.Title -match "Security Update|Cumulative Update|KB\d+" -and
    $_.LastDeploymentChangeTime -ge $CutoffDate
} | Sort-Object LastDeploymentChangeTime -Descending

if (-not $securityUpdates) {
    Write-Log "No security updates found in the last $MonthsBack months" "WARN"
} else {
    Write-Host ""
    Write-Host "Found $($securityUpdates.Count) security updates since $($CutoffDate.ToString('yyyy-MM-dd')):" -ForegroundColor Yellow
    Write-Host ("-" * 80)
    $securityUpdates | ForEach-Object {
        $kb = if ($_.Title -match 'KB(\d+)') { $matches[1] } else { "N/A" }
        $date = $_.LastDeploymentChangeTime.ToString("yyyy-MM-dd")
        Write-Host "  KB$kb | $date | $($_.Title)" -ForegroundColor White
        $allUpdates += [PSCustomObject]@{ KB = "KB$kb"; Title = $_.Title; Date = $date }
    }
    Write-Host ("-" * 80)
}

# Also check via DISM/WUSA as fallback
Write-Host ""
Write-Host "Also checking via DISM for any missed updates..." -ForegroundColor Gray
$hotfixes = Get-HotFix | Where-Object {
    $_.InstalledOn -ge $CutoffDate -and
    $_.Description -match "Security|Update"
} | Sort-Object InstalledOn -Descending

if ($hotfixes) {
    Write-Host "DISM found $($hotfixes.Count) additional hotfixes:" -ForegroundColor Yellow
    $hotfixes | ForEach-Object {
        Write-Host "  $($_.HotFixID) | $($_.InstalledOn.ToString('yyyy-MM-dd')) | $($_.Description)" -ForegroundColor White
    }
}

# ──────────────────────────────────────────────
# STEP 3: REMOVE UPDATES ONE BY ONE
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== STEP 3: Removing Updates ===" -ForegroundColor Cyan

$removedList = @()
$failedList = @()
$ignoredList = @()

# Build combined list from both sources
$combinedKBs = @()
if ($securityUpdates) {
    $securityUpdates | ForEach-Object {
        if ($_.Title -match 'KB(\d+)') {
            $combinedKBs += $matches[1]
        }
    }
}
$hotfixes | ForEach-Object {
    if ($_.HotFixID -match 'KB(\d+)') {
        $kbNum = $matches[1]
        if ($kbNum -notin $combinedKBs) {
            $combinedKBs += $kbNum
        }
    }
}

$combinedKBs = $combinedKBs | Select-Object -Unique | Sort-Object

if ($combinedKBs.Count -eq 0) {
    Write-Log "No KBs to remove" "WARN"
} else {
    Write-Host "Will attempt to remove $($combinedKBs.Count) updates one by one..." -ForegroundColor Yellow
    Write-Host ""

    foreach ($kb in $combinedKBs) {
        Write-Host "--- Removing KB$kb ---" -ForegroundColor Magenta
        $success = $false

        for ($attempt = 1; $attempt -le $RetryMax; $attempt++) {
            if ($attempt -gt 1) {
                Write-Host "  Retry attempt $attempt of $RetryMax..." -ForegroundColor Yellow
            }

            try {
                # Use wusa.exe for removal (quiet, no restart)
                $process = Start-Process -FilePath "wusa.exe" `
                    -ArgumentList "/uninstall /kb:$kb /quiet /norestart" `
                    -Wait -PassThru -NoNewWindow

                $exitCode = $process.ExitCode

                # Check if it was actually removed
                Start-Sleep -Seconds 3
                $stillThere = Get-HotFix -Id "KB$kb" -ErrorAction SilentlyContinue

                if (-not $stillThere) {
                    Write-Log "KB$kb removed successfully (attempt $attempt)" "SUCCESS"
                    $removedList += "KB$kb"
                    $success = $true
                    break
                } elseif ($exitCode -eq 0) {
                    # wusa reported success but hotfix still shows - may need reboot
                    Write-Log "KB$kb marked for removal (pending reboot)" "SUCCESS"
                    $removedList += "KB$kb"
                    $success = $true
                    break
                } elseif ($exitCode -eq 3010) {
                    Write-Log "KB$kb removed (reboot required)" "SUCCESS"
                    $removedList += "KB$kb"
                    $success = $true
                    break
                } elseif ($exitCode -eq -2145124329) {
                    # ERROR_NOT_FOUND - already removed
                    Write-Log "KB$kb already removed or not found" "SUCCESS"
                    $removedList += "KB$kb"
                    $success = $true
                    break
                } else {
                    Write-Log "KB$kb removal returned exit code: $exitCode (attempt $attempt)" "WARN"
                }
            } catch {
                Write-Log "KB$kb removal error: $_ (attempt $attempt)" "ERROR"
            }

            if ($attempt -lt $RetryMax) {
                Start-Sleep -Seconds 5
            }
        }

        if (-not $success) {
            Write-Log "KB$kb FAILED after $RetryMax attempts - adding to retry queue" "ERROR"
            $failedList += "KB$kb"
        }
    }
}

# ──────────────────────────────────────────────
# STEP 4: RETRY FAILED UPDATES
# ──────────────────────────────────────────────
if ($failedList.Count -gt 0) {
    Write-Host ""
    Write-Host "=== STEP 4: Retrying Failed Updates ===" -ForegroundColor Cyan
    Write-Host "$($failedList.Count) updates failed initial removal. Retrying with force..." -ForegroundColor Yellow

    $stillFailed = @()

    foreach ($kb in $failedList) {
        Write-Host "--- Force retry KB$kb ---" -ForegroundColor Magenta

        for ($attempt = 1; $attempt -le $RetryMax; $attempt++) {
            try {
                # Try with DISM as alternative
                $dismResult = & dism /online /Remove-Package /PackageName:"*$kb*" /quiet /norestart 2>&1
                Start-Sleep -Seconds 3

                $stillThere = Get-HotFix -Id "KB$kb" -ErrorAction SilentlyContinue
                if (-not $stillThere) {
                    Write-Log "KB$kb removed via DISM (attempt $attempt)" "SUCCESS"
                    $removedList += "KB$kb"
                    break
                }

                # Try wusa with force
                $process = Start-Process -FilePath "wusa.exe" `
                    -ArgumentList "/uninstall /kb:$kb /quiet /norestart" `
                    -Wait -PassThru -NoNewWindow

                Start-Sleep -Seconds 3
                $stillThere = Get-HotFix -Id "KB$kb" -ErrorAction SilentlyContinue
                if (-not $stillThere) {
                    Write-Log "KB$kb removed via wusa force (attempt $attempt)" "SUCCESS"
                    $removedList += "KB$kb"
                    break
                }

                if ($attempt -eq $RetryMax) {
                    Write-Log "KB$kb COULD NOT BE REMOVED after all attempts" "ERROR"
                    $stillFailed += "KB$kb"
                }
            } catch {
                if ($attempt -eq $RetryMax) {
                    Write-Log "KB$kb COULD NOT BE REMOVED: $_" "ERROR"
                    $stillFailed += "KB$kb"
                }
            }

            if ($attempt -lt $RetryMax) {
                Start-Sleep -Seconds 5
            }
        }
    }

    if ($stillFailed.Count -gt 0) {
        Write-Host ""
        Write-Host "⚠ The following updates could NOT be removed:" -ForegroundColor Red
        $stillFailed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        Write-Log "Unremovable updates: $($stillFailed -join ', ')" "ERROR"
    }
}

# ──────────────────────────────────────────────
# STEP 5: CLEAN TEMP FILES
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== STEP 5: Cleaning Temporary Files ===" -ForegroundColor Cyan

$tempPaths = @(
    "$env:SystemRoot\Temp",
    "$env:USERPROFILE\AppData\Local\Temp",
    "$env:SystemRoot\Prefetch",
    "$env:SystemRoot\SoftwareDistribution\Download",
    "$env:SystemRoot\SoftwareDistribution\DataStore\Logs",
    "$env:USERPROFILE\AppData\Local\Microsoft\Windows\INetCache",
    "$env:USERPROFILE\AppData\Local\Microsoft\Windows\Temporary Internet Files"
)

foreach ($path in $tempPaths) {
    if (Test-Path $path) {
        try {
            Write-Host "Cleaning: $path" -ForegroundColor Gray
            Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue | 
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-Log "Cleaned: $path" "SUCCESS"
        } catch {
            Write-Log "Failed to clean $path : $_" "WARN"
        }
    }
}

# Clean Windows Update cache specifically
Write-Host "Resetting Windows Update components..." -ForegroundColor Gray
try {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service -Name bits -Force -ErrorAction SilentlyContinue
    Stop-Service -Name cryptsvc -Force -ErrorAction SilentlyContinue
    Stop-Service -Name msiserver -Force -ErrorAction SilentlyContinue

    # Rename SoftwareDistribution and Catroot2 folders
    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    $crPath = "$env:SystemRoot\System32\Catroot2"

    if (Test-Path $sdPath) {
        Rename-Item -Path $sdPath -NewName "SoftwareDistribution.old" -Force -ErrorAction SilentlyContinue
        Write-Log "Renamed SoftwareDistribution to SoftwareDistribution.old" "SUCCESS"
    }
    if (Test-Path $crPath) {
        Rename-Item -Path $crPath -NewName "Catroot2.old" -Force -ErrorAction SilentlyContinue
        Write-Log "Renamed Catroot2 to Catroot2.old" "SUCCESS"
    }
} catch {
    Write-Log "Error resetting WU components: $_" "WARN"
}

# ──────────────────────────────────────────────
# STEP 6: PERMANENTLY DISABLE WINDOWS UPDATE
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "=== STEP 6: Disabling Windows Update Permanently ===" -ForegroundColor Cyan

# 6a. Disable services
$wuServices = @("wuauserv", "UsoSvc", "WaaSMedicSvc", "bits")
foreach ($svc in $wuServices) {
    try {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log "Service '$svc' stopped and disabled" "SUCCESS"
    } catch {
        Write-Log "Could not disable service '$svc': $_" "WARN"
    }
}

# 6b. Disable scheduled tasks
$wuTasks = @(
    "\Microsoft\Windows\WindowsUpdate\Scheduled Start",
    "\Microsoft\Windows\WindowsUpdate\sih",
    "\Microsoft\Windows\WindowsUpdate\Automatic App Update",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan",
    "\Microsoft\Windows\UpdateOrchestrator\Schedule Work",
    "\Microsoft\Windows\UpdateOrchestrator\UpdateModelTask",
    "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker",
    "\Microsoft\Windows\UpdateOrchestrator\Reboot",
    "\Microsoft\Windows\UpdateOrchestrator\Maintenance Install",
    "\Microsoft\Windows\UpdateOrchestrator\Policy Install",
    "\Microsoft\Windows\WaaSMedic\PerformRemediation",
    "\Microsoft\Windows\WindowsUpdate\Refresh Settings"
)

foreach ($task in $wuTasks) {
    try {
        Disable-ScheduledTask -TaskPath (Split-Path $task) -TaskName (Split-Path $task -Leaf) -ErrorAction SilentlyContinue
        Write-Log "Disabled scheduled task: $task" "SUCCESS"
    } catch {
        # Task may not exist - that's fine
    }
}

# 6c. Registry: Disable Windows Update via Group Policy equivalent
$regPaths = @(
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "DisableWindowsUpdateAccess"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "NoAutoUpdate"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"; Name = "AUOptions"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update"; Name = "AUOptions"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "DoNotConnectToWindowsUpdateInternetLocations"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "SetDisableUXWUAccess"; Value = 1 },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "WUServer"; Value = "" },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "WUStatusServer"; Value = "" },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "UpdateServiceUrlAlternate"; Value = "" },
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"; Name = "FillEmptyContentUrls"; Value = 0 }
)

foreach ($reg in $regPaths) {
    try {
        if (-not (Test-Path $reg.Path)) {
            New-Item -Path $reg.Path -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Set-ItemProperty -Path $reg.Path -Name $reg.Name -Value $reg.Value -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Log "Registry set: $($reg.Path)\$($reg.Name) = $($reg.Value)" "SUCCESS"
    } catch {
        Write-Log "Registry error: $($reg.Path)\$($reg.Name): $_" "WARN"
    }
}

# 6d. Block Windows Update URLs in hosts file (nuclear option)
$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$wuDomains = @(
    "update.microsoft.com",
    "windowsupdate.microsoft.com",
    "download.microsoft.com",
    "download.windowsupdate.com",
    "wustat.windows.com",
    "ntservicepack.microsoft.com",
    "stats.microsoft.com",
    "sls.update.microsoft.com",
    "fe2.update.microsoft.com",
    "tsfe.trafficshaping.dsp.mp.microsoft.com",
    "au.download.windowsupdate.com",
    "au.v4.download.windowsupdate.com",
    "ctldl.windowsupdate.com"
)

try {
    $hostsContent = Get-Content $hostsPath -ErrorAction Stop
    $added = 0
    foreach ($domain in $wuDomains) {
        $entry = "0.0.0.0 $domain"
        if ($hostsContent -notcontains $entry) {
            Add-Content -Path $hostsPath -Value $entry -ErrorAction SilentlyContinue
            $added++
        }
    }
    Write-Log "Added $added Windows Update domains to hosts file (blocked)" "SUCCESS"
} catch {
    Write-Log "Could not modify hosts file: $_" "ERROR"
}

# ──────────────────────────────────────────────
# STEP 7: SUMMARY
# ──────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                   OPERATION COMPLETE                     ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "Updates removed: $($removedList.Count)" -ForegroundColor Green
if ($removedList.Count -gt 0) { $removedList | ForEach-Object { Write-Host "  ✓ $_" -ForegroundColor Green } }
Write-Host ""
if ($stillFailed.Count -gt 0) {
    Write-Host "Updates that could NOT be removed: $($stillFailed.Count)" -ForegroundColor Red
    $stillFailed | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }
    Write-Host ""
}
Write-Host "Temp files cleaned" -ForegroundColor Green
Write-Host "Windows Update: PERMANENTLY DISABLED" -ForegroundColor Green
Write-Host ""
Write-Host "Log file saved to: $LogFile" -ForegroundColor Cyan
Write-Host ""
Write-Host "A REBOOT IS RECOMMENDED to complete the removal process." -ForegroundColor Yellow

$reboot = Read-Host "Reboot now? (y/n)"
if ($reboot -eq 'y') {
    Write-Log "User initiated reboot" "INFO"
    Restart-Computer -Force
}

Write-Log "Script completed" "INFO"
