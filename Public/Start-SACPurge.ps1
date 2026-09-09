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
    # -WhatIf:$false - a preview is exactly when the audit trail matters, so the run
    # folder and transcript are always created.
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue -WhatIf:$false | Out-Null

    $TranscriptLog = "$($LogDir)\PurgeTranscript.log"
    $DebugLog = "$($LogDir)\PurgeDebug.log"

    Start-Transcript -Path $TranscriptLog -Append -Force -WhatIf:$false | Out-Null
    if ($IsPreview) { Write-SACMsg " PREVIEW (-WhatIf): no changes will be made." "Warning" }

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
        if ($script:SACFailures.Count -gt 0) {
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
            $content | Out-File -FilePath $AttentionFile -Encoding utf8 -WhatIf:$false
        }

        $script:SACLastRunStatus = [PSCustomObject]@{
            Operation        = 'Master Purge'
            Criticals        = $script:SACFailures.Count
            Warnings         = 0
            Elapsed          = $ElapsedTime
            LogDir           = $LogDir
            AttentionItems   = if ($script:SACFailures.Count -gt 0) { $AttentionFile } else { $null }
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
            foreach ($reason in (Get-SACPendingRebootReason)) { Write-Host "    - $reason" -ForegroundColor DarkYellow }
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
                Stop-Transcript | Out-Null
                return
            }
        }

        Write-Host "`nWARNING: This will forcefully terminate and remove all Autodesk applications.`n" -ForegroundColor Yellow
        $Response = Read-Host "Type 'YES' to proceed"
        if ($Response -ne "YES") { 
            Write-SACMsg "Execution aborted by user." "Warning"
            Stop-Transcript | Out-Null
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
            Write-SACMsg "WARNING: A pending system reboot has been detected: $((Get-SACPendingRebootReason) -join '; ')" "Warning"
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
        Stop-Transcript | Out-Null
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
    Stop-Transcript | Out-Null
    return $FinalStatus
}

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAYrt+KsFSpDaiH
# 82ncQM9zLUNNZTqY7bzdiU8ggYYdgaCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqUMIIakAIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMC
# EzMABiB0TAioxsL2jdQAAAAGIHQwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQgJtwlfLDba3pZKIz5rfztWu89cyG43U1wM39jpOP/2yEwDQYJKoZIhvcNAQEB
# BQAEggGAdnBUSA8MT8KFIwmJHhnSnF7Eq1YILHcvZtRj8o+ubEmYiZos3qWhoEO/
# MtEO6MCS4OdT8dTmYMNSxYjTJGg22TjCt9Ecmiyj+MZIJ5qy8/pTH4qYJG9DRmml
# YRZhoE7iFijPJ25QIF/3Z9yyy5UqX66VwOJALfOOFQvl+I1XxhpZu/sDO0Yd1aoC
# cJ3k85efCRENo/GzNb/hpw3WGArgf1mXd9DIRYxc5/DAZO4Ks/HXLhEWbdSBLPXG
# SdMpLpcKxKZouLEyLg/MvegkAoWgDdGrIWbv22MIzPAkzxrroj68XhnCBCIQr3JH
# Mml+u5i+57w4+542LGvgAqeiGN7lj3mbUsxhBZ8zzzX8JeQxAwsDw4agKQ83M3lX
# 86MhRay05CfndpB6JJsV4aqkOASzDREVNudx3etVMsyiSqsei39WFi4LzW+TFvnS
# vxk6JkOyxi94nmjd28y01FRCPIMhIcAxnGm9tZeu6V3P/JenN2CVtA5DxsNlNFaV
# h+JPa2AkoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIJVSQnc10mcs
# tK29PXUxo+KS1EQe3unW+d5Rw5PRzqZTAgZqhI09JbEYEzIwMjYwOTA5MTQzODM0
# LjgxMlowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UE
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
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJMQAAAAAAVzANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEwMjIyMDQ2NTNaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbAmeKSZ5ex7/jCymdV
# 7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkHkAI21MoCN+YWnhT8
# K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfFBK15JuD3JOzWuF2s
# uQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2PfZ154w041po+fDeT
# j0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4RbJXk8ONXyOOfXOxK2
# VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaLNNaYtm8AT/pZHYJ3
# 5mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07ZZm74JCsfhmrQ1ij
# VNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr2kPuj1jHDOXzUG4O
# 9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw/3bI/wBGNvLk6fLV
# nrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX6PNZv+vzSeqVeWWH
# KdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksai4TURnVj2mMCAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD7RKSpzAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ4uPENCSOwkRTnNog
# PLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTCFVrPBJKEWVshm+Ig
# 7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXhGueBxlnSvjkAX1oh
# iN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8OWweqTWZcGlJO4YjZ
# NI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oIWKKXWaBYJY5P3QPs
# iC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40fUNveRnwzMQnx8dM
# 2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgjvd/Deo7Xr371PFPP
# Yb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F9H9/wSLsMDUvWME7
# u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs30yBhuE3QhqT1YDZ2
# pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYuXcoeDcwe2UaC7EDO
# GD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1MYIHRjCCB0ICAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQMEAgEFAKCCBJ8wEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MTQzODM0WjAvBgkqhkiG9w0BCQQxIgQgLZmDRvqM
# jNzmUrpn1XUXWd48Tm9LLzAOaxOOtHc/e1gwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmFTHjbUjB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFck05XgounJMQAAAAAAVzCCA2EGCyqGSIb3DQEJEAISMYIDUDCCA0yh
# ggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3xaKKPXHnLw6BnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5LY9MwIhgPMjAyNjA5MDkwNDQ5MjNaGA8y
# MDI2MDkxMDA0NDkyM1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7ktj0wIBADAK
# AgEAAgIRAwIB/zAHAgEAAgITITAKAgUA7ky1UwIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQAcGzZo21MhC18092oBxB7xFxebaCJkodJTLWJDBFOBfdqFGPSC
# xqQeFDxSiZFMlK/PqTuQ7OeW2j5EJY2hSJWjdccLHiQx9hzz81j3mMM83Yd+P74f
# C2M6DJas0kVloWW8WzK5fqecpuXLLlQxXaJFteHtVPXIH2VySqggLuygkjK+dQHM
# xgSkpXeesWaGwEyrahuiN3cFJ/TP1Mu2JYjS7FlAIIE6QnlaP9/UNqVM2jBPyd89
# m47cSQ88DO+iPM5VtvQiQ0Hq7D65/uA95L1Kpvtd2B26CPprMkhC32Dnp6rEz647
# Ln4A9S1DmoR0MWBWeys1ULRXeM8r/yq2+/YdMA0GCSqGSIb3DQEBAQUABIICAIns
# jW9xOoUkYDdi9w5AyhpNRol0g/mt9hGxxrpYZaOZCuGp/xCQ/Ws2GtUDF3Q68eoq
# mprBiQbUspAUpaEm5DUQkTtX2IXXCC94ZKDgUpFXxyAe0a+8en1g2v70iJ4rVI6p
# 1xxOc7jbqagIRWvvJfx24EKbwhwxXlJQhrb3nM5bFVwAR0As3vOnzZ8ypPf/M3un
# GTl9wLaKXsj2oMQc43IepA5rSf6p7eFuc5yYOVDnJXhjDN7pff4BIy9keS/hCFfG
# NSUDNmHaQBMhQ3t9woeXbtmL8PDQGgHhOkNh0MAwUEawuqrZ61T5yw6uR1bCIkSI
# D2F9fY9aDFw6lQS64JOY/rSQ5D/fOI6nLC8XOefV+NwFMusfDDl+RxfUqg5Si0r3
# FPOBvTyVJDoTRruVgGB3grpoGcQ5Y5+VNWByyXeObQH+D9vPDLFJ81Lv4c3vT0IK
# gIm/AuOr7FnfifFqgoOgg5Ci1DglEp+4C8UwsxchGMgL8NJVlIfYEV6wapuZIKj2
# 7WXBT0BNqHK75w6HaAyHJuh4rR1Xc8BiSBLVOAGHYPxhKmzblKl72pvfiSAEqIm9
# EjdckjGsBuiCN9qVlDgK80ppqCHk2WVkokmgOl1MTrb4LmMCWiw7mSHV+tkACvFb
# T50dAm7e2wyLZhm6a680PMItnXPGNIf7KfpOoJdE
# SIG # End signature block
