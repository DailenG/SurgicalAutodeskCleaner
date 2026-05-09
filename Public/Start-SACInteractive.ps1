function Start-SACInteractive {
    <#
    .SYNOPSIS
        Interactive CLI menu for Surgical Autodesk Cleaner.
    .DESCRIPTION
        Scans the machine for installed Autodesk products, allowing you to select
        the target years and products for removal. Calls Start-SACCleanup dynamically.
    #>
    [CmdletBinding()]
    param(
        [switch]$ScanOnly
    )

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
                    $selected = $Items | Out-ConsoleGridView -Title "$Title (CTRL-A to Select All, SPACE to toggle)" -OutputMode Multiple -ErrorAction Stop
                    if ($selected) { return @($selected) }
                    return @()
                } catch {
                    Write-Host "`n[!] UI Rendering failed. Falling back to native console menu..." -ForegroundColor Yellow
                }
            }
        }
        
        Write-Host "`n--- $Title ---" -ForegroundColor Cyan
        Write-Host "0. ALL ITEMS" -ForegroundColor Yellow
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host "$($i+1). $($Items[$i])"
        }

        $inputStr = Read-Host "`nEnter numbers to select (comma-separated)"
        $selected = @()
        if ($inputStr -match '0') {
            return $Items
        }
        else {
            $indices = $inputStr -split ',' | ForEach-Object { $_.Trim() }
            foreach ($idx in $indices) {
                if ([int]$idx -gt 0 -and [int]$idx -le $Items.Count) {
                    $selected += $Items[[int]$idx - 1]
                }
            }
        }
        return $selected
    }

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

    Write-Host "`nHow would you like to target Autodesk uninstalls?" -ForegroundColor Cyan
    Write-Host "[1] By Product"
    Write-Host "[2] By Year"
    Write-Host "[3] By Product + Year (Default)"
    
    $modeInput = Read-Host "Select an option [1-3]"
    if ([string]::IsNullOrWhiteSpace($modeInput)) { $modeInput = "3" }
    
    if ($modeInput -notin @("1","2","3")) {
        Write-Host "Invalid selection. Defaulting to By Product + Year." -ForegroundColor Yellow
        $modeInput = "3"
    }

    $SelectedProducts = @()
    $SelectedYears = @()

    if ($modeInput -eq "1") {
        $SelectedProducts = Invoke-SACSelection -Items $AllAppNames -Title "Available Products"
        if (-not $SelectedProducts) { Write-Host "No valid products selected. Exiting." -ForegroundColor Red; return }
        $SelectedYears = $AvailableYears
    }
    elseif ($modeInput -eq "2") {
        $SelectedYears = Invoke-SACSelection -Items $AvailableYears -Title "Available Autodesk Years"
        if (-not $SelectedYears) { Write-Host "No valid years selected. Exiting." -ForegroundColor Red; return }
        $SelectedProducts = $AllAppNames
    }
    elseif ($modeInput -eq "3") {
        $SelectedYears = Invoke-SACSelection -Items $AvailableYears -Title "Target Years"
        if (-not $SelectedYears) { Write-Host "No valid years selected. Exiting." -ForegroundColor Red; return }
        
        $FilteredProducts = $FoundProducts | Where-Object { $_.Year -in $SelectedYears }
        $FilteredAppNames = @()
        foreach ($fp in $FilteredProducts) {
            $name = $fp.DisplayName -replace '\s*\b20\d{2}\b.*', '' -replace '^Autodesk\s+', ''
            $name = $name.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { $name = "Autodesk Core" }
            if ($FilteredAppNames -notcontains $name) { $FilteredAppNames += $name }
        }
        $FilteredAppNames = $FilteredAppNames | Sort-Object
        
        $SelectedProducts = Invoke-SACSelection -Items $FilteredAppNames -Title "Target Products for Selected Years ($($SelectedYears -join ', '))"
        if (-not $SelectedProducts) { Write-Host "No valid products selected. Exiting." -ForegroundColor Red; return }
    }

    if ($ScanOnly) {
        Write-Host "`nSimulating Surgical Cleanup and building pre-flight report..." -ForegroundColor Cyan
        
        $Report = @()
        
        # 1. Uninstallation Actions
        foreach ($product in $SelectedProducts) {
            foreach ($year in $SelectedYears) {
                $PackageName = "*$product*$year*"
                
                $UninstallKeys = Get-ItemProperty -Path @(
                    'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
                ) -ErrorAction SilentlyContinue | Where-Object { 
                    $_.DisplayName -like $PackageName
                }

                foreach ($app in $UninstallKeys) {
                    $UninstallString = $app.UninstallString
                    $ActionType = if ($app.PSChildName -match '^{.*}$' -and $UninstallString -match '^MsiExec\.exe') { "MSI Uninstall" } else { "Custom Uninstall" }
                    
                    $Report += [PSCustomObject]@{
                        Action        = $ActionType
                        ComponentType = "Application"
                        TargetProduct = $product
                        TargetYear    = $year
                        DisplayName   = $app.DisplayName
                        Detail        = $UninstallString
                    }
                }
            }
        }

        # 2. Process Termination Actions
        $ProcessesToKill = @("acad*", "AcEventSync*", "AcQMod*", "revit*", "3dsmax*", "maya*", "inventor*", "roamer*", "navisworks*", "recap*", "dwgviewr*")
        foreach ($procPattern in $ProcessesToKill) {
            $foundProcs = Get-Process -Name $procPattern -ErrorAction SilentlyContinue
            foreach ($p in $foundProcs) {
                $Report += [PSCustomObject]@{
                    Action        = "Terminate Process"
                    ComponentType = "Active Process"
                    TargetProduct = "Global"
                    TargetYear    = "Global"
                    DisplayName   = "$($p.ProcessName).exe"
                    Detail        = "PID: $($p.Id)"
                }
            }
        }

        # 3. Directory Purge Actions
        $SafePathsToSearch = @(
            "$($env:ProgramFiles)\Autodesk",
            "$(${env:ProgramFiles(x86)})\Autodesk",
            "$($env:ProgramData)\Autodesk",
            "$($env:PUBLIC)\Documents\Autodesk"
        )
        foreach ($product in $SelectedProducts) {
            foreach ($year in $SelectedYears) {
                $SearchPattern = "*$product*$year*"
                foreach ($basePath in $SafePathsToSearch) {
                    if (Test-Path $basePath) {
                        $dirs = Get-ChildItem -Path $basePath -Filter $SearchPattern -Directory -ErrorAction SilentlyContinue
                        foreach ($d in $dirs) {
                            $Report += [PSCustomObject]@{
                                Action        = "Purge Directory"
                                ComponentType = "Orphaned Folder"
                                TargetProduct = $product
                                TargetYear    = $year
                                DisplayName   = $d.Name
                                Detail        = $d.FullName
                            }
                        }
                    }
                }
            }
        }

        if ($Report.Count -gt 0) {
            # Deduplicate just in case
            $Report = $Report | Select-Object -Unique *
            
            $OutPath = "$([Environment]::GetFolderPath('Desktop'))\Autodesk_ScanReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
            $Report | Export-Csv -Path $OutPath -NoTypeInformation -Force
            Write-Host "Scan Complete! Found $($Report.Count) actions to take." -ForegroundColor Green
            Write-Host "CSV Report saved to: $OutPath`n" -ForegroundColor Green
        } else {
            Write-Host "Scan Complete! No matching components would be removed." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "`nExecuting Surgical Cleanup..." -ForegroundColor Cyan
        Start-SACCleanup -TargetProducts $SelectedProducts -TargetYears $SelectedYears -AnyVendor
    }
}
