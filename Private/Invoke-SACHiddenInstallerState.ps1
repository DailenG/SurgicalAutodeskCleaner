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

    $joined = if ($Text.Count -eq 1) { [string]$Text[0] } else { (@($Text) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " " }
    if ([string]::IsNullOrWhiteSpace($joined)) { return $false }

    foreach ($code in @($Context.ProductCodes + $Context.PackedCodes + $Context.UpgradeCodes + $Context.UpgradePackedCodes + $Context.PackageIds)) {
        if (-not [string]::IsNullOrWhiteSpace($code) -and $joined.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    # The product name is a literal, so an ordinal IndexOf beats a compiled regex here.
    # This runs once per candidate per context - hundreds of thousands of times on a
    # default cleanup - so the constant factor is the whole cost of the scan.
    if ($joined.IndexOf([string]$Context.Product, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    if ($Context.Year -eq '*') { return $true }

    return ($joined -match "\b$([regex]::Escape([string]$Context.Year))\b")
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
    # Content libraries (RVT/ACAD family/template payloads) are the bulk of the volume under
    # ProgramData\Autodesk and never carry installer metadata, so they are skipped outright.
    $skipPattern = '(?i)\\(Libraries|Library|Content|Templates|Families|Materials|Samples|Lookup Tables)\\'
    try {
        return @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -le 5242880 -and
                $_.FullName -notmatch $skipPattern -and
                ($extensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -match '(?i)(manifest|setup|package|deployment|bundle|collection)')
            } |
            Select-Object -First 250)
    } catch {
        return @()
    }
}

function Get-SACOdisFileTextCache {
    <#
    .SYNOPSIS
        Reads a folder's searchable files once, for reuse across every target context.
    #>
    param([string]$FolderPath)

    $cache = @()
    foreach ($file in (Get-SACSearchableOdisFile -FolderPath $FolderPath)) {
        $text = Read-SACFileText -Path $file.FullName
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $cache += [PSCustomObject]@{ Name = $file.Name; FullName = $file.FullName; Text = $text }
    }
    return @($cache)
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

    # Quick-reject filter. Testing every file against every product/year context is
    # 243 regex passes per file on a default cleanup; a file that mentions no target
    # product and no target year cannot match any context, and two regexes settle that.
    $productAlternation = (@($Contexts | ForEach-Object { [regex]::Escape([string]$_.Product) } | Select-Object -Unique) -join '|')
    $yearAlternation = (@($Contexts | ForEach-Object { [string]$_.Year } | Where-Object { $_ -ne '*' } | ForEach-Object { [regex]::Escape($_) } | Select-Object -Unique) -join '|')
    $anyYearContext = @($Contexts | Where-Object { [string]$_.Year -eq '*' }).Count -gt 0

    $programData = if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }
    $roots = @(
        [PSCustomObject]@{ Source = 'ODIS Metadata'; Path = (Join-Path $programData 'Autodesk\ODIS\metadata'); Action = 'Rename Folder' },
        [PSCustomObject]@{ Source = 'ODIS Extract';  Path = (Join-Path $programData 'Autodesk\ODIS\extract');  Action = 'Rename Folder' }
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path)) { continue }

        $folders = @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue)
        foreach ($folder in $folders) {
            # One folder produces at most one remnant record. Without this the file scan and
            # its log lines were repeated once per product/year context - 243 passes over the
            # same files on a default cleanup - which is what made the scan take 23 minutes
            # and flooded the log with identical "Queued ODIS metadata folder" lines.
            $fileCache = $null
            $folderQueued = $false

            foreach ($context in $Contexts) {
                if ($folderQueued) { break }

                $matched = Test-SACContextTextMatch -Context $context -Text @($folder.Name, $folder.FullName)
                $matchedTerm = if ($matched) { Get-SACContextMatchedTerm -Context $context -Text @($folder.Name, $folder.FullName) } else { $null }
                $matchedFile = $null
                $identifierText = $folder.Name

                if (-not $matched) {
                    if ($null -eq $fileCache) {
                        $fileCache = @(Get-SACOdisFileTextCache -FolderPath $folder.FullName | Where-Object {
                            ($productAlternation -and $_.Text -match $productAlternation) -and
                            ($anyYearContext -or ($yearAlternation -and $_.Text -match $yearAlternation))
                        })
                    }
                    foreach ($file in $fileCache) {
                        if (Test-SACContextTextMatch -Context $context -Text @($file.Name, $file.Text)) {
                            $matched = $true
                            $matchedFile = $file.FullName
                            $matchedTerm = Get-SACContextMatchedTerm -Context $context -Text @($file.Name, $file.Text)
                            $identifierText = $file.Text
                            $warnings += Get-SACTextPathWarning -Context $context -Text $file.Text -Source $root.Source -SourcePath $file.FullName -DisplayName $folder.Name
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

                $folderQueued = $true
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

function Get-SACCodeMatchedContext {
    <#
    .SYNOPSIS
        Returns the target contexts whose product/packed codes appear in a registry value.
    .DESCRIPTION
        Tests each distinct code once and fans the hit out to the contexts that own it,
        instead of re-testing every code for every context.
    #>
    param(
        [hashtable]$CodeContextMap,
        [string[]]$DistinctCodes,
        [string]$ValueName,
        [string]$ValueData
    )

    if ($null -eq $CodeContextMap -or $DistinctCodes.Count -eq 0) { return @() }

    $matchedContexts = @()
    $seen = @{}
    foreach ($code in $DistinctCodes) {
        $hit = $false
        if (-not [string]::IsNullOrEmpty($ValueName) -and $ValueName.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
        elseif (-not [string]::IsNullOrEmpty($ValueData) -and $ValueData.IndexOf($code, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true }
        if (-not $hit) { continue }

        foreach ($context in $CodeContextMap[$code]) {
            $key = "$($context.Product)|$($context.Year)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $matchedContexts += $context
        }
    }

    return @($matchedContexts)
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
                    # Joined once per key, not once per key per context.
                    $text = @(@(
                        $displayName,
                        $values['DisplayVersion'],
                        $values['InstallLocation'],
                        $values['InstallSource'],
                        $values['LocalPackage'],
                        $values['UninstallString'],
                        $productCode,
                        $packedCode
                    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '

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

    # The Components hive holds tens of thousands of keys. Testing every value against
    # every context's every code was O(keys x contexts x codes) and dominated the run
    # time (measured: 23 minutes on a machine with 243 contexts). Codes are indexed once
    # so each value is tested against the small set of *distinct* codes instead.
    $codeContextMap = @{}
    foreach ($context in $referenceContexts) {
        foreach ($code in @($context.ProductCodes + $context.PackedCodes)) {
            if ([string]::IsNullOrWhiteSpace($code)) { continue }
            $key = $code.Trim().ToUpperInvariant()
            if (-not $codeContextMap.ContainsKey($key)) { $codeContextMap[$key] = @() }
            $codeContextMap[$key] += $context
        }
    }
    $distinctCodes = @($codeContextMap.Keys)

    $baseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

        $componentSubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'
        $componentKeyRoot = $baseKey.OpenSubKey($componentSubPath)
        if ($componentKeyRoot -and $referenceContexts.Count -gt 0) {
            # The Components hive routinely holds 75,000+ keys, so the scan is minutes long
            # even at one pass. Report progress: a silent multi-minute phase reads as a hang.
            $componentNames = @($componentKeyRoot.GetSubKeyNames())
            $componentTotal = $componentNames.Count
            $componentSeen = 0
            Write-SACMsg "  Scanning $componentTotal MSI component registration(s)..." "Info"
            foreach ($componentName in $componentNames) {
                $componentSeen++
                if (($componentSeen % 5000) -eq 0) {
                    Write-Host "`r    Components scanned: $componentSeen / $componentTotal" -NoNewline -ForegroundColor DarkGray
                }
                $componentKey = $componentKeyRoot.OpenSubKey($componentName)
                if (-not $componentKey) { continue }

                try {
                    foreach ($valueName in $componentKey.GetValueNames()) {
                        $valueData = [string]$componentKey.GetValue($valueName)
                        foreach ($context in (Get-SACCodeMatchedContext -CodeContextMap $codeContextMap -DistinctCodes $distinctCodes -ValueName $valueName -ValueData $valueData)) {
                            $componentRefs += [PSCustomObject]@{
                                Product       = $context.Product
                                Year          = $context.Year
                                ComponentKey  = $componentName
                                RegistryPath  = "HKLM:\$componentSubPath\$componentName"
                                ValueName     = $valueName
                                ValueData     = $valueData
                                MatchedTerm   = Get-SACContextMatchedTerm -Context $context -Text @($valueName, $valueData)
                            }
                        }
                    }
                } finally {
                    $componentKey.Close()
                }
            }
            if ($componentTotal -ge 5000) { Write-Host "`r$(' ' * 60)`r" -NoNewline }
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
                            foreach ($context in (Get-SACCodeMatchedContext -CodeContextMap $codeContextMap -DistinctCodes $distinctCodes -ValueName $valueName -ValueData $valueData)) {
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
                                    MatchedTerm       = Get-SACContextMatchedTerm -Context $context -Text @($valueName, $valueData)
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
        'Get-SACOdisFileTextCache',
        'Get-SACOdisRemnant',
        'Get-SACCodeMatchedContext',
        'Get-SACHiddenInstallerState'
    )

    return (($names | ForEach-Object {
        $cmd = Get-Command -Name $_ -CommandType Function -ErrorAction Stop
        "function $($_) {`r`n$($cmd.ScriptBlock.ToString())`r`n}"
    }) -join "`r`n")
}
# SIG # Begin signature block
# MII9NwYJKoZIhvcNAQcCoII9KDCCPSQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCASCeQJ1uPQHbX2
# qB5hoC4RFf2rDnxdO5AClTwwlt7O3KCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# IgQgI0LZNrPrDaHa5qFw6MWF/gxIunFEofW/lv7DYr6TrZIwDQYJKoZIhvcNAQEB
# BQAEggGAAbXn20DjdIyjn6pRW6Y8OXGcJulZ/MHVQfQEymDmKoQ1pJTUgp+4uo68
# qq3GIqVBfWf4NhII97tcUa4XJI56NtkHd4j5kAbnLUllJ3YvkX1mkpNxtN6OBSr9
# 2wNCUfTos+hI/ZDtGTPV0i+/cHeuUHVYpvc5QEVaSNCNj1tBmq0RLuq9bNQN3oOI
# HXywr797GYmQd9f3MwH7hYNQ/j/r+0vN3PvulvFq/P1bZWkexIFYbUumRXKm7R8i
# +GaI5GdrANtR6IKw/2va8cfXD3UffGf5ESPkeRZhj/F4Sil2Akt7KfaMK64IO8Tr
# YUBt8NTc/oZeW3ItnYrRw/USEgGCwhiGfdKVk9pT3kzdzf8cIA+9jJ/CvRGFhgZs
# w9SqcxtAlLT+EUqqSFjAjbzLpp0LYaVVIrrIj0JH8k7Mv2WoCKlg8wIMRDn6CYwe
# N/xtw97Oj2AmRVpK+rfZyts73rRx4hHhxsz02JTINwsJVq7HI/+i5PgFjQcs4694
# Yp/tGxrzoYIYETCCGA0GCisGAQQBgjcDAwExghf9MIIX+QYJKoZIhvcNAQcCoIIX
# 6jCCF+YCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEILU3FgzQr6oL
# ejo28mEL4ATVcmbR8XdB1tbjh4kT9LDHAgZqhGwzOvYYEzIwMjYwOTA5MTQzODA5
# LjAwN1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
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
# hkiG9w0BCQUxDxcNMjYwOTA5MTQzODA5WjAvBgkqhkiG9w0BCQQxIgQgi0gP68vA
# W4iPk1dMGHp8cRmuxN+gR1OoyCjWIG36ofswgbkGCyqGSIb3DQEJEAIvMYGpMIGm
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
# 0Sk7F1Bxw9rKA50iTM6qlnvpY4I74Kf9MA0GCSqGSIb3DQEBAQUABIICAJd6WlWR
# erl9NagpbUjElK5J6Y6hkmxx31lAKAT3W1p5Mkp2P/TI66+bu4OJEbRosHainh7Y
# QQND3MYho/yTk40SxCM22o5RYq8fj0n2Ss3na7mktnYncAufJcLcvBe2sRWxj35T
# moFwfoXr/ZKL2X3vv9RS2iIiJ+2e0W8J25yUYlkGeLqQVQjd8YfqkiLT/PA1DASq
# t4E0ILzRBZilUXuKPHJJuY2XSiBlfRDEagPylIed41DANtEEGiDtg2wlVghup+DJ
# HOKtRpyLN0QixBKW5emtFxcWiyd264W8Nz7fK0JkGTJAz9/wHeSv1A8Xsnx/rJRb
# OnYmUU70YzwYciH5VA0QyI0ZjtfZk1A0jb4P1zf2tC+5nTnYyGJm8QMrLfXTOHLw
# dkEY3DvrsBnyOBcJSKw5XZvR77FXWssrJsvkHFw1+/vudF0LiiGEVk0AkQOyoj7r
# 4Hb5qMqG08TzE9IGwqN3FI4gMI8Y+J6Z9X/HnmcCciysoGCtb+u7xp7KNk0PBzh3
# wUhFAKXMcfPAS6CdFbta3seqKpjCjYnEo5+Ndtxb5OQG5dFx7ho62kjXgiRanw5G
# d0BU9xF092M95ip1evPtG5NUZDZrpm6RThE9m6uHhsDakK9ZbhOU1W8/TWaCmrKe
# slEfW3hDi9g+X/rQUTbCJelGMdEcbJfg+FXq
# SIG # End signature block
