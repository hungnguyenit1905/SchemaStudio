---
phase: 3
title: "Rename storage identity"
status: pending
priority: P2
effort: "4h"
dependencies: [1]
---

# Phase 3: Rename storage identity

## Overview

Rename the identifiers the app uses for logging and on-disk state: OSLog subsystem,
Keychain service, UserDefaults keys, and the Application Support directory. Data loss is
accepted, so no migration code is written.

This is the phase where a careless `sed` breaks plugin loading.

## Requirements

- Functional: app stores state under a SchemaStudio identity; all 30 plugins still resolve.
- Non-functional: no migration code, no compatibility shim (repo rule: no backward-compat shims).

## Architecture

Four identifier families, all currently rooted at `com.TablePro` or `"TablePro"`:

| Family | Count | Example |
|---|---|---|
| OSLog subsystem | 338 files | `Logger(subsystem: "com.TablePro", category: …)` |
| Keychain service | 1 | `KeychainHelper.swift:39` `private let service = "com.TablePro"` |
| UserDefaults keys | ~110 of 147 literals | `"com.TablePro.tags"`, `"com.TablePro.favoriteTables"` |
| App Support directory | 16 files | `appSupport.appendingPathComponent("TablePro")` |

### The exclusion list — read before writing any sed

147 distinct `com.TablePro.*` literals exist in Swift. **32 are plugin bundle IDs that must
not change.** Five of those are hardcoded in Swift and will be caught by a naive replace:

```
com.TablePro.BeancountDriver
com.TablePro.CassandraDriver
com.TablePro.OracleDriver
com.TablePro.PostgreSQLDriver
com.TablePro.RedisDriver
```

Plugin driver subsystems are also legitimately `com.TablePro.*` and belong to the plugin,
not the app:

```
Logger(subsystem: "com.TablePro.PostgreSQLDriver", …)   // 3 occurrences
Logger(subsystem: "com.TablePro.RedisDriver", …)        // 2
Logger(subsystem: "com.TablePro.CassandraDriver", …)    // 2
```

Decide once and apply consistently: **plugin-owned identifiers keep the `com.TablePro`
prefix**, matching the bundle IDs they belong to. Only app-owned identifiers move to
`com.SchemaStudio`.

### A symlink makes `Packages/` unsafe to sed — red team, Critical

`Packages/TableProCore/Sources/TableProPluginKit` is **a symlink**, not a directory:

```
TableProPluginKit -> ../../../Plugins/TableProPluginKit
```

Any recursive replacement rooted at `Packages/` (or at the repo root without an exclusion)
therefore edits the frozen PluginKit framework source through the link, breaking the one
invariant this whole plan is built to protect. `CLAUDE.md` already warns that
`Plugins/TableProPluginKit/` is the single source of truth and the SwiftPM path is a
symlink to it.

**Every replacement command in this phase must exclude the PluginKit source**, for example
`--exclude-dir=TableProPluginKit`, and the exclusion must be verified rather than assumed:
`git status --porcelain Plugins/TableProPluginKit/` must stay empty for the whole phase.

### Safe replacement strategy

Replace the exact app-only string `"com.TablePro"` (fully quoted, no trailing dot) first —
that covers the 338 OSLog subsystems and the Keychain service in one mechanical pass with
zero risk of touching `com.TablePro.<Plugin>`. Then handle dotted keys individually,
skipping anything on the exclusion list.

## Related Code Files

- Modify: `TablePro/Core/Storage/KeychainHelper.swift` (service constant)
- Modify: ~338 `.swift` files (subsystem literal only)
- Modify: 16 `.swift` files under `TablePro/Core/Storage/` and `TablePro/Core/MCP/`
  (App Support directory)
- Modify: `TablePro/Core/Storage/*.swift` (UserDefaults key literals)
- Do NOT modify: any `com.TablePro.<PluginName>` literal

## Implementation Steps

1. Snapshot the plugin ID list so drift is detectable:
   `grep -oE "PRODUCT_BUNDLE_IDENTIFIER = \"?com\.TablePro\.[A-Za-z0-9]+" SchemaStudio.xcodeproj/project.pbxproj | sort -u > /tmp/plugin-ids-before.txt`
2. Replace the exact quoted literal `"com.TablePro"` → `"com.SchemaStudio"` across `.swift`.
   This is safe because the plugin IDs always carry a trailing `.` before the driver name.
3. Rebuild. A green build here proves nothing about plugins yet — continue.
4. Enumerate remaining dotted literals and subtract the exclusion list:
   `grep -rhoE '"com\.TablePro\.[a-zA-Z0-9.]+"' --include="*.swift" . | sort -u`
5. Rename only app-owned dotted keys. Leave every `com.TablePro.<Driver>` untouched.
6. Replace the App Support directory literal `"TablePro"` → `"SchemaStudio"` in the 16 files.
   Confirm each is genuinely a directory component, not a display string.
7. Decide the `tablepro-mcp` helper left over from Phase 1: grep for the literal
   `tablepro-mcp` and rename only if nothing external depends on the binary name.
8. Re-run the plugin ID snapshot and diff against step 1. Any difference is a bug.
9. **Migration flags — red team, High.** Four UserDefaults keys are one-way migration
   latches:
   ```
   TabDiskActor.swift:63          com.TablePro.tabStateMigrationComplete
   ColumnLayoutPersister.swift:21 com.TablePro.columnLayoutSchemaScopeMigrationComplete
   ConnectionStorage.swift:20     com.TablePro.connectionsMigratedToFile
   FilterSettingsStorage.swift:84 com.TablePro.filterStateMigrationComplete
   ```
   Renaming them resets every latch to "not migrated", so on first launch each migration
   path runs again against legacy data that no longer exists at the new location. Read all
   four migration routines and confirm each is a no-op on absent input before shipping.
   A migration that assumes its source exists is a first-launch crash.
10. Confirm `TablePro/Core/Plugins/Registry/RegistryClient.swift:96`
   (`Bundle.main.bundleIdentifier ?? "com.TablePro"`) still behaves sensibly. It reports the
   host app identity to the plugin registry; after Phase 1 the real bundle ID is
   `com.SchemaStudio`, so the fallback literal is dead code. Renaming it is harmless;
   leaving a stale `com.TablePro` fallback is misleading.

## Success Criteria

- [ ] `grep -rn '"com\.TablePro"' --include="*.swift" .` → empty
- [ ] `grep -c "com\.TablePro\." SchemaStudio.xcodeproj/project.pbxproj` unchanged at 32
- [ ] `diff /tmp/plugin-ids-before.txt` against a fresh snapshot → identical
- [ ] The 5 excluded driver IDs still present in Swift
- [ ] Build succeeds; app launches; **all 30 plugins load** (this is the real test)
- [ ] App writes to `~/Library/Application Support/SchemaStudio/` on first run
- [ ] `otool -L` on a built plugin still resolves `TableProPluginKit`
- [ ] `git status --porcelain Plugins/TableProPluginKit/` empty (symlink never written through)
- [ ] All four migration routines confirmed no-op on absent legacy data
- [ ] First launch on a clean user account does not crash

## Risk Assessment

**Blanket sed breaks plugin resolution (High).** The failure is silent at build time and
appears at runtime as missing drivers or "Bundle failed to load executable". Mitigation:
the two-stage replacement in steps 2 and 5, plus the before/after snapshot in steps 1 and 8.

**Plugin-owned subsystems renamed by accident (Medium).** `com.TablePro.PostgreSQLDriver`
as an OSLog subsystem looks like an app string but belongs to the plugin. The step-2
strategy of matching the exact quoted `"com.TablePro"` avoids it structurally.

**Orphaned Keychain entries (Low, hygiene).** Renaming the Keychain service leaves every
previously saved database password in the login keychain under service `com.TablePro`,
unreferenced and undeleted. Nothing breaks, but real credentials linger indefinitely. If
this machine ever held real connections, delete them manually via Keychain Access.

**App Support literal is not always a path (Low).** `"TablePro"` also appears as a display
title, for example `InitializeHandler.swift:57` sends `"title": .string("TablePro")` over
MCP. Step 6 requires inspecting each of the 16 sites rather than replacing blind; the MCP
title belongs to Phase 4.
