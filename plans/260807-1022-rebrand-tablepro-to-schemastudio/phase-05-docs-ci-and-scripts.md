---
phase: 5
title: "Docs CI and scripts"
status: pending
priority: P3
effort: "3h"
dependencies: [1]
---

# Phase 5: Docs CI and scripts

## Overview

Bring documentation, CI workflows, and shell scripts in line with the new name, while
leaving the two upstream references that are deliberately correct.

## Requirements

- Functional: `scripts/download-libs.sh` still fetches libraries successfully.
- Non-functional: docs build/lint cleanly if a docs toolchain is configured.

## Architecture

Three groups, and the distinction between them is the whole point of this phase:

| Group | Files | Action |
|---|---|---|
| Docs | 100 `.mdx` / `.md`, `docs/docs.json` | Rename to SchemaStudio |
| CI + scripts | 32 `.sh` / `.py` / `.yml` | Rename **selectively** |
| Artifact host references | `scripts/download-libs.sh` | **Leave unchanged** |

### What must not change

`scripts/download-libs.sh` pulls prebuilt static libraries from the
`TableProApp/TablePro` `libs-v1` GitHub release. That is an artifact host, not a brand
reference. Rewriting it breaks first-time setup for anyone cloning the fork, and the
failure is a confusing 404 rather than an obvious error.

The same applies to `scripts/publish-libs.sh` and any workflow that reads the checksum
baseline: they coordinate with upstream's release assets.

### Plugin CI is a non-goal

`.github/workflows/build-plugin.yml` contains `resolve_plugin_info()` mapping plugin target
names to tag names, and `.github/scripts/update-registry.py` maintains the upstream plugin
registry. Since plugin identity is deliberately frozen (see plan-level invariant) and this
fork does not publish to that registry, **do not rename anything in the plugin release
pipeline**. Either leave it as-is or delete it, but do not half-rename it.

### Legal files

`LICENSE` (AGPL-3.0), `CODE_OF_CONDUCT.md`, and copyright headers keep upstream's
attribution. AGPL permits the fork and the rename; it requires preserving copyright
notices and the license text. Renaming the project inside `LICENSE` would be wrong.

## Related Code Files

- Modify: `docs/**/*.mdx` (100 files), `docs/docs.json` (`"name": "TablePro"`)
- Modify: `README.md`, `README.vi.md`, `README.zh.md`, `CONTRIBUTING.md`
- Modify: `CLAUDE.md` (project overview, build commands, paths)
- Modify: `.github/workflows/build.yml`, `macos-tests.yml` (project/scheme names from Phase 1)
- Preserve: `LICENSE`, `scripts/download-libs.sh`, `scripts/publish-libs.sh`
- Decide: `.github/workflows/build-plugin.yml`, `scripts/release-all-plugins.sh`, `appcast.xml`

## Implementation Steps

1. Update `docs/docs.json` `name` and any site metadata.
2. Replace "TablePro" across `docs/**/*.mdx`. Check for links to `docs.tablepro.app` and
   `tablepro.app` — those point at upstream's live site and must be removed or repointed,
   not silently rebranded into dead links.
3. Rewrite the three READMEs. Add a short "fork of TableProApp/TablePro" attribution line:
   it is honest, and it explains the preserved `TableProPluginKit` naming to future readers.
4. Update `CLAUDE.md` for the new project name, scheme, and the plugin-ABI invariant that
   this rebrand deliberately preserves.
5. Update CI workflows that reference `TablePro.xcodeproj` / scheme `TablePro` to the Phase 1
   names. Do not touch the plugin release workflow.
6. Decide `appcast.xml`: delete it, since Phase 2 disables Sparkle and a stale appcast
   advertising upstream versions is misleading.
7. Assert the preserved references survived.

## Success Criteria

- [ ] `grep -rl "TablePro" --include="*.mdx" docs/` → empty
- [ ] `grep -rn "tablepro\.app" docs/` → empty or intentionally repointed
- [ ] `grep -c "TableProApp/TablePro" scripts/download-libs.sh` → unchanged
- [ ] `scripts/download-libs.sh --force` still downloads and passes checksum verification
- [ ] `LICENSE` byte-identical to before the rebrand
- [ ] READMEs state the fork relationship and the preserved PluginKit naming
- [ ] CI workflow files reference `SchemaStudio.xcodeproj` and scheme `SchemaStudio`

## Risk Assessment

**Rewriting the artifact host URL (Medium).** Breaks setup for every fresh clone with a
misleading 404. Mitigation: the explicit success-criteria assertion, and never running a
repo-wide sed across `scripts/`.

**Half-renamed plugin pipeline (Medium).** Renaming some identifiers in
`build-plugin.yml` while the registry script and tag conventions keep the old ones produces
a pipeline that fails only when someone tries to release a plugin — months later.
Mitigation: all-or-nothing, and the recommendation is "leave as-is".

**Dead documentation links (Low).** `docs.tablepro.app` will keep serving upstream's docs.
Rebranding the link text while the URL still points upstream is worse than removing it.
