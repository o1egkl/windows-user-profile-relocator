# Windows User Profile Relocator

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://microsoft.com/powershell)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server-lightgrey.svg)](https://microsoft.com/windows)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A battle-tested, fail-safe PowerShell toolkit designed to relocate Windows user libraries (`Downloads`, `Documents`, `Desktop`, `Pictures`, `Music`, `Videos`) and heavy `AppData` directories from an overfilled system drive (`C:`) to a secondary drive (e.g. `D:`), with complete rollback capabilities.

---

## 💡 Why This Tool?

### The Problem
Moving the entire `%USERPROFILE%` or root `%LOCALAPPDATA%` via Windows Registry hacks or unsupported methods frequently breaks:
* Windows Store and UWP / MSIX applications
* Windows Search, Start Menu indexing, and Cortana
* Windows Updates and Feature Upgrades
* Antivirus scanners and security descriptors

### The Solution: Selective NTFS Junctions
**Windows User Profile Relocator** uses native **NTFS directory junctions** (`mklink /J`) combined with **Robocopy mirroring** and atomic switchovers:
1. System-critical components (`AppData\Local\Microsoft`, `AppData\Local\Packages`, etc.) remain intact on `C:`.
2. Heavy third-party app folders (Chrome/Edge caches, Discord, Telegram, IDEs, etc.) and user libraries are moved to `D:`, transparently redirected via filesystem-level junctions.
3. Windows and all applications continue to see the standard paths on `C:\Users\...` without knowing the data physically resides on `D:`.

---

## ✨ Features

- 🛡️ **Zero Data Loss Guarantee**: Files are copied using `robocopy` with ACL, owner, and timestamp retention (`/COPY:DATSO /DCOPY:DAT`). Before anything is removed or switched, `robocopy /L` confirms bit-for-bit sync.
- 🔄 **Atomic Cutover & Rollback on Error**: Folders are renamed to `<name>.migrated_old` before creating junctions. If junction creation or verification fails, the original folder is immediately restored.
- 🧪 **Safe Simulation Mode (`-DryRun`)**: Inspect the execution plan, preview directory sizes, and verify available disk space without making any changes.
- 💾 **Pre-Flight Disk Checks**: Verifies that destination drives are NTFS, ready, and have enough free space (with an enforced 10% safety margin).
- ☁️ **OneDrive Protection**: Detects and skips libraries redirected to OneDrive to prevent sync loops or remote file deletion.
- 📋 **Automatic Registry Backup & Reset**: Exports `User Shell Folders` to a timestamped `.reg` file in `%ProgramData%\ProfileMigration\` before any registry modification.
- ↩️ **Full Rollback Support**: `Rollback-UserToDriveC.ps1` safely removes junctions, moves data back to `C:`, and resets `User Shell Folders` back to default `%USERPROFILE%\...`.
- 📝 **Detailed Auditing & Logs**: Transcripts and robocopy outputs are written to `%ProgramData%\ProfileMigration\`.

---

## 📂 What Gets Relocated?

| Category | Directories Included | Exclusions / Handling |
| :--- | :--- | :--- |
| **User Libraries** | `Downloads`, `Documents`, `Videos`, `Pictures`, `Music`, `Desktop` | Skipped if managed by OneDrive |
| **AppData\Local** | Third-party app caches & storage (browsers, IDEs, chat clients, tools) | **Excluded:** `Microsoft`, `Packages`, `Temp`, `CrashDumps`, `Application Data`, `History` |
| **AppData\Roaming** | Non-system roaming data | **Excluded:** `Microsoft`, `Application Data`, `SystemCertificates`, `Protect` |

*(Use `-SkipAppData` if you only want to migrate User Libraries and leave AppData completely untouched).*

---

## 🚀 Quick Start

### Prerequisites
* Windows 10, Windows 11, or Windows Server
* PowerShell 5.1 or PowerShell 7+
* Administrator privileges (**Run as Administrator**)
* Source and destination partitions formatted with **NTFS**

---

### 1. Migrate Profile to Drive D:

```powershell
# Step 1: Open PowerShell as Administrator
# Step 2: Run a dry run to inspect the plan and required disk space
.\Migrate-UserToDriveD.ps1 -DryRun

# Step 3: Run the actual migration (keeps backup of originals on C: as *.migrated_old)
.\Migrate-UserToDriveD.ps1 -KeepOldCopy

# Or run the standard migration (removes originals after successful verification)
.\Migrate-UserToDriveD.ps1
```

#### Parameters for `Migrate-UserToDriveD.ps1`:
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-DestRoot` | `D:\Users` | Destination directory root. |
| `-DryRun` | `False` | Simulates actions, displays disk calculation and plan without modifying anything. |
| `-SkipAppData` | `False` | Skips `AppData\Local` and `AppData\Roaming` (moves libraries only). |
| `-KeepOldCopy` | `False` | Leaves original folders on `C:` as `<name>.migrated_old` instead of deleting them. |
| `-NoExplorerRestart`| `False` | Prevents restarting `explorer.exe` at the end of the script. |
| `-Yes` | `False` | Suppresses confirmation prompts (ideal for automated setups). |

---

### 2. Rollback Profile to Drive C:

If you ever want to revert everything back to `C:`, run `Rollback-UserToDriveC.ps1`:

```powershell
# Step 1: Preview rollback actions in dry-run mode
.\Rollback-UserToDriveC.ps1 -DryRun

# Step 2: Safely return folders back to C: and reset registry
.\Rollback-UserToDriveC.ps1 -KeepOldCopy
```

#### Parameters for `Rollback-UserToDriveC.ps1`:
| Parameter | Default | Description |
| :--- | :--- | :--- |
| `-DestRoot` | `D:\Users` | Root where profile was migrated to. |
| `-DryRun` | `False` | Simulates rollback plan without touching files or registry. |
| `-SkipAppData` | `False` | Skips returning `AppData` (rolls back libraries only). |
| `-KeepOldCopy` | `False` | Renames folders on `D:` to `<name>.rollback_old` instead of deleting them. |
| `-NoExplorerRestart`| `False` | Prevents restarting `explorer.exe` at the end of the script. |
| `-Yes` | `False` | Suppresses confirmation prompts. |

---

## 🔒 Safety Architecture

```
[Start Migration]
       │
       ▼
[Check Admin & NTFS & Free Space (Need + 10%)]
       │
       ▼
[Robocopy with /COPY:DATSO /DCOPY:DAT] ──(Fails)──> [Abort: Original C: untouched]
       │
       ▼
[Robocopy /L Verification (Bit-for-Bit Sync)] ──(Mismatch)──> [Abort: Original C: untouched]
       │
       ▼
[Rename original to <name>.migrated_old]
       │
       ▼
[Create NTFS Junction: C:\... -> D:\...]
       │
       ├─(Junction Failed)─> [Rename <name>.migrated_old back to original, abort]
       │
       ▼
[Delete or Keep <name>.migrated_old (-KeepOldCopy)]
       │
       ▼
[Backup Registry to .reg & Update User Shell Folders]
       │
       ▼
[Restart explorer.exe & Done]
```

---

## 📁 Logs & Diagnostics

All session transcripts, registry backups, and robocopy logs are automatically saved in:
```
%ProgramData%\ProfileMigration\
├── Migrate_YYYYMMDD_HHMMSS.log
├── Migrate_YYYYMMDD_HHMMSS_robocopy.log
├── UserShellFolders_before_YYYYMMDD_HHMMSS.reg
└── Rollback_YYYYMMDD_HHMMSS.log
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
