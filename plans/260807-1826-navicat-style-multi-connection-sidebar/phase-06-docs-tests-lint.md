---
phase: 6
title: "Docs, tests, lint"
status: pending
priority: P1
effort: "0.5-1d"
dependencies: [5]
---

# Phase 6: Docs, tests, lint

<!-- Updated: Validation Session 1 - đổi số từ Phase 5; thêm docs hai đường mở tab và đo tải health monitor -->


## Overview

Đóng các cổng bắt buộc của repo: UI automation cho luồng chính, tài liệu Mintlify, CHANGELOG,
localization, lint, và đo lại hiệu năng mở tab.

## Requirements

Functional:
- UI test phủ luồng expand connection → connect → mở bảng → tab đúng connection.
- Docs mô tả sidebar mới và hành vi tab group.

Non-functional:
- `swiftlint lint --strict` sạch; `swiftformat .` không tạo diff.
- Không có chuỗi user-facing nào thiếu `String(localized:)`.

## Related Code Files

- Create: `TableProUITests/MultiConnectionSidebarUITests.swift`
- Modify: `docs/features/` — trang mô tả sidebar và quản lý connection
- Modify: `docs/customization/settings.mdx` — làm rõ "Group all connections in one window" sau thay đổi Phase 4
- Modify: `CHANGELOG.md` — mục `[Unreleased]` → `Added` / `Changed`
- Modify: các file đã tạo ở Phase 1-5 nếu lint hoặc localization phát hiện thiếu sót

## Implementation Steps

1. Viết UI test luồng chính. Với bước cần server thật, dùng SQLite (driver bundled, không cần
   server ngoài) để test chạy tất định.
2. Rà mọi chuỗi mới: dùng `String(localized:)` trong computed property/AppKit/alert; không dùng
   nội suy chuỗi trong `String(localized:)` mà dùng `String(format:)`.
3. Cập nhật docs Mintlify: cây connection, connect/disconnect trên cây, và **hai đường mở tab**:
   mở từ cây luôn vào cùng tab group, mở từ Welcome/menu vẫn theo setting "Group all connections in
   one window". Nói rõ luôn: đóng tab cuối của một connection đang expand không ngắt kết nối.
4. CHANGELOG: một dòng cho mỗi thay đổi hướng người dùng, không nêu tên file/class. Nhớ cả mục
   `Removed` cho dropdown connection cũ nếu nó từng hiện diện với người dùng (kiểm tra lịch sử; nếu
   chưa từng hiện thì không ghi).
5. Kiểm tra pbxproj lần cuối: clone sạch repo vào thư mục tạm, chạy `scripts/download-libs.sh` rồi
   build. Repo này commit `SchemaStudio.xcodeproj/project.pbxproj`, nên file quên đăng ký chỉ lộ ra
   ở máy khác hoặc CI.
6. `swiftlint lint --strict`, `swiftformat .`, rồi chạy test đầy đủ.
7. Đo lại `[open] WindowManager.openTab done ... elapsedMs` trong log so với trước khi refactor; nếu
   xấu đi rõ rệt thì tìm nguyên nhân gốc, không nới ngưỡng. Đo thêm thời gian khởi động app với 10
   connection đã lưu (không cái nào tự connect theo quy tắc Phase 5), và tải của
   `ConnectionHealthMonitor` khi 10 connection cùng expand và cùng connected (ping 30s mỗi session)
   — session nay sống lâu hơn trước vì cây giữ chúng.
8. Chạy bộ lọc văn phong trước khi commit:
   `git diff --cached -U0 | grep -nE '—|seamless|robust|comprehensive|intuitive|effortless|streamlined|leverage|elevate|delve|utilize|facilitate'`

## Success Criteria

- [ ] UI test luồng expand → connect → mở bảng xanh và tất định
- [ ] `swiftlint lint --strict` không cảnh báo; `swiftformat .` không đổi file
- [ ] `xcodebuild -project SchemaStudio.xcodeproj -scheme SchemaStudio test -skipPackagePluginValidation` xanh
- [ ] Docs và CHANGELOG cập nhật, không có từ cấm và không có em dash
- [ ] Thời gian mở tab không xấu đi so với trước refactor
- [ ] Clone sạch build được (pbxproj đầy đủ)

## Risk Assessment

- **UI test dễ flaky** nếu phụ thuộc server ngoài. Dùng SQLite và tránh chờ theo thời gian cố định.
- **CHANGELOG**: không thêm mục "Fixed" cho thứ hỏng rồi sửa trong chính đợt chưa phát hành; gộp
  vào Added/Changed.
