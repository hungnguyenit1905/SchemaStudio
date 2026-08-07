---
phase: 1
title: "Project and target identity"
status: pending
priority: P1
effort: "4h"
dependencies: []
---

# Phase 1: Project and target identity

## Overview

Rename the Xcode target, scheme, project file, main bundle ID, and display name so the
built product is `SchemaStudio.app`. This is the highest-risk phase and everything else
depends on the project still opening afterwards.

## Requirements

- Functional: `SchemaStudio.app` builds and launches with all bundled plugins loading.
- Non-functional: `project.pbxproj` stays valid and openable in Xcode at every commit.

## Architecture

The app binary name is not a literal. `project.pbxproj` sets:

```
PRODUCT_NAME = "$(TARGET_NAME)";          // 66 targets
INFOPLIST_KEY_CFBundleDisplayName = TablePro;
PRODUCT_BUNDLE_IDENTIFIER = com.TablePro;  // main app
```

So the product name follows the **target name**. Renaming the display string alone is not
enough; the target itself must be renamed.

### Explicitly out of scope

- Renaming the source directory `TablePro/` — every pbxproj path reference points at it;
  churn is large and the payoff is zero. Target name and folder name may differ.
- Renaming targets `TableProTests`, `TableProUITests`, `TableProMobile`.
- Any change to the 32 plugin targets or their bundle IDs.

## Related Code Files

- Modify: `TablePro.xcodeproj/project.pbxproj` (target name, display name, main bundle ID)
- Rename: `TablePro.xcodeproj` → `SchemaStudio.xcodeproj`
- Rename: `TablePro.xcodeproj/xcshareddata/xcschemes/TablePro.xcscheme` → `SchemaStudio.xcscheme`
- Modify: `TablePro/Info.plist` (only if display keys live there after inspection)

## Implementation Steps

1. Commit or stash everything first. This phase must start from a clean tree so a bad
   pbxproj edit is one `git checkout` away from recovery.
2. Record the baseline: `xcodebuild -list -project TablePro.xcodeproj > /tmp/targets-before.txt`.
3. In **Xcode UI** (not sed), rename the app target `TablePro` → `SchemaStudio`. Let Xcode
   update dependent references. Decline any offer to rename the source folder.
4. In Build Settings for the `SchemaStudio` target only, set:
   - `PRODUCT_BUNDLE_IDENTIFIER` = `com.SchemaStudio`
   - `INFOPLIST_KEY_CFBundleDisplayName` = `SchemaStudio`
5. Verify no plugin target's bundle ID changed:
   `grep -c "com\.TablePro\." project.pbxproj` must still report the original 32.
5b. **Fix `TEST_HOST`** — red team, Critical. `project.pbxproj` hardcodes the host app path
   for the test targets:
   ```
   TEST_HOST = "$(BUILT_PRODUCTS_DIR)/TablePro.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/TablePro";
   BUNDLE_LOADER = "$(TEST_HOST)";
   ```
   Renaming the app target changes the product to `SchemaStudio.app`, so this path goes
   stale and every unit/UI test fails to launch. Update both occurrences to
   `SchemaStudio.app/.../SchemaStudio`. This does **not** require renaming the test targets
   themselves, which remain `TableProTests` / `TableProUITests` per the non-goals.
6. Close Xcode. Rename the project bundle and scheme on disk:
   `git mv TablePro.xcodeproj SchemaStudio.xcodeproj` and the `.xcscheme` file inside it.
7. Diff the target list against the baseline; only the app target name may differ.
8. Build and confirm the product is `SchemaStudio.app`.

## This phase is not fully automatable

Red team, High. Step 3 specifies the Xcode GUI, which an autonomous `/ak:cook` run cannot
drive. Two consequences:

- If a human is driving, do steps 3-4 in Xcode and let the agent do the rest.
- If this must run headless, the target rename has to be a scripted `project.pbxproj` edit
  instead, which is exactly the High-risk path this phase was written to avoid. In that
  case make it a standalone commit, and treat `xcodebuild -list` plus a clean build as the
  gate before anything else proceeds.

Do not let an agent silently substitute a sed for step 3 without saying so.

## Success Criteria

- [ ] `xcodebuild -list -project SchemaStudio.xcodeproj` shows scheme `SchemaStudio`
- [ ] `grep -c "TEST_HOST.*SchemaStudio\.app" SchemaStudio.xcodeproj/project.pbxproj` > 0
- [ ] `xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio test -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO` launches the test host (tests may fail on content, but must not fail to launch)
- [ ] `xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio -configuration Debug -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED
- [ ] Built product path ends in `SchemaStudio.app`
- [ ] `grep -c "PRODUCT_BUNDLE_IDENTIFIER = \"\?com\.TablePro\." SchemaStudio.xcodeproj/project.pbxproj` still returns 32 (plugins untouched)
- [ ] `otool -L` on a bundled plugin still resolves `TableProPluginKit`
- [ ] App launches and the Connections screen lists every bundled driver

## Risk Assessment

**pbxproj corruption (High).** A malformed pbxproj makes the project unopenable and the
damage is not obvious from a diff. Mitigation: clean tree before starting, Xcode UI over
text editing, `xcodebuild -list` as the smoke test after every structural change, and a
separate commit for this phase alone.

**Silent plugin bundle ID drift (High).** Xcode's rename refactor may offer to update
identifiers across targets. Accepting that would rewrite plugin bundle IDs and break
loading at runtime, not at build time. Mitigation: step 5 count check before committing.

**`tablepro-mcp` helper (Low, needs decision).** `PRODUCT_NAME = "tablepro-mcp"` and bundle
ID `com.TablePro.tablepro-mcp` belong to an embedded helper, not a plugin. Renaming is
safe in principle but the binary name may be referenced by MCP client config. Leave it
unchanged in this phase and revisit in Phase 3 after grepping for the literal.
