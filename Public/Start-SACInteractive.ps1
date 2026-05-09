function Start-SACInteractive {
<#
.SYNOPSIS
    Interactive CLI main menu for the Surgical Autodesk Cleaner toolkit.
.DESCRIPTION
    Presents a top-level action menu that surfaces all SAC tools:
    Surgical Cleanup, Master Purge, User Profile Reset, Licensing Reset,
    Pre-Flight Scan, and Profile Backup Restore. Supports Out-ConsoleGridView
    on PowerShell 7+ with automatic fallback to a native console menu.
#>
    [CmdletBinding()]
    param()

    # -------------------------------------------------------------------------
    # Shared helper: multi-select list (GridView on PS7+, text fallback)
    # -------------------------------------------------------------------------
    function Invoke-SACSelection {
        param (
            [Parameter(Mandatory=$true)][array]$Items,
            [string]$Title
        )
        if ($Items.Count -eq 0) { return @() }

        if ($PSVersionTable.PSVersion.Major -ge 7) {
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
                    $selected = $Items | Out-ConsoleGridView -Title "$Title  (CTRL-A = Select All | SPACE = Toggle | ENTER = Confirm)" -OutputMode Multiple -ErrorAction Stop
                    if ($selected) { return @($selected) }
                    return @()
                } catch {
                    Write-Host "`n[!] UI rendering unavailable. Falling back to text menu..." -ForegroundColor Yellow
                }
            }
        }

        Write-Host "`n--- $Title ---" -ForegroundColor Cyan
        Write-Host "0. ALL ITEMS" -ForegroundColor Yellow
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host "$($i+1). $($Items[$i])"
        }
        $inputStr = Read-Host "`nEnter numbers to select (comma-separated, or 0 for all)"
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
        $keys = Get-ItemProperty -Path @(
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
            Where-Object { $_.Publisher -match 'Autodesk' -or $_.DisplayName -match 'Autodesk' } |
            Where-Object { $_.DisplayName -match '\b20\d{2}\b' } |
            Select-Object -ExpandProperty DisplayName -Unique |
            Sort-Object

        return $keys
    }

    # -------------------------------------------------------------------------
    # Surgical Cleanup flow (product + year selection → Start-SACCleanup)
    # -------------------------------------------------------------------------
    function Invoke-SurgicalCleanupFlow {
        param ([bool]$ScanOnly = $false)

        Write-Host "`nScanning registry for installed Autodesk products..." -ForegroundColor Cyan

        $UninstallKeys = Get-ItemProperty -Path @(
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue | Where-Object {
            $_.Publisher -match 'Autodesk' -or $_.DisplayName -match 'Autodesk'
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
            $SelectedYears = Invoke-SACSelection -Items $AvailableYears -Title "Step 1 of 2 — Select Target Years"
            if (-not $SelectedYears) { Write-Host "No years selected." -ForegroundColor Red; return }

            $FilteredProducts = @()
            foreach ($fp in ($FoundProducts | Where-Object { $_.Year -in $SelectedYears })) {
                $name = $fp.DisplayName -replace '\s*\b20\d{2}\b.*', '' -replace '^Autodesk\s+', ''
                $name = $name.Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { $name = "Autodesk Core" }
                if ($FilteredProducts -notcontains $name) { $FilteredProducts += $name }
            }
            $FilteredProducts = $FilteredProducts | Sort-Object

            $SelectedProducts = Invoke-SACSelection -Items $FilteredProducts -Title "Step 2 of 2 — Select Products for $($SelectedYears -join ', ')"
            if (-not $SelectedProducts) { Write-Host "No products selected." -ForegroundColor Red; return }
        }

        if ($ScanOnly) {
            Write-Host "`nBuilding pre-flight scan report..." -ForegroundColor Cyan

            $Report = @()

            foreach ($product in $SelectedProducts) {
                foreach ($year in $SelectedYears) {
                    $PackageName = "*$product*$year*"
                    $keys = Get-ItemProperty -Path @(
                        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
                    ) -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $PackageName }

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

            $ProcessesToKill = @("acad*","AcEventSync*","AcQMod*","revit*","3dsmax*","maya*","inventor*","roamer*","navisworks*","recap*","dwgviewr*")
            foreach ($procPattern in $ProcessesToKill) {
                Get-Process -Name $procPattern -ErrorAction SilentlyContinue | ForEach-Object {
                    $Report += [PSCustomObject]@{
                        Action="Terminate Process"; ComponentType="Active Process"
                        TargetProduct="Global"; TargetYear="Global"
                        DisplayName="$($_.ProcessName).exe"; Detail="PID: $($_.Id)"
                    }
                }
            }

            $SafePathsToSearch = @(
                "$($env:ProgramFiles)\Autodesk","$(${env:ProgramFiles(x86)})\Autodesk",
                "$($env:ProgramData)\Autodesk","$($env:PUBLIC)\Documents\Autodesk",
                "C:\Users\*\AppData\Local\Autodesk","C:\Users\*\AppData\Roaming\Autodesk"
            )
            foreach ($product in $SelectedProducts) {
                foreach ($year in $SelectedYears) {
                    foreach ($basePath in $SafePathsToSearch) {
                        Get-ChildItem -Path $basePath -Filter "*$product*$year*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                            $Report += [PSCustomObject]@{
                                Action="Purge Directory"; ComponentType="Orphaned Folder"
                                TargetProduct=$product; TargetYear=$year
                                DisplayName=$_.Name; Detail=$_.FullName
                            }
                        }
                    }
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
        } else {
            Write-Host "`nExecuting Surgical Cleanup..." -ForegroundColor Cyan
            Start-SACCleanup -TargetProducts $SelectedProducts -TargetYears $SelectedYears -AnyVendor
        }
    }

    # -------------------------------------------------------------------------
    # Main menu loop
    # -------------------------------------------------------------------------
    $installedProducts = Get-InstalledAutodeskSummary

    while ($true) {
        Clear-Host

        # Header
        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
        Write-Host "║        SURGICAL AUTODESK CLEANER                        ║" -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor DarkCyan

        if ($installedProducts -and $installedProducts.Count -gt 0) {
            Write-Host "║  Detected Products:" -ForegroundColor DarkCyan -NoNewline
            Write-Host (" " * 37) + "║" -ForegroundColor DarkCyan
            foreach ($p in ($installedProducts | Select-Object -First 5)) {
                $truncated = if ($p.Length -gt 52) { $p.Substring(0,49) + "..." } else { $p }
                $padded = $truncated.PadRight(52)
                Write-Host "║  " -ForegroundColor DarkCyan -NoNewline
                Write-Host "  $padded" -ForegroundColor Gray -NoNewline
                Write-Host "║" -ForegroundColor DarkCyan
            }
            if ($installedProducts.Count -gt 5) {
                $more = "  ...and $($installedProducts.Count - 5) more".PadRight(54)
                Write-Host "║$more║" -ForegroundColor DarkCyan
            }
        } else {
            Write-Host "║  No versioned Autodesk products detected on this machine.║" -ForegroundColor DarkCyan
        }

        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor DarkCyan
        Write-Host "║                                                          ║" -ForegroundColor DarkCyan
        Write-Host "║  [1]  Surgical Cleanup      Targeted uninstall           ║" -ForegroundColor DarkCyan
        Write-Host "║  [2]  Master Purge          Scorched-earth full removal  ║" -ForegroundColor DarkCyan
        Write-Host "║  [3]  Reset User Profile    Rename/clear AppData & reg   ║" -ForegroundColor DarkCyan
        Write-Host "║  [4]  Reset Licensing       Wipe CLM & token cache       ║" -ForegroundColor DarkCyan
        Write-Host "║  [5]  Pre-Flight Scan       Simulate & export CSV report  ║" -ForegroundColor DarkCyan
        Write-Host "║  [6]  Restore User Profile  List/restore SAC backups     ║" -ForegroundColor DarkCyan
        Write-Host "║  [Q]  Quit                                               ║" -ForegroundColor DarkCyan
        Write-Host "║                                                          ║" -ForegroundColor DarkCyan
        Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
        Write-Host ""

        $choice = Read-Host "  Select an option"

        switch ($choice.Trim().ToUpper()) {

            "1" {
                Invoke-SurgicalCleanupFlow -ScanOnly $false
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "2" {
                Write-Host "`n  *** MASTER PURGE — This will remove ALL Autodesk software ***" -ForegroundColor Red
                Write-Host "  This action is irreversible. All products, services, and" -ForegroundColor Yellow
                Write-Host "  registry data will be forcefully removed from this machine.`n" -ForegroundColor Yellow
                $confirm = Read-Host "  Type 'PURGE' to confirm"
                if ($confirm -eq "PURGE") {
                    Start-SACPurge
                } else {
                    Write-Host "  Master Purge cancelled." -ForegroundColor Yellow
                }
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "3" {
                Write-Host "`n  Roaming folders will be RENAMED (backed up) by default." -ForegroundColor Cyan
                Write-Host "  Local cache folders will be DELETED outright.`n" -ForegroundColor Cyan

                $delRoaming = $false
                $delChoice = Read-Host "  Delete Roaming instead of rename? (y/N)"
                if ($delChoice.Trim().ToLower() -eq "y") { $delRoaming = $true }

                if ($delRoaming) {
                    Reset-SACUserProfile -DeleteRoaming
                } else {
                    Reset-SACUserProfile
                }
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "4" {
                Write-Host "`n  FlexNet (adsk* stubs) removal is optional.`n" -ForegroundColor Cyan
                $flexChoice = Read-Host "  Also remove Autodesk FlexNet stubs? (y/N)"
                if ($flexChoice.Trim().ToLower() -eq "y") {
                    Reset-SACLicensing -IncludeFlexNet
                } else {
                    Reset-SACLicensing
                }
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "5" {
                Invoke-SurgicalCleanupFlow -ScanOnly $true
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "6" {
                Restore-SACUserProfile -List
                Write-Host ""
                $restoreChoice = Read-Host "  Restore a specific backup? Enter full path (or press Enter to return)"
                if (-not [string]::IsNullOrWhiteSpace($restoreChoice)) {
                    Restore-SACUserProfile -Restore -BackupPath $restoreChoice.Trim()
                }
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "Q" {
                Write-Host "`nExiting Surgical Autodesk Cleaner. Goodbye.`n" -ForegroundColor Cyan
                return
            }

            default {
                Write-Host "`n  Invalid option. Please select 1-6 or Q." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}
