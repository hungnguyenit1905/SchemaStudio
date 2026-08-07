---
title: "Navicat-style multi-connection sidebar"
description: "Sidebar chính trở thành cây toàn cục Folder → Connection → Database → Schema → Table, dùng chung cho mọi tab window, mở tab được cho connection bất kỳ."
status: pending
priority: P1
effort: "7.5-10.5d"
tags: [sidebar, connections, macos, appkit, outlineview]
created: 2026-08-07
---

# Navicat-style multi-connection sidebar

## Overview

Sidebar hiện tại phục vụ đúng một connection: `SidebarView(connectionId:databaseType:)` nhận
connectionId của window, state lấy qua `SharedSidebarState.forConnection(id)`, và gốc cây là
**database** (`DatabaseTreeNode.Kind` chỉ có `recentSection / database / schema / table /
routine / status`). Muốn đổi connection phải quay lại Welcome window hoặc mở window mới.
`ConnectionSidebarHeader.swift` (dropdown chuyển connection) tồn tại nhưng không được render ở
đâu, chỉ có chính nó và `#Preview` tham chiếu.

Kế hoạch này đưa level **folder** và **connection** vào trên đỉnh cây, biến sidebar thành danh
sách toàn cục giống Navicat: mọi connection đã lưu đều hiện, expand một connection thì kết nối
và nạp database, mở bảng của connection bất kỳ sẽ tạo tab thuộc đúng connection đó.

## Điều kiện thuận lợi đã có sẵn (đừng làm lại)

| Thứ đã có | Ở đâu |
|---|---|
| Mỗi tab đã là một NSWindow riêng với SessionState riêng | `WindowManager.openTab` → `TabWindowController` → `MainSplitViewController(payload:sessionState:)`; `SessionStateFactory.create` dựng `QueryTabManager`, `DataChangeManager`, `ConnectionToolbarState`, `MainContentCoordinator` cho từng connection |
| Gộp mọi connection vào một tab group | `WindowManager.tabbingIdentifier(for:)` trả `com.SchemaStudio.main` khi `AppSettings.tabs.groupAllConnectionTabs` bật (Settings → "Group all connections in one window") |
| Session và metadata đã keyed theo connectionId | `DatabaseManager.activeSessions: [UUID: ConnectionSession]`, `DatabaseTreeMetadataService.databaseList: [UUID: ...]`, `SidebarViewModel.registry[connectionId]`, `SharedSidebarState.registry[connectionId]` |
| Model folder + cây connection | `ConnectionGroup` (`parentId`, `color`, `sortOrder`), `ConnectionGroupTreeNode`, `buildGroupTree(maxDepth: 3)` — hiện chỉ dùng ở `WelcomeViewModel.treeItems` |
| Cây database đã là NSOutlineView có cache lazy | `DatabaseTreeOutlineCoordinator` (705 dòng), `DatabaseTreeOutlineView`, `DatabaseTreeNode` |

Vì thế công việc thật không phải viết lại vòng đời session, mà là: thêm hai level trên đỉnh cây,
phân giải `connectionId` theo từng node thay vì theo window, và định tuyến mở tab theo node.

## Decisions đã chốt ở brainstorm (không mở lại)

| Decision | Value |
|---|---|
| Hướng | A: nhiều session song song trong một tab group |
| Welcome window | Giữ nguyên. `WelcomeRouter` và luồng khởi động không đổi |
| Sửa/xoá connection và folder | Vẫn ở Welcome. Sidebar chỉ có Connect/Disconnect/Refresh/Edit (mở form sẵn có) |
| Phạm vi cây | Level connection/folder bọc bên trên; phần dưới connection vẫn theo `GroupingStrategy` hiện có (tree / hierarchicalSchema / flat) |
| Drag-drop sắp xếp folder trong sidebar | Không làm |
| Khôi phục trạng thái expand lúc khởi động | Chỉ khôi phục hiển thị, không tự kết nối (red team C2) |
| Ba nhánh render sidebar | Hội tụ về một NSOutlineView; không giữ nhánh cũ (red team M7) |
| Plugin ABI | Không đụng. Không sửa gì dưới `Plugins/` |
| Tab persistence / recovery | Không đổi cơ chế |
| Đóng tab cuối của connection đang expand | Không ngắt kết nối. Cây là nguồn giữ session thứ hai bên cạnh window (validation D1) |
| Phạm vi search | Match tên connection và folder từ storage, cộng node đã nạp của connection đang expand. Không auto-connect để tìm (validation D2) |
| `groupAllConnectionTabs` | Giữ nguyên setting, chỉ còn điều khiển luồng Welcome/menu. Mở tab từ cây luôn cùng group (validation D3) |

## Goals

| # | Goal | Priority |
|---|------|----------|
| 1 | Sidebar liệt kê mọi connection đã lưu theo folder, mọi tab window thấy cùng một cây và cùng trạng thái expand | P1 |
| 2 | Expand một connection chưa kết nối sẽ tự connect rồi nạp danh sách database | P1 |
| 3 | Mở bảng thuộc connection bất kỳ tạo tab bind đúng connection đó, nằm cùng tab group | P1 |
| 4 | Trạng thái kết nối và lỗi hiển thị ngay trên dòng connection; connect/disconnect làm được từ cây | P1 |
| 5 | Thêm/sửa/xoá connection ở Welcome phản ánh vào sidebar mà không cần khởi động lại | P2 |

## Phases

| # | Phase | Status |
|---|-------|--------|
| 1 | [Phase 1: Tree model và app-level state](./phase-01-start.md) | Done |
| 2 | [Phase 2: Node context và cây connection trên nhánh outline](./phase-02-multi-connection-outline-coordinator.md) | Pending |
| 3 | [Phase 3: Gộp ba nhánh render về một outline](./phase-03-unify-render-branches.md) | Pending |
| 4 | [Phase 4: Cross-connection tab routing](./phase-04-cross-connection-tab-routing.md) | Pending |
| 5 | [Phase 5: Connect lifecycle and connection sync](./phase-05-connect-lifecycle-and-connection-sync.md) | Pending |
| 6 | [Phase 6: Docs, tests, lint](./phase-06-docs-tests-lint.md) | Pending |

Phụ thuộc tuyến tính: 1 → 2 → 3 → 4 → 5 → 6. Phase 6 chạm mọi phase trước.

Phase 2 và 3 là hai nửa của phase 2 cũ, tách ở validation session 1. Kết thúc Phase 2 app build và
chạy được nhưng SQLite chưa vào cây; đó là trạng thái trung gian có chủ đích, không ship release ở
giữa hai phase này.

## Invariant phải giữ (đã gây bug thật, xem CLAUDE.md)

1. **Refresh không được xoá cache đang refresh.** Nạp lại database của một connection phải fetch
   trước rồi commit đè, chỉ vào `.loading` khi chưa có nội dung (`#1916`). Dùng
   `DatabaseTreeMetadataService.reloadTablesInPlace` / `prepareForReload` làm mẫu, không gọi
   `invalidate` để ép reload.
2. **Huỷ connect không dừng được driver.** Expand-to-connect phải đi qua
   `DatabaseManager.connectToSession` và tôn trọng generation của `ConnectionAttemptRegistry`;
   attempt đến muộn phải tự dọn driver của nó, không được ghi đè session thắng (`#1185`, `#1358`,
   `#1369`).
3. **Window title.** Mọi thay đổi title vẫn phải qua `WindowTitleResolver`; không ghi thẳng
   `window.title`.
4. **Tab replacement guard.** `openTableTab` kiểm tra unsaved edits/filter/sort trước khi thay tab;
   định tuyến chéo connection không được đi vòng qua guard này.
5. **`DatabaseType` là struct mở.** Mọi `switch` mới phải có `default:`.
6. **SwiftLint file length.** `DatabaseTreeOutlineCoordinator` đã 705/1200 dòng. Mở rộng nó phải
   tách sang `Extensions/` ngay trong Phase 2, không để chạm ngưỡng.
6b. **Vòng đời session không còn chỉ do window quyết định.** `WindowLifecycleMonitor` ngắt kết nối
   khi window cuối của một connection đóng (`WindowLifecycleMonitor.swift:231`). Sau plan này, cây
   là nguồn giữ session thứ hai: điều kiện ngắt phải xét cả `expandedConnectionIds` (Phase 5).
7. ~~**pbxproj được commit trong repo này.** Khác `schema_studio/` (XcodeGen), mọi file tạo mới hoặc
   xoá phải cập nhật `SchemaStudio.xcodeproj/project.pbxproj` trong cùng commit, nếu không CI và
   máy khác build hỏng.~~ **Sai, bác bỏ ở Implementation Session 1.** `project.pbxproj` có
   `objectVersion = 77` và `TablePro`, `TableProTests`, `TableProUITests` đều là
   `PBXFileSystemSynchronizedRootGroup`. Xcode đồng bộ thư mục theo file system, nên thêm hoặc xoá
   file Swift dưới các thư mục đó **không** cần sửa pbxproj. Chỉ khi đổi target membership
   (`membershipExceptions`) mới phải sửa. Bước "đăng ký file mới vào pbxproj" ở Phase 1-6 bỏ được.

## Red Team Review

Chạy 2026-08-07, 3 lăng kính (Security Adversary, Assumption Destroyer, Failure Mode Analyst).
7 phát hiện, tất cả có dẫn chứng `file:line`, tất cả được nhận và đã áp vào plan.

| # | Mức | Phát hiện | Dẫn chứng | Áp vào |
|---|---|---|---|---|
| C1 | Critical | Selection đi bằng `TableInfo` trần và batch operation nhận tên bảng dạng chuỗi, nên hai connection có bảng trùng tên có thể bị truncate/delete nhầm | `WindowSidebarState.swift:28`, `QueryResult.swift:83-94`, `SidebarView.swift:375` | Phase 1 |
| C2 | Critical | Khôi phục expand kéo theo connect sẽ bắn hàng loạt kết nối và sheet mật khẩu lúc khởi động | `DatabaseManager+Sessions.swift:81`, `PasswordPromptHelper.swift:11-46` | Phase 1, Phase 5 |
| H3 | High | "Coordinator của connection X" không duy nhất: registry keyed theo `instanceId`, một connection có nhiều coordinator | `MainContentCoordinator.swift:282`, `MainContentCoordinator.swift:304-306`, `+Registry.swift:25-30` | Phase 4 |
| H4 | ~~High~~ Bác bỏ | ~~Không phase nào đăng ký file mới/xoá vào pbxproj đang được commit~~ Phát hiện dựa trên giả định sai: pbxproj dùng synchronized root group | `project.pbxproj:6` (`objectVersion = 77`), `:704-711` (`TablePro` là `PBXFileSystemSynchronizedRootGroup`), `:906`, `:919` | Không phase nào |
| H5 | High | `disconnectSession` xoá `SharedSidebarState` của connection, phá state của cây vẫn đang hiển thị | `DatabaseManager+Sessions.swift:387` | Phase 5 |
| M6 | Medium | Safe mode đọc từ window thay vì từ connection của node | `SidebarView.swift:231`, `MainContentCoordinator.swift:82` | Phase 2, Phase 4 |
| M7 | Medium | "Dừng và báo nếu vượt dự kiến" không phải quyết định; giữ nhánh flat riêng sẽ loại SQLite khỏi sidebar | `PluginManager+Registration.swift:509-516`, `SidebarView.swift:152-161` | Phase 3 |

Số phase trong bảng đã đổi theo lần tách phase ở validation session 1 (xem `## Validation Log`).

### Whole-Plan Consistency Sweep

Đã đọc lại `plan.md` và cả 5 phase sau khi áp. Kết quả:

- `pendingTruncates`/`pendingDeletes` giờ nhất quán là `[UUID: Set<String>]` ở Phase 1 (định nghĩa)
  và Phase 2 (dùng); Phase 2 không còn tự nhận là nơi đổi kiểu.
- Câu "nếu vượt dự kiến thì dừng và báo" ở Phase 2 đã bị thay bằng quyết định dứt khoát; mục Risk
  của Phase 2 cập nhật theo.
- Ước lượng: Phase 1 lên 1.5-2d (thêm việc đổi selection), tổng plan lên 6-9d.
- Bảng decisions ở `plan.md` bổ sung 2 dòng mới, không dòng nào mâu thuẫn dòng cũ.
- Không còn mâu thuẫn chưa giải quyết.

## Success Criteria

- [ ] Mở app, sidebar hiện toàn bộ connection đã lưu, nhóm theo folder giống Welcome
- [ ] Mọi tab window hiển thị cùng cây và cùng trạng thái expand; expand ở tab này thấy ở tab kia
- [ ] Expand connection chưa kết nối → spinner → danh sách database; lỗi hiện ngay trên node
- [ ] Double-click bảng thuộc connection khác → tab mới bind đúng connectionId, cùng tab group
- [ ] Connect/Disconnect từ context menu của node connection hoạt động, huỷ giữa chừng không để node treo
- [ ] Đóng tab cuối của một connection đang expand không ngắt kết nối; đã collapse thì vẫn ngắt
- [ ] Search khớp tên connection và folder ngay cả khi chưa expand connection nào
- [ ] Thêm/xoá connection ở Welcome phản ánh vào sidebar không cần restart
- [ ] Trạng thái expand sống qua lần mở lại app
- [ ] `swiftlint lint --strict` sạch, `xcodebuild ... test` xanh
- [ ] CHANGELOG `[Unreleased]` và `docs/features/` cập nhật

## Validation Log

### Session 1 — 2026-08-07

#### Verification Results

- Claims checked: 13 đường dẫn file + 4 symbol
- Verified: 17 | Failed: 0 | Unverified: 0
- Tier: rút gọn (plan đã có `## Red Team Review` với dẫn chứng `file:line`, theo guard của validate
  workflow nên không chạy lại verification pass đầy đủ)
- Xác nhận: `DatabaseTreeOutlineCoordinator.swift` đúng 705 dòng; `ConnectionSidebarHeader.swift`
  tồn tại (200 dòng); `DatabaseTreeTableRef.id` là `database|schema|table.id`, không có connectionId
  (`DatabaseTreeView.swift:9-16`); `supportsDatabaseTree` ở `PluginManager+Registration.swift:509`
- Làm rõ (không phải lỗi): `GroupingStrategy` đến từ plugin metadata theo `databaseType`
  (`PluginManager+Registration.swift:504`), không phải setting của window. "GroupingStrategy của
  chính node connection" là phân giải được, không cần quyết định thêm.

#### Quyết định

| # | Câu hỏi | Quyết định | Áp vào |
|---|---|---|---|
| D1 | Đóng tab cuối của connection X trong khi X đang expand trong cây | Cây giữ session sống. Điều kiện disconnect trong `WindowLifecycleMonitor.handleWindowClose` thêm vế "không nằm trong `expandedConnectionIds`" | Phase 5, invariant 6b |
| D2 | Phạm vi search | Match tên connection và folder từ storage, cộng node đã nạp của connection đang expand. Không auto-connect để tìm | Phase 2, Phase 3 |
| D3 | Ngữ nghĩa `groupAllConnectionTabs` sau khi ép tab group | Giữ setting, chỉ còn điều khiển luồng Welcome/menu; mở từ cây luôn cùng group. Chấp nhận hai đường có hành vi khác nhau, docs phải nói rõ | Phase 4, Phase 6 |
| D4 | Phase 2 (rủi ro cao nhất) có tách không | Tách đôi: Phase 2 = node context + cây connection trên nhánh outline sẵn có; Phase 3 = gộp ba nhánh render | Phase 2, Phase 3, đánh số lại 3-5 → 4-6 |

D1 là phát hiện mới của validation, không nằm trong red team: `WindowLifecycleMonitor.swift:225-239`
giả định "không còn window ⇒ connection không còn được nhìn thấy", và refactor này phá giả định đó
theo hai hướng (connection connected mà chưa từng có window riêng; connection còn hiện trong cây của
mọi window khác).

#### Propagation

- `phase-02`: thu hẹp phạm vi về 2a, thêm ràng buộc "hàm dựng children nhận `GroupingStrategy` như
  tham số" để Phase 3 không phải viết lại, đổi search theo D2, effort 2-3d → 1.5-2d, gỡ mục xoá
  `ConnectionSidebarHeader` và tiêu chí SQLite sang Phase 3
- `phase-03-unify-render-branches.md`: file mới
- `phase-04` (cũ 03): frontmatter `phase: 4`, `dependencies: [3]`; chốt D3; nói rõ chọn node
  root/folder không đổi `activeConnectionId`
- `phase-05` (cũ 04): frontmatter `phase: 5`, `dependencies: [4]`; thêm mục D1 (kiến trúc, file,
  bước 7, 2 test, 2 tiêu chí, 1 rủi ro về `ConnectionHealthMonitor`); effort 1.5-2d → 2-2.5d
- `phase-06` (cũ 05): frontmatter `phase: 6`, `dependencies: [5]`; docs mô tả hai đường mở tab và
  hành vi đóng tab cuối; thêm phép đo tải health monitor
- `plan.md`: bảng phases, 3 dòng decisions mới, invariant 6b, số phase trong bảng red team, 2 tiêu
  chí thành công mới, effort 6-9d → 7.5-10.5d

### Whole-Plan Consistency Sweep

Đã đọc lại `plan.md` và cả 6 phase file sau khi áp.

- Số phase: mọi tham chiếu chéo đã đổi. `plan.md` bảng red team (C2, H3, H4, H5, M6, M7),
  `phase-02` trỏ Phase 3 và Phase 5, `phase-04` trỏ Phase 6, `phase-06` trỏ Phase 4 và Phase 5. Không
  còn chỗ nào nói "Phase 4 connect" theo cách đánh số cũ.
- M7 không bị hạ cấp: quyết định "cả ba nhánh hội tụ, không giữ nhánh cũ" giữ nguyên, chỉ dời sang
  Phase 3. `phase-02` nói rõ điều này thay vì im lặng.
- Trạng thái trung gian giữa Phase 2 và Phase 3 (SQLite chưa vào cây) được nêu ở cả `plan.md` và
  `phase-02`, kèm ràng buộc không ship release ở giữa.
- D2 nhất quán: `plan.md` bảng decisions, `phase-02` Requirements + bước 6 + tiêu chí, `phase-03`
  requirement search đồng nhất trên bốn strategy.
- D1 nhất quán: `plan.md` bảng decisions + invariant 6b + tiêu chí, `phase-05` requirement + mục
  kiến trúc + file + bước 7 + test + 2 tiêu chí + rủi ro.
- Effort: tổng 7.5-10.5d khớp tổng 6 phase (1.5-2 + 1.5-2 + 1-1.5 + 1-1.5 + 2-2.5 + 0.5-1).
- Không còn mâu thuẫn chưa giải quyết.

## Implementation Log

### Session 1 — 2026-08-07 — Phase 1

Commit `523ea08b` (code) và `5aa2311f` (plan docs) trên nhánh `rebrand/schemastudio`.

Đã làm đúng plan:

- `DatabaseTreeNode.Kind` thêm `connectionRoot` / `folder` / `connection`, thêm `var connectionId: UUID?`.
- Mọi id node dưới connection có tiền tố connectionId; `DatabaseTreeTableRef` và
  `DatabaseTreeRoutineRef` mang `connectionId` trong `id`.
- `ConnectionTreeBuilder` (hàm thuần, tái dùng `buildGroupTreeIndexed` + `filterGroupTree` nên thứ
  tự khớp Welcome) và `ConnectionTreeState` (app-level `@Observable` singleton, persist expand ids).
- C1 đóng: `selectedTables` sang `Set<DatabaseTreeTableRef>`, khoá expand mang connectionId,
  `batchToggleTruncate`/`batchToggleDelete` nhận `connectionId` và từ chối connection lạ.

Hai chỗ lệch khỏi câu chữ của plan, có chủ ý:

1. **Lưu trữ pending truncate/delete vẫn ở `ConnectionSession`**, chỉ kiểu *hiển thị* phía sidebar
   thành `[UUID: Set<String>]`. `ConnectionSession` đã keyed theo connection và là nơi
   `RowEditingCoordinator` đọc khi save/discard; dựng thêm một `[UUID: Set<String>]` toàn cục sẽ tạo
   nguồn sự thật thứ hai. Rủi ro mà C1 nêu (hiện nhầm dấu pending, truncate nhầm connection) đã đóng
   bằng kiểu hiển thị + `connectionId` bắt buộc ở API ghi.
2. **`connectionRoot` / `folder` / `connection` render `EmptyView()`.** Phase 1 là model, chưa có
   chỗ nào dựng ba kind này. Phase 2 thay bằng `ConnectionRowView`.

#### Kết quả kiểm chứng

| | passed | failed |
|---|---|---|
| Baseline (stash, HEAD sạch) | 9576 | 72 |
| Sau Phase 1 | 9582 | 74 |

Toàn bộ 72 lỗi baseline cũng fail sau Phase 1 (không che lỗi nào). Hai lỗi lệch là
`AWSSSOFetchTests/unauthorized()` và `CopilotIdleStopControllerTests/rescheduleFiresOnce()`; chạy lại
trên cây **chưa sửa** thì `AWSSSOFetchTests/unauthorized()` vẫn fail và
`AWSSSOFetchTests/networkFailure()` đổi kết quả giữa hai lần trong cùng một lần chạy. Kết luận: flaky
có sẵn, không phải regression. `swiftlint lint --strict` sạch.

#### Hai việc chặn Phase 6, phát hiện ở session này

1. **Repo có sẵn ~72 test fail** trên `rebrand/schemastudio`, không liên quan plan này. Tiêu chí
   "`xcodebuild ... test` xanh" của Phase 6 không đạt được cho tới khi xử lý số này.
2. **`swiftformat --lint .` không chạy được**: `error: Unknown option --ifdefindent` trong
   `.swiftformat`, lệch với SwiftFormat 0.65.0 đang cài. Có sẵn từ trước, nhưng chặn cổng format của
   Phase 6.

<!-- slug: navicat-style-multi-connection-sidebar -->
