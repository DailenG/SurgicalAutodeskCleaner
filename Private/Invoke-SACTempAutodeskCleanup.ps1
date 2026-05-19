function Invoke-SACTempAutodeskCleanup {
    <#
    .SYNOPSIS
        Cleans Autodesk-specific files and folders from user and system temp folders.
    .DESCRIPTION
        Searches all user Temp directories and Windows Temp for files/directories
        matching Autodesk patterns and removes them.
    #>
    $Patterns = @(
        "*adsk*",
        "*autodesk*",
        "*AdAppMgr*",
        "*AdODIS*",
        "*ODIS*",
        "*GenuineService*",
        "*Genuine Service*",
        "*AdSSO*",
        "*AcWebBrowser*",
        "*Navisworks*",
        "*Civil3D*",
        "*Civil 3D*",
        "*Revit*",
        "*AutoCAD*",
        "*Inventor*",
        "*3dsMax*",
        "*3ds Max*",
        "*Maya*",
        "*mc3_*",
        "*MC3Info*",
        "*InfraWorks*",
        "*Autodesk Forma*",
        "*AutodeskForma*",
        "*Autodesk Docs*",
        "*ACCDocs*",
        "*Autodesk Fusion*",
        "*Fusion360*",
        "*Fusion 360*",
        "*Autodesk Alias*",
        "*Autodesk Vault*",
        "*Vault*Client*",
        "*Moldflow*",
        "*Modlflow*",
        "*Netfabb*",
        "*Autodesk Construction Cloud*",
        "*BIM 360*",
        "*BIM360*"
    )

    $TempPaths = @()
    # 1. Current user/Windows temp
    if ($env:TEMP) { $TempPaths += $env:TEMP }
    $TempPaths += "C:\Windows\Temp"

    # 2. All user temp folders (resolved dynamically)
    $UserProfilesBase = "C:\Users"
    if (Test-Path $UserProfilesBase) {
        Get-ChildItem -Path $UserProfilesBase -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch "^(Public|Default|Default User|All Users)$" } |
            ForEach-Object {
                $userTemp = Join-Path $_.FullName "AppData\Local\Temp"
                if (Test-Path $userTemp) {
                    $TempPaths += $userTemp
                }
            }
    }

    $TempPaths = $TempPaths | Select-Object -Unique

    Write-SACMsg "Searching temp directories for Autodesk-related files/folders..." "Info"

    foreach ($tempPath in $TempPaths) {
        if (-not (Test-Path $tempPath)) { continue }
        
        foreach ($pattern in $Patterns) {
            Get-ChildItem -Path $tempPath -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                $item = $_
                try {
                    Remove-Item $item.FullName -Recurse -Force -ErrorAction Stop
                    Write-SACMsg "Purged temp item: $($item.FullName)" "Success"
                }
                catch {
                    Write-SACQuietLog "Skipped/Failed to delete temp item $($item.FullName): $($_.Exception.Message)"
                }
            }
        }
    }
}
