function Connect-SACTarget {
    <#
    .SYNOPSIS
        Tests and establishes a connection to a remote target for SAC operations.
    #>
    param(
        [string]$ComputerName,
        [System.Management.Automation.PSCredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName) -or $ComputerName -eq "localhost" -or $ComputerName -eq $env:COMPUTERNAME) {
        return [PSCustomObject]@{
            ComputerName = "localhost"
            Credential   = $null
            Connected    = $true
        }
    }

    Write-Host "`n  Testing WinRM connection to $ComputerName..." -ForegroundColor Cyan
    
    $testParams = @{
        ComputerName = $ComputerName
        ErrorAction  = "Stop"
    }
    if ($Credential) { $testParams["Credential"] = $Credential }

    try {
        Test-WSMan @testParams | Out-Null
        Write-Host "  [OK] WinRM connectivity verified." -ForegroundColor Green
        return [PSCustomObject]@{
            ComputerName = $ComputerName
            Credential   = $Credential
            Connected    = $true
        }
    } catch {
        Write-Host "  [!] Connection failed: $($_.Exception.Message)" -ForegroundColor Red
        
        $retry = Read-Host "`n  Would you like to try with alternative credentials? (y/N)"
        if ($retry.Trim().ToLower() -eq "y") {
            $newCred = Get-Credential
            return Connect-SACTarget -ComputerName $ComputerName -Credential $newCred
        }
    }

    return [PSCustomObject]@{
        ComputerName = $ComputerName
        Credential   = $null
        Connected    = $false
    }
}
