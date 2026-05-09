# Surgical Autodesk Cleaner

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![PowerShell Gallery Version](https://img.shields.io/powershellgallery/v/SurgicalAutodeskCleaner.svg)](https://www.powershellgallery.com/packages/SurgicalAutodeskCleaner)
[![DeepWiki](https://img.shields.io/badge/Docs-DeepWiki-blue)](https://deepwiki.com/DailenG/SurgicalAutodeskCleaner)

A powerful, highly targeted, enterprise-grade PowerShell module designed to surgically remove technical debt from CAD/BIM workstations by cleanly uninstalling legacy Autodesk products. 

Published and maintained by **Dailen**.

## Why this module?

Autodesk products often leave behind deeply nested registry keys, orphaned background services, and fragmented shared dependencies. Scorched-earth uninstallation scripts often break global licensing (FlexNet/ODIS) for *other* software on the machine.

**Surgical Autodesk Cleaner** takes a different approach:
- **Targeted Removal:** Uninstalls specific applications for specific years without touching shared services.
- **Fail-Safe Mechanism:** Verifies the vendor and product names against strict patterns, preventing accidental removal of non-Autodesk tools.
- **Deep Cleansing:** Purges orphaned installation directories and handles cyclical registry keys using native OS methods to prevent StackOverflow exceptions.

---

## Installation

You can install the module directly from the PowerShell Gallery:

```powershell
Install-Module -Name SurgicalAutodeskCleaner -Scope CurrentUser -Force
```

## Functions

This module exports three primary functions for different deployment scenarios:

### 1. `Start-SACInteractive`
The easiest way to use the tool manually. Run this command with no parameters to launch an interactive, dynamic menu.
- Pre-scans the registry for installed Autodesk components.
- Allows you to select one, multiple, or **ALL** target years found on the system.
- Allows you to select one, multiple, or **ALL** products matching those years.
- Hands the execution off to `Start-SACCleanup`.

```powershell
Start-SACInteractive
```

### 2. `Start-SACCleanup`
The surgical strike weapon. Designed for RMM deployment (like N-Central) or background execution. 

```powershell
# Scenario: Silently target a specific cluster of products for a defined range of older years
Start-SACCleanup -TargetProducts "AutoCAD", "Civil 3D" -TargetYears 2018, 2019, 2020

#### Parameters:
- `-TargetProducts`: Array of strings. The script implicitly uses wildcards (e.g., `"Revit"` becomes `*Revit*`).
- `-TargetYears`: Array of integers to target specific release versions.
- `-AnyVendor`: A switch to bypass the "Autodesk" vendor failsafe. 
- `-AdditionalVendors`: Array of strings to expand the failsafe (e.g., `-AdditionalVendors "MyPluginCorp"`).

### 3. `Start-SACPurge`
The scorched-earth tool. When a machine is completely "bricked" due to a corrupt Autodesk installation, this function hard-kills services, disables scheduled tasks, removes ODIS/Licensing components, purges SQL Server LocalDB instances, and recursively wipes the registry hive.

```powershell
# WARNING: This will terminate all Autodesk applications and remove them forcefully
Start-SACPurge
```

---

## Documentation & DeepWiki References

For extensive documentation regarding enterprise deployment strategies, logging architecture, and error code resolution, please refer to our internal DeepWiki:

**[DeepWiki - Surgical Autodesk Cleaner Implementation Guide](https://deepwiki.com/DailenG/SurgicalAutodeskCleaner)**

---

## License & Copyright

Copyright (c) 2026 Dailen. All rights reserved.

Licensed under the MIT License. See [LICENSE](LICENSE) for more details.
