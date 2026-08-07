---
title: "Rebrand TablePro to SchemaStudio"
description: "Hard fork rebrand: product identity becomes SchemaStudio while the TableProPluginKit ABI stays untouched so all 30 plugins keep loading."
status: pending
priority: P1
effort: "2-3d"
tags: [rebrand, fork, macos, xcode]
created: 2026-08-07
branch: rebrand/schemastudio
---

# Rebrand TablePro to SchemaStudio

## Overview

`SchemaStudio/` is a downstream mirror of `TableProApp/TablePro` (40/40 recent commits
authored upstream, none local). This plan converts it into an independently branded
product named SchemaStudio.

Scope C was chosen in brainstorm: rename the **product identity**, deliberately keep the
**plugin ABI**. Upstream sync is abandoned (hard fork). No data migration is written
because there is no real user data yet.

## Decisions already settled (do not reopen)

| Decision | Value |
|---|---|
| Upstream sync | Abandoned. Hard fork. |
| Scope | C: identity renamed, plugin ABI preserved |
| Keychain / UserDefaults / App Support migration | None. Data loss accepted. |
| CloudKit | Disabled, not re-created |
| Signing | Unsigned Debug (`CODE_SIGNING_ALLOWED=NO`); team `D7HJ5TFYCU` unavailable |

## The one invariant that governs every phase

Every plugin binary hard-links the framework by name:

```
@rpath/TableProPluginKit.framework/Versions/A/TableProPluginKit
```

Verified with `otool -L` on the built `MySQLDriver.tableplugin`.

**Therefore these must survive the rebrand unchanged:**

- framework name `TableProPluginKit`
- Info.plist key `TableProPluginKitVersion` (currently `19`)
- all 32 plugin bundle IDs `com.TablePro.<Name>`

This is **intentional technical debt**, recorded here so a future reader does not
"finish the job" and break all 30 plugins.

### The trap this creates

The `com.TablePro.*` namespace is **overloaded**. It holds both:

- storage keys that SHOULD be renamed (`com.TablePro.tags`, `com.TablePro.favoriteTables`, …)
- plugin bundle IDs that MUST NOT be (`com.TablePro.RedisDriver`, …)

147 distinct `com.TablePro.*` literals exist in Swift; 32 are plugin bundle IDs; **5 overlap
exactly** and are hardcoded in Swift:

```
com.TablePro.BeancountDriver
com.TablePro.CassandraDriver
com.TablePro.OracleDriver
com.TablePro.PostgreSQLDriver
com.TablePro.RedisDriver
```

A blanket `sed 's/com\.TablePro/com.SchemaStudio/g'` breaks plugin resolution.
Phase 3 handles this with an explicit exclusion list.

### Second trap: the PluginKit source is reachable through a symlink

```
Packages/TableProCore/Sources/TableProPluginKit -> ../../../Plugins/TableProPluginKit
```

A recursive replacement rooted at the repo or at `Packages/` edits the frozen framework
**through the link**. Every bulk command in this plan must exclude `TableProPluginKit`, and
`git status --porcelain Plugins/TableProPluginKit/` must stay empty throughout.

## Goals

| # | Goal | Priority |
|---|------|----------|
| 1 | App builds and runs as SchemaStudio with all 30 plugins loading | P1 |
| 2 | No network call or auto-update reaches upstream TablePro infrastructure | P1 |
| 3 | Storage identity renamed without touching plugin bundle IDs | P2 |
| 4 | No user-visible "TablePro" text remains, translations preserved | P2 |
| 5 | Docs, CI, and scripts consistent with the new name | P3 |

## Phases

| # | Phase | Status | Depends on |
|---|-------|--------|-----------|
| 1 | [Project and target identity](./phase-01-start.md) | Pending | — |
| 2 | [Cut upstream network links](./phase-02-cut-upstream-network-links.md) | Pending | — |
| 3 | [Rename storage identity](./phase-03-rename-storage-identity.md) | Pending | 1 |
| 4 | [User facing strings](./phase-04-user-facing-strings.md) | Pending | 1 |
| 5 | [Docs CI and scripts](./phase-05-docs-ci-and-scripts.md) | Pending | 1 |
| 6 | [Verification](./phase-06-verification.md) | Pending | 1-5 |

Phases 2-5 are independent of each other. Each ends with a green build.

## Measured scope

| Surface | Count | Nature |
|---|---|---|
| OSLog subsystem in `.swift` | 338 files | one-line, mechanical |
| `com.TablePro.*` literals in `.swift` | 147 distinct | **needs exclusion list** |
| App Support dir `"TablePro"` | 16 files | one-line |
| `Localizable.xcstrings` | 236 hits | **must not sed, keys are translation keys** |
| Docs `.mdx` / `.md` | 100 files | text |
| `.plist` / `.entitlements` | 37 files | bundle ID, SUFeedURL, display name |
| `.sh` / `.py` / `.yml` | 32 files | **must not touch download-libs.sh upstream URL** |
| `project.pbxproj` | 1 file | highest risk |

## Success Criteria

- [ ] `xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio -configuration Debug -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED
- [ ] App launches; About box and window title read "SchemaStudio"
- [ ] All 14 bundled plugins load (Connections screen lists every driver)
- [ ] `otool -L` on a built plugin still shows `TableProPluginKit` (ABI intact)
- [ ] `grep -r "tablepro.app\|TableProApp/TablePro" TablePro/ --include="*.swift" --include="*.plist"` → only `download-libs.sh` style artifact hosts remain, no runtime endpoint
- [ ] `grep -rl "TablePro" --include="*.mdx" docs/` → empty
- [ ] `LICENSE` unchanged, AGPL-3.0 copyright notices intact

## Known risks

| Risk | Severity | Mitigation |
|---|---|---|
| `project.pbxproj` corrupted by sed | High | Backup + commit before touching; prefer Xcode UI; verify with `xcodebuild -list` |
| Blanket sed breaks plugin IDs | High | Explicit 5-entry exclusion list, Phase 3 |
| `xcstrings` key rename collides or drops entries | Medium | Keys and nested values renamed in one scripted JSON pass; key count asserted. Translations are **not** lost — see Phase 4 |
| `download-libs.sh` URL rewritten | Medium | Explicitly out of scope, asserted in Phase 5 |
| Sparkle still points upstream | High | Phase 2, disable rather than repoint |

## Red Team Review

Four adversarial lenses run 2026-08-07 (security, assumptions, failure modes, scope).
8 findings raised, 7 accepted and applied, 1 escalated to the user as a scope decision.

| # | Severity | Finding | Evidence | Disposition |
|---|---|---|---|---|
| 1 | Critical | `TEST_HOST` hardcodes `TablePro.app`; renaming the target breaks every test | `project.pbxproj` `TEST_HOST` / `BUNDLE_LOADER` | Accepted → Phase 1 step 5b |
| 2 | Critical | PluginKit source reachable via symlink; bulk sed edits the frozen framework | `Packages/TableProCore/Sources/TableProPluginKit -> ../../../Plugins/TableProPluginKit` | Accepted → Phase 3 + plan invariant |
| 3 | High | Licensing stub is a product decision, not a refactor; must not stub as licensed | `LinkedFoldersSection.swift:16,37,41` | Accepted → Phase 2 step 4 |
| 4 | High | Phase 1 depends on the Xcode GUI, so an autonomous cook run cannot execute it | `phase-01` step 3 | Accepted → Phase 1 "not fully automatable" |
| 5 | High | Renaming migration latches re-runs 4 migrations against absent legacy data | `TabDiskActor.swift:63`, `ColumnLayoutPersister.swift:21`, `ConnectionStorage.swift:20`, `FilterSettingsStorage.swift:84` | Accepted → Phase 3 step 9 |
| 6 | Medium | Stale `com.TablePro` fallback for host app identity sent to plugin registry | `RegistryClient.swift:96` | Accepted → Phase 3 step 10 |
| 7 | Low | Old DB passwords linger in Keychain under the abandoned service name | `KeychainHelper.swift:39` | Accepted → Phase 3 risks |
| 8 | Medium | YAGNI: renaming ~110 UserDefaults keys has no user-visible benefit but carries the plugin-ID collision risk | `phase-03`, 5 known collisions | **Escalated — user decision pending** |

### Whole-Plan Consistency Sweep

Re-read `plan.md` and all six phase files after applying findings.

- Phase 1 success criteria now include the `TEST_HOST` assertion, consistent with Phase 6 step 6 running the test suite.
- Phase 3 exclusion strategy and the plan-level invariant now both name the symlink.
- The earlier claim that renaming xcstrings keys loses translations was corrected in both `plan.md` risks and Phase 4; no stale copy remains.
- No unresolved contradictions.

## Environment notes

- `swiftlint 0.65.0` and `swiftformat` installed 2026-08-07; the repo's mandatory
  `swiftlint lint --strict` gate can run in Phase 6.
- Signing unavailable for team `D7HJ5TFYCU`; all builds and verification run unsigned.
- The 12 registry-only plugins cannot be exercised: a renamed app cannot install from
  upstream's registry. Their sources are in `Plugins/` if they are ever needed.

<!-- slug: rebrand-tablepro-to-schemastudio -->
