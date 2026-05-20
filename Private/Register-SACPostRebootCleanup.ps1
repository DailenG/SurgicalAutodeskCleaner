function Register-SACPostRebootCleanup {
    <#
    .SYNOPSIS
        Saves locked files/directories to a JSON file and schedules a silent post-reboot cleanup task.
    .DESCRIPTION
        Saves the list of locked items to C:\ProgramData\SurgicalAutodeskCleaner\pending_deletions.json,
        writes a self-contained self-elevating script to perform the cleanup, and registers it to run
        on the next logon of the current user via the RunOnce registry key.
    .PARAMETER Paths
        The list of file or directory paths that were locked or failed to delete.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $CleanFolder = Join-Path $env:ProgramData "SurgicalAutodeskCleaner"
    if (-not (Test-Path $CleanFolder)) {
        New-Item -ItemType Directory -Path $CleanFolder -Force | Out-Null
    }

    $JsonPath = Join-Path $CleanFolder "pending_deletions.json"
    $ScriptPath = Join-Path $CleanFolder "post_reboot_cleanup.ps1"

    # Save locked items to JSON
    $Paths | ConvertTo-Json | Out-File -FilePath $JsonPath -Encoding utf8 -Force

    # Write self-contained cleanup script
    $ScriptContent = @'
# Self-elevate to Administrator context if not already elevated
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process powershell.exe -ArgumentList "-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

$Folder = Split-Path $PSCommandPath -Parent
$JsonPath = Join-Path $Folder "pending_deletions.json"
$LogDir = Join-Path $Folder "Logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogPath = Join-Path $LogDir "PostRebootPurge_$Timestamp.log"

$logContent = [System.Collections.Generic.List[string]]::new()
$logContent.Add("==========================================================")
$logContent.Add("SURGICAL AUTODESK CLEANER - POST-REBOOT CLEANUP LOG")
$logContent.Add("Timestamp: $(Get-Date)")
$logContent.Add("==========================================================")
$logContent.Add("")

if (-not (Test-Path $JsonPath)) {
    $logContent.Add("[!] Error: pending_deletions.json not found at $JsonPath")
    $logContent.ToArray() | Out-File -FilePath $LogPath -Encoding utf8 -Force
    Start-Process notepad.exe -ArgumentList $LogPath
    Exit
}

try {
    $rawJson = Get-Content -Raw -Path $JsonPath -ErrorAction Stop
    $Paths = $rawJson | ConvertFrom-Json
} catch {
    $logContent.Add("[!] Error parsing pending_deletions.json: $($_.Exception.Message)")
    $logContent.ToArray() | Out-File -FilePath $LogPath -Encoding utf8 -Force
    Start-Process notepad.exe -ArgumentList $LogPath
    Exit
}

if (-not $Paths -or $Paths.Count -eq 0) {
    $logContent.Add("[*] No items found in pending_deletions.json.")
} else {
    $logContent.Add("[*] Found $($Paths.Count) item(s) to remove.")
    $logContent.Add("")

    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            $isDir = (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue).PSIsContainer
            $typeStr = if ($isDir) { "Directory" } else { "File" }
            $logContent.Add("[-] Attempting to delete ($typeStr): $path")
            try {
                if ($isDir) {
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                } else {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
                if (-not (Test-Path -LiteralPath $path)) {
                    $logContent.Add("    [OK] Deleted successfully.")
                } else {
                    # Fallback to cmd force deletion
                    if ($isDir) {
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q /s `"$path\*`" >nul 2>&1" -Wait -NoNewWindow
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c rmdir /s /q `"$path`" >nul 2>&1" -Wait -NoNewWindow
                    } else {
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c del /f /a /q `"$path`" >nul 2>&1" -Wait -NoNewWindow
                    }
                    if (-not (Test-Path -LiteralPath $path)) {
                        $logContent.Add("    [OK] Deleted successfully (via cmd fallback).")
                    } else {
                        $logContent.Add("    [FAIL] Item is still present on disk.")
                    }
                }
            } catch {
                $logContent.Add("    [FAIL] Exception: $($_.Exception.Message)")
            }
        } else {
            $logContent.Add("[?] Not found (already removed): $path")
        }
        $logContent.Add("")
    }
}

$logContent.Add("==========================================================")
$logContent.Add("Cleanup completed at $(Get-Date)")
$logContent.Add("==========================================================")
$logContent.ToArray() | Out-File -FilePath $LogPath -Encoding utf8 -Force

# Clean up json file
Remove-Item -LiteralPath $JsonPath -Force -ErrorAction SilentlyContinue

# Launch log in Notepad
Start-Process notepad.exe -ArgumentList $LogPath

# Remove self asynchronously to avoid lock
Start-Process cmd.exe -ArgumentList "/c ping 127.0.0.1 -n 3 >nul & del `"$PSCommandPath`"" -WindowStyle Hidden
'@

    $ScriptContent | Out-File -FilePath $ScriptPath -Encoding utf8 -Force

    # Register RunOnce key for current user login
    $RunOnceKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    $RunOnceValueName = "SurgicalAutodeskCleanerPostReboot"
    $RunOnceCommand = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    
    try {
        Set-ItemProperty -Path $RunOnceKey -Name $RunOnceValueName -Value $RunOnceCommand -Type String -Force -ErrorAction Stop
        Write-SACQuietLog "Post-reboot cleanup script registered in HKCU RunOnce."
        return $true
    } catch {
        Write-SACQuietLog "Failed to register RunOnce key: $($_.Exception.Message)"
        return $false
    }
}
