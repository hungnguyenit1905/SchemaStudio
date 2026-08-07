---
phase: 4
title: "User facing strings"
status: pending
priority: P2
effort: "3h"
dependencies: [1]
---

# Phase 4: User facing strings

## Overview

Replace every "TablePro" a user can read: the strings catalog, Swift literals that are not
localized, and the MCP server identity. Translations must survive.

## Requirements

- Functional: no user-visible "TablePro" text in any of the 5 shipped languages.
- Non-functional: existing tr / vi / zh-Hans / zh-Hant translations stay attached to their entries.

## Architecture

`TablePro/Resources/Localizable.xcstrings` holds **3515 keys**. Of those:

- **44 keys** contain "TablePro" — and in a strings catalog the key *is* the English source
  string, e.g. `"About TablePro"`, `"A newer TablePro is required to load this plugin."`
- **177 localization values** contain "TablePro", across `en`, `tr`, `vi`, `zh-Hans`, `zh-Hant`

### Why the translations are recoverable

The initial brainstorm assumed renaming a key orphans its translations. Inspecting the file
shows that is only true if the key and its values are edited separately, or if Xcode
regenerates the catalog. Each entry is a JSON object keyed by the source string, with all
localizations nested inside it:

```json
"About TablePro": {
  "localizations": {
    "vi": { "stringUnit": { "value": "Giới thiệu TablePro" } },
    "zh-Hans": { "stringUnit": { "value": "关于 TablePro" } }
  }
}
```

Renaming the key **and** rewriting the nested values in the same scripted pass keeps every
translation intact. "TablePro" is a proper noun carried verbatim into every language, so a
literal substring replacement is correct in all 5 locales.

This makes the work a scripted JSON transform, not a manual re-translation. It is still not
a `sed` job — the file is JSON and must stay valid.

## Related Code Files

- Modify: `TablePro/Resources/Localizable.xcstrings` (44 keys + 177 values)
- Modify: `TablePro/Core/MCP/Protocol/Handlers/InitializeHandler.swift:57` (MCP server title)
- Modify: remaining non-localized Swift literals found by grep
- Check: `TableProMobile/` has its own catalog; out of scope unless the mobile target is built

## Implementation Steps

1. Back up the catalog: `cp TablePro/Resources/Localizable.xcstrings /tmp/`.
2. Write a Python transform that loads the JSON, and for every entry replaces "TablePro"
   with "SchemaStudio" in **both** the key and every nested `stringUnit.value`, then writes
   back with `ensure_ascii=False` and stable key ordering to keep the diff readable.
3. Validate: `python3 -c "import json; json.load(open(...))"` and confirm the key count is
   still 3515 — a changed count means keys collided or were dropped.
4. Confirm zero remaining hits: the catalog should contain no "TablePro" substring.
5. Fix `InitializeHandler.swift:57` — the MCP `"title"` field identifies this server to
   connected AI clients and is user-visible in client UIs.
6. Grep Swift for remaining non-localized literals and fix the ones a user can see. Leave
   plugin bundle IDs and `TableProPluginKit` alone.
7. Open the app and walk the surfaces that render these strings: About box, plugin update
   alerts, MCP permission prompt, schema-switch error.

## Success Criteria

- [ ] `grep -c "TablePro" TablePro/Resources/Localizable.xcstrings` → 0
- [ ] Catalog parses as JSON and still has 3515 keys
- [ ] `vi` and `zh-Hans` values for renamed entries are present and read "SchemaStudio"
- [ ] About box shows "About SchemaStudio"
- [ ] MCP `initialize` response reports title "SchemaStudio"
- [ ] Build succeeds and no missing-key warnings appear in the build log

## Risk Assessment

**Key collision (Medium).** If two distinct keys normalize to the same string after
replacement, one entry silently overwrites the other and a UI string goes missing. Step 3's
key-count assertion catches this.

**Xcode rewriting the catalog (Medium).** Opening and saving the catalog in Xcode can
reorder or reformat the file, producing an unreviewable diff. Do the transform with the
project closed, and commit before opening Xcode again.

**Non-catalog literals missed (Low).** `String(localized:)` entries land in the catalog, but
AppKit strings, log messages, and protocol fields do not. Step 6's grep is the safety net;
`CLAUDE.md` forbids `String(localized:)` with interpolation, so there are no dynamic keys
hiding a brand name.

**Mobile catalog (Low).** `TableProMobile/` carries a separate catalog. The mobile target is
a non-goal for this rebrand; leaving it stale is acceptable but should be stated, not
forgotten.
