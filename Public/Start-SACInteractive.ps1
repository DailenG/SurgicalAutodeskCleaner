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
    param(
        [switch]$ScanOnly
    )

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
        # Known primary/parent product keywords - these float to the top
        $PrimaryProducts = @(
            'AutoCAD','Revit','Civil 3D','Inventor','Navisworks','3ds Max','Maya',
            'Fusion','Vault','ReCap','Advance Steel','BIM 360','InfraWorks'
        )

        $all = Get-ItemProperty -Path @(
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        ) -ErrorAction SilentlyContinue |
            Where-Object { $_.Publisher -match 'Autodesk' -or $_.DisplayName -match 'Autodesk' } |
            Where-Object { $_.DisplayName -match '\b20\d{2}\b' } |
            Select-Object -ExpandProperty DisplayName -Unique

        # Score: 0 = primary product, 1 = everything else
        $sorted = $all | Sort-Object {
            $name = $_
            $isPrimary = ($PrimaryProducts | Where-Object { $name -match [regex]::Escape($_) }).Count -gt 0
            if ($isPrimary) { 0 } else { 1 }
        }, { $_ }   # secondary sort: alphabetical within each group

        return $sorted
    }


    # -------------------------------------------------------------------------
    # Surgical Cleanup flow (product + year selection -> Start-SACCleanup)
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

    if ($ScanOnly) {
        Invoke-SurgicalCleanupFlow -ScanOnly $true
        return
    }

    while ($true) {
        Clear-Host

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
        $title     = "  SURGICAL AUTODESK CLEANER  v1.2.9"
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
                Write-BoxLine -Text "  [!] Last Run ($($st.Operation)): $($st.Criticals) item(s) need attention" -Color "Red" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      $($st.Warnings) minor notice(s). Log: $($st.LogDir)" -Color "DarkGray" -BorderColor "DarkCyan"
            } elseif ($st.Warnings -gt 0) {
                Write-BoxLine -Text "  [~] Last Run ($($st.Operation)): OK  ($($st.Warnings) minor notice(s))" -Color "DarkYellow" -BorderColor "DarkCyan"
            } else {
                Write-BoxLine -Text "  [OK] Last Run ($($st.Operation)): Completed successfully in $($st.Elapsed)" -Color "Green" -BorderColor "DarkCyan"
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
        Write-BoxLine -Text "  [6]  Restore User Profile   List/restore SAC backup folders"
        if ($script:SACLastRunStatus.AttentionItems -and (Test-Path $script:SACLastRunStatus.AttentionItems)) {
            Write-BoxLine -Text "  [V]  View Attention Items   Open logs for items requiring attention" -Color "Yellow"
        }
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
                Invoke-SurgicalCleanupFlow -ScanOnly $false
                Write-Host "`nPress any key to return to menu..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }

            "2" {
                Write-Host "`n  *** MASTER PURGE - This will remove ALL Autodesk software ***" -ForegroundColor Red
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

            "V" {
                if ($script:SACLastRunStatus.AttentionItems -and (Test-Path $script:SACLastRunStatus.AttentionItems)) {
                    Write-Host "`nOpening Attention Items log in Notepad..." -ForegroundColor Cyan
                    Start-Process "notepad.exe" -ArgumentList "`"$($script:SACLastRunStatus.AttentionItems)`""
                } else {
                    Write-Host "`nNo attention items found or log file missing." -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
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
