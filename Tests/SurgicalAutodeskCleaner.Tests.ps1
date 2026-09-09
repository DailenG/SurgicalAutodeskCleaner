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

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDJmqgucIoDumeX
# 4WYi+tP5noj0DVi3CoA8gp2XOS2B86CCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# IgQgF8Vx9mWs3PUq/7yexvxzsp1vaffE7JdecopFnVu7veQwDQYJKoZIhvcNAQEB
# BQAEggGAfA75urR5s3laGP0lTp5lNXd7JIfHrzqO5H6IMlp/etjsAZM2hsBgBAfq
# /jp+XcNPidyQMnHEPrPy6lpGUJNmIKIe5maVai8/gSu+6sw6wjWD4fPkqIuFA6J0
# QE9lBFGWmBzsR5BOmgjddWJPVUqapSuGDZiHCIM5OMhwu1+1HbvlUM6BCsNoOD/o
# tktHwijgk8+gSuqVNUYAQgUL1d8WPWiHp/UcRgwl/w/rONSCZy+4WNF+DFdrEwuw
# KeBkYfiygnUgwKEZWujD6Ndr7zdolerUqtM6JwoqeRmV1x6/xLcxu9tzzJRFyOBW
# qWxpEFY7k/0rDJiRPu9/XTU5tJGJhzlDc+5nZzcEbwDW2nxVRkDxJnVWjlivV4Bp
# 5rHHSqK8tqrzYNrc0jfRiug3CfcNwFk1tT6HL2Q/26MOJz5RvMgvlomQOstGEuat
# fK47ZmLMFus2A570pzTyIkaF4drDqU/fZYScvcTKKZdyzOr2GglcQ6eotcJl91Ay
# oYUtXit9oYIYFDCCGBAGCisGAQQBgjcDAwExghgAMIIX/AYJKoZIhvcNAQcCoIIX
# 7TCCF+kCAQMxDzANBglghkgBZQMEAgEFADCCAWIGCyqGSIb3DQEJEAEEoIIBUQSC
# AU0wggFJAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIEtr+B8NHrqT
# T5JyWWhY4Js4Dlmw+XOERautxNX523+AAgZqhI072AkYEzIwMjYwOTA5MDIyODA0
# LjM3NVowBIACAfSggeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMx
# JzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo3ODAwLTA1RTAtRDk0NzE1MDMGA1UE
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
# 2GwYe6ZoAF1bMIIHlzCCBX+gAwIBAgITMwAAAFck05XgounJMQAAAAAAVzANBgkq
# hkiG9w0BAQwFADBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3Rh
# bXBpbmcgQ0EgMjAyMDAeFw0yNTEwMjMyMDQ2NTNaFw0yNjEwMjIyMDQ2NTNaMIHb
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxN
# aWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRT
# UyBFU046NzgwMC0wNUUwLUQ5NDcxNTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMg
# UlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9yaXR5MIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAsWylCpMIfbizJLY1kPXO2cmX2HRWvRbAmeKSZ5ex7/jCymdV
# 7Eap+Ic2iqRtWDkKKe5gL6JV80wtn5C2qHJLPxUYFKNG3UkHkAI21MoCN+YWnhT8
# K/YuPib6+6970jdbeFKIiZMWwd5hnpX9J3jeteuEdXbp/DfFBK15JuD3JOzWuF2s
# uQCPgqYjQPk/gpq+3KCKtXJRbXSCSJ9YtITU2IHwmfdE7l2PfZ154w041po+fDeT
# j0gJOzcV/Jv56Q0M+w19jAKo/I5PEzrLV1IPQnmP4or1X4RbJXk8ONXyOOfXOxK2
# VLpNxgklK1yAezbFP2uzqihaXkW1h9GQLGENKESnezwgdRaLNNaYtm8AT/pZHYJ3
# 5mZVqkZdMIckpQHJk/F1fSLyDKeKtH4TC4cc3ESKUMgItq07ZZm74JCsfhmrQ1ij
# VNDi1Sln+QBamgC7WviZbkQnceQRq9DY+6hANwOrasAZUiVr2kPuj1jHDOXzUG4O
# 9QTK70P/oXSqZAN1oTv3UfF8JTGmAxg+l1ZPOz50MY96HBDw/3bI/wBGNvLk6fLV
# nrxGN5B5unF/lYvjjWbIUdyBPVQnPOKXu08SRHbY19M1HoWX6PNZv+vzSeqVeWWH
# KdKjC3GjVjbbGpi+JLbiyaKRSwEqo49tJLvu69cQ7dWsbksai4TURnVj2mMCAwEA
# AaOCAcswggHHMB0GA1UdDgQWBBSOg8leLTUOAglIZ+bjXpiD7RKSpzAfBgNVHSME
# GDAWgBRraSg6NS9IY0DPe9ivSek+2T3bITBsBgNVHR8EZTBjMGGgX6BdhltodHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBQdWJs
# aWMlMjBSU0ElMjBUaW1lc3RhbXBpbmclMjBDQSUyMDIwMjAuY3JsMHkGCCsGAQUF
# BwEBBG0wazBpBggrBgEFBQcwAoZdaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBQdWJsaWMlMjBSU0ElMjBUaW1lc3RhbXBp
# bmclMjBDQSUyMDIwMjAuY3J0MAwGA1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDgYDVR0PAQH/BAQDAgeAMGYGA1UdIARfMF0wUQYMKwYBBAGCN0yD
# fQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lv
# cHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTAIBgZngQwBBAIwDQYJKoZIhvcNAQEMBQAD
# ggIBAHJ1wHY86Zk5SUBDPY25d/u9YJVaaNa71uxjX4cyO/XJ4uPENCSOwkRTnNog
# PLxTD0Fg3z4TFf/2T/0IFSxdtWVtTjhzrn+WLInzeRawUhTCFVrPBJKEWVshm+Ig
# 7/nB7JbJN88+ltImBbL5kT1StBLfG6UksAcDbNSQww90CUXhGueBxlnSvjkAX1oh
# iN16y1bB2s0rvQx8Csepl2CuBefTfDrMGzW/tzNx5YaK2D8OWweqTWZcGlJO4YjZ
# NI83cTrQghfHl/8AXOHj8cWL3wEFltQQs2xeRYAb3Kdnl7oIWKKXWaBYJY5P3QPs
# iC+DTMp7ejdYKTrb396f3gr+wL/Ms5/Z3vIWZPJJv18qNw40fUNveRnwzMQnx8dM
# 2bGuXXQZ5y7P8aXT4HJMo349qZtn4XQwiUE/DDp++MUL0kgjvd/Deo7Xr371PFPP
# Yb4TboZhjV1x9+wCHDoOpNCBt+VuXU78ytJdKzQ1Jv2cEP1F9H9/wSLsMDUvWME7
# u9mGElOPDZPMVr8AuBEuLdbTSEdaLwsZBplzxLBcgxhZ/Cs30yBhuE3QhqT1YDZ2
# pa56RexPA2SasPcToT6gJgJ6E06BmZ2zQTNvWOjs5XQqHbYuXcoeDcwe2UaC7EDO
# GD8GmLE9LiqtQsuQCM7v7I2xR+sPZT2Ax/85HjIkM+3MzTK1MYIHRjCCB0ICAQEw
# eDBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMAITMwAAAFck05XgounJMQAAAAAAVzANBglghkgBZQMEAgEFAKCCBJ8wEQYL
# KoZIhvcNAQkQAg8xAgUAMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAcBgkq
# hkiG9w0BCQUxDxcNMjYwOTA5MDIyODA0WjAvBgkqhkiG9w0BCQQxIgQgSAGZhtOx
# DQHf25Qyh9vQNg0eB3n8TThAfk0Ob3lk72cwgbkGCyqGSIb3DQEJEAIvMYGpMIGm
# MIGjMIGgBCD1PJ9ktQVuTGWIbKLO4f1VUOlUU29ARCEpDZmFTHjbUjB8MGWkYzBh
# MQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIw
# MAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0EgMjAy
# MAITMwAAAFck05XgounJMQAAAAAAVzCCA2EGCyqGSIb3DQEJEAISMYIDUDCCA0yh
# ggNIMIIDRDCCAiwCAQEwggEJoYHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVy
# YXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046NzgwMC0wNUUwLUQ5NDcx
# NTAzBgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0
# aG9yaXR5oiMKAQEwBwYFKw4DAhoDFQD9LzE5nEJRAUE2Ss3xaKKPXHnLw6BnMGWk
# YzBhMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MTIwMAYDVQQDEylNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lc3RhbXBpbmcgQ0Eg
# MjAyMDANBgkqhkiG9w0BAQsFAAIFAO5KuxMwIhgPMjAyNjA5MDgxNjQ5MjNaGA8y
# MDI2MDkwOTE2NDkyM1owdzA9BgorBgEEAYRZCgQBMS8wLTAKAgUA7kq7EwIBADAK
# AgEAAgI1+gIB/zAHAgEAAgITjjAKAgUA7kwMkwIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQCuVC2B5wJ7g1O5Z1YoHRn/9KQgrkdAUVu+jcfj5br6o154IyNX
# a2Z1yjLW6WqcYY6wJg/d7w1F+/+6HjgypxGSDonSlDoaZfMp/TxzCOnBKxtPe2HL
# w3dXpqNoG5NiIwyuFKXl9+91BPGsKNSu2W9EtwW/ODWQ2AkBkibZ65gFs35u0Z2b
# eUTl0sI0PKymLkxEM5xm4+ob7TGmKHWnfE/gYpikCOA8hydISzdtwl7g891W4yA0
# vAR3quCaKV2AGD4ihADfCwQVw5gyircsRsNQAdBk5ftmUKObyeitTqmkDeDn1Qfw
# Qr9wluJUyhRhHa9cZnYGj04A+eGpUCLC/DXTMA0GCSqGSIb3DQEBAQUABIICAFh9
# 0BTMyyjayGoWs5LX3y1/hpeOOYnBxtPFXJL7FU6YyImjQDckAjtLDXWDpYDC7Kuu
# PMXxKM1qqspqBcyzM1DRoO4e9bVhUEfaK6z+6WBD7ya2a3J7kAbR4KsCqkNDluGr
# hlnRV9UfB2jUEcXmQupSJ1n1CK9BRwz64NZTlxB2cCUB7SXlYXidJ5ndwUV2aFa1
# wWo6Smj52E++1eCupowgWzPiO8rANQdpJDPhB8YwlJ3AgevhJkd1Gob0chii9PqS
# +6omvVMFRc68qfeCKuR/tRH47TCTBU+ijK0yX+Adl6lbj1AmWOqByyWCrVOwhgP7
# ySJxYK6i32O0cnwbF9GyZ8uC5e3p1A3rJn9sPkOhfL2BAgqFXtGboRqN460g/ND8
# cMUhSnr2k4sepB1Uy6VDxGMx6Vz/B97Gq1P76mD0MbQ1An7l0XdZG7dBLONNCehS
# 4NXaKHmBR6oJVg636vxxSRFC7AtUUtkQGN+7xM/Ux7M+D60NAmklGfPi4x9Mqb2o
# /ohoa1nDGh+cDieZ6M23B/6G8K8+Wg5FKHWPsrsq6Bz0uM2ln11L/abrR34qBfRu
# jBjQHj5bYeTHcfvImbUZo1JIri5ZM1Bjmh+46qoCE6RdZ+tHcObSsPMZVPJGa8N3
# 0+OwWsN5gy/Y7WcL+aEuGY+L1a04pkUI0fppn+ip
# SIG # End signature block
