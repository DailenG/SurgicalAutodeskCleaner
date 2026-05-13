function Connect-SACTarget {
    <#
    .SYNOPSIS
        Tests and establishes a connection to a remote target for SAC operations.
    #>
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )

    # Only treat empty input or explicit 'localhost' as the local machine reset.
    if ([string]::IsNullOrWhiteSpace($ComputerName) -or $ComputerName.Trim().ToLower() -eq "localhost") {
        return [PSCustomObject]@{
            ComputerName = "localhost"
            Credential   = $null
            Connected    = $true
        }
    }

    $TargetMachine = $ComputerName.Trim()
    Write-Host "`n  Testing WinRM connection to $TargetMachine..." -ForegroundColor Cyan
    
    $testParams = @{
        ComputerName = $TargetMachine
        ErrorAction  = "Stop"
    }
    if ($Credential) { $testParams["Credential"] = $Credential }

    try {
        Test-WSMan @testParams | Out-Null
        Write-Host "  [OK] WinRM connectivity verified for $TargetMachine." -ForegroundColor Green
        return [PSCustomObject]@{
            ComputerName = $TargetMachine
            Credential   = $Credential
            Connected    = $true
        }
    } catch {
        Write-Host "  [!] Connection failed to ${TargetMachine}: $($_.Exception.Message)" -ForegroundColor Red
        
        $retry = Read-Host "`n  Would you like to try with alternative credentials? (y/N)"
        if ($retry.Trim().ToLower() -eq "y") {
            $newCred = Get-Credential
            return Connect-SACTarget -ComputerName $TargetMachine -Credential $newCred
        }
    }

    return [PSCustomObject]@{
        ComputerName = $TargetMachine
        Credential   = $null
        Connected    = $false
    }
}
