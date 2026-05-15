function Start-SACPurge {
    <#
.SYNOPSIS
    Enterprise Autodesk Master Purge Script
.DESCRIPTION
    Hard-kills Autodesk services, uninstalls MSI and modern components, 
    purges registry/file remnants, and cleans desktops. Handles locked 
    files gracefully with dual-channel logging to prevent IO lock exceptions.
    Includes safe-evaluation regex removal of SQL Server LocalDB.

    Supports robust temporary pathing, falling back to $env:TEMP if C:\temp is unavailable.
    Creates an AttentionItems.txt log if any critical component failures are detected.
#>
    [CmdletBinding()]
    param (
        [string[]]$AdditionalVendors = @(),
        [switch]$AnyVendor,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SACFailures = @()

    # --- Configuration Arrays ---
    $RemoveVersions = @(
        @{Name = "AutoCAD"; Versions = @("*") },
        @{Name = "Civil 3D"; Versions = @("*") },
        @{Name = "Revit"; Versions = @("*") },
        @{Name = "Autodesk"; Versions = @("*") }
    )

    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "*adsk*", "AdskAccess*", "GenuineService*", "*AdAppMgr*", "*AdODIS*", "*Autodesk*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*", "DesktopConnector*")

    $DataLocations = @(
        "$($env:ProgramData)\Autodesk",
        "$($env:PUBLIC)\Documents\Autodesk",
        "C:\Users\*\AppData\Local\Autodesk",
        "C:\Users\*\AppData\Roaming\Autodesk",
        "C:\Users\*\AppData\Local\Temp\Autodesk",
        "$($env:ProgramFiles)\Autodesk",
        "$($env:CommonProgramFiles)\Autodesk Shared",
        "$(${env:ProgramFiles(x86)})\Autodesk",
        "$(${env:CommonProgramFiles(x86)})\Autodesk Shared",
        "C:\Autodesk"
    )

    $RegistryLocations = @(
        "HKCU:\Software\Autodesk",
        "HKCU:\Software\Wow6432Node\Autodesk",
        "HKLM:\Software\Autodesk",
        "HKLM:\Software\Wow6432Node\Autodesk",
        "HKU:\*\Software\Autodesk",
        "HKU:\*\Software\Wow6432Node\Autodesk"
    )

    # --- Logging Setup ---
    $ToDate = (Get-Date -Format 'yyyyMMdd_HHmmss')
    $BaseTemp = if (Test-Path "C:\temp") { "C:\temp" } else { $env:TEMP }
    $LogDir = Join-Path $BaseTemp "AutodeskPurge_$($ToDate)"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null

    $TranscriptLog = "$($LogDir)\PurgeTranscript.log"
    $DebugLog = "$($LogDir)\PurgeDebug.log"

    Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null

    # --- Helper Functions (Centralized) ---

    function Invoke-SACShortcutPurge {
        Write-SACMsg "Sweeping desktops and start menus for Autodesk shortcuts..." "Info"
        $ShortcutLocations = @(
            "$($env:PUBLIC)\Desktop",
            "C:\Users\*\Desktop",
            "C:\Users\*\OneDrive\Desktop",
            "$($env:ProgramData)\Microsoft\Windows\Start Menu\Programs",
            "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        )
        
        $Shell = New-Object -ComObject WScript.Shell
        $AutodeskPath = "$($env:ProgramFiles)\Autodesk\"
        $AutodeskPathX86 = "$(${env:ProgramFiles(x86)})\Autodesk\"
        # Stricter name patterns for fallback
        $ShortcutPatterns = @("*AutoCAD*", "*Revit*", "*Autodesk*", "*Civil 3D*", "*BIM 360*", "*Recap*", "*Navisworks*", "*3ds Max*", "*Maya*", "*Inventor*")

        foreach ($loc in $ShortcutLocations) {
            # Resolve wildcards for user profiles
            $resolved = if ($loc -match '\*') { Resolve-Path $loc -ErrorAction SilentlyContinue } else { ,$loc }
            
            foreach ($path in $resolved) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -Filter "*.lnk" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                        $isMatch = $false
                        $lnkBore = $_
                        $target = ""

                        # --- STEP 1: Deep Inspection of Target Path (PRIORITY) ---
                        try {
                            $shortcut = $Shell.CreateShortcut($lnkBore.FullName)
                            $target = $shortcut.TargetPath
                            
                            if (-not [string]::IsNullOrWhiteSpace($target)) {
                                # If we HAVE a target path, the decision is based STRICTLY on that path.
                                if ($target -like "$AutodeskPath*" -or $target -like "$AutodeskPathX86*") {
                                    $isMatch = $true
                                } else {
                                    # EXPLICIT SAFETY: If it points elsewhere (e.g., PDQ Inventory), it is NOT a match.
                                    $isMatch = $false
                                }
                            }
                        } catch {
                            Write-SACQuietLog "Failed to inspect shortcut target for $($lnkBore.FullName)"
                        }

                        # --- STEP 2: Name-Based Fallback (Only if Target Path is empty/unresolvable) ---
                        # Some advertised shortcuts (MSI) return empty TargetPath via COM.
                        if (-not $isMatch -and [string]::IsNullOrWhiteSpace($target)) {
                            foreach ($pattern in $ShortcutPatterns) {
                                if ($lnkBore.Name -like "$pattern*") {
                                    $isMatch = $true
                                    break
                                }
                            }
                        }

                        if ($isMatch) {
                            try {
                                Remove-Item $lnkBore.FullName -Force -ErrorAction Stop
                                Write-SACMsg "Deleted shortcut: $($lnkBore.FullName)" "Success"
                            }
                            catch {
                                Write-SACQuietLog "Failed to delete shortcut $($lnkBore.FullName): $($_.Exception.Message)"
                            }
                        }
                    }
                }
            }
        }
    }

    function Stop-AndRemoveService {
        param ([string]$ServiceName)
    
        $ServiceCim = Get-CimInstance Win32_Service -Filter "Name LIKE '%$($ServiceName)%' OR DisplayName LIKE '%$($ServiceName)%'"
        foreach ($svc in $ServiceCim) {
            if ($svc.State -eq 'Running' -and $svc.ProcessId -gt 0) {
                Write-SACMsg "Hard killing process ID $($svc.ProcessId) for service $($svc.Name)" "Warning"
                try { Stop-Process -Id $svc.ProcessId -Force -ErrorAction Stop } catch { Write-SACQuietLog "Failed to kill PID $($svc.ProcessId): $($_.Exception.Message)" }
            }
            try {
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                sc.exe delete $svc.Name 2>&1 | Out-Null
                Write-SACMsg "Removed service: $($svc.Name)" "Success"
            }
            catch {
                Write-SACQuietLog "Failed to disable/remove service $($svc.Name): $($_.Exception.Message)"
            }
        }
    }

    function Invoke-RemoveODISAndLicensing {
        Write-SACMsg "Targeting modern Autodesk ODIS and Licensing components..." "Info"
        $UninstallerPaths = @(
            "$($env:ProgramFiles)\Autodesk\AdODIS\V1\RemoveODIS.exe",
            "$(${env:CommonProgramFiles(x86)})\Autodesk Shared\AdskLicensing\uninstall.exe",
            "$($env:ProgramFiles)\Autodesk\Autodesk AdSSO\uninstall.exe"
        )

        foreach ($path in $UninstallerPaths) {
            if (Test-Path $path) {
                Write-SACMsg "Executing native uninstaller: $($path)" "Info"
                try {
                    $Process = Start-Process -FilePath $path -ArgumentList "--mode unattended" -PassThru -Wait -NoNewWindow -ErrorAction Stop
                    Write-SACMsg "Uninstaller exited with code: $($Process.ExitCode)" "Info"
                }
                catch {
                    Write-SACQuietLog "Failed to execute uninstaller $($path): $($_.Exception.Message)"
                }
            }
        }
    }

    function Invoke-RemoveSQLLocalDB {
        Write-SACMsg "Evaluating SQL Server LocalDB dependencies..." "Info"
        $AutodeskPatterns = @("*SteelConnections*", "*AdvanceSteel*", "*Revit*", "*AutoCAD*", "MSSQLLocalDB", "v11.0")
    
        $instances = try { & sqllocaldb info 2>$null } catch { $null }

        if ($instances) {
            $unknownInstances = @()
            foreach ($inst in $instances) {
                $isAutodesk = $false
                foreach ($pattern in $AutodeskPatterns) {
                    if ($inst -like $pattern) { $isAutodesk = $true; break }
                }
                if (-not $isAutodesk) { $unknownInstances += $inst }
            }

            if ($unknownInstances.Count -gt 0) {
                Write-SACMsg "Found unknown LocalDB instances. Skipping SQL removal to prevent breaking other apps." "Warning"
                foreach ($inst in $unknownInstances) { Write-SACQuietLog "Skipping due to unknown instance: $inst" }
                return
            }

            Write-SACMsg "Only Autodesk/Default LocalDB instances detected. Proceeding with SQL purge..." "Success"
            foreach ($inst in $instances) {
                Write-SACQuietLog "Stopping and deleting instance: $inst"
                & sqllocaldb stop "$inst" 2>&1 | Out-Null
                & sqllocaldb delete "$inst" 2>&1 | Out-Null
            }
        }
        else {
            Write-SACMsg "No active LocalDB instances found." "Info"
        }

        Write-SACMsg "Locating SQL Server LocalDB MSIs..." "Info"
        $LocalDbRegex = "^Microsoft SQL Server (2014|2019).*LocalDB"
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        $appsToUninstall = @()
        foreach ($path in $regPaths) {
            if (Test-Path $path) {
                Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                    $dn = $_.GetValue("DisplayName")
                    if ($null -ne $dn -and $dn -match $LocalDbRegex) {
                        $appsToUninstall += [PSCustomObject]@{
                            DisplayName = $dn
                            PSChildName = $_.PSChildName
                        }
                    }
                }
            }
        }

        if ($appsToUninstall) {
            foreach ($app in $appsToUninstall) {
                $guid = $app.PSChildName
                $name = $app.DisplayName
                Write-SACMsg "Uninstalling: $name" "Info"
                $MsiLogFile = "$($LogDir)\$($name -replace '[\\/:\*\?"<>\|]','')_Uninstall.log"
            
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress /L*v `"$($MsiLogFile)`"" -Wait -NoNewWindow -PassThru
            
                if ($process.ExitCode -eq 0) {
                    Write-SACMsg "Successfully uninstalled $name." "Success"
                }
                else {
                    Write-SACMsg "Uninstall for $name returned exit code $($process.ExitCode)." "Warning"
                }
            }
        }
        else {
            Write-SACQuietLog "Target SQL LocalDB installations not found in the registry."
        }

        $localDbAppData = "$env:LOCALAPPDATA\Microsoft\Microsoft SQL Server Local DB"
        if (Test-Path $localDbAppData) {
            Write-SACQuietLog "Purging residual LocalDB AppData..."
            Invoke-SACRobocopyPurge -TargetPath $localDbAppData | Out-Null
        }
    }

    function Invoke-UninstallAutodeskProduct {
        param ([string]$ProductName, [string[]]$Versions)

        foreach ($version in $Versions) {
            # Kill running processes before we start uninstallation
            foreach ($processName in $ProcessesToKill) {
                try { Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop } 
                catch { Write-SACQuietLog "Could not stop process $($processName): $($_.Exception.Message)" }
            }

            # Disable Autodesk Scheduled Tasks FIRST to prevent processes from restarting
            Get-ScheduledTask -TaskPath "\Autodesk\*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
            Get-ScheduledTask -TaskName "*Autodesk*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue

            Write-SACMsg "Starting uninstallation sequence for $($ProductName) $($version)..." "Info"

            Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -Force -ErrorAction SilentlyContinue

            $PackageName = if ($version -eq "*") { "*$($ProductName)*" } else { "*$($ProductName)*$($version)*" }
        
            $vendorPattern = "^$"
            if (-not $AnyVendor) {
                $vendors = @("Autodesk")
                if ($AdditionalVendors) { $vendors += $AdditionalVendors }
                $vendorPattern = ($vendors | ForEach-Object { [regex]::Escape($_) }) -join '|'
            }

            $regPaths = @(
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            $UninstallKeys = @()
            foreach ($path in $regPaths) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                        $dn = $_.GetValue("DisplayName")
                        $pb = $_.GetValue("Publisher")
                        
                        if ($null -ne $dn -and $dn -like $PackageName) {
                            if ($AnyVendor -or ($null -ne $pb -and $pb -match $vendorPattern) -or ($dn -match $vendorPattern)) {
                                $UninstallKeys += [PSCustomObject]@{
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

            function Invoke-SACUninstallEntry {
                param ([object]$app)
                
                $ProductCode = $app.PSChildName
                $DisplayName = $app.DisplayName
                $QuietUninstallString = $app.QuietUninstallString
                $UninstallString = if (-not [string]::IsNullOrWhiteSpace($QuietUninstallString)) { $QuietUninstallString } else { $app.UninstallString }
                $MsiLogFile = "$($LogDir)\$($DisplayName -replace '[\\/:\*\?"<>\|]','')_Uninstall.log"
                
                Write-SACMsg "Uninstalling: $DisplayName" "Warning"
                
                $Process = $null
                if ($ProductCode -match '^{.*}$') {
                    # Robust MSI detection: case-insensitive, handles quotes and paths
                    if ($UninstallString -match 'msiexec\.exe') {
                        Write-SACMsg "  [MSI] $DisplayName" "Info"
                        $Process = Start-Process "msiexec.exe" -ArgumentList "/x $($ProductCode) /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable /L*v `"$($MsiLogFile)`"" -PassThru -WindowStyle Hidden
                    }
                    else {
                        Write-SACMsg "  [Custom-MSI] $DisplayName" "Info"
                        $Process = Invoke-SACCustomUninstall -App $app -UninstallString $UninstallString -DisplayName $DisplayName
                    }
                }
                else {
                    $Process = Invoke-SACCustomUninstall -App $app -UninstallString $UninstallString -DisplayName $DisplayName
                }
                
                if ($null -ne $Process) {
                    Watch-SACProcessTree -RootProcess $Process -DisplayName $DisplayName -TimeoutMinutes 20 -IdleTimeoutMinutes 5 -TailLogFile $MsiLogFile
                    Write-SACMsg "  Exit code: $($Process.ExitCode) for $($DisplayName)" "Info"
                    if ($Process.ExitCode -ne 0 -and $Process.ExitCode -ne 3010 -and $Process.ExitCode -ne 1605) {
                        $script:SACFailures += [PSCustomObject]@{ Component = "Uninstall: $DisplayName"; Reason = "Exit Code $($Process.ExitCode)" }
                    }
                }
                
                # Evict the registry key
                if (Test-Path $app.PsPath) {
                    try {
                        Remove-Item $app.PsPath -Recurse -Force -ErrorAction Stop
                        Write-SACMsg "  Evicted Add/Remove Programs Key: $($DisplayName)" "Success"
                    }
                    catch {
                        Write-SACQuietLog "Failed to evict registry key for $($DisplayName) ($($app.PsPath)): $($_.Exception.Message)"
                        $script:SACFailures += [PSCustomObject]@{ Component = "Registry Eviction: $DisplayName"; Reason = $_.Exception.Message }
                    }
                } else {
                    Write-SACMsg "  Registry key already removed (self-cleaned): $DisplayName" "Success"
                    Write-SACQuietLog "Eviction skipped - key not found (uninstaller self-cleaned): $($App.PSPath)"
                }
            }

            function Invoke-SACCustomUninstall {
                param ([object]$App, [string]$UninstallString, [string]$DisplayName)
                if ([string]::IsNullOrWhiteSpace($UninstallString)) {
                    Write-SACQuietLog "No UninstallString found for $($DisplayName). Skipping."
                    return $null
                }

                $ExePath = ""
                $Arguments = ""
            
                if ($UninstallString -match '^"([^"]+)"(.*)$') {
                    $ExePath = $matches[1]
                    $Arguments = $matches[2].Trim()
                }
                elseif ($UninstallString -match '^(.*\.exe)(.*)$') {
                    $ExePath = $matches[1].Trim()
                    $Arguments = $matches[2].Trim()
                }
                else {
                    $ExePath = $UninstallString
                }

                if ([string]::IsNullOrWhiteSpace($ExePath)) {
                    Write-SACQuietLog "Could not parse executable path from UninstallString for $($DisplayName). Skipping."
                    return $null
                }

                # If it's MSIExec, we MUST avoid non-MSI flags like --silent or --mode
                $isMsi = ($ExePath -match 'msiexec\.exe')
                $FullArgs = if ($isMsi) {
                    "$($Arguments) /qn /quiet /norestart".Trim()
                } else {
                    "$($Arguments) --silent /qn /quiet /norestart --mode unattended".Trim()
                }
            
                try {
                    # Use cmd /c with NUL redirection to discourage interactive prompts from hanging the process.
                    # We still use Start-Process -PassThru to get the PID for the Supervisor.
                    $cmdArgs = "/c `"`"$ExePath`" $FullArgs < NUL`""
                    Write-SACQuietLog "Executing custom uninstall for ${DisplayName}: cmd.exe $cmdArgs"
                    return Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
                }
                catch {
                    Write-SACQuietLog "Failed to execute custom uninstaller for $($DisplayName): $($_.Exception.Message)"
                    Write-SACMsg "  Execution failed for $($DisplayName) (See Debug Log)" "Error"
                    $script:SACFailures += [PSCustomObject]@{ Component = "Uninstaller Execution: $DisplayName"; Reason = $_.Exception.Message }
                    return $null
                }
            }

            $Classified = @()
            foreach ($app in $UninstallKeys) {
                $tier = Get-SACTier -DisplayName $app.DisplayName
                $Classified += [PSCustomObject]@{ Tier = $tier; App = $app }
            }

            $Tier1 = $Classified | Where-Object { $_.Tier -eq 1 }
            $Tier2 = $Classified | Where-Object { $_.Tier -eq 2 }
            $Tier3 = $Classified | Where-Object { $_.Tier -eq 3 }
            $Tier4 = $Classified | Where-Object { $_.Tier -eq 4 }

            $total = $Classified.Count
            $skippable = $Tier2.Count + $Tier3.Count
            Write-SACMsg "Found $total component(s) for Purge: $($Tier1.Count) primary, $skippable update/addon(s), $($Tier4.Count) shared." "Info"

            # --- Tier 1: Primary products (full uninstall) ---
            $tier1Succeeded = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($item in $Tier1) {
                Invoke-SACUninstallEntry -app $item.App
                $baseName = $item.App.DisplayName -replace $Tier2Pattern,'' -replace $Tier3Pattern,'' -replace $Tier4Pattern,'' -replace '\s+', ' '
                $tier1Succeeded.Add($baseName.Trim()) | Out-Null
            }

            # --- Tier 2: Service packs / updates ---
            foreach ($item in $Tier2) {
                $dn = $item.App.DisplayName
                if ($tier1Succeeded.Count -gt 0) {
                    Write-SACMsg "  [SKIP uninstall] Parent removed - evicting only: $dn" "Info"
                    if (Test-Path $item.App.PSPath) {
                        try {
                            Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                            Write-SACMsg "  Evicted: $dn" "Success"
                        } catch {
                            Write-SACQuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                        }
                    }
                } else {
                    Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                    Invoke-SACUninstallEntry -app $item.App
                }
            }

            # --- Tier 3: Add-ons / extensions ---
            foreach ($item in $Tier3) {
                $dn = $item.App.DisplayName
                if ($tier1Succeeded.Count -gt 0) {
                    Write-SACMsg "  [SKIP uninstall] Parent removed - evicting only: $dn" "Info"
                    if (Test-Path $item.App.PSPath) {
                        try {
                            Remove-Item $item.App.PSPath -Recurse -Force -ErrorAction Stop
                            Write-SACMsg "  Evicted: $dn" "Success"
                        } catch {
                            Write-SACQuietLog "Failed to evict $($dn): $($_.Exception.Message)"
                        }
                    }
                } else {
                    Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                    Invoke-SACUninstallEntry -app $item.App
                }
            }

            # --- Tier 4: Shared components (always full uninstall, last) ---
            foreach ($item in $Tier4) {
                Invoke-SACUninstallEntry -app $item.App
            }
        }
    }

    # --- Execution Block ---
    Clear-Host
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " AUTODESK MASTER PURGE INITIALIZED" "Info"
    Write-SACMsg " Transcript: $($TranscriptLog)" "Info"
    Write-SACMsg " Debug Log:  $($DebugLog)" "Info"
    Write-SACMsg "==========================================" "Info"

    if (Test-SACInteractive -Silent $Silent) {
        Write-Host "`nWARNING: This will forcefully terminate and remove all Autodesk applications.`n" -ForegroundColor Yellow
        $Response = Read-Host "Type 'YES' to proceed"
        if ($Response -ne "YES") { 
            Write-SACMsg "Execution aborted by user." "Warning"
            Stop-Transcript | Out-Null
            return 
        }
    }
    else {
        Write-SACMsg "Running in non-interactive/silent mode." "Info"
    }

    foreach ($product in $RemoveVersions) {
        Invoke-UninstallAutodeskProduct -ProductName $product.Name -Versions $product.Versions
    }

    # --- Phase 2: Service and System Component Removal ---
    Write-SACMsg "All product uninstallers completed. Proceeding to service removal..." "Info"
    Stop-AndRemoveService -ServiceName "Autodesk"
    Stop-AndRemoveService -ServiceName "Adsk"
    Stop-AndRemoveService -ServiceName "ODIS"
    Stop-AndRemoveService -ServiceName "AdskAccessService"
    Stop-AndRemoveService -ServiceName "AGS"
    Stop-AndRemoveService -ServiceName "Genuine"

    Invoke-RemoveODISAndLicensing
    Invoke-RemoveSQLLocalDB

    Write-SACMsg "Purging Installer Cache..." "Info"
    $InstallerCache = Get-ItemProperty -Path "HKLM:\SOFTWARE\Classes\Installer\Products\*" -ErrorAction SilentlyContinue | 
    Where-Object { $_.ProductName -Like "*Autodesk*" }
    foreach ($cache in $InstallerCache) {
        try {
            Remove-Item $cache.PSPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-SACQuietLog "Failed to purge installer cache key $($cache.PSPath): $($_.Exception.Message)"
        }
    }

    Write-SACMsg "Wiping Registry Hive..." "Info"
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS\ -ErrorAction SilentlyContinue | Out-Null

    foreach ($location in $RegistryLocations) {
        # Resolve any wildcards in the path without using -Recurse
        $resolvedPaths = Get-Item $location -ErrorAction SilentlyContinue
    
        foreach ($regKey in $resolvedPaths) {
            $nativeRegPath = $regKey.Name
            try {
                # Use reg.exe because it avoids PowerShell's StackOverflowException on extremely deep/cyclic keys
                $regArgs = "delete `"$nativeRegPath`" /f"
                $regProc = Start-Process -FilePath "reg.exe" -ArgumentList $regArgs -Wait -NoNewWindow -PassThru
                if ($regProc.ExitCode -eq 0) {
                    Write-SACMsg "Removed registry tree: $nativeRegPath" "Success"
                }
                else {
                    Write-SACQuietLog "reg.exe failed to remove $nativeRegPath. Exit code: $($regProc.ExitCode)"
                }
            }
            catch {
                Write-SACQuietLog "Failed to execute reg delete for $($nativeRegPath): $($_.Exception.Message)"        
            }
        }
    }

    Write-SACMsg "Wiping File System..." "Info"
    Start-Sleep -Seconds 3
    foreach ($location in $DataLocations) {
        # Separate wildcard paths (need Get-Item expansion) from literal paths.
        # Get-Item returns nothing for a literal path whose root was partially deleted
        # by a previous uninstaller — even when subdirectories still exist on disk.
        # Test-Path -LiteralPath is immune to this and correctly detects those survivors.
        if ($location -match '\*') {
            $resolvedPaths = Get-Item -Path $location -ErrorAction SilentlyContinue |
                             Select-Object -ExpandProperty FullName
        } else {
            $resolvedPaths = if (Test-Path -LiteralPath $location) { @($location) } else { @() }
        }

        foreach ($fp in $resolvedPaths) {
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
                }
            } else {
                Write-SACMsg "Purged directory: $fp" "Success"
            }
        }
    }

    Invoke-SACShortcutPurge

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " PURGE COMPLETED in $($ElapsedTime)" "Success"
    Write-SACMsg "==========================================" "Info"

    if ($script:SACFailures.Count -gt 0) {
        Write-Host "`n[!] CRITICAL COMPONENT FAILURES DETECTED:" -ForegroundColor Red
        Write-Host "    (Note: These items may have been forcibly evicted/removed despite errors)" -ForegroundColor Gray
        foreach ($fail in $script:SACFailures) {
            Write-Host "   - $($fail.Component)" -ForegroundColor Yellow
            Write-Host "     Reason: $($fail.Reason)" -ForegroundColor DarkGray
        }
        Write-Host "`nPlease review the Debug Log for deeper diagnostics or resolve locks manually.`n" -ForegroundColor Red
    } else {
        Write-Host "`n[*] All operations completed successfully with no critical failures.`n" -ForegroundColor Green
    }

    # Persist outcome so the interactive menu can show a status badge on return
    $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
    if ($script:SACFailures.Count -gt 0) {
        $content = @(
            "AUTODESK MASTER PURGE - ITEMS REQUIRING ATTENTION",
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
        Operation      = 'Master Purge'
        Criticals      = $script:SACFailures.Count
        Warnings       = 0
        Elapsed        = $ElapsedTime
        LogDir         = $LogDir
        AttentionItems = if ($script:SACFailures.Count -gt 0) { $AttentionFile } else { $null }
    }

    Stop-Transcript | Out-Null
    return $script:SACLastRunStatus
}
