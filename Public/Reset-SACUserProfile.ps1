function Reset-SACUserProfile {
<#
.SYNOPSIS
    Resets per-user Autodesk application data for a clean-start experience.
.DESCRIPTION
    Clears or backs up per-user Autodesk AppData folders and registry keys
    for targeted products and years. By default, Roaming profile data is
    RENAMED with a timestamp suffix (preserving customizations) while Local
    cache data is DELETED outright. Use -DeleteRoaming to skip the backup.

.PARAMETER TargetProducts
    Array of product name substrings to target (e.g., "AutoCAD", "Revit").
    Defaults to all Autodesk products found in user profiles.

.PARAMETER TargetYears
    Array of integers representing years to target (e.g., 2020, 2021).
    Defaults to all years found.

.PARAMETER TargetUser
    Specific username to target (e.g., "jsmith"). Defaults to all local profiles.

.PARAMETER DeleteRoaming
    Switch. If specified, Roaming folders are DELETED instead of renamed.
    Use with caution — this will destroy custom .cuix layouts, plot styles, etc.

.PARAMETER SkipRegistry
    Switch. Skip clearing HKCU/HKU Autodesk registry keys for the user.

.PARAMETER Silent
    Switch. Bypasses the confirmation prompt for RMM/headless execution.

.EXAMPLE
    # Interactive: Reset all users, rename Roaming, delete Local
    Reset-SACUserProfile

.EXAMPLE
    # RMM: Reset only AutoCAD 2020 for a specific user, delete everything
    Reset-SACUserProfile -TargetProducts "AutoCAD" -TargetYears 2020 -TargetUser "jsmith" -DeleteRoaming -Silent
#>
    [CmdletBinding()]
    param (
        [string[]]$TargetProducts  = @(),
        [int[]]$TargetYears        = @(),
        [string]$TargetUser        = "*",
        [switch]$DeleteRoaming,
        [switch]$SkipRegistry,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()

    $ToDate    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskProfileReset_$ToDate"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
    $DebugLog  = "$LogDir\ProfileResetDebug.log"
    $TranscriptLog = "$LogDir\ProfileResetTranscript.log"
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

    Clear-Host
    Write-Msg "==========================================" "Info"
    Write-Msg " SAC USER PROFILE RESET INITIALIZED"       "Info"
    Write-Msg " Debug Log:  $DebugLog"                    "Info"
    Write-Msg "==========================================" "Info"

    if (Test-Interactive) {
        $action = if ($DeleteRoaming) { "DELETE (permanent)" } else { "RENAME with backup suffix" }
        Write-Host "`nRoaming profile action : $action" -ForegroundColor Cyan
        Write-Host "Target users           : $(if ($TargetUser -eq '*') { 'ALL local profiles' } else { $TargetUser })" -ForegroundColor Cyan
        Write-Host "`nWARNING: This will clear per-user Autodesk application data.`n" -ForegroundColor Yellow
        $resp = Read-Host "Type 'YES' to proceed"
        if ($resp -ne "YES") {
            Write-Msg "Aborted by user." "Warning"
            Stop-Transcript | Out-Null
            return
        }
    }
    else {
        Write-Msg "Running in silent/non-interactive mode." "Info"
    }

    # Build user profile list
    $UserProfilesBase = "C:\Users"
    $UserProfiles = Get-ChildItem -Path $UserProfilesBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "^(Public|Default|Default User|All Users)$" } |
        Where-Object { $TargetUser -eq "*" -or $_.Name -eq $TargetUser }

    if (-not $UserProfiles) {
        Write-Msg "No matching user profiles found. Exiting." "Warning"
        Stop-Transcript | Out-Null
        return
    }

    $BackupSuffix = "_SAC_BACKUP_$ToDate"
    $Summary = @()

    foreach ($profile in $UserProfiles) {
        $userName = $profile.Name
        Write-Msg "Processing user: $userName" "Info"

        # --- LOCAL (delete outright) ---
        $LocalBase = Join-Path $profile.FullName "AppData\Local\Autodesk"
        if (Test-Path $LocalBase) {
            $LocalTargets = Get-ChildItem -Path $LocalBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                $productMatch = ($TargetProducts.Count -eq 0) -or ($TargetProducts | Where-Object { $_.Name -match $_ })
                $yearMatch    = ($TargetYears.Count -eq 0)    -or ($TargetYears | Where-Object { $_.Name -match $_ })
                $nameMatch    = $true

                if ($TargetProducts.Count -gt 0) {
                    $nameMatch = ($TargetProducts | Where-Object { $_.FullName -match $_ }).Count -gt 0
                }
                if ($TargetYears.Count -gt 0 -and $nameMatch) {
                    $nameMatch = ($TargetYears | Where-Object { $_.FullName -match $_ }).Count -gt 0
                }

                # Use the directory name itself for matching
                $dirName = $_.Name
                $productOk = ($TargetProducts.Count -eq 0) -or ($TargetProducts | Where-Object { $dirName -match [regex]::Escape($_) })
                $yearOk    = ($TargetYears.Count -eq 0)    -or ($TargetYears   | Where-Object { $dirName -match $_ })
                return ($productOk -and $yearOk)
            }

            foreach ($dir in $LocalTargets) {
                try {
                    Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                    Write-Msg "[$userName] Deleted Local cache: $($dir.Name)" "Success"
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Local)"; Path=$dir.FullName; Result="OK" }
                } catch {
                    Write-QuietLog "Failed to delete $($dir.FullName): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component="Local Delete: $($dir.FullName)"; Reason=$_.Exception.Message }
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Local)"; Path=$dir.FullName; Result="FAILED" }
                }
            }
        }

        # --- ROAMING (rename or delete) ---
        $RoamingBase = Join-Path $profile.FullName "AppData\Roaming\Autodesk"
        if (Test-Path $RoamingBase) {
            $RoamingTargets = Get-ChildItem -Path $RoamingBase -Directory -ErrorAction SilentlyContinue | Where-Object {
                $dirName   = $_.Name
                $productOk = ($TargetProducts.Count -eq 0) -or ($TargetProducts | Where-Object { $dirName -match [regex]::Escape($_) })
                $yearOk    = ($TargetYears.Count -eq 0)    -or ($TargetYears   | Where-Object { $dirName -match $_ })
                return ($productOk -and $yearOk)
            }

            foreach ($dir in $RoamingTargets) {
                if ($DeleteRoaming) {
                    try {
                        Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                        Write-Msg "[$userName] Deleted Roaming profile: $($dir.Name)" "Success"
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Roaming)"; Path=$dir.FullName; Result="OK" }
                    } catch {
                        Write-QuietLog "Failed to delete roaming $($dir.FullName): $($_.Exception.Message)"
                        $script:SACFailures += [PSCustomObject]@{ Component="Roaming Delete: $($dir.FullName)"; Reason=$_.Exception.Message }
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Roaming)"; Path=$dir.FullName; Result="FAILED" }
                    }
                } else {
                    $newName = "$($dir.FullName)$BackupSuffix"
                    try {
                        Rename-Item -Path $dir.FullName -NewName $newName -ErrorAction Stop
                        Write-Msg "[$userName] Backed up Roaming profile: $($dir.Name) -> $($dir.Name)$BackupSuffix" "Success"
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Renamed (Roaming Backup)"; Path=$newName; Result="OK" }
                    } catch {
                        Write-QuietLog "Failed to rename roaming $($dir.FullName): $($_.Exception.Message)"
                        $script:SACFailures += [PSCustomObject]@{ Component="Roaming Rename: $($dir.FullName)"; Reason=$_.Exception.Message }
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Renamed (Roaming Backup)"; Path=$dir.FullName; Result="FAILED" }
                    }
                }
            }
        }

        # --- REGISTRY (HKU hive) ---
        if (-not $SkipRegistry) {
            New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction SilentlyContinue | Out-Null

            # Get the SID for this user profile
            try {
                $SID = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -eq $profile.FullName }).SID
                if ($SID) {
                    $RegTargets = @(
                        "HKU:\$SID\Software\Autodesk",
                        "HKU:\$SID\Software\Wow6432Node\Autodesk"
                    )
                    foreach ($regPath in $RegTargets) {
                        if (Test-Path $regPath) {
                            $keysToRemove = if ($TargetProducts.Count -gt 0) {
                                Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue |
                                    Where-Object { $prod = $_.PSChildName; $TargetProducts | Where-Object { $prod -match [regex]::Escape($_) } }
                            } else {
                                @(Get-Item -Path $regPath -ErrorAction SilentlyContinue)
                            }

                            foreach ($key in $keysToRemove) {
                                try {
                                    Remove-Item $key.PSPath -Recurse -Force -ErrorAction Stop
                                    Write-Msg "[$userName] Cleared registry key: $($key.PSChildName)" "Success"
                                    $Summary += [PSCustomObject]@{ User=$userName; Action="Cleared Registry"; Path=$key.PSPath; Result="OK" }
                                } catch {
                                    Write-QuietLog "Failed to remove registry key $($key.PSPath): $($_.Exception.Message)"
                                    $script:SACFailures += [PSCustomObject]@{ Component="Registry: $($key.PSPath)"; Reason=$_.Exception.Message }
                                    $Summary += [PSCustomObject]@{ User=$userName; Action="Cleared Registry"; Path=$key.PSPath; Result="FAILED" }
                                }
                            }
                        }
                    }
                } else {
                    Write-QuietLog "Could not resolve SID for user $userName — registry keys skipped."
                }
            } catch {
                Write-QuietLog "Failed to load HKU hive for $userName : $($_.Exception.Message)"
            }
        }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed

    Write-Msg "==========================================" "Info"
    Write-Msg " PROFILE RESET COMPLETED in $ElapsedTime" "Success"
    Write-Msg "==========================================" "Info"

    if ($Summary.Count -gt 0) {
        Write-Host "`n--- Summary ---" -ForegroundColor Cyan
        $Summary | Format-Table User, Action, Result, Path -AutoSize
    }

    if ($script:SACFailures.Count -gt 0) {
        Write-Host "`n[!] FAILURES DETECTED:" -ForegroundColor Red
        Write-Host "    (Note: These items may have been forcibly evicted/removed despite errors)" -ForegroundColor Gray
        foreach ($fail in $script:SACFailures) {
            Write-Host "   - $($fail.Component)" -ForegroundColor Yellow
            Write-Host "     Reason: $($fail.Reason)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "`n[*] All operations completed successfully.`n" -ForegroundColor Green
    }

    # Persist outcome so the interactive menu can show a status badge on return
    $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
    if ($script:SACFailures.Count -gt 0) {
        $content = @(
            "AUTODESK PROFILE RESET - ITEMS REQUIRING ATTENTION",
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
        Operation      = 'Profile Reset'
        Criticals      = $script:SACFailures.Count
        Warnings       = 0
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($script:SACFailures.Count -gt 0) { $AttentionFile } else { $null }
    }

    Stop-Transcript | Out-Null
}
