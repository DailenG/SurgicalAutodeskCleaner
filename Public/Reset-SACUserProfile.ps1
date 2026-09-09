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
    Use with caution - this will destroy custom .cuix layouts, plot styles, etc.

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

    # --- Helper Functions (Centralized) ---

    if (-not (Test-SACRemoteSession)) { Clear-Host }
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " SAC USER PROFILE RESET INITIALIZED"       "Info"
    Write-SACMsg " Debug Log:  $DebugLog"                    "Info"
    Write-SACMsg "==========================================" "Info"

    if (Test-SACInteractive -Silent $Silent) {
        $action = if ($DeleteRoaming) { "DELETE (permanent)" } else { "RENAME with backup suffix" }
        Write-Host "`nRoaming profile action : $action" -ForegroundColor Cyan
        Write-Host "Target users           : $(if ($TargetUser -eq '*') { 'ALL local profiles' } else { $TargetUser })" -ForegroundColor Cyan
        Write-Host "`nWARNING: This will clear per-user Autodesk application data.`n" -ForegroundColor Yellow
        $resp = Read-Host "Type 'YES' to proceed"
        if ($resp -ne "YES") {
            Write-SACMsg "Aborted by user." "Warning"
            Stop-Transcript | Out-Null
            return
        }
    }
    else {
        Write-SACMsg "Running in silent/non-interactive mode." "Info"
    }

    # Build user profile list
    $UserProfilesBase = "C:\Users"
    $UserProfiles = Get-ChildItem -Path $UserProfilesBase -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "^(Public|Default|Default User|All Users)$" } |
        Where-Object { $TargetUser -eq "*" -or $_.Name -eq $TargetUser }

    if (-not $UserProfiles) {
        Write-SACMsg "No matching user profiles found. Exiting." "Warning"
        Stop-Transcript | Out-Null
        return
    }

    $BackupSuffix = "_SAC_BACKUP_$ToDate"
    $Summary = @()

    foreach ($profile in $UserProfiles) {
        $userName = $profile.Name
        Write-SACMsg "Processing user: $userName" "Info"

        # --- LOCAL (delete outright) ---
        $LocalPathsToCheck = @()
        $LocalSearchPaths = @(
            "AppData\Local\Autodesk",
            "AppData\Local\Autodesk Navisworks",
            "AppData\Local\Autodesk,_Inc",
            "AppData\Local\Autodesk Inc",
            "AppData\Local\Autodesk Installer",
            "AppData\Local\Autodesk Ltd",
            "AppData\Local\AdSSO",
            "AppData\Local\Civil3DFeatures"
        )
        foreach ($sp in $LocalSearchPaths) {
            $fullPath = Join-Path $profile.FullName $sp
            if (Test-Path $fullPath) {
                $LocalPathsToCheck += Get-Item $fullPath
                $LocalPathsToCheck += Get-ChildItem -Path $fullPath -Directory -ErrorAction SilentlyContinue
            }
        }

        $LocalTargets = $LocalPathsToCheck | Select-Object -Unique | Where-Object {
            $dirName = $_.Name
            $isGlobal = $dirName -in @("Autodesk,_Inc", "Autodesk Inc", "Autodesk Installer", "Autodesk Ltd", "AdSSO")
            if ($isGlobal) {
                return (@($TargetProducts).Count -eq 0 -and @($TargetYears).Count -eq 0)
            }
            $productOk = (@($TargetProducts).Count -eq 0) -or ($TargetProducts | Where-Object { $dirName -match [regex]::Escape($_) })
            $hasYearInName = ($dirName -match '\b20\d{2}\b')
            $yearOk = if ($hasYearInName) {
                (@($TargetYears).Count -eq 0) -or ($TargetYears | Where-Object { $dirName -match $_ })
            } else {
                (@($TargetYears).Count -eq 0)
            }
            return ($productOk -and $yearOk)
        }

        foreach ($dir in $LocalTargets) {
            try {
                Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-SACMsg "[$userName] Deleted Local cache: $($dir.Name)" "Success"
                $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Local)"; Path=$dir.FullName; Result="OK" }
            } catch {
                Write-SACQuietLog "Failed to delete $($dir.FullName): $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component="Local Delete: $($dir.FullName)"; Reason=$_.Exception.Message }
                $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Local)"; Path=$dir.FullName; Result="FAILED" }
            }
        }

        # --- Root Profile Caches (e.g. Autodesk Docs & ACC) ---
        $RootCaches = @(
            @{ Name = "ACCDocs"; MatchProducts = @("Autodesk Docs", "Autodesk Construction Cloud", "ACC") },
            @{ Name = "BIM 360"; MatchProducts = @("Autodesk Docs", "Autodesk Construction Cloud", "ACC", "BIM 360") }
        )
        foreach ($rc in $RootCaches) {
            $rcPath = Join-Path $profile.FullName $rc.Name
            if (Test-Path $rcPath) {
                $shouldDelete = (@($TargetProducts).Count -eq 0) -or ($TargetProducts | Where-Object { $prod = $_; $rc.MatchProducts | Where-Object { $prod -match [regex]::Escape($_) } })
                if ($shouldDelete) {
                    try {
                        Remove-Item $rcPath -Recurse -Force -ErrorAction Stop
                        Write-SACMsg "[$userName] Deleted Root Cache: $($rc.Name)" "Success"
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Root Cache)"; Path=$rcPath; Result="OK" }
                    } catch {
                        Write-SACQuietLog "Failed to delete root cache $($rcPath): $($_.Exception.Message)"
                        $script:SACFailures += [PSCustomObject]@{ Component="Root Cache Delete: $rcPath"; Reason=$_.Exception.Message }
                        $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Root Cache)"; Path=$rcPath; Result="FAILED" }
                    }
                }
            }
        }

        # --- ROAMING (rename or delete) ---
        $RoamingPathsToCheck = @()
        $RoamingSearchPaths = @(
            "AppData\Roaming\Autodesk",
            "AppData\Roaming\Autodesk Navisworks",
            "AppData\Roaming\Autodesk,_Inc",
            "AppData\Roaming\Autodesk Inc",
            "AppData\Roaming\Autodesk Installer",
            "AppData\Roaming\Autodesk Ltd",
            "AppData\Roaming\AdSSO",
            "AppData\Roaming\Civil3DFeatures"
        )
        foreach ($sp in $RoamingSearchPaths) {
            $fullPath = Join-Path $profile.FullName $sp
            if (Test-Path $fullPath) {
                $RoamingPathsToCheck += Get-Item $fullPath
                $RoamingPathsToCheck += Get-ChildItem -Path $fullPath -Directory -ErrorAction SilentlyContinue
            }
        }

        $RoamingTargets = $RoamingPathsToCheck | Select-Object -Unique | Where-Object {
            $dirName = $_.Name
            $isGlobal = $dirName -in @("Autodesk,_Inc", "Autodesk Inc", "Autodesk Installer", "Autodesk Ltd", "AdSSO")
            if ($isGlobal) {
                return (@($TargetProducts).Count -eq 0 -and @($TargetYears).Count -eq 0)
            }
            $productOk = (@($TargetProducts).Count -eq 0) -or ($TargetProducts | Where-Object { $dirName -match [regex]::Escape($_) })
            $hasYearInName = ($dirName -match '\b20\d{2}\b')
            $yearOk = if ($hasYearInName) {
                (@($TargetYears).Count -eq 0) -or ($TargetYears | Where-Object { $dirName -match $_ })
            } else {
                (@($TargetYears).Count -eq 0)
            }
            return ($productOk -and $yearOk)
        }

        foreach ($dir in $RoamingTargets) {
            if ($DeleteRoaming) {
                try {
                    Remove-Item $dir.FullName -Recurse -Force -ErrorAction Stop
                    Write-SACMsg "[$userName] Deleted Roaming profile: $($dir.Name)" "Success"
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Roaming)"; Path=$dir.FullName; Result="OK" }
                } catch {
                    Write-SACQuietLog "Failed to delete roaming $($dir.FullName): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component="Roaming Delete: $($dir.FullName)"; Reason=$_.Exception.Message }
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Deleted (Roaming)"; Path=$dir.FullName; Result="FAILED" }
                }
            } else {
                $newName = "$($dir.FullName)$BackupSuffix"
                try {
                    Rename-Item -Path $dir.FullName -NewName $newName -ErrorAction Stop
                    Write-SACMsg "[$userName] Backed up Roaming profile: $($dir.Name) -> $($dir.Name)$BackupSuffix" "Success"
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Renamed (Roaming Backup)"; Path=$newName; Result="OK" }
                } catch {
                    Write-SACQuietLog "Failed to rename roaming $($dir.FullName): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component="Roaming Rename: $($dir.FullName)"; Reason=$_.Exception.Message }
                    $Summary += [PSCustomObject]@{ User=$userName; Action="Renamed (Roaming Backup)"; Path=$dir.FullName; Result="FAILED" }
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
                                    Write-SACMsg "[$userName] Cleared registry key: $($key.PSChildName)" "Success"
                                    $Summary += [PSCustomObject]@{ User=$userName; Action="Cleared Registry"; Path=$key.PSPath; Result="OK" }
                                } catch {
                                    Write-SACQuietLog "Failed to remove registry key $($key.PSPath): $($_.Exception.Message)"
                                    $script:SACFailures += [PSCustomObject]@{ Component="Registry: $($key.PSPath)"; Reason=$_.Exception.Message }
                                    $Summary += [PSCustomObject]@{ User=$userName; Action="Cleared Registry"; Path=$key.PSPath; Result="FAILED" }
                                }
                            }
                        }
                    }
                } else {
                    Write-SACQuietLog "Could not resolve SID for user $userName - registry keys skipped."
                }
            } catch {
                Write-SACQuietLog "Failed to load HKU hive for $userName : $($_.Exception.Message)"
            }
        }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed

    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " PROFILE RESET COMPLETED in $ElapsedTime" "Success"
    Write-SACMsg "==========================================" "Info"

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
    return $script:SACLastRunStatus
}

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC0Svn1vKKEqLQP
# dm/aWJeZm7SI2U4gg/YiOd52PSvM8qCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggarMIIEk6ADAgECAhMzAAYTVdk2
# ehI+T0rIAAAABhNVMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwHhcNMjYwOTA3MDM0ODI0WhcNMjYwOTEw
# MDM0ODI0WjBtMQswCQYDVQQGEwJVUzELMAkGA1UECBMCZ2ExETAPBgNVBAcTCEJv
# c3R3aWNrMR4wHAYDVQQKExVSaWNoYXJkIERhaWxlbiBHdW50ZXIxHjAcBgNVBAMT
# FVJpY2hhcmQgRGFpbGVuIEd1bnRlcjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCC
# AYoCggGBALfpUhuyxWlOrMpuIe/L70ARCDcPrcpzy8zk5J/FIA3jhJEVls7cEdFw
# z7T3SLKq6n9KPcogyaVDTYf6E8gw7otblBreeHFt4jpxzBbmWsbLVCEPVxdc6QmC
# ablEKgjlg7qC2mrXFGrUxmUQ21+XddgBN+xa3XR4svzOCD3qCjfiEC3A2rqudRv0
# v11LU7usedCSQ0aI/8oCvl48c/bUfkkZEMmXZPD8FWVFfU2H0Ry9ZuyEy4M/q6jB
# t5AG1vokjHqjPBAbLL3smeD5Vbgx/ph4hKRSdDqBvzAKRlX3qcnOzpYFMP2BJSLV
# hbFf9gpk6Jku9xmUKOwi31zfleocEwiPeUaDQWXPDaqGSpYrdnkDSmb6HniHkIpH
# S7HOMjS2zSvUiIy5nFXpVzQuS9IrgmYHs7ClmujPrstFnQe/2OwPW7BAsvqfWUGW
# RwAzPuSJg/vjBfvq8WtEeQcVsTk+7S+AHDLt3J4LAfRxi5seUDImRWMdopt0DeVt
# DEYUe2Ob8wIDAQABo4IB1TCCAdEwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMC
# B4AwPAYDVR0lBDUwMwYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGysGAQQBgjdhoOiV
# eoK/0ttMg5+ekiyCi8TIKTAdBgNVHQ4EFgQUC0F3x+fKE1nse9GFDO/VwTCiozEw
# HwYDVR0jBBgwFoAUayVB3vtrfP0YgAotf492XapzPbgwZwYDVR0fBGAwXjBcoFqg
# WIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwNC5jcmwwdAYIKwYB
# BQUHAQEEaDBmMGQGCCsGAQUFBzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEFP
# QyUyMENBJTIwMDQuY3J0MFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9y
# eS5odG0wDQYJKoZIhvcNAQEMBQADggIBAByXwNSoxMmFO2Dg0OAEEuNGiuWN72Kf
# cblukHrWS7Lb4P6MZW3BjuPI7pzPEAU5FGc+qisL0I3MLjC4i+YhJFWc23qkmRmF
# BYx8eDbPjQ2BvnjLssQxd1c43s0iEJa+628WrA1KizFsPygYxk+aSwoZOddGSjCz
# F5mZWDh++TgumeghOk/JFUYy/cqFAhqjqxZxKeuVEMrBwTXUa9SQQbZRDWxoENrS
# mOpF8v3B8ahtZIemmwlZuJApNASuZi0xMoUDz6mERGPL0dHZz8buQRtbpc61A8qS
# 1wJrHH22KAFntYwIh6prgOXsXiU6F9oc+2cPbS9z/TWAfJphZeSFFOckvN1FEXHu
# xdlEXM8LjPjHm/6+1TZzfoxnhIq+emrs3tDFUqkQmG+4fUMi4p6qlTn0rjvVAskR
# jC2YYIfJncIFpB5Vn5/m9sbJA5Ck5bDU/JrgEU/6cYUtZL08d5B4lRXJao29Wlzb
# yhTJY7jphlDA1wRUzNhC/3+O+/SNTQXnoJzpGwYgPuEfHDK4FBwBh9HU1H8DRGeP
# Nvy5P3nBaNrUtsQqX8wE7UhbMxQplz8qaCsSNTTHm0YyLdTu4+azBp7ycXS8oZA7
# pYbbUKyHdemLdVj+kHx19ni3SGUdli9PSkH5O1ikOFObMfR4b1wXhoaqLPCmq20r
# qoyDuHoMrsUGMIIGqzCCBJOgAwIBAgITMwAGE1XZNnoSPk9KyAAAAAYTVTANBgkq
# hkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9D
# IENBIDA0MB4XDTI2MDkwNzAzNDgyNFoXDTI2MDkxMDAzNDgyNFowbTELMAkGA1UE
# BhMCVVMxCzAJBgNVBAgTAmdhMREwDwYDVQQHEwhCb3N0d2ljazEeMBwGA1UEChMV
# UmljaGFyZCBEYWlsZW4gR3VudGVyMR4wHAYDVQQDExVSaWNoYXJkIERhaWxlbiBH
# dW50ZXIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQC36VIbssVpTqzK
# biHvy+9AEQg3D63Kc8vM5OSfxSAN44SRFZbO3BHRcM+090iyqup/Sj3KIMmlQ02H
# +hPIMO6LW5Qa3nhxbeI6ccwW5lrGy1QhD1cXXOkJgmm5RCoI5YO6gtpq1xRq1MZl
# ENtfl3XYATfsWt10eLL8zgg96go34hAtwNq6rnUb9L9dS1O7rHnQkkNGiP/KAr5e
# PHP21H5JGRDJl2Tw/BVlRX1Nh9EcvWbshMuDP6uowbeQBtb6JIx6ozwQGyy97Jng
# +VW4Mf6YeISkUnQ6gb8wCkZV96nJzs6WBTD9gSUi1YWxX/YKZOiZLvcZlCjsIt9c
# 35XqHBMIj3lGg0Flzw2qhkqWK3Z5A0pm+h54h5CKR0uxzjI0ts0r1IiMuZxV6Vc0
# LkvSK4JmB7OwpZroz67LRZ0Hv9jsD1uwQLL6n1lBlkcAMz7kiYP74wX76vFrRHkH
# FbE5Pu0vgBwy7dyeCwH0cYubHlAyJkVjHaKbdA3lbQxGFHtjm/MCAwEAAaOCAdUw
# ggHRMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDwGA1UdJQQ1MDMGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhsrBgEEAYI3YaDolXqCv9LbTIOfnpIsgovEyCkw
# HQYDVR0OBBYEFAtBd8fnyhNZ7HvRhQzv1cEwoqMxMB8GA1UdIwQYMBaAFGslQd77
# a3z9GIAKLX+Pdl2qcz24MGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQl
# MjBDUyUyMEFPQyUyMENBJTIwMDQuY3JsMHQGCCsGAQUFBwEBBGgwZjBkBggrBgEF
# BQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDA0LmNydDBU
# BgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMA0GCSqGSIb3DQEB
# DAUAA4ICAQAcl8DUqMTJhTtg4NDgBBLjRorlje9in3G5bpB61kuy2+D+jGVtwY7j
# yO6czxAFORRnPqorC9CNzC4wuIvmISRVnNt6pJkZhQWMfHg2z40Ngb54y7LEMXdX
# ON7NIhCWvutvFqwNSosxbD8oGMZPmksKGTnXRkowsxeZmVg4fvk4LpnoITpPyRVG
# Mv3KhQIao6sWcSnrlRDKwcE11GvUkEG2UQ1saBDa0pjqRfL9wfGobWSHppsJWbiQ
# KTQErmYtMTKFA8+phERjy9HR2c/G7kEbW6XOtQPKktcCaxx9tigBZ7WMCIeqa4Dl
# 7F4lOhfaHPtnD20vc/01gHyaYWXkhRTnJLzdRRFx7sXZRFzPC4z4x5v+vtU2c36M
# Z4SKvnpq7N7QxVKpEJhvuH1DIuKeqpU59K471QLJEYwtmGCHyZ3CBaQeVZ+f5vbG
# yQOQpOWw1Pya4BFP+nGFLWS9PHeQeJUVyWqNvVpc28oUyWO46YZQwNcEVMzYQv9/
# jvv0jU0F56Cc6RsGID7hHxwyuBQcAYfR1NR/A0Rnjzb8uT95wWja1LbEKl/MBO1I
# WzMUKZc/KmgrEjU0x5tGMi3U7uPmswae8nF0vKGQO6WG21Csh3Xpi3VY/pB8dfZ4
# t0hlHZYvT0pB+TtYpDhTmzH0eG9cF4aGqizwpqttK6qMg7h6DK7FBjCCBygwggUQ
# oAMCAQICEzMAAAAWMZKNkgJle5oAAAAAABYwDQYJKoZIhvcNAQEMBQAwYzELMAkG
# A1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UE
# AxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTAe
# Fw0yNjAzMjYxODExMjlaFw0zMTAzMjYxODExMjlaMFoxCzAJBgNVBAYTAlVTMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29m
# dCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQDKVfrI2+gJMM/0bQ5OVKNdvOASzLbUUMvXuf+Vl7YGuofPaZHV
# o3gMHF5inT+GMSpIcfIZ9qtXU1UG68ry8vNbQtOL4Nm30ifXpqI1+ByiAWLO1YT0
# WnzG7XPOuoTeeWsNZv5FmjxCsReBZvyzyzCyXZbu1EQfJxWTH4ebUwtAiW9rqMf9
# eDj/wYhiEfNteJV3ZFeibD2ztCHr9JhFdd97XbnCHgQoTIqc02X5xlRKtUGBa++O
# tHBBjiJ/uwBnzTkqu4FjpZjQeJtrmda+ur1CT2jflWIB/ypn7u7V9tvW9wJbJYt/
# H2EtJ0GONWxJZ7TEu8jWPindOO3lzPP7UtzS/mVDV94HucWaltmsra6zSG8BoEJ8
# 7IM8QSb7vfm/O41FhYkUv89WIj5ES2O4kxyiMSfe95CMivCuYrRP2hKvx7egPMrW
# gDDBkxMLgrKZO9hRNUMm8vk3w5b9SogHOyJVhxyFm8aFXfIxgqDF4S0g4bhbhnzl
# jmSlCLlumMZcXFGDjpF2tNoAu3VGFGYtHtTSNVKvZpgB3b4ynaoDkbPf+Wg4523j
# t4VneasBgZhC1srZI2NCnCBBfgjLq04pqEKAWEohyW2K29KSkkHvt5VaE1ac3Yt+
# oyiOzMS57tXwQDJLGvLg/OXFO0VNvczDndfIfXYExB/ab2PuMSwd5VIBOwIDAQAB
# o4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1Ud
# DgQWBBRrJUHe+2t8/RiACi1/j3ZdqnM9uDBUBgNVHSAETTBLMEkGBFUdIAAwQTA/
# BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2Nz
# L1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMBIGA1Ud
# EwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zvadf1zSmepEhqMOYw
# cAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENvZGUlMjBTaWduaW5n
# JTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0GCCsGAQUFBzAChmFo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUy
# MElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0
# MA0GCSqGSIb3DQEBDAUAA4ICAQAG1VBeVHTVRBljlcZD3IiMxwPyMjQyLNaEnVu5
# mODm2hRBJfH8GsBLATmrHAc8F47jmk5CnpUPiIguCbw6Z/KVj4Dsoiq228NSLMLe
# wFfGMri7uwNGLISC5ccp8vUdADDEIsS2dE+QI9OwkDpv3XuUD7d+hAgcLVcMOl1A
# sfEZtsZenhGvSYUrm/FuLq0BqEGL9GXM5c+Ho9q8o+Vn/S+GWQN2y+gkRO15s0kI
# 05nUpq/dOD4ri9rgVs6tipEd0YZqGgD+CZNiaZWrDTOQbNPncd2F9qOsUa20miYr
# uoT5PwJAaI+QQiTE2ZJeMJOkOpzhTUgqVMZwZidEUZKCqudaeQA08WwnkQMfKyHz
# aU8j48ULcU4hUwvMsv7fSurOe9GAdRQCPvF8WcSK5oDHe8VVJM4tv6KKCm91HqLx
# 9JamBgRI6R2SfY3nu26EGznu0rCg/769z8xWm4PVcC2ZaL6VlKVqFp1NsN8YqMyf
# 5t+bbGVb09noFKcJG/UwyGlxRmQBlfeBUQx5/ytlzZzsEnhrJF9fTAfje8j3OdX5
# lEnePTFQLRlvzZFBqUXnIeQKv3fHQjC9m2fo/Z01DII/qp3d8LhGVUW0BCG04fRw
# HJNH8iqqCG/qofMv+kym2AxBDnHzNgRjL60JOFiBgiurvLhYQNhB95KWojFA6shQ
# nggkMTCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAAAAcwDQYJKoZIhvcN
# AQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlvbiBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIxMDQwMTIwMDUyMFoX
# DTM2MDQwMTIwMTUyMFowYzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjE0MDIGA1UEAxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENv
# ZGUgU2lnbmluZyBQQ0EgMjAyMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
# ggIBALLwwK8ZiCji3VR6TElsaQhVCbRS/3pK+MHrJSj3Zxd3KU3rlfL3qrZilYKJ
# NqztA9OQacr1AwoNcHbKBLbsQAhBnIB34zxf52bDpIO3NJlfIaTE/xrweLoQ71lz
# CHkD7A4As1Bs076Iu+mA6cQzsYYH/Cbl1icwQ6C65rU4V9NQhNUwgrx9rGQ//h89
# 0Q8JdjLLw0nV+ayQ2Fbkd242o9kH82RZsH3HEyqjAB5a8+Ae2nPIPc8sZU6ZE7iR
# rRZywRmrKDp5+TcmJX9MRff241UaOBs4NmHOyke8oU1TYrkxh+YeHgfWo5tTgkoS
# MoayqoDpHOLJs+qG8Tvh8SnifW2Jj3+ii11TS8/FGngEaNAWrbyfNrC69oKpRQXY
# 9bGH6jn9NEJv9weFxhTwyvx9OJLXmRGbAUXN1U9nf4lXezky6Uh/cgjkVd6CGUAf
# 0K+Jw+GE/5VpIVbcNr9rNE50Sbmy/4RTCEGvOq3GhjITbCa4crCzTTHgYYjHs1Nb
# Oc6brH+eKpWLtr+bGecy9CrwQyx7S/BfYJ+ozst7+yZtG2wR461uckFu0t+gCwLd
# N0A6cFtSRtR8bvxVFyWwTtgMMFRuBa3vmUOTnfKLsLefRaQcVTgRnzeLzdpt32cd
# YKp+dhr2ogc+qM6K4CBI5/j4VFyC4QFeUP2YAidLtvpXRRo3AgMBAAGjggI1MIIC
# MTAOBgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFNlB
# KbAPD2Ns72nX9c0pnqRIajDmMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUF
# BwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3Np
# dG9yeS5odG0wGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwDwYDVR0TAQH/BAUw
# AwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcnz1AQT2ioojCBhAYDVR0fBH0w
# ezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWlj
# cm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRpb24lMjBSb290JTIwQ2VydGlm
# aWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCBwwYIKwYBBQUHAQEEgbYwgbMw
# gYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Nl
# cnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUy
# MENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcnQwLQYIKwYBBQUHMAGG
# IWh0dHA6Ly9vbmVvY3NwLm1pY3Jvc29mdC5jb20vb2NzcDANBgkqhkiG9w0BAQwF
# AAOCAgEAfyUqnv7Uq+rdZgrbVyNMul5skONbhls5fccPlmIbzi+OwVdPQ4H55v7V
# OInnmezQEeW4LqK0wja+fBznANbXLB0KrdMCbHQpbLvG6UA/Xv2pfpVIE1CRFfNF
# 4XKO8XYEa3oW8oVH+KZHgIQRIwAbyFKQ9iyj4aOWeAzwk+f9E5StNp5T8FG7/VEU
# RIVWArbAzPt9ThVN3w1fAZkF7+YU9kbq1bCR2YD+MtunSQ1Rft6XG7b4e0ejRA7m
# B2IoX5hNh3UEauY0byxNRG+fT2MCEhQl9g2i2fs6VOG19CNep7SquKaBjhWmirYy
# ANb0RJSLWjinMLXNOAga10n8i9jqeprzSMU5ODmrMCJE12xS/NWShg/tuLjAsKP6
# SzYZ+1Ry358ZTFcx0FS/mx2vSoU8s8HRvy+rnXqyUJ9HBqS0DErVLjQwK8VtsBde
# kBmdTbQVoCgPCqr+PDPB3xajYnzevs7eidBsM71PINK2BoE2UfMwxCCX3mccFgx6
# UsQeRSdVVVNSyALQe6PT12418xon2iDGE81OGCreLzDcMAZnrUAx4XQLUz6ZTl65
# yPUiOh3k7Yww94lDf+8oG2oZmDh5O1Qe38E+M3vhKwmzIeoB1dVLlz4i3IpaDcR+
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqUMIIakAIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQC
# EzMABhNV2TZ6Ej5PSsgAAAAGE1UwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQgbb0n6GvpBnvy78BSti8z32VL3fNCLrNNGMZz09tWz98wDQYJKoZIhvcNAQEB
# BQAEggGAqvKMtyWddz8lPwJhfdsGlaWX8Ojd0n5xEHkGszIP6ZXeRRWkjQ2jpAIs
# F4Uvw4rGuhbn3ei2UFdPSU2+UGao2A7hBwW/fzny0q0CACyGbKU9FzNKGXynZ5G5
# CNOS+I/+wxMYnyyqAV6drccxO8nrnDtIXxqhYTepy+R9CeUTPAADsNw9gfKsyZ6c
# j2MOd9wDcGIW46DNLJT6azksOQeqt/qeEVWVDjMuoh/U+tOUa+nlg17vJU1ULzSo
# W7/GktBYQEE/Kh9rSu6B2vzMWPrM/0L/tRlML/4vYpVCkM3aIijORtb+kQPD7kcA
# M4IIvan0JYxfLz3oXUnS3kO4VWRZCpJ2WQYjpBACn3C7kN0hmzrWWeRvLA6ou3BH
# Ql2AgD+y7dRrOmOwzyQ/BI3c0PoZ9w7/J8q582a0pUhGaytzLIQxf5PGEHwsXt3S
# p9qxkRHzLbMnlRxKeZkh3gaKuQYMp4i+D3MZjtbdgCj28lEJg/svHQKPQEDeJQFP
# IUR4hklkoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEINwismhi1kKV
# fYUbZVclNTwMzTUwP6VJUGmk+0mFl6ZZAgZqhEkGSHQYEzIwMjYwOTA5MDIyNzQy
# LjE5NFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1MDMGA1UE
# AxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHmg
# gg8hMIIHgjCCBWqgAwIBAgITMwAAAAXlzw//Zi7JhwAAAAAABTANBgkqhkiG9w0B
# AQwFADB3MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMUgwRgYDVQQDEz9NaWNyb3NvZnQgSWRlbnRpdHkgVmVyaWZpY2F0aW9uIFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMjAwHhcNMjAxMTE5MjAzMjMxWhcN
# MzUxMTE5MjA0MjMxWjBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1l
# c3RhbXBpbmcgQ0EgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AJ5851Jj/eDFnwV9Y7UGIqMcHtfnlzPREwW9ZUZHd5HBXXBvf7KrQ5cMSqFSHGqg
# 2/qJhYqOQxwuEQXG8kB41wsDJP5d0zmLYKAY8Zxv3lYkuLDsfMuIEqvGYOPURAH+
# Ybl4SJEESnt0MbPEoKdNihwM5xGv0rGofJ1qOYSTNcc55EbBT7uq3wx3mXhtVmtc
# CEr5ZKTkKKE1CxZvNPWdGWJUPC6e4uRfWHIhZcgCsJ+sozf5EeH5KrlFnxpjKKTa
# vwfFP6XaGZGWUG8TZaiTogRoAlqcevbiqioUz1Yt4FRK53P6ovnUfANjIgM9JDdJ
# 4e0qiDRm5sOTiEQtBLGd9Vhd1MadxoGcHrRCsS5rO9yhv2fjJHrmlQ0EIXmp4DhD
# BieKUGR+eZ4CNE3ctW4uvSDQVeSp9h1SaPV8UWEfyTxgGjOsRpeexIveR1MPTVf7
# gt8hY64XNPO6iyUGsEgt8c2PxF87E+CO7A28TpjNq5eLiiunhKbq0XbjkNoU5Jht
# YUrlmAbpxRjb9tSreDdtACpm3rkpxp7AQndnI0Shu/fk1/rE3oWsDqMX3jjv40e8
# KN5YsJBnczyWB4JyeeFMW3JBfdeAKhzohFe8U5w9WuvcP1E8cIxLoKSDzCCBOu0h
# WdjzKNu8Y5SwB1lt5dQhABYyzR3dxEO/T1K/BVF3rV69AgMBAAGjggIbMIICFzAO
# BgNVHQ8BAf8EBAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFGtpKDo1
# L0hjQM972K9J6T7ZPdshMFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9y
# eS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUA
# YgBDAEEwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTIftJqhSobyhmYBAcn
# z1AQT2ioojCBhAYDVR0fBH0wezB5oHegdYZzaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJpZmljYXRp
# b24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIwLmNybDCB
# lAYIKwYBBQUHAQEEgYcwgYQwgYEGCCsGAQUFBzAChnVodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVy
# aWZpY2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAy
# MC5jcnQwDQYJKoZIhvcNAQEMBQADggIBAF+Idsd+bbVaFXXnTHho+k7h2ESZJRWl
# uLE0Oa/pO+4ge/XEizXvhs0Y7+KVYyb4nHlugBesnFqBGEdC2IWmtKMyS1OWIviw
# pnK3aL5JedwzbeBF7POyg6IGG/XhhJ3UqWeWTO+Czb1c2NP5zyEh89F72u9UIw+I
# fvM9lzDmc2O2END7MPnrcjWdQnrLn1Ntday7JSyrDvBdmgbNnCKNZPmhzoa8PccO
# iQljjTW6GePe5sGFuRHzdFt8y+bN2neF7Zu8hTO1I64XNGqst8S+w+RUdie8fXC1
# jKu3m9KGIqF4aldrYBamyh3g4nJPj/LR2CBaLyD+2BuGZCVmoNR/dSpRCxlot0i7
# 9dKOChmoONqbMI8m04uLaEHAv4qwKHQ1vBzbV/nG89LDKbRSSvijmwJwxRxLLpMQ
# /u4xXxFfR4f/gksSkbJp7oqLwliDm/h+w0aJ/U5ccnYhYb7vPKNMN+SZDWycU5OD
# IRfyoGl59BsXR/HpRGtiJquOYGmvA/pk5vC1lcnbeMrcWD/26ozePQ/TWfNXKBOm
# kFpvPE8CH+EeGGWzqTCjdAsno2jzTeNSxlx3glDGJgcdz5D/AAxw9Sdgq/+rY7jj
# gs7X6fqPTXPmaCAJKVHAP19oEjJIBwD1LyHbaEgBxFCogYSOiUIr0Xqcr1nJfiWG
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFZ+j51YCI7pYAAAAAAAVjANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTFaFw0yNjEwMjIyMDQ2NTFaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046QTUwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAtKWfm/ul027/d8Rlb8Mn/g0QUvvLqY2Vsy3tI8U2tFSspTZo
# mZOD3BHT8LkR+RrhMJgb1VjAKFNysaK9cLSXifPGSIBrPCgs9P4y24lrJEmrV6Q5
# z4BmqMhIPrZhEvZnWpCS4HO7jYSei/nxmC7/1Er+l5Lg3PmSxb8d2IVcARxSw1B4
# mxB6XI0nkel9wa1dYb2wfGpofraFmxZOxT9eNht4LH0RBSVueba6ZNpjS/0gtfm7
# qiIiyP6p6PRzTTbMnVqsHnV/d/rW0zHx+Q+QNZ5wUqKmTZJB9hU853+2pX5rDfK3
# 2uNY9/WBOAmzbqgpEdQkbiMavUMyUDShmycIvgHdQnS207sTj8M+kJL3tOdahPuP
# qMwsaCCgdfwwQx0O9TKe7FSvbAEYs1AnldCl/KHGZCOVvUNqjyL10JLe0/+GD9/y
# nqXGWFpXOjaunvZ/cKROhjN4M5e6xx0b2miqcPii4/ii2ZheKallJET7CKlpFShs
# 3wyg6F/fojQxQvPnbWD4Nyx6lhjWjwmoLcx6w1FSCtavLCly33BLRSlTU4qKUxaa
# 8d7YN7Eqpn9XO0SY0umOvKFXrWH7rxl+9iaicitdnTTksAnRjvekdKT3lg7lRMfm
# fZU8vXNiN0UYJzT9EjqjRm0uN/h0oXxPhNfPYqeFbyPXGGxzaYUz6zx3qTcCAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBS+tjPyu6tZ/h5GsyLvyz1H+FNIWjAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAA4DqAXEsO26j/La7Fgn/Qifit8xuZekqZ57+Ye+sH/hRTbEEjGYrZgsqwR/
# lUUfKCFpbZF8msaZPQJOR4YYUEU8XyjLrn8Y1jCSmoxh9l7tWiSoc/JFBw356JAm
# zGGxeBA2EWSxRuTr1AuZe6nYaN8/wtFkiHcs8gMadxXBs6DxVhyu5YnhLPQkfumK
# m3lFftwE7pieV7f1lskmlgsC6AeSGCzGPZUgCvcH5Tv/Qe9z7bIImSD3SuzhOIwa
# P+eKQTYf67TifyJKkWQSdGfTA6Kcu41k8LB6oPK+MLk1jbxxK5wPqLSL62xjK04S
# BXHEJSEnsFt0zxWkxP/lgej1DxqUnmrYEdkxvzKSHIAqFWSZul/5hI+vJxvFPhsN
# QBEk4cSulDkJQpcdVi/gmf/mHFOYhDBjsa15s4L+2sBil3XV/T8RiR66Q8xYvTLR
# Wxd2dVsrOoCwnsU4WIeiC0JinCv1WLHEh7Qyzr9RSr4kKJLWdpNYLhgjkojTmEkA
# jFO774t3xB7enbvIF0GOsV19xnCUzq9EGKyt0gMuaphKlNjJ+aTpjWMZDGo+GOKs
# np93Hmftml0Syp3F9+M3y+y6WJGUZoIZJq227jDjjEndtpUrh9BdPdVIfVJD/Au8
# 1Rzh05UHAivorQ3Os8PELHIgiOd9TWzbdgmGzcILt/ddVQERMYIHRjCCB0ICAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFZ+j51YCI7pYAAAAAAAVjANBglghkgBZQMEAgEFAKCCBJ8wEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MDIyNzQyWjAvBgkqhkiG9w0BCQQxIgQgFWF0IWiC
# bRCuvNGStRivtipdODD51+XiWMZ/VCCnBtUwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCC2DDMlTaTj8JV3iTg5Xnpe4CSH60143Z+X9o5NBgMMqDB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFZ+j51YCI7pYAAAAAAAVjCCA2EGCyqGSIb3DQEJEAISMYIDUDCCA0yh
# ggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046QTUwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD/c/cpFSqQWYBeXggyRJ2ZbvYEEaBnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5LH50wIhgPMjAyNjA5MDgyMzU4MjFaGA8y
# MDI2MDkwOTIzNTgyMVowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7ksfnQIBADAK
# AgEAAgIotgIB/zAHAgEAAgIcWDAKAgUA7kxxHQIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQCRJZbrXx3mAuxUJUoBhyisQ7lxIyE6rZfXOfJ50piLDFv8KJ40
# CbsSY+AkObstiWjAyKSVmlFxZvKebDLH63VPMe/Vu3pJ9iuQhhm9r1fdgxFTCFkQ
# DIhF3vPbASfHYOjOx7x6ZsnLUPuFmUWlpAx2HdyeRvIwy0nUx8tkzgTLkxg1CbT2
# F33OTWZO9sZ67H4CZ+ak4DwFj09TaZOdVFq9K4hbzQgD/93FcOh8tdNuWGqu+UvR
# 2no+vXN10/KkpMvQJzVC817gJS4Hn4/a7fzTXKkYugOwp1X6NXaBic7Xwr8Eawly
# Rz7cG01QVtwJ0uXG453Leu7vsh7HpsjQN5CgMA0GCSqGSIb3DQEBAQUABIICAAJV
# 2eyT2DspOMIExxqZlsFz0MtDGK8M+Nt6xXsGTiYwYir2EI6MhM7ijn0WdxlG5yJh
# OGODdMSuVtLLbsXhaGCbwFeJLZ/Z2nsXePsMSMibEiOScuejg2S27LXGr6sq43SP
# 2viI9BOYKNiV/BTnSl9CbD3YRsWf8PLbeqi+pPzC4JiwCOUdOaq8dijovNAbxKLI
# HEsd7NItd2CPnCMu9uvQ932UPlvWwPxTseEgSebB5MorZjMipbfhlEGPoQdWcXdA
# LaXiJO6NBkoPjaLJto+fY26rmnVXfwamjYi+CU75h/I0/S/bxnDNSRrFNmdollDp
# Y7UKK/KWHssZMBVfXS/0ejTKLIqYZV4/qLpu30g650WpqhPgbU3YzY9hqly/5ypZ
# rls6Ce7H7P7rFIguiEq2i1swizoXbxO5Amp5lH3ZJqzGxflAUV20VP6f8+FhfRje
# /H9ZZVfk0qTGUDFcBfGO6PW7SeO9ffZtyzc6DDga/wujmOQt9jU5DCMz2sjGtaEo
# SCZlvFEIXERSZfA6IGQXN63VwJoo5mSdALrcr/j2X3cliuTueKYppl6by+mrtpWu
# vpvkqC02OugqB/msLTR3d+nYLzqGWRLOafT+TV0JiAS1pu9jrKUNK5scKEutwycs
# Cu5cI3/jEyA7Rda4K3VEglRhvGhoxEJ5nQcJ2Cjk
# SIG # End signature block
