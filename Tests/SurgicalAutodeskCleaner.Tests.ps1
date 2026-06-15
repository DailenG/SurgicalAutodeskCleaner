BeforeAll {
    $ModulePath = Resolve-Path "$PSScriptRoot\..\SurgicalAutodeskCleaner.psd1"
    . "$PSScriptRoot\..\Private\Invoke-SACHiddenInstallerState.ps1"
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
