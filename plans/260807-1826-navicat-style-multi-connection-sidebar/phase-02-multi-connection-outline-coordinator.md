---
phase: 2
title: "Node context và cây connection trên nhánh outline"
status: done
priority: P1
effort: "1.5-2d"
dependencies: [1]
---

# Phase 2: Node context và cây connection trên nhánh outline

<!-- Updated: Validation Session 1 - tách phase 2 cũ thành 2 (phase này) và 3 (gộp nhánh render) -->

## Overview

Gỡ giả định "một connection mỗi coordinator" khỏi `DatabaseTreeOutlineCoordinator` và render cây
mới: root → folder → connection → database → schema → table, **trên nhánh `databaseTreeContent`
sẵn có**. Việc gộp hai nhánh `flat` và `hierarchicalSchema` vào cùng outline tách sang Phase 3.

Ranh giới: kết thúc phase này, app build được và chạy được. Connection loại `.network` hiện đủ
trong cây mới; SQLite và các loại đi nhánh flat vẫn render như hôm nay và **chưa** nằm trong cây.
Đó là trạng thái trung gian có chủ đích, Phase 3 đóng lại.

## Requirements

Functional:
- Outline hiển thị folder và connection kể cả khi connection chưa kết nối (dữ liệu từ storage,
  không cần session).
- Expand một connection nạp database của đúng connection đó.
- Mỗi dòng connection hiện icon theo `DatabaseType`, màu theo `connection.displayColor`, và chấm
  trạng thái (connected/connecting/disconnected/error) giống `ConnectionSidebarHeader.statusColor`.
- Search match **tên connection và tên folder** (đọc từ storage, không cần session), cộng với
  database/schema/table của các connection đang expand. Không tự connect để tìm.

Non-functional:
- Không nạp metadata của connection chưa expand.
- File coordinator phải tách nhỏ trước khi vượt ngưỡng SwiftLint.

## Architecture

`DatabaseTreeOutlineCoordinator` hiện lưu `connectionId`, `databaseType`, `viewModel`,
`sidebarState`, `activeDatabase`, `activeSchema` như **field của chính nó** và
`DatabaseTreeOutlineView.update(from:)` bơm vào. Sau phase này chúng phải phân giải **theo node**:

```swift
private func context(for node: DatabaseTreeNode) -> NodeContext?
// -> (connectionId, databaseType, viewModel, sidebarState)
```

trong đó `viewModel` lấy từ `SidebarViewModel.shared(connectionId:databaseType:...)` (đã là
registry theo connection) và `sidebarState` từ `SharedSidebarState.forConnection(id)`. Hai registry
này đã tồn tại nên không cần vòng đời mới.

Những thứ đang là "một giá trị cho cả coordinator" phải thành theo connection:
- `connectionToken` (`isConnected ? "connected" : "down"`) → token tổng hợp trạng thái của các
  connection đang expand, để `refresh()` chạy khi bất kỳ connection nào đổi trạng thái.
- `supportsSchemaLevel` và `systemSchemas` đang đọc `PluginManager` theo `databaseType` của
  coordinator → phải hỏi theo `databaseType` của node cha.
- `pendingTruncates` / `pendingDeletes` đang là `Set<String>` tên bảng của một connection → phải
  keyed theo connectionId, nếu không bảng cùng tên ở connection khác sẽ hiện nhầm dấu pending.
- `lastSelection: Set<DatabaseTreeTableRef>` → `DatabaseTreeTableRef.id` hiện là
  `database|schema|table`, phải thêm connectionId vào id (làm ở Phase 1).

`DatabaseTreeMetadataService` đã keyed theo connectionId (`databaseList: [UUID: ...]`) nên nạp
database cho nhiều connection song song là chuyện có sẵn; chỉ cần gọi
`loadDatabases(connectionId:databaseType:)` khi node connection được expand, và tuân thủ invariant
"refresh không xoá cache": dùng `prepareForReload`, không `invalidate`.

### Ba nhánh render vẫn còn, gộp ở Phase 3 (red team M7)

`SidebarView` hiện chọn một trong ba nhánh render (`hierarchicalContent` / `databaseTreeContent` /
`flatContent`) theo `GroupingStrategy` (`SidebarView.swift:152-161`). Phase này chỉ đổi nhánh
`databaseTreeContent`; hai nhánh kia còn nguyên và được gộp ở Phase 3. Quyết định "cả ba hội tụ về
một NSOutlineView, không giữ nhánh cũ" không đổi, chỉ dời chỗ thực thi.

Ràng buộc để Phase 3 không phải viết lại phase này: `context(for:)` và cách dựng children của node
connection phải nhận `GroupingStrategy` như tham số phân giải từ `databaseType` của node
(`PluginManager.databaseGroupingStrategy(for:)`, `PluginManager+Registration.swift:504`), **không**
được hard-code giả định `.byDatabase`/`.bySchema`. Phase 3 chỉ việc bỏ hai nhánh SwiftUI và cho
chúng đi qua cùng đường children này.

### Safe mode đọc theo node (red team M6)

`SidebarView.swift:231` disable nút tạo object bằng `coordinator?.safeModeLevel.blocksAllWrites`,
tức safe mode **của window** (`MainContentCoordinator.swift:82` → `toolbarState.safeModeLevel`).
Mọi hành động ghi hiển thị cho connection X (context menu ở phase này, thanh dưới ở Phase 3) phải
đọc safe mode của X. Đọc nhầm nguồn nghĩa là hiện nút ghi cho một connection đang ở chế độ chỉ đọc.

## Related Code Files

- Modify: `TablePro/Views/Sidebar/DatabaseTreeOutlineCoordinator.swift` (705 dòng — tách ngay)
- Create: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+Nodes.swift` — dựng node và children
- Create: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+Selection.swift` — selection, expansion, click
- Create: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+ContextMenu.swift`
- Create: `TablePro/Views/Sidebar/ConnectionRowView.swift` — dòng connection (icon, tên, chấm trạng thái, spinner)
- Modify: `TablePro/Views/Sidebar/DatabaseTreeOutlineView.swift` — thôi truyền connectionId/databaseType đơn lẻ
- Modify: `TablePro/Views/Sidebar/DatabaseTreeView.swift` — bỏ nhánh state theo một connection
- Modify: `TablePro/Views/Sidebar/SidebarView.swift` — nhánh `databaseTreeContent` nhận cây connection
- Modify: `TablePro/Views/Sidebar/DatabaseTreeCellView.swift`, `DatabaseTreeRowView.swift` — render kind mới
- Modify: `TablePro/Views/Sidebar/DatabaseTreeFilter.swift` — lọc xuyên connection, match cả tên connection/folder
- Modify: `TablePro/Core/Services/Infrastructure/MainSplitViewController.swift` — `buildSidebarView()` không còn cần `currentSession` để dựng cây
- Create: `TableProTests/Views/Sidebar/MultiConnectionTreeTests.swift`

`ConnectionSidebarHeader.swift` xoá ở Phase 3, cùng lúc bỏ ba nhánh render.

## Implementation Steps

1. Tách `DatabaseTreeOutlineCoordinator` thành các extension file ở trên **trước khi** thêm code.
2. Thêm `NodeContext` và hàm `context(for:)`; đổi mọi chỗ đọc field coordinator sang đọc context.
3. Dựng children cho `connectionRoot` / `folder` / `connection` qua một hàm nhận `GroupingStrategy`
   phân giải từ `databaseType` của node; node connection chưa kết nối sinh node `status(.loading)`
   khi expand và kích hoạt connect (tạm thời gọi thẳng `DatabaseManager.connectToSession`, hoàn
   thiện ở Phase 5).
4. Viết `ConnectionRowView` với icon, màu, chấm trạng thái, spinner khi `.connecting`.
5. Context menu và mọi hành động ghi đọc safe mode của connection thuộc node, không của window.
6. Cho `DatabaseTreeFilter` nhận nhiều connection: match tên connection và tên folder từ storage,
   cộng database/schema/table của connection đang expand. Không connect để tìm.
7. Thêm mọi file mới vào pbxproj.
8. Test: dựng cây với 2 connection khác loại (MySQL byDatabase, PostgreSQL bySchema), kiểm tra
   children resolve đúng `GroupingStrategy` và `systemSchemas` của từng loại; kiểm tra pending set
   không rò giữa 2 connection có bảng trùng tên; kiểm tra safe mode của connection A không ảnh
   hưởng menu của connection B; kiểm tra search khớp tên connection và tên folder khi chưa expand
   gì.

## Success Criteria

- [x] Sidebar hiện folder + connection kể cả khi chưa kết nối
- [x] Expand hai connection cùng lúc, cả hai nạp database độc lập, không nhiễu id
- [x] Hành động ghi đọc safe mode của đúng connection thuộc node
- [x] Search khớp tên connection và tên folder khi chưa expand connection nào
- [x] ~~File mới đã vào pbxproj~~ Không cần: synchronized root group (xem invariant 7)
- [x] Dấu pending truncate/delete không rò sang connection khác có bảng trùng tên
- [x] Không file nào vượt cảnh báo 1200 dòng của SwiftLint
- [x] App build và chạy được với ba nhánh render còn nguyên (trạng thái trung gian hợp lệ)

## Risk Assessment

- **Rủi ro cao nhất của cả plan.** Coordinator là 705 dòng logic AppKit có cache, reconcile, và cờ
  chống đệ quy (`isApplyingExpansion`, `isSyncingSelection`, `isReloading`, `reconcileScheduled`).
  Thêm level mới dễ gây reload vòng lặp. Mitigation: tách file trước, đổi từng nhóm field một, và
  giữ nguyên cơ chế cờ thay vì viết lại.
- **Trạng thái trung gian sống trong một commit.** Kết thúc phase, SQLite chưa vào cây. Đây là chủ
  ý để cô lập lỗi reload vòng lặp khỏi việc gộp nhánh; không được ship bản release ở giữa Phase 2
  và Phase 3.
- **Regression hiệu năng**: cây có nhiều connection dễ khiến `refresh()` chạy thừa. Đo lại thời
  gian mở tab (log `[open] WindowManager.openTab done ... elapsedMs`) trước và sau.
