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
        $activeCount = 0
        $totalCpu = 0
        $totalMemMB = 0

        foreach ($knownPid in $KnownProcs.Keys) {
            # Ensure the PID hasn't been recycled by checking CreationDate against our state
            $cimProc = $currentCimProcs[$knownPid]
            if ($null -ne $cimProc) {
                # We check for exact match or close match (within 2s) if we had to fallback to StartTime
                $expectedDate = $KnownProcs[$knownPid]
                if ($cimProc.CreationDate -eq $expectedDate -or [math]::Abs(($cimProc.CreationDate - $expectedDate).TotalSeconds) -lt 2) {
                    $activeCount++
                    
                    # Resilient: Use CIM properties for remote monitoring, Get-Process for local
                    if ($ComputerName -ne "localhost") {
                        # WMI KernelModeTime/UserModeTime are 100ns units
                        $totalCpu += ($cimProc.KernelModeTime + $cimProc.UserModeTime) / 10000000
                        $totalMemMB += ($cimProc.WorkingSetSize / 1MB)
                    } else {
                        try {
                            $p = Get-Process -Id $knownPid -ErrorAction Stop
                            $totalCpu += $p.CPU
                            $totalMemMB += ($p.WorkingSet64 / 1MB)
                        } catch {}
                    }
                }
            }
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

