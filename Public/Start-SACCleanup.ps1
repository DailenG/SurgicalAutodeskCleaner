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
    $LogDir = "C:\temp\AutodeskCleanup_$($ToDate)"
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

    function Invoke-UninstallAutodeskProduct {
        param ([string]$ProductName, [string]$Version)

        Write-Msg "Scanning for $($ProductName) $($Version)..." "Info"

        $PackageName = "*$($ProductName)*$($Version)*"
    
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

        if (-not $UninstallKeys) {
            Write-QuietLog "No registry match found for $($ProductName) $($Version)."
            return
        }

        foreach ($processName in $ProcessesToKill) {
            try { Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction Stop } 
            catch { Write-QuietLog "Could not stop process $($processName): $($_.Exception.Message)" }
        }

        foreach ($app in $UninstallKeys) {
            $ProductCode = $app.PSChildName
            $DisplayName = $app.DisplayName
            $UninstallString = $app.UninstallString
            $MsiLogFile = "$($LogDir)\$($DisplayName -replace '[\\/:\*\?"<>\|]','')_Uninstall.log"
        
            Write-Msg "Found matching installation: $($DisplayName)" "Warning"

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
        
            # Force registry eviction to clear out Add/Remove Programs
            try {
                Remove-Item $app.PSPath -Recurse -Force -ErrorAction Stop
                Write-Msg "Evicted Add/Remove Programs Key: $($DisplayName)" "Success"
            }
            catch {
                Write-QuietLog "Failed to evict registry key for $($DisplayName) ($($app.PSPath)): $($_.Exception.Message)"
                $script:SACFailures += [PSCustomObject]@{ Component = "Registry Eviction: $DisplayName"; Reason = $_.Exception.Message }
            }
        }
    
        # Run the surgical directory sweep after uninstallation attempts
        Invoke-SurgicalDirectoryCleanup -ProductName $ProductName -Version $Version
    }

    # --- Execution Block ---
    Clear-Host
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

    foreach ($product in $TargetProducts) {
        foreach ($year in $TargetYears) {
            Invoke-UninstallAutodeskProduct -ProductName $product -Version $year.ToString()
        }
    }

    $StopWatch.Stop()
    $ElapsedTime = "{0:mm} min {0:ss} sec" -f $StopWatch.Elapsed
    Write-Msg "==========================================" "Info"
    Write-Msg " CLEANUP COMPLETED in $($ElapsedTime)" "Success"
    Write-Msg "==========================================" "Info"

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

    Stop-Transcript | Out-Null
}
