---
phase: 6
title: "Verification"
status: complete
priority: P1
effort: "2h"
dependencies: [1, 2, 3, 4, 5]
---

# Phase 6: Verification

## Overview

Prove the rebrand is complete and, more importantly, prove the plugin ABI survived it.
A green build is not evidence: plugin loading fails at runtime, not at compile time.

## Requirements

- Functional: every acceptance criterion from the plan contract passes.
- Non-functional: failures are observed directly, not inferred.

## Architecture

Verification splits into three tiers, in increasing order of what they actually prove:

1. **Static** — greps and file assertions. Cheap, catches leftovers, proves nothing about behaviour.
2. **Build** — `xcodebuild` succeeds. Proves compilation only.
3. **Runtime** — app launches, all 30 plugins load, storage lands in the new location.
   This is the only tier that validates the preserved-ABI decision.

The repo's own `CLAUDE.md` documents that PluginKit ABI breakage manifests as
"Bundle failed to load executable" at load time. That is exactly the failure this phase
exists to catch.

## Related Code Files

- Read only. This phase changes nothing except fixing defects it finds.

## Implementation Steps

1. Static sweep:
   ```sh
   grep -rn '"com\.TablePro"' --include="*.swift" .
   grep -c "TablePro" TablePro/Resources/Localizable.xcstrings
   grep -rl "TablePro" --include="*.mdx" docs/
   grep -rn "api\.tablepro\.app" --include="*.swift" .
   grep -n "SUFeedURL" TablePro/Info.plist
   ```
   All must be empty / zero.
2. Preserved-reference sweep — these must still be present:
   ```sh
   grep -c "com\.TablePro\." SchemaStudio.xcodeproj/project.pbxproj   # expect 32
   grep -c "TableProApp/TablePro" scripts/download-libs.sh            # expect >0
   git diff --stat HEAD -- LICENSE                                    # expect empty
   ```
3. Clean build from scratch so no stale DerivedData masks a problem:
   ```sh
   xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio clean
   xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio \
     -configuration Debug -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build
   ```
4. ABI proof on the built product:
   ```sh
   otool -L "$APP/Contents/PlugIns/MySQLDriver.tableplugin/Contents/MacOS/MySQLDriver" | grep PluginKit
   /usr/libexec/PlistBuddy -c "Print :TableProPluginKitVersion" \
     "$APP/Contents/PlugIns/MySQLDriver.tableplugin/Contents/Info.plist"   # expect 19
   ls "$APP/Contents/PlugIns" | wc -l                                      # expect 14
   ```
5. Runtime verification — launch the app and confirm:
   - window title and About box read "SchemaStudio"
   - the connection form lists every bundled driver (proves plugins loaded)
   - creating a connection writes to `~/Library/Application Support/SchemaStudio/`
   - Console shows subsystem `com.SchemaStudio`, and plugin logs still show `com.TablePro.*`
   - no outbound request to `tablepro.app`
   - no "Check for Updates" that silently does nothing
6. Run the test suite:
   ```sh
   xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio test \
     -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
   ```
7. Lint. `swiftlint 0.65.0` and `swiftformat` are installed, so the repo's mandatory gate
   runs: `swiftlint lint --strict`. Fix violations in the changed files rather than
   suppressing them. Expect noise proportional to ~510 touched files; most changes are
   single string literals and should produce none.

## Success Criteria

- [ ] Every static assertion in step 1 returns empty
- [ ] Every preserved-reference assertion in step 2 holds
- [ ] Clean build succeeds
- [ ] `otool -L` shows `TableProPluginKit`; plugin `TableProPluginKitVersion` is 19
- [ ] 14 bundled plugins present in the app bundle and all visible in the UI
- [ ] App stores state under `~/Library/Application Support/SchemaStudio/`
- [ ] No network traffic to `tablepro.app` during a 5-minute session
- [ ] Test suite result recorded (pass, or failures listed with output)
- [ ] Lint result recorded, including "not run" if swiftlint is absent

## Risk Assessment

**Green build mistaken for success (High).** Plugin loading is a runtime concern. Step 5 is
mandatory; skipping it is how a broken plugin system ships. If any driver is missing from
the connection form, Phase 3's exclusion list was violated.

**Stale DerivedData hiding breakage (Medium).** An incremental build can link against a
previously built framework and succeed where a clean build would not. Step 3 cleans first.

**Registry-installed plugins untested (Accepted).** The 12 registry-only drivers are not
bundled and cannot be installed from upstream's registry by a renamed app. Their sources
are in `Plugins/` and can be built locally if needed. Out of scope; do not treat their
absence as a regression.

**Unverified lint across a large diff (Open).** ~510 files change. Without swiftlint, style
regressions land unchecked. This is a known, recorded gap rather than a silent one.
