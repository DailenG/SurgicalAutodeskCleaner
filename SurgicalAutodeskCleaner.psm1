$Public = @( Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue )
$Private = @( Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue )

foreach ($Import in @($Public + $Private)) {
    try {
        . $Import.FullName
    }
    catch {
        Write-Error -Message "Failed to import function $($Import.Name): $_"
    }
}

New-Alias -Name Start-SAC -Value Start-SACInteractive -Force
Export-ModuleMember -Alias Start-SAC

Export-ModuleMember -Function $Public.BaseName
