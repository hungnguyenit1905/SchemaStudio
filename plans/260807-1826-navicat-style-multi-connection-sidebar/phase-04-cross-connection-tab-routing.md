---
phase: 4
title: "Cross-connection tab routing"
status: pending
priority: P1
effort: "1-1.5d"
dependencies: [3]
---

# Phase 4: Cross-connection tab routing

<!-- Updated: Validation Session 1 - đổi số từ Phase 3; chốt ngữ nghĩa groupAllConnectionTabs -->



## Overview

Mở bảng thuộc connection X từ một sidebar đang nằm trong window bind với connection Y. Đây là chỗ
"nhiều session song song" trở thành hành vi người dùng thấy được.

## Requirements

Functional:
- Double-click bảng dưới connection X mở tab bind `payload.connectionId = X`.
- Tab mới nằm cùng tab group với các tab đang mở, không tách cửa sổ riêng.
- Nếu bảng thuộc đúng connection của window hiện tại, giữ nguyên hành vi cũ (preview tab, promote,
  tab replacement guard) — không được đi đường vòng làm mất guard.
- Thanh dưới sidebar (nút tạo object, `SchemaPickerControl`, filter database) bám theo connection
  đang chọn trong cây, không bám connection của window.

Non-functional:
- Không sửa cơ chế tab persistence hay recovery.

## Architecture

Hai đường mở tab đã tồn tại:

| Trường hợp | Đường đi |
|---|---|
| Cùng connection với window | `coordinator.openTableTab(table, forceNonPreview:activateGridFocus:)` — giữ nguyên, có tab replacement guard và preview tab |
| Khác connection | `WindowManager.openTab(payload:)` với `EditorTabPayload(connectionId: X, tableName: ...)` — tự dựng `SessionState` mới cho X qua `SessionStateFactory.create` |

Điểm cần quyết ở phase này là **tab group**. `WindowManager.tabbingIdentifier(for:)` trả
`com.SchemaStudio.main.<connectionId>` khi `groupAllConnectionTabs` tắt (mặc định), nghĩa là tab của
connection X sẽ mở thành cửa sổ riêng và người dùng thấy sidebar "biến mất". Không chấp nhận được.

Giải pháp đã chốt ở validation: khi mở tab từ node của một connection khác, ép tabbing identifier
chung (`com.SchemaStudio.main`) cho lần mở đó, **độc lập với setting**. Setting
`groupAllConnectionTabs` giữ nguyên và chỉ còn điều khiển luồng Welcome/menu. Hệ quả phải chấp nhận:
cùng một việc "mở bảng của connection X" cho ra window riêng nếu đi từ Welcome và cùng tab group
nếu đi từ cây. Phase 6 phải viết rõ hai đường này trong `docs/customization/settings.mdx`. Phương án
tôn trọng setting ở cả cây đã bị loại vì nó làm sidebar biến mất khỏi window mới, phá trải nghiệm
chính của plan. Cụ thể: thêm tham số tường minh cho
`WindowManager.openTab` (ví dụ `tabGroup: .shared` / `.perConnection`) thay vì đọc setting toàn cục
bên trong — hàm hiện đọc setting ở hai nơi (`tabbingIdentifier(for:)` và biến `groupAll` trong
`openTab`), nên gom về một tham số cũng dọn được chỗ trùng lặp đó.

### "Coordinator của connection X" không có nghiệm duy nhất (red team H3)

`MainContentCoordinator.activeCoordinators` keyed theo `instanceId`
(`MainContentCoordinator.swift:282`), và **một connection có nhiều coordinator**, mỗi tab window
một cái — chính `aggregatedTabs(for:)` mô tả "across all of a connection's windows"
(`MainContentCoordinator.swift:304-306`). Mỗi coordinator có `browseDatabaseName`, safe mode,
filter riêng, nên `activeCoordinators.values.first { $0.connectionId == X }` trả về một cái tuỳ
thứ tự dictionary. Thanh dưới sidebar sẽ đổi hành vi ngẫu nhiên giữa các lần chạy.

Luật chọn bắt buộc, theo thứ tự:
1. Coordinator của **key window** nếu `connectionId` của nó bằng X.
2. Nếu không, coordinator của window đang chứa sidebar này nếu khớp X.
3. Nếu không, `nil` → thanh dưới disable, đúng như hành vi hiện có khi `coordinator == nil`
   (`SidebarView.swift:231`).

Không được "đoán" một coordinator bất kỳ của X. Viết luật này thành một hàm thuần có test, không
rải điều kiện trong view.

Connection đang chọn: `ConnectionTreeState.activeConnectionId` (Phase 1) cập nhật khi selection rơi
vào node có connectionId. Chọn node root hoặc folder **không** đổi giá trị, giữ connection đã chọn
trước đó, vì thanh dưới không có gì hợp lý để hiện cho một folder. Thanh dưới sidebar đọc giá trị
này để lấy `databaseType` và `SchemaPickerControl`. Safe mode
cho hành động ghi đọc theo connection đang chọn, không theo window (red team M6, cùng luật với
Phase 2).

## Related Code Files

- Modify: `TablePro/Core/Services/Infrastructure/WindowManager.swift` — tham số tab group tường minh
- Modify: `TablePro/Core/Services/Infrastructure/MainSplitViewController.swift` — `onDoubleClick` phân nhánh theo connectionId của node
- Modify: `TablePro/Views/Sidebar/SidebarView.swift` — thanh dưới bám `activeConnectionId`
- Modify: `TablePro/Views/Sidebar/SchemaPickerControl.swift` — nhận connectionId từ cây
- Modify: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+Selection.swift` — cập nhật `activeConnectionId`
- Read-only: `TablePro/Views/Main/MainContentCoordinator.swift`, `TablePro/Models/Query/QueryTabManager.swift`
- Create: `TableProTests/Core/Services/TabRoutingTests.swift`

## Implementation Steps

1. Thêm tham số tab group cho `WindowManager.openTab` và `tabbingIdentifier`; gom hai chỗ đọc
   `groupAllConnectionTabs` về một điểm.
2. Sửa `onDoubleClick` trong `MainSplitViewController.sidebarBody`: so `node.connectionId` với
   `currentSession.connection.id`; bằng nhau thì giữ nguyên đường cũ, khác thì dựng
   `EditorTabPayload` và gọi `WindowManager.openTab(payload:tabGroup: .shared)`.
3. Cập nhật `activeConnectionId` khi selection đổi trong outline.
4. Viết hàm thuần phân giải coordinator theo luật 3 bước ở trên; cho thanh dưới sidebar và
   `SchemaPickerControl` dùng nó, đọc `activeConnectionId`, và đọc safe mode của connection đó.
5. Đăng ký file mới vào pbxproj.
6. Test đơn vị cho: logic chọn đường (cùng/khác connection), hàm phân giải tabbing identifier, và
   hàm phân giải coordinator khi có nhiều coordinator cùng connectionId.

## Success Criteria

- [ ] Mở bảng của connection khác tạo tab đúng connectionId, cùng tab group
- [ ] Mở bảng cùng connection giữ nguyên preview tab và tab replacement guard
- [ ] Thanh dưới sidebar đổi theo connection đang chọn trong cây, và hành vi ổn định khi connection
      đó có nhiều tab window (không phụ thuộc thứ tự dictionary)
- [ ] Setting "Group all connections in one window" vẫn điều khiển đúng luồng cũ
- [ ] Window title của tab mới đúng ngay từ lúc tạo (qua `WindowTitleResolver`, không hiện blank)

## Risk Assessment

- **Tab replacement guard.** Đi tắt qua `WindowManager.openTab` cho trường hợp cùng connection sẽ
  mất guard unsaved-edits. Phân nhánh phải rõ ràng và có test.
- **Window title blank.** Tab join vào group mà không được activate sẽ không chạy `viewWillAppear`;
  title phải resolve ngay trong `TabWindowController.init` như hiện tại. Không được để
  `EditorTabPayload` thiếu thông tin khiến title rỗng.
- **Recovery list.** `MainContentCoordinator.syncRecoveryList()` ghi `LastOpenConnections.json` cho
  window đã activate. Nhiều connection trong một group có thể làm danh sách khôi phục dài hơn
  trước; kiểm tra "Reopen Last Session" vẫn đúng.
