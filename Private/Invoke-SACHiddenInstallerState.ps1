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

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCABHf7EOSnoUgfB
# gfpu3wo1kiya1yG7g0y7q9N0fVFd0aCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# IgQgnvxYFH8PGVupgKn17hzG6POEd7vfZ10QIFUQuUdJhz8wDQYJKoZIhvcNAQEB
# BQAEggGAGC0DSn6Kyse72bXrSYjdBkzJJWcSQjrV+HGDJj+qDiKxDHVk/qkqmvex
# kqIa90L+2LagxB59DIgXY8wm6CEnfUmBF1LYGcFkA6J6Mj7qh1ZKzWB0G0UYCYFn
# ZLlDlSkJSHBA7YpJdS2kif5WQWhrvOpMr3He3FMUTkO/yEUYradXAHr6ejruu+7w
# A0KNctRWKkNyvYDIyNijHv6wlj+8N5x8DnJ+arhszgi6La8of5HHARzJKaGwwRSw
# bPG1RbPlaO++bYxHeqYFYshfwPEZBPY87uqtQ137DLZcOVYt7INx2r3wSxDta3zT
# o/TeyEa4LelQSGP/T4YoterA/LyF3zenp4NXdUcgUzsvYgH8oSwXYd7BPrL26jul
# JsS6aamjGW2RvylpZufJGMS7WzpTvqyDHeb9PJSDsgW9GKYsOJ9eoHYsac8bl2FE
# 5ZP7PCmm//2swu40/D7M/07i1P5OQwvmnr+ORpi5GTWIE2WHLd80oJ2QmdwFWOWr
# XyuQJB9goYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIMKNHfB4yIXz
# LSwYsDuyeZHDkGuRaE8BzhJy/3H4NAteAgZqhEkGSBkYEzIwMjYwOTA5MDIyNjU4
# LjY1OFowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
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
# hkiG9w0BCQUxDxcNMjYwOTA5MDIyNjU4WjAvBgkqhkiG9w0BCQQxIgQgFCczqzl3
# I+l1KTFse1J4yr7zyzOheJ0cHcrAar3XpvowgbkGCyqGSIb3DQEJEAIvMYGpMIGm
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
# Rz7cG01QVtwJ0uXG453Leu7vsh7HpsjQN5CgMA0GCSqGSIb3DQEBAQUABIICAIQ3
# ElQjQMFnuYmr9ntDoNocVtdAYI5cXagoT0vR/jjBYOd/YtVwgfu18WXbKa9cMwSp
# xBucvRMYDdvyZdxjN+Lp4QwKRzxziB65Y1gIJ/nHL/YNZsa0lk2O+9DxbxQGL+15
# k7JTvVQbYDOMNfbFueciHU798shVBulh2cMdk5Z59zxg5DyXG/HqV1YUAcgrYDpG
# dePJ76ZNYxcB74g8sR0CImmwarI2RIQgZHv+Ehhw5YawypfmhZsIX+Uu8bS5t91r
# Sjhn9e6u6fMagctnP/lSWD/lTiol7hkS5BNndIu6he/XM2NPeUws4aOq2ykfXUQF
# cqwEiyx8ubNmtZJBgLTfciWbB48aLCzxOPE6awUli3SnNzoPXsHN7KTnKcs3J9pV
# f6sEOpaSbvLFLWDpvJt2L4oJ0oc/GclQACVSX6YoQFXLYRPu13LjPPbhL/AHgl1Y
# 2Mi1JMNo/ILWLzZfVS4kJO6+d+6lhCQhbrO/raF1GVSr4v5zT+epyS1svUDXA69+
# rgZ8VyoB9YiEhzv17aOEKCIDt+C1HpU8w1l/hgh0eIY9if3pYVMFf648iOPxq5Vc
# wsSU04jXQkZpeg6Kjtmh2By86Qr1yS9KsEvdTnXf50xkLVIORi2x0CaD+VVDIrWl
# eu8iUQCPWVBNgvSieJoRM/iH7Y/UCvpJNND3BC75
# SIG # End signature block
