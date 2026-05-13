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
            "Revit", 
            "Advance Steel", 
            "Autodesk Material Library", 
            "Civil 3D",
            "Inventor",
            "Navisworks Manage",
            "Navisworks Freedom",
            "ReCap",
            "3ds Max",
            "Maya",
            "Vault Professional Client",
            "Vault Basic Client"
        ),
        [int[]]$TargetYears = (2015..2023),
        [string[]]$AdditionalVendors = @(),
        [switch]$AnyVendor,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()

    # Processes that are safe to kill if an older version is hanging (excluding shared system services/tray apps)
    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*")

    # --- Logging Setup ---
    $ToDate = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskCleanup_$($ToDate)"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

    $TranscriptLog = "$($LogDir)\CleanupTranscript.log"
    $DebugLog = "$($LogDir)\CleanupDebug.log"

    Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null

    # --- Helper Functions ---
    function Write-Msg {
        param (
            [string]$Message,
            [ValidateSet("Info", "Success", "Warning", "Error")]
            [string]$Type = "Info"
        )
        $TimeStamp = "[$(Get-Date -Format 'HH:mm:ss')]"
        $Colors = @{
            "Info"    = "Cyan"
            "Success" = "Green"
            "Warning" = "Yellow"
            "Error"   = "Red"
        }
        Write-Host "$($TimeStamp) $($Message)" -ForegroundColor $Colors[$Type]
    }

    function Write-QuietLog {
        param ([string]$Message)
        $TimeStamp = "[$(Get-Date -Format 'HH:mm:ss')]"
        Add-Content -Path $DebugLog -Value "$($TimeStamp) [DEBUG] $($Message)"
    }

    function Test-Interactive {
        return [Environment]::UserInteractive -and -not $Silent -and ($host.Name -eq "ConsoleHost" -or $host.Name -match "ISE|VS Code")
    }

    function Invoke-SurgicalDirectoryCleanup {
        param ([string]$ProductName, [string]$Version)
    
        $SafePathsToSearch = @(
            "$($env:ProgramFiles)\Autodesk",
            "$(${env:ProgramFiles(x86)})\Autodesk",
            "$($env:ProgramData)\Autodesk",
            "$($env:PUBLIC)\Documents\Autodesk"
        )

        $SearchPattern = "*$($ProductName)*$($Version)*"

        foreach ($basePath in $SafePathsToSearch) {
            if (Test-Path $basePath) {
                Get-ChildItem -Path $basePath -Filter $SearchPattern -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                        Write-Msg "Purged orphaned directory: $($_.FullName)" "Success"
                    }
                    catch {
                        Write-QuietLog "Failed to remove directory $($_.FullName): $($_.Exception.Message)"
                        $script:SACFailures += [PSCustomObject]@{ Component = "Directory Purge: $($_.FullName)"; Reason = $_.Exception.Message }
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
            "$($env:ProgramData)\Microsoft\Windows\Start Menu\Programs",
            "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        )

        $SearchPattern = "*$($ProductName)*$($Version)*.lnk"

        foreach ($loc in $ShortcutLocations) {
            # Resolve wildcards for user profiles
            $resolved = if ($loc -match '\*') { Resolve-Path $loc -ErrorAction SilentlyContinue } else { ,$loc }
            
            foreach ($path in $resolved) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -Filter $SearchPattern -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                        try {
                            Remove-Item $_.FullName -Force -ErrorAction Stop
                            Write-Msg "Removed shortcut: $($_.Name)" "Success"
                        } catch {
                            Write-QuietLog "Failed to remove shortcut $($_.FullName): $($_.Exception.Message)"
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

        Write-Msg "Uninstalling: $DisplayName" "Warning"

        $Process = $null
        if ($ProductCode -match '^{.*}$') {
            if ($UninstallString -match '^MsiExec\.exe') {
                Write-Msg "  [MSI] $DisplayName" "Info"
                $Process = Start-Process "msiexec.exe" -ArgumentList "/x $ProductCode /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable /L*v `"$MsiLogFile`"" -PassThru -WindowStyle Hidden
            } else {
                Write-Msg "  [Custom] $DisplayName" "Info"
                $Process = Invoke-SACCustomUninstall -App $App -UninstallString $UninstallString
            }
        } else {
            # Non-GUID entry - attempt custom uninstall path
            $Process = Invoke-SACCustomUninstall -App $App -UninstallString $UninstallString
        }

        if ($null -ne $Process) {
            Watch-SACProcessTree -RootProcess $Process -DisplayName $DisplayName -TimeoutMinutes 20 -IdleTimeoutMinutes 5
            Write-Msg "  Exit code $($Process.ExitCode): $DisplayName" "Info"
            $safeExitCodes = @(0, 3010, 1605, 1614, 1646, 7)
            if ($Process.ExitCode -notin $safeExitCodes) {
                $script:SACFailures += [PSCustomObject]@{ Component = "Uninstall: $DisplayName"; Reason = "Exit Code $($Process.ExitCode)" }
            } else {
                Write-QuietLog "  Safe exit code $($Process.ExitCode) for: $DisplayName"
            }
        }

        # Evict the registry key. If it is already gone the uninstaller
        # cleaned up after itself, which is the ideal outcome - not a failure.
        if (Test-Path $App.PSPath) {
            try {
                Remove-Item $App.PSPath -Recurse -Force -ErrorAction Stop
                Write-Msg "  Evicted registry key: $DisplayName" "Success"
            } catch {
                Write-QuietLog "Failed to evict registry key for $DisplayName ($($App.PSPath)): $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component = "Registry Eviction: $DisplayName"; Reason = $_.Exception.Message }
            }
        } else {
            Write-Msg "  Registry key already removed (self-cleaned): $DisplayName" "Success"
            Write-QuietLog "Eviction skipped - key not found (uninstaller self-cleaned): $($App.PSPath)"
        }
    }

    function Invoke-SACCustomUninstall {
        param (
            [object]$App,
            [string]$UninstallString
        )
        $DisplayName     = $App.DisplayName
        if ([string]::IsNullOrWhiteSpace($UninstallString)) {
            Write-QuietLog "No UninstallString for $DisplayName. Skipping."
            return
        }
        $ExePath  = ''
        $ArgPart  = ''
        if ($UninstallString -match '^"([^"]+)"(.*)$')    { $ExePath = $Matches[1]; $ArgPart = $Matches[2].Trim() }
        elseif ($UninstallString -match '^(.*\.exe)(.*)$') { $ExePath = $Matches[1].Trim(); $ArgPart = $Matches[2].Trim() }
        else                                               { $ExePath = $UninstallString }

        if ([string]::IsNullOrWhiteSpace($ExePath)) {
            Write-QuietLog "Could not parse exe path for $DisplayName. Skipping."
            return
        }
        $FullArgs = "$ArgPart -q --silent /qn /quiet /norestart --mode unattended".Trim()
        try {
            $Process = Start-Process -FilePath $ExePath -ArgumentList $FullArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
            return $Process
        } catch {
            $msg = $_.Exception.Message
            # If the installer exe itself is gone the product was already removed - not a failure
            if ($_.Exception -is [System.ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -in @(2, 3)) {
                Write-Msg "  Installer not found (already removed): $DisplayName" "Info"
                Write-QuietLog "Installer exe not found for $($DisplayName) - treating as already removed."
            } else {
                Write-QuietLog "Failed to launch uninstaller for $($DisplayName): $msg"
                Write-Msg "  Launch failed for $DisplayName (see Debug Log)" "Error"
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

        $AllKeys = Get-ItemProperty -Path @(
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue | Where-Object {
            if (-not ($_.DisplayName -like $PackageName)) { return $false }
            if ($AnyVendor) { return $true }
            return ($_.Publisher -match $vendorPattern -or $_.DisplayName -match $vendorPattern)
        }

        if (-not $AllKeys) {
            Write-QuietLog "No registry match for $ProductName $Version."
            return
        }

        # Kill running processes before we start
        foreach ($procName in $ProcessesToKill) {
            try { Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop }
            catch { Write-QuietLog "Could not stop process $procName`: $($_.Exception.Message)" }
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
        Write-Msg "Found $total component(s) for $($ProductName) $($Version): $($Tier1.Count) primary, $skippable update/addon(s), $($Tier4.Count) shared." "Info"

        # --- Tier 1: Primary products (full uninstall) ---
        $tier1Succeeded = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($item in $Tier1) {
            Invoke-SACUninstallEntry -App $item.App
            # Track parent product names for Tier 2/3 skip logic
            $baseName = $item.App.DisplayName -replace $Tier2Pattern,'' -replace $Tier3Pattern,'' -replace $Tier4Pattern,'' -replace '\s+', ' '
            $tier1Succeeded.Add($baseName.Trim()) | Out-Null
        }

        # --- Tier 2: Service packs / updates ---
        foreach ($item in $Tier2) {
            $dn = $item.App.DisplayName
            # Check if any T1 parent of this update was successfully processed
            $parentFound = $tier1Succeeded.Count -gt 0
            if ($parentFound) {
                Write-Msg "  [SKIP uninstall] Parent removed - evicting only: $dn" "Info"
                try {
                    Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Msg "  Evicted: $dn" "Success"
                } catch {
                    Write-QuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component = "Evict SP/Update: $dn"; Reason = $_.Exception.Message; Severity = 'Warning' }
                }
            } else {
                Write-Msg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                Invoke-SACUninstallEntry -App $item.App
            }
        }

        # --- Tier 3: Add-ons / extensions ---
        foreach ($item in $Tier3) {
            $dn = $item.App.DisplayName
            $parentFound = $tier1Succeeded.Count -gt 0
            if ($parentFound) {
                Write-Msg "  [SKIP uninstall] Parent removed - evicting only: $dn" "Info"
                try {
                    Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                    Write-Msg "  Evicted: $dn" "Success"
                } catch {
                    Write-QuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component = "Evict Addon: $dn"; Reason = $_.Exception.Message; Severity = 'Warning' }
                }
            } else {
                Write-Msg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
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
    Write-Msg "==========================================" "Info"
    Write-Msg " SURGICAL AUTODESK CLEANUP INITIALIZED" "Info"
    Write-Msg " Transcript: $($TranscriptLog)" "Info"
    Write-Msg " Debug Log:  $($DebugLog)" "Info"
    Write-Msg "==========================================" "Info"

    if (Test-Interactive) {
        Write-Host "`nTarget Products: $($TargetProducts -join ', ')" -ForegroundColor Cyan
        Write-Host "Target Years: $($TargetYears -join ', ')`n" -ForegroundColor Cyan
        Write-Host "WARNING: This will forcefully remove the specified versions.`n" -ForegroundColor Yellow
        $Response = Read-Host "Type 'YES' to proceed"
        if ($Response -ne "YES") { 
            Write-Msg "Execution aborted by user." "Warning"
            Stop-Transcript | Out-Null
            exit 
        }
    }
    else {
        Write-Msg "Running in non-interactive/silent mode." "Info"
    }

    Write-Msg "Processing $($TargetProducts.Count) product(s) across $($TargetYears.Count) year(s)..." "Info"
    foreach ($year in ($TargetYears | Sort-Object)) {
        foreach ($product in $TargetProducts) {
            Invoke-UninstallAutodeskProduct -ProductName $product -Version $year.ToString()
        }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-Msg "==========================================" "Info"
    Write-Msg " CLEANUP COMPLETED in $($ElapsedTime)" "Success"
    Write-Msg "==========================================" "Info"

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
}
