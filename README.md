<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="SchemaStudio">
</p>

<h1 align="center">SchemaStudio</h1>

<p align="center">
  A fast, native database client for developers.<br>
  Free and open source.
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">Website</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio">Docs</a> ·
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases">Download</a> ·
  <a href="https://discord.gg/hCNmUUbnD4">Discord</a>
</p>

<p align="center">
  <a href="https://github.com/hungnguyenit1905/SchemaStudio/releases/latest"><img src="https://img.shields.io/github/v/release/hungnguyenit1905/SchemaStudio" alt="Release"></a>
  <a href="https://www.gnu.org/licenses/agpl-3.0"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg" alt="License: AGPL v3"></a>
</p>

<p align="center">
  <a href="README.vi.md">Tiếng Việt</a>
  <a href="README.zh.md">简体中文</a>
</p>

---

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/app-dark.png">
    <source media="(prefers-color-scheme: light)" srcset=".github/assets/app-light.png">
    <img alt="SchemaStudio database client with SQL editor and data grid" src=".github/assets/app-light.png" width="800">
  </picture>
</p>

## About

SchemaStudio is what I wanted TablePlus to be: native, fast, open source.

Built with native frameworks on every platform. No Electron, no JDBC, no JavaScript runtime. Cold start under 1 second, idle around 80 MB RAM. Connects to all major SQL and NoSQL databases through native drivers.

AI is built in: chat, inline suggestions, and an MCP server that lets Cursor, Raycast, or Claude Desktop talk to your databases. Bring your own API key, pick your own provider, or run local with Ollama.

## Why SchemaStudio

Native macOS database clients today fall into three groups:

- **Single-database, open source**: Sequel Ace (MySQL only), Postico (PostgreSQL only). Great if you live in one engine.
- **Multi-database, closed source**: TablePlus. Polished and native, but proprietary.
- **Multi-database, not native**: DBeaver (JVM), Beekeeper Studio and DBGate (Electron). Cross-platform, but slow to start and heavy on memory.

SchemaStudio is the missing fourth: native, multi-database, and open source.

## Platforms

| Platform | Status |
|----------|--------|
| macOS 14+ | Stable |
| iOS / iPadOS 18+ | Stable |
| Linux | In development |

## Supported Databases

| Database | Distribution |
|----------|--------------|
| MySQL | Built-in |
| MariaDB | Built-in |
| PostgreSQL | Built-in |
| Amazon Redshift | Built-in |
| CockroachDB | Built-in |
| SQLite | Built-in |
| ClickHouse | Built-in |
| Redis | Built-in |
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

Built-in drivers ship with the app. Plugin drivers install on demand, and need a plugin registry URL configured in Settings first.

## What's inside

- SQL editor with autocomplete, multi-cursor, Vim mode, syntax themes
- Data grid with inline editing, sort, filter, undo/redo
- Native window tabs, multi-window, split panes
- SSH tunnels with password and key authentication, SSL/TLS
- Query history with full-text search
- AI chat, inline suggestions, and Explain/Optimize
- MCP server and URL scheme for Raycast, Cursor, Claude Desktop
- Plugin system, write your own database driver in Swift

## Install

Download the latest DMG from [GitHub Releases](https://github.com/hungnguyenit1905/SchemaStudio/releases).

There is no Homebrew cask yet.

## How to Build

Building SchemaStudio requires macOS 14 or later and Xcode 15 or later.

Run the first-time setup from the repository root:

```bash
scripts/download-libs.sh
touch Secrets.xcconfig
```

Build a Debug app without code signing:

```bash
xcodebuild \
  -project SchemaStudio.xcodeproj \
  -scheme SchemaStudio \
  -configuration Debug \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app is written to `~/Library/Developer/Xcode/DerivedData/SchemaStudio-*/Build/Products/Debug/SchemaStudio.app`.

To build and run a signed app, configure your personal Apple team, a unique bundle identifier, and the Debug entitlements in Xcode. See [Building with a personal Apple team](CONTRIBUTING.md#building-with-a-personal-apple-team) for the required settings.

## Documentation

Full docs live in [`docs/`](docs/).

## Support development

The app is free under AGPLv3. This fork sells no licenses; the upstream project it forks from is [TablePro](https://github.com/TableProApp/TablePro).

## Sponsors

Thanks to these amazing people for supporting SchemaStudio:

**[SimpleLocalize](https://simplelocalize.io)** · **[CodeRabbit](https://coderabbit.ai)** · **[Nimbus](https://getnimbus.io)** · **[Visnalize](https://visnalize.com)** · **[Dwarves Foundation](https://dwarves.foundation/)** · **[Huy TQ](https://github.com/imhuytq)** · **[Xermius](https://xermius.com)** · **[Unikorn](https://unikorn.vn)**

## Star History

<a href="https://www.star-history.com/?repos=hungnguyenit1905%2FSchemaStudio&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=hungnguyenit1905/SchemaStudio&type=date&legend=top-left" />
 </picture>
</a>

## License

This project is licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).

Contributions require signing a Contributor License Agreement (CLA). See [CLA.md](CLA.md) for details.
