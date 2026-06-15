function Convert-SACStringReverse {
    param([string]$Value)

    if ($null -eq $Value) { return $null }
    $chars = $Value.ToCharArray()
    [array]::Reverse($chars)
    return -join $chars
}

function Convert-SACPairNibbleReverse {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }

    $result = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i += 2) {
        $pair = $Value.Substring($i, [Math]::Min(2, $Value.Length - $i))
        [void]$result.Append((Convert-SACStringReverse -Value $pair))
    }
    return $result.ToString()
}

function ConvertTo-SACPackedMsiCode {
    <#
    .SYNOPSIS
        Converts a ProductCode GUID to the packed MSI registry key form.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProductCode
    )

    $normalized = $ProductCode.Trim().Trim('{', '}').Replace('-', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{32}$') {
        throw "Invalid MSI ProductCode GUID: $ProductCode"
    }

    $part1 = $normalized.Substring(0, 8)
    $part2 = $normalized.Substring(8, 4)
    $part3 = $normalized.Substring(12, 4)
    $part4 = $normalized.Substring(16, 4)
    $part5 = $normalized.Substring(20, 12)

    return (
        (Convert-SACStringReverse -Value $part1) +
        (Convert-SACStringReverse -Value $part2) +
        (Convert-SACStringReverse -Value $part3) +
        (Convert-SACPairNibbleReverse -Value $part4) +
        (Convert-SACPairNibbleReverse -Value $part5)
    ).ToUpperInvariant()
}

function ConvertFrom-SACPackedMsiCode {
    <#
    .SYNOPSIS
        Converts a packed MSI registry product code back to ProductCode GUID form.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$PackedCode
    )

    $normalized = $PackedCode.Trim().Trim('{', '}').Replace('-', '').ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{32}$') {
        throw "Invalid packed MSI product code: $PackedCode"
    }

    $part1 = Convert-SACStringReverse -Value $normalized.Substring(0, 8)
    $part2 = Convert-SACStringReverse -Value $normalized.Substring(8, 4)
    $part3 = Convert-SACStringReverse -Value $normalized.Substring(12, 4)
    $part4 = Convert-SACPairNibbleReverse -Value $normalized.Substring(16, 4)
    $part5 = Convert-SACPairNibbleReverse -Value $normalized.Substring(20, 12)

    return "{$part1-$part2-$part3-$part4-$part5}".ToUpperInvariant()
}

function Format-SACProductCode {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match($Value, '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?')
    if (-not $match.Success) { return $null }

    $guidText = $match.Value.Trim('{', '}').ToUpperInvariant()
    return "{$guidText}"
}

function Test-SACPackedMsiCode {
    param([string]$Value)

    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim() -match '^[0-9A-Fa-f]{32}$')
}

function Test-SACAbsoluteInstallerPath {
    <#
    .SYNOPSIS
        Returns true when an installer-derived path is drive-rooted, UNC-rooted, or env-var rooted.
    #>
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $true }

    $candidate = $PathValue.Trim().Trim('"')
    if ($candidate -match '^[A-Za-z]:[\\/]') { return $true }
    if ($candidate -match '^\\\\[^\\/]+[\\/][^\\/]+') { return $true }
    if ($candidate -match '^%[A-Za-z_][A-Za-z0-9_()]*%([\\/]|$)') { return $true }
    if ($candidate -match '^\$env:[A-Za-z_][A-Za-z0-9_()]*([\\/]|$)') { return $true }
    if ($candidate -match '^\$\{env:[^}]+\}([\\/]|$)') { return $true }

    return $false
}

function Add-SACUniqueString {
    param(
        [string[]]$Values,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return @($Values) }
    $trimmed = $Value.Trim()
    if ($Values -notcontains $trimmed) { return @($Values + $trimmed) }
    return @($Values)
}

function Add-SACContextProductCode {
    param(
        [psobject]$Context,
        [string]$ProductCode
    )

    $formatted = Format-SACProductCode -Value $ProductCode
    if (-not $formatted) { return }

    $Context.ProductCodes = Add-SACUniqueString -Values $Context.ProductCodes -Value $formatted
    try {
        $Context.PackedCodes = Add-SACUniqueString -Values $Context.PackedCodes -Value (ConvertTo-SACPackedMsiCode -ProductCode $formatted)
    } catch { $null = $_ }
}

function Add-SACContextPackedCode {
    param(
        [psobject]$Context,
        [string]$PackedCode
    )

    if (-not (Test-SACPackedMsiCode -Value $PackedCode)) { return }

    $packed = $PackedCode.Trim().ToUpperInvariant()
    $Context.PackedCodes = Add-SACUniqueString -Values $Context.PackedCodes -Value $packed
    try {
        $Context.ProductCodes = Add-SACUniqueString -Values $Context.ProductCodes -Value (ConvertFrom-SACPackedMsiCode -PackedCode $packed)
    } catch { $null = $_ }
}

function Add-SACContextUpgradeCode {
    param(
        [psobject]$Context,
        [string]$UpgradeCode,
        [string]$PackedUpgradeCode
    )

    if ($UpgradeCode) {
        $formatted = Format-SACProductCode -Value $UpgradeCode
        if ($formatted) { $Context.UpgradeCodes = Add-SACUniqueString -Values $Context.UpgradeCodes -Value $formatted }
    }

    if (Test-SACPackedMsiCode -Value $PackedUpgradeCode) {
        $packed = $PackedUpgradeCode.Trim().ToUpperInvariant()
        $Context.UpgradePackedCodes = Add-SACUniqueString -Values $Context.UpgradePackedCodes -Value $packed
        try {
            $Context.UpgradeCodes = Add-SACUniqueString -Values $Context.UpgradeCodes -Value (ConvertFrom-SACPackedMsiCode -PackedCode $packed)
        } catch { $null = $_ }
    }
}

function Add-SACContextPackageId {
    param(
        [psobject]$Context,
        [string]$PackageId
    )

    if ([string]::IsNullOrWhiteSpace($PackageId)) { return }
    $clean = $PackageId.Trim().Trim('"', "'", ',', ';')
    if ($clean.Length -lt 4) { return }

    $Context.PackageIds = Add-SACUniqueString -Values $Context.PackageIds -Value $clean
}

function Get-SACProductCodesFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $regexMatches = [regex]::Matches($Text, '\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?')
    $results = @()
    foreach ($match in $regexMatches) {
        $formatted = Format-SACProductCode -Value $match.Value
        if ($formatted -and $results -notcontains $formatted) { $results += $formatted }
    }
    return $results
}

function Get-SACPackageIdsFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $results = @()
    $patterns = @(
        '(?i)\bUPI2?\b\s*["'']?\s*[:=]\s*["'']?([A-Za-z0-9._{}\-]+)',
        '(?i)\bPackage(?:Id|ID|_ID|_id)?\b\s*["'']?\s*[:=]\s*["'']?([A-Za-z0-9._{}\-]+)',
        '(?i)\bPackageCode\b\s*["'']?\s*[:=]\s*["'']?([A-Za-z0-9._{}\-]+)'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $value = $match.Groups[1].Value.Trim().Trim('"', "'", ',', ';')
            if ($value.Length -ge 4 -and $results -notcontains $value) { $results += $value }
        }
    }

    return $results
}

function Test-SACContextTextMatch {
    param(
        [psobject]$Context,
        [string[]]$Text
    )

    $joined = (@($Text) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
    if ([string]::IsNullOrWhiteSpace($joined)) { return $false }

    foreach ($code in @($Context.ProductCodes + $Context.PackedCodes + $Context.UpgradeCodes + $Context.UpgradePackedCodes + $Context.PackageIds)) {
        if (-not [string]::IsNullOrWhiteSpace($code) -and $joined.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    $product = [regex]::Escape([string]$Context.Product)
    $year = [regex]::Escape([string]$Context.Year)
    if ($joined -match $product -and ($Context.Year -eq '*' -or $joined -match "\b$year\b")) {
        return $true
    }

    return $false
}

function Get-SACContextMatchedTerm {
    param(
        [psobject]$Context,
        [string[]]$Text
    )

    $joined = (@($Text) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " "
    foreach ($code in @($Context.ProductCodes + $Context.PackedCodes + $Context.UpgradeCodes + $Context.UpgradePackedCodes + $Context.PackageIds)) {
        if (-not [string]::IsNullOrWhiteSpace($code) -and $joined.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $code
        }
    }

    if ($joined -match [regex]::Escape([string]$Context.Product) -and ($Context.Year -eq '*' -or $joined -match "\b$([regex]::Escape([string]$Context.Year))\b")) {
        return "$($Context.Product) $($Context.Year)"
    }

    return $null
}

function Get-SACTargetContext {
    param(
        [string[]]$TargetProducts,
        [string[]]$TargetYears,
        [object[]]$UninstallKeys,
        [string[]]$KnownProductCodes,
        [string[]]$KnownPackedCodes
    )

    $contexts = @()
    foreach ($product in $TargetProducts) {
        foreach ($year in $TargetYears) {
            $contexts += [PSCustomObject]@{
                Product            = [string]$product
                Year               = [string]$year
                ProductCodes       = @()
                PackedCodes        = @()
                UpgradeCodes       = @()
                UpgradePackedCodes = @()
                PackageIds         = @()
            }
        }
    }

    foreach ($context in $contexts) {
        foreach ($app in @($UninstallKeys)) {
            $text = @(
                $app.DisplayName,
                $app.DisplayVersion,
                $app.InstallLocation,
                $app.InstallSource,
                $app.LocalPackage,
                $app.UninstallString,
                $app.QuietUninstallString,
                $app.PSChildName
            )

            if (Test-SACContextTextMatch -Context $context -Text $text) {
                Add-SACContextProductCode -Context $context -ProductCode $app.PSChildName
                foreach ($code in (Get-SACProductCodesFromText -Text ($text -join " "))) {
                    Add-SACContextProductCode -Context $context -ProductCode $code
                }
            }
        }

        foreach ($code in @($KnownProductCodes)) { Add-SACContextProductCode -Context $context -ProductCode $code }
        foreach ($packed in @($KnownPackedCodes)) { Add-SACContextPackedCode -Context $context -PackedCode $packed }
    }

    return $contexts
}

function Get-SACRegistryValue {
    param(
        [Microsoft.Win32.RegistryKey]$Key,
        [string[]]$Names
    )

    if ($null -eq $Key) { return $null }
    foreach ($name in $Names) {
        try {
            $value = $Key.GetValue($name)
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
        } catch { $null = $_ }
    }
    return $null
}

function Get-SACInstallerPathWarning {
    param(
        [psobject]$Context,
        [hashtable]$Values,
        [string]$Source,
        [string]$SourcePath,
        [string]$DisplayName
    )

    $pathNamePattern = '^(ADSK_INSTALL_PATH|INSTALLDIR|ARPINSTALLLOCATION|InstallLocation|InstallSource|LocalPackage|TARGETDIR|ROOTDRIVE)$'
    $warnings = @()

    foreach ($key in $Values.Keys) {
        if ($key -notmatch $pathNamePattern) { continue }
        $value = [string]$Values[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (Test-SACAbsoluteInstallerPath -PathValue $value) { continue }

        $warnings += [PSCustomObject]@{
            Product      = $Context.Product
            Year         = $Context.Year
            Source       = $Source
            SourcePath   = $SourcePath
            DisplayName  = $DisplayName
            PropertyName = $key
            Value        = $value
        }
    }

    return $warnings
}

function Get-SACTextPathWarning {
    param(
        [psobject]$Context,
        [string]$Text,
        [string]$Source,
        [string]$SourcePath,
        [string]$DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $warnings = @()
    $pattern = '(?im)\b(ADSK_INSTALL_PATH|INSTALLDIR|ARPINSTALLLOCATION)\b\s*["'']?\s*[:=]\s*["'']?([^"''\r\n,;]+)'
    foreach ($match in [regex]::Matches($Text, $pattern)) {
        $name = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (Test-SACAbsoluteInstallerPath -PathValue $value) { continue }

        $warnings += [PSCustomObject]@{
            Product      = $Context.Product
            Year         = $Context.Year
            Source       = $Source
            SourcePath   = $SourcePath
            DisplayName  = $DisplayName
            PropertyName = $name
            Value        = $value
        }
    }

    return $warnings
}

function Get-SACMsiProductState {
    param([string[]]$ProductCodes)

    $results = @()
    $installer = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
    } catch {
        $comError = $_.Exception.Message
        foreach ($code in @($ProductCodes | Select-Object -Unique)) {
            $packedCode = $null
            try { $packedCode = ConvertTo-SACPackedMsiCode -ProductCode $code } catch { $null = $_ }

            $results += [PSCustomObject]@{
                ProductCode  = $code
                PackedCode   = $packedCode
                ProductState = $null
                IsInstalled  = $false
                Error        = $comError
            }
        }
        return $results
    }

    foreach ($code in @($ProductCodes | Where-Object { $_ } | Select-Object -Unique)) {
        $packedCode = $null
        try { $packedCode = ConvertTo-SACPackedMsiCode -ProductCode $code } catch { $null = $_ }

        try {
            $state = $installer.ProductState($code)
            $results += [PSCustomObject]@{
                ProductCode  = $code
                PackedCode   = $packedCode
                ProductState = $state
                IsInstalled  = ($state -eq 5)
                Error        = $null
            }
        } catch {
            $results += [PSCustomObject]@{
                ProductCode  = $code
                PackedCode   = $packedCode
                ProductState = $null
                IsInstalled  = $false
                Error        = $_.Exception.Message
            }
        }
    }

    return $results
}

function Get-SACSearchableOdisFile {
    param([string]$FolderPath)

    $extensions = @('.json', '.xml', '.txt', '.ini', '.log', '.properties', '.manifest', '.pit', '.yaml', '.yml')
    try {
        return @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -le 5242880 -and
                ($extensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -match '(?i)(manifest|setup|package|deployment|bundle|collection)')
            } |
            Select-Object -First 250)
    } catch {
        return @()
    }
}

function Read-SACFileText {
    param([string]$Path)

    try {
        return [System.IO.File]::ReadAllText($Path)
    } catch {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($Path)
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        } catch {
            return $null
        }
    }
}

function Get-SACOdisRemnant {
    param([psobject[]]$Contexts)

    $results = @()
    $warnings = @()
    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $roots = @(
        [PSCustomObject]@{ Source = 'ODIS Metadata'; Path = (Join-Path $programData 'Autodesk\ODIS\metadata'); Action = 'Rename Folder' },
        [PSCustomObject]@{ Source = 'ODIS Extract';  Path = (Join-Path $programData 'Autodesk\ODIS\extract');  Action = 'Rename Folder' }
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }

        $folders = @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue)
        foreach ($folder in $folders) {
            foreach ($context in $Contexts) {
                $matched = Test-SACContextTextMatch -Context $context -Text @($folder.Name, $folder.FullName)
                $matchedTerm = if ($matched) { Get-SACContextMatchedTerm -Context $context -Text @($folder.Name, $folder.FullName) } else { $null }
                $matchedFile = $null
                $identifierText = $folder.Name

                if (-not $matched) {
                    foreach ($file in (Get-SACSearchableOdisFile -FolderPath $folder.FullName)) {
                        $text = Read-SACFileText -Path $file.FullName
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }

                        if (Test-SACContextTextMatch -Context $context -Text @($file.Name, $text)) {
                            $matched = $true
                            $matchedFile = $file.FullName
                            $matchedTerm = Get-SACContextMatchedTerm -Context $context -Text @($file.Name, $text)
                            $identifierText = $text
                            $warnings += Get-SACTextPathWarning -Context $context -Text $text -Source $root.Source -SourcePath $file.FullName -DisplayName $folder.Name
                            break
                        }
                    }
                }

                if (-not $matched) { continue }

                foreach ($packageId in (Get-SACPackageIdsFromText -Text $identifierText)) {
                    Add-SACContextPackageId -Context $context -PackageId $packageId
                }

                foreach ($code in (Get-SACProductCodesFromText -Text $identifierText)) {
                    Add-SACContextProductCode -Context $context -ProductCode $code
                }

                $results += [PSCustomObject]@{
                    Product       = $context.Product
                    Year          = $context.Year
                    Source        = $root.Source
                    Action        = $root.Action
                    Path          = $folder.FullName
                    DisplayName   = $folder.Name
                    MatchedTerm   = $matchedTerm
                    MatchedFile   = $matchedFile
                    PackageIds    = ($context.PackageIds -join '; ')
                    ProductCodes  = ($context.ProductCodes -join '; ')
                    PackedCodes   = ($context.PackedCodes -join '; ')
                    UpgradeCodes  = ($context.UpgradeCodes -join '; ')
                }
            }
        }
    }

    $installDb = Join-Path $programData 'Autodesk\ODIS\Install.db'
    if (Test-Path -LiteralPath $installDb) {
        $dbText = Read-SACFileText -Path $installDb
        if (-not [string]::IsNullOrWhiteSpace($dbText)) {
            foreach ($context in $Contexts) {
                if (Test-SACContextTextMatch -Context $context -Text $dbText) {
                    $results += [PSCustomObject]@{
                        Product       = $context.Product
                        Year          = $context.Year
                        Source        = 'ODIS Install.db'
                        Action        = 'Report Only'
                        Path          = $installDb
                        DisplayName   = 'Install.db'
                        MatchedTerm   = (Get-SACContextMatchedTerm -Context $context -Text $dbText)
                        MatchedFile   = $installDb
                        PackageIds    = ($context.PackageIds -join '; ')
                        ProductCodes  = ($context.ProductCodes -join '; ')
                        PackedCodes   = ($context.PackedCodes -join '; ')
                        UpgradeCodes  = ($context.UpgradeCodes -join '; ')
                    }
                    $warnings += Get-SACTextPathWarning -Context $context -Text $dbText -Source 'ODIS Install.db' -SourcePath $installDb -DisplayName 'Install.db'
                }
            }
        }
    }

    return [PSCustomObject]@{
        Remnants = @($results)
        Warnings = @($warnings)
    }
}

function Get-SACHiddenInstallerState {
    <#
    .SYNOPSIS
        Finds hidden Autodesk MSI installer-state and ODIS remnants for targeted products/years.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$TargetProducts,

        [Parameter(Mandatory=$true)]
        [string[]]$TargetYears,

        [object[]]$UninstallKeys = @(),

        [string[]]$KnownProductCodes = @(),

        [string[]]$KnownPackedCodes = @()
    )

    $contexts = @(Get-SACTargetContext -TargetProducts $TargetProducts -TargetYears $TargetYears -UninstallKeys $UninstallKeys -KnownProductCodes $KnownProductCodes -KnownPackedCodes $KnownPackedCodes)
    $hiddenProducts = @()
    $componentRefs = @()
    $upgradeRefs = @()
    $relativeWarnings = @()

    $productRoots = @(
        [PSCustomObject]@{ Source = 'UserData Products'; ProviderPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'; SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products' },
        [PSCustomObject]@{ Source = 'Classes Products';  ProviderPath = 'HKLM:\SOFTWARE\Classes\Installer\Products'; SubPath = 'SOFTWARE\Classes\Installer\Products' }
    )

    $productBaseKey = $null
    try {
        $productBaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

        foreach ($root in $productRoots) {
            $productRootKey = $productBaseKey.OpenSubKey($root.SubPath)
            if (-not $productRootKey) { continue }

            try {
                foreach ($packedName in $productRootKey.GetSubKeyNames()) {
                    $packedCode = $packedName.ToUpperInvariant()
                    if (-not (Test-SACPackedMsiCode -Value $packedCode)) { continue }

                    $productCode = $null
                    try { $productCode = ConvertFrom-SACPackedMsiCode -PackedCode $packedCode } catch { $null = $_ }

                    $productKeyPath = "$($root.ProviderPath)\$packedName"
                    $installPropertiesPath = "$productKeyPath\InstallProperties"
                    $productKey = $productRootKey.OpenSubKey($packedName)
                    if (-not $productKey) { continue }

                    $propsKey = $null
                    $hadPropsKey = $false
                    $values = @{}
                    try {
                        $propsKey = $productKey.OpenSubKey('InstallProperties')
                        if ($propsKey) {
                            $hadPropsKey = $true
                            foreach ($name in $propsKey.GetValueNames()) {
                                $values[$name] = [string]$propsKey.GetValue($name)
                            }
                        }

                        foreach ($name in $productKey.GetValueNames()) {
                            if (-not $values.ContainsKey($name)) { $values[$name] = [string]$productKey.GetValue($name) }
                        }
                    } finally {
                        if ($propsKey) { $propsKey.Close() }
                        $productKey.Close()
                    }

                    $displayName = $values['DisplayName']
                    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $values['ProductName'] }
                    $text = @(
                        $displayName,
                        $values['DisplayVersion'],
                        $values['InstallLocation'],
                        $values['InstallSource'],
                        $values['LocalPackage'],
                        $values['UninstallString'],
                        $productCode,
                        $packedCode
                    )

                    foreach ($context in $contexts) {
                        if (-not (Test-SACContextTextMatch -Context $context -Text $text)) { continue }

                        if ($productCode) { Add-SACContextProductCode -Context $context -ProductCode $productCode }
                        Add-SACContextPackedCode -Context $context -PackedCode $packedCode

                        $hiddenProducts += [PSCustomObject]@{
                            Product          = $context.Product
                            Year             = $context.Year
                            Source           = $root.Source
                            ProductCode      = $productCode
                            PackedCode       = $packedCode
                            DisplayName      = $displayName
                            DisplayVersion   = $values['DisplayVersion']
                            InstallLocation  = $values['InstallLocation']
                            InstallSource    = $values['InstallSource']
                            LocalPackage     = $values['LocalPackage']
                            UninstallString  = $values['UninstallString']
                            RegistryPath     = $productKeyPath
                            PropertiesPath   = if ($hadPropsKey) { $installPropertiesPath } else { $null }
                        }

                        $relativeWarnings += Get-SACInstallerPathWarning -Context $context -Values $values -Source $root.Source -SourcePath $productKeyPath -DisplayName $displayName
                    }
                }
            } finally {
                $productRootKey.Close()
            }
        }

        $featureProviderPath = 'HKLM:\SOFTWARE\Classes\Installer\Features'
        $featureRootKey = $productBaseKey.OpenSubKey('SOFTWARE\Classes\Installer\Features')
        if ($featureRootKey) {
            try {
                foreach ($packedName in $featureRootKey.GetSubKeyNames()) {
                    $packedCode = $packedName.ToUpperInvariant()
                    if (-not (Test-SACPackedMsiCode -Value $packedCode)) { continue }

                    $productCode = $null
                    try { $productCode = ConvertFrom-SACPackedMsiCode -PackedCode $packedCode } catch { $null = $_ }

                    foreach ($context in $contexts) {
                        $isMatch = ($context.PackedCodes -contains $packedCode) -or ($productCode -and $context.ProductCodes -contains $productCode)
                        if (-not $isMatch) { continue }

                        $featureKeyPath = "$featureProviderPath\$packedName"
                        $featureNames = @()
                        $featureKey = $featureRootKey.OpenSubKey($packedName)
                        if ($featureKey) {
                            try { $featureNames = @($featureKey.GetValueNames()) }
                            finally { $featureKey.Close() }
                        }

                        $hiddenProducts += [PSCustomObject]@{
                            Product          = $context.Product
                            Year             = $context.Year
                            Source           = 'Classes Features'
                            ProductCode      = $productCode
                            PackedCode       = $packedCode
                            DisplayName      = "MSI feature registration ($($featureNames.Count) feature value(s))"
                            DisplayVersion   = $null
                            InstallLocation  = $null
                            InstallSource    = $null
                            LocalPackage     = $null
                            UninstallString  = $null
                            RegistryPath     = $featureKeyPath
                            PropertiesPath   = $null
                        }
                    }
                }
            } finally {
                $featureRootKey.Close()
            }
        }
    } catch {
        Write-SACQuietLog "Hidden MSI product/feature scan failed: $($_.Exception.Message)"
    } finally {
        if ($productBaseKey) { $productBaseKey.Close() }
    }

    foreach ($context in $contexts) {
        foreach ($app in @($UninstallKeys)) {
            $values = @{}
            foreach ($name in @('InstallLocation', 'InstallSource', 'LocalPackage')) {
                if ($null -ne $app.$name) { $values[$name] = [string]$app.$name }
            }
            if ($values.Count -gt 0 -and (Test-SACContextTextMatch -Context $context -Text @($app.DisplayName, $app.InstallLocation, $app.InstallSource, $app.LocalPackage))) {
                $relativeWarnings += Get-SACInstallerPathWarning -Context $context -Values $values -Source 'Add/Remove Programs' -SourcePath $app.PSPath -DisplayName $app.DisplayName
            }
        }
    }

    $allProductCodes = @()
    foreach ($context in $contexts) { $allProductCodes += $context.ProductCodes }
    $productStates = @(Get-SACMsiProductState -ProductCodes ($allProductCodes | Where-Object { $_ } | Select-Object -Unique))
    $referenceContexts = @($contexts | Where-Object { @($_.ProductCodes + $_.PackedCodes).Count -gt 0 })

    $baseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

        $componentSubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
        $componentKeyRoot = $baseKey.OpenSubKey($componentSubPath)
        if ($componentKeyRoot -and $referenceContexts.Count -gt 0) {
            foreach ($componentName in $componentKeyRoot.GetSubKeyNames()) {
                $componentKey = $componentKeyRoot.OpenSubKey($componentName)
                if (-not $componentKey) { continue }

                try {
                    foreach ($valueName in $componentKey.GetValueNames()) {
                        $valueData = [string]$componentKey.GetValue($valueName)
                        foreach ($context in $referenceContexts) {
                            $valueText = @($valueName, $valueData)
                            $isMatch = $false
                            foreach ($code in @($context.ProductCodes + $context.PackedCodes)) {
                                if (-not [string]::IsNullOrWhiteSpace($code) -and (($valueName -ieq $code) -or ($valueData -ieq $code) -or ($valueName.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($valueData.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                                    $isMatch = $true
                                    break
                                }
                            }
                            if (-not $isMatch) { continue }

                            $componentRefs += [PSCustomObject]@{
                                Product       = $context.Product
                                Year          = $context.Year
                                ComponentKey  = $componentName
                                RegistryPath  = "HKLM:\$componentSubPath\$componentName"
                                ValueName     = $valueName
                                ValueData     = $valueData
                                MatchedTerm   = Get-SACContextMatchedTerm -Context $context -Text $valueText
                            }
                        }
                    }
                } finally {
                    $componentKey.Close()
                }
            }
            $componentKeyRoot.Close()
        }

        $upgradeRoots = @(
            [PSCustomObject]@{ ProviderPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes'; SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UpgradeCodes' },
            [PSCustomObject]@{ ProviderPath = 'HKLM:\SOFTWARE\Classes\Installer\UpgradeCodes'; SubPath = 'SOFTWARE\Classes\Installer\UpgradeCodes' }
        )

        foreach ($upgradeRoot in $upgradeRoots) {
            $upgradeKeyRoot = $baseKey.OpenSubKey($upgradeRoot.SubPath)
            if (-not $upgradeKeyRoot -or $referenceContexts.Count -eq 0) { continue }

            try {
                foreach ($upgradeName in $upgradeKeyRoot.GetSubKeyNames()) {
                    $upgradePackedCode = $upgradeName.ToUpperInvariant()
                    $upgradeCode = $null
                    if (Test-SACPackedMsiCode -Value $upgradePackedCode) {
                        try { $upgradeCode = ConvertFrom-SACPackedMsiCode -PackedCode $upgradePackedCode } catch { $null = $_ }
                    }

                    $upgradeKey = $upgradeKeyRoot.OpenSubKey($upgradeName)
                    if (-not $upgradeKey) { continue }

                    try {
                        foreach ($valueName in $upgradeKey.GetValueNames()) {
                            $valueData = [string]$upgradeKey.GetValue($valueName)
                            foreach ($context in $referenceContexts) {
                                $valueText = @($valueName, $valueData)
                                $isMatch = $false
                                foreach ($code in @($context.ProductCodes + $context.PackedCodes)) {
                                    if (-not [string]::IsNullOrWhiteSpace($code) -and (($valueName -ieq $code) -or ($valueData -ieq $code) -or ($valueName.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or ($valueData.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0))) {
                                        $isMatch = $true
                                        break
                                    }
                                }
                                if (-not $isMatch) { continue }

                                Add-SACContextUpgradeCode -Context $context -UpgradeCode $upgradeCode -PackedUpgradeCode $upgradePackedCode
                                $upgradeRefs += [PSCustomObject]@{
                                    Product           = $context.Product
                                    Year              = $context.Year
                                    Source            = $upgradeRoot.ProviderPath
                                    RegistryPath      = "$($upgradeRoot.ProviderPath)\$upgradeName"
                                    UpgradeCode       = $upgradeCode
                                    UpgradePackedCode = $upgradePackedCode
                                    ValueName         = $valueName
                                    ValueData         = $valueData
                                    MatchedTerm       = Get-SACContextMatchedTerm -Context $context -Text $valueText
                                }
                            }
                        }
                    } finally {
                        $upgradeKey.Close()
                    }
                }
            } finally {
                $upgradeKeyRoot.Close()
            }
        }
    } catch {
        Write-SACQuietLog "Hidden MSI component/upgrade scan failed: $($_.Exception.Message)"
    } finally {
        if ($baseKey) { $baseKey.Close() }
    }

    $odis = Get-SACOdisRemnant -Contexts $contexts
    $relativeWarnings += @($odis.Warnings)

    $uniqueHiddenCodes = @($hiddenProducts | Where-Object { $_.ProductCode } | Select-Object -ExpandProperty ProductCode -Unique)
    $installedStates = @($productStates | Where-Object { $_.IsInstalled })

    return [PSCustomObject]@{
        HiddenProducts         = @($hiddenProducts | Select-Object -Unique *)
        ProductStates          = @($productStates | Select-Object -Unique *)
        ComponentReferences    = @($componentRefs | Select-Object -Unique *)
        UpgradeCodeReferences  = @($upgradeRefs | Select-Object -Unique *)
        OdisRemnants           = @($odis.Remnants | Select-Object -Unique *)
        RelativePathWarnings   = @($relativeWarnings | Select-Object -Unique *)
        Contexts               = @($contexts)
        Summary                = [PSCustomObject]@{
            HiddenMsiProducts      = $uniqueHiddenCodes.Count
            ProductStateInstalled  = $installedStates.Count
            ComponentReferences    = @($componentRefs | Select-Object -Unique *).Count
            UpgradeCodeReferences  = @($upgradeRefs | Select-Object -Unique *).Count
            OdisRemnants           = @($odis.Remnants | Select-Object -Unique *).Count
            RelativePathWarnings   = @($relativeWarnings | Select-Object -Unique *).Count
        }
    }
}

function Convert-SACRegistryPathToNative {
    param([string]$RegistryPath)

    if ([string]::IsNullOrWhiteSpace($RegistryPath)) { return $null }

    $path = $RegistryPath
    $path = $path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $path = $path -replace '^HKLM:\\', 'HKEY_LOCAL_MACHINE\'
    $path = $path -replace '^HKCU:\\', 'HKEY_CURRENT_USER\'
    $path = $path -replace '^HKCR:\\', 'HKEY_CLASSES_ROOT\'
    $path = $path -replace '^HKU:\\', 'HKEY_USERS\'
    return $path
}

function Backup-SACRegistryKey {
    param(
        [string]$RegistryPath,
        [string]$LogDir,
        [string]$Prefix = 'Registry'
    )

    if ([string]::IsNullOrWhiteSpace($LogDir) -or [string]::IsNullOrWhiteSpace($RegistryPath)) { return $null }
    if (-not (Test-Path -LiteralPath $RegistryPath)) { return $null }

    $backupDir = Join-Path $LogDir 'RegistryBackups'
    New-Item -ItemType Directory -Path $backupDir -Force -ErrorAction SilentlyContinue | Out-Null

    $safeName = ($Prefix + '_' + ($RegistryPath -replace '[\\/:*?"<>|{}\s]', '_')).Trim('_')
    if ($safeName.Length -gt 160) { $safeName = $safeName.Substring(0, 160) }
    $backupPath = Join-Path $backupDir "$safeName.reg"
    $nativePath = Convert-SACRegistryPathToNative -RegistryPath $RegistryPath

    try {
        & reg.exe export "$nativePath" "$backupPath" /y 2>&1 | Out-Null
        if (Test-Path -LiteralPath $backupPath) {
            Write-SACQuietLog "Backed up registry key $RegistryPath to $backupPath"
            return $backupPath
        }
    } catch {
        Write-SACQuietLog "Failed to back up registry key $($RegistryPath): $($_.Exception.Message)"
    }

    return $null
}

function Invoke-SACHiddenInstallerStateCleanup {
    <#
    .SYNOPSIS
        Removes hidden MSI installer-state references and renames targeted ODIS folders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [psobject]$State,

        [Parameter(Mandatory=$true)]
        [string]$LogDir
    )

    $result = [PSCustomObject]@{
        HiddenMsiProductCodes        = @()
        ProductStateInstalledCodes   = @()
        HiddenMsiProductKeysRemoved  = 0
        ComponentRefsRemoved         = 0
        UpgradeCodeRefsRemoved       = 0
        OdisFoldersRenamed           = 0
    }

    foreach ($stateItem in @($State.ProductStates | Where-Object { $_.IsInstalled })) {
        $result.ProductStateInstalledCodes = Add-SACUniqueString -Values $result.ProductStateInstalledCodes -Value $stateItem.ProductCode
    }

    $hiddenPaths = @($State.HiddenProducts | Where-Object { $_.RegistryPath } | Sort-Object RegistryPath -Unique)
    foreach ($product in $hiddenPaths) {
        if ($product.ProductCode) {
            $result.HiddenMsiProductCodes = Add-SACUniqueString -Values $result.HiddenMsiProductCodes -Value $product.ProductCode
        }

        if (-not (Test-Path -LiteralPath $product.RegistryPath)) { continue }

        Backup-SACRegistryKey -RegistryPath $product.RegistryPath -LogDir $LogDir -Prefix 'HiddenMsiProduct' | Out-Null
        try {
            Remove-Item -LiteralPath $product.RegistryPath -Recurse -Force -ErrorAction Stop
            $result.HiddenMsiProductKeysRemoved++
            Write-SACMsg "Removed hidden MSI registration: $($product.DisplayName) [$($product.PackedCode)]" "Success"
            Write-SACQuietLog "Removed hidden MSI registry key: $($product.RegistryPath)"
        } catch {
            Write-SACQuietLog "Failed to remove hidden MSI key $($product.RegistryPath): $($_.Exception.Message)"
            $script:SACFailures += [PSCustomObject]@{ Component = "Hidden MSI Registry: $($product.DisplayName)"; Reason = $_.Exception.Message; Severity = 'Warning' }
        }
    }

    $componentRefs = @($State.ComponentReferences | Where-Object { $_.RegistryPath -and $_.ValueName } | Sort-Object RegistryPath, ValueName -Unique)
    foreach ($ref in $componentRefs) {
        if (-not (Test-Path -LiteralPath $ref.RegistryPath)) { continue }

        Backup-SACRegistryKey -RegistryPath $ref.RegistryPath -LogDir $LogDir -Prefix 'MsiComponentRef' | Out-Null
        try {
            Remove-ItemProperty -LiteralPath $ref.RegistryPath -Name $ref.ValueName -Force -ErrorAction Stop
            $result.ComponentRefsRemoved++
            Write-SACMsg "Removed MSI component reference: $($ref.ValueName)" "Success"
            Write-SACQuietLog "Removed MSI component value $($ref.ValueName) from $($ref.RegistryPath)"
        } catch {
            Write-SACQuietLog "Failed to remove MSI component value $($ref.ValueName) from $($ref.RegistryPath): $($_.Exception.Message)"
            $script:SACFailures += [PSCustomObject]@{ Component = "MSI Component Ref: $($ref.ValueName)"; Reason = $_.Exception.Message; Severity = 'Warning' }
        }
    }

    $upgradeRefs = @($State.UpgradeCodeReferences | Where-Object { $_.RegistryPath -and $_.ValueName } | Sort-Object RegistryPath, ValueName -Unique)
    foreach ($ref in $upgradeRefs) {
        if (-not (Test-Path -LiteralPath $ref.RegistryPath)) { continue }

        Backup-SACRegistryKey -RegistryPath $ref.RegistryPath -LogDir $LogDir -Prefix 'MsiUpgradeRef' | Out-Null
        try {
            Remove-ItemProperty -LiteralPath $ref.RegistryPath -Name $ref.ValueName -Force -ErrorAction Stop
            $result.UpgradeCodeRefsRemoved++
            Write-SACMsg "Removed MSI upgrade-code reference: $($ref.ValueName)" "Success"
            Write-SACQuietLog "Removed MSI upgrade-code value $($ref.ValueName) from $($ref.RegistryPath)"
        } catch {
            Write-SACQuietLog "Failed to remove MSI upgrade-code value $($ref.ValueName) from $($ref.RegistryPath): $($_.Exception.Message)"
            $script:SACFailures += [PSCustomObject]@{ Component = "MSI UpgradeCode Ref: $($ref.ValueName)"; Reason = $_.Exception.Message; Severity = 'Warning' }
        }
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $odisFolders = @($State.OdisRemnants | Where-Object { $_.Action -eq 'Rename Folder' -and $_.Path } | Sort-Object Path -Unique)
    foreach ($folder in $odisFolders) {
        if (-not (Test-Path -LiteralPath $folder.Path)) { continue }
        if ((Split-Path -Leaf $folder.Path) -match '\.SAC_bak_') { continue }

        $backupLeaf = "$(Split-Path -Leaf $folder.Path).SAC_bak_$timestamp"
        try {
            Rename-Item -LiteralPath $folder.Path -NewName $backupLeaf -Force -ErrorAction Stop
            $result.OdisFoldersRenamed++
            Write-SACMsg "Renamed targeted ODIS folder: $($folder.Path) -> $backupLeaf" "Success"
            Write-SACQuietLog "Renamed targeted ODIS folder $($folder.Path) to $backupLeaf"
        } catch {
            Write-SACQuietLog "Failed to rename ODIS folder $($folder.Path): $($_.Exception.Message)"
            $script:SACFailures += [PSCustomObject]@{ Component = "ODIS Folder Rename: $($folder.Path)"; Reason = $_.Exception.Message; Severity = 'Warning' }
        }
    }

    return $result
}

function Get-SACHiddenInstallerStateFunctionBundle {
    $names = @(
        'Convert-SACStringReverse',
        'Convert-SACPairNibbleReverse',
        'ConvertTo-SACPackedMsiCode',
        'ConvertFrom-SACPackedMsiCode',
        'Format-SACProductCode',
        'Test-SACPackedMsiCode',
        'Test-SACAbsoluteInstallerPath',
        'Add-SACUniqueString',
        'Add-SACContextProductCode',
        'Add-SACContextPackedCode',
        'Add-SACContextUpgradeCode',
        'Add-SACContextPackageId',
        'Get-SACProductCodesFromText',
        'Get-SACPackageIdsFromText',
        'Test-SACContextTextMatch',
        'Get-SACContextMatchedTerm',
        'Get-SACTargetContext',
        'Get-SACRegistryValue',
        'Get-SACInstallerPathWarning',
        'Get-SACTextPathWarning',
        'Get-SACMsiProductState',
        'Get-SACSearchableOdisFile',
        'Read-SACFileText',
        'Get-SACOdisRemnant',
        'Get-SACHiddenInstallerState'
    )

    return (($names | ForEach-Object {
        $cmd = Get-Command -Name $_ -CommandType Function -ErrorAction Stop
        "function $($_) {`r`n$($cmd.ScriptBlock.ToString())`r`n}"
    }) -join "`r`n")
}
