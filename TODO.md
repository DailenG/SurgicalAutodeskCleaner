# Surgical Autodesk Cleaner - Roadmap & TODO

## Future Enhancements
- [x] **Implementation of "Supervisor" Process Monitoring Pattern**
    - [x] Replace blocking `Wait-Process` or basic `while` loops with a non-blocking supervisor loop.
    - [x] Monitor the entire process tree (child processes) of an uninstaller to ensure nested `msiexec` or ODIS tasks are truly finished before moving on.
    - [x] Implement live UI feedback (elapsed time, status indicators) in the primary console while child processes are running.
    - [x] Add logic to detect and potentially handle hidden modal dialogs or "zombie" processes that are no longer consuming resources but haven't exited. (Completed: Idle CPU + Static Mem detection)
- [ ] **Parallel Execution for Non-MSI Tasks**
    - Explore using `ForEach-Object -Parallel` for independent file system and registry wiping once all uninstallers have finished.
- [x] **Enhanced Logging**
    - [x] Real-time log tailing within the supervisor loop to surface uninstaller errors directly to the main console.
- [x] **Service & Lock Hardening**
    - [x] Explicitly target `AdskAccessService` and `GenuineService` (AGS) for removal.
    - [x] Implement a `PendingFileRenameOperations` queue for locked files (Reboot Deletion).
- [x] **Uninstall Safety Model** (issue #1)
    - [x] Gate Add/Remove Programs eviction on the product's Windows Installer registration instead of the uninstaller exit code.
    - [x] Treat `3010` as a reboot barrier: keep the ARP entry, stop the run, re-verify after the reboot.
    - [x] Keep `1603` failures visible and retryable in Add/Remove Programs.
    - [x] Verify runs against the installer hives directly (orphaned products, patches linked to zero products) instead of ARP.
    - [x] `SupportsShouldProcess` / `-WhatIf` on `Start-SACCleanup`, `Start-SACPurge` and `Repair-SACODIS`.
- [x] **Supervisor and Scan Hardening** (2.10.1)
    - [x] Stop sampling a dead child PID with `Get-Process -ErrorAction Stop`; sample from the CIM snapshot inside a fenced pass so a vanished child can never unwind the run.
    - [x] Write the run folder and transcript under `-WhatIf` (`-WhatIf:$false` on the log writes).
    - [x] One ODIS remnant record per folder, file text cached and quick-rejected, content libraries skipped.
    - [x] Index product/packed codes by context once for the Components/UpgradeCodes scans; ordinal product matching in `Test-SACContextTextMatch`.
    - [x] Progress output during the multi-minute Components scan.
    - [x] Name the condition that tripped the pending-reboot warning.
- [ ] **Unit Testing Improvements**
    - Increase coverage for `Get-SACTier` classification logic.
    - Add mock-based testing for registry parsing and uninstaller launch logic.
- [x] **Remote Task Firing Architecture**
    - [x] Implement a mechanism to dispatch `Start-SAC` scripts to remote endpoints via `Invoke-Command -AsJob`. (Completed: `Invoke-SACRemote`)
    - [x] Enhance `Watch-SACProcessTree` to use `Get-CimInstance -ComputerName` for remote, disconnected process tree monitoring that is resilient to VPN/network drops. (Completed)
- [ ] **Encoding & Standards Compliance**
    - Perform a project-wide encoding check to ensure all `.ps1`, `.psm1`, and `.psd1` files are saved as UTF-8 with BOM for consistent rendering of ASCII box-drawing characters across different host environments.
    - Centralize redundant helper functions (Logging, Interactive tests) to improve module maintainability. (Completed: Centralized in `Private\Invoke-SACLogger.ps1`)

