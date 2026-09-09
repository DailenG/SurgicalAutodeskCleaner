function Watch-SACProcessTree {
    <#
    .SYNOPSIS
        Monitors a process and its entire descendant process tree until all processes have exited.
    .DESCRIPTION
        Acts as a "Supervisor" for uninstallation tasks. It tracks a root Process ID and recursively
        finds all child processes. It monitors the aggregate CPU and Memory usage of the entire tree.
        Includes safeguards against PID recycling and enforces hard/idle timeouts.
    .PARAMETER RootPID
        The Process ID of the root process to monitor.
    .PARAMETER DisplayName
        A friendly name for the process being monitored, used in UI feedback.
    .PARAMETER TimeoutMinutes
        The maximum total time (in minutes) the process tree is allowed to run before being force-killed.
    .PARAMETER IdleTimeoutMinutes
        The maximum time (in minutes) the aggregate CPU time can remain unchanged before the tree is considered hung and force-killed.
    #>
    [CmdletBinding(DefaultParameterSetName="ProcessObject")]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="ProcessObject")]
        [System.Diagnostics.Process]$RootProcess,

        [Parameter(Mandatory=$true, ParameterSetName="ProcessID")]
        [int]$RootPID,
        
        [string]$DisplayName = "Process",
        [int]$TimeoutMinutes = 20,
        [int]$IdleTimeoutMinutes = 5,
        [string]$TailLogFile = $null,

        [string]$ComputerName = "localhost"
    )

    $StartTime = Get-Date
    $ZeroCpuTime = $null
    $LastTotalCpu = $null
    $LastTotalMem = $null
    $StaticActivityTime = $null
    
    # We maintain a stateful dictionary of known processes: [int] PID -> CreationDate
    # This completely eliminates PID recycling vulnerabilities.
    $KnownProcs = @{}
    
    if ($PSCmdlet.ParameterSetName -eq "ProcessObject") {
        $RootPID = [int]$RootProcess.Id
    } else {
        $RootPID = [int]$RootPID
    }

    $CimSession = if ($ComputerName -ne "localhost") { 
        $opt = New-CimSessionOption -Protocol Dcom -ConnectTimeoutMs 5000
        New-CimSession -ComputerName $ComputerName -SessionOption $opt -ErrorAction SilentlyContinue 
    } else { $null }
    
    try {
        $cimParams = @{ Classname = "Win32_Process"; Filter = "ProcessId = $RootPID"; ErrorAction = "Stop" }
        if ($CimSession) { $cimParams["CimSession"] = $CimSession }
        
        $rootCim = Get-CimInstance @cimParams
        if ($rootCim) { 
            $KnownProcs[[int]$rootCim.ProcessId] = $rootCim.CreationDate 
        }
    } catch {
        # If it exited before we could grab CIM info, we try to use the StartTime from the process object
        # as a fallback for PID recycling defense.
        if ($PSCmdlet.ParameterSetName -eq "ProcessObject") {
            try { $KnownProcs[[int]$RootPID] = $RootProcess.StartTime } catch { $KnownProcs[[int]$RootPID] = $StartTime }
        } else {
            $KnownProcs[[int]$RootPID] = $StartTime
        }
    }

    # Helper function to update the known process tree
    function Update-KnownTree {
        param($Session, $Computer)
        
        $cimParams = @{ Classname = "Win32_Process"; ErrorAction = "SilentlyContinue" }
        if ($Session) { $cimParams["CimSession"] = $Session }
        elseif ($Computer -ne "localhost") { $cimParams["ComputerName"] = $Computer }

        $allProcs = Get-CimInstance @cimParams
        if (-not $allProcs) { return $null }

        # Build a quick lookup dictionary for this loop
        $currentProcs = @{ "TotalCount" = $allProcs.Count }
        foreach ($p in $allProcs) {
            $currentProcs[[int]$p.ProcessId] = $p
        }

        $addedNew = $true
        while ($addedNew) {
            $addedNew = $false
            foreach ($p in $allProcs) {
                $processId = [int]$p.ProcessId
                $parentId = [int]$p.ParentProcessId
                # If this process is NOT known, but its parent IS known...
                if (-not $KnownProcs.ContainsKey($processId) -and $KnownProcs.ContainsKey($parentId)) {
                    $parentCreationTime = $KnownProcs[$parentId]
                    # PID Recycling Defense: The child must be created at or after the parent's creation time.
                    # Note: We allow a 2-second margin for potential clock skew or StartTime vs CreationDate deltas.
                    if ($p.CreationDate -ge $parentCreationTime.AddSeconds(-2)) {
                        $KnownProcs[$processId] = $p.CreationDate
                        $addedNew = $true
                    }
                }
            }
        }
        return $currentProcs
    }

    $isRemote = ($ComputerName -ne "localhost") -or (Test-SACRemoteSession)

    Write-Host "`n  Monitoring process tree for $DisplayName..." -ForegroundColor Cyan
    Write-SACQuietLog "Supervisor started for $DisplayName (RootPID: $RootPID, Target: $ComputerName)"

    $busyDots = ""
    while ($true) {
        $elapsed = (Get-Date) - $StartTime

        # Update our stateful tree with any new descendants
        $currentCimProcs = Update-KnownTree -Session $CimSession -Computer $ComputerName
        
        # Resilient Monitoring: Handle connection drops
        if ($null -eq $currentCimProcs -and $ComputerName -ne "localhost") {
            Write-Host "`n  [!] Connection lost to $ComputerName. Retrying..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
            if ($CimSession) { $CimSession | Remove-CimSession; $CimSession = New-CimSession -ComputerName $ComputerName -ErrorAction SilentlyContinue }
            continue
        }

        # 1. Check Hard Timeout
        if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
            Write-SACQuietLog "Supervisor Hard Timeout ($TimeoutMinutes m) reached for $DisplayName. Killing tree."
            Write-Host "`n  [!] Hard timeout ($TimeoutMinutes m) reached for $DisplayName. Terminating tree." -ForegroundColor Red
            foreach ($pidToKill in $KnownProcs.Keys) {
                if ($ComputerName -ne "localhost") {
                    Invoke-CimMethod -Query "SELECT * FROM Win32_Process WHERE ProcessId = $pidToKill" -MethodName Terminate -ErrorAction SilentlyContinue
                } else {
                    try { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
            break
        }

        # 2. Evaluate active processes from our known list
        # A child PID vanishing between the CIM snapshot and the sample is the normal
        # success condition for a supervisor, never an error, so the whole sampling pass
        # is fenced and CPU/memory come from the snapshot already in hand. Get-Process
        # is deliberately not used here: -ErrorAction Stop on a dead PID raises a
        # terminating error that unwinds the entire run, not just the supervisor.
        $activeCount = 0
        $totalCpu = 0
        $totalMemMB = 0

        try {
            foreach ($knownPid in $KnownProcs.Keys) {
                # Ensure the PID hasn't been recycled by checking CreationDate against our state
                $cimProc = $currentCimProcs[$knownPid]
                if ($null -eq $cimProc) { continue }

                # We check for exact match or close match (within 2s) if we had to fallback to StartTime
                $expectedDate = $KnownProcs[$knownPid]
                if ($cimProc.CreationDate -ne $expectedDate -and [math]::Abs(($cimProc.CreationDate - $expectedDate).TotalSeconds) -ge 2) { continue }

                $activeCount++
                # WMI KernelModeTime/UserModeTime are 100ns units
                $totalCpu += ($cimProc.KernelModeTime + $cimProc.UserModeTime) / 10000000
                $totalMemMB += ($cimProc.WorkingSetSize / 1MB)
            }
        } catch {
            Write-SACQuietLog "Supervisor sample failed for $DisplayName (ignored): $($_.Exception.Message)"
        }

        # Root logic: The root process must be truly dead 
        # (Using CIM check if remote or if monitored by PID, otherwise .NET object)
        $rootIsDead = if ($ComputerName -ne "localhost" -or $PSCmdlet.ParameterSetName -eq "ProcessID") {
            $rootAlive = $null -ne $currentCimProcs -and $currentCimProcs.ContainsKey($RootPID)
            if ($rootAlive) {
                $expectedDate = $KnownProcs[$RootPID]
                $rootAlive = ($currentCimProcs[$RootPID].CreationDate -eq $expectedDate -or [math]::Abs(($currentCimProcs[$RootPID].CreationDate - $expectedDate).TotalSeconds) -lt 2)
            }
            -not $rootAlive
        } else {
            try {
                $RootProcess.Refresh()
                $RootProcess.HasExited
            } catch { 
                Write-SACQuietLog "Supervisor failed to refresh RootProcess object for $DisplayName. Assuming dead."
                $true 
            }
        }

        # Final exit condition: Root is dead AND no active descendants found
        if ($rootIsDead -and $activeCount -eq 0) {
            Write-SACQuietLog "Supervisor exit condition met for $DisplayName (Root is dead, descendants: 0)"
            Write-Host "`n  [*] Process tree for $DisplayName has exited cleanly." -ForegroundColor Green
            break
        }

        # Safety fallback: If root is dead and we've seen 0 active procs for 3 seconds, 
        # and CIM successfully returned a process list, assume we're done.
        if ($rootIsDead -and $activeCount -eq 0 -and $elapsed.TotalSeconds -gt 3 -and $null -ne $currentCimProcs) {
             Write-SACQuietLog "Supervisor Safety Fallback met for $DisplayName (Root dead, active: 0, elapsed: $($elapsed.TotalSeconds)s)"
             Write-Host "`n  [*] No active descendants found for $DisplayName. Monitor closing." -ForegroundColor Green
             break
        }

        Write-SACQuietLog "Supervisor status for ${DisplayName}: RootDead=$rootIsDead, Active=$activeCount, CPU=$totalCpu, Mem=$totalMemMB"

        # 3. Enhanced Zombie Detection (Idle CPU + Static Memory)
        # If an uninstaller hangs on a hidden dialog, CPU usage is 0 and WorkingSet is usually static.
        $isIdle = ($null -ne $LastTotalCpu -and $totalCpu -eq $LastTotalCpu)
        $isStaticMem = ($null -ne $LastTotalMem -and [math]::Abs($totalMemMB - $LastTotalMem) -lt 0.1)

        if ($isIdle -and $isStaticMem) {
            if ($null -eq $StaticActivityTime) { $StaticActivityTime = Get-Date }
            elseif (((Get-Date) - $StaticActivityTime).TotalMinutes -ge $IdleTimeoutMinutes) {
                Write-Host "`n  [!] Zombie process detected (Idle CPU/Static Mem for $IdleTimeoutMinutes m) for $DisplayName. Terminating tree." -ForegroundColor Yellow
                foreach ($pidToKill in $KnownProcs.Keys) {
                    if ($ComputerName -ne "localhost") {
                         Invoke-CimMethod -Query "SELECT * FROM Win32_Process WHERE ProcessId = $pidToKill" -MethodName Terminate -ErrorAction SilentlyContinue
                    } else {
                         try { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
                break
            }
        } else {
            $StaticActivityTime = $null
            $LastTotalCpu = $totalCpu
            $LastTotalMem = $totalMemMB
        }

        # 4. UI Feedback
        if (-not $isRemote) {
            $statusLine = ""
            if ($activeCount -gt 0) {
                # Standard tree monitoring view
                $tailPart = ""
                if (-not [string]::IsNullOrWhiteSpace($TailLogFile) -and (Test-Path $TailLogFile)) {
                    try {
                        $stream = New-Object System.IO.FileStream($TailLogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        $reader = New-Object System.IO.StreamReader($stream)
                        if ($stream.Length -gt 2048) { $stream.Seek(-2048, [System.IO.SeekOrigin]::End) | Out-Null }
                        $lines = $reader.ReadToEnd() -split "`n"
                        $lastLine = ($lines | Where-Object { $_.Trim() -ne "" })[-1]
                        if ($lastLine) {
                            $tailStr = $lastLine.Trim()
                            if ($tailStr.Length -gt 60) { $tailStr = $tailStr.Substring(0, 57) + "..." }
                            $tailPart = " | Tail: $tailStr"
                        }
                        $reader.Close()
                        $stream.Close()
                    } catch {}
                }

                $elapsedStr = "{0:mm\:ss}" -f $elapsed
                $memStr = [math]::Round($totalMemMB, 1)
                $statusLine = "    [Elapsed: $elapsedStr] | [Active Procs: $activeCount] | [Tree Mem: ${memStr}MB]$tailPart"
            } else {
                # 'Busy' animation while waiting for discovery or for children to spawn
                if ($busyDots.Length -ge 10) { $busyDots = "" } else { $busyDots += "." }
                $statusLine = "    Initializing process tree discovery$busyDots"
            }
            
            $statusLine = $statusLine.PadRight(130)
            Write-Host "`r$statusLine" -NoNewline -ForegroundColor DarkGray
        }

        Start-Sleep -Milliseconds 1500
    }
    
    if (-not $isRemote) { Write-Host "" } # Newline cleanup
    if ($CimSession) { $CimSession | Remove-CimSession }
}


# SIG # Begin signature block
# MII9OQYJKoZIhvcNAQcCoII9KjCCPSYCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBf6oDG5JFyv6L3
# /0WoMn+0TtTddCMUAhwVzvFYcJgc5KCCIfwwggXMMIIDtKADAgECAhBUmNLR1FsZ
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
# iuGjH2TdaC1ZOmBXiCRKJLj4DT2uhJ04ji+tHD6n58vhavFIrmcxghqTMIIajwIB
# ATBxMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBBT0MgQ0EgMDMC
# EzMABiB0TAioxsL2jdQAAAAGIHQwDQYJYIZIAWUDBAIBBQCgXjAQBgorBgEEAYI3
# AgEMMQIwADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAvBgkqhkiG9w0BCQQx
# IgQgKsZNAfKX2Mv3RaRuF0XXHzSWcEzy3FjFKExDuXIaEugwDQYJKoZIhvcNAQEB
# BQAEggGAs/+9Uyhe1ObkJqqMIAcqF9aXF39AdGHkC5sJXLDqWMfuP54QHrqNDUbd
# Mks4J5VFY2CYtgxrm8ESCUlun6VhmYGpZIklM7XmgknWfVTh1rAnHlzdW4HzKMCW
# 0wYpLPcao2vzkxGOn9dcXMrMU06On9M/g+nfVnxMmPA0tRBA3484fNcn0zOoFUQP
# gYl91/SXHnE5kvLFoFVsZ2A6zd2ux2hGZsLPPqoDoWEqbTS/BnD7DRDZ29b1hFeJ
# e+B83tUuIGEq27buJT2jSssf4ok3MWlQ9MFb17OBpo1TiHkE+P0OZ4wdyRqafElI
# DWCsjgeh7MJnZTWH4hbSGo+jX8b4IQ97L9l07Jy464Cfdlk47FpQOgxQB8vERGPz
# s3VN/MSfW7gM41ba7TGt81d7nm4QeKxyfJcq3CuiQstpg8fH7HJtUEzfSUU9LwhM
# YZG4zX9/kPZCuQzAZ3O/bDfjEG4sLYI9MJYu4UHlaFyhUqpwvn13FbSo01oZHNhx
# 7Pj05KovoYIYEzCCGA8GCisGAQQBgjcDAwExghf/MIIX+wYJKoZIhvcNAQcCoIIX
# 7DCCF+gCAQMxDzANBglghkgBZQMEAgEFADCCAWEGCyqGSIb3DQEJEAEEoIIBUASC
# AUwwggFIAgEBBgorBgEEAYRZCgMBMDEwDQYJYIZIAWUDBAIBBQAEIFMrQQekkrPH
# +uajDwb+0584QJHtONcL5Bq5pSY2ZSuAAgZqhEkHjUoYEjIwMjYwOTA5MTQzODE4
# Ljg5WjAEgAIB9KCB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOkE1MDAtMDVFMC1EOTQ3MTUwMwYDVQQD
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
# bBh7pmgAXVswggeXMIIFf6ADAgECAhMzAAAAVn6PnVgIjulgAAAAAABWMA0GCSqG
# SIb3DQEBDAUAMGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFt
# cGluZyBDQSAyMDIwMB4XDTI1MTAyMzIwNDY1MVoXDTI2MTAyMjIwNDY1MVowgdsx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1p
# Y3Jvc29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNT
# IEVTTjpBNTAwLTA1RTAtRDk0NzE1MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBS
# U0EgVGltZSBTdGFtcGluZyBBdXRob3JpdHkwggIiMA0GCSqGSIb3DQEBAQUAA4IC
# DwAwggIKAoICAQC0pZ+b+6XTbv93xGVvwyf+DRBS+8upjZWzLe0jxTa0VKylNmiZ
# k4PcEdPwuRH5GuEwmBvVWMAoU3Kxor1wtJeJ88ZIgGs8KCz0/jLbiWskSatXpDnP
# gGaoyEg+tmES9mdakJLgc7uNhJ6L+fGYLv/USv6XkuDc+ZLFvx3YhVwBHFLDUHib
# EHpcjSeR6X3BrV1hvbB8amh+toWbFk7FP142G3gsfREFJW55trpk2mNL/SC1+buq
# IiLI/qno9HNNNsydWqwedX93+tbTMfH5D5A1nnBSoqZNkkH2FTznf7alfmsN8rfa
# 41j39YE4CbNuqCkR1CRuIxq9QzJQNKGbJwi+Ad1CdLbTuxOPwz6Qkve051qE+4+o
# zCxoIKB1/DBDHQ71Mp7sVK9sARizUCeV0KX8ocZkI5W9Q2qPIvXQkt7T/4YP3/Ke
# pcZYWlc6Nq6e9n9wpE6GM3gzl7rHHRvaaKpw+KLj+KLZmF4pqWUkRPsIqWkVKGzf
# DKDoX9+iNDFC8+dtYPg3LHqWGNaPCagtzHrDUVIK1q8sKXLfcEtFKVNTiopTFprx
# 3tg3sSqmf1c7RJjS6Y68oVetYfuvGX72JqJyK12dNOSwCdGO96R0pPeWDuVEx+Z9
# lTy9c2I3RRgnNP0SOqNGbS43+HShfE+E189ip4VvI9cYbHNphTPrPHepNwIDAQAB
# o4IByzCCAccwHQYDVR0OBBYEFL62M/K7q1n+HkazIu/LPUf4U0haMB8GA1UdIwQY
# MBaAFGtpKDo1L0hjQM972K9J6T7ZPdshMGwGA1UdHwRlMGMwYaBfoF2GW2h0dHA6
# Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMFB1Ymxp
# YyUyMFJTQSUyMFRpbWVzdGFtcGluZyUyMENBJTIwMjAyMC5jcmwweQYIKwYBBQUH
# AQEEbTBrMGkGCCsGAQUFBzAChl1odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtp
# b3BzL2NlcnRzL01pY3Jvc29mdCUyMFB1YmxpYyUyMFJTQSUyMFRpbWVzdGFtcGlu
# ZyUyMENBJTIwMjAyMC5jcnQwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggr
# BgEFBQcDCDAOBgNVHQ8BAf8EBAMCB4AwZgYDVR0gBF8wXTBRBgwrBgEEAYI3TIN9
# AQEwQTA/BggrBgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9Eb2NzL1JlcG9zaXRvcnkuaHRtMAgGBmeBDAEEAjANBgkqhkiG9w0BAQwFAAOC
# AgEADgOoBcSw7bqP8trsWCf9CJ+K3zG5l6Spnnv5h76wf+FFNsQSMZitmCyrBH+V
# RR8oIWltkXyaxpk9Ak5HhhhQRTxfKMuufxjWMJKajGH2Xu1aJKhz8kUHDfnokCbM
# YbF4EDYRZLFG5OvUC5l7qdho3z/C0WSIdyzyAxp3FcGzoPFWHK7lieEs9CR+6Yqb
# eUV+3ATumJ5Xt/WWySaWCwLoB5IYLMY9lSAK9wflO/9B73PtsgiZIPdK7OE4jBo/
# 54pBNh/rtOJ/IkqRZBJ0Z9MDopy7jWTwsHqg8r4wuTWNvHErnA+otIvrbGMrThIF
# ccQlISewW3TPFaTE/+WB6PUPGpSeatgR2TG/MpIcgCoVZJm6X/mEj68nG8U+Gw1A
# ESThxK6UOQlClx1WL+CZ/+YcU5iEMGOxrXmzgv7awGKXddX9PxGJHrpDzFi9MtFb
# F3Z1Wys6gLCexThYh6ILQmKcK/VYscSHtDLOv1FKviQoktZ2k1guGCOSiNOYSQCM
# U7vvi3fEHt6du8gXQY6xXX3GcJTOr0QYrK3SAy5qmEqU2Mn5pOmNYxkMaj4Y4qye
# n3ceZ+2aXRLKncX34zfL7LpYkZRmghkmrbbuMOOMSd22lSuH0F091Uh9UkP8C7zV
# HOHTlQcCK+itDc6zw8QsciCI531NbNt2CYbNwgu3911VARExggdGMIIHQgIBATB4
# MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAy
# MDIwAhMzAAAAVn6PnVgIjulgAAAAAABWMA0GCWCGSAFlAwQCAQUAoIIEnzARBgsq
# hkiG9w0BCRACDzECBQAwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqG
# SIb3DQEJBTEPFw0yNjA5MDkxNDM4MThaMC8GCSqGSIb3DQEJBDEiBCC/QvcVj7u2
# NQHAgnJrevfNim8hnbIHSi0s+dQ1CEK3CTCBuQYLKoZIhvcNAQkQAi8xgakwgaYw
# gaMwgaAEILYMMyVNpOPwlXeJODleel7gJIfrTXjdn5f2jk0GAwyoMHwwZaRjMGEx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAyMDIw
# AhMzAAAAVn6PnVgIjulgAAAAAABWMIIDYQYLKoZIhvcNAQkQAhIxggNQMIIDTKGC
# A0gwggNEMIICLAIBATCCAQmhgeGkgd4wgdsxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jvc29mdCBBbWVyaWNhIE9wZXJh
# dGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjpBNTAwLTA1RTAtRDk0NzE1
# MDMGA1UEAxMsTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZSBTdGFtcGluZyBBdXRo
# b3JpdHmiIwoBATAHBgUrDgMCGgMVAP9z9ykVKpBZgF5eCDJEnZlu9gQRoGcwZaRj
# MGExCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWVzdGFtcGluZyBDQSAy
# MDIwMA0GCSqGSIb3DQEBCwUAAgUA7kvIXTAiGA8yMDI2MDkwOTExNTgyMVoYDzIw
# MjYwOTEwMTE1ODIxWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDuS8hdAgEAMAoC
# AQACAgcnAgH/MAcCAQACAhKLMAoCBQDuTRndAgEAMDYGCisGAQQBhFkKBAIxKDAm
# MAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJKoZIhvcN
# AQELBQADggEBAE9RFQCtGv94tffrNmJhdavuY/Pc4+KcFoCnKN/WQ9MXkMyJo4BL
# flifX64hOULc3zyhUSaJlptuyFhW92oGKmzKR288axHW7DZMUDNczmbbTQZ8mbcJ
# IPZhqsakTxWHEyYh7kfNE1N55EmNSfVxM+8c8nNl8NJb/eYoXiBupR/dd7ghamK8
# cQYH41H3JGrJkEmGVzuslbhzm0ktLQ+sJA1nJ8mkFuF5Y0l67gLLSvt6bZOtNABs
# aTxKQmyce50Tt9bTZq52r/EPuYlmcMJqGitASl9GSSSb6JvV+JbE2ykroIs7BIPX
# ouXC7lbufXOZOEJC6fBd/1eha7IIBZZkxN0wDQYJKoZIhvcNAQEBBQAEggIAqJZZ
# 4wQjfwbFAVFuWMCjlcidpcjAqrRrYQiLl4V6AJC02n0wuWCurrj7GVxvFMESaVJs
# 60gtSJNDmqS5cbYG9BoZ8oTUR0eO4+QZEufbYhCC9g9il6WClFHkWRjBl1QWPh8D
# oWq+EsiUewonqDwVHn1CnnX2Gwnnf84bSnWtgskWD2yxVpr/Dj2Lh6zmM9bqCG77
# GOyHSCMgMhdR0fuscnDT/PNy01kz2wUWl2pXOj7rrdCq8F1jkqmV2+N6nnoSCyKH
# FAgsjQuuqi0kOaU4/+OX9aDlhkaSbfr4vgLQknt1BucvNz6n3UPuFgb8P+K5JkhQ
# vYKU1UYvoXveYaCIH9ahTXPC/yzHNOMSBoeJV1KxJWk7RNxq7Xn6mIe8CDc3rRV3
# UHWuHgNKhC1c3F9Qzd0LomdZa+CQhpUM3ru1TTukiOMuEchYTH4halywhbRc9c4l
# dQOFz9x5bWB7NF2mIz1uuoUX65NdPqlKt6pZF82ySCp7s/GRfswiiMqOuux5MECO
# gZUmWS9wbpeOYNjuI+wFJD/ZJumkn2ND3WlAvpnVjKYnX9keXUTLVlilvnE3WCsk
# KZde47o+xLzBVCHTEPMvvkQEAX1bV0QARLPe0y2pj7qbhhB53MwZnp7oiz6EqS3j
# LNLTddrvnH6GOOJHXO0jhuNbAEa8gzFRpIPdlZQ=
# SIG # End signature block
