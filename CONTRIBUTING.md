# Contributing to Sebas

Thanks for your interest in Sebas! This document describes how to build, test, and
submit changes. 中文要点见每节末尾的「中文要点」。

## Code of Conduct

By participating you agree to follow our [Code of Conduct](CODE_OF_CONDUCT.md).
*中文要点：参与本项目即表示遵守行为准则。*

## Ways to contribute

- Report bugs and request features through the issue templates.
- Improve documentation, examples, or platform support.
- Send pull requests for open issues — comment first for anything larger than a small fix.

*中文要点：通过 Issue 模板报 bug / 提特性；大改动请先开 Issue 讨论再动手。*

## Development setup

Requirements:

- Crystal **>= 1.19** (see `shard.yml`); CI tracks the latest stable release.
- Shards (bundled with Crystal).
- A C toolchain with `libsqlite3`, OpenSSL, and PCRE2 development headers.
- **Windows**: MSVC build of Crystal + SQLite3 (e.g. `vcpkg install sqlite3`), or MSYS2 UCRT64.

```sh
git clone https://github.com/ShiningRay/sebas.git
cd sebas
shards install
crystal spec
```

*中文要点：需要 Crystal ≥1.19、Shards、带 libsqlite3/OpenSSL/PCRE2 头的 C 工具链；Windows 用 MSVC 版 Crystal + SQLite3，或 MSYS2 UCRT64。*

## Quality gates

Every change must keep the three local gates green — they mirror CI:

```sh
crystal spec            # 0 failures
crystal tool format --check
crystal build bin/ameba lib/ameba/bin/ameba.cr && ./bin/ameba   # 0 issues
```

CI additionally builds the binary in release mode on Windows, Linux and macOS.

*中文要点：提交前本地跑 spec、format --check、ameba 三道门禁（与 CI 一致）；CI 另做三平台 release 构建。*

## Coding conventions

- Follow the existing layout under `src/<layer>/…`; each layer mirrors a chapter of
  `docs/design/design.md`.
- Crystal is formatted by `crystal tool format`; do not hand-format.
- Keep source comments and design docs in Chinese to match the existing corpus;
  public-facing docs (README, CONTRIBUTING, templates) are English-first with Chinese notes.
- Platform-specific code must be guarded by `{% if flag?(:windows) %}` (or the matching
  flag) and compile on all three OSes. Windows-only FFI lives in its own file.
- Tests may not depend on `$TEMP` or other platform-specific environment variables;
  use `Dir.tempdir`.

*中文要点：目录按设计文档分层；用 formatter；平台相关代码用宏 flag 隔离并保证三平台可编译；spec 用 `Dir.tempdir` 而非 `$TEMP`。*

## Commit and pull request flow

1. Branch from `main` (`feat/…`, `fix/…`, `docs/…`).
2. Keep commits focused; write imperative messages, optionally Conventional Commits
   (`feat(orchestration): …`).
3. Open a PR against `main` and fill in the checklist. `main` is protected: PRs require
   a green CI run.
4. Squash-merge by default; the PR author merges once approved.

**CI on your PR.** Linux and Windows jobs run on GitHub-hosted runners, but the macOS job
runs on a **self-hosted** machine for branches in this repository. Because fork pull
requests execute workflow files from the PR branch, every run from an external contributor
waits for a maintainer approval; changes under `.github/` are reviewed especially closely
before approving. Fork PRs otherwise run macOS on a hosted runner.

*中文要点：从 main 开分支；提交信息用 Conventional Commits 风格；main 受保护需 PR + CI 绿灯；默认 squash 合并。macOS job 跑在自托管机器上，外部贡献者的 workflow 需维护者批准后才执行，`.github/` 改动会重点审查；fork PR 的 macOS 走托管 runner。*

## Design-first changes

Large behavioral changes go through a design note under `docs/design/` (see existing
`design.md` chapters and milestone gate records). A PR that changes architecture should
link that note.

*中文要点：架构级改动先在 docs/design 下留设计说明，并在 PR 中链接。*

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).
Do not open a public issue for a suspected vulnerability, and never commit
credentials, tokens, or private keys.

*中文要点：漏洞走私密报告（SECURITY.md），不要开公开 Issue，也不要提交任何凭据。*
