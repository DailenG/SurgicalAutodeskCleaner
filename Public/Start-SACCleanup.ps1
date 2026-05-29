function Start-SACCleanup {
    <#
.SYNOPSIS
    Surgical Autodesk Version Cleanup
    
.DESCRIPTION
    Safely uninstalls specific older versions of Autodesk products without damaging 
    global licensing, ODIS services, or newer installed versions. Designed for 
    enterprise/MSP deployment to prune technical debt from CAD/BIM workstations.

    By default, it utilizes a dual-channel logging system:
    1. Console Transcript: Captures standard output for immediate review.
    2. Debug Log: Silently captures background IO exceptions to keep the console clean.
    3. Attention Items: A targeted log of critical failures (AttentionItems.txt) created 
       when uninstallation or registry eviction requires manual review.

    Supports robust temporary pathing, falling back to $env:TEMP if C:\temp is unavailable.

.PARAMETER TargetProducts
    An array of string values representing the Autodesk products to target. 
    Matches against the 'DisplayName' in the registry Add/Remove Programs list.
    Wildcards are handled implicitly by the script (e.g., "AutoCAD" targets "*AutoCAD*").

.PARAMETER TargetYears
    An array of integers representing the release years to target.
    
.PARAMETER Silent
    Switch parameter. Bypasses all interactive confirmation prompts. 
    Mandatory for deployment via RMM (e.g., N-Central) or background execution.

.EXAMPLE
    # Scenario 1: The Default Run (Interactive)
    .\Autodesk-Cleanup.ps1
    
    # Behavior: 
    # Prompts for confirmation. Scans for the default array of products (AutoCAD, Revit, 
    # Civil 3D, Inventor, etc.) matching years 2015 through 2023.

.EXAMPLE
    # Scenario 2: RMM Silent Deployment (Default Targeting)
    .\Autodesk-Cleanup.ps1 -Silent
    
    # Behavior: 
    # Bypasses the confirmation prompt. Ideal for an N-Central scheduled task 
    # cleaning up legacy tech debt across a tenant.

.EXAMPLE
    # Scenario 3: Surgical Single-Product Strike
    .\Autodesk-Cleanup.ps1 -TargetProducts "Revit" -TargetYears 2021
    
    # Behavior: 
    # Only searches for and removes "Revit 2021". Ignores AutoCAD, ignores Revit 2022.

.EXAMPLE
    # Scenario 4: Aggressive AEC Legacy Sweep (Silent)
    .\Autodesk-Cleanup.ps1 -TargetProducts "AutoCAD", "Civil 3D", "Navisworks", "ReCap" -TargetYears 2015, 2016, 2017, 2018 -Silent
    
    # Behavior: 
    # Silently targets a specific cluster of products for a defined range of older years.

.EXAMPLE
    # Scenario 5: Targeted Manufacturing Suite Cleanup
    .\Autodesk-Cleanup.ps1 -TargetProducts "Inventor", "Vault Professional Client", "3ds Max" -TargetYears 2020, 2021
    
    # Behavior: 
    # Cleans up specific manufacturing and rendering tools for 2020 and 2021.
#>
    [CmdletBinding()]
    param (
        [string[]]$TargetProducts = @(
            "AutoCAD", 
            "AutoCAD LT",
            "DWG TrueView",
            "Revit", 
            "Advance Steel", 
            "Autodesk Material Library", 
            "Civil 3D",
            "Inventor",
            "Navisworks Manage",
            "Navisworks Freedom",
            "Navisworks Simulate",
            "ReCap",
            "3ds Max",
            "Maya",
            "Vault Professional Client",
            "Vault Basic Client",
            "Vault",
            "InfraWorks",
            "Forma Site Design",
            "Autodesk Docs",
            "Fusion",
            "Alias",
            "Moldflow",
            "Modlflow",
            "Netfabb",
            "Autodesk Construction Cloud",
            "SketchUp Import"
        ),
        [int[]]$TargetYears = (2015..2023),
        [string[]]$AdditionalVendors = @(),
        [switch]$AnyVendor,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()
    $script:SACLockedItems = [System.Collections.Generic.List[string]]::new()

    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "*adsk*", "AdskAccess*", "AdskLicensing*", "AdskSSO*", "GenuineService*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*", "DesktopConnector*", "fusion*", "alias*", "vault*", "moldflow*", "modlflow*", "netfabb*")

    # --- Logging Setup ---
    $ToDate = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskCleanup_$($ToDate)"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

    $TranscriptLog = "$($LogDir)\CleanupTranscript.log"
    $DebugLog = "$($LogDir)\CleanupDebug.log"

    Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null

    # --- Helper Functions (Centralized in Private\Invoke-SACLogger.ps1) ---

    function Invoke-SurgicalDirectoryCleanup {
        param ([string]$ProductName, [string]$Version)
    
        $SafePathsToSearch = @(
            "$($env:ProgramFiles)\Autodesk",
            "$(${env:ProgramFiles(x86)})\Autodesk",
            "$($env:ProgramData)\Autodesk",
            "$($env:ProgramData)",
            "$($env:PUBLIC)\Documents\Autodesk",
            "C:\Users\*\AppData\Local",
            "C:\Users\*\AppData\Roaming"
        )

        $SearchPattern = "*$($ProductName)*$($Version)*"

        foreach ($basePath in $SafePathsToSearch) {
            if (Test-Path $basePath) {
                Get-ChildItem -Path $basePath -Filter $SearchPattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $fp = $_.FullName
                    $purgeResult = Invoke-SACRobocopyPurge -TargetPath $fp
                    
                    if (-not $purgeResult.Success) {
                        Write-SACQuietLog "Failed to fully remove directory $fp (files likely locked)."
                        
                        $failReason = "Files are locked/in-use."
                        if ($purgeResult.LockedItems.Count -gt 0) {
                            $failReason += " Locked Items: $($purgeResult.LockedItems -join ', ')"
                        }
                        
                        $script:SACFailures += [PSCustomObject]@{ Component = "Directory Purge (Partial): $fp"; Reason = $failReason }
                        
                        if ($purgeResult.LockedItems.Count -gt 0) {
                            Write-SACMsg "  Queuing $($purgeResult.LockedItems.Count) locked item(s) for deletion on reboot." "Warning"
                            Invoke-SACPendingDelete -Paths $purgeResult.LockedItems
                            foreach ($lockedPath in $purgeResult.LockedItems) {
                                if (-not $script:SACLockedItems.Contains($lockedPath)) { $script:SACLockedItems.Add($lockedPath) }
                            }
                        }
                    } else {
                        Write-SACMsg "Purged orphaned directory: $fp" "Success"
                    }
                }
            }
        }
    }

    function Invoke-SACShortcutCleanup {
        param ([string]$ProductName, [string]$Version)

        $ShortcutLocations = @(
            "$($env:Public)\Desktop",
            "C:\Users\*\Desktop",
            "C:\Users\*\OneDrive\Desktop",
            "$($env:ProgramData)\Microsoft\Windows\Start Menu\Programs",
            "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        )

        $Shell = New-Object -ComObject WScript.Shell
        $AutodeskPath = "$($env:ProgramFiles)\Autodesk"
        $AutodeskPathX86 = "$(${env:ProgramFiles(x86)})\Autodesk"
        $SearchPattern = "*$($ProductName)*$($Version)*"

        foreach ($loc in $ShortcutLocations) {
            # Resolve wildcards for user profiles
            $resolved = if ($loc -match '\*') { Resolve-Path $loc -ErrorAction SilentlyContinue } else { ,$loc }
            
            foreach ($path in $resolved) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -Filter "*.lnk" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                        $isMatch = $false
                        $lnkBore = $_
                        
                        # Match 1: Name pattern (classic)
                        if ($lnkBore.Name -like "*$SearchPattern*") {
                            $isMatch = $true
                        }
                        else {
                            # Match 2: Target path (deep inspection)
                            try {
                                $shortcut = $Shell.CreateShortcut($lnkBore.FullName)
                                $target = $shortcut.TargetPath
                                if ($target -like "$AutodeskPath$SearchPattern*" -or $target -like "$AutodeskPathX86$SearchPattern*") {
                                    $isMatch = $true
                                }
                            } catch {
                                Write-SACQuietLog "Failed to inspect shortcut target for $($lnkBore.FullName)"
                            }
                        }

                        if ($isMatch) {
                            try {
                                Remove-Item $lnkBore.FullName -Force -ErrorAction Stop
                                Write-SACMsg "Removed shortcut: $($lnkBore.Name)" "Success"
                            } catch {
                                Write-SACQuietLog "Failed to remove shortcut $($lnkBore.FullName): $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Tier Classification
    # ---------------------------------------------------------------------------
    # Tier 1 - Primary products: full uninstall, processed first
    # Tier 2 - Service packs / updates: skip uninstall if parent succeeded; evict only
    # Tier 3 - Add-ons / extensions: skip uninstall if parent succeeded; evict only
    # Tier 4 - Shared components: full uninstall, processed last
    # ---------------------------------------------------------------------------
    $Tier2Pattern = 'Service Pack|\bSP\d\b|Hotfix|Patch|Update \d|Security Update'
    $Tier3Pattern = 'Language Pack|Object Enabler|Add-[Ii]n|Plugin|Extension|' +
                    'Content Library|Content Core|Content Essential|Content Basic|' +
                    'Material Library Base|Material Library Low|Material Library Medium|Material Library High|' +
                    'Sample|Template|Documentation|DWG TrueView|' +
                    'Colorbooks|Color Books|Unit Schemas|MEP Content|MEP Metric|MEP Imperial|' +
                    'Revit Content|Batch Print|eTransmit|Worksharing Monitor|DB Link|Model Review|' +
                    'BIM Interoperability|Cloud Models|Issues Addon|Robot Structural Analysis Extension|' +
                    'OpenStudio CLI'
    $Tier4Pattern = 'Shared Component|Collaboration for Revit|Desktop Connector|Desktop App|Single Sign|Autodesk Access|Autodesk Identity|Genuine Service'

    function Get-SACTier {
        param ([string]$DisplayName)
        if ($DisplayName -match $Tier2Pattern) { return 2 }
        if ($DisplayName -match $Tier3Pattern) { return 3 }
        if ($DisplayName -match $Tier4Pattern) { return 4 }
        return 1
    }

    # ---------------------------------------------------------------------------
    # Core uninstall engine: executes a single pre-classified entry
    # ---------------------------------------------------------------------------
    function Invoke-SACUninstallEntry {
        param (
            [object]$App
        )

        $ProductCode    = $App.PSChildName
        $DisplayName    = $App.DisplayName
        $QuietUninstallString = $App.QuietUninstallString
        $UninstallString = if (-not [string]::IsNullOrWhiteSpace($QuietUninstallString)) { $QuietUninstallString } else { $App.UninstallString }
        $MsiLogFile     = "$LogDir\$($DisplayName -replace '[\\/:*?"<>|]', '')_Uninstall.log"

        Write-SACMsg "Uninstalling: $DisplayName" "Warning"

        $Process = $null
        if ($ProductCode -match '^{.*}$') {
            # Robust MSI detection: case-insensitive, handles quotes and paths
            if ($UninstallString -match 'msiexec\.exe') {
                Write-SACMsg "  [MSI] $DisplayName" "Info"
                $Process = Start-Process "msiexec.exe" -ArgumentList "/x $ProductCode /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable /L*v `"$MsiLogFile`"" -PassThru -WindowStyle Hidden
            } else {
                Write-SACMsg "  [Custom-MSI] $DisplayName" "Info"
                $Process = Invoke-SACCustomUninstall -App $App -UninstallString $UninstallString
            }
        } else {
            # Non-GUID entry - attempt custom uninstall path
            $Process = Invoke-SACCustomUninstall -App $App -UninstallString $UninstallString
        }

        if ($null -ne $Process) {
            Watch-SACProcessTree -RootProcess $Process -DisplayName $DisplayName -TimeoutMinutes 20 -IdleTimeoutMinutes 5 -TailLogFile $MsiLogFile
            Write-SACMsg "  Exit code $($Process.ExitCode): $DisplayName" "Info"
            # Kill licensing/SSO subprocesses spawned by the uninstaller that run outside its process tree
            foreach ($spawnedProc in @("AdskLicensing*", "AdskSSO*")) {
                Get-Process -Name $spawnedProc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            $safeExitCodes = @(0, 3010, 1605, 1614, 1646, 7)
            if ($Process.ExitCode -notin $safeExitCodes) {
                $script:SACFailures += [PSCustomObject]@{ Component = "Uninstall: $DisplayName"; Reason = "Exit Code $($Process.ExitCode)" }
            } else {
                Write-SACQuietLog "  Safe exit code $($Process.ExitCode) for: $DisplayName"
            }
        }

        # Evict the registry key. If it is already gone the uninstaller
        # cleaned up after itself, which is the ideal outcome - not a failure.
        if (Test-Path $App.PSPath) {
            try {
                Remove-Item $App.PSPath -Recurse -Force -ErrorAction Stop
                Write-SACMsg "  Evicted registry key: $DisplayName" "Success"
            } catch {
                Write-SACQuietLog "Failed to evict registry key for $DisplayName ($($App.PSPath)): $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component = "Registry Eviction: $DisplayName"; Reason = $_.Exception.Message }
            }
        } else {
            Write-SACMsg "  Registry key already removed (self-cleaned): $DisplayName" "Success"
            Write-SACQuietLog "Eviction skipped - key not found (uninstaller self-cleaned): $($App.PSPath)"
        }
    }

    function Invoke-SACCustomUninstall {
        param (
            [object]$App,
            [string]$UninstallString
        )
        $DisplayName     = $App.DisplayName
        if ([string]::IsNullOrWhiteSpace($UninstallString)) {
            Write-SACQuietLog "No UninstallString for $DisplayName. Skipping."
            return
        }
        $ExePath  = ''
        $ArgPart  = ''
        if ($UninstallString -match '^"([^"]+)"(.*)$')    { $ExePath = $Matches[1]; $ArgPart = $Matches[2].Trim() }
        elseif ($UninstallString -match '^(.*\.exe)(.*)$') { $ExePath = $Matches[1].Trim(); $ArgPart = $Matches[2].Trim() }
        else                                               { $ExePath = $UninstallString }

        if ([string]::IsNullOrWhiteSpace($ExePath)) {
            Write-SACQuietLog "Could not parse exe path for $DisplayName. Skipping."
            return
        }

        # If it's MSIExec, we MUST avoid non-MSI flags like --silent or --mode
        $isMsi = ($ExePath -match 'msiexec\.exe')
        $FullArgs = if ($isMsi) {
            "$ArgPart /qn /quiet /norestart".Trim()
        } else {
            "$ArgPart --silent /qn /quiet /norestart --mode unattended".Trim()
        }

        try {
            # Use cmd /c with NUL redirection to discourage interactive prompts from hanging the process.
            # We still use Start-Process -PassThru to get the PID for the Supervisor.
            $cmdArgs = "/c `"`"$ExePath`" $FullArgs < NUL`""
            Write-SACQuietLog "Executing custom uninstall for ${DisplayName}: cmd.exe $cmdArgs"
            $Process = Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
            return $Process
        } catch {
            $msg = $_.Exception.Message
            # If the installer exe itself is gone the product was already removed - not a failure
            if ($_.Exception -is [System.ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -in @(2, 3)) {
                Write-SACMsg "  Installer not found (already removed): $DisplayName" "Info"
                Write-SACQuietLog "Installer exe not found for $($DisplayName) - treating as already removed."
            } else {
                Write-SACQuietLog "Failed to launch uninstaller for $($DisplayName): $msg"
                Write-SACMsg "  Launch failed for $DisplayName (see Debug Log)" "Error"
                $script:SACFailures += [PSCustomObject]@{ Component = "Uninstaller Launch: $DisplayName"; Reason = $msg }
            }
        }
    }

    # ---------------------------------------------------------------------------
    # Main function: scan, classify, sort by tier, smart-execute
    # ---------------------------------------------------------------------------
    function Invoke-UninstallAutodeskProduct {
        param ([string]$ProductName, [string]$Version)

        $PackageName = "*$ProductName*$Version*"

        $vendorPattern = '^$'
        if (-not $AnyVendor) {
            $vendors = @('Autodesk')
            if ($AdditionalVendors) { $vendors += $AdditionalVendors }
            $vendorPattern = ($vendors | ForEach-Object { [regex]::Escape($_) }) -join '|'
        }

        $regPaths = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        $AllKeys = @()
        foreach ($path in $regPaths) {
            if (Test-Path $path) {
                Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                    $dn = $_.GetValue("DisplayName")
                    $pb = $_.GetValue("Publisher")
                    
                    if ($null -ne $dn -and $dn -like $PackageName) {
                        if ($AnyVendor -or ($null -ne $pb -and $pb -match $vendorPattern) -or ($dn -match $vendorPattern)) {
                            $AllKeys += [PSCustomObject]@{
                                DisplayName          = $dn
                                Publisher            = $pb
                                UninstallString      = $_.GetValue("UninstallString")
                                QuietUninstallString = $_.GetValue("QuietUninstallString")
                                InstallLocation      = $_.GetValue("InstallLocation")
                                PSChildName          = $_.PSChildName
                                PSPath               = $_.PSPath
                            }
                        }
                    }
                }
            }
        }

        if (-not $AllKeys) {
            Write-SACQuietLog "No registry match for $ProductName $Version."
            return
        }

        # Stop AdskAccessService if running to prevent file locks during directory purge
        $AccessSvc = Get-Service -Name "AdskAccessService" -ErrorAction SilentlyContinue
        if ($AccessSvc -and $AccessSvc.Status -eq "Running") {
            Write-SACMsg "Stopping AdskAccessService to prevent file locks..." "Info"
            try { Stop-Service -Name "AdskAccessService" -Force -ErrorAction Stop } catch { Write-SACQuietLog "Failed to stop AdskAccessService: $($_.Exception.Message)" }
        }

        # Kill running processes before we start
        foreach ($procName in $ProcessesToKill) {
            try { Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop }
            catch { Write-SACQuietLog "Could not stop process $procName`: $($_.Exception.Message)" }
        }

        # Classify and annotate each entry
        $Classified = $AllKeys | ForEach-Object {
            [PSCustomObject]@{ App = $_; Tier = (Get-SACTier -DisplayName $_.DisplayName) }
        }

        $Tier1 = @($Classified | Where-Object { $_.Tier -eq 1 })
        $Tier2 = @($Classified | Where-Object { $_.Tier -eq 2 })
        $Tier3 = @($Classified | Where-Object { $_.Tier -eq 3 })
        $Tier4 = @($Classified | Where-Object { $_.Tier -eq 4 })

        $total = $Classified.Count
        $skippable = $Tier2.Count + $Tier3.Count
        Write-SACMsg "Found $total component(s) for $($ProductName) $($Version): $($Tier1.Count) primary, $skippable update/addon(s), $($Tier4.Count) shared." "Info"

        # --- Tier 1: Primary products (full uninstall) ---
        $tier1Succeeded = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($item in $Tier1) {
            Invoke-SACUninstallEntry -App $item.App
            # Track parent product names for Tier 2/3 skip logic
            $baseName = $item.App.DisplayName -replace $Tier2Pattern,'' -replace $Tier3Pattern,'' -replace $Tier4Pattern,'' -replace '\s+', ' '
            $tier1Succeeded.Add($baseName.Trim()) | Out-Null
        }

        # --- Tier 2: Service packs / updates (always evict-only) ---
        # Patch uninstallers require the parent product to be present and add no value once the
        # Tier 1 uninstaller or directory purge has already handled the binaries.
        foreach ($item in $Tier2) {
            $dn = $item.App.DisplayName
            Write-SACMsg "  [EVICT] Skipping patch uninstaller - evicting registry: $dn" "Info"
            try {
                Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                Write-SACMsg "  Evicted: $dn" "Success"
            } catch {
                Write-SACQuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component = "Evict SP/Update: $dn"; Reason = $_.Exception.Message; Severity = 'Warning' }
            }
        }

        # --- Tier 3: Add-ons / extensions ---
        foreach ($item in $Tier3) {
            $dn = $item.App.DisplayName
            $parentFound = $tier1Succeeded.Count -gt 0
            if ($parentFound) {
                Write-SACMsg "  [SKIP uninstall] Parent removed - evicting only: $dn" "Info"
                try {
                    Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                    Write-SACMsg "  Evicted: $dn" "Success"
                } catch {
                    Write-SACQuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component = "Evict Addon: $dn"; Reason = $_.Exception.Message; Severity = 'Warning' }
                }
            } else {
                Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                Invoke-SACUninstallEntry -App $item.App
            }
        }

        # --- Tier 4: Shared components (always full uninstall, last) ---
        foreach ($item in $Tier4) {
            Invoke-SACUninstallEntry -App $item.App
        }

        # Run the surgical sweeps after all uninstallation attempts
        Invoke-SurgicalDirectoryCleanup -ProductName $ProductName -Version $Version
        Invoke-SACShortcutCleanup -ProductName $ProductName -Version $Version
    }

    # --- Execution Block ---
    if (-not (Test-SACRemoteSession)) { Clear-Host }
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " SURGICAL AUTODESK CLEANUP INITIALIZED" "Info"
    Write-SACMsg " Transcript: $($TranscriptLog)" "Info"
    Write-SACMsg " Debug Log:  $($DebugLog)" "Info"
    Write-SACMsg "==========================================" "Info"

    if (Test-SACInteractive -Silent $Silent) {
        $PendingReboot = Test-SACPendingReboot
        if ($PendingReboot) {
            Write-Host "[!] WARNING: A pending reboot is detected on this system." -ForegroundColor Yellow
            $ProceedCleanup = Read-Host "Would you like to proceed with the Cleanup anyway? (y/N)"
            if ($ProceedCleanup.Trim().ToLower() -ne 'y') {
                Write-SACMsg "Execution aborted by user." "Warning"
                Stop-Transcript | Out-Null
                return
            }
        }

        Write-Host "`nTarget Products: $($TargetProducts -join ', ')" -ForegroundColor Cyan
        Write-Host "Target Years: $($TargetYears -join ', ')`n" -ForegroundColor Cyan
        Write-Host "WARNING: This will forcefully remove the specified versions.`n" -ForegroundColor Yellow
        $Response = Read-Host "Type 'YES' to proceed"
        if ($Response -ne "YES") { 
            Write-SACMsg "Execution aborted by user." "Warning"
            Stop-Transcript | Out-Null
            return 
        }
    }
    else {
        Write-SACMsg "Running in non-interactive/silent mode." "Info"
        if (Test-SACPendingReboot) {
            Write-SACMsg "WARNING: A pending system reboot has been detected." "Warning"
        }
    }

    Write-SACMsg "Processing $($TargetProducts.Count) product(s) across $($TargetYears.Count) year(s)..." "Info"
    foreach ($year in ($TargetYears | Sort-Object)) {
        foreach ($product in $TargetProducts) {
            Invoke-UninstallAutodeskProduct -ProductName $product -Version $year.ToString()
        }
    }

    # Wipe specific Autodesk temp files and directories
    Invoke-SACTempAutodeskCleanup

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " CLEANUP COMPLETED in $($ElapsedTime)" "Success"
    Write-SACMsg "==========================================" "Info"

    $criticals = @($script:SACFailures | Where-Object { $_.Severity -ne 'Warning' })
    $warnings   = @($script:SACFailures | Where-Object { $_.Severity -eq 'Warning' })

    if ($criticals.Count -gt 0) {
        Write-Host "`n[!] FAILURES REQUIRING ATTENTION:" -ForegroundColor Red
        Write-Host "    (Note: These items may have been forcibly evicted/removed despite errors)" -ForegroundColor Gray
        foreach ($fail in $criticals) {
            Write-Host "   - $($fail.Component)" -ForegroundColor Yellow
            Write-Host "     Reason: $($fail.Reason)" -ForegroundColor DarkGray
        }
        Write-Host "`nReview the Debug Log for diagnostics or resolve locks manually.`n" -ForegroundColor Red
    }

    if ($warnings.Count -gt 0) {
        Write-Host "`n[~] MINOR NOTICES ($($warnings.Count) item(s) - likely moot after parent removal):" -ForegroundColor DarkYellow
        foreach ($fail in $warnings) {
            Write-Host "   - $($fail.Component)" -ForegroundColor DarkGray
        }
        Write-Host "    See Debug Log for details. These are typically benign.`n" -ForegroundColor DarkGray
    }

    if ($criticals.Count -eq 0 -and $warnings.Count -eq 0) {
        Write-Host "`n[*] All operations completed successfully with no failures.`n" -ForegroundColor Green
    } elseif ($criticals.Count -eq 0) {
        Write-Host "`n[*] Primary operations succeeded. $($warnings.Count) minor notice(s) logged.`n" -ForegroundColor Green
    }

    # Register post-logon cleanup script for any files that could not be deleted
    if ($script:SACLockedItems.Count -gt 0) {
        if (Test-SACInteractive -Silent $Silent) {
            Write-Host "`n[!] $($script:SACLockedItems.Count) file(s) queued for OS-level deletion on next reboot." -ForegroundColor Yellow
            $resp = Read-Host "    Also register a post-logon PowerShell cleanup script for redundancy? (y/N)"
            if ($resp.Trim().ToLower() -eq 'y') {
                $registered = Register-SACPostRebootCleanup -Paths $script:SACLockedItems.ToArray()
                Write-Host "    $(if ($registered) { '[OK] Post-logon cleanup script registered.' } else { '[!] Registration failed.' })" -ForegroundColor $(if ($registered) { 'Green' } else { 'Red' })
            }
        } else {
            Register-SACPostRebootCleanup -Paths $script:SACLockedItems.ToArray() | Out-Null
            Write-SACMsg "Post-logon cleanup script registered for $($script:SACLockedItems.Count) locked item(s)." "Info"
        }
    }

    # Persist outcome so the interactive menu can show a status badge on return
    $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
    if ($criticals.Count -gt 0) {
        $content = @(
            "SURGICAL AUTODESK CLEANER - ITEMS REQUIRING ATTENTION",
            "Timestamp: $(Get-Date)",
            "Log Directory: $LogDir",
            "Note: Despite the errors below, these components may have been forcibly",
            "evicted or surgically removed from the system by the SAC engine.",
            "----------------------------------------------------------",
            ""
        )
        foreach ($fail in $criticals) {
            $content += "[!] $($fail.Component)"
            $content += "    Reason: $($fail.Reason)"
            $content += ""
        }
        $content | Out-File -FilePath $AttentionFile -Encoding utf8
    }

    $script:SACLastRunStatus = [PSCustomObject]@{
        Operation      = 'Cleanup'
        Criticals      = $criticals.Count
        Warnings       = $warnings.Count
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($criticals.Count -gt 0) { $AttentionFile } else { $null }
    }

    Stop-Transcript | Out-Null
    return $script:SACLastRunStatus
}
