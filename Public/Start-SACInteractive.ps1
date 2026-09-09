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
            function ConvertFrom-PackedMsiCode {
                param([string]$PackedCode)

                $normalized = $PackedCode.Trim().Trim('{', '}').Replace('-', '').ToUpperInvariant()
                if ($normalized -notmatch '^[0-9A-F]{32}$') { return $null }

                function ConvertFrom-ReversedText {
                    param([string]$Value)
                    $chars = $Value.ToCharArray()
                    [array]::Reverse($chars)
                    return -join $chars
                }
                function ConvertFrom-ReversedPairNibble {
                    param([string]$Value)
                    $result = New-Object System.Text.StringBuilder
                    for ($i = 0; $i -lt $Value.Length; $i += 2) {
                        $pair = $Value.Substring($i, [Math]::Min(2, $Value.Length - $i))
                        [void]$result.Append((ConvertFrom-ReversedText -Value $pair))
                    }
                    return $result.ToString()
                }

                $part1 = ConvertFrom-ReversedText -Value $normalized.Substring(0, 8)
                $part2 = ConvertFrom-ReversedText -Value $normalized.Substring(8, 4)
                $part3 = ConvertFrom-ReversedText -Value $normalized.Substring(12, 4)
                $part4 = ConvertFrom-ReversedPairNibble -Value $normalized.Substring(16, 4)
                $part5 = ConvertFrom-ReversedPairNibble -Value $normalized.Substring(20, 12)
                return "{$part1-$part2-$part3-$part4-$part5}".ToUpperInvariant()
            }

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
                                DisplayVersion       = $_.GetValue("DisplayVersion")
                                Publisher            = $pb
                                UninstallString      = $_.GetValue("UninstallString")
                                QuietUninstallString = $_.GetValue("QuietUninstallString")
                                InstallLocation      = $_.GetValue("InstallLocation")
                                InstallSource        = $_.GetValue("InstallSource")
                                LocalPackage         = $_.GetValue("LocalPackage")
                                PSChildName          = $_.PSChildName
                                PSPath               = $_.PSPath
                                Source               = "Add/Remove Programs"
                            }
                        }
                    }
                }
            }

            $hiddenProductRoots = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products',
                'HKLM:\SOFTWARE\Classes\Installer\Products'
            )
            $autodeskNamePattern = 'Autodesk|AutoCAD|Revit|Civil 3D|Inventor|Navisworks|ReCap|3ds Max|Maya|Vault|InfraWorks|Fusion|Alias|Moldflow|Netfabb|Advance Steel|DWG TrueView|OpenStudio|Unit Schemas|Steel Connections'

            foreach ($rootPath in $hiddenProductRoots) {
                if (-not (Test-Path $rootPath)) { continue }

                Get-ChildItem -Path $rootPath -ErrorAction SilentlyContinue | ForEach-Object {
                    $packedCode = $_.PSChildName
                    if ($packedCode -notmatch '^[0-9A-Fa-f]{32}$') { return }

                    $productKeyPath = Join-Path $rootPath $_.PSChildName
                    $propsPath = Join-Path $productKeyPath 'InstallProperties'
                    $productKey = Get-Item -LiteralPath $productKeyPath -ErrorAction SilentlyContinue
                    $propsKey = Get-Item -LiteralPath $propsPath -ErrorAction SilentlyContinue
                    $displayName = $null
                    $displayVersion = $null
                    $installLocation = $null
                    $installSource = $null
                    $localPackage = $null
                    $uninstallString = $null

                    if ($propsKey) {
                        $displayName = $propsKey.GetValue("DisplayName")
                        if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $propsKey.GetValue("ProductName") }
                        $displayVersion = $propsKey.GetValue("DisplayVersion")
                        $installLocation = $propsKey.GetValue("InstallLocation")
                        $installSource = $propsKey.GetValue("InstallSource")
                        $localPackage = $propsKey.GetValue("LocalPackage")
                        $uninstallString = $propsKey.GetValue("UninstallString")
                    }

                    if ([string]::IsNullOrWhiteSpace($displayName) -and $productKey) { $displayName = $productKey.GetValue("ProductName") }
                    $matchText = "$displayName $installLocation $installSource $uninstallString"
                    if ([string]::IsNullOrWhiteSpace($displayName) -or $matchText -notmatch $autodeskNamePattern) { return }

                    $productCode = ConvertFrom-PackedMsiCode -PackedCode $packedCode
                    $results += [PSCustomObject]@{
                        DisplayName          = $displayName
                        DisplayVersion       = $displayVersion
                        Publisher            = "Autodesk"
                        UninstallString      = $uninstallString
                        QuietUninstallString = $null
                        InstallLocation      = $installLocation
                        InstallSource        = $installSource
                        LocalPackage         = $localPackage
                        PSChildName          = $productCode
                        PSPath               = $productKeyPath
                        Source               = "Hidden MSI"
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
                        $packedCode = if ($app.PSChildName -match '^{.*}$') { try { ConvertTo-SACPackedMsiCode -ProductCode $app.PSChildName } catch { "" } } else { "" }
                        $Report += [PSCustomObject]@{
                            Action="$actionType"; ComponentType="Application"
                            TargetProduct=$product; TargetYear=$year
                            DisplayName=$app.DisplayName; Detail=$app.UninstallString
                            ProductCode=if ($app.PSChildName -match '^{.*}$') { $app.PSChildName } else { "" }
                            PackedCode=$packedCode
                            RegistryPath=$app.PSPath
                        }
                    }
                }
            }

            $hiddenState = $null
            if ($script:SACTarget.IsRemote) {
                $helperBundle = Get-SACHiddenInstallerStateFunctionBundle
                $hiddenStateBlock = {
                    param($helperDefinitions, $prods, $years, $keys)
                    . ([scriptblock]::Create($helperDefinitions))
                    Get-SACHiddenInstallerState -TargetProducts $prods -TargetYears $years -UninstallKeys $keys
                }
                $cmdParams = @{
                    ComputerName = $script:SACTarget.ComputerName
                    ScriptBlock  = $hiddenStateBlock
                    ArgumentList = @($helperBundle, $SelectedProducts, $SelectedYears, $UninstallKeys)
                    ErrorAction  = "SilentlyContinue"
                }
                if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
                $hiddenState = Invoke-Command @cmdParams
            } else {
                $hiddenState = Get-SACHiddenInstallerState -TargetProducts $SelectedProducts -TargetYears $SelectedYears -UninstallKeys $UninstallKeys
            }

            foreach ($hidden in @($hiddenState.HiddenProducts)) {
                $detailParts = @(
                    "Source=$($hidden.Source)",
                    "DisplayVersion=$($hidden.DisplayVersion)",
                    "InstallLocation=$($hidden.InstallLocation)",
                    "InstallSource=$($hidden.InstallSource)",
                    "LocalPackage=$($hidden.LocalPackage)"
                ) | Where-Object { $_ -notmatch '=$' }

                $Report += [PSCustomObject]@{
                    Action="Remove Hidden MSI Product Key"; ComponentType="Hidden MSI Product"
                    TargetProduct=$hidden.Product; TargetYear=$hidden.Year
                    DisplayName=$hidden.DisplayName; Detail=($detailParts -join "; ")
                    ProductCode=$hidden.ProductCode
                    PackedCode=$hidden.PackedCode
                    RegistryPath=$hidden.RegistryPath
                }
            }

            foreach ($stateItem in @($hiddenState.ProductStates | Where-Object { $_.IsInstalled })) {
                $Report += [PSCustomObject]@{
                    Action="MSI ProductState Installed"; ComponentType="MSI ProductState"
                    TargetProduct="Targeted"; TargetYear="Targeted"
                    DisplayName=$stateItem.ProductCode; Detail="ProductState=5; MSI still thinks installed"
                    ProductCode=$stateItem.ProductCode
                    PackedCode=$stateItem.PackedCode
                    RegistryPath=""
                }
            }

            foreach ($ref in @($hiddenState.ComponentReferences)) {
                $Report += [PSCustomObject]@{
                    Action="Remove MSI Component Reference"; ComponentType="MSI Component Reference"
                    TargetProduct=$ref.Product; TargetYear=$ref.Year
                    DisplayName=$ref.ValueName; Detail="Component=$($ref.ComponentKey); Matched=$($ref.MatchedTerm)"
                    ProductCode=""
                    PackedCode=$ref.MatchedTerm
                    RegistryPath=$ref.RegistryPath
                }
            }

            foreach ($ref in @($hiddenState.UpgradeCodeReferences)) {
                $Report += [PSCustomObject]@{
                    Action="Remove MSI UpgradeCode Reference"; ComponentType="MSI UpgradeCode Reference"
                    TargetProduct=$ref.Product; TargetYear=$ref.Year
                    DisplayName=$ref.ValueName; Detail="UpgradeCode=$($ref.UpgradeCode); Matched=$($ref.MatchedTerm)"
                    ProductCode=""
                    PackedCode=$ref.MatchedTerm
                    RegistryPath=$ref.RegistryPath
                }
            }

            foreach ($odis in @($hiddenState.OdisRemnants)) {
                $Report += [PSCustomObject]@{
                    Action=if ($odis.Action -eq 'Rename Folder') { "Rename ODIS Folder" } else { "Report ODIS Install.db Match" }
                    ComponentType=$odis.Source
                    TargetProduct=$odis.Product; TargetYear=$odis.Year
                    DisplayName=$odis.DisplayName; Detail="Matched=$($odis.MatchedTerm); PackageIds=$($odis.PackageIds)"
                    ProductCode=$odis.ProductCodes
                    PackedCode=$odis.PackedCodes
                    RegistryPath=$odis.Path
                }
            }

            foreach ($warning in @($hiddenState.RelativePathWarnings)) {
                $Report += [PSCustomObject]@{
                    Action="Review Relative Installer Path"; ComponentType="Warning"
                    TargetProduct=$warning.Product; TargetYear=$warning.Year
                    DisplayName=$warning.DisplayName; Detail="$($warning.PropertyName)=$($warning.Value)"
                    ProductCode=""
                    PackedCode=""
                    RegistryPath=$warning.SourcePath
                }
            }

            # Process discovery (remote-aware)
            $processDiscoveryBlock = {
                $ProcessesToKill = @("acad*","AcEventSync*","AcQMod*","revit*","*adsk*","AdskAccess*","GenuineService*","AGS*","3dsmax*","maya*","inventor*","roamer*","navisworks*","recap*","dwgviewr*")
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
                    ProductCode=""
                    PackedCode=""
                    RegistryPath=""
                }
            }

            # File system discovery (remote-aware)
            $fsDiscoveryBlock = {
                param($prods, $years)
                $SafePathsToSearch = @(
                    "$($env:ProgramFiles)\Autodesk","$(${env:ProgramFiles(x86)})\Autodesk",
                    "$($env:ProgramData)\Autodesk","$($env:ProgramData)",
                    "$($env:PUBLIC)\Documents\Autodesk",
                    "C:\Users\*\AppData\Local","C:\Users\*\AppData\Roaming"
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
                    ProductCode=""
                    PackedCode=""
                    RegistryPath=""
                }
            }

            if ($Report.Count -gt 0) {
                $Report = $Report | Select-Object Action,ComponentType,TargetProduct,TargetYear,DisplayName,Detail,ProductCode,PackedCode,RegistryPath -Unique
                $OutPath = "$([Environment]::GetFolderPath('Desktop'))\Autodesk_ScanReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
                $Report | Export-Csv -Path $OutPath -NoTypeInformation -Force
                Write-Host "Scan Complete! $($Report.Count) actions identified." -ForegroundColor Green
                if ($hiddenState) {
                    Write-Host "Hidden MSI products: $($hiddenState.Summary.HiddenMsiProducts); ProductState=5: $($hiddenState.Summary.ProductStateInstalled); Component refs: $($hiddenState.Summary.ComponentReferences); Upgrade-code refs: $($hiddenState.Summary.UpgradeCodeReferences); ODIS remnants: $($hiddenState.Summary.OdisRemnants)" -ForegroundColor Cyan
                }
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
    Install-Module -Name 'SurgicalAutodeskCleaner' -Force -AllowClobber -Scope 'CurrentUser'
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
        $title     = "  SURGICAL AUTODESK CLEANER  v2.10.1"
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
            if ($st.RebootRequired) {
                Write-BoxLine -Text "  [!] Last Run ($($st.Operation)): REBOOT REQUIRED - run halted" -Color "Red" -BorderColor "DarkCyan"
                Write-BoxLine -Text "      An uninstaller returned 3010; reboot, then re-run" -Color "Yellow" -BorderColor "DarkCyan"
                Write-BoxLine -Text "  Log: $($st.LogDir)" -Color "DarkGray" -BorderColor "DarkCyan"
            } elseif ($st.Criticals -gt 0) {
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
            if ($st.InstallerResidue -gt 0) {
                Write-BoxLine -Text "      [$($st.InstallerResidue)] orphaned installer registration(s) found" -Color "Red" -BorderColor "DarkCyan"
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
        Write-BoxLine -Text "  [9]  Repair ODIS Installer  Uninstall, clean/rename, & reinstall ODIS"
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

            "9" {
                if ($script:SACTarget.IsRemote) {
                    Write-Host "`n  Dispatching ODIS Installer Repair to $($script:SACTarget.ComputerName)..." -ForegroundColor Cyan
                    $script:SACLastRunStatus = Invoke-SACRemote -ComputerName $script:SACTarget.ComputerName -Credential $script:SACTarget.Credential -Command "Repair-SACODIS -Silent" -AutoInstall
                } else {
                    $script:SACLastRunStatus = Repair-SACODIS
                }
                $needsRefresh = $true
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
                    $cmdParams = @{
                        ComputerName = $script:SACTarget.ComputerName
                        ScriptBlock  = { Get-ChildItem -LiteralPath $using:logDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name }
                        ErrorAction  = "SilentlyContinue"
                    }
                    if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
                    $files = Invoke-Command @cmdParams
                } else {
                    $files = Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
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
                    
                    $content = $null
                    if ($script:SACTarget.IsRemote) {
                        $cmdParams = @{
                            ComputerName = $script:SACTarget.ComputerName
                            ScriptBlock  = { Get-Content -LiteralPath $using:filePath -Tail 5000 -ErrorAction SilentlyContinue }
                            ErrorAction  = "SilentlyContinue"
                        }
                        if ($script:SACTarget.Credential) { $cmdParams["Credential"] = $script:SACTarget.Credential }
                        $content = Invoke-Command @cmdParams
                    } else {
                        # Use a shared-read FileStream so the log can be read even if a transcript
                        # session still holds the file open (e.g. during a hung install).
                        try {
                            $fs = [System.IO.File]::Open($filePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
                            $rawText = $sr.ReadToEnd()
                            $sr.Close(); $fs.Close()
                            if ($rawText) {
                                $allLines = $rawText -split '\r?\n'
                                $content = if ($allLines.Count -gt 5000) { $allLines[-5000..-1] } else { $allLines }
                            }
                        } catch {
                            Write-Host "  [!] Could not open log file: $($_.Exception.Message)" -ForegroundColor Red
                        }
                    }

                    if ($content) {
                        $selected = Invoke-SACSelection -Items $content -Title "Viewing: $selectedFile (Last 5000 lines)" -ViewerOnly
                        if ($selected) {
                            try {
                                $text = $selected -join "`r`n"
                                $text | Set-Clipboard -ErrorAction Stop
                                Write-Host "`n  [OK] $($selected.Count) log line(s) copied to clipboard." -ForegroundColor Green
                            } catch {
                                Write-Host "`n  [!] Failed to copy to clipboard (terminal/host restriction)." -ForegroundColor Yellow
                            }
                            Invoke-SACPause
                        }
                    } else {
                        if (-not (Test-Path -LiteralPath $filePath)) {
                            Write-Host "  Log file not found: $filePath" -ForegroundColor Red
                        } else {
                            Write-Host "  Log file is empty or could not be read: $filePath" -ForegroundColor Yellow
                        }
                        Invoke-SACPause
                    }
                }
            }

            "T" {
                $comp = Read-Host "`n  Enter remote computer name (or leave blank to reset)"
                if ([string]::IsNullOrWhiteSpace($comp) -or $comp.Trim().ToLower() -eq "local") {
                    $script:SACTarget = [PSCustomObject]@{ ComputerName = "localhost"; Credential = $null; IsRemote = $false }
                    $needsRefresh = $true
                    $script:SACLastRunStatus = $null
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
                        $script:SACLastRunStatus = $null
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

# SIG # Begin signature block
# MII9NwYJKoZIhvcNAQcCoII9KDCCPSQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCxYWOEZYqqGdAr
# IhVMsh8koibwZQb0+uwF8b6ROvs2aaCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqRMIIajQIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMC
# EzMABiB0TAioxsL2jdQAAAAGIHQwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQg7voBojlq5LnmoWLM2ouDrH+pdIhjpKLqyNf/l+1/itkwDQYJKoZIhvcNAQEB
# BQAEggGAiI7IOM+JU5a7b9+JHZyNMUT7FOcGNkcLW+AYLrdm3z+TLmpuIeBF3Iu2
# Il9MATJS2yDhugKB6cEx1rRMopFC4zV0zbrhMo00JwrHP3/BIT3V+E2srPjA2HKb
# 5+PavhpPuTXjkWZ6Q75LyYkAME27VMbiYtkIAoRxf/zogZUbdGzOO+XfuDlJdI+n
# ue0RJpbOmF7gomP1ZreKiQIpiShbh0JMQCNFnAoEvibSWRvP73ovmvDFpwfbots0
# SczlK8o0Nny8Dds53fEpDJKghdczAoNU0oOa9isrx4p081r8TrJeChVAT7NpHNGr
# kwA/T0/xeRACh00Ko4ToNiSUKGT+85CBgq4WbgCw7acGH4cpE+284MVc/aemTQFk
# qRojqx/BNWZ4OSPSzu9SczmZBGY6ya6sxr4XP+r3QyhgzWHt9BqVUcMoMIc9yNxk
# YDofjf8/z5WdQAv2gWpO9kSsXjUgsoFHVX6IJpDX924+o8/XrR2d+VHAss5ou9/U
# PkukCz2WoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJKoZIhvcNAQcCoIIX
# 6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIM3tJxiCx77S
# RsR+4epR3FnCfIz1oUbhwG1QvuRhlZgJAgZqhGwzOyUYEzIwMjYwOTA5MTQzODMw
# LjY1OFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3QTAwLTA1RTAtRDk0NzE1MDMGA1UE
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
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFhlzes/odf80gAAAAAAWDANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTVaFw0yNjEwMjIyMDQ2NTVaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046N0EwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAnXg0pHaQ7PVAlln+HZZrJFcLoKbekhW1yL+QNBUgFFUsjZIK
# aqqN4oIJsJM3ps0rJNSO7ndCNRuZDX2Wgur3Ak77eXrloBXqZmO6ZVXeDNRCLldW
# 4A0/NfjzJ7XXkdEhjr81ghXEpR7zC+wbaNN+sPSxzLAZBeibDFP7Xws5wX0ZtIsN
# 1a2+Xq5bvWp3kRMytwskTjunRgeLZL/tBp237JVdRPFAQ9jYRKpCqUBo/v1xjBLR
# CV3PalKjnGfb3MN4U7jVyqifFHShcnW5CERRoBmUa6sygDzFSr8e3g93TPNLFUiv
# UE0GmLfbX5ceD1Gt1FcZ6x/JLVATzk5+BWHbMxwJIVkVPTqSSMjQ6KTKdcnq3pH0
# c4AFJp/glvcpq0U9fzZIjJGGvdpishlRl77RQtUhSjxHvCn3LC/xqQQwOHSQDsGh
# 6NX2D0RfsSyEtTAByAae+2w1HByTDTcmlTNLEuQLeCj1gNBdIWj0WOYyDtjjQ/8i
# TWY6ey1vb9qHljIj5HgIndT5P9MYk2Vg2e7hKUZNBNbA/hsgBsuoZ+IX89WvjEN9
# abF91S4OJVuinmKsLO/MLbnl7ikuD0dN6oA0YewyDQncs12sM9HOtu72QA/TZlef
# vW8r9xtMXAYoQlcGjsk8W4Uc7cfqVqbIPjdoc8ZxBzLcXcVyP4p5cyLwvkMCAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBRyjU3Fer4VxXJ+hjPcRJnxnRIJsDAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAHvrxIiVF1iHcXvxrJTCD8eOtbPUbK9x+Lz70iYehh+G0UoOMcMf04QD6tQP
# TeZ5HhGETkcn0raDJ5NpfbRBuKEH31rxbZK97o12KRDNJ3Nu4ePaUIpH/TcWz8PL
# VOCECywSxbEgEG20kyydGc46c591tXzpfkJDckjoYrypaerdeQLRQH9LaoTYZfdA
# zMo+Dy0O1DzFJkF5YnsmAM8lt9r1NtXdFjdbFMCbV5dau64mV22s186A8Umi+l23
# 9+Ue0cbJQIykWhIlhhWhxQgoksqHz7kp2GFZAAeySTmIOQOWyXOA8JA8TISJyn3J
# DOgStv583P3V0QSALT6JXDCW26FV208VGJMzkv0S22iOTZJ/oamTpk8RzD8oWT8p
# fbe1q/k/bxPiXYRbzps96a5YOko7n0Vdo61DOJhL/mhk01Y348gq6vhG/VTcdGHh
# 1rCkwOM05B35AZZq9AtPpfRzJinrHzzGRx+r6fD3ccYMPMMX/Nwd2irzrph172fQ
# cSf1fMwvwIhmfH4GWJJ+mf1HA6uXoAOVByckguXvlj8gPi7T2ES6RU8+QssfqTNT
# JKjsBheWKWv2W4ESVen2L7lCz7i79FhA+0kp0yXJnYwdzWS0ovTINULINmzVyMcS
# Um5WuVf8YZ33cAud2Opr6N1+RuLZDavDvjiehlI5dH+GEy56MYIHQzCCBz8CAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFhlzes/odf80gAAAAAAWDANBglghkgBZQMEAgEFAKCCBJwwEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MTQzODMwWjAvBgkqhkiG9w0BCQQxIgQg05XcKzOB
# 5oYPRiCAZaN5Tk03aN7M7t3mAtnQQ+cCpPswgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCDFIlS7sgfQ+wAo1cWbWz+WN69VBds58hbran919aLocTB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFhlzes/odf80gAAAAAAWDCCA14GCyqGSIb3DQEJEAISMYIDTTCCA0mh
# ggNFMIIDQTCCAikCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0EwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQCdZHkb26ercF2O62vCdZUfUSvEXKBnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5L64kwIhgPMjAyNjA5MDkxNDI4MjVaGA8y
# MDI2MDkxMDE0MjgyNVowdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA7kvriQIBADAH
# AgEAAgIiMzAHAgEAAgISIDAKAgUA7k09CQIBADA2BgorBgEEAYRZCgQCMSgwJjAM
# BgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEB
# CwUAA4IBAQA7OJK6aYPrPIEIpO1/KgGZ4p2GfYDlHTrQkZbPs1Tx1AylYGWd1PiP
# z/rid4jX9pLJD01C4BsbYbiRnSpxmrVJW0vUoX1akTfsaIBP1Mx1gT3tPSh67bbV
# MhELawA283g8NUUffcm5kpfmINtX+PSjASjFWeDx47spWuBDnuGnyha8+ThyVBHl
# 7bMmaFmKfntmyGtXZG0c/IaOhHCTn4cfiDyw9WgwVKFLjdn5sqaq0xgXO1lG7HSw
# xNFpj3rerXNxGlrpUe1hjntQ0/+8CzvdGPuTQwZQvd60wl/5JZKo96GSpDkBC+e1
# 0Sk7F1Bxw9rKA50iTM6qlnvpY4I74Kf9MA0GCSqGSIb3DQEBAQUABIICAI2zsR+V
# 7tePPY7nikkIAaWiPCOhJTpdpsyWaeHejpvNgwh8gSFxFm7nAg9+ySRPem1IGRIl
# akgDHwZsWrrhZ+E3FmeHAvZnw1Fx5V/yKM4WbBaHYbaEqqXY+ntWH1MuZiTgYLtA
# zyOEsW9tersN2rBLfLRLpRNYF+rnivyRk2dWezcG/MflyfKhDwNsRNBAD0+sMBfL
# 63cLvS3c29AUPwxp0VB1TQoZXPjx9s/RUgJYq49rLm5s2NrKxmwzp0ocumaIfY6m
# LPzpfJpXPN3Wh5W8y7cyLBQFBJiLjIatXAiKldFYHN7FncJ5xBWdyDpW7OhyV15T
# j5n7SS/j10mNN7uCXju5be5hEEtyuE1DWlJFZWvw3BvBuU5M79Gd8QHBnXWPhPxY
# qh4u8Ef6FiSOuNkAZOedePBZlk9TZby6VUmQ9NPBgme3xqZX8jU/aaU09FcwgtS6
# m2q8dze287cVj9Rk7bKO4PmZvfP+6bF7IvMFO3V4pSdWgKvRSJq3+Ny+LFE4pSjL
# aGWo9qqdRvgww/RNyd7JA/Oc4j16LMFKoz23QVW6/wg5XFEZr+0Sm4d+rR6IxBT5
# QLGoLeUqgD8iHNSxHZvqZzmQFp1PL7vJxIbJVVt/Ud3gGHSF0GkyxLRC90BzJKMT
# OnzpMBK2UttL1jL4AuiTkj//kcShznFC2Ojw
# SIG # End signature block
