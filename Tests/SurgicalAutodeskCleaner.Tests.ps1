BeforeAll {
    $ModulePath = Resolve-Path "$PSScriptRoot\..\SurgicalAutodeskCleaner.psd1"
    . "$PSScriptRoot\..\Private\Invoke-SACHiddenInstallerState.ps1"
    . "$PSScriptRoot\..\Private\Invoke-SACLogger.ps1"
    . "$PSScriptRoot\..\Private\Get-SACMsiRegistrationState.ps1"
    . "$PSScriptRoot\..\Private\Get-SACInstallerResidue.ps1"

    # Redirect the installer hive roots at a disposable HKCU tree so the registration
    # probe and residue scan can be exercised without touching real MSI state.
    $script:SACTestRoot = 'HKCU:\Software\SACPesterFixture'
    $script:SACInstallerUserDataRoot = "$script:SACTestRoot\UserData"
    $script:SACInstallerClassesRoot = "$script:SACTestRoot\Classes\Installer"
    $script:SACArpRoots = @("$script:SACTestRoot\Uninstall")

    function New-SACTestRegistration {
        param(
            [string]$ProductCode,
            [switch]$UserData,
            [switch]$Classes,
            [switch]$Arp,
            [string]$DisplayName = 'Autodesk Revit 2024'
        )

        $packed = ConvertTo-SACPackedMsiCode -ProductCode $ProductCode
        if ($UserData) {
            $key = New-Item -Path "$script:SACInstallerUserDataRoot\S-1-5-18\Products\$packed\InstallProperties" -Force
            New-ItemProperty -Path $key.PSPath -Name 'DisplayName' -Value $DisplayName -Force | Out-Null
        }
        if ($Classes) {
            $key = New-Item -Path "$script:SACInstallerClassesRoot\Products\$packed" -Force
            New-ItemProperty -Path $key.PSPath -Name 'ProductName' -Value $DisplayName -Force | Out-Null
        }
        if ($Arp) {
            $key = New-Item -Path "$($script:SACArpRoots[0])\$ProductCode" -Force
            New-ItemProperty -Path $key.PSPath -Name 'DisplayName' -Value $DisplayName -Force | Out-Null
        }
        return $packed
    }

    function Reset-SACTestHive {
        Remove-Item -Path $script:SACTestRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path "$script:SACInstallerUserDataRoot\S-1-5-18\Products" -Force | Out-Null
        New-Item -Path "$script:SACInstallerClassesRoot\Products" -Force | Out-Null
        New-Item -Path "$script:SACInstallerClassesRoot\Patches" -Force | Out-Null
        New-Item -Path $script:SACArpRoots[0] -Force | Out-Null
    }
}

AfterAll {
    Remove-Item -Path 'HKCU:\Software\SACPesterFixture' -Recurse -Force -ErrorAction SilentlyContinue
}

Describe "SurgicalAutodeskCleaner Module validation" {
    
    It "Should possess a valid Module Manifest" {
        $Manifest = Test-ModuleManifest -Path $ModulePath -WarningAction SilentlyContinue
        $Manifest | Should -Not -BeNullOrEmpty
    }

    It "Should export Start-SACCleanup, Start-SACPurge, Start-SACInteractive, and Repair-SACODIS" {
        $Module = Import-Module -Name $ModulePath -PassThru -Force
        $ExportedCommands = $Module.ExportedCommands.Keys
        
        $ExportedCommands | Should -Contain "Start-SACCleanup"
        $ExportedCommands | Should -Contain "Start-SACPurge"
        $ExportedCommands | Should -Contain "Start-SACInteractive"
        $ExportedCommands | Should -Contain "Start-SACScan"
        $ExportedCommands | Should -Contain "Repair-SACODIS"
    }

    It "Should export the Start-SAC alias" {
        $Module = Import-Module -Name $ModulePath -PassThru -Force
        $ExportedAliases = $Module.ExportedAliases.Keys
        
        $ExportedAliases | Should -Contain "Start-SAC"
    }

    It "Should pass PSScriptAnalyzer static analysis rules (if available)" {
        $analyzerAvailable = Get-Command -Name "Invoke-ScriptAnalyzer" -ErrorAction SilentlyContinue
        if ($analyzerAvailable) {
            $issues = Invoke-ScriptAnalyzer -Path $PSScriptRoot\..\ -Recurse -ErrorAction SilentlyContinue | Where-Object {
                $_.Severity -eq "Error" -and
                $_.RuleName -notmatch "PSAvoidUsingWriteHost"
            }
            $issues.Count | Should -Be 0
        } else {
            Set-ItResult -Inconclusive -Because "PSScriptAnalyzer is not installed on this system."
        }
    }
}

Describe "SurgicalAutodeskCleaner hidden MSI helper validation" {

    It "Should convert ProductCode GUIDs to packed MSI product codes" {
        ConvertTo-SACPackedMsiCode -ProductCode "{7346B4A0-2300-0510-0000-705C0D862004}" | Should -Be "0A4B643700320150000007C5D0680240"
        ConvertTo-SACPackedMsiCode -ProductCode "{C430585C-2023-4517-A253-D0C70D33ADD5}" | Should -Be "C585034C320271542A350D7CD033DA5D"
        ConvertTo-SACPackedMsiCode -ProductCode "{CDCC6F31-2023-4912-8E9B-D562B70697B6}" | Should -Be "13F6CCDC32022194E8B95D267B60796B"
        ConvertTo-SACPackedMsiCode -ProductCode "{F4566FD5-3182-4EAE-BD7C-5BE6AD1F5D35}" | Should -Be "5DF6654F2813EAE4DBC7B56EDAF1D553"
    }

    It "Should round-trip the packed patch code from the ARP eviction defect report" {
        ConvertTo-SACPackedMsiCode -ProductCode "{9CA05B9A-2414-0510-A1B4-FFF7A680FE55}" | Should -Be "A9B50AC9414201501A4BFF7F6A08EF55"
        ConvertFrom-SACPackedMsiCode -PackedCode "A9B50AC9414201501A4BFF7F6A08EF55" | Should -Be "{9CA05B9A-2414-0510-A1B4-FFF7A680FE55}"
    }

    It "Should convert packed MSI product codes back to ProductCode GUIDs" {
        ConvertFrom-SACPackedMsiCode -PackedCode "0A4B643700320150000007C5D0680240" | Should -Be "{7346B4A0-2300-0510-0000-705C0D862004}"
        ConvertFrom-SACPackedMsiCode -PackedCode "C585034C320271542A350D7CD033DA5D" | Should -Be "{C430585C-2023-4517-A253-D0C70D33ADD5}"
        ConvertFrom-SACPackedMsiCode -PackedCode "13F6CCDC32022194E8B95D267B60796B" | Should -Be "{CDCC6F31-2023-4912-8E9B-D562B70697B6}"
        ConvertFrom-SACPackedMsiCode -PackedCode "5DF6654F2813EAE4DBC7B56EDAF1D553" | Should -Be "{F4566FD5-3182-4EAE-BD7C-5BE6AD1F5D35}"
    }

    It "Should flag relative installer-derived paths" {
        Test-SACAbsoluteInstallerPath -PathValue "C:\Program Files\Autodesk\Revit 2023" | Should -BeTrue
        Test-SACAbsoluteInstallerPath -PathValue "\\server\share\Autodesk\Revit 2023" | Should -BeTrue
        Test-SACAbsoluteInstallerPath -PathValue "%ProgramFiles%\Autodesk\Revit 2023" | Should -BeTrue
        Test-SACAbsoluteInstallerPath -PathValue "Revit 2023\" | Should -BeFalse
    }
}

Describe "Add/Remove Programs eviction gate" {

    BeforeEach {
        Reset-SACTestHive
        $script:RevitCode = '{7346B4A0-2400-0510-0000-705C0D862004}'
        $script:RevitApp = [PSCustomObject]@{
            DisplayName = 'Autodesk Revit 2024'
            PSChildName = $script:RevitCode
            PSPath      = "Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Software\SACPesterFixture\Uninstall\$script:RevitCode"
        }
    }

    It "Keeps the ARP key and raises the reboot barrier on 3010" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes -Arp | Out-Null
        $script:SACFailures = @()
        Reset-SACEvictionState

        Invoke-SACArpEviction -App $script:RevitApp -ExitCode 3010 | Out-Null

        Test-Path -LiteralPath $script:RevitApp.PSPath | Should -BeTrue
        $script:SACRebootRequired | Should -BeTrue
        $script:SACRebootBlockers | Should -Contain 'Autodesk Revit 2024'
    }

    It "Removes the ARP key once the registration is gone" {
        New-SACTestRegistration -ProductCode $script:RevitCode -Arp | Out-Null
        $script:SACFailures = @()
        Reset-SACEvictionState

        Invoke-SACArpEviction -App $script:RevitApp -ExitCode 0 | Out-Null

        Test-Path -LiteralPath $script:RevitApp.PSPath | Should -BeFalse
        $script:SACRebootRequired | Should -BeFalse
    }

    It "Re-verifies deferred entries and evicts only after the registration disappears" {
        $packed = New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Arp
        $script:SACFailures = @()
        Reset-SACEvictionState

        Invoke-SACArpEviction -App $script:RevitApp -ExitCode 1603 | Out-Null
        Test-Path -LiteralPath $script:RevitApp.PSPath | Should -BeTrue

        Invoke-SACDeferredArpEviction
        Test-Path -LiteralPath $script:RevitApp.PSPath | Should -BeTrue

        Remove-Item -Path "$script:SACInstallerUserDataRoot\S-1-5-18\Products\$packed" -Recurse -Force
        Invoke-SACDeferredArpEviction

        Test-Path -LiteralPath $script:RevitApp.PSPath | Should -BeFalse
        $script:SACFailures.Component | Should -Not -Contain 'Uninstall incomplete: Autodesk Revit 2024'
    }

    It "Refuses to evict on 3010 even when nothing is registered" {
        $decision = Get-SACArpEvictionDecision -App $script:RevitApp -ExitCode 3010

        $decision.Evict | Should -BeFalse
        $decision.RebootRequired | Should -BeTrue
    }

    It "Refuses to evict a failed uninstall whose MSI registration survives" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes -Arp | Out-Null

        $decision = Get-SACArpEvictionDecision -App $script:RevitApp -ExitCode 1603

        $decision.Evict | Should -BeFalse
        $decision.RebootRequired | Should -BeFalse
        $decision.Reason | Should -BeLike '*registration still present*'
    }

    It "Refuses to evict a successful uninstall that left the registration behind" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Arp | Out-Null

        (Get-SACArpEvictionDecision -App $script:RevitApp -ExitCode 0).Evict | Should -BeFalse
    }

    It "Evicts once the MSI registration is confirmed gone" {
        New-SACTestRegistration -ProductCode $script:RevitCode -Arp | Out-Null

        $decision = Get-SACArpEvictionDecision -App $script:RevitApp -ExitCode 0

        $decision.Evict | Should -BeTrue
    }

    It "Keeps a failed non-MSI uninstall visible and retryable" {
        $exeApp = [PSCustomObject]@{
            DisplayName = 'Autodesk Access'
            PSChildName = 'Autodesk Access'
            PSPath      = "Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER\Software\SACPesterFixture\Uninstall\Autodesk Access"
        }

        (Get-SACArpEvictionDecision -App $exeApp -ExitCode 1603).Evict | Should -BeFalse
        (Get-SACArpEvictionDecision -App $exeApp -ExitCode 0).Evict | Should -BeTrue
    }

    It "Reports which hive holds the surviving registration" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData | Out-Null

        $state = Get-SACMsiRegistrationState -ProductCode $script:RevitCode

        $state.IsRegistered | Should -BeTrue
        $state.HasArp | Should -BeFalse
        $state.RegisteredIn | Should -Contain 'Installer\UserData\Products'
    }

    It "Returns null for entries Windows Installer does not manage" {
        Get-SACMsiRegistrationState -ProductCode 'Autodesk Access' | Should -BeNullOrEmpty
    }
}

Describe "Installer-hive residue scan" {

    BeforeEach {
        Reset-SACTestHive
        $script:RevitCode = '{7346B4A0-2400-0510-0000-705C0D862004}'
        $script:PatchCode = '{9CA05B9A-2414-0510-A1B4-FFF7A680FE55}'
    }

    It "Flags a product registered in an installer hive with no ARP entry" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes | Out-Null

        $residue = Get-SACInstallerResidue

        $residue.OrphanedProducts.ProductCode | Should -Contain $script:RevitCode
    }

    It "Does not flag a product that still has its ARP entry" {
        New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes -Arp | Out-Null

        (Get-SACInstallerResidue).OrphanedProducts.Count | Should -Be 0
    }

    It "Flags a patch registered globally but linked to zero products" {
        $packedProduct = New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes -Arp
        $packedPatch = ConvertTo-SACPackedMsiCode -ProductCode $script:PatchCode
        $patchKey = New-Item -Path "$script:SACInstallerClassesRoot\Patches\$packedPatch" -Force
        New-ItemProperty -Path $patchKey.PSPath -Name 'DisplayName' -Value 'Autodesk Revit 2024.3.6 Update' -Force | Out-Null

        $residue = Get-SACInstallerResidue

        $residue.OrphanedPatches.PatchCode | Should -Contain $script:PatchCode
        $packedProduct | Should -Not -BeNullOrEmpty
    }

    It "Does not flag a patch a product still links to" {
        $packedProduct = New-SACTestRegistration -ProductCode $script:RevitCode -UserData -Classes -Arp
        $packedPatch = ConvertTo-SACPackedMsiCode -ProductCode $script:PatchCode
        $patchKey = New-Item -Path "$script:SACInstallerClassesRoot\Patches\$packedPatch" -Force
        New-ItemProperty -Path $patchKey.PSPath -Name 'DisplayName' -Value 'Autodesk Revit 2024.3.6 Update' -Force | Out-Null
        New-Item -Path "$script:SACInstallerClassesRoot\Products\$packedProduct\Patches\$packedPatch" -Force | Out-Null

        (Get-SACInstallerResidue).OrphanedPatches.Count | Should -Be 0
    }
}

Describe "Installer-state scan scaling" {

    BeforeAll {
        $script:BenchContexts = @(Get-SACTargetContext `
            -TargetProducts @('AutoCAD', 'Revit', 'Civil 3D', 'Inventor') `
            -TargetYears @('2021', '2022', '2023') `
            -UninstallKeys @())
    }

    It "Fans a single code hit out to every context that owns it, without duplicates" {
        $codeA = '{7346B4A0-2400-0510-0000-705C0D862004}'
        $ctx1 = [PSCustomObject]@{ Product = 'Revit'; Year = '2024'; ProductCodes = @($codeA); PackedCodes = @() }
        $ctx2 = [PSCustomObject]@{ Product = 'Revit'; Year = '*';    ProductCodes = @($codeA); PackedCodes = @() }
        $map = @{ $codeA.ToUpperInvariant() = @($ctx1, $ctx2, $ctx1) }

        $hits = Get-SACCodeMatchedContext -CodeContextMap $map -DistinctCodes @($codeA.ToUpperInvariant()) `
            -ValueName $codeA -ValueData 'C:\Windows\Installer\thing.msi'

        $hits.Count | Should -Be 2
        Get-SACCodeMatchedContext -CodeContextMap $map -DistinctCodes @($codeA.ToUpperInvariant()) `
            -ValueName 'unrelated' -ValueData 'unrelated' | Should -BeNullOrEmpty
    }

    It "Records one ODIS remnant per folder regardless of how many contexts match" {
        $fake = Join-Path $env:TEMP "SACPester_$([guid]::NewGuid().ToString('N'))"
        $folder = Join-Path $fake 'Autodesk\ODIS\metadata\pkg1'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'manifest.json') `
            -Value '{"UPI2":"Revit-2023-x64","INSTALLDIR":"C:\\Program Files\\Autodesk\\Revit 2023"}'

        $saved = $env:ProgramData
        $env:ProgramData = $fake
        try {
            $odis = Get-SACOdisRemnant -Contexts $script:BenchContexts
        } finally {
            $env:ProgramData = $saved
            Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
        }

        @($odis.Remnants).Count | Should -Be 1
        $odis.Remnants[0].Path | Should -BeLike '*pkg1'
    }
}

Describe "Pending reboot reporting" {

    It "Names the conditions that tripped whenever it reports a pending reboot" {
        . "$PSScriptRoot\..\Private\Test-SACPendingReboot.ps1"
        $pending = Test-SACPendingReboot
        $reasons = @(Get-SACPendingRebootReason)

        if ($pending) { $reasons.Count | Should -BeGreaterThan 0 } else { $reasons.Count | Should -Be 0 }
    }
}
# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAqL+E8vNIG59Z4
# bLlAI2Gbd8kJNsX0jRxbYQkt9oPLxqCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqUMIIakAIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMC
# EzMABiB0TAioxsL2jdQAAAAGIHQwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQgQJ1Vzvs917AbvyEFTL6VyG0LUGdNEkl8NdgFDUn/Ar4wDQYJKoZIhvcNAQEB
# BQAEggGABBKAcdp2TM4kdfZXU08ngpu36P/g/ut4fZKqH0uuo4zKaCFiMG73UmT1
# dt1HNZrlCelchhiq/CVWbGQdfzCuoBDW8jmoOMLmeTgmJvz+0840S7RIJJdw26kL
# bdWF4+NSHyGcLzH+gpCG2AGvFVfoVJDPn+QcJiupsSjrg5Ui0s/6MU3TPAMfodzm
# H2TzLP9CftOaRmtqn4kp0D0+7sfPQQ+th65I4H/1wqj5wUwlv9f+p1CHaMj0PDi3
# l5YU+aPyKUYEcHt+x2KPV0pFhfeKffTLz34cthbQOdy2Vx9gooVjxDtz9L2JQOzs
# qFxzlwnw3d+Wgy00c1f/T1peApXGDCOudJmQv02VafAqFtxHV4HWF7kMeHalFcq0
# DpRTT+39+ubCv6JfVN/f+ivHISOh0rwfyJhrHbnwwfp6/4uBqN9NtSUoVVGwbu2I
# qvaUfmUynokL+e5oNtKSPA2kPCo2mfsMFssMiIN0UwOYyJXNibgVFI/LL7NyJzVx
# KJNLrXtgoYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIO2A5BQ/172i
# mo0zEaHVzAT73zF080x5/CShR5UCzigZAgZqhILuEbAYEzIwMjYwOTA5MTQzODM4
# LjI5N1owBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3RDAwLTA1RTAtRDk0NzE1MDMGA1UE
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
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFXZ3WkmKPn44gAAAAAAVTANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NDlaFw0yNjEwMjIyMDQ2NDlaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046N0QwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAvbkfkh5ZSLP0MCUWafaw/KZoVZu9iQx8r5JwhZvdrUi86UjC
# CFQONjQanrIxGF9hRGIZLQZ50gHrLC+4fpUEJff5t04VwByWC2/bWOuk6NmaTh9J
# pPZDcGzNR95QlryjfEjtl+gxj12zNPEdADPplVfzt8cYRWFBx/Fbfch08k6P9p7j
# X2q1jFPbUxWYJ+xOyGC1aKhDGY5b+8wL39v6qC0HFIx/v3y+bep+aEXooK8VoeWK
# +szfaFjXo8YTcvQ8UL4szu9HFTuZNv6vvoJ7Ju+o5aTj51sph+0+FXW38TlL/rDB
# d5ia79jskLtOeHbDjkbljilwzegcxv9i49F05ZrS/5ELZCCY1VaqO7EOLKVaxxdA
# O5oy1vb0Bx0ZRVX1mxFjYzay2EC051k6yGJHm58y1oe2IKRa/SM1+BTGse6vHNi5
# Q2d5ZnoR9AOAUDDwJIIqRI4rZz2MSinh11WrXTG9urF2uoyd5Ve+8hxes9ABeP2P
# YQKlXYTAxvdaeanDTQ/vwmnM+yTcWzrVm84Z38XVFw4G7p/ZNZ2nscvv6uru2Aev
# XcyV1t8ha7iWmhhgTWBNBrViuDlc3iPvOz2SVPbPeqhyY/NXwNZCAgc2H5pOztu6
# MwQxDIjte3XM/FkKBxHofS2abNT/0HG+xZtFqUJDaxgbJa6lN1zh7spjuQ8CAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBRWBF8QbdwIA/DIv6nJFsrB16xltjAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAFIe4ZJUe9qUKcWeWypchB58fXE/ZIWv2D5XP5/k/tB7LCN9BvmNSVKZ3Vec
# lQM978wfEvuvdMQSUv6Y20boIM8DK1K1IU9cP21MG0ExiHxaqjrikf2qbfrXIip4
# Ef3v2bNYKQxCxN3Sczp1SX0H7uqK2L5OhfDEiXf15iou5hh+EPaaqp49czNQpJDO
# R/vfJghUc/qcslDPhoCZpZx8b2ODvywGQNXwqlbsmCS24uGmEkQ3UH5JUeN6c91y
# asVchS78riMrm6R9ZpAiO5pfNKMGU2MLm1A3pp098DcbFTAc95Hh6Qvkh//28F/X
# e2bMFb6DL7Sw0ZO95v0gv0ZTyJfxS/LCxfraeEII9FSFOKAMEp1zNFSs2ue0GGjB
# t9yEEMUwvxq9ExFz0aZzYm8ivJfffpIVDnX/+rVRTYcxIkQyFYslIhYlWF9SjCw5
# r49qakjMRNh8W9O7aaoolSVZleQZjGt0K8JzMlyp6hp2lbW6XqRx2cOHbbxJDxmE
# NzohGUziI13lI2g2Bf5qibfC4bKNRpJo9lbE8HUbY0qJiE8u3SU8eDQaySPXOEhJ
# jxRCQwwOvejYmBG5P7CckQNBSnnl12+FKRKgPoj0Mv+z5OMhj9z2MtpbnHLAkep0
# odQClEyyCG/uR5tK5rW6mZH5Oq56UWS0NI6NV1JGS7Jri6jFMYIHRjCCB0ICAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFXZ3WkmKPn44gAAAAAAVTANBglghkgBZQMEAgEFAKCCBJ8wEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MTQzODM4WjAvBgkqhkiG9w0BCQQxIgQgXipnjG48
# gn8LcGEzroVrR5LiZ+d2+kgA96RljXJIORgwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCDYuTyXZIZiu799/v4PaqsmeSzBxh0rqkYq7sYYavj+zTB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFXZ3WkmKPn44gAAAAAAVTCCA2EGCyqGSIb3DQEJEAISMYIDUDCCA0yh
# ggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0QwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQAdO1QBgmW/tuBZV5EGjhfsV4cN6qBnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5LWYQwIhgPMjAyNjA5MDkwNDA1MjRaGA8y
# MDI2MDkxMDA0MDUyNFowdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7ktZhAIBADAK
# AgEAAgI09QIB/zAHAgEAAgIRHTAKAgUA7kyrBAIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQBUyRmMNJ+o5XpSgLZNG66RB8KGb66f68r7QXkcM6wX6FjfZIXs
# YEB85RtXGb1ZqTvI4scSkOU5SDoaSI3739mpYYm6f4xQ6tIG6Wwle8cz+wMc50PP
# sS7oqDR274P8F12TQaEZceK5PZ5C4BN8MRj+4EblbZ/FYKxpUzdpkYwlMsWW1Sof
# 8V7UxA1HIbDtP2DWia14lkULNKoEEgLAAzN63xDGSInXtgJ9tPIl1P7Ayt4evCMk
# uKNa1U4Ka63cmbQ84UGCQu/stheqQ8QhvEjIaWXxv8pFojjMIME6zBOX4b9PrGVw
# VkUjxkFYrdTCR/0lstgOs7x29uBvYAqAzxCTMA0GCSqGSIb3DQEBAQUABIICAAOs
# byFdj5Rj9mPjnu6pvpJHFJtV0ArEMvrkGP6GqSHcryzGiOi1LIDz4gZrGehGC3DJ
# noVnMJUP+Z9kYsuOyG1m8mYZsp8kNOgiVoZSA44iG5ujbBWiK/UsDtJU6UpHYKnL
# OfmON9sno4MEBbcncm3pc9zOQ42jncBZWFJghJ2JkbRkoxkuUL8lwEO/7mlrtQJ0
# cdGl7/DI9XSseW1AvWMFKhqmNV2FrmNxXWy3KO7oUdlyKnihtcY2ji79RhGn7xEI
# n2iNRxYJxjezN1J+qlD+GuF8WpUJ631ci5hkosj5ueQs4CLLJdwH0yV4GyXl5SxP
# zASJlIWcrSTmIsY9VJ+BYShdzs3CaIETheWvuxVwOE2z0Dk0I7g4EFRl38MeGZyq
# V2fV6gXXN0UXbIOSvT3Q6odmr0k1jno5laW/f2SXrVDqMjXqU1E5t3d8SzW+BLly
# IHf+2oiWPCSPoCTNTCp+26S8+kShhv3h8OHusZn8kAvmiRKAwjk7+tI6SqCD+6TX
# 9u8+dILwhOqGEwVTeGopg3TDCPvcF6H8Gnkv+eufMwtjR311Ig0Htr0nhIXNhLXH
# y3r3jp4Cx9qvmDyBPNlRV6KsFlGnyCdasDH0COG/3QDs6/8fEU0sSfoP7afsrfCi
# RolxIMiuNKB2tyJ8w+yWgi1sxKZYyLZasC99GK3B
# SIG # End signature block
