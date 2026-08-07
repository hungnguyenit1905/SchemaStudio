---
phase: 5
title: "Connect lifecycle and connection sync"
status: pending
priority: P1
effort: "2-2.5d"
dependencies: [4]
---

# Phase 5: Connect lifecycle and connection sync

<!-- Updated: Validation Session 1 - đổi số từ Phase 4; thêm luật giữ session cho WindowLifecycleMonitor -->


## Overview

Hoàn thiện vòng đời kết nối ngay trên cây: expand để connect, context menu Connect/Disconnect/
Refresh, hiển thị lỗi trên node, và giữ cây đồng bộ khi connection bị thêm/sửa/xoá ở Welcome.

## Requirements

Functional:
- Expand node connection chưa kết nối **do người dùng thao tác** → connect → nạp database. Đang
  connect thì hiện spinner. Khởi động lại app không tự kết nối bất kỳ connection nào.
- Connect thất bại → node hiện trạng thái lỗi kèm thông báo, có hành động thử lại.
- Collapse node connection **không** ngắt kết nối (giống Navicat); Disconnect là hành động riêng
  trong context menu.
- Đóng window/tab cuối cùng của một connection **không** ngắt kết nối nếu connection đó vẫn đang
  expand trong cây.
- Context menu node connection: Connect, Disconnect, Refresh, Edit Connection (mở form sẵn có),
  New Query.
- Thêm/sửa/xoá connection hoặc folder ở Welcome phản ánh vào sidebar mà không cần restart.

Non-functional:
- Không được vi phạm hợp đồng huỷ kết nối đã ghi trong CLAUDE.md.

## Architecture

### Khôi phục không được kéo theo kết nối (red team C2)

`connectToSession` có thể mở modal hỏi mật khẩu ngay trong luồng connect
(`DatabaseManager+Sessions.swift:81` → `PasswordPromptHelper.prompt`, sheet modal), chưa kể SSH
tunnel, Cloudflare tunnel và CloudSQL proxy. Nếu `expandedConnectionIds` được khôi phục lúc khởi
động và expand kéo theo connect, mở app với 8 connection từng expand sẽ bắn 8 lần connect và xếp
hàng 8 sheet mật khẩu. Navicat không làm vậy.

Quy tắc:
- Khởi động: cây khôi phục hình dạng ở mức hiển thị, mọi node connection về trạng thái
  **collapsed nhưng nhớ** (`ConnectionTreeState` giữ id, coordinator không tự expand).
- Chỉ expand **do người dùng thao tác trong phiên** mới kích hoạt connect.
- Node connection có sẵn session (`activeSessions[id] != nil`) thì expand tự do, không connect lại.
- Không có bất kỳ đường nào cho phép nhiều hơn một sheet mật khẩu chờ cùng lúc; connect được kích
  hoạt tuần tự theo thao tác người dùng, không theo vòng lặp khôi phục.

### Disconnect không được phá state của cây (red team H5)

`disconnectSession` hiện gọi `SharedSidebarState.removeConnection(sessionId)`
(`DatabaseManager+Sessions.swift:387`). Hôm nay vô hại vì window cũng đang biến mất. Sau refactor,
connection vẫn nằm trong cây của **mọi** window sau khi disconnect, nên xoá state object khiến view
còn giữ instance cũ phân kỳ khỏi registry: recent tables, `searchText`, `redisKeyTreeViewModel`
biến mất hoặc quay về giá trị cũ tuỳ view nào giữ tham chiếu nào.

Quy tắc:
- `SharedSidebarState.removeConnection` chỉ được gọi khi connection bị **xoá hẳn**, không gọi khi
  disconnect. Gỡ lời gọi khỏi `disconnectSession`.
- Disconnect giữ nguyên `SharedSidebarState` và `SidebarViewModel`, chỉ xoá metadata phụ thuộc
  session (`DatabaseTreeMetadataService` cho connection đó) và collapse node.
- Kiểm tra `redisKeyTreeViewModel` không rò sang phiên kết nối sau.

### Đóng window cuối không được giết session của cây (validation D1)

`WindowLifecycleMonitor.handleWindowClose` (`WindowLifecycleMonitor.swift:225-239`) đếm số window
còn lại có cùng `connectionId`; về 0 thì `disconnectSession`. Hôm nay đúng, vì không còn window
nghĩa là connection không còn được nhìn thấy ở đâu.

Sau refactor giả định đó sai theo hai hướng. Một connection có thể **đang connected mà chưa từng có
window nào của riêng nó**: user expand connection X từ sidebar của window thuộc connection Y và
chưa mở bảng nào. Và đóng tab cuối của X trong khi X vẫn hiện connected trong cây của mọi window
khác sẽ giết session ngay dưới chân cây, node quay về disconnected không có nguyên nhân nhìn thấy
được.

Quy tắc:
- Điều kiện disconnect đổi thành: không còn window nào của connection đó **và** connection đó không
  nằm trong `ConnectionTreeState.expandedConnectionIds`.
- Session còn lại chỉ chết bằng Disconnect trong context menu, xoá connection, hoặc thoát app.
- Đây là nguồn giữ session thứ hai bên cạnh window; test phải phủ cả hai chiều (expand rồi đóng hết
  tab; collapse rồi đóng hết tab thì phải ngắt).

Connect đi qua `DatabaseManager.connectToSession(_:passwordOverride:sshPasswordOverride:)`. Hàm này
đã: trả sớm nếu session đã có driver (`switchToSession`), mở attempt qua
`connectionAttempts.begin(for:)`, và giải quyết env var. Cây **không** được tự dựng đường connect
riêng.

Hợp đồng huỷ (đã gây bug 4 lần: #1185, #1358, #1369):
- `Task.cancel()` không dừng được driver đang kẹt trong C call. Collapse node giữa lúc connect
  không được coi là "đã huỷ xong".
- Attempt đến muộn phải kiểm tra generation của `ConnectionAttemptRegistry` trước khi nhận driver
  vào `activeSessions`; attempt thua tự `disconnect` driver của nó.
- Node phải phản ánh trạng thái thật từ `DatabaseManager.activeSessions[id]?.status`, không giữ cờ
  loading cục bộ của riêng cây — cờ cục bộ chính là cách bug này tái phát.

Đồng bộ connection: hiện **không có** notification nào cho "danh sách connection đã đổi".
`WelcomeViewModel` sở hữu mảng `connections` và tự gọi `rebuildTree()` (invariant trong CLAUDE.md:
mọi mutation phải gọi `rebuildTree()`, nếu không UI không cập nhật). `SyncChangeTracker` có
`postChangeNotification()` nhưng phục vụ sync, và sync tắt trong fork này.

Cần thêm một `Notification.Name.connectionsDidChange` do `ConnectionStorage` phát sau khi ghi file
(theo đúng thứ tự đã ghi trong invariant: **persist trước, notify sau**). Cả `WelcomeViewModel` và
cây sidebar cùng nghe. Đây là điểm dọn dẹp thật, không phải shim: hiện Welcome cập nhật được chỉ vì
nó là nơi duy nhất sở hữu dữ liệu.

Xoá connection đang mở: dọn `SharedSidebarState.removeConnection(id)`, `SidebarViewModel` registry,
`ConnectionTreeState.expandedConnectionIds`, và ngắt session nếu đang kết nối.

## Related Code Files

- Modify: `TablePro/Core/Storage/ConnectionStorage.swift` — phát `connectionsDidChange` sau khi ghi
- Modify: `TablePro/ViewModels/WelcomeViewModel.swift` — nghe notification thay vì chỉ tự rebuild
- Modify: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+Nodes.swift` — expand → connect
- Modify: `TablePro/Views/Sidebar/Extensions/DatabaseTreeOutlineCoordinator+ContextMenu.swift`
- Modify: `TablePro/Views/Sidebar/ConnectionRowView.swift` — trạng thái lỗi + nút thử lại
- Modify: `TablePro/Models/UI/ConnectionTreeState.swift` — dọn state khi connection bị xoá
- Modify: `TablePro/Core/Services/Infrastructure/WindowLifecycleMonitor.swift` — điều kiện disconnect thêm vế "không đang expand trong cây"
- Read-only: `TablePro/Core/Database/DatabaseManager+Sessions.swift`, `DatabaseManager+Health.swift`
- Create: `TableProTests/Core/Database/TreeConnectLifecycleTests.swift`

## Implementation Steps

1. Thêm `Notification.Name.connectionsDidChange`; phát trong `ConnectionStorage` sau `save`, đúng
   thứ tự persist-rồi-notify. Cho `WelcomeViewModel` và cây cùng nghe.
2. Expand node connection: nếu chưa có session, gọi `connectToSession`, node hiện `.loading`; state
   đọc từ `activeSessions[id]?.status`, không dựng cờ riêng.
3. Xử lý thất bại: node `.error(message)` + hành động thử lại; không xoá cache database cũ nếu
   trước đó đã nạp được (invariant refresh).
4. Context menu: Connect / Disconnect / Refresh / Edit Connection / New Query. Disconnect gọi
   `disconnectSession(_:)` và collapse node.
5. Gỡ `SharedSidebarState.removeConnection` khỏi `disconnectSession`; chuyển lời gọi sang đường xoá
   connection. Disconnect chỉ dọn metadata phụ thuộc session và collapse node.
6. Xử lý connection bị xoá khi đang mở: ngắt session, dọn cả 3 registry và state.
7. Đổi điều kiện disconnect trong `WindowLifecycleMonitor.handleWindowClose`: thêm vế kiểm tra
   `ConnectionTreeState.expandedConnectionIds`. Tách điều kiện thành một hàm thuần có test thay vì
   viết thẳng trong handler.
8. Đăng ký file mới vào pbxproj.
9. Test: connect thành công, connect lỗi, expand rồi collapse giữa lúc connect (attempt đến muộn
   không được ghi đè), xoá connection đang kết nối, thêm connection mới xuất hiện trong cây,
   **khởi động lại với nhiều connection từng expand không phát sinh lời gọi connect nào**,
   disconnect rồi reconnect giữ nguyên recent tables cùng search text, **đóng tab cuối của một
   connection đang expand thì session sống**, và **đóng tab cuối của một connection đã collapse thì
   session ngắt**.

## Success Criteria

- [ ] Expand connection chưa kết nối → spinner → danh sách database
- [ ] Connect lỗi hiện thông báo trên node, thử lại được, không mất dữ liệu đã nạp trước đó
- [ ] Collapse giữa lúc connect không để lại node treo và không tạo session ma
- [ ] Disconnect từ context menu ngắt đúng session, không ảnh hưởng connection khác
- [ ] Thêm/xoá connection ở Welcome cập nhật sidebar ngay
- [ ] Mở lại app với 8 connection từng expand: không connect cái nào, không sheet mật khẩu nào
- [ ] Disconnect rồi reconnect giữ nguyên recent tables và search text của connection đó
- [ ] Đóng tab cuối của connection đang expand: session vẫn sống, node vẫn connected
- [ ] Đóng tab cuối của connection đã collapse: session ngắt như hôm nay
- [ ] Test ở bước 9 xanh

## Risk Assessment

- **Khu vực đã ship cùng một bug bốn lần.** Không viết cơ chế connect mới; chỉ gọi API sẵn có và
  đọc trạng thái từ `DatabaseManager`. Nếu thấy cần cờ loading riêng cho cây, đó là dấu hiệu đang
  đi sai đường.
- **`connectionsDidChange` có thể gây vòng lặp** nếu ai đó ghi trong handler. Handler chỉ đọc và
  rebuild, không ghi.
- **Xoá connection đang mở** dễ để lại registry rác (`SharedSidebarState`, `SidebarViewModel`,
  `MainContentCoordinator.activeCoordinators`). Test riêng cho đường này.
- **Session sống lâu hơn trước.** Cây giữ session nghĩa là connection có thể connected hàng giờ
  không tab nào. `ConnectionHealthMonitor` ping 30s vẫn chạy cho từng session, nên 10 connection
  expand là 10 luồng ping. Đo tải này ở Phase 6; nếu thành vấn đề thì fix ở tầng health monitor,
  không quay lại giết session.
