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

.NOTES
    Add/Remove Programs entries are evicted only after the product's Windows Installer
    registration is confirmed gone. An uninstaller that returns 3010 ends the run so the
    reboot can complete the MSI transaction before anything else is removed.
    Supports -WhatIf for a non-destructive preview of every action.
#>
    [CmdletBinding(SupportsShouldProcess)]
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
    $IsPreview = [bool]$WhatIfPreference
    $script:SACFailures = @()
    $script:SACLockedItems = [System.Collections.Generic.List[string]]::new()
    $script:SACResidueReport = $null
    Reset-SACEvictionState
    $script:SACHiddenInstallerProductCodes = @()
    $script:SACHiddenInstallerProductStateCodes = @()
    $script:SACHiddenInstallerComponentRefsRemoved = 0
    $script:SACHiddenInstallerUpgradeRefsRemoved = 0
    $script:SACHiddenInstallerOdisFoldersRenamed = 0
    $script:SACHiddenInstallerSeedKeys = @()

    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "*adsk*", "AdskAccess*", "AdskLicensing*", "AdskSSO*", "GenuineService*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*", "DesktopConnector*", "fusion*", "alias*", "vault*", "moldflow*", "modlflow*", "netfabb*")

    # --- Logging Setup ---
    $ToDate = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskCleanup_$($ToDate)"
    # -WhatIf:$false - a preview is exactly when the audit trail matters, so the run
    # folder and transcript are always created.
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null

    $TranscriptLog = "$($LogDir)\CleanupTranscript.log"
    $DebugLog = "$($LogDir)\CleanupDebug.log"

    Start-Transcript -Path $TranscriptLog -Append -Force -WhatIf:$false | Out-Null
    if ($IsPreview) { Write-SACMsg " PREVIEW (-WhatIf): no changes will be made." "Warning" }

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
                    if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $fp -Action 'Purge directory')) { return }
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

                        if ($isMatch -and (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $lnkBore.FullName -Action 'Remove shortcut')) {
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

    function Add-SACHiddenInstallerCleanupSummary {
        param([object]$Result)

        foreach ($code in @($Result.HiddenMsiProductCodes)) {
            if ($code -and $script:SACHiddenInstallerProductCodes -notcontains $code) {
                $script:SACHiddenInstallerProductCodes += $code
            }
        }

        foreach ($code in @($Result.ProductStateInstalledCodes)) {
            if ($code -and $script:SACHiddenInstallerProductStateCodes -notcontains $code) {
                $script:SACHiddenInstallerProductStateCodes += $code
            }
        }

        $script:SACHiddenInstallerComponentRefsRemoved += [int]$Result.ComponentRefsRemoved
        $script:SACHiddenInstallerUpgradeRefsRemoved += [int]$Result.UpgradeCodeRefsRemoved
        $script:SACHiddenInstallerOdisFoldersRenamed += [int]$Result.OdisFoldersRenamed
    }

    function Add-SACHiddenInstallerDiscoverySummary {
        param([object]$State)

        foreach ($product in @($State.HiddenProducts | Where-Object { $_.ProductCode })) {
            if ($script:SACHiddenInstallerProductCodes -notcontains $product.ProductCode) {
                $script:SACHiddenInstallerProductCodes += $product.ProductCode
            }
        }

        foreach ($stateItem in @($State.ProductStates | Where-Object { $_.IsInstalled })) {
            if ($script:SACHiddenInstallerProductStateCodes -notcontains $stateItem.ProductCode) {
                $script:SACHiddenInstallerProductStateCodes += $stateItem.ProductCode
            }
        }
    }

    function Write-SACHiddenInstallerFinding {
        param([object]$State)

        foreach ($stateItem in @($State.ProductStates | Where-Object { $_.IsInstalled })) {
            Write-SACMsg "  [MSI ProductState=5] $($stateItem.ProductCode) still reports installed." "Warning"
            Write-SACQuietLog "MSI ProductState=5 for $($stateItem.ProductCode) packed=$($stateItem.PackedCode)"
        }

        foreach ($warning in @($State.RelativePathWarnings)) {
            Write-SACMsg "  [WARN] Relative installer path: $($warning.PropertyName)=$($warning.Value)" "Warning"
            Write-SACQuietLog "Relative installer path in $($warning.SourcePath): $($warning.PropertyName)=$($warning.Value)"
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

        if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $DisplayName -Action 'Uninstall')) { return }

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

        $ExitCode = $null
        if ($null -ne $Process) {
            Watch-SACProcessTree -RootProcess $Process -DisplayName $DisplayName -TimeoutMinutes 20 -IdleTimeoutMinutes 5 -TailLogFile $MsiLogFile
            $ExitCode = $Process.ExitCode
            Write-SACMsg "  Exit code $($ExitCode): $DisplayName" "Info"
            # Kill licensing/SSO subprocesses spawned by the uninstaller that run outside its process tree
            foreach ($spawnedProc in @("AdskLicensing*", "AdskSSO*")) {
                Get-Process -Name $spawnedProc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            $safeExitCodes = @(0, 3010, 1605, 1614, 1646, 7)
            if ($ExitCode -notin $safeExitCodes) {
                $script:SACFailures += [PSCustomObject]@{ Component = "Uninstall: $DisplayName"; Reason = "Exit Code $($ExitCode)" }
            } else {
                Write-SACQuietLog "  Safe exit code $($ExitCode) for: $DisplayName"
            }
        }

        # The ARP key is only a projection of the installer hives. Evicting it while the
        # product is still registered (3010 pending reboot, or a failed 1603) hides a live
        # MSI registration from every ARP-driven tool, so the decision is made against the
        # registration itself.
        Invoke-SACArpEviction -App $App -ExitCode $ExitCode -Cmdlet $PSCmdlet | Out-Null
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
                            $appKey = [PSCustomObject]@{
                                DisplayName          = $dn
                                DisplayVersion       = $_.GetValue("DisplayVersion")
                                Publisher            = $pb
                                UninstallString      = $_.GetValue("UninstallString")
                                QuietUninstallString = $_.GetValue("QuietUninstallString")
                                InstallLocation      = $_.GetValue("InstallLocation")
                                InstallSource        = $_.GetValue("InstallSource")
                                LocalPackage         = $_.GetValue("LocalPackage")
                                PSChildName          = $_.PSChildName
                                PSPath               = $_.PSPath
                            }
                            $AllKeys += $appKey
                            $script:SACHiddenInstallerSeedKeys += $appKey
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
        if ($AccessSvc -and $AccessSvc.Status -eq "Running" -and (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'AdskAccessService' -Action 'Stop service')) {
            Write-SACMsg "Stopping AdskAccessService to prevent file locks..." "Info"
            try { Stop-Service -Name "AdskAccessService" -Force -ErrorAction Stop } catch { Write-SACQuietLog "Failed to stop AdskAccessService: $($_.Exception.Message)" }
        }

        # Kill running processes before we start
        if (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'Autodesk processes' -Action 'Terminate') {
            foreach ($procName in $ProcessesToKill) {
                try { Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop }
                catch { Write-SACQuietLog "Could not stop process $procName`: $($_.Exception.Message)" }
            }
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
            if ($script:SACRebootRequired) { break }
            Invoke-SACUninstallEntry -App $item.App
            # Track parent product names for Tier 2/3 skip logic
            $baseName = $item.App.DisplayName -replace $Tier2Pattern,'' -replace $Tier3Pattern,'' -replace $Tier4Pattern,'' -replace '\s+', ' '
            $tier1Succeeded.Add($baseName.Trim()) | Out-Null
        }
        if ($script:SACRebootRequired) { return }

        # --- Tier 2: Service packs / updates (evict-only when the registration is gone) ---
        # Patch uninstallers require the parent product to be present and add no value once the
        # Tier 1 uninstaller or directory purge has already handled the binaries. The eviction
        # itself still has to clear the installer hives, or an orphaned patch registration is
        # left behind and later installs fail with 1647.
        foreach ($item in $Tier2) {
            if ($script:SACRebootRequired) { break }
            $dn = $item.App.DisplayName
            Write-SACMsg "  [EVICT] Skipping patch uninstaller - checking registration: $dn" "Info"
            Invoke-SACArpEviction -App $item.App -Cmdlet $PSCmdlet | Out-Null
        }
        if ($script:SACRebootRequired) { return }

        # --- Tier 3: Add-ons / extensions ---
        foreach ($item in $Tier3) {
            if ($script:SACRebootRequired) { break }
            $dn = $item.App.DisplayName
            $parentFound = $tier1Succeeded.Count -gt 0
            if ($parentFound) {
                Write-SACMsg "  [SKIP uninstall] Parent removed - checking registration before eviction: $dn" "Info"
                Invoke-SACArpEviction -App $item.App -Cmdlet $PSCmdlet | Out-Null
            } else {
                Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                Invoke-SACUninstallEntry -App $item.App
            }
        }
        if ($script:SACRebootRequired) { return }

        # --- Tier 4: Shared components (always full uninstall, last) ---
        foreach ($item in $Tier4) {
            if ($script:SACRebootRequired) { break }
            Invoke-SACUninstallEntry -App $item.App
        }
        if ($script:SACRebootRequired) { return }

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
            foreach ($reason in (Get-SACPendingRebootReason)) { Write-Host "    - $reason" -ForegroundColor DarkYellow }
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
            Write-SACMsg "WARNING: A pending system reboot has been detected: $((Get-SACPendingRebootReason) -join '; ')" "Warning"
        }
    }

    Write-SACMsg "Processing $($TargetProducts.Count) product(s) across $($TargetYears.Count) year(s)..." "Info"
    foreach ($year in ($TargetYears | Sort-Object)) {
        foreach ($product in $TargetProducts) {
            Invoke-UninstallAutodeskProduct -ProductName $product -Version $year.ToString()
            if ($script:SACRebootRequired) { break }
        }
        if ($script:SACRebootRequired) { break }
    }

    # A 3010 means the MSI transaction is incomplete. Rewriting the installer hives or
    # sweeping files while it is outstanding is what turns a pending reboot into an
    # unrepairable product, so the remaining phases are skipped.
    if ($script:SACRebootRequired) {
        Write-SACMsg "Reboot barrier reached - skipping hidden installer-state cleanup and temp sweeps." "Warning"
    } else {
        Write-SACMsg "Scanning hidden MSI installer-state and ODIS remnants for selected targets..." "Info"
        $hiddenState = Get-SACHiddenInstallerState -TargetProducts $TargetProducts -TargetYears ($TargetYears | ForEach-Object { $_.ToString() }) -UninstallKeys ($script:SACHiddenInstallerSeedKeys | Select-Object -Unique *)
        $hasHiddenInstallerState = (
            $hiddenState.Summary.HiddenMsiProducts -gt 0 -or
            $hiddenState.Summary.ProductStateInstalled -gt 0 -or
            $hiddenState.Summary.ComponentReferences -gt 0 -or
            $hiddenState.Summary.UpgradeCodeReferences -gt 0 -or
            $hiddenState.Summary.OdisRemnants -gt 0 -or
            $hiddenState.Summary.RelativePathWarnings -gt 0
        )

        if ($hasHiddenInstallerState) {
            Write-SACMsg "Found hidden installer-state: $($hiddenState.Summary.HiddenMsiProducts) hidden MSI product(s), $($hiddenState.Summary.ProductStateInstalled) ProductState=5, $($hiddenState.Summary.ComponentReferences) component ref(s), $($hiddenState.Summary.UpgradeCodeReferences) upgrade ref(s), $($hiddenState.Summary.OdisRemnants) ODIS remnant(s)." "Info"
            Add-SACHiddenInstallerDiscoverySummary -State $hiddenState
            Write-SACHiddenInstallerFinding -State $hiddenState
            if (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'Hidden MSI installer-state and ODIS remnants' -Action 'Clean up') {
                $hiddenCleanupResult = Invoke-SACHiddenInstallerStateCleanup -State $hiddenState -LogDir $LogDir
                Add-SACHiddenInstallerCleanupSummary -Result $hiddenCleanupResult
            }
        } else {
            Write-SACQuietLog "No hidden MSI installer-state or ODIS remnants matched the selected targets."
        }

        # Wipe specific Autodesk temp files and directories
        if (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'Autodesk temp files' -Action 'Delete') {
            Invoke-SACTempAutodeskCleanup
        }

        # Entries whose eviction was refused earlier may be evictable now that the hidden
        # installer-state cleanup has run.
        Invoke-SACDeferredArpEviction -Cmdlet $PSCmdlet
    }

    # Verification reads the installer hives, not Add/Remove Programs. An ARP-driven rescan
    # cannot see a product it has just orphaned.
    Write-SACMsg "Verifying Windows Installer hives for orphaned registrations..." "Info"
    $Residue = Get-SACInstallerResidue
    $script:SACResidueReport = Write-SACInstallerResidueReport -Residue $Residue -LogDir $LogDir
    foreach ($orphan in $Residue.OrphanedProducts) {
        $label = if ([string]::IsNullOrWhiteSpace($orphan.DisplayName)) { $orphan.ProductCode } else { $orphan.DisplayName }
        $script:SACFailures += [PSCustomObject]@{ Component = "Installer residue (product): $label"; Reason = "Registered in $($orphan.Hives -join ', ') with no Add/Remove Programs entry" }
    }
    foreach ($orphan in $Residue.OrphanedPatches) {
        $label = if ([string]::IsNullOrWhiteSpace($orphan.DisplayName)) { $orphan.PatchCode } else { $orphan.DisplayName }
        $script:SACFailures += [PSCustomObject]@{ Component = "Installer residue (patch): $label"; Reason = "Registered in $($orphan.Hives -join ', ') but linked to zero products" }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-SACMsg "==========================================" "Info"
    if ($script:SACRebootRequired) {
        Write-SACMsg " CLEANUP HALTED after $($ElapsedTime) - REBOOT REQUIRED" "Warning"
    } else {
        Write-SACMsg " CLEANUP COMPLETED in $($ElapsedTime)" "Success"
    }
    Write-SACMsg "==========================================" "Info"

    if ($script:SACRebootRequired) {
        Write-Host "`n[!] REBOOT REQUIRED - the cleanup stopped before completing." -ForegroundColor Yellow
        Write-Host "    An uninstaller returned 3010 (ERROR_SUCCESS_REBOOT_REQUIRED). Windows Installer" -ForegroundColor Gray
        Write-Host "    keeps the product registered until the reboot finishes the transaction, so the" -ForegroundColor Gray
        Write-Host "    Add/Remove Programs entry was kept and no further removal was attempted:" -ForegroundColor Gray
        foreach ($blocker in $script:SACRebootBlockers) {
            Write-Host "      - $blocker" -ForegroundColor Yellow
        }
        Write-Host "    Reboot, then re-run the cleanup to finish and re-verify.`n" -ForegroundColor Gray

        if ((Test-SACInteractive -Silent $Silent) -and -not $IsPreview) {
            $RebootResp = Read-Host "    Reboot now? (y/N)"
            if ($RebootResp.Trim().ToLower() -eq 'y' -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart computer')) {
                Restart-Computer -Force
            }
        }
    }

    $criticals = @($script:SACFailures | Where-Object { $_.Severity -ne 'Warning' })
    $warnings   = @($script:SACFailures | Where-Object { $_.Severity -eq 'Warning' })

    if ($criticals.Count -gt 0) {
        Write-Host "`n[!] FAILURES REQUIRING ATTENTION:" -ForegroundColor Red
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

    if ($criticals.Count -eq 0 -and $warnings.Count -eq 0 -and -not $script:SACRebootRequired) {
        Write-Host "`n[*] All operations completed successfully with no failures.`n" -ForegroundColor Green
    } elseif ($criticals.Count -eq 0 -and -not $script:SACRebootRequired) {
        Write-Host "`n[*] Primary operations succeeded. $($warnings.Count) minor notice(s) logged.`n" -ForegroundColor Green
    }

    if ($script:SACHiddenInstallerProductCodes.Count -gt 0 -or $script:SACHiddenInstallerProductStateCodes.Count -gt 0 -or $script:SACHiddenInstallerComponentRefsRemoved -gt 0 -or $script:SACHiddenInstallerUpgradeRefsRemoved -gt 0 -or $script:SACHiddenInstallerOdisFoldersRenamed -gt 0) {
        Write-Host "[*] Hidden installer-state cleanup summary:" -ForegroundColor Cyan
        Write-Host "    Hidden MSI products: $($script:SACHiddenInstallerProductCodes.Count)" -ForegroundColor Gray
        Write-Host "    ProductState=5 products: $($script:SACHiddenInstallerProductStateCodes.Count)" -ForegroundColor Gray
        Write-Host "    Component refs removed: $script:SACHiddenInstallerComponentRefsRemoved" -ForegroundColor Gray
        Write-Host "    Upgrade-code refs removed: $script:SACHiddenInstallerUpgradeRefsRemoved" -ForegroundColor Gray
        Write-Host "    ODIS folders renamed: $script:SACHiddenInstallerOdisFoldersRenamed`n" -ForegroundColor Gray
    }

    # Register post-logon cleanup script for any files that could not be deleted
    if ($script:SACLockedItems.Count -gt 0 -and -not $IsPreview) {
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
            "----------------------------------------------------------",
            ""
        )
        if ($script:SACRebootRequired) {
            $content += "[!] REBOOT REQUIRED - the cleanup halted before completing."
            $content += "    Reboot the machine and re-run the cleanup before removing anything else."
            $content += ""
        }
        foreach ($fail in $criticals) {
            $content += "[!] $($fail.Component)"
            $content += "    Reason: $($fail.Reason)"
            $content += ""
        }
        $content | Out-File -FilePath $AttentionFile -Encoding utf8 -WhatIf:$false
    }

    $script:SACLastRunStatus = [PSCustomObject]@{
        Operation      = 'Cleanup'
        Criticals      = $criticals.Count
        Warnings       = $warnings.Count
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($criticals.Count -gt 0) { $AttentionFile } else { $null }
        HiddenMsiProducts = $script:SACHiddenInstallerProductCodes.Count
        ProductStateInstalled = $script:SACHiddenInstallerProductStateCodes.Count
        ComponentRefsRemoved = $script:SACHiddenInstallerComponentRefsRemoved
        UpgradeCodeRefsRemoved = $script:SACHiddenInstallerUpgradeRefsRemoved
        OdisFoldersRenamed = $script:SACHiddenInstallerOdisFoldersRenamed
        RebootRequired = [bool]$script:SACRebootRequired
        RebootBlockers = @($script:SACRebootBlockers)
        InstallerResidue = $Residue.Total
        ResidueReport  = $script:SACResidueReport
    }

    Stop-Transcript | Out-Null
    return $script:SACLastRunStatus
}

# SIG # Begin signature block
# MII9NwYJKoZIhvcNAQcCoII9KDCCPSQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCwBFWlLBPzFJS3
# h0KY8qSDkZgMuzfnwhNkFvSLg03lEKCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggarMIIEk6ADAgECAhMzAAYgdEwI
# qMbC9o3UAAAABiB0MA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwHhcNMjYwOTA4MDM1NTU5WhcNMjYwOTEx
# MDM1NTU5WjBtMQswCQYDVQQGEwJVUzELMAkGA1UECBMCZ2ExETAPBgNVBAcTCEJv
# c3R3aWNrMR4wHAYDVQQKExVSaWNoYXJkIERhaWxlbiBHdW50ZXIxHjAcBgNVBAMT
# FVJpY2hhcmQgRGFpbGVuIEd1bnRlcjCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCC
# AYoCggGBAMaVHw1xEKM/ypHgCoqzRLfs3ifk+jtX1alGru9yVQJl6XNgN3RQboVV
# HGa4/Y4xvsfJKfcfYxr/2EuZM2dpsNmPVwAoLqRn9NrFSvM8EEIviwZjNZPFszwq
# /nWUtCL1odXE6qpca2JXyYtWeGhE8XHP1LxLZ6NaAcBy1aCsliSSt45PjMqLWaw1
# 16YFWiuas9311NDYlxH5+Fz1Tqqo8SEeNioekzo0cJyDBkASuyQcf1LXy22LdNQQ
# WCq6vw6bjjmS1tQZc06X6mMQYQnJdHVwqWSwzXPHtaMSXXApaiyY1SnpztOGNXF0
# Jd4u8TblLFpKmoPDCp3nmv6wHBtBwA60CVnGH0Ga3QTrqDBxUd8o7eEAhup2mOwp
# U/epYC3fKOZhpq8FHnjBoxSKf6oa7LQfe53TwfdLmC5LRqROPp06FW87ifoWnPOp
# I5HCNPdsokl9BoH2mBCEvywqrhUZxzZMGSvKlyGjvApE+bTNsF9N/NEzZXeQ1Eq1
# ZhybQzkyPQIDAQABo4IB1TCCAdEwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMC
# B4AwPAYDVR0lBDUwMwYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGysGAQQBgjdhoOiV
# eoK/0ttMg5+ekiyCi8TIKTAdBgNVHQ4EFgQU4KW1b5S1TD1sjhK66eR2C9UMLBcw
# HwYDVR0jBBgwFoAUpEMMf3ZapYXnPo0oDwwXokVpcMYwZwYDVR0fBGAwXjBcoFqg
# WIZWaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0
# JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwQU9DJTIwQ0ElMjAwMy5jcmwwdAYIKwYB
# BQUHAQEEaDBmMGQGCCsGAQUFBzAChlhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDUyUyMEFP
# QyUyMENBJTIwMDMuY3J0MFQGA1UdIARNMEswSQYEVR0gADBBMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9y
# eS5odG0wDQYJKoZIhvcNAQEMBQADggIBABs65KrxSZxozLE987sSET+UmFgwaO77
# nelKKU/51CQqwtFhE8NVMc4RG3Jt2ExmVSDMxc9BJEXro0k1M5aI81qHSMU7gogF
# C5Iug+/Y515Bst++G4nPiu+NsVbGlDrAPGho+NXDDg9xkCNOlga5qbl8LKmAQ/ar
# p5L7BZY/qFhDFPvak0I89Y7wHEyQln8cXbysgOdKPbxbltNrDHb/JDsAU1H6Qy4P
# wOcefY/z1/mPhIXMpFtMGCWtNfaSP1QfsPiYd5PdDFvJbChiVyxZA56hPBeNTRgF
# y1Are1HEtvXXZePCIQSr0z6N6gdx8/b0DzRx9ABjhJzfnZaSO85fskIjWhl+/hcA
# 1nhvhN2BZFX8UodOXgfu9DDJ8+1d22skEH0oyMj6WlFzGteArOEPH/s6v1diN5Wl
# g3EaOvZ19eKLk92UO5dkWcw9bKiR5m/fZwo9XKTqR0bktovIGrKdp3FKTxemzq0P
# a8V737OKHSingPM2zf1+1rIP+Z3jEieeCxiNkvxeadckSI9cC/sWcPKatof5tQ7f
# x/kEOXbKmtSBy0lIkGTQMzd0rdg+ejHkICQBHQoNpLQXUDB8g1AQQbxp1t5y33VZ
# Gkap7+f+72HnROJRTD8syZmM3O2ZP7UZgZ41gRVy3GMV0YmmAOMX+S7rZSw9wRLV
# 3iXbj1569sk7MIIGqzCCBJOgAwIBAgITMwAGIHRMCKjGwvaN1AAAAAYgdDANBgkq
# hkiG9w0BAQwFADBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgQU9D
# IENBIDAzMB4XDTI2MDkwODAzNTU1OVoXDTI2MDkxMTAzNTU1OVowbTELMAkGA1UE
# BhMCVVMxCzAJBgNVBAgTAmdhMREwDwYDVQQHEwhCb3N0d2ljazEeMBwGA1UEChMV
# UmljaGFyZCBEYWlsZW4gR3VudGVyMR4wHAYDVQQDExVSaWNoYXJkIERhaWxlbiBH
# dW50ZXIwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDGlR8NcRCjP8qR
# 4AqKs0S37N4n5Po7V9WpRq7vclUCZelzYDd0UG6FVRxmuP2OMb7HySn3H2Ma/9hL
# mTNnabDZj1cAKC6kZ/TaxUrzPBBCL4sGYzWTxbM8Kv51lLQi9aHVxOqqXGtiV8mL
# VnhoRPFxz9S8S2ejWgHActWgrJYkkreOT4zKi1msNdemBVormrPd9dTQ2JcR+fhc
# 9U6qqPEhHjYqHpM6NHCcgwZAErskHH9S18tti3TUEFgqur8Om445ktbUGXNOl+pj
# EGEJyXR1cKlksM1zx7WjEl1wKWosmNUp6c7ThjVxdCXeLvE25SxaSpqDwwqd55r+
# sBwbQcAOtAlZxh9Bmt0E66gwcVHfKO3hAIbqdpjsKVP3qWAt3yjmYaavBR54waMU
# in+qGuy0H3ud08H3S5guS0akTj6dOhVvO4n6FpzzqSORwjT3bKJJfQaB9pgQhL8s
# Kq4VGcc2TBkrypcho7wKRPm0zbBfTfzRM2V3kNRKtWYcm0M5Mj0CAwEAAaOCAdUw
# ggHRMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMDwGA1UdJQQ1MDMGCisG
# AQQBgjdhAQAGCCsGAQUFBwMDBhsrBgEEAYI3YaDolXqCv9LbTIOfnpIsgovEyCkw
# HQYDVR0OBBYEFOCltW+UtUw9bI4SuunkdgvVDCwXMB8GA1UdIwQYMBaAFKRDDH92
# WqWF5z6NKA8MF6JFaXDGMGcGA1UdHwRgMF4wXKBaoFiGVmh0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQl
# MjBDUyUyMEFPQyUyMENBJTIwMDMuY3JsMHQGCCsGAQUFBwEBBGgwZjBkBggrBgEF
# BQcwAoZYaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNy
# b3NvZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBBT0MlMjBDQSUyMDAzLmNydDBU
# BgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNy
# b3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9zaXRvcnkuaHRtMA0GCSqGSIb3DQEB
# DAUAA4ICAQAbOuSq8UmcaMyxPfO7EhE/lJhYMGju+53pSilP+dQkKsLRYRPDVTHO
# ERtybdhMZlUgzMXPQSRF66NJNTOWiPNah0jFO4KIBQuSLoPv2OdeQbLfvhuJz4rv
# jbFWxpQ6wDxoaPjVww4PcZAjTpYGuam5fCypgEP2q6eS+wWWP6hYQxT72pNCPPWO
# 8BxMkJZ/HF28rIDnSj28W5bTawx2/yQ7AFNR+kMuD8DnHn2P89f5j4SFzKRbTBgl
# rTX2kj9UH7D4mHeT3QxbyWwoYlcsWQOeoTwXjU0YBctQK3tRxLb112XjwiEEq9M+
# jeoHcfP29A80cfQAY4Sc352WkjvOX7JCI1oZfv4XANZ4b4TdgWRV/FKHTl4H7vQw
# yfPtXdtrJBB9KMjI+lpRcxrXgKzhDx/7Or9XYjeVpYNxGjr2dfXii5PdlDuXZFnM
# PWyokeZv32cKPVyk6kdG5LaLyBqynadxSk8Xps6tD2vFe9+zih0op4DzNs39ftay
# D/md4xInngsYjZL8XmnXJEiPXAv7FnDymraH+bUO38f5BDl2yprUgctJSJBk0DM3
# dK3YPnox5CAkAR0KDaS0F1AwfINQEEG8adbect91WRpGqe/n/u9h50TiUUw/LMmZ
# jNztmT+1GYGeNYEVctxjFdGJpgDjF/ku62UsPcES1d4l249eevbJOzCCBygwggUQ
# oAMCAQICEzMAAAAYDeuRVamKAJgAAAAAABgwDQYJKoZIhvcNAQEMBQAwYzELMAkG
# A1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjE0MDIGA1UE
# AxMrTWljcm9zb2Z0IElEIFZlcmlmaWVkIENvZGUgU2lnbmluZyBQQ0EgMjAyMTAe
# Fw0yNjAzMjYxODExMzJaFw0zMTAzMjYxODExMzJaMFoxCzAJBgNVBAYTAlVTMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29m
# dCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQDIgNpgNFaiif2VWeWP5I6PnFXxJ/lB37fJR55GCvR7GLZBMkBi
# jbiKVwgpBI3xM5nf484znH/qncJ+OCq6y3jgnQW+R8Zd7U+7LjlrmcskalzSQ0gh
# MxEpnBW8/HHs2V8ZJzQk6HP+SDsbvsL7LdlH/eO2l4mknhDBwr0Z/Q966TvEth5b
# 8kCxj1vqiV4YNthLGRqZR9u2fK/yBMWu83p6O4uo2Edg++gEew5IL7vnnnKFqmSh
# /R9vPJy3WF1YcZewAUx8sXZNUnx3ZhVg59l2LpitPiwzE6FMqIsqaEvVe3MzuFd2
# a/uWDZH6VbDyUiRK78mIg1DQYA9zDEyyBFcNI+nxVSzglvL6u7PRuNqgcV3sf6EL
# xw89ysQM/Z4R1hRFWXRpyOWKKAKtfBHTk0UnNiPcxmLMMYs8jeUjOidfVPjTIry/
# UVwnwxdlkK85cZfBEMYZ/DBNOwdomP459Y1n8izKkbhsa+p4lw+cQVxATBFx9ggR
# 79HhryT7HDmpPLvkJvBZ4wW4CW32UT2SMyDe28nIOU3m+hfHlVeKcLBQcym5VoRD
# jIcCVI7uqgGW2PNME0cfei8zCwCy6HCsssJWFS7eg/YbFhnATJcyWfMrkNuAbMfM
# N8Npg8crS6jVVowyD0GG5zdgi+uQVcSK/638mA1xEYK3pnIoQgO09uuDBwIDAQAB
# o4IB3DCCAdgwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1Ud
# DgQWBBSkQwx/dlqlhec+jSgPDBeiRWlwxjBUBgNVHSAETTBLMEkGBFUdIAAwQTA/
# BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2Nz
# L1JlcG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMBIGA1Ud
# EwEB/wQIMAYBAf8CAQAwHwYDVR0jBBgwFoAU2UEpsA8PY2zvadf1zSmepEhqMOYw
# cAYDVR0fBGkwZzBloGOgYYZfaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENvZGUlMjBTaWduaW5n
# JTIwUENBJTIwMjAyMS5jcmwwfQYIKwYBBQUHAQEEcTBvMG0GCCsGAQUFBzAChmFo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUy
# MElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2lnbmluZyUyMFBDQSUyMDIwMjEuY3J0
# MA0GCSqGSIb3DQEBDAUAA4ICAQBxxyBW+X6mhdRiSwD9PMMWcGUAnx5/QUwnNvZd
# FGEX+4DRDIr9WCh4C87wHtw+lg1D3uzK10DstPX0LFLBFAC3vWMYX4ImXwoLhoR0
# xlN8mUdorJ3bgnpCJWuI1531Z1rCwPuUrSkBxfOIGDk3p2ECb3Ho/xHi5PRSR/OU
# rWuQHwXiaXMTuXu3IRLezwVkZpFmNwYRD57R9Nx2F/yM7tzOY0Hh0hGCaYEK38/6
# FrS0SXadXWyDUCfn5XOGACRjUCnHx+JQUG0f4SHD+iblpAI0gl+ZHnVmdXXxHTZe
# Ta0CYCIhFxKP2922s0g6zLmeiV13LWUmtt/UF7TrWXpMi2/0UNniaDoH7rnPGRV5
# xVX8uXy4sZii4aswzqPM7Y7+mzcranqZ8EjZk5gjLhQ3A2sZaprlOu8CaRmyfcIi
# VH7zVfgAvm81MWXFziAf7my7QOvnyEFPGddq8MSfPtfRyw/Uq3uH6KpoaJNIfPYH
# 6fceZSi53Rat1A9grExq3ROjhhSpTcchuBItAMNVPxoKNbUm+iR/X3XkL+9WQgin
# jyHe+hXLclY8vAGXFD1p40PqMIpAYsmEJBFKW9df4//1N5oQDr/FY9IBJl/oSS97
# 9i5rtT7NZz9KvYraCPRBGs0QCy+sWvgQa0coM70QJVLeVwmSxUO/0od0w9Qry7bS
# LrxGoDCCB54wggWGoAMCAQICEzMAAAAHh6M0o3uljhwAAAAAAAcwDQYJKoZIhvcN
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqRMIIajQIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMC
# EzMABiB0TAioxsL2jdQAAAAGIHQwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQg0P0ZFVEiiFKXeKi31qs4+xAMzETEYsFgQkz4nni0RbMwDQYJKoZIhvcNAQEB
# BQAEggGAHsBeTMQUXMITvNXjY1quGeym17N4ze8IEO04NivBwZOh9IcDl/j3Uwjz
# uCjNcm9Fh+mgtXPO0r37Tfrdt81W9mAPezEftF/yVxqra5jNNCbOiFSnQit+CuWo
# SsyXM5A6uagf0s3rRSCv1HfCH8Du9fANABMfBTIcU/Qu3dXv9yPpL/E1+Zwl5PkC
# nWuQ+dbBFfpQOtRkloXPS2MSlL1fFS3Z9qv6QrwZzXstCbL8bBheIKB02+0dPFvV
# E6m8aZNYabpd1/x/5H3sdSY3Dhbtzl9irXTRlxQ7RjQQzPsycf1bnS8u0jDXZwhs
# jeRYO08AyCLXoKMSCF5PJfkEZmS44m85Kee+5I6qwzrms3BrUPndseamzoCk0vLv
# 5ox5bIMjGjJlNygVZE1MLBhfULRk+P0jFNK8HGzRl8T9U3jWGOfHEKxBQBpnIqCy
# 4mVlivhEdC8G86GhxRQL9VXpw1mOSvQj0RV32ge1r46f+wHTOMRnkbLmUfEr+LS2
# zwRuJFkBoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJKoZIhvcNAQcCoIIX
# 6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIA6WnvxO3V5g
# zbt2U8yfLp8uUCvJYuIgCkEU5gtaPXRpAgZqhGwzOxwYEzIwMjYwOTA5MTQzODI3
# LjcxM1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3QTAwLTA1RTAtRDk0NzE1MDMGA1UE
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
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFhlzes/odf80gAAAAAAWDANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTVaFw0yNjEwMjIyMDQ2NTVaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046N0EwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnXg0pHaQ7PVAlln+HZZrJFcLoKbekhW1yL+QNBUgFFUsjZIK
# aqqN4oIJsJM3ps0rJNSO7ndCNRuZDX2Wgur3Ak77eXrloBXqZmO6ZVXeDNRCLldW
# 4A0/NfjzJ7XXkdEhjr81ghXEpR7zC+wbaNN+sPSxzLAZBeibDFP7Xws5wX0ZtIsN
# 1a2+Xq5bvWp3kRMytwskTjunRgeLZL/tBp237JVdRPFAQ9jYRKpCqUBo/v1xjBLR
# CV3PalKjnGfb3MN4U7jVyqifFHShcnW5CERRoBmUa6sygDzFSr8e3g93TPNLFUiv
# UE0GmLfbX5ceD1Gt1FcZ6x/JLVATzk5+BWHbMxwJIVkVPTqSSMjQ6KTKdcnq3pH0
# c4AFJp/glvcpq0U9fzZIjJGGvdpishlRl77RQtUhSjxHvCn3LC/xqQQwOHSQDsGh
# 6NX2D0RfsSyEtTAByAae+2w1HByTDTcmlTNLEuQLeCj1gNBdIWj0WOYyDtjjQ/8i
# TWY6ey1vb9qHljIj5HgIndT5P9MYk2Vg2e7hKUZNBNbA/hsgBsuoZ+IX89WvjEN9
# abF91S4OJVuinmKsLO/MLbnl7ikuD0dN6oA0YewyDQncs12sM9HOtu72QA/TZlef
# vW8r9xtMXAYoQlcGjsk8W4Uc7cfqVqbIPjdoc8ZxBzLcXcVyP4p5cyLwvkMCAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBRyjU3Fer4VxXJ+hjPcRJnxnRIJsDAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAHvrxIiVF1iHcXvxrJTCD8eOtbPUbK9x+Lz70iYehh+G0UoOMcMf04QD6tQP
# TeZ5HhGETkcn0raDJ5NpfbRBuKEH31rxbZK97o12KRDNJ3Nu4ePaUIpH/TcWz8PL
# VOCECywSxbEgEG20kyydGc46c591tXzpfkJDckjoYrypaerdeQLRQH9LaoTYZfdA
# zMo+Dy0O1DzFJkF5YnsmAM8lt9r1NtXdFjdbFMCbV5dau64mV22s186A8Umi+l23
# 9+Ue0cbJQIykWhIlhhWhxQgoksqHz7kp2GFZAAeySTmIOQOWyXOA8JA8TISJyn3J
# DOgStv583P3V0QSALT6JXDCW26FV208VGJMzkv0S22iOTZJ/oamTpk8RzD8oWT8p
# fbe1q/k/bxPiXYRbzps96a5YOko7n0Vdo61DOJhL/mhk01Y348gq6vhG/VTcdGHh
# 1rCkwOM05B35AZZq9AtPpfRzJinrHzzGRx+r6fD3ccYMPMMX/Nwd2irzrph172fQ
# cSf1fMwvwIhmfH4GWJJ+mf1HA6uXoAOVByckguXvlj8gPi7T2ES6RU8+QssfqTNT
# JKjsBheWKWv2W4ESVen2L7lCz7i79FhA+0kp0yXJnYwdzWS0ovTINULINmzVyMcS
# Um5WuVf8YZ33cAud2Opr6N1+RuLZDavDvjiehlI5dH+GEy56MYIHQzCCBz8CAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFhlzes/odf80gAAAAAAWDANBglghkgBZQMEAgEFAKCCBJwwEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MTQzODI3WjAvBgkqhkiG9w0BCQQxIgQg2b4H4CWW
# BZCJo6LJN4fcFLftZ4iJv1LY1h1sqk53iBkwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCDFIlS7sgfQ+wAo1cWbWz+WN69VBds58hbran919aLocTB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFhlzes/odf80gAAAAAAWDCCA14GCyqGSIb3DQEJEAISMYIDTTCCA0mh
# ggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0EwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQCdZHkb26ercF2O62vCdZUfUSvEXKBnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5L64kwIhgPMjAyNjA5MDkxNDI4MjVaGA8y
# MDI2MDkxMDE0MjgyNVowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7kvriQIBADAH
# AgEAAgIiMzAHAgEAAgISIDAKAgUA7k09CQIBADA2BgorBgEEAYRZCgQCMSgwJjAM
# BgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEB
# CwUAA4IBAQA7OJK6aYPrPIEIpO1/KgGZ4p2GfYDlHTrQkZbPs1Tx1AylYGWd1PiP
# z/rid4jX9pLJD01C4BsbYbiRnSpxmrVJW0vUoX1akTfsaIBP1Mx1gT3tPSh67bbV
# MhELawA283g8NUUffcm5kpfmINtX+PSjASjFWeDx47spWuBDnuGnyha8+ThyVBHl
# 7bMmaFmKfntmyGtXZG0c/IaOhHCTn4cfiDyw9WgwVKFLjdn5sqaq0xgXO1lG7HSw
# xNFpj3rerXNxGlrpUe1hjntQ0/+8CzvdGPuTQwZQvd60wl/5JZKo96GSpDkBC+e1
# 0Sk7F1Bxw9rKA50iTM6qlnvpY4I74Kf9MA0GCSqGSIb3DQEBAQUABIICAAXNbY/b
# TnkViCEJmQXfn/yM95oPbg0DHEgjIDV13L16661a7CFtjjL+CvOSPqU/90pJOsPA
# l3+QyAz37Zhf27kVuw2oxtZ0D3IvncE/i6hQuiD0/65yyU0Q1t56SKxvVLqaGEOz
# gi9F06l0RRTjNsvRT7rf6jGphILpqn97ehzQHJTYRSdkFVPgxfgJwtXPRksKkgye
# Rgk7PlxhtQe7z8ejXhPjNnStGruZNRvRfKzxuny6/RZeHWbLPrJjWK4h3Wamd8nh
# mGeu5eV0AIcEwlbqLc5eiBBmjszNgicE+012PBOZZfsmdWv7RMK2d9vievvL3GzE
# xQIgkDfyv0mR0jGRH5LnkmW+G9yMW6tbMH7oY1tUueIBSjq8I9WeWX1ZTYxRMNP8
# BvTGeFJHyBLl2SQMiaxp+HkgbgnSe2+NHmi77ur5iYPTC3XzFHJsgavClsSuSGnm
# 2XQZhJ9NLiWDnR0U1RD1Tg+AXqhhqqSkXXvqswxBRawmO1pagCNGwBxxMpwDzmLR
# 0HmnPeuFj/TIzVyXWsbSRCff/x+2Uqe2cJJv8WsKeMzPwNPf9f0mXtSS72arGIeN
# WyKTQkkA4PHIlMMeLzYwKPG5lIcMFi3voJH5bCwHb7mBRQ5kDrCCKlXUP2I9wjEy
# wHXxyBFmbkbtyetaXHQajhPEMww/ypPBU93k
# SIG # End signature block
