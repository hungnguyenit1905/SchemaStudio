---
phase: 3
title: "Gộp ba nhánh render về một outline"
status: pending
priority: P1
effort: "1-1.5d"
dependencies: [2]
---

# Phase 3: Gộp ba nhánh render về một outline

<!-- Updated: Validation Session 1 - tách ra từ Phase 2 cũ -->

## Overview

Bỏ hai nhánh render SwiftUI `flatContent` và `hierarchicalContent`, cho mọi `GroupingStrategy` đi
qua cùng một NSOutlineView đã dựng ở Phase 2. Đây là điều kiện để SQLite có mặt trong cây.

## Requirements

Functional:
- Mọi connection, bất kể `GroupingStrategy`, nằm trong cùng một outline dưới node connection của
  nó.
- Cấu trúc con của mỗi connection đúng theo loại của nó: `.byDatabase` có level database,
  `.bySchema` có level schema, `.hierarchicalSchema` giữ đúng thứ bậc hiện có, `.flat` cho ra danh
  sách bảng thẳng dưới node connection.
- Search hoạt động đồng nhất trên cả bốn strategy.

Non-functional:
- Không giữ lại nhánh render cũ dưới bất kỳ cờ hay setting nào.

## Architecture

`SidebarView.swift:152-161` chọn nhánh theo `GroupingStrategy`. `supportsDatabaseTree` trả false
cho mọi loại không phải `.network` (`PluginManager+Registration.swift:509-516`), tức **SQLite luôn ở
nhánh flat**. Giữ nhánh cũ đồng nghĩa SQLite biến mất khỏi sidebar sau khi khung ngoài đổi sang cây
connection, phá mục tiêu 1 của plan (red team M7).

Phase 2 đã bắt buộc hàm dựng children nhận `GroupingStrategy` như tham số phân giải từ node, nên
phase này không phải viết lại logic children: chỉ mở rộng cho `.flat` và `.hierarchicalSchema`, rồi
xoá hai view SwiftUI và điểm rẽ nhánh.

`supportsDatabaseTree` sau thay đổi này không còn quyết định *có dùng outline hay không* (luôn
dùng). Nếu nó còn call site khác (`MainContentCommandActions.swift:303`) thì giữ nguyên ngữ nghĩa ở
đó; không đổi hàm để hợp với sidebar.

## Related Code Files

- Modify: `TablePro/Views/Sidebar/SidebarView.swift` — xoá `flatContent`, `hierarchicalContent` và điểm rẽ nhánh
- Modify: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+Nodes.swift` — children cho `.flat` và `.hierarchicalSchema`
- Modify: `TablePro/Views/Sidebar/DatabaseTreeFilter.swift` — search đồng nhất trên mọi strategy
- Delete: `TablePro/Views/Connection/ConnectionSidebarHeader.swift` — code chết, cây thay thế vai trò của nó
- Modify: `TableProTests/Views/Sidebar/MultiConnectionTreeTests.swift` — thêm ca SQLite và hierarchicalSchema
- Read-only: `TablePro/Core/Plugins/PluginManager+Registration.swift`

## Implementation Steps

1. Mở rộng hàm dựng children cho `.flat`: node connection sinh thẳng node table, không level
   database.
2. Mở rộng cho `.hierarchicalSchema`: giữ đúng thứ bậc mà `hierarchicalContent` đang render.
3. Xoá `flatContent` và `hierarchicalContent` khỏi `SidebarView`, xoá điểm rẽ nhánh; mọi trường hợp
   đi qua outline.
4. Xoá `ConnectionSidebarHeader.swift`, gỡ khỏi pbxproj, xác nhận không còn tham chiếu ngoài
   `#Preview` của chính nó.
5. Cập nhật pbxproj cho file đã xoá.
6. Test: cây có MySQL (`byDatabase`), PostgreSQL (`bySchema`), SQLite (`flat`) và một loại
   `hierarchicalSchema` cùng lúc; mỗi loại đúng cấu trúc; search cho kết quả trên cả bốn.

## Success Criteria

- [ ] MySQL, PostgreSQL và SQLite cùng nằm trong một outline, mỗi loại đúng cấu trúc của nó
- [ ] Không còn `flatContent` / `hierarchicalContent` trong `SidebarView`
- [ ] `ConnectionSidebarHeader.swift` đã xoá, không còn tham chiếu
- [ ] Search cho kết quả đúng trên cả bốn `GroupingStrategy`
- [ ] File đã xoá đã gỡ khỏi pbxproj; clone mới build được
- [ ] `swiftlint lint --strict` sạch trên các file đã đụng

## Risk Assessment

- **Không có phương án lùi.** Bỏ gộp nghĩa là mất SQLite khỏi sidebar. Nếu ước lượng trượt, xin
  thêm thời gian chứ không cắt phạm vi này.
- **`.hierarchicalSchema` là nhánh ít người dùng nhất nên dễ regress lặng.** Test tự động cho nó,
  đừng dựa vào kiểm tra tay.
