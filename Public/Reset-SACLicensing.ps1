function Reset-SACLicensing {
<#
.SYNOPSIS
    Wipes Autodesk licensing data to force a clean re-authentication.
.DESCRIPTION
    Clears the Autodesk CLM (Central Licensing Manager), AdskLicensing
    service data, per-user SSO token cache, and optionally Autodesk-specific
    FlexNet stubs. Restarts the AdskLicensing service after the wipe.

    This resolves common issues like:
      - "Autodesk keeps asking for activation"
      - "License not found" after account changes
      - Stuck multi-seat license reservations

.PARAMETER SkipServiceRestart
    Switch. Do not restart the AdskLicensing service after clearing data.

.PARAMETER IncludeFlexNet
    Switch. Also remove Autodesk-specific files (adsk*) from C:\ProgramData\FLEXnet\.
    Off by default since FLEXnet is a shared directory used by other software.

.PARAMETER Silent
    Switch. Bypasses the confirmation prompt for RMM/headless execution.

.EXAMPLE
    # Interactive: full licensing reset with service restart
    Reset-SACLicensing

.EXAMPLE
    # RMM: silent reset including FlexNet stubs
    Reset-SACLicensing -IncludeFlexNet -Silent
#>
    [CmdletBinding()]
    param (
        [switch]$SkipServiceRestart,
        [switch]$IncludeFlexNet,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()

    $ToDate    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskLicenseReset_$ToDate"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
    $DebugLog  = "$LogDir\LicenseResetDebug.log"
    $TranscriptLog = "$LogDir\LicenseResetTranscript.log"
    Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null

    function Write-Msg {
        param ([string]$Message, [ValidateSet("Info","Success","Warning","Error")][string]$Type = "Info")
        $ts  = "[$(Get-Date -Format 'HH:mm:ss')]"
        $clr = @{ Info="Cyan"; Success="Green"; Warning="Yellow"; Error="Red" }
        Write-Host "$ts $Message" -ForegroundColor $clr[$Type]
    }

    function Write-QuietLog {
        param ([string]$Message)
        Add-Content -Path $DebugLog -Value "[$(Get-Date -Format 'HH:mm:ss')] [DEBUG] $Message"
    }

    function Test-Interactive {
        return [Environment]::UserInteractive -and -not $Silent -and ($host.Name -eq "ConsoleHost" -or $host.Name -match "ISE|VS Code")
    }

    function Remove-TargetPath {
        param ([string]$Path, [string]$Label)
        if (Test-Path $Path) {
            try {
                Remove-Item $Path -Recurse -Force -ErrorAction Stop
                Write-Msg "Cleared: $Label" "Success"
                return "OK"
            } catch {
                Write-QuietLog "Failed to remove $Path : $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component=$Label; Reason=$_.Exception.Message }
                return "FAILED"
            }
        } else {
            Write-QuietLog "Not found (skipped): $Path"
            return "NOT FOUND"
        }
    }

    if (-not (Test-SACRemoteSession)) { Clear-Host }
    Write-Msg "==========================================" "Info"
    Write-Msg " SAC LICENSING RESET INITIALIZED"           "Info"
    Write-Msg " Debug Log:  $DebugLog"                    "Info"
    Write-Msg "==========================================" "Info"

    if (Test-Interactive) {
        Write-Msg "Checking for running Autodesk applications..." "Info"
        $Running = Get-Process | Where-Object { 
            try { ($_.Path -match "Autodesk") -or ($_.Description -match "Autodesk") -or ($_.Company -match "Autodesk") } catch { $false }
        }

        if ($Running) {
            Write-Host "`n[!] WARNING: The following Autodesk processes are still running:" -ForegroundColor Red
            $Running | Select-Object -Property Name, Description -Unique | ForEach-Object {
                Write-Host "    - $($_.Name) ($($_.Description))" -ForegroundColor Yellow
            }
            Write-Host "`nPlease close all Autodesk applications before resetting licensing.`n" -ForegroundColor Red
            Stop-Transcript | Out-Null
            return
        }

        Write-Host "`n[!] CRITICAL: This will wipe all Autodesk licensing tokens and force re-authentication." -ForegroundColor Yellow
        Write-Host "    Users will be logged out of all Autodesk products on this machine." -ForegroundColor Yellow
        if ($IncludeFlexNet) {
            Write-Host "    [!] FLEXNET STUBS WILL BE REMOVED." -ForegroundColor Red
        }
        Write-Host ""
        
        $resp = Read-Host "  Type 'LICENSING' to confirm"
        if ($resp -ne "LICENSING") {
            Write-Msg "Aborted by user." "Warning"
            Stop-Transcript | Out-Null
            return
        }
    } else {
        Write-Msg "Running in silent/non-interactive mode." "Info"
    }

    # --- Stop licensing service before wipe ---
    $LicService = Get-Service -Name "AdskLicensing" -ErrorAction SilentlyContinue
    if ($LicService -and $LicService.Status -eq "Running") {
        Write-Msg "Stopping AdskLicensing service..." "Info"
        try {
            Stop-Service -Name "AdskLicensing" -Force -ErrorAction Stop
            Write-Msg "AdskLicensing service stopped." "Success"
        } catch {
            Write-QuietLog "Failed to stop AdskLicensing: $($_.Exception.Message)"
            Write-Msg "Warning: Could not stop AdskLicensing service. Files may be locked." "Warning"
        }
    }

    # --- System-wide licensing paths ---
    $SystemTargets = @(
        @{ Path = "$($env:ProgramData)\Autodesk\CLM";            Label = "ProgramData CLM" },
        @{ Path = "$($env:ProgramData)\Autodesk\AdskLicensing";  Label = "ProgramData AdskLicensing" },
        @{ Path = "HKLM:\SOFTWARE\Autodesk\CLM";                 Label = "Registry HKLM CLM" },
        @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Autodesk\CLM";     Label = "Registry HKLM CLM (WOW64)" }
    )

    foreach ($target in $SystemTargets) {
        Remove-TargetPath -Path $target.Path -Label $target.Label | Out-Null
    }

    # --- Per-user licensing token paths ---
    $UserProfiles = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "^(Public|Default|Default User|All Users)$" }

    foreach ($profile in $UserProfiles) {
        $userName = $profile.Name

        $UserTargets = @(
            @{ Path = "$($profile.FullName)\AppData\Roaming\Autodesk\CLM";            Label = "[$userName] Roaming CLM cache" },
            @{ Path = "$($profile.FullName)\AppData\Local\Autodesk\Web Services";     Label = "[$userName] Local Web Services (SSO tokens)" },
            @{ Path = "$($profile.FullName)\AppData\Local\Autodesk\Autodesk Desktop App"; Label = "[$userName] Desktop App manager cache" }
        )

        foreach ($target in $UserTargets) {
            Remove-TargetPath -Path $target.Path -Label $target.Label | Out-Null
        }
    }

    # --- Optional: FlexNet Autodesk stubs ---
    if ($IncludeFlexNet) {
        Write-Msg "Scanning FLEXnet for Autodesk-specific stubs..." "Info"
        $FlexNetDir = "C:\ProgramData\FLEXnet"
        if (Test-Path $FlexNetDir) {
            $adskFiles = Get-ChildItem -Path $FlexNetDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match "^adsk" }
            foreach ($f in $adskFiles) {
                try {
                    Remove-Item $f.FullName -Force -ErrorAction Stop
                    Write-Msg "Removed FLEXnet stub: $($f.Name)" "Success"
                } catch {
                    Write-QuietLog "Failed to remove FLEXnet file $($f.FullName): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component="FLEXnet: $($f.Name)"; Reason=$_.Exception.Message }
                }
            }
            if ($adskFiles.Count -eq 0) {
                Write-Msg "No Autodesk FLEXnet stubs found." "Info"
            }
        } else {
            Write-Msg "FLEXnet directory not found - skipping." "Info"
        }
    }

    # --- Restart licensing service ---
    if (-not $SkipServiceRestart) {
        $LicService = Get-Service -Name "AdskLicensing" -ErrorAction SilentlyContinue
        if ($LicService) {
            Write-Msg "Restarting AdskLicensing service..." "Info"
            try {
                Start-Service -Name "AdskLicensing" -ErrorAction Stop
                Write-Msg "AdskLicensing service restarted successfully." "Success"
            } catch {
                Write-QuietLog "Failed to restart AdskLicensing: $($_.Exception.Message)"
                Write-Msg "AdskLicensing could not be restarted. You may need to reboot." "Warning"
            }
        } else {
            Write-Msg "AdskLicensing service not present on this machine - skipping restart." "Info"
        }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed

    Write-Msg "==========================================" "Info"
    Write-Msg " LICENSING RESET COMPLETED in $ElapsedTime" "Success"
    Write-Msg "==========================================" "Info"

    if ($script:SACFailures.Count -gt 0) {
        Write-Host "`n[!] FAILURES DETECTED:" -ForegroundColor Red
        Write-Host "    (Note: These items may have been forcibly evicted/removed despite errors)" -ForegroundColor Gray
        foreach ($fail in $script:SACFailures) {
            Write-Host "   - $($fail.Component)" -ForegroundColor Yellow
            Write-Host "     Reason: $($fail.Reason)" -ForegroundColor DarkGray
        }
        Write-Host "`nPlease review the Debug Log: $DebugLog`n" -ForegroundColor Red
    } else {
        Write-Host "`n[*] All operations completed successfully.`n" -ForegroundColor Green
    }

    # Persist outcome so the interactive menu can show a status badge on return
    $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
    if ($script:SACFailures.Count -gt 0) {
        $content = @(
            "AUTODESK LICENSING RESET - ITEMS REQUIRING ATTENTION",
            "Timestamp: $(Get-Date)",
            "Log Directory: $LogDir",
            "Note: Despite the errors below, these components may have been forcibly",
            "evicted or surgically removed from the system by the SAC engine.",
            "----------------------------------------------------------",
            ""
        )
        foreach ($fail in $script:SACFailures) {
            $content += "[!] $($fail.Component)"
            $content += "    Reason: $($fail.Reason)"
            $content += ""
        }
        $content | Out-File -FilePath $AttentionFile -Encoding utf8
    }

    $script:SACLastRunStatus = [PSCustomObject]@{
        Operation      = 'Licensing Reset'
        Criticals      = $script:SACFailures.Count
        Warnings       = 0
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($script:SACFailures.Count -gt 0) { $AttentionFile } else { $null }
    }

    Stop-Transcript | Out-Null
}
