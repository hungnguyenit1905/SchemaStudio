<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="SchemaStudio">
</p>

<h1 align="center">SchemaStudio</h1>

<p align="center">
  Database client nhanh, native cho lập trình viên.<br>
  Miễn phí và mã nguồn mở.
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">Website</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">Tài liệu</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases">Tải xuống</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases/latest"><img src="https://img.shields.io/github/v/release/hungnguyenit1905/SchemaStudio" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
  <a href="README.zh.md">简体中文</a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/app-light.png">
    <img alt="SchemaStudio database client native với SQL editor và data grid" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## Giới thiệu

SchemaStudio là TablePlus mà tôi luôn muốn có: native, nhanh, mã nguồn mở.

Viết bằng framework native cho từng nền tảng. Không Electron, không JDBC, không JavaScript runtime. Khởi động dưới 1 giây, chạy nền khoảng 80 MB RAM. Kết nối tới hầu hết các database SQL và NoSQL qua driver native.

AI tích hợp sẵn: chat, gợi ý inline, và MCP server để Cursor, Raycast hay Claude Desktop nói chuyện trực tiếp với database của bạn. API key bạn tự cấp, provider bạn tự chọn, hoặc chạy local với Ollama.

## Vì sao chọn SchemaStudio

Database client native trên macOS hiện chia làm ba nhóm:

- **Một database, mã nguồn mở**: Sequel Ace (chỉ MySQL), Postico (chỉ PostgreSQL). Hợp nếu bạn chỉ làm một engine.
- **Đa database, đóng nguồn**: TablePlus. Mượt và native, nhưng proprietary.
- **Đa database, không native**: DBeaver (JVM), Beekeeper Studio và DBGate (Electron). Chạy được trên mọi OS, nhưng khởi động chậm và ngốn RAM.

SchemaStudio là mảnh thứ tư còn thiếu: native, đa database, và mã nguồn mở.

## Nền tảng

| Nền tảng | Trạng thái |
|----------|-----------|
| macOS 14+ | Ổn định |
| iOS / iPadOS 18+ | Ổn định |
| Linux | Đang phát triển |

## Database hỗ trợ

| Database | Phân phối |
|----------|-----------|
| MySQL | Tích hợp sẵn |
| MariaDB | Tích hợp sẵn |
| PostgreSQL | Tích hợp sẵn |
| Amazon Redshift | Tích hợp sẵn |
| CockroachDB | Tích hợp sẵn |
| SQLite | Tích hợp sẵn |
| ClickHouse | Tích hợp sẵn |
| Redis | Tích hợp sẵn |
| Microsoft SQL Server | Plugin |
| MongoDB | Plugin |
| Oracle Database | Plugin |
| DuckDB | Plugin |
| Beancount | Plugin |
| Cassandra / ScyllaDB | Plugin |
| Etcd | Plugin |
| Cloudflare D1 | Plugin |
| DynamoDB | Plugin |
| BigQuery | Plugin |
| libSQL / Turso | Plugin |

Driver tích hợp sẵn đi kèm app. Driver dạng plugin cài thêm khi cần, và phải cấu hình URL plugin registry trong Cài đặt trước.

## Bên trong có gì

- SQL editor với autocomplete, multi-cursor, Vim mode, theme cú pháp
- Data grid sửa inline, sort, filter, undo/redo
- Tab native trong cửa sổ, đa cửa sổ, split pane
- SSH tunnel (password và key), SSL/TLS
- Lịch sử query tìm kiếm full-text
- AI chat, gợi ý inline, Explain/Optimize
- MCP server và URL scheme cho Raycast, Cursor, Claude Desktop
- Hệ thống plugin, tự viết driver database bằng Swift

## Cài đặt

Tải file DMG mới nhất từ [GitHub Releases](https://github.com/hungnguyenit1905/SchemaStudio/releases).

Chưa có Homebrew cask.

## Tài liệu

Tài liệu đầy đủ nằm trong thư mục [`docs/`](docs/).

## Ủng hộ phát triển

App miễn phí theo AGPLv3. Bản fork này không bán license; dự án gốc mà nó fork từ đó là [TablePro](https://github.com/TableProApp/TablePro).

## Nhà tài trợ

Cảm ơn những người tuyệt vời đã ủng hộ SchemaStudio:

**[SimpleLocalize](https://simplelocalize.io)** · **[CodeRabbit](https://coderabbit.ai)** · **[Nimbus](https://getnimbus.io)** · **[Visnalize](https://visnalize.com)** · **[Dwarves Foundation](https://dwarves.foundation/)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com)** · **[Unikorn](https://unikorn.vn)**

## Star History

<a href="https://www.star-history.com/?repos=hungnguyenit1905%2FSchemaStudio&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
 </picture>
</a>

## Bản quyền

Dự án này cấp phép theo [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Đóng góp cần ký Contributor License Agreement (CLA). Xem [CLA.md](CLA.md) để biết chi tiết.
