---
phase: 2
title: "Cut upstream network links"
status: complete
priority: P1
effort: "3h"
dependencies: []
---

# Phase 2: Cut upstream network links

## Overview

The app talks to upstream TablePro infrastructure at runtime: auto-update, licensing,
team library, and analytics. Once the product is called SchemaStudio, every one of those
calls is wrong — it either impersonates upstream, leaks telemetry to a third party, or
silently reinstalls TablePro over your build.

This phase is independent of the rename and can land first.

## Requirements

- Functional: no runtime code path reaches `tablepro.app` or `TableProApp/TablePro`.
- Non-functional: disabling a service must fail closed and quietly, not crash or block launch.

## Architecture

Four distinct upstream couplings, each needing a different decision:

| Coupling | Location | Why it is wrong after rebrand |
|---|---|---|
| Sparkle auto-update | `TablePro/Info.plist` `SUFeedURL` | App silently updates itself back into upstream TablePro |
| Licensing | `LicenseAPIClient.swift:17`, `LicenseConstants.swift` | Calls someone else's licensing service under a new brand |
| Team library | `LiveTeamLibraryAPIClient.swift:18` | Same service, same problem |
| Analytics | `Packages/TableProCore/Sources/TableProAnalytics/AnalyticsHeartbeatService.swift:49` | Sends your telemetry to upstream's server |

### Sparkle needs more than a URL swap

`Info.plist` also carries upstream's EdDSA public key:

```
SUPublicEDKey = EongGFyuahKlYPZwgmnFx8nW3s1CqWlSSU5BDqY6n6Q=
```

Updates are verified against that key, and the matching **private key belongs to upstream**.
Repointing `SUFeedURL` at your own appcast without generating your own keypair produces an
updater that rejects every update it downloads. Since the fork has no release pipeline yet,
**disable Sparkle** rather than repoint it. Repointing becomes correct only once you have
your own signing keypair and a published `appcast.xml`.

### CloudKit

`TablePro/TablePro.entitlements` declares container `iCloud.com.TablePro` under team
`D7HJ5TFYCU`, which is not available on this machine. A container ID cannot be renamed.
Per the settled decision, disable iCloud rather than create a new container: the repo
already ships `TablePro/TablePro.Debug.entitlements` with iCloud dropped, which is the
intended path for non-team builds.

## Related Code Files

- Modify: `TablePro/Info.plist` (Sparkle keys)
- Modify: `TablePro/Core/Services/Licensing/LicenseAPIClient.swift`
- Modify: `TablePro/Core/Services/Licensing/LicenseConstants.swift`
- Modify: `TablePro/Core/Services/TeamLibrary/LiveTeamLibraryAPIClient.swift`
- Modify: `Packages/TableProCore/Sources/TableProAnalytics/AnalyticsHeartbeatService.swift`
- Modify: `TablePro/TableProApp.swift`, `TablePro/AppDelegate.swift` (service wiring)
- Modify: build settings to use `TablePro.Debug.entitlements`

## Implementation Steps

1. Read `TableProApp.swift` and `AppDelegate.swift` to find where the updater, license
   service, team library, and analytics heartbeat are started.
2. Disable Sparkle: remove `SUFeedURL` and `SUPublicEDKey` from `Info.plist`, and gate the
   updater startup off. Verify the "Check for Updates" menu item is removed or disabled —
   a menu item that silently does nothing is worse than an absent one.
3. Disable analytics at the call site rather than blanking the URL, so no request is
   constructed at all. Note `AnalyticsHeartbeatService.swift:49` carries a
   `swiftlint:disable:this force_unwrapping` comment — remove the comment along with the
   forced unwrap if the URL literal goes away.
4. Decide licensing behaviour and apply it consistently across `LicenseAPIClient` and
   `LiveTeamLibraryAPIClient`: either stub the client to return "unlicensed / feature
   unavailable", or remove the feature surface. Do not leave a client pointed at a dead host.

   **Red team, High — this is not a cosmetic stub.** `isLicensed` gates real UI:
   `TablePro/Views/Settings/LinkedFoldersSection.swift:16` computes it and lines 37 and 41
   drive `.disabled(!isLicensed)` and an upsell branch. So:
   - Stubbing **unlicensed** silently disables the Linked Folders feature. Acceptable, but
     it is a product change, not a refactor — say so rather than discovering it later.
   - Stubbing **licensed = true** would unlock a feature upstream gates commercially.
     Do not do this. It is circumventing another project's paid tier, and shipping it in a
     public AGPL fork makes the fork's intent look like license evasion.
   - Removing the feature surface entirely is the cleanest option if Linked Folders is not
     wanted in SchemaStudio.

   Record which of the three was chosen, in the commit message.
5. Switch the Debug configuration's `CODE_SIGN_ENTITLEMENTS` to
   `TablePro/TablePro.Debug.entitlements` so iCloud is dropped.
6. Grep for stragglers and confirm only non-runtime references remain.

## Success Criteria

- [ ] `grep -rn "api\.tablepro\.app" --include="*.swift" .` → empty
- [ ] `grep -n "SUFeedURL\|SUPublicEDKey" TablePro/Info.plist` → empty
- [ ] Launch the app with Console filtered on the app subsystem: no outbound request to
      `tablepro.app` during first 60 seconds
- [ ] "Check for Updates" is absent or explicitly disabled, never a silent no-op
- [ ] App launches with no iCloud entitlement and does not crash on the sync path
- [ ] `scripts/download-libs.sh` still references `TableProApp/TablePro` (artifact host,
      deliberately unchanged)

## Risk Assessment

**Disabling a service by blanking a URL (Medium).** An empty or placeholder URL still
builds a request and fails at runtime, often on a background queue where the error is
invisible. Disable at the call site so the code path is never entered.

**Sync path assumes iCloud exists (Medium).** `CLAUDE.md` documents that this codebase has
shipped bugs where CloudKit rejection silently killed a whole record type. Dropping the
entitlement is the supported configuration per `CONTRIBUTING.md`, but exercise connection
save/load after the change rather than assuming.

**License removal cuts a visible feature (Low).** If licensing gates real UI, stubbing it
changes what the app offers. Decide deliberately in step 4 and record the choice; do not
let it fall out of an implementation detail.
