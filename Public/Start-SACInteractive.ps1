function Start-SACInteractive {
<#
.SYNOPSIS
    Interactive CLI main menu for the Surgical Autodesk Cleaner toolkit.
.DESCRIPTION
    Presents a top-level action menu that surfaces all SAC tools:
    Surgical Cleanup, Master Purge, User Profile Reset, Licensing Reset,
    Pre-Flight Scan, and Profile Backup Restore. Supports Out-ConsoleGridView
    on PowerShell 7+ with automatic fallback to a native console menu.

    Includes a conditional "View Attention Items" menu option that surfaces
    critical failure logs from the last run for immediate review.
#>
    [CmdletBinding()]
    param(
        [switch]$ScanOnly
    )

    # Always reset the target state on start to ensure a fresh session.
    # This prevents the target from 'sticking' between TUI entries in the same shell session.
    $script:SACTarget = [PSCustomObject]@{
        ComputerName = "localhost"
        Credential   = $null
        IsRemote     = $false
    }
    
    # Reset last run status for the fresh session
    $script:SACLastRunStatus = $null

    # Shared helpers (Test-SACRemoteSession and Invoke-SACPause) are imported from the Private folder.

    # -------------------------------------------------------------------------
    # Shared helper: multi-select list (GridView on PS7+, text fallback)
    # -------------------------------------------------------------------------
    function Invoke-SACSelection {
        param (
            [Parameter(Mandatory=$true)][array]$Items,
            [string]$Title,
            [switch]$ViewerOnly
        )
        if ($Items.Count -eq 0) { return @() }

        if ($PSVersionTable.PSVersion.Major -ge 7 -and -not (Test-SACRemoteSession)) {
            if (-not (Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue)) {
                try { Import-Module Microsoft.PowerShell.ConsoleGuiTools -ErrorAction Stop }
                catch {
                    try {
                        Write-Host "Installing Microsoft.PowerShell.ConsoleGuiTools for enhanced UI..." -ForegroundColor Cyan
                        Install-Module Microsoft.PowerShell.ConsoleGuiTools -Force -Scope CurrentUser -ErrorAction Stop
                        Import-Module Microsoft.PowerShell.ConsoleGuiTools -ErrorAction Stop
                    } catch {}
                }
            }
            if (Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue) {
                try {
                    $hint = if ($ViewerOnly) { "(Select items to copy to clipboard | ENTER = Close)" } else { "(CTRL-A = Select All | SPACE = Toggle | ENTER = Confirm)" }
                    $selected = $Items | Out-ConsoleGridView -Title "$Title  $hint" -OutputMode Multiple -ErrorAction Stop
                    if ($selected) { return @($selected) }
                    return @()
                } catch {
                    Write-Host "`n[!] UI rendering unavailable. Falling back to text menu..." -ForegroundColor Yellow
                }
            }
        }

        Write-Host "`n--- $Title ---" -ForegroundColor Cyan
        if (-not $ViewerOnly) {
            Write-Host "0. ALL ITEMS" -ForegroundColor Yellow
        }
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host "$($i+1). $($Items[$i])"
        }
        
        $inputStr = ""
        if ($ViewerOnly) {
            $inputStr = Read-Host "`n(Optional) Enter numbers to copy to clipboard (or press Enter to return)"
        } else {
            $inputStr = Read-Host "`nEnter numbers to select (comma-separated, or 0 for all)"
        }

        if ([string]::IsNullOrWhiteSpace($inputStr)) { return @() }
        if ($inputStr -match '0') { return $Items }
        $selected = @()
        $indices = $inputStr -split ',' | ForEach-Object { $_.Trim() }
        foreach ($idx in $indices) {
            if ($idx -match '^\d+$' -and [int]$idx -gt 0 -and [int]$idx -le $Items.Count) {
                $selected += $Items[[int]$idx - 1]
            }
        }
        return $selected
    }

    # -------------------------------------------------------------------------
    # Discover installed Autodesk products for header context
    # -------------------------------------------------------------------------
    function Get-InstalledAutodeskSummary {
        # Known primary/parent product keywords - these float to the top
        $PrimaryProducts = @(
            'AutoCAD','Revit','Civil 3D','Inventor','Navisworks','3ds Max','Maya',
            'Fusion','Vault','ReCap','Advance Steel','BIM 360','InfraWorks'
        )

        $registryBlock = {
            $regPaths = @(
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            $results = @()
            foreach ($path in $regPaths) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                        $dn = $_.GetValue("DisplayName")
                        $pb = $_.GetValue("Publisher")
                        if (($null -ne $dn -and $dn -match 'Autodesk') -or ($null -ne $pb -and $pb -match 'Autodesk')) {
                            if ($dn -match '\b20\d{2}\b') {
                                $results += $dn
                            }
                        }
                    }
                }
            }
            return $results | Select-Object -Unique
        }

        $all = if ($script:SACTarget.IsRemote) {
            $cmdParams = @{
                ComputerName = $script:SACTarget.ComputerName
                ScriptBlock  = $registryBlock
                ErrorAction  = "SilentlyContinue"
            }
            if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
            Invoke-Command @cmdParams
        } else {
            & $registryBlock
        }

        if (-not $all) { return @() }

        # Score: 0 = primary product, 1 = everything else
        $sorted = $all | Sort-Object {
            $name = $_
            $isPrimary = ($PrimaryProducts | Where-Object { $name -match [regex]::Escape($_) }).Count -gt 0
            if ($isPrimary) { 0 } else { 1 }
        }, { $_ }   # secondary sort: alphabetical within each group

        return $sorted
    }


    function Invoke-SurgicalCleanupFlow {
        param ([bool]$ScanOnly = $false, [switch]$BuildScript)

        Write-Host "`nScanning registry for installed Autodesk products..." -ForegroundColor Cyan

        $discoveryBlock = {
            $regPaths = @(
                'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            $results = @()
            foreach ($path in $regPaths) {
                if (Test-Path $path) {
                    Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                        $dn = $_.GetValue("DisplayName")
                        $pb = $_.GetValue("Publisher")
                        if (($null -ne $dn -and $dn -match 'Autodesk') -or ($null -ne $pb -and $pb -match 'Autodesk')) {
                            $results += [PSCustomObject]@{
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
            return $results
        }

        $UninstallKeys = if ($script:SACTarget.IsRemote) {
            $cmdParams = @{
                ComputerName = $script:SACTarget.ComputerName
                ScriptBlock  = $discoveryBlock
                ErrorAction  = "SilentlyContinue"
            }
            if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
            Invoke-Command @cmdParams
        } else {
            & $discoveryBlock
        }

        if (-not $UninstallKeys) {
            Write-Host "No Autodesk products found on this system." -ForegroundColor Yellow
            return
        }

        $FoundProducts = @()
        foreach ($app in $UninstallKeys) {
            if ($app.DisplayName -match '\b(20\d{2})\b') {
                $year = $matches[1]
                $FoundProducts += [PSCustomObject]@{
                    DisplayName = $app.DisplayName
                    Year        = [int]$year
                }
            }
        }

        if ($FoundProducts.Count -eq 0) {
            Write-Host "No versioned Autodesk products found." -ForegroundColor Yellow
            return
        }

        $AvailableYears = $FoundProducts.Year | Select-Object -Unique | Sort-Object
        $AllAppNames = @()
        foreach ($fp in $FoundProducts) {
            $name = $fp.DisplayName -replace '\s*\b20\d{2}\b.*', '' -replace '^Autodesk\s+', ''
            $name = $name.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "Autodesk Core" }
            if ($AllAppNames -notcontains $name) { $AllAppNames += $name }
        }
        $AllAppNames = $AllAppNames | Sort-Object

        Write-Host "`nHow would you like to target?" -ForegroundColor Cyan
        Write-Host "  [1] By Product"
        Write-Host "  [2] By Year"
        Write-Host "  [3] By Product + Year (recommended)"
        $modeInput = Read-Host "Select [1-3]"
        if ([string]::IsNullOrWhiteSpace($modeInput) -or $modeInput -notin @("1","2","3")) { $modeInput = "3" }

        $SelectedProducts = @()
        $SelectedYears    = @()

        if ($modeInput -eq "1") {
            $SelectedProducts = Invoke-SACSelection -Items $AllAppNames -Title "Select Products"
            if (-not $SelectedProducts) { Write-Host "No products selected." -ForegroundColor Red; return }
            $SelectedYears = $AvailableYears
        } elseif ($modeInput -eq "2") {
            $SelectedYears = Invoke-SACSelection -Items $AvailableYears -Title "Select Years"
            if (-not $SelectedYears) { Write-Host "No years selected." -ForegroundColor Red; return }
            $SelectedProducts = $AllAppNames
        } else {
            $SelectedYears = Invoke-SACSelection -Items $AvailableYears -Title "Step 1 of 2 - Select Target Years"
            if (-not $SelectedYears) { Write-Host "No years selected." -ForegroundColor Red; return }

            $FilteredProducts = @()
            foreach ($fp in ($FoundProducts | Where-Object { $_.Year -in $SelectedYears })) {
                $name = $fp.DisplayName -replace '\s*\b20\d{2}\b.*', '' -replace '^Autodesk\s+', ''
                $name = $name.Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { $name = "Autodesk Core" }
                if ($FilteredProducts -notcontains $name) { $FilteredProducts += $name }
            }
            $FilteredProducts = $FilteredProducts | Sort-Object

            $SelectedProducts = Invoke-SACSelection -Items $FilteredProducts -Title "Step 2 of 2 - Select Products for $($SelectedYears -join ', ')"
            if (-not $SelectedProducts) { Write-Host "No products selected." -ForegroundColor Red; return }
        }

        if ($ScanOnly) {
            Write-Host "`nBuilding pre-flight scan report..." -ForegroundColor Cyan

            $Report = @()

            foreach ($product in $SelectedProducts) {
                foreach ($year in $SelectedYears) {
                    $PackageName = "*$product*$year*"
                    $keys = $UninstallKeys | Where-Object { $_.DisplayName -like $PackageName }

                    foreach ($app in $keys) {
                        $actionType = if ($app.PSChildName -match '^{.*}$' -and $app.UninstallString -match '^MsiExec\.exe') { "MSI Uninstall" } else { "Custom Uninstall" }
                        $Report += [PSCustomObject]@{
                            Action="$actionType"; ComponentType="Application"
                            TargetProduct=$product; TargetYear=$year
                            DisplayName=$app.DisplayName; Detail=$app.UninstallString
                        }
                    }
                }
            }

            # Process discovery (remote-aware)
            $processDiscoveryBlock = {
                $ProcessesToKill = @("acad*","AcEventSync*","AcQMod*","revit*","3dsmax*","maya*","inventor*","roamer*","navisworks*","recap*","dwgviewr*")
                $results = @()
                foreach ($procPattern in $ProcessesToKill) {
                    Get-Process -Name $procPattern -ErrorAction SilentlyContinue | ForEach-Object {
                        $results += [PSCustomObject]@{ Name = $_.ProcessName; Id = $_.Id }
                    }
                }
                return $results
            }

            $FoundProcesses = if ($script:SACTarget.IsRemote) {
                $cmdParams = @{
                    ComputerName = $script:SACTarget.ComputerName
                    ScriptBlock  = $processDiscoveryBlock
                    ErrorAction  = "SilentlyContinue"
                }
                if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
                Invoke-Command @cmdParams
            } else {
                & $processDiscoveryBlock
            }

            foreach ($p in $FoundProcesses) {
                $Report += [PSCustomObject]@{
                    Action="Terminate Process"; ComponentType="Active Process"
                    TargetProduct="Global"; TargetYear="Global"
                    DisplayName="$($p.Name).exe"; Detail="PID: $($p.Id)"
                }
            }

            # File system discovery (remote-aware)
            $fsDiscoveryBlock = {
                param($prods, $years)
                $SafePathsToSearch = @(
                    "$($env:ProgramFiles)\Autodesk","$(${env:ProgramFiles(x86)})\Autodesk",
                    "$($env:ProgramData)\Autodesk","$($env:PUBLIC)\Documents\Autodesk",
                    "C:\Users\*\AppData\Local\Autodesk","C:\Users\*\AppData\Roaming\Autodesk"
                )
                $results = @()
                foreach ($product in $prods) {
                    foreach ($year in $years) {
                        foreach ($basePath in $SafePathsToSearch) {
                            Get-ChildItem -Path $basePath -Filter "*$product*$year*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                                $results += [PSCustomObject]@{ Name = $_.Name; FullName = $_.FullName; Product = $product; Year = $year }
                            }
                        }
                    }
                }
                return $results
            }

            $FoundDirs = if ($script:SACTarget.IsRemote) {
                $cmdParams = @{
                    ComputerName = $script:SACTarget.ComputerName
                    ScriptBlock  = $fsDiscoveryBlock
                    ArgumentList = @($SelectedProducts, $SelectedYears)
                    ErrorAction  = "SilentlyContinue"
                }
                if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
                Invoke-Command @cmdParams
            } else {
                & $fsDiscoveryBlock $SelectedProducts $SelectedYears
            }

            foreach ($d in $FoundDirs) {
                $Report += [PSCustomObject]@{
                    Action="Purge Directory"; ComponentType="Orphaned Folder"
                    TargetProduct=$d.Product; TargetYear=$d.Year
                    DisplayName=$d.Name; Detail=$d.FullName
                }
            }

            if ($Report.Count -gt 0) {
                $Report = $Report | Select-Object -Unique *
                $OutPath = "$([Environment]::GetFolderPath('Desktop'))\Autodesk_ScanReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                $Report | Export-Csv -Path $OutPath -NoTypeInformation -Force
                Write-Host "Scan Complete! $($Report.Count) actions identified." -ForegroundColor Green
                Write-Host "Report saved to: $OutPath`n" -ForegroundColor Green
            } else {
                Write-Host "Scan Complete! No matching components would be removed.`n" -ForegroundColor Yellow
            }
        } elseif ($BuildScript) {
            # ... (BuildScript logic stays largely the same for now, as it generates a local script)
            # ... (omitted for brevity in this replace call, will keep it if it fits)
            Write-Host "`nGenerating Deployment Script..." -ForegroundColor Cyan
            $OutPath = "$([Environment]::GetFolderPath('Desktop'))\SAC_Deployment_$(Get-Date -Format 'yyyyMMdd_HHmmss').ps1"
            $prodString = ($SelectedProducts | ForEach-Object { "`"$_`"" }) -join ", "
            $yearString = $SelectedYears -join ", "
            $command = "Start-SACCleanup -TargetProducts $prodString -TargetYears $yearString -Silent"
            
            $scriptContent = @"
<#
.SYNOPSIS
    Automated Surgical Autodesk Cleanup Deployment

.DESCRIPTION
    This script is designed to safely and silently remove specific versions 
    of Autodesk products from this workstation. It will automatically download
    and utilize the SurgicalAutodeskCleaner module from the PowerShell Gallery.

    Targeted Products: $($SelectedProducts -join ', ')
    Targeted Years: $($SelectedYears -join ', ')

.NOTES
    Generated by SAC Script Builder on $(Get-Date)
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ensure module is installed
if (-not (Get-Module -ListAvailable -Name SurgicalAutodeskCleaner)) {
    Write-Host "Installing SurgicalAutodeskCleaner from PSGallery..."
    
    $installParams = @{
        Name         = 'SurgicalAutodeskCleaner'
        Force        = $true
        AllowClobber = $true
        Scope        = 'CurrentUser'
    }
    if ((Get-Command Install-Module).Parameters.Keys -contains 'AcceptLicense') {
        $installParams['AcceptLicense'] = $true
    }
    
    Install-Module @installParams
}

Import-Module SurgicalAutodeskCleaner -Force

# Execute silent cleanup
Write-Host "Beginning silent Autodesk cleanup..."
$command
"@
            $scriptContent | Out-File -FilePath $OutPath -Encoding utf8
            Write-Host "`nDeployment Script Generated!" -ForegroundColor Green
            Write-Host "Saved to: $OutPath`n" -ForegroundColor Green
            Write-Host "Raw Command:" -ForegroundColor Cyan
            Write-Host "  $command`n" -ForegroundColor Gray
        } else {
            if ($script:SACTarget.IsRemote) {
                Write-Host "`nDispatching Surgical Cleanup to $($script:SACTarget.ComputerName)..." -ForegroundColor Cyan
                $prodArgs = ($SelectedProducts | ForEach-Object { "`"$_`"" }) -join ","
                $yearArgs = $SelectedYears -join ","
                $remoteCmd = "Start-SACCleanup -TargetProducts $prodArgs -TargetYears $yearArgs -Silent"
                
                return Invoke-SACRemote -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -Command $remoteCmd -AutoInstall
            } else {
                Write-Host "`nExecuting Surgical Cleanup..." -ForegroundColor Cyan
                return Start-SACCleanup -TargetProducts $SelectedProducts -TargetYears $SelectedYears
            }
        }
    }

    # -------------------------------------------------------------------------
    # Main menu loop
    # -------------------------------------------------------------------------
    $needsRefresh = $true
    $installedProducts = @()

    if ($ScanOnly) {
        Invoke-SurgicalCleanupFlow -ScanOnly $true
        return
    }

    while ($true) {
        if (-not (Test-SACRemoteSession)) { Clear-Host }
        else { Write-Host "`n--- SAC Main Menu ---`n" -ForegroundColor Cyan }

        if ($needsRefresh) {
            $scanTarget = if ($script:SACTarget.IsRemote) { $script:SACTarget.ComputerName } else { "Local Machine" }
            Write-Host "  Scanning ${scanTarget} for installed Autodesk products..." -ForegroundColor DarkGray
            
            try {
                $installedProducts = Get-InstalledAutodeskSummary
            } catch {
                Write-Host "  [!] Discovery scan failed: $($_.Exception.Message)" -ForegroundColor Red
                $installedProducts = @()
            }
            $needsRefresh = $false

            # Re-clear after scan to show the clean menu
            if (-not (Test-SACRemoteSession)) { Clear-Host }
        }

        # Box-drawing characters generated at runtime via [char] casts.
        # Source file stays pure 7-bit ASCII - no BOM or encoding dependency.
        $TL = [string][char]0x2554  # top-left corner
        $TR = [string][char]0x2557  # top-right corner
        $BL = [string][char]0x255A  # bottom-left corner
        $BR = [string][char]0x255D  # bottom-right corner
        $ML = [string][char]0x2560  # mid-left tee
        $MR = [string][char]0x2563  # mid-right tee
        $H  = [string][char]0x2550  # horizontal double line
        $V  = [string][char]0x2551  # vertical double line

        # Fixed inner width (between the vertical borders) = 80 chars
        $W = 80

        function Write-BoxLine {
            param(
                [string]$Text = "",
                [string]$Color = "Cyan",
                [string]$BorderColor = "DarkCyan"
            )
            $inner = " $Text".PadRight($W)
            Write-Host $V -ForegroundColor $BorderColor -NoNewline
            Write-Host $inner -ForegroundColor $Color -NoNewline
            Write-Host $V -ForegroundColor $BorderColor
        }

        $border     = $H * $W
        $borderLine = $V + (" " * $W) + $V

        # Top border + title
        $title     = "  SURGICAL AUTODESK CLEANER  v2.3.6-beta"
        $titlePad  = $title.PadLeft(($W + $title.Length) / 2)
        Write-Host "$TL$border$TR" -ForegroundColor DarkCyan
        Write-BoxLine -Text $titlePad -Color "Cyan"
        Write-Host "$ML$border$MR" -ForegroundColor DarkCyan

        # Detected products
        if ($installedProducts -and $installedProducts.Count -gt 0) {
            Write-BoxLine -Text "Detected Products:" -Color "DarkCyan"
            foreach ($p in ($installedProducts | Select-Object -First 5)) {
                $truncated = if ($p.Length -gt ($W - 4)) { $p.Substring(0, $W - 7) + "..." } else { $p }
                Write-BoxLine -Text "  $truncated" -Color "Gray"
            }
            if ($installedProducts.Count -gt 5) {
                Write-BoxLine -Text "  ...and $($installedProducts.Count - 5) more" -Color "DarkGray"
            }
        } else {
            Write-BoxLine -Text "  No versioned Autodesk products detected." -Color "Yellow"
        }

        # Last-run status badge
        if ($script:SACLastRunStatus) {
            $st = $script:SACLastRunStatus
            Write-Host "$ML$border$MR" -ForegroundColor DarkCyan
            if ($st.Criticals -gt 0) {
                Write-BoxLine -Text "  [!] Last Run ($($st.Operation)): Attention Required" -Color "Red" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      [$($st.Criticals)] critical item(s) failed" -Color "Red" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      [$($st.Warnings)] minor notice(s) logged" -Color "DarkGray" -BorderColor "DarkCyan"
                Write-BoxLine -Text "  Log: $($st.LogDir)" -Color "DarkGray" -BorderColor "DarkCyan"
            } elseif ($st.Warnings -gt 0) {
                Write-BoxLine -Text "  [~] Last Run ($($st.Operation)): Attention Items" -Color "DarkYellow" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      [$($st.Warnings)] minor notice(s) logged" -Color "DarkYellow" -BorderColor "DarkCyan"
                Write-BoxLine -Text "  Log: $($st.LogDir)" -Color "DarkGray" -BorderColor "DarkCyan"
            } else {
                Write-BoxLine -Text "  [OK] Last Run ($($st.Operation)): Completed successfully" -Color "Green" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      Time elapsed: $($st.Elapsed)" -Color "Green" -BorderColor "DarkCyan"
                Write-BoxLine -Text "  Log: $($st.LogDir)" -Color "DarkGray" -BorderColor "DarkCyan"
            }
        }

        # Menu options
        Write-Host "$ML$border$MR" -ForegroundColor DarkCyan
        Write-Host $borderLine    -ForegroundColor DarkCyan
        Write-BoxLine -Text "  [1]  Surgical Cleanup       Targeted uninstall by product/year"
        Write-BoxLine -Text "  [2]  Master Purge           Scorched-earth full system removal"
        Write-BoxLine -Text "  [3]  Reset User Profile     Rename/clear per-user AppData and reg"
        Write-BoxLine -Text "  [4]  Reset Licensing        Wipe CLM, token cache and FlexNet"
        Write-BoxLine -Text "  [5]  Pre-Flight Scan        Simulate cleanup, export CSV report"
        Write-BoxLine -Text "  [6]  Build Cleanup Script   Build an SAC script to run later"
        Write-BoxLine -Text "  [7]  Restore User Profile   List/restore SAC backup folders"
        Write-BoxLine -Text "  [8]  View All Products      List all detected Autodesk software"
        if ($script:SACLastRunStatus.LogDir) {
            $vColor = if ($script:SACLastRunStatus.Criticals -gt 0) { "Red" } else { "Yellow" }
            Write-BoxLine -Text "  [L]  View Last Run Logs     Examine transcript or attention items" -Color $vColor
        }
        Write-Host $borderLine    -ForegroundColor DarkCyan
        $targetStr = if ($script:SACTarget.IsRemote) { 
            if ($script:SACTarget.Credential.UserName) { "$($script:SACTarget.ComputerName) ($($script:SACTarget.Credential.UserName))" }
            else { $script:SACTarget.ComputerName }
        } else { "Local Machine" }
        Write-BoxLine -Text "  [T]  Target Remote Machine  Currently: $targetStr" -Color "Yellow"
        Write-BoxLine -Text "  [Q]  Quit"
        if ($PSVersionTable.PSVersion.Major -lt 7) {
            Write-Host $borderLine    -ForegroundColor DarkCyan
            Write-BoxLine -Text "  Notice: Interactive mode is best experienced in PowerShell 7 (Core)+" -Color "DarkGray"
        }
        Write-Host $borderLine    -ForegroundColor DarkCyan
        Write-Host "$BL$border$BR" -ForegroundColor DarkCyan
        Write-Host ""

        $choice = Read-Host "  Select an option"

        switch ($choice.Trim().ToUpper()) {

            "1" {
                $script:SACLastRunStatus = Invoke-SurgicalCleanupFlow -ScanOnly $false
                $needsRefresh = $true
                Invoke-SACPause
            }

            "2" {
                Write-Host "`n  *** MASTER PURGE - This will remove ALL Autodesk software ***" -ForegroundColor Red
                Write-Host "  This action is irreversible. All products, services, and" -ForegroundColor Yellow
                Write-Host "  registry data will be forcefully removed from this machine.`n" -ForegroundColor Yellow
                $confirm = Read-Host "  Type 'PURGE' to confirm"
                if ($confirm -eq "PURGE") {
                    if ($script:SACTarget.IsRemote) {
                        Write-Host "`n  Dispatching Master Purge to $($script:SACTarget.ComputerName)..." -ForegroundColor Cyan
                        $script:SACLastRunStatus = Invoke-SACRemote -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -Command "Start-SACPurge -Silent" -AutoInstall
                    } else {
                        $script:SACLastRunStatus = Start-SACPurge
                    }
                    $needsRefresh = $true
                } else {
                    Write-Host "  Master Purge cancelled." -ForegroundColor Yellow
                }
                Invoke-SACPause
            }

            "3" {
                Write-Host "`n  Roaming folders will be RENAMED (backed up) by default." -ForegroundColor Cyan
                Write-Host "  Local cache folders will be DELETED outright.`n" -ForegroundColor Cyan

                $delRoaming = $false
                $delChoice = Read-Host "  Delete Roaming instead of rename? (y/N)"
                if ($delChoice.Trim().ToLower() -eq "y") { $delRoaming = $true }

                if ($script:SACTarget.IsRemote) {
                    Write-Host "`n  Dispatching Profile Reset to $($script:SACTarget.ComputerName)..." -ForegroundColor Cyan
                    $flags = if ($delRoaming) { "-DeleteRoaming -Silent" } else { "-Silent" }
                    $script:SACLastRunStatus = Invoke-SACRemote -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -Command "Reset-SACUserProfile $flags" -AutoInstall
                } else {
                    if ($delRoaming) { $script:SACLastRunStatus = Reset-SACUserProfile -DeleteRoaming } else { $script:SACLastRunStatus = Reset-SACUserProfile }
                }
                $needsRefresh = $true
                Invoke-SACPause
            }

            "4" {
                Write-Host "`n  FlexNet (adsk* stubs) removal is optional.`n" -ForegroundColor Cyan
                $flexChoice = Read-Host "  Also remove Autodesk FlexNet stubs? (y/N)"
                $includeFlex = ($flexChoice.Trim().ToLower() -eq "y")

                if ($script:SACTarget.IsRemote) {
                    Write-Host "`n  Dispatching Licensing Reset to $($script:SACTarget.ComputerName)..." -ForegroundColor Cyan
                    $flags = if ($includeFlex) { "-IncludeFlexNet -Silent" } else { "-Silent" }
                    $script:SACLastRunStatus = Invoke-SACRemote -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -Command "Reset-SACLicensing $flags" -AutoInstall
                } else {
                    if ($includeFlex) { $script:SACLastRunStatus = Reset-SACLicensing -IncludeFlexNet } else { $script:SACLastRunStatus = Reset-SACLicensing }
                }
                $needsRefresh = $true
                Invoke-SACPause
            }

            "5" {
                Invoke-SurgicalCleanupFlow -ScanOnly $true
                Invoke-SACPause
            }

            "6" {
                Invoke-SurgicalCleanupFlow -BuildScript
                Invoke-SACPause
            }

            "7" {
                Restore-SACUserProfile -List
                Write-Host ""
                $restoreChoice = Read-Host "  Restore a specific backup? Enter full path (or press Enter to return)"
                if (-not [string]::IsNullOrWhiteSpace($restoreChoice)) {
                    Restore-SACUserProfile -Restore -BackupPath $restoreChoice.Trim()
                    $needsRefresh = $true
                }
                Invoke-SACPause
            }

            "8" {
                $selected = Invoke-SACSelection -Items $installedProducts -Title "Detected Autodesk Products on ${targetStr}" -ViewerOnly
                if ($selected) {
                    try {
                        $text = $selected -join "`r`n"
                        $text | Set-Clipboard -ErrorAction Stop
                        Write-Host "`n  [OK] $($selected.Count) product(s) copied to clipboard." -ForegroundColor Green
                    } catch {
                        Write-Host "`n  [!] Failed to copy to clipboard (terminal/host restriction)." -ForegroundColor Yellow
                    }
                }
                Invoke-SACPause
            }

            "L" {
                if (-not $script:SACLastRunStatus.LogDir) {
                    Write-Host "`n  No log directory found for the last run." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                    continue
                }

                $logDir = $script:SACLastRunStatus.LogDir
                $files = @()

                Write-Host "`n  Retrieving log file list from ${targetStr}..." -ForegroundColor DarkGray
                if ($script:SACTarget.IsRemote) {
                    $files = Invoke-Command -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -ScriptBlock {
                        Get-ChildItem -Path $using:logDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                    } -ErrorAction SilentlyContinue
                } else {
                    $files = Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
                }

                if (-not $files) {
                    Write-Host "  No log files found in $logDir" -ForegroundColor Yellow
                    Invoke-SACPause
                    continue
                }

                $selectedFile = Invoke-SACSelection -Items $files -Title "Select Log File to View"
                if ($selectedFile) {
                    $filePath = Join-Path $logDir $selectedFile[0]
                    Write-Host "`n  Reading $selectedFile..." -ForegroundColor DarkGray
                    
                    $content = @()
                    if ($script:SACTarget.IsRemote) {
                        $content = Invoke-Command -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -ScriptBlock {
                            Get-Content -Path $using:filePath -Tail 5000 -ErrorAction SilentlyContinue
                        } -ErrorAction SilentlyContinue
                    } else {
                        $content = Get-Content -Path $filePath -Tail 5000 -ErrorAction SilentlyContinue
                    }

                    if ($content) {
                        Invoke-SACSelection -Items $content -Title "Viewing: $selectedFile (Last 5000 lines)" -ViewerOnly
                    } else {
                        Write-Host "  Log file is empty or inaccessible." -ForegroundColor Yellow
                        Invoke-SACPause
                    }
                }
            }

            "T" {
                $comp = Read-Host "`n  Enter remote computer name (or leave blank to reset)"
                if ([string]::IsNullOrWhiteSpace($comp) -or $comp.Trim().ToLower() -eq "local") {
                    $script:SACTarget = [PSCustomObject]@{ ComputerName = "localhost"; Credential = $null; IsRemote = $false }
                    $needsRefresh = $true
                    Write-Host "  Target successfully reset to LOCAL MACHINE." -ForegroundColor Green
                    Start-Sleep -Seconds 1
                } else {
                    $res = Connect-SACTarget -ComputerName $comp.Trim()
                    if ($res.Connected) {
                        # We consider it remote if it's NOT explicitly "localhost"
                        $script:SACTarget = [PSCustomObject]@{ 
                            ComputerName = $res.ComputerName; 
                            Credential = $res.Credential; 
                            IsRemote = ($res.ComputerName -ne "localhost") 
                        }
                        $needsRefresh = $true
                        Write-Host "  Target successfully set to REMOTE: $($res.ComputerName)." -ForegroundColor Green
                        Start-Sleep -Seconds 1
                    } else {
                        # Recalculate target display string for the error message to avoid stale data
                        $currentSetting = if ($script:SACTarget.IsRemote) { $script:SACTarget.ComputerName } else { "Local Machine" }
                        Write-Host "`n  [!] FAILED to connect to $($comp.Trim())." -ForegroundColor Red
                        Write-Host "      Target remains set to: $currentSetting" -ForegroundColor Yellow
                        Invoke-SACPause
                    }
                }
            }

            "Q" {
                Write-Host "`nExiting Surgical Autodesk Cleaner. Goodbye.`n" -ForegroundColor Cyan
                return
            }

            default {
                Write-Host "`n  Invalid option. Please select 1-7 or Q." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}
