# Surgical Autodesk Cleaner

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/SurgicalAutodeskCleaner.svg)](https://www.powershellgallery.com/packages/SurgicalAutodeskCleaner)
[![DeepWiki](https://img.shields.io/badge/Docs-DeepWiki-blue)](https://deepwiki.com/DailenG/SurgicalAutodeskCleaner)

A powerful, highly targeted, enterprise-grade PowerShell module designed to surgically remove technical debt from CAD/BIM workstations by cleanly uninstalling legacy Autodesk products — and resetting user profile data and licensing when things go sideways.

Published and maintained by **Dailen**.

---

## Screenshots

### Main Menu
![Main Menu](https://github.com/user-attachments/assets/010ebfc8-1d1b-4241-94b9-607086cb164e)

### Product List Selection
![Product List Selection](https://github.com/user-attachments/assets/337bbcba-81c5-4f56-ac56-cbff1a5d661b)

### Year List Selection
![Year List Selection](https://github.com/user-attachments/assets/8b0e5397-8747-4706-98a3-8e0ccda7aee9)

---

## Why this module?

Autodesk products often leave behind deeply nested registry keys, orphaned background services, and fragmented shared dependencies. Scorched-earth uninstallation scripts often break global licensing (FlexNet/ODIS) for *other* software on the machine.

**Surgical Autodesk Cleaner** takes a different approach:
- **Targeted Removal:** Uninstalls specific applications for specific years without touching shared services.
- **Fail-Safe Mechanism:** Verifies vendor and product names against strict patterns to prevent accidental removal of non-Autodesk tools.
- **Deep Cleansing:** Purges orphaned installation directories and handles cyclical registry keys using native OS methods to prevent StackOverflow exceptions.
- **Robust Pathing:** Automatically detects and utilizes $env:TEMP if C:\temp is unavailable, ensuring deployment reliability on locked-down systems.
- **Profile & Licensing Utilities:** Resets per-user AppData and Autodesk licensing tokens to resolve post-install issues without a full reinstall.
- **Non-Destructive by Default:** Roaming profile data is renamed with a timestamped backup suffix rather than deleted, so user customizations can be restored.
- **Smart Logging:** Dual-channel logging with a dedicated "Attention Items" summary file that surfaces critical failures for easy review.
- **PowerShell Core Optimized:** While fully compatible with PowerShell 5.1, the **Interactive Mode (TUI)** is best experienced in **PowerShell 7+**.

---

## Requirements

- **Operating System:** Windows 10/11 or Windows Server 2016+
- **PowerShell Version:** 5.1 or **7.0+ (Recommended for TUI)**
- **Permissions:** Administrative privileges are required for registry and service manipulation.

---

## Installation

```powershell
Install-Module -Name SurgicalAutodeskCleaner -Scope CurrentUser -Force
```

---

## Quick Start

```powershell
# Launch the full interactive menu (recommended for manual use)
Start-SAC

# Surgical cleanup via RMM/headless — no prompts
Start-SACCleanup -TargetProducts "AutoCAD", "Revit" -TargetYears 2020, 2021 -Silent

# Reset a user's Autodesk profile data after a bad upgrade
Reset-SACUserProfile -TargetProducts "AutoCAD" -TargetYears 2022

# Wipe licensing tokens to force re-authentication
Reset-SACLicensing -Silent
```

---

## Functions

### 1. `Start-SACInteractive` *(Alias: `Start-SAC`)*

The interactive entry point. Launches a full-screen TUI main menu that surfaces all SAC tools in one place. Automatically scans the registry and displays detected Autodesk products in the header.

Supports **Out-ConsoleGridView** (PowerShell 7+) for multi-select with automatic install of `Microsoft.PowerShell.ConsoleGuiTools` if not present. Falls back to a native text-based menu if running headless or in a limited console.

```powershell
Start-SAC
```

**Menu options:**
| Option | Action |
|--------|--------|
| `[1]` Surgical Cleanup | Targeted uninstall by product + year |
| `[2]` Master Purge | Scorched-earth full system removal |
| `[3]` Reset User Profile | Rename/clear per-user AppData & registry |
| `[4]` Reset Licensing | Wipe CLM, token cache & FlexNet stubs |
| `[5]` Pre-Flight Scan | Simulate cleanup and export CSV report |
| `[6]` Restore User Profile | List and restore SAC backup folders |
| `[V]` View Attention Items | Open failure logs in Notepad (Conditional) |

---

### 2. `Start-SACCleanup`

The surgical strike engine. Designed for RMM deployment (N-Central, ConnectWise Automate, Intune) or silent background execution. Uninstalls only the specified products and years, leaving shared services and newer installations intact.

```powershell
# Remove AutoCAD and Civil 3D 2019/2020 silently
Start-SACCleanup -TargetProducts "AutoCAD", "Civil 3D" -TargetYears 2019, 2020 -Silent

# Remove all Revit versions found (default year range 2015-2023)
Start-SACCleanup -TargetProducts "Revit"
```

**Parameters:**
| Parameter | Type | Description |
|---|---|---|
| `-TargetProducts` | `string[]` | Product name substrings to target. Wildcards are implicit (`"AutoCAD"` → `*AutoCAD*`). |
| `-TargetYears` | `int[]` | Release years to target. Defaults to `2015..2023`. |
| `-Silent` | `switch` | Bypasses the interactive confirmation prompt. Required for RMM execution. |
| `-AnyVendor` | `switch` | Bypasses the Autodesk vendor failsafe. Use with care. |
| `-AdditionalVendors` | `string[]` | Expands the vendor allowlist (e.g., `-AdditionalVendors "MyPluginCorp"`). |

---

### 3. `Start-SACPurge`

The scorched-earth tool. When a machine is completely bricked by a corrupt Autodesk installation, this function hard-kills services, disables all Autodesk scheduled tasks, removes ODIS/Licensing components, purges SQL Server LocalDB instances, and recursively wipes the full Autodesk registry hive using `reg.exe` (bypasses PowerShell's StackOverflow limitation on deep recursive keys).

> ⚠️ **This is irreversible.** Use only when targeted cleanup is not an option.

```powershell
Start-SACPurge -Silent
```

**Parameters:**
| Parameter | Type | Description |
|---|---|---|
| `-Silent` | `switch` | Bypasses the interactive confirmation prompt. |
| `-AnyVendor` | `switch` | Bypasses the Autodesk vendor failsafe. |
| `-AdditionalVendors` | `string[]` | Expands the vendor allowlist. |

---

### 4. `Start-SACScan`

A non-destructive pre-flight tool. Scans the machine for what `Start-SACCleanup` *would* remove and exports a detailed CSV to the desktop. No changes are made to the system.

```powershell
Start-SACScan
```

The exported CSV includes: Action type, Component type, Target product, Target year, Display name, and the full uninstall string or path.

---

### 5. `Reset-SACUserProfile`

Resets per-user Autodesk application data to give a user a clean start — without destroying their custom work.

**Default behavior:**
- `AppData\Roaming\Autodesk\<Product>\<Year>` → **Renamed** with a `_SAC_BACKUP_<timestamp>` suffix (preserves `.cuix` layouts, plot styles, templates)
- `AppData\Local\Autodesk\<Product>\<Year>` → **Deleted** outright (pure cache and crash logs)
- `HKU:\<SID>\Software\Autodesk\<Product>` → **Removed** (window positions, recent file paths)

```powershell
# Reset all profiles for AutoCAD 2020 across all users
Reset-SACUserProfile -TargetProducts "AutoCAD" -TargetYears 2020

# Reset for a specific user, delete Roaming instead of renaming
Reset-SACUserProfile -TargetUser "jsmith" -DeleteRoaming -Silent
```

**Parameters:**
| Parameter | Type | Description |
|---|---|---|
| `-TargetProducts` | `string[]` | Products to target. Defaults to all Autodesk products found. |
| `-TargetYears` | `int[]` | Years to target. Defaults to all years found. |
| `-TargetUser` | `string` | Specific username. Defaults to all local profiles. |
| `-DeleteRoaming` | `switch` | Delete Roaming folders instead of renaming. **Destroys customizations.** |
| `-SkipRegistry` | `switch` | Skip clearing HKCU/HKU Autodesk registry keys. |
| `-Silent` | `switch` | Bypasses the confirmation prompt. |

---

### 6. `Reset-SACLicensing`

Wipes all Autodesk licensing tokens and forces a clean re-authentication on next launch. Resolves common issues like "Autodesk keeps asking for activation," "License not found," and stuck multi-seat reservations.

**What it clears:**
- `C:\ProgramData\Autodesk\CLM\` — Central Licensing Manager data
- `C:\ProgramData\Autodesk\AdskLicensing\` — ODIS licensing service state
- `C:\Users\*\AppData\Roaming\Autodesk\CLM\` — Per-user license token cache
- `C:\Users\*\AppData\Local\Autodesk\Web Services\` — SSO/Autodesk Account JWT tokens
- `C:\ProgramData\FLEXnet\adsk*` *(optional)* — FlexNet seat reservation stubs

The `AdskLicensing` service is stopped before the wipe and restarted afterward.

```powershell
# Standard licensing reset
Reset-SACLicensing

# Include FlexNet Autodesk stubs, silent
Reset-SACLicensing -IncludeFlexNet -Silent
```

**Parameters:**
| Parameter | Type | Description |
|---|---|---|
| `-IncludeFlexNet` | `switch` | Also removes `adsk*` files from `C:\ProgramData\FLEXnet\`. Off by default since FLEXnet is shared. |
| `-SkipServiceRestart` | `switch` | Do not restart `AdskLicensing` after the wipe. |
| `-Silent` | `switch` | Bypasses the confirmation prompt. |

---

### 7. `Restore-SACUserProfile`

Lists, restores, or purges the `_SAC_BACKUP_<timestamp>` folders created by `Reset-SACUserProfile`.

```powershell
# List all backups on the machine
Restore-SACUserProfile

# Restore a specific backup
Restore-SACUserProfile -Restore -BackupPath "C:\Users\jsmith\AppData\Roaming\Autodesk\AutoCAD 2020_SAC_BACKUP_20250509_143000"

# Remove all backups to free disk space
Restore-SACUserProfile -Purge -Silent
```

---

## Logging

All functions write dual-channel logs to `C:\temp\` (falling back to `$env:TEMP` if unavailable):
- **Transcript log** — Standard console output captured via `Start-Transcript`
- **Debug log** — Background IO exceptions and verbose details written silently to prevent console noise
- **Attention Items** — A targeted log of critical failures, viewable directly from the interactive menu

Log directories are timestamped per-run (e.g., `...\AutodeskCleanup_20260510_183022\`).

---

## Documentation & DeepWiki

For extensive documentation on enterprise deployment strategies, logging architecture, and error code resolution:

**[DeepWiki — Surgical Autodesk Cleaner](https://deepwiki.com/DailenG/SurgicalAutodeskCleaner)**

---

## License & Copyright

Copyright (c) 2026 Dailen. All rights reserved.

Licensed under the MIT License. See [LICENSE](LICENSE) for more details.
