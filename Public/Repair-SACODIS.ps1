function Repair-SACODIS {
<#
.SYNOPSIS
    Uninstalls, cleans directory states, and reinstalls the Autodesk On-Demand Install Service (ODIS).
.DESCRIPTION
    Resolves common ODIS installation failures (e.g., "Unable to install - An error occurred
    while preparing the installation") by performing a structured repair:
      1. Kills active ODIS-related processes.
      2. Runs the native uninstaller (RemoveODIS.exe) if present.
      3. Stops and deletes the AdODISService.
      4. Renames existing ODIS folders to preserve installer logs while preventing state reuse.
      5. Downloads the latest AdODIS-installer.exe from Autodesk's servers.
      6. Performs a silent reinstallation of the AdODIS service.
.PARAMETER Silent
    Switch. Bypasses the confirmation prompt for headless/scripted execution.
.EXAMPLE
    Repair-SACODIS
.EXAMPLE
    Repair-SACODIS -Silent
#>
    [CmdletBinding()]
    param (
        [switch]$Silent
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Error "Repair-SACODIS must be run in an elevated Administrator session."
        return
    }

    if (-not $Silent) {
        Write-Host "`n==========================================================" -ForegroundColor Cyan
        Write-Host "             AUTODESK ODIS INSTALLER REPAIR" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "This utility will perform the following actions:" -ForegroundColor Yellow
        Write-Host "  1. Terminate all active ODIS processes." -ForegroundColor Gray
        Write-Host "  2. Run the native ODIS uninstaller (if present)." -ForegroundColor Gray
        Write-Host "  3. Stop and delete the AdODISService." -ForegroundColor Gray
        Write-Host "  4. Rename old ODIS data and log paths to prevent reuse." -ForegroundColor Gray
        Write-Host "  5. Download the latest AdODIS-installer.exe from Autodesk." -ForegroundColor Gray
        Write-Host "  6. Perform a fresh, silent reinstall of ODIS." -ForegroundColor Gray
        Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
        $Confirm = Read-Host "Proceed with ODIS installer repair? (y/N)"
        if ($Confirm -notmatch '^[yY](es)?$') {
            Write-Host "`nODIS repair cancelled by user." -ForegroundColor Yellow
            return
        }
    }

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()

    # --- Setup Logging ---
    $ToDate = Get-Date -Format 'yyyyMMdd_HHmmss'
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskODISRepair_$ToDate"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

    $TranscriptLog = Join-Path $LogDir "ODISRepairTranscript.log"
    Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null

    Write-SACMsg "Beginning Autodesk ODIS Repair Flow..." "Info"
    Write-SACMsg "Log directory initialized at: $LogDir" "Info"

    # 1. Kill active ODIS and Autodesk licensing processes; stop services that cause installer hangs
    $ProcessesToKill = @("AdODIS", "AdODISService", "AdODISInstaller", "AdskLicensing*", "AdskSSO*", "AdskAccess*")
    Write-SACMsg "Terminating ODIS and Autodesk licensing processes..." "Info"
    foreach ($proc in $ProcessesToKill) {
        Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    foreach ($svcName in @("AdODISService", "AdskAccessService", "AdskLicensing")) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne "Stopped") {
            Write-SACMsg "  Stopping service: $svcName" "Info"
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        }
    }

    # 2. Run native ODIS uninstaller if present
    $RemovePath = Join-Path $env:ProgramFiles "Autodesk\AdODIS\V1\RemoveODIS.exe"
    if (Test-Path $RemovePath) {
        Write-SACMsg "Executing native ODIS uninstaller: $RemovePath" "Info"
        try {
            $proc = Start-Process -FilePath $RemovePath -ArgumentList "--mode unattended" -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
            if ($proc.ExitCode -eq 0) {
                Write-SACMsg "  [OK] Native uninstaller finished successfully." "Success"
            } else {
                Write-SACMsg "  [!] Native uninstaller finished with exit code $($proc.ExitCode)." "Warning"
            }
        } catch {
            Write-SACMsg "  [!] Failed to run native uninstaller: $($_.Exception.Message)" "Warning"
        }
    } else {
        Write-SACMsg "Native ODIS uninstaller (RemoveODIS.exe) not found. Skipping." "Info"
    }

    # 3. Stop and delete AdODISService
    $service = Get-Service -Name "AdODISService" -ErrorAction SilentlyContinue
    if ($service) {
        Write-SACMsg "Stopping and deleting AdODISService..." "Info"
        Stop-Service -Name "AdODISService" -Force -ErrorAction SilentlyContinue
        Start-Process sc.exe -ArgumentList "delete AdODISService" -Wait -NoNewWindow | Out-Null
    }

    # 4. Clean up / Rename old ODIS paths
    $PathsToRename = @(
        Join-Path $env:ProgramFiles "Autodesk\AdODIS",
        Join-Path $env:ProgramData "Autodesk\ODIS"
    )

    # Gather user profiles AppData Local paths
    $UserProfilesBase = "C:\Users"
    if (Test-Path $UserProfilesBase) {
        Get-ChildItem -LiteralPath $UserProfilesBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $profileName = $_.Name
            if ($profileName -notmatch '^(Public|Default|Default User|All Users)$') {
                $PathsToRename += Join-Path $_.FullName "AppData\Local\Autodesk\ODIS"
                $PathsToRename += Join-Path $_.FullName "AppData\Local\Autodesk\AdODIS"
            }
        }
    }

    # Pre-delete the run lock file if present
    $LockFile = Join-Path $env:ProgramData "Autodesk\ODIS\AdODISInstaller.run.lock"
    if (Test-Path $LockFile) {
        Write-SACMsg "Removing ODIS installation lock file: $LockFile" "Info"
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }

    foreach ($path in $PathsToRename) {
        if (Test-Path -LiteralPath $path) {
            $bakPath = "${path}_bak_$ToDate"
            Write-SACMsg "Renaming directory: $path -> $(Split-Path $bakPath -Leaf)" "Info"
            try {
                Rename-Item -LiteralPath $path -NewName (Split-Path $bakPath -Leaf) -Force -ErrorAction Stop
                Write-SACMsg "  [OK] Renamed successfully." "Success"
            } catch {
                Write-SACMsg "  [!] Rename failed: $($_.Exception.Message). Attempting force deletion..." "Warning"
                try {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                    Write-SACMsg "  [OK] Force deleted successfully." "Success"
                } catch {
                    Write-SACMsg "  [FAIL] Failed to delete ${path}: $($_.Exception.Message)" "Warning"
                    $script:SACFailures += [PSCustomObject]@{
                        Component = "ODIS Path ($path)"
                        Reason    = "Locked/In-Use"
                    }
                }
            }
        }
    }

    # 5. Download the latest AdODIS installer
    $InstallerUrl = "https://emsfs.autodesk.com/utility/odis/1/installer/latest/AdODIS-installer.exe"
    $LocalInstallerPath = Join-Path $env:TEMP "AdODIS-installer.exe"

    # Pre-clean local installer file if it somehow exists
    if (Test-Path $LocalInstallerPath) {
        Remove-Item -LiteralPath $LocalInstallerPath -Force -ErrorAction SilentlyContinue
    }

    Write-SACMsg "Downloading latest ODIS installer from Autodesk..." "Info"
    Write-SACMsg "  URL: $InstallerUrl" "Info"
    
    $downloadSuccess = $false
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $LocalInstallerPath -UseBasicParsing -ErrorAction Stop
        $downloadSuccess = $true
        Write-SACMsg "  [OK] Download completed successfully." "Success"
    } catch {
        Write-SACMsg "  [!] Invoke-WebRequest failed: $($_.Exception.Message). Trying WebClient fallback..." "Warning"
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($InstallerUrl, $LocalInstallerPath)
            $downloadSuccess = $true
            Write-SACMsg "  [OK] WebClient download completed successfully." "Success"
        } catch {
            Write-SACMsg "  [FAIL] Download fallback failed: $($_.Exception.Message)" "Error"
            $script:SACFailures += [PSCustomObject]@{
                Component = "ODIS Download"
                Reason    = $_.Exception.Message
            }
        }
    }

    # 6. Perform a fresh, silent reinstall of ODIS
    if ($downloadSuccess -and (Test-Path $LocalInstallerPath)) {
        # Stop AdskAccessService before launching the installer. The ODIS installer restarts this
        # service internally; if it is already in a bad/pending state the installer will hang
        # waiting for the service to reach Running status.
        $accessSvc = Get-Service -Name "AdskAccessService" -ErrorAction SilentlyContinue
        if ($accessSvc -and $accessSvc.Status -ne "Stopped") {
            Write-SACMsg "  Stopping AdskAccessService before installation..." "Info"
            Stop-Service -Name "AdskAccessService" -Force -ErrorAction SilentlyContinue
        }

        Write-SACMsg "Running fresh ODIS installation silently..." "Info"
        try {
            $proc = Start-Process -FilePath $LocalInstallerPath -ArgumentList "--mode unattended" -PassThru -NoNewWindow -ErrorAction Stop
            Watch-SACProcessTree -RootProcess $proc -DisplayName "ODIS Installer" -TimeoutMinutes 15 -IdleTimeoutMinutes 5
            if ($proc.ExitCode -eq 0) {
                Write-SACMsg "  [OK] Reinstallation completed successfully." "Success"
            } else {
                Write-SACMsg "  [FAIL] Reinstallation failed with exit code $($proc.ExitCode)." "Error"
                $script:SACFailures += [PSCustomObject]@{
                    Component = "ODIS Installation Execution"
                    Reason    = "Exit code $($proc.ExitCode)"
                }
            }
        } catch {
            Write-SACMsg "  [FAIL] Failed to execute ODIS installer: $($_.Exception.Message)" "Error"
            $script:SACFailures += [PSCustomObject]@{
                Component = "ODIS Installation Execution"
                Reason    = $_.Exception.Message
            }
        }

        # Clean up local installer
        Remove-Item -LiteralPath $LocalInstallerPath -Force -ErrorAction SilentlyContinue
    } else {
        Write-SACMsg "Skipping reinstallation step due to download failure." "Warning"
    }

    # 7. Verification check
    $InstalledExe = Join-Path $env:ProgramFiles "Autodesk\AdODIS\V1\AdODIS.exe"
    if (Test-Path $InstalledExe) {
        Write-SACMsg "Verification: ODIS successfully installed at $InstalledExe" "Success"
    } else {
        Write-SACMsg "Verification: ODIS executable not found at $InstalledExe!" "Error"
        if ($script:SACFailures.Count -eq 0) {
            $script:SACFailures += [PSCustomObject]@{
                Component = "ODIS Verification"
                Reason    = "AdODIS.exe missing post-install"
            }
        }
    }

    # --- Terminate & Output ---
    $ElapsedTime = "$($StopWatch.Elapsed.Minutes)m $($StopWatch.Elapsed.Seconds)s"
    $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
    if ($script:SACFailures.Count -gt 0) {
        $content = @(
            "ODIS INSTALLER REPAIR - ITEMS REQUIRING ATTENTION",
            "Timestamp: $(Get-Date)",
            "Log Directory: $LogDir",
            "----------------------------------------------------------",
            ""
        )
        foreach ($fail in $script:SACFailures) {
            $content += "[!] $($fail.Component)"
            $content += "    Reason: $($fail.Reason)"
            $content += ""
        }
        $content | Out-File -FilePath $AttentionFile -Encoding utf8 -Force
    }

    $script:SACLastRunStatus = [PSCustomObject]@{
        Operation      = 'ODIS Repair'
        Criticals      = $script:SACFailures.Count
        Warnings       = 0
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($script:SACFailures.Count -gt 0) { $AttentionFile } else { $null }
    }

    Stop-Transcript | Out-Null
    
    if (-not $Silent) {
        Write-Host "`n==========================================================" -ForegroundColor Cyan
        if ($script:SACFailures.Count -eq 0) {
            Write-Host "         ODIS INSTALLER REPAIR COMPLETED SUCCESSFULLY" -ForegroundColor Green
        } else {
            Write-Host "          ODIS INSTALLER REPAIR COMPLETED WITH ERRORS" -ForegroundColor Red
        }
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "Log directory: $LogDir" -ForegroundColor Gray
        Write-Host "Time elapsed: $ElapsedTime`n" -ForegroundColor Gray
    }

    return $script:SACLastRunStatus
}
