---
phase: 1
title: "Tree model và app-level state"
status: pending
priority: P1
effort: "1.5-2d"
dependencies: []
---

# Phase 1: Tree model và app-level state

## Overview

Thêm hai level `folder` và `connection` vào model cây, và tạo state cấp app giữ trạng thái
expand/selection của phần đỉnh cây đó. Phase này thuần model + state, không đụng NSOutlineView,
nên test được bằng unit test.

## Requirements

Functional:
- Model node biểu diễn được: root `My Connections`, folder lồng nhau (tối đa 3 cấp như
  `buildGroupTree(maxDepth: 3)`), connection, rồi nối xuống các node database hiện có.
- Mọi node dưới root phải phân giải được `connectionId` của nó.
- Trạng thái expand của folder và connection sống ở cấp app (dùng chung mọi window) và persist
  qua UserDefaults.

Non-functional:
- Tree builder là hàm thuần, không chạm UI, không chạm mạng — để test.
- Không đổi `DatabaseTreeNode.Kind` theo cách phá code đang dùng nó; chỉ mở rộng.

## Architecture

`DatabaseTreeNode` hiện có `Kind`: `recentSection / recentTable / database / schema / table /
routine / status`, id là chuỗi ghép bằng `\u{1}`. Cách rẻ và ít rủi ro nhất là **mở rộng chính
enum này** thay vì dựng một cây thứ hai song song, vì `DatabaseTreeOutlineCoordinator` đã cache
node theo `id: String` (`nodeCache`, `childrenCache`).

Thêm:

```swift
case connectionRoot                       // "My Connections"
case folder(ConnectionGroup)
case connection(DatabaseConnection)
```

kèm id factory tương ứng (`folderId(_:)`, `connectionId(_:)`) và mở rộng `isExpandable`.

Quan trọng: mọi id của node dưới connection phải **có tiền tố connectionId**, nếu không hai
connection cùng có database tên `mysql` sẽ đụng key trong `nodeCache`/`childrenCache` và trong
`WindowSidebarState.expandedTreeDatabases` (đang là `Set<String>` chỉ chứa tên database). Đây là
thay đổi bắt buộc, không phải tuỳ chọn.

State mới `ConnectionTreeState` (@MainActor @Observable, singleton):
- `expandedFolderIds: Set<UUID>`
- `expandedConnectionIds: Set<UUID>` — khôi phục ở mức hiển thị, **không** kéo theo kết nối
  (red team C2, chi tiết ở Phase 5)
- `selectedNodeId: String?`
- `activeConnectionId: UUID?` — connection đang chọn trong cây, dùng cho thanh dưới sidebar ở Phase 4
- persist qua UserDefaults key `com.SchemaStudio.sidebar.connectionTree`

Vì `ConnectionTreeState` là app-level singleton và `@Observable`, mọi sidebar ở mọi tab window
cùng đọc một instance nên tự đồng bộ.

### Đơn vị selection phải mang connectionId (red team C1)

Selection hiện đi bằng `TableInfo` trần: `WindowSidebarState.selectedTables: Set<TableInfo>`
(`WindowSidebarState.swift:28`), mà `TableInfo.id` chỉ là `schema.name_type`, không có database lẫn
connection (`TablePro/Models/Query/QueryResult.swift:83-94`). Batch operation còn tệ hơn: nó nhận
tên bảng dạng chuỗi (`SidebarView.swift:375` → `viewModel.batchToggleTruncate(tableNames:)`).

Hệ quả nếu giữ nguyên: hai connection cùng có `public.users` thì chọn một dòng sẽ sáng cả hai, và
truncate/delete có thể áp lên connection sai. Đây là mất dữ liệu, không phải lỗi hiển thị.

Bắt buộc trong phase này:
- `selectedTables` đổi sang `Set<DatabaseTreeTableRef>` (ref đã có connectionId sau bước 2), hoặc
  một `SelectedTableRef` tương đương. Không giữ `Set<TableInfo>`.
- `pendingTruncates` / `pendingDeletes` và toàn bộ API batch nhận `(connectionId, tên bảng)`, không
  nhận chuỗi tên trần.
- Cập nhật hết call site trong cùng commit (rule "atomic API changes"): `SidebarView`,
  `SidebarViewModel`, `MainSplitViewController`, `SidebarContextMenu`, `DatabaseTreeOutlineCoordinator`.

State theo connection giữ nguyên: `SharedSidebarState.forConnection(id)` và
`SidebarViewModel.shared(connectionId:)` vẫn là registry theo connectionId, đúng như hiện tại.
`WindowSidebarState` giữ vai trò selection theo window, nhưng khoá expand của nó phải đổi sang có
connectionId (xem bên dưới).

## Related Code Files

- Modify: `TablePro/Views/Sidebar/DatabaseTreeNode.swift` — thêm 3 case và id factory có tiền tố connectionId
- Create: `TablePro/Models/UI/ConnectionTreeState.swift` — state cấp app
- Create: `TablePro/Views/Sidebar/ConnectionTreeBuilder.swift` — hàm thuần dựng node folder/connection từ `ConnectionGroup` + `DatabaseConnection`, tái dùng `buildGroupTree`
- Modify: `TablePro/Models/UI/WindowSidebarState.swift` — `expandedTreeDatabases`, `expandedTreeDatabaseSchemas`, `expandedTreeTables` phải kèm connectionId; `PersistedExpansion` cần version/migration hoặc bỏ giá trị cũ
- Read-only tham chiếu: `TablePro/Models/Connection/ConnectionGroupTree.swift`, `TablePro/ViewModels/WelcomeViewModel.swift`
- Create: `TableProTests/Views/Sidebar/ConnectionTreeBuilderTests.swift`
- Create: `TableProTests/Models/ConnectionTreeStateTests.swift`

## Implementation Steps

1. Mở rộng `DatabaseTreeNode.Kind` với `connectionRoot`, `folder`, `connection`; cập nhật
   `isExpandable`; thêm `var connectionId: UUID?` phân giải từ kind.
2. Đổi mọi id factory dưới connection sang dạng có tiền tố: `databaseId(connectionId:database:)`,
   `schemaId(connectionId:database:schema:)`, `tableId(connectionId:ref:)`, v.v. Cập nhật hết
   call site trong `DatabaseTreeOutlineCoordinator`.
3. Viết `ConnectionTreeBuilder.build(groups:connections:filter:)` trả `[DatabaseTreeNode]`, tái
   dùng `buildGroupTree` để không nhân đôi luật sắp xếp/`sortOrder`/depth.
4. Viết `ConnectionTreeState` với persist + load, dùng `didSet` giống `WindowSidebarState`.
5. Thêm connectionId vào khoá expand trong `WindowSidebarState`; bump `PersistedExpansion` sang
   phiên bản mới, dữ liệu cũ decode không được thì bỏ qua (mất trạng thái expand một lần, chấp
   nhận được, không cần shim).
6. Đổi `WindowSidebarState.selectedTables` sang ref có connectionId; đổi pending set sang
   `[UUID: Set<String>]`; cập nhật mọi call site trong cùng commit.
7. Đăng ký file mới và file đã xoá vào `SchemaStudio.xcodeproj/project.pbxproj` (repo này commit
   pbxproj, không dùng XcodeGen). Build sạch từ clone mới trước khi coi phase là xong.
8. Viết unit test: cây rỗng, folder lồng 3 cấp, connection không thuộc folder nào, folder có
   `parentId` trỏ tới group đã xoá (đường `validGroupIds` trong `buildGroupTree`), search filter,
   persist/restore của `ConnectionTreeState`, và **hai connection có bảng trùng tên schema.bảng thì
   selection cùng pending set không lẫn nhau**.

## Success Criteria

- [ ] `ConnectionTreeBuilder` dựng đúng cây folder/connection, khớp thứ tự với Welcome
- [ ] Hai connection có database trùng tên không đụng id node
- [ ] `ConnectionTreeState` persist và restore đúng qua UserDefaults
- [ ] Selection và pending truncate/delete mang connectionId; hai connection có `public.users`
      không lẫn selection và không thể truncate nhầm nhau
- [ ] Unit test phủ 7 trường hợp ở bước 8, tất cả xanh
- [ ] File mới/xoá đã vào pbxproj; clone mới build được
- [ ] Không file nào vượt ngưỡng SwiftLint; build sạch

## Risk Assessment

- **Đổi id factory chạm nhiều call site trong coordinator.** Làm trong cùng một commit với việc
  đổi khoá `WindowSidebarState` (rule "atomic API changes"), không tách.
- **Mất trạng thái expand cũ của người dùng** khi đổi format persist. Chấp nhận, không viết shim
  tương thích ngược (nguyên tắc "no hacky solutions").
