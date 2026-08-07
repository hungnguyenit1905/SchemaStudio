<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="SchemaStudio">
</p>

<h1 align="center">SchemaStudio</h1>

<p align="center">
  面向开发者的快速、原生数据库客户端。<br>
  免费开源。
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">官网</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">文档</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases">下载</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases/latest"><img src="https://img.shields.io/github/v/release/hungnguyenit1905/SchemaStudio" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.md">English</a>
  <a href="README.vi.md">Tiếng Việt</a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/app-light.png">
    <img alt="SchemaStudio 原生数据库客户端,带 SQL 编辑器和数据网格" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## 关于

SchemaStudio 是我心目中的 TablePlus:原生、快速、开源。

每个平台都用原生框架构建。没有 Electron,没有 JDBC,没有 JavaScript 运行时。冷启动不到 1 秒,空闲约 80 MB 内存。通过原生驱动连接所有主流 SQL 和 NoSQL 数据库。

AI 内置:聊天、行内建议,以及 MCP 服务器,让 Cursor、Raycast 或 Claude Desktop 直接和你的数据库对话。使用你自己的 API key,选你喜欢的服务商,或本地跑 Ollama。

## 为什么选 SchemaStudio

目前 macOS 原生数据库客户端可分三类:

- **单数据库,开源**:Sequel Ace(仅 MySQL)、Postico(仅 PostgreSQL)。只用一种引擎的话很合适。
- **多数据库,闭源**:TablePlus。流畅且原生,但是专有软件。
- **多数据库,非原生**:DBeaver(JVM)、Beekeeper Studio 和 DBGate(Electron)。跨平台,但启动慢且占内存。

SchemaStudio 补上缺失的第四类:原生、多数据库、开源。

## 平台支持

| 平台 | 状态 |
|------|------|
| macOS 14+ | 稳定版 |
| iOS / iPadOS 18+ | 稳定版 |
| Linux | 开发中 |

## 支持的数据库

| 数据库 | 分发方式 |
|--------|---------|
| MySQL | 内置 |
| MariaDB | 内置 |
| PostgreSQL | 内置 |
| Amazon Redshift | 内置 |
| CockroachDB | 内置 |
| SQLite | 内置 |
| ClickHouse | 内置 |
| Redis | 内置 |
| Microsoft SQL Server | 插件 |
| MongoDB | 插件 |
| Oracle Database | 插件 |
| DuckDB | 插件 |
| Cassandra / ScyllaDB | 插件 |
| Etcd | 插件 |
| Cloudflare D1 | 插件 |
| DynamoDB | 插件 |
| BigQuery | 插件 |
| libSQL / Turso | 插件 |

内置驱动随应用一起发布。插件驱动按需安装,需先在设置中配置插件仓库 URL。

## 主要功能

- SQL 编辑器:自动补全、多光标、Vim 模式、语法主题
- 数据网格:行内编辑、排序、过滤、撤销/重做
- 原生窗口标签、多窗口、分屏
- SSH 隧道(密码和密钥认证)、SSL/TLS
- 查询历史全文搜索
- AI 聊天、行内建议、Explain/Optimize
- MCP 服务器和 URL scheme:Raycast、Cursor、Claude Desktop
- 插件系统:用 Swift 自己写数据库驱动

## 安装

从 [GitHub Releases](https://github.com/hungnguyenit1905/SchemaStudio/releases) 下载最新的 DMG。

暂无 Homebrew cask。

## 文档

完整文档见 [`docs/`](docs/) 目录。

## 支持开发

应用在 AGPLv3 下免费。本分支不出售许可证;它所基于的上游项目是 [TablePro](https://github.com/TableProApp/TablePro)。

## 赞助者

感谢这些为 SchemaStudio 提供支持的朋友们:

**[SimpleLocalize](https://simplelocalize.io)** · **[CodeRabbit](https://coderabbit.ai)** · **[Nimbus](https://getnimbus.io)** · **[Visnalize](https://visnalize.com)** · **[Dwarves Foundation](https://dwarves.foundation/)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com)** · **[Unikorn](https://unikorn.vn)**

## Star History

<a href="https://www.star-history.com/?repos=hungnguyenit1905%2FSchemaStudio&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
 </picture>
</a>

## 许可证

本项目采用 [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE) 许可。

贡献者需签署贡献者许可协议(CLA)。详见 [CLA.md](CLA.md)。
