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

    Add/Remove Programs entries are evicted only after the product's Windows Installer
    registration is confirmed gone. An uninstaller that returns 3010 ends the run: the
    reboot has to complete the MSI transaction before anything else is removed.

    Supports -WhatIf for a non-destructive preview of every action.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [string[]]$AdditionalVendors = @(),
        [switch]$AnyVendor,
        [switch]$ClearTemp,
        [switch]$Silent
    )

    $StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $IsPreview = [bool]$WhatIfPreference
    $script:SACFailures = @()
    $script:SACLockedItemsList = [System.Collections.Generic.List[string]]::new()
    $script:SACResidueReport = $null
    Reset-SACEvictionState

    # --- Configuration Arrays ---
    $RemoveVersions = @(
        @{Name = "AutoCAD"; Versions = @("*") },
        @{Name = "Civil 3D"; Versions = @("*") },
        @{Name = "Revit"; Versions = @("*") },
        @{Name = "Autodesk"; Versions = @("*") }
    )

    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "*adsk*", "AdskAccess*", "GenuineService*", "*AdAppMgr*", "*AdODIS*", "*Autodesk*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*", "DesktopConnector*", "fusion*", "alias*", "vault*", "moldflow*", "modlflow*", "netfabb*")

    $DataLocations = @(
        "$($env:ProgramData)\Autodesk",
        "C:\ProgramData\Autodesk Navisworks Freedom *",
        "$($env:PUBLIC)\Documents\Autodesk",
        "C:\Users\*\AppData\Local\Autodesk",
        "C:\Users\*\AppData\Local\Autodesk Navisworks",
        "C:\Users\*\AppData\Local\Autodesk,_Inc",
        "C:\Users\*\AppData\Local\Autodesk Inc",
        "C:\Users\*\AppData\Local\Autodesk Installer",
        "C:\Users\*\AppData\Local\Autodesk Ltd",
        "C:\Users\*\AppData\Local\Autodesk Navisworks Freedom *",
        "C:\Users\*\AppData\Local\AdSSO",
        "C:\Users\*\AppData\Local\Civil3DFeatures",
        "C:\Users\*\AppData\Roaming\Autodesk",
        "C:\Users\*\AppData\Roaming\Autodesk Navisworks",
        "C:\Users\*\AppData\Roaming\Autodesk,_Inc",
        "C:\Users\*\AppData\Roaming\Autodesk Inc",
        "C:\Users\*\AppData\Roaming\Autodesk Installer",
        "C:\Users\*\AppData\Roaming\Autodesk Ltd",
        "C:\Users\*\AppData\Roaming\Autodesk Navisworks Freedom *",
        "C:\Users\*\AppData\Roaming\AdSSO",
        "C:\Users\*\AppData\Roaming\Civil3DFeatures",
        "C:\Users\*\AppData\Local\Temp\Autodesk",
        "$($env:ProgramFiles)\Autodesk",
        "$($env:CommonProgramFiles)\Autodesk Shared",
        "$($env:CommonProgramFiles)\Autodesk",
        "$(${env:ProgramFiles(x86)})\Autodesk",
        "$(${env:CommonProgramFiles(x86)})\Autodesk Shared",
        "$(${env:CommonProgramFiles(x86)})\Autodesk",
        "C:\Autodesk",
        "C:\Windows\Temp\AdAppMgrUpdater",
        "C:\Users\*\ACCDocs",
        "C:\Users\*\BIM 360"
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
    if (-not $IsPreview) { New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null }

    $TranscriptLog = "$($LogDir)\PurgeTranscript.log"
    $DebugLog = "$($LogDir)\PurgeDebug.log"

    if (-not $IsPreview) { Start-Transcript -Path $TranscriptLog -Append -Force | Out-Null }

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

                        if ($isMatch -and (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $lnkBore.FullName -Action 'Delete shortcut')) {
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
    
        # The LIKE filter is deliberately broad, so every hit must also prove it belongs to
        # Autodesk before it is deleted: '%AGS%' on its own matches BTAGService, defragsvc
        # and diagsvc, none of which this tool has any business removing.
        $ServiceVendorPattern = 'Autodesk|Adsk|AdODIS|AdAppMgr|Genuine Service'
        $ServiceCim = Get-CimInstance Win32_Service -Filter "Name LIKE '%$($ServiceName)%' OR DisplayName LIKE '%$($ServiceName)%'"
        foreach ($svc in $ServiceCim) {
            $ServiceIdentity = @($svc.Name, $svc.DisplayName, $svc.PathName) -join ' '
            if ($ServiceIdentity -notmatch $ServiceVendorPattern) {
                Write-SACQuietLog "Skipping non-Autodesk service matched by '$ServiceName': $($svc.Name)"
                continue
            }

            if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $svc.Name -Action 'Stop and delete service')) { continue }

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
                if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $path -Action 'Run native uninstaller')) { continue }
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
                if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $inst -Action 'Stop and delete LocalDB instance')) { continue }
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
                if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $name -Action 'Uninstall SQL LocalDB')) { continue }
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
        if ((Test-Path $localDbAppData) -and (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $localDbAppData -Action 'Purge directory')) {
            Write-SACQuietLog "Purging residual LocalDB AppData..."
            Invoke-SACRobocopyPurge -TargetPath $localDbAppData | Out-Null
        }
    }

    function Invoke-UninstallAutodeskProduct {
        param ([string]$ProductName, [string[]]$Versions)

        foreach ($version in $Versions) {
            if (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'Autodesk processes and scheduled tasks' -Action 'Terminate and disable') {
                # Kill running processes before we start uninstallation
                foreach ($processName in $ProcessesToKill) {
                    try { Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop } 
                    catch { Write-SACQuietLog "Could not stop process $($processName): $($_.Exception.Message)" }
                }

                # Disable Autodesk Scheduled Tasks FIRST to prevent processes from restarting
                Get-ScheduledTask -TaskPath "\Autodesk\*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
                Get-ScheduledTask -TaskName "*Autodesk*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
            }

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
                        
                        if ($null -ne $dn -and ($dn -like $PackageName -or ($ProductName -eq "Autodesk" -and $null -ne $pb -and $pb -match "Autodesk"))) {
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
                
                if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $DisplayName -Action 'Uninstall')) { return }

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
                
                $ExitCode = $null
                if ($null -ne $Process) {
                    Watch-SACProcessTree -RootProcess $Process -DisplayName $DisplayName -TimeoutMinutes 20 -IdleTimeoutMinutes 5 -TailLogFile $MsiLogFile
                    $ExitCode = $Process.ExitCode
                    Write-SACMsg "  Exit code: $($ExitCode) for $($DisplayName)" "Info"
                    if ($ExitCode -ne 0 -and $ExitCode -ne 3010 -and $ExitCode -ne 1605) {
                        $script:SACFailures += [PSCustomObject]@{ Component = "Uninstall: $DisplayName"; Reason = "Exit Code $($ExitCode)" }
                    }
                }

                # The ARP key is only a projection of the installer hives. Evicting it while the
                # product is still registered (3010 pending reboot, or a failed 1603) hides a live
                # MSI registration from every ARP-driven tool, so the decision is made against the
                # registration itself.
                Invoke-SACArpEviction -App $app -ExitCode $ExitCode -Cmdlet $PSCmdlet | Out-Null
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
                if ($script:SACRebootRequired) { break }
                Invoke-SACUninstallEntry -app $item.App
                $baseName = $item.App.DisplayName -replace $Tier2Pattern,'' -replace $Tier3Pattern,'' -replace $Tier4Pattern,'' -replace '\s+', ' '
                $tier1Succeeded.Add($baseName.Trim()) | Out-Null
            }
            if ($script:SACRebootRequired) { return }

            # --- Tier 2: Service packs / updates ---
            foreach ($item in $Tier2) {
                if ($script:SACRebootRequired) { break }
                $dn = $item.App.DisplayName
                if ($tier1Succeeded.Count -gt 0) {
                    Write-SACMsg "  [SKIP uninstall] Parent removed - checking registration before eviction: $dn" "Info"
                    Invoke-SACArpEviction -App $item.App -Cmdlet $PSCmdlet | Out-Null
                } else {
                    Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                    Invoke-SACUninstallEntry -app $item.App
                }
            }
            if ($script:SACRebootRequired) { return }

            # --- Tier 3: Add-ons / extensions ---
            foreach ($item in $Tier3) {
                if ($script:SACRebootRequired) { break }
                $dn = $item.App.DisplayName
                if ($tier1Succeeded.Count -gt 0) {
                    Write-SACMsg "  [SKIP uninstall] Parent removed - checking registration before eviction: $dn" "Info"
                    Invoke-SACArpEviction -App $item.App -Cmdlet $PSCmdlet | Out-Null
                } else {
                    Write-SACMsg "  [FULL uninstall] No parent removed - running uninstaller: $dn" "Info"
                    Invoke-SACUninstallEntry -app $item.App
                }
            }
            if ($script:SACRebootRequired) { return }

            # --- Tier 4: Shared components (always full uninstall, last) ---
            foreach ($item in $Tier4) {
                if ($script:SACRebootRequired) { break }
                Invoke-SACUninstallEntry -app $item.App
            }
            if ($script:SACRebootRequired) { return }
        }
    }

    function Complete-SACPurgeRun {
        param ([switch]$Halted)

        # Entries whose eviction was refused earlier may have become evictable once the
        # installer-cache purge ran. Never retried when a reboot is outstanding.
        if (-not $Halted) { Invoke-SACDeferredArpEviction -Cmdlet $PSCmdlet }

        # Verification reads the installer hives, not Add/Remove Programs. An ARP-driven
        # rescan cannot see a product it has just orphaned.
        Write-SACMsg "Verifying Windows Installer hives for orphaned registrations..." "Info"
        $Residue = Get-SACInstallerResidue
        $script:SACResidueReport = Write-SACInstallerResidueReport -Residue $Residue -LogDir $LogDir -NoFile:$IsPreview
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
        if ($Halted) {
            Write-SACMsg " PURGE HALTED after $($ElapsedTime) - REBOOT REQUIRED" "Warning"
        } else {
            Write-SACMsg " PURGE COMPLETED in $($ElapsedTime)" "Success"
        }
        Write-SACMsg "==========================================" "Info"

        if ($script:SACRebootRequired) {
            Write-Host "`n[!] REBOOT REQUIRED - the purge stopped before completing." -ForegroundColor Yellow
            Write-Host "    An uninstaller returned 3010 (ERROR_SUCCESS_REBOOT_REQUIRED). Windows Installer" -ForegroundColor Gray
            Write-Host "    keeps the product registered until the reboot finishes the transaction, so the" -ForegroundColor Gray
            Write-Host "    Add/Remove Programs entry was kept and no further removal was attempted:" -ForegroundColor Gray
            foreach ($blocker in $script:SACRebootBlockers) {
                Write-Host "      - $blocker" -ForegroundColor Yellow
            }
            Write-Host "    Reboot, then re-run the purge to finish and re-verify.`n" -ForegroundColor Gray

            if ((Test-SACInteractive -Silent $Silent) -and -not $IsPreview) {
                $RebootResp = Read-Host "    Reboot now? (y/N)"
                if ($RebootResp.Trim().ToLower() -eq 'y' -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart computer')) {
                    Restart-Computer -Force
                }
            }
        }

        if ($script:SACFailures.Count -gt 0) {
            Write-Host "`n[!] CRITICAL COMPONENT FAILURES DETECTED:" -ForegroundColor Red
            foreach ($fail in $script:SACFailures) {
                Write-Host "   - $($fail.Component)" -ForegroundColor Yellow
                Write-Host "     Reason: $($fail.Reason)" -ForegroundColor DarkGray
            }
            Write-Host "`nPlease review the Debug Log for deeper diagnostics or resolve locks manually.`n" -ForegroundColor Red
        } else {
            Write-Host "`n[*] All operations completed successfully with no critical failures.`n" -ForegroundColor Green
        }

        # Prompt if there were locked files/folders and we are not running silently
        if ($script:SACLockedItemsList.Count -gt 0 -and -not $Silent -and -not $IsPreview) {
            Write-Host "`n[!] There were $($script:SACLockedItemsList.Count) files/directories locked or in-use." -ForegroundColor Yellow
            $resp = Read-Host "    Would you like to schedule them for removal on the next restart? (y/N)"
            if ($resp.Trim().ToLower() -eq 'y') {
                Write-Host "`n    Scheduling post-reboot cleanup..." -ForegroundColor Cyan
                $registered = Register-SACPostRebootCleanup -Paths $script:SACLockedItemsList.ToArray()
                if ($registered) {
                    Write-Host "    [OK] Post-reboot cleanup registered successfully. It will run silently on next logon." -ForegroundColor Green
                } else {
                    Write-Host "    [!] Failed to register post-reboot cleanup." -ForegroundColor Red
                }
                Start-Sleep -Seconds 2
            }
        }

        # Persist outcome so the interactive menu can show a status badge on return
        $AttentionFile = Join-Path $LogDir "AttentionItems.txt"
        if ($script:SACFailures.Count -gt 0 -and -not $IsPreview) {
            $content = @(
                "AUTODESK MASTER PURGE - ITEMS REQUIRING ATTENTION",
                "Timestamp: $(Get-Date)",
                "Log Directory: $LogDir",
                "----------------------------------------------------------",
                ""
            )
            if ($script:SACRebootRequired) {
                $content += "[!] REBOOT REQUIRED - the purge halted before completing."
                $content += "    Reboot the machine and re-run the purge before removing anything else."
                $content += ""
            }
            foreach ($fail in $script:SACFailures) {
                $content += "[!] $($fail.Component)"
                $content += "    Reason: $($fail.Reason)"
                $content += ""
            }
            $content | Out-File -FilePath $AttentionFile -Encoding utf8
        }

        $script:SACLastRunStatus = [PSCustomObject]@{
            Operation        = 'Master Purge'
            Criticals        = $script:SACFailures.Count
            Warnings         = 0
            Elapsed          = $ElapsedTime
            LogDir           = $LogDir
            AttentionItems   = if ($script:SACFailures.Count -gt 0 -and -not $IsPreview) { $AttentionFile } else { $null }
            RebootRequired   = [bool]$script:SACRebootRequired
            RebootBlockers   = @($script:SACRebootBlockers)
            InstallerResidue = $Residue.Total
            ResidueReport    = $script:SACResidueReport
        }

        return $script:SACLastRunStatus
    }

    # --- Execution Block ---
    Clear-Host
    Write-SACMsg "==========================================" "Info"
    Write-SACMsg " AUTODESK MASTER PURGE INITIALIZED" "Info"
    Write-SACMsg " Transcript: $($TranscriptLog)" "Info"
    Write-SACMsg " Debug Log:  $($DebugLog)" "Info"
    Write-SACMsg "==========================================" "Info"

    if (Test-SACInteractive -Silent $Silent) {
        $PendingReboot = Test-SACPendingReboot
        if ($PendingReboot) {
            Write-Host "[!] WARNING: A pending reboot is detected on this system." -ForegroundColor Yellow
            $ProceedPurge = Read-Host "Would you like to proceed with the Master Purge anyway? (y/N)"
            if ($ProceedPurge.Trim().ToLower() -ne 'y') {
                $RebootPrep = Read-Host "Are you planning to reboot, and would you like to disable or remove any applicable scheduled tasks and services first? (y/N)"
                if ($RebootPrep.Trim().ToLower() -eq 'y') {
                    Write-SACMsg "Disabling and removing Autodesk scheduled tasks and services before reboot..." "Warning"
                    Stop-AndRemoveService -ServiceName "Autodesk"
                    Stop-AndRemoveService -ServiceName "Adsk"
                    Stop-AndRemoveService -ServiceName "ODIS"
                    Stop-AndRemoveService -ServiceName "AdskAccessService"
                    Stop-AndRemoveService -ServiceName "AGS"
                    Stop-AndRemoveService -ServiceName "Genuine"
                    
                    Get-ScheduledTask -TaskPath "\Autodesk\*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
                    Get-ScheduledTask -TaskName "*Autodesk*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
                    Write-SACMsg "Autodesk scheduled tasks and services disabled/removed. Please reboot the machine and re-run the tool." "Success"
                } else {
                    Write-SACMsg "Execution aborted. No changes made." "Warning"
                }
                if (-not $IsPreview) { Stop-Transcript | Out-Null }
                return
            }
        }

        Write-Host "`nWARNING: This will forcefully terminate and remove all Autodesk applications.`n" -ForegroundColor Yellow
        $Response = Read-Host "Type 'YES' to proceed"
        if ($Response -ne "YES") { 
            Write-SACMsg "Execution aborted by user." "Warning"
            if (-not $IsPreview) { Stop-Transcript | Out-Null }
            return 
        }

        $ClearTempChoice = $ClearTemp
        if (-not $ClearTemp) {
            $TempResp = Read-Host "Would you like to clear all files in the Temp folders (user temp and Windows temp)? (y/N)"
            if ($TempResp.Trim().ToLower() -eq 'y') {
                $ClearTempChoice = $true
            }
        }
    }
    else {
        Write-SACMsg "Running in non-interactive/silent mode." "Info"
        if (Test-SACPendingReboot) {
            Write-SACMsg "WARNING: A pending system reboot has been detected." "Warning"
        }
        $ClearTempChoice = $ClearTemp
    }

    foreach ($product in $RemoveVersions) {
        Invoke-UninstallAutodeskProduct -ProductName $product.Name -Versions $product.Versions
        if ($script:SACRebootRequired) { break }
    }

    # A 3010 means the MSI transaction is incomplete. Continuing to strip services,
    # registry hives and directories out from under it is what turns a pending reboot
    # into an unrepairable product, so the run ends here.
    if ($script:SACRebootRequired) {
        Write-SACMsg "Reboot barrier reached - skipping service removal, registry hive wipe and file system wipe." "Warning"
        $HaltedStatus = Complete-SACPurgeRun -Halted
        if (-not $IsPreview) { Stop-Transcript | Out-Null }
        return $HaltedStatus
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
        if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $cache.PSPath -Action 'Remove installer cache key')) { continue }
        try {
            Remove-Item $cache.PSPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-SACQuietLog "Failed to purge installer cache key $($cache.PSPath): $($_.Exception.Message)"
        }
    }

    Write-SACMsg "Wiping Registry Hive..." "Info"
    # -WhatIf:$false - mapping a drive is not a change, and the preview needs it to resolve HKU:\*
    New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS\ -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null

    foreach ($location in $RegistryLocations) {
        # Resolve any wildcards in the path without using -Recurse
        $resolvedPaths = Get-Item $location -ErrorAction SilentlyContinue
    
        foreach ($regKey in $resolvedPaths) {
            $nativeRegPath = $regKey.Name
            if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $nativeRegPath -Action 'Delete registry tree')) { continue }
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
            if (-not (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target $fp -Action 'Purge directory')) { continue }
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
                    foreach ($item in $purgeResult.LockedItems) {
                        if (-not $script:SACLockedItemsList.Contains($item)) {
                            $script:SACLockedItemsList.Add($item)
                        }
                    }
                }
            } else {
                Write-SACMsg "Purged directory: $fp" "Success"
            }
        }
    }

    Invoke-SACShortcutPurge

    # Wipe specific Autodesk temp files and directories
    if (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'Autodesk temp files' -Action 'Delete') {
        Invoke-SACTempAutodeskCleanup
    }

    # Optionally clear the entire Temp folders (user and Windows Temp)
    if ($ClearTempChoice -and (Test-SACShouldProcess -Cmdlet $PSCmdlet -Target 'User and Windows temp folders' -Action 'Clear')) {
        Clear-SACTempFolders
    }

    $FinalStatus = Complete-SACPurgeRun
    if (-not $IsPreview) { Stop-Transcript | Out-Null }
    return $FinalStatus
}

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDq7UUX+DDgcUbW
# O+lzEUO3e5NYjiaHuwVhQHJuEu9oqqCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# IgQgXActwlcd6xT2rUbEirz93XtQA8Z4qVHcHryp2J3/EBEwDQYJKoZIhvcNAQEB
# BQAEggGAkdzkJvmy9Ef/9kr1/muoLu2mJXTUjVrsWuGBOXR2hbgfUPvFewnd98tg
# SyHJ9AKeZE8pRpmYOyLZ/j5n3+/R6m09oUr/A3HHA2SlTVYnORq3bWywPd7yuJMG
# D8nmbqPD1Eg6Do+eDuNzks+pXd7ryi34/Q+Q7CJMuXOsLVWqf8WacxTAuTTq+i2K
# zriKfzsa3z/znI8RIyYUNV26MrChppZl7iP4Z4GIn7LDfE9lv90/zOkskStf540G
# te3bfzxZQPuSUUxh5YRsqhCpg6t/3w1IV3uEHB1+2GK1EQ8SxALTtDWw0L0QT12e
# TsPlPxW+beUauMNZGgNFg2DAg+6rcyzAStRb76imJEIL+M1nOvoikdtE1IcwXyjd
# 4ijV01aLBbe/Tx/ql2L9yHFw1u5VVqpfXgAb2mL2qY7Gnk+WJsTIx2fp0BvhUpkt
# 3n6HUXVMRgOmHuGbOUp2UxPo5SrKSUx5Zs1xYwImhZOSLssiocNbC79RiNmLCW65
# YvOmv+fUoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIAj/ZONO7wII
# lvqtSyrjYwGvM0a0cWmOf5PBQnp81G9qAgZqhEkGSJsYEzIwMjYwOTA5MDIyNzU3
# LjU0N1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
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
# hkiG9w0BCQUxDxcNMjYwOTA5MDIyNzU3WjAvBgkqhkiG9w0BCQQxIgQg2gBbqG48
# 3OGTDIwM2KxYVD/OrqmsgpC7s3/ONxWNi8YwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
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
# Rz7cG01QVtwJ0uXG453Leu7vsh7HpsjQN5CgMA0GCSqGSIb3DQEBAQUABIICAHX7
# Wt9Yr6iC0HyI+HqVyhT+hXtjpNRMz+CuJZzbFcP2BDd2SJiP49mgTupcTqkS8sx8
# vTa2NfYg3Pe9xSwRIaovbEtWg8AOfPPcI6Y6025rJW4h3CgAXXd+y5Aq2Q6irCll
# +dK1wXhiljPvXQwea5qNB+G+pMnxCquRjZRxl9U8xqyZhPmVp6O1eoPrlss1JJvv
# 0n05VYlhu6OfXTIRL47G0JbJxMLkdl6254OqTQbgDKzLgXTbsw4eltWcrhE+j7SL
# YbBzh5rPQPRLBn+IZasNG4lt6ANkRCgrpD9B+t6112u/+MRY+s9P/M2F12kQlrG+
# NXOTht4YqKoZ1oLEvI9sRrH5RhARB/RM73XW/TNKGdQpeBy5yrCDxBy+0y/iEZbh
# m+Y29ZVt8UMHj+UtHhxSzvmRNCuLsXv3FQyIDLnSnWfdLbo09QmwU5+uBK4VfTYU
# BGT38Lva8xUO6vNb4kGlCsWt/eLzFafVBerDx5xjRn13gdODPi1jr7a978Kk1ddt
# tMg8VOoWi0n4jdTWNGGf+xrRFH/OIXUyVfuDTrvfVKNxPJoQ33GhEDis/2ugMTXO
# Qu8sR/jqJ/FbvmWQk6JA5xY/ot5fnBVyopjEZCMvDkQTFeB2QFjUeVIMeoJ24cTz
# WoI72yZfeXjUbU12QhNukmjYNwLjoJ2Scs2sb3qH
# SIG # End signature block
