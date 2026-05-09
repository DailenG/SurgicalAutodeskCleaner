BeforeAll {
    $ModulePath = Resolve-Path "$PSScriptRoot\..\SurgicalAutodeskCleaner.psd1"
}

Describe "SurgicalAutodeskCleaner Module validation" {
    
    It "Should possess a valid Module Manifest" {
        $Manifest = Test-ModuleManifest -Path $ModulePath -WarningAction SilentlyContinue
        $Manifest | Should -Not -BeNullOrEmpty
    }

    It "Should export Start-SACCleanup, Start-SACPurge, and Start-SACInteractive" {
        $Module = Import-Module -Name $ModulePath -PassThru -Force
        $ExportedCommands = $Module.ExportedCommands.Keys
        
        $ExportedCommands | Should -Contain "Start-SACCleanup"
        $ExportedCommands | Should -Contain "Start-SACPurge"
        $ExportedCommands | Should -Contain "Start-SACInteractive"
        $ExportedCommands | Should -Contain "Start-SACScan"
    }

    It "Should export the Start-SAC alias" {
        $Module = Import-Module -Name $ModulePath -PassThru -Force
        $ExportedAliases = $Module.ExportedAliases.Keys
        
        $ExportedAliases | Should -Contain "Start-SAC"
    }

    It "Should pass PSScriptAnalyzer static analysis rules (if available)" {
        $analyzerAvailable = Get-Command -Name "Invoke-ScriptAnalyzer" -ErrorAction SilentlyContinue
        if ($analyzerAvailable) {
            $issues = Invoke-ScriptAnalyzer -Path $PSScriptRoot\..\ -Recurse | Where-Object {
                $_.Severity -in @("Error", "Warning") -and 
                $_.RuleName -notmatch "PSAvoidUsingWriteHost"
            }
            $issues.Count | Should -Be 0
        } else {
            Set-ItResult -Inconclusive -Because "PSScriptAnalyzer is not installed on this system."
        }
    }
}
