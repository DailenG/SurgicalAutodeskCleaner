#
# Installer-hive residue scanning.
#
# Post-run verification used to be ARP-driven, so it reported "0 components / all
# operations completed successfully" over products it had just orphaned. This scan
# reads the Windows Installer hives directly and flags the two states that ARP
# cannot see:
#   1. a product registered in an installer hive with no ARP entry;
#   2. a patch registered globally but linked to zero products.
#

$script:SACResidueNamePattern = 'Autodesk|AutoCAD|Revit|Civil 3D|Navisworks|Inventor|3ds Max|Maya|ReCap|Vault|InfraWorks|Fusion|Alias|Moldflow|Modlflow|Netfabb|Advance Steel|DWG TrueView|Desktop Connector|AdODIS|AdSSO|AdskLicensing'

function Get-SACArpKeyNameSet {
    <#
    .SYNOPSIS
        Returns the set of Add/Remove Programs key names present in both uninstall hives.
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $script:SACArpRoots) {
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            [void]$set.Add($key.PSChildName)
        }
    }
    return ,$set
}

function Get-SACLinkedPatchCodeSet {
    <#
    .SYNOPSIS
        Returns the packed patch codes that at least one registered product still links to.
    #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $productRoots = @()
    foreach ($sidKey in @(Get-ChildItem -LiteralPath $script:SACInstallerUserDataRoot -ErrorAction SilentlyContinue)) {
        $productRoots += "$($sidKey.PSPath)\Products"
    }
    $productRoots += "$($script:SACInstallerClassesRoot)\Products"

    foreach ($root in $productRoots) {
        foreach ($productKey in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $patchesKey = "$($productKey.PSPath)\Patches"
            if (-not (Test-Path -LiteralPath $patchesKey)) { continue }

            foreach ($patchKey in @(Get-ChildItem -LiteralPath $patchesKey -ErrorAction SilentlyContinue)) {
                [void]$set.Add($patchKey.PSChildName)
            }

            $listed = (Get-ItemProperty -LiteralPath $patchesKey -Name 'Patches' -ErrorAction SilentlyContinue).Patches
            foreach ($entry in @($listed)) {
                if (-not [string]::IsNullOrWhiteSpace($entry)) { [void]$set.Add($entry.Trim()) }
            }
        }
    }

    return ,$set
}

function Get-SACOrphanedInstallerProduct {
    <#
    .SYNOPSIS
        Finds products registered in an installer hive with no Add/Remove Programs entry.
    #>
    param (
        [string]$NamePattern = $script:SACResidueNamePattern,
        [switch]$AnyVendor
    )

    $arpNames = Get-SACArpKeyNameSet
    $found = @{}

    $sources = @()
    foreach ($sidKey in @(Get-ChildItem -LiteralPath $script:SACInstallerUserDataRoot -ErrorAction SilentlyContinue)) {
        $sources += [PSCustomObject]@{ Hive = "Installer\UserData\$($sidKey.PSChildName)\Products"; Path = "$($sidKey.PSPath)\Products"; IsUserData = $true }
    }
    $sources += [PSCustomObject]@{ Hive = 'Classes\Installer\Products'; Path = "$($script:SACInstallerClassesRoot)\Products"; IsUserData = $false }

    foreach ($source in $sources) {
        foreach ($productKey in @(Get-ChildItem -LiteralPath $source.Path -ErrorAction SilentlyContinue)) {
            $packed = $productKey.PSChildName
            if (-not (Test-SACPackedMsiCode -Value $packed)) { continue }

            $displayName = $null
            $localPackage = $null
            if ($source.IsUserData) {
                $installProps = "$($productKey.PSPath)\InstallProperties"
                if (-not (Test-Path -LiteralPath $installProps)) { continue }
                $props = Get-ItemProperty -LiteralPath $installProps -ErrorAction SilentlyContinue
                if ($props) {
                    $displayName = [string]$props.DisplayName
                    $localPackage = [string]$props.LocalPackage
                }
            } else {
                $props = Get-ItemProperty -LiteralPath $productKey.PSPath -ErrorAction SilentlyContinue
                if ($props) { $displayName = [string]$props.ProductName }
            }

            $productCode = $null
            try { $productCode = ConvertFrom-SACPackedMsiCode -PackedCode $packed } catch { $productCode = $null }
            if (-not $productCode) { continue }
            if ($arpNames.Contains($productCode)) { continue }

            if (-not $AnyVendor) {
                if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName -notmatch $NamePattern) { continue }
            }

            if ($found.ContainsKey($packed)) {
                $existing = $found[$packed]
                if ($existing.Hives -notcontains $source.Hive) { $existing.Hives += $source.Hive }
                if ([string]::IsNullOrWhiteSpace($existing.DisplayName)) { $existing.DisplayName = $displayName }
                if ([string]::IsNullOrWhiteSpace($existing.LocalPackage)) { $existing.LocalPackage = $localPackage }
                continue
            }

            $found[$packed] = [PSCustomObject]@{
                ProductCode  = $productCode
                PackedCode   = $packed
                DisplayName  = $displayName
                LocalPackage = $localPackage
                Hives        = @($source.Hive)
            }
        }
    }

    return @($found.Values | Sort-Object DisplayName, ProductCode)
}

function Get-SACOrphanedInstallerPatch {
    <#
    .SYNOPSIS
        Finds patches registered globally but linked to zero products.
    #>
    param (
        [string]$NamePattern = $script:SACResidueNamePattern,
        [switch]$AnyVendor
    )

    $linked = Get-SACLinkedPatchCodeSet
    $found = @{}

    $sources = @()
    foreach ($sidKey in @(Get-ChildItem -LiteralPath $script:SACInstallerUserDataRoot -ErrorAction SilentlyContinue)) {
        $sources += [PSCustomObject]@{ Hive = "Installer\UserData\$($sidKey.PSChildName)\Patches"; Path = "$($sidKey.PSPath)\Patches" }
    }
    $sources += [PSCustomObject]@{ Hive = 'Classes\Installer\Patches'; Path = "$($script:SACInstallerClassesRoot)\Patches" }

    foreach ($source in $sources) {
        foreach ($patchKey in @(Get-ChildItem -LiteralPath $source.Path -ErrorAction SilentlyContinue)) {
            $packed = $patchKey.PSChildName
            if (-not (Test-SACPackedMsiCode -Value $packed)) { continue }
            if ($linked.Contains($packed)) { continue }

            $props = Get-ItemProperty -LiteralPath $patchKey.PSPath -ErrorAction SilentlyContinue
            $displayName = if ($props) { [string]$props.DisplayName } else { $null }
            $localPackage = if ($props) { [string]$props.LocalPackage } else { $null }

            $patchCode = $null
            try { $patchCode = ConvertFrom-SACPackedMsiCode -PackedCode $packed } catch { $patchCode = $null }
            if (-not $patchCode) { continue }

            if (-not $AnyVendor) {
                $haystack = "$displayName $localPackage"
                if ([string]::IsNullOrWhiteSpace($displayName) -or $haystack -notmatch $NamePattern) { continue }
            }

            if ($found.ContainsKey($packed)) {
                $existing = $found[$packed]
                if ($existing.Hives -notcontains $source.Hive) { $existing.Hives += $source.Hive }
                if ([string]::IsNullOrWhiteSpace($existing.DisplayName)) { $existing.DisplayName = $displayName }
                if ([string]::IsNullOrWhiteSpace($existing.LocalPackage)) { $existing.LocalPackage = $localPackage }
                continue
            }

            $found[$packed] = [PSCustomObject]@{
                PatchCode    = $patchCode
                PackedCode   = $packed
                DisplayName  = $displayName
                LocalPackage = $localPackage
                Hives        = @($source.Hive)
            }
        }
    }

    return @($found.Values | Sort-Object DisplayName, PatchCode)
}

function Get-SACInstallerResidue {
    <#
    .SYNOPSIS
        Scans the Windows Installer hives for registrations that ARP cannot see.
    .DESCRIPTION
        Returns orphaned products (registered, no ARP entry) and orphaned patches
        (registered globally, linked to zero products). This is the only verification
        in the module that does not depend on Add/Remove Programs.
    #>
    param (
        [string]$NamePattern = $script:SACResidueNamePattern,
        [switch]$AnyVendor
    )

    $products = Get-SACOrphanedInstallerProduct -NamePattern $NamePattern -AnyVendor:$AnyVendor
    $patches = Get-SACOrphanedInstallerPatch -NamePattern $NamePattern -AnyVendor:$AnyVendor

    return [PSCustomObject]@{
        OrphanedProducts = $products
        OrphanedPatches  = $patches
        Total            = ($products.Count + $patches.Count)
        NamePattern      = $NamePattern
        ScannedAt        = Get-Date
    }
}

function Write-SACInstallerResidueReport {
    <#
    .SYNOPSIS
        Prints the residue scan result and persists it to InstallerResidue.txt.
    .OUTPUTS
        The report file path when residue was found and written, otherwise $null.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [object]$Residue,

        [string]$LogDir,

        [switch]$NoFile
    )

    if ($Residue.Total -eq 0) {
        Write-SACMsg "Installer-hive residue check: no orphaned product or patch registrations." "Success"
        return $null
    }

    Write-SACMsg "Installer-hive residue check: $($Residue.OrphanedProducts.Count) orphaned product registration(s), $($Residue.OrphanedPatches.Count) orphaned patch registration(s)." "Error"

    $lines = @(
        'INSTALLER-HIVE RESIDUE (not visible to Add/Remove Programs)',
        "Timestamp: $($Residue.ScannedAt)",
        '----------------------------------------------------------',
        ''
    )

    foreach ($product in $Residue.OrphanedProducts) {
        $label = if ([string]::IsNullOrWhiteSpace($product.DisplayName)) { '(no DisplayName)' } else { $product.DisplayName }
        Write-SACMsg "  [ORPHAN PRODUCT] $label $($product.ProductCode)" "Error"
        $lines += "[ORPHAN PRODUCT] $label"
        $lines += "    ProductCode : $($product.ProductCode)"
        $lines += "    Packed      : $($product.PackedCode)"
        $lines += "    Registered  : $($product.Hives -join ', ')"
        if ($product.LocalPackage) { $lines += "    LocalPackage: $($product.LocalPackage)" }
        $lines += '    Windows Installer still considers this product installed, but no ARP entry exists.'
        $lines += ''
    }

    foreach ($patch in $Residue.OrphanedPatches) {
        $label = if ([string]::IsNullOrWhiteSpace($patch.DisplayName)) { '(no DisplayName)' } else { $patch.DisplayName }
        Write-SACMsg "  [ORPHAN PATCH] $label $($patch.PatchCode)" "Error"
        $lines += "[ORPHAN PATCH] $label"
        $lines += "    PatchCode   : $($patch.PatchCode)"
        $lines += "    Packed      : $($patch.PackedCode)"
        $lines += "    Registered  : $($patch.Hives -join ', ')"
        if ($patch.LocalPackage) { $lines += "    LocalPackage: $($patch.LocalPackage)" }
        $lines += '    Registered globally but linked to zero products; installs can fail with 1647.'
        $lines += ''
    }

    if ($NoFile -or [string]::IsNullOrWhiteSpace($LogDir) -or -not (Test-Path -LiteralPath $LogDir)) { return $null }

    $reportPath = Join-Path $LogDir 'InstallerResidue.txt'
    try {
        $lines | Out-File -FilePath $reportPath -Encoding utf8 -Force
        Write-SACMsg "  Residue report written to $reportPath" "Warning"
        return $reportPath
    } catch {
        Write-SACQuietLog "Failed to write installer residue report: $($_.Exception.Message)"
        return $null
    }
}

# SIG # Begin signature block
# MII9OQYJKoZIhvcNAQcCoII9KjCCPSYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBUCMt4GtVAMvxK
# bYpHFlP3bqe1yFEOGzhuBh93SApQTqCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqTMIIajwIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDQC
# EzMABhNV2TZ6Ej5PSsgAAAAGE1UwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQgKyrsEodMKnBd3zoLTvSoKQWIaZgj2Fe1Jwng4uvFM7wwDQYJKoZIhvcNAQEB
# BQAEggGAFv0MI+UMF8OzRvrOvh7OMnlLucxejLIeLRbC7BZIrUgdI+mJrP4nmgnV
# otkw2MvN/BYPR+tKOMCowyHmASAmp3anRm69Elngq5IFkDzkF2PzjjNuDoTgxKTX
# EtgKBagHRWZzvIMLyXAsbZ0B2s8LPOXKHtNvH+KdNeEQLiD8z79nBWhm6SZKCcuU
# B1VfkEK6NJbnZl9EfeM6BAk6tbszd2rWIeaA5wHvkOY7HgzsJvZ/L4qME9TSI3gj
# cSFF46B9BUIQItBNSwuczxctMWLiBChOlDy8XNJVeDN3HoP59Z1LDAy4nWGlMiGq
# 11MQzYdIUWti5OWjHKGI0AjWuVb2x6tyZhBT2tJ3w38jEJ6jgg3NP7CAO2iOEetw
# R1ql7slyPIIuiR/rjdlfLTV12hiT4MxRm5h9r0t3CEcjyhxioKAfd43y44mIqLB1
# skjKQNDvO9fglkxzegWGngZM2BY5OMbDBI9Fu+bQ5CjUawLW1ONNc6xcDxUpb3t+
# tzWZ9hM4oYIYEzCCGA8GCisGAQQBgjcDAwExghf/MIIX+wYJKoZIhvcNAQcCoIIX
# 7DCCF+gCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3DQEJEAEEoIIBUASC
# AUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEILrivJirRZFG
# QYt3m0uq5xFsJtBvKCO7wDVQ2cTzwHfUAgZqhI0714oYEjIwMjYwOTA5MDIyNjUy
# Ljc2WjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjc4MDAtMDVFMC1EOTQ3MTUwMwYDVQQD
# EyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eaCC
# DyEwggeCMIIFaqADAgECAhMzAAAABeXPD/9mLsmHAAAAAAAFMA0GCSqGSIb3DQEB
# DAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9v
# dCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMDExMTkyMDMyMzFaFw0z
# NTExMTkyMDQyMzFaMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVz
# dGFtcGluZyBDQSAyMDIwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA
# nnznUmP94MWfBX1jtQYioxwe1+eXM9ETBb1lRkd3kcFdcG9/sqtDlwxKoVIcaqDb
# +omFio5DHC4RBcbyQHjXCwMk/l3TOYtgoBjxnG/eViS4sOx8y4gSq8Zg49REAf5h
# uXhIkQRKe3Qxs8Sgp02KHAznEa/Ssah8nWo5hJM1xznkRsFPu6rfDHeZeG1Wa1wI
# SvlkpOQooTULFm809Z0ZYlQ8Lp7i5F9YciFlyAKwn6yjN/kR4fkquUWfGmMopNq/
# B8U/pdoZkZZQbxNlqJOiBGgCWpx69uKqKhTPVi3gVErnc/qi+dR8A2MiAz0kN0nh
# 7SqINGbmw5OIRC0EsZ31WF3Uxp3GgZwetEKxLms73KG/Z+MkeuaVDQQheangOEMG
# J4pQZH55ngI0Tdy1bi69INBV5Kn2HVJo9XxRYR/JPGAaM6xGl57Ei95HUw9NV/uC
# 3yFjrhc087qLJQawSC3xzY/EXzsT4I7sDbxOmM2rl4uKK6eEpurRduOQ2hTkmG1h
# SuWYBunFGNv21Kt4N20AKmbeuSnGnsBCd2cjRKG79+TX+sTehawOoxfeOO/jR7wo
# 3liwkGdzPJYHgnJ54UxbckF914AqHOiEV7xTnD1a69w/UTxwjEugpIPMIIE67SFZ
# 2PMo27xjlLAHWW3l1CEAFjLNHd3EQ79PUr8FUXetXr0CAwEAAaOCAhswggIXMA4G
# A1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUa2koOjUv
# SGNAz3vYr0npPtk92yEwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEW
# M2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5
# Lmh0bTATBgNVHSUEDDAKBggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBi
# AEMAQTAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFMh+0mqFKhvKGZgEByfP
# UBBPaKiiMIGEBgNVHR8EfTB7MHmgd6B1hnNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlv
# biUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3JsMIGU
# BggrBgEFBQcBAQSBhzCBhDCBgQYIKwYBBQUHMAKGdWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSWRlbnRpdHklMjBWZXJp
# ZmljYXRpb24lMjBSb290JTIwQ2VydGlmaWNhdGUlMjBBdXRob3JpdHklMjAyMDIw
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAX4h2x35ttVoVdedMeGj6TuHYRJklFaW4
# sTQ5r+k77iB79cSLNe+GzRjv4pVjJviceW6AF6ycWoEYR0LYhaa0ozJLU5Yi+LCm
# crdovkl53DNt4EXs87KDogYb9eGEndSpZ5ZM74LNvVzY0/nPISHz0Xva71QjD4h+
# 8z2XMOZzY7YQ0Psw+etyNZ1CesufU211rLslLKsO8F2aBs2cIo1k+aHOhrw9xw6J
# CWONNboZ497mwYW5EfN0W3zL5s3ad4Xtm7yFM7Ujrhc0aqy3xL7D5FR2J7x9cLWM
# q7eb0oYioXhqV2tgFqbKHeDick+P8tHYIFovIP7YG4ZkJWag1H91KlELGWi3SLv1
# 0o4KGag42pswjybTi4toQcC/irAodDW8HNtX+cbz0sMptFJK+KObAnDFHEsukxD+
# 7jFfEV9Hh/+CSxKRsmnuiovCWIOb+H7DRon9TlxydiFhvu88o0w35JkNbJxTk4Mh
# F/KgaXn0GxdH8elEa2Imq45gaa8D+mTm8LWVydt4ytxYP/bqjN49D9NZ81coE6aQ
# Wm88TwIf4R4YZbOpMKN0CyejaPNN41LGXHeCUMYmBx3PkP8ADHD1J2Cr/6tjuOOC
# ztfp+o9Nc+ZoIAkpUcA/X2gSMkgHAPUvIdtoSAHEUKiBhI6JQivRepyvWcl+JYbY
# bBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCSqG
# SIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1M1oXDTI2MTAyMjIwNDY1M1owgdsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBS
# U0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQCxbKUKkwh9uLMktjWQ9c7ZyZfYdFa9FsCZ4pJnl7Hv+MLKZ1Xs
# Rqn4hzaKpG1YOQop7mAvolXzTC2fkLaocks/FRgUo0bdSQeQAjbUygI35haeFPwr
# 9i4+Jvr7r3vSN1t4UoiJkxbB3mGelf0neN6164R1dun8N8UErXkm4Pck7Na4Xay5
# AI+CpiNA+T+Cmr7coIq1clFtdIJIn1i0hNTYgfCZ90TuXY99nXnjDTjWmj58N5OP
# SAk7NxX8m/npDQz7DX2MAqj8jk8TOstXUg9CeY/iivVfhFsleTw41fI459c7ErZU
# uk3GCSUrXIB7NsU/a7OqKFpeRbWH0ZAsYQ0oRKd7PCB1Fos01pi2bwBP+lkdgnfm
# ZlWqRl0whySlAcmT8XV9IvIMp4q0fhMLhxzcRIpQyAi2rTtlmbvgkKx+GatDWKNU
# 0OLVKWf5AFqaALta+JluRCdx5BGr0Nj7qEA3A6tqwBlSJWvaQ+6PWMcM5fNQbg71
# BMrvQ/+hdKpkA3WhO/dR8XwlMaYDGD6XVk87PnQxj3ocEPD/dsj/AEY28uTp8tWe
# vEY3kHm6cX+Vi+ONZshR3IE9VCc84pe7TxJEdtjX0zUehZfo81m/6/NJ6pV5ZYcp
# 0qMLcaNWNtsamL4ktuLJopFLASqjj20ku+7r1xDt1axuSxqLhNRGdWPaYwIDAQAB
# o4IByzCCAccwHQYDVR0OBBYEFI6DyV4tNQ4CCUhn5uNemIPtEpKnMB8GA1UdIwQY
# MBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMwYaBfoF2GW2h0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFB1Ymxp
# YyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcmwweQYIKwYBBQUH
# AQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGlu
# ZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggr
# BgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBRBgwrBgEEAYI3TIN9
# AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkqhkiG9w0BAQwFAAOC
# AgEAcnXAdjzpmTlJQEM9jbl3+71glVpo1rvW7GNfhzI79cni48Q0JI7CRFOc2iA8
# vFMPQWDfPhMV//ZP/QgVLF21ZW1OOHOuf5YsifN5FrBSFMIVWs8EkoRZWyGb4iDv
# +cHslsk3zz6W0iYFsvmRPVK0Et8bpSSwBwNs1JDDD3QJReEa54HGWdK+OQBfWiGI
# 3XrLVsHazSu9DHwKx6mXYK4F59N8OswbNb+3M3HlhorYPw5bB6pNZlwaUk7hiNk0
# jzdxOtCCF8eX/wBc4ePxxYvfAQWW1BCzbF5FgBvcp2eXughYopdZoFgljk/dA+yI
# L4NMynt6N1gpOtvf3p/eCv7Av8yzn9ne8hZk8km/Xyo3DjR9Q295GfDMxCfHx0zZ
# sa5ddBnnLs/xpdPgckyjfj2pm2fhdDCJQT8MOn74xQvSSCO938N6jtevfvU8U89h
# vhNuhmGNXXH37AIcOg6k0IG35W5dTvzK0l0rNDUm/ZwQ/UX0f3/BIuwwNS9YwTu7
# 2YYSU48Nk8xWvwC4ES4t1tNIR1ovCxkGmXPEsFyDGFn8KzfTIGG4TdCGpPVgNnal
# rnpF7E8DZJqw9xOhPqAmAnoTToGZnbNBM29Y6OzldCodti5dyh4NzB7ZRoLsQM4Y
# PwaYsT0uKq1Cy5AIzu/sjbFH6w9lPYDH/zkeMiQz7czNMrUxggdGMIIHQgIBATB4
# MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAy
# MDIwAhMzAAAAVyTTleCi6ckxAAAAAABXMA0GCWCGSAFlAwQCAQUAoIIEnzARBgsq
# hkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqG
# SIb3DQEJBTEPFw0yNjA5MDkwMjI2NTJaMC8GCSqGSIb3DQEJBDEiBCDmmMQmOP49
# /19spvLbpqWh2YlXQxYcW9FQf5UmtHUo1DCBuQYLKoZIhvcNAQkQAi8xgakwgaYw
# gaMwgaAEIPU8n2S1BW5MZYhsos7h/VVQ6VRTb0BEISkNmYVMeNtSMHwwZaRjMGEx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIw
# AhMzAAAAVyTTleCi6ckxAAAAAABXMIIDYQYLKoZIhvcNAQkQAhIxggNQMIIDTKGC
# A0gwggNEMIICLAIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJh
# dGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1
# MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRo
# b3JpdHmiIwoBATAHBgUrDgMCGgMVAP0vMTmcQlEBQTZKzfFooo9cecvDoGcwZaRj
# MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAy
# MDIwMA0GCSqGSIb3DQEBCwUAAgUA7kq7EzAiGA8yMDI2MDkwODE2NDkyM1oYDzIw
# MjYwOTA5MTY0OTIzWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuSrsTAgEAMAoC
# AQACAjX6AgH/MAcCAQACAhOOMAoCBQDuTAyTAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAK5ULYHnAnuDU7lnVigdGf/0pCCuR0BRW76Nx+PluvqjXngjI1dr
# ZnXKMtbpapxhjrAmD93vDUX7/7oeODKnEZIOidKUOhpl8yn9PHMI6cErG097YcvD
# d1emo2gbk2IjDK4UpeX373UE8awo1K7Zb0S3Bb84NZDYCQGSJtnrmAWzfm7RnZt5
# ROXSwjQ8rKYuTEQznGbj6hvtMaYodad8T+BimKQI4DyHJ0hLN23CXuDz3VbjIDS8
# BHeq4JopXYAYPiKEAN8LBBXDmDKKtyxGw1AB0GTl+2ZQo5vJ6K1OqaQN4OfVB/BC
# v3CW4lTKFGEdr1xmdgaPTgD54alQIsL8NdMwDQYJKoZIhvcNAQEBBQAEggIAjvw0
# MXdr5x3OSKfRUtMd1xIo2bQwcdeMy5CvRROrmS2sVA6BqZyal3lmahoJDThDvhy7
# PXJNn8bs/Vlr3vhThvDuDlGJioU4l+rfgPQv5fafklN6jasAoECPxSFLids0z6Ii
# N51+BaX3KQXYbysjTm6OVLsdYDuTDsTpLVeWl+UFVJFE36PJHxXid9ks5shLQ3dN
# hiftZWVPKc7j4yoT3pjkosx8Ye65fdSrIhdDUyJvj/B8BhSb2QGSgXUdjIPTwVs1
# 8q6Y3r1KqNXrgme62bV7a5aPh83Pqm4LA7zJyG/QIS3FhrU9nZsH82tZzpe7LnJX
# Msgt05FXFX/v8/xYLhoPHotA9teCkdS/bUiNOHb1BAr3oJ+JBELfXvrwEpc2Zb+O
# u3Z/G1QB1TSMvDfmOJA07H8ygXSFjnLxjdlJcR76tQa1wXr+P7CD2BpeZ4pdyUg0
# 579KnHIm2n7ym61iNsX7mppScclk+og1LXpiYOsBP2g1WV+HSVBiIXWVlvL7iG5/
# 6JnI2M4hF4vr70jP92qKdFS1iYwUJNrJ0q9PMlJGsbuJumVnGsaOjwVNUtiUCXxD
# txHF1jJGbRg8uD0MJcgG3NqCEYSkwPkZzJoC8Bkjjfh44zPmA9H2abmEqcnfbwwS
# B/HS1t5hdF8s0sfSWN6pY++pvsKeAsB4nmtSC+I=
# SIG # End signature block
