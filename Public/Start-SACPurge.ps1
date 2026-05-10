function Start-SACPurge {
    <#
.SYNOPSIS
    Enterprise Autodesk Master Purge Script
.DESCRIPTION
    Hard-kills Autodesk services, uninstalls MSI and modern components, 
    purges registry/file remnants, and cleans desktops. Handles locked 
    files gracefully with dual-channel logging to prevent IO lock exceptions.
    Includes safe-evaluation regex removal of SQL Server LocalDB.
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

    $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "*adsk*", "*AdAppMgr*", "*AdODIS*", "*Autodesk*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*", "DesktopConnector*")

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
        # Writing to a separate debug file to prevent IO locks with Start-Transcript
        Add-Content -Path $DebugLog -Value "$($TimeStamp) [DEBUG] $($Message)"
    }

    function Test-Interactive {
        return [Environment]::UserInteractive -and -not $Silent -and ($host.Name -eq "ConsoleHost" -or $host.Name -match "ISE|VS Code")
    }

    function Invoke-DesktopCleanup {
        Write-Msg "Sweeping desktops for Autodesk shortcuts..." "Info"
        $DesktopPaths = @("$($env:PUBLIC)\Desktop", "C:\Users\*\Desktop", "C:\Users\*\OneDrive\Desktop")
        $ShortcutPatterns = @("*AutoCAD*.lnk", "*Revit*.lnk", "*Autodesk*.lnk", "*Civil 3D*.lnk", "*BIM*.lnk", "*Recap*.lnk")

        foreach ($path in $DesktopPaths) {
            foreach ($pattern in $ShortcutPatterns) {
                Get-ChildItem -Path $path -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        Remove-Item $_.FullName -Force -ErrorAction Stop
                        Write-Msg "Deleted shortcut: $($_.FullName)" "Success"
                    }
                    catch {
                        Write-QuietLog "Failed to delete shortcut $($_.FullName): $($_.Exception.Message)"
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
                Write-Msg "Hard killing process ID $($svc.ProcessId) for service $($svc.Name)" "Warning"
                try { Stop-Process -Id $svc.ProcessId -Force -ErrorAction Stop } catch { Write-QuietLog "Failed to kill PID $($svc.ProcessId): $($_.Exception.Message)" }
            }
            try {
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
                sc.exe delete $svc.Name 2>&1 | Out-Null
                Write-Msg "Removed service: $($svc.Name)" "Success"
            }
            catch {
                Write-QuietLog "Failed to disable/remove service $($svc.Name): $($_.Exception.Message)"
            }
        }
    }

    function Invoke-RemoveODISAndLicensing {
        Write-Msg "Targeting modern Autodesk ODIS and Licensing components..." "Info"
        $UninstallerPaths = @(
            "$($env:ProgramFiles)\Autodesk\AdODIS\V1\RemoveODIS.exe",
            "$(${env:CommonProgramFiles(x86)})\Autodesk Shared\AdskLicensing\uninstall.exe",
            "$($env:ProgramFiles)\Autodesk\Autodesk AdSSO\uninstall.exe"
        )

        foreach ($path in $UninstallerPaths) {
            if (Test-Path $path) {
                Write-Msg "Executing native uninstaller: $($path)" "Info"
                try {
                    $Process = Start-Process -FilePath $path -ArgumentList "--mode unattended", "-q" -PassThru -Wait -NoNewWindow -ErrorAction Stop
                    Write-Msg "Uninstaller exited with code: $($Process.ExitCode)" "Info"
                }
                catch {
                    Write-QuietLog "Failed to execute uninstaller $($path): $($_.Exception.Message)"
                }
            }
        }
    }

    function Invoke-RemoveSQLLocalDB {
        Write-Msg "Evaluating SQL Server LocalDB dependencies..." "Info"
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
                Write-Msg "Found unknown LocalDB instances. Skipping SQL removal to prevent breaking other apps." "Warning"
                foreach ($inst in $unknownInstances) { Write-QuietLog "Skipping due to unknown instance: $inst" }
                return
            }

            Write-Msg "Only Autodesk/Default LocalDB instances detected. Proceeding with SQL purge..." "Success"
            foreach ($inst in $instances) {
                Write-QuietLog "Stopping and deleting instance: $inst"
                & sqllocaldb stop "$inst" 2>&1 | Out-Null
                & sqllocaldb delete "$inst" 2>&1 | Out-Null
            }
        }
        else {
            Write-Msg "No active LocalDB instances found." "Info"
        }

        Write-Msg "Locating SQL Server LocalDB MSIs..." "Info"
        $LocalDbRegex = "^Microsoft SQL Server (2014|2019).*LocalDB"
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        $appsToUninstall = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue | 
        Where-Object { $_.DisplayName -match $LocalDbRegex }

        if ($appsToUninstall) {
            foreach ($app in $appsToUninstall) {
                $guid = $app.PSChildName
                $name = $app.DisplayName
                Write-Msg "Uninstalling: $name" "Info"
                $MsiLogFile = "$($LogDir)\$($name -replace '[\\/:\*\?"<>\|]','')_Uninstall.log"
            
                $process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $guid /qn /norestart REBOOT=ReallySuppress /L*v `"$($MsiLogFile)`"" -Wait -NoNewWindow -PassThru
            
                if ($process.ExitCode -eq 0) {
                    Write-Msg "Successfully uninstalled $name." "Success"
                }
                else {
                    Write-Msg "Uninstall for $name returned exit code $($process.ExitCode)." "Warning"
                }
            }
        }
        else {
            Write-QuietLog "Target SQL LocalDB installations not found in the registry."
        }

        $localDbAppData = "$env:LOCALAPPDATA\Microsoft\Microsoft SQL Server Local DB"
        if (Test-Path $localDbAppData) {
            Write-QuietLog "Purging residual LocalDB AppData..."
            Remove-Item -Path $localDbAppData -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Invoke-UninstallAutodeskProduct {
        param ([string]$ProductName, [string[]]$Versions)

        foreach ($version in $Versions) {
            Write-Msg "Starting uninstallation sequence for $($ProductName) $($version)..." "Info"

            Stop-AndRemoveService -ServiceName "Autodesk"
            Stop-AndRemoveService -ServiceName "Adsk"
            Stop-AndRemoveService -ServiceName "ODIS"

            # Disable Autodesk Scheduled Tasks FIRST to prevent processes from restarting
            Get-ScheduledTask -TaskPath "\Autodesk\*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
            Get-ScheduledTask -TaskName "*Autodesk*" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue

            foreach ($processName in $ProcessesToKill) {
                try { Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop } 
                catch { Write-QuietLog "Could not stop process $($processName): $($_.Exception.Message)" }
            }

            Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -Force -ErrorAction SilentlyContinue

            $PackageName = if ($version -eq "*") { "*$($ProductName)*" } else { "*$($ProductName)*$($version)*" }
        
            $vendorPattern = "^$"
            if (-not $AnyVendor) {
                $vendors = @("Autodesk")
                if ($AdditionalVendors) { $vendors += $AdditionalVendors }
                $vendorPattern = ($vendors | ForEach-Object { [regex]::Escape($_) }) -join '|'
            }

            $UninstallKeys = Get-ItemProperty -Path @(
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) -ErrorAction SilentlyContinue | Where-Object { 
                if (-not ($_.DisplayName -like $PackageName)) { return $false }
                if ($AnyVendor) { return $true }
                return ($_.Publisher -match $vendorPattern -or $_.DisplayName -match $vendorPattern)
            }

            foreach ($app in $UninstallKeys) {
                $ProductCode = $app.PSChildName
                $DisplayName = $app.DisplayName
                $UninstallString = $app.UninstallString
                $MsiLogFile = "$($LogDir)\$($DisplayName -replace '[\\/:\*\?"<>\|]','')_Uninstall.log"
            
                if ($ProductCode -match '^{.*}$') {
                    if ($UninstallString -match '^MsiExec\.exe') {
                        Write-Msg "MSI Executing: $($DisplayName)" "Info"
                        $Process = Start-Process "msiexec.exe" -ArgumentList "/x $($ProductCode) /qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable /L*v `"$($MsiLogFile)`"" -PassThru -WindowStyle Hidden
                    
                        $LastCpu = $null
                        $ZeroCpuTime = $null
                        while (!$Process.HasExited) {
                            Start-Sleep -Seconds 10
                            try {
                                $GrabProcess = Get-Process -Id $Process.Id -ErrorAction Stop
                                $currentCpu = $GrabProcess.CPU
                            
                                # If CPU time hasn't changed since last check, it's idle
                                if ($null -ne $LastCpu -and $currentCpu -eq $LastCpu) {
                                    if ($null -eq $ZeroCpuTime) { $ZeroCpuTime = Get-Date } 
                                    elseif (((Get-Date) - $ZeroCpuTime).TotalMinutes -ge 5) {
                                        Write-Msg "Process idle timeout. Terminating msiexec for $($DisplayName)." "Warning"
                                        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                                        break
                                    }
                                }
                                else { 
                                    $ZeroCpuTime = $null 
                                    $LastCpu = $currentCpu
                                }
                            }
                            catch { break }
                        }
                        Write-Msg "Exit code: $($Process.ExitCode) for $($DisplayName)" "Info"
                        if ($Process.ExitCode -ne 0 -and $Process.ExitCode -ne 3010 -and $Process.ExitCode -ne 1605) {
                            $script:SACFailures += [PSCustomObject]@{ Component = "MSI Uninstall: $DisplayName"; Reason = "Exit Code $($Process.ExitCode)" }
                        }
                    }
                    else {
                        Write-Msg "Custom Executing: $($DisplayName)" "Info"
                    
                        if ([string]::IsNullOrWhiteSpace($UninstallString)) {
                            Write-QuietLog "No UninstallString found for $($DisplayName). Skipping."
                            continue
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
                            Write-QuietLog "Could not parse executable path from UninstallString for $($DisplayName). Skipping."
                            continue
                        }

                        $FullArgs = "$($Arguments) /qn /quiet /norestart --mode unattended".Trim()
                    
                        try {
                            $Process = Start-Process -FilePath $ExePath -ArgumentList $FullArgs -PassThru -WindowStyle Hidden -ErrorAction Stop
                        
                            $LastCpu = $null
                            $ZeroCpuTime = $null
                            while (!$Process.HasExited) {
                                Start-Sleep -Seconds 10
                                try {
                                    $GrabProcess = Get-Process -Id $Process.Id -ErrorAction Stop
                                    $currentCpu = $GrabProcess.CPU
                                
                                    if ($null -ne $LastCpu -and $currentCpu -eq $LastCpu) {
                                        if ($null -eq $ZeroCpuTime) { $ZeroCpuTime = Get-Date } 
                                        elseif (((Get-Date) - $ZeroCpuTime).TotalMinutes -ge 5) {
                                            Write-Msg "Process idle timeout. Terminating custom uninstaller for $($DisplayName)." "Warning"
                                            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
                                            break
                                        }
                                    }
                                    else { 
                                        $ZeroCpuTime = $null 
                                        $LastCpu = $currentCpu
                                    }
                                }
                                catch { break }
                            }
                            Write-Msg "Exit code: $($Process.ExitCode) for $($DisplayName)" "Info"
                            if ($Process.ExitCode -ne 0 -and $Process.ExitCode -ne 3010 -and $Process.ExitCode -ne 1605) {
                                $script:SACFailures += [PSCustomObject]@{ Component = "Custom Uninstall: $DisplayName"; Reason = "Exit Code $($Process.ExitCode)" }
                            }
                        }
                        catch {
                            Write-QuietLog "Failed to execute custom uninstaller for $($DisplayName): $($_.Exception.Message)"
                            Write-Msg "Execution failed for $($DisplayName) (See Debug Log)" "Error"
                            $script:SACFailures += [PSCustomObject]@{ Component = "Uninstaller Execution: $DisplayName"; Reason = $_.Exception.Message }
                        }
                    }
                }
            
                try {
                    Remove-Item $app.PsPath -Recurse -Force -ErrorAction Stop
                    Write-Msg "Evicted Add/Remove Programs Key: $($DisplayName)" "Success"
                }
                catch {
                    Write-QuietLog "Failed to evict registry key for $($DisplayName) ($($app.PsPath)): $($_.Exception.Message)"
                    $script:SACFailures += [PSCustomObject]@{ Component = "Registry Eviction: $DisplayName"; Reason = $_.Exception.Message }
                }
            }
        }
    }

    # --- Execution Block ---
    Clear-Host
    Write-Msg "==========================================" "Info"
    Write-Msg " AUTODESK MASTER PURGE INITIALIZED" "Info"
    Write-Msg " Transcript: $($TranscriptLog)" "Info"
    Write-Msg " Debug Log:  $($DebugLog)" "Info"
    Write-Msg "==========================================" "Info"

    if (Test-Interactive) {
        Write-Host "`nWARNING: This will forcefully terminate and remove all Autodesk applications.`n" -ForegroundColor Yellow
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

    foreach ($product in $RemoveVersions) {
        Invoke-UninstallAutodeskProduct -ProductName $product.Name -Versions $product.Versions
    }

    Invoke-RemoveODISAndLicensing
    Invoke-RemoveSQLLocalDB

    Write-Msg "Purging Installer Cache..." "Info"
    $InstallerCache = Get-ItemProperty -Path "HKLM:\SOFTWARE\Classes\Installer\Products\*" -ErrorAction SilentlyContinue | 
    Where-Object { $_.ProductName -Like "*Autodesk*" }
    foreach ($cache in $InstallerCache) {
        try {
            Remove-Item $cache.PSPath -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-QuietLog "Failed to purge installer cache key $($cache.PSPath): $($_.Exception.Message)"
        }
    }

    Write-Msg "Wiping Registry Hive..." "Info"
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
                    Write-Msg "Removed registry tree: $nativeRegPath" "Success"
                }
                else {
                    Write-QuietLog "reg.exe failed to remove $nativeRegPath. Exit code: $($regProc.ExitCode)"
                }
            }
            catch {
                Write-QuietLog "Failed to execute reg delete for $($nativeRegPath): $($_.Exception.Message)"        
            }
        }
    }

    Write-Msg "Wiping File System..." "Info"
    Start-Sleep -Seconds 3 
    foreach ($location in $DataLocations) {
        # Resolve the paths first to handle wildcards properly
        $resolvedPaths = Get-Item -Path $location -ErrorAction SilentlyContinue
        foreach ($path in $resolvedPaths) {
            if (Test-Path $path.FullName) {
                try { 
                    Remove-Item $path.FullName -Recurse -Force -ErrorAction Stop 
                }
                catch { 
                    Write-QuietLog "Failed to remove directory $($path.FullName) (likely in use): $($_.Exception.Message)" 
                    $script:SACFailures += [PSCustomObject]@{ Component = "Directory Purge: $($path.FullName)"; Reason = $_.Exception.Message }
                }
            }
        }
    }

    Invoke-DesktopCleanup

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-Msg "==========================================" "Info"
    Write-Msg " PURGE COMPLETED in $($ElapsedTime)" "Success"
    Write-Msg "==========================================" "Info"

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
}
