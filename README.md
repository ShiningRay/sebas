# Sebas

**A local-first, multi-account orchestration platform for personal agents — shipped as a single Crystal binary.**

Sebas binds several accounts per channel (multiple mailboxes, multiple WeCom companies,
multiple Lark/Feishu workspaces) on the machine you own, and lets you orchestrate them
with a **trigger → condition → action** model: durable tasks, approvals, budgets, and
hot-reloading configuration without restarting the gateway.

> 中文简介：运行在你自己机器上的 Crystal 单二进制 Personal Agent 平台——同一渠道可绑定 N 个账号，
> 以「触发→条件→动作」编排自动化流程，支持多 agent 协作、配置免重启热更新与插件脚本层。

[![CI](https://github.com/ShiningRay/sebas/actions/workflows/ci.yml/badge.svg)](https://github.com/ShiningRay/sebas/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/crystal-%3E%3D1.22-black)](https://crystal-lang.org)

---

## Contents

- [Why Sebas](#why-sebas)
- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Architecture](#architecture)
- [Project status](#project-status)
- [Development](#development)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Why Sebas

Most personal-agent tooling assumes one account, one channel, and a cloud runtime.
Sebas takes the opposite stance:

| Concern | Sebas approach |
| --- | --- |
| Many accounts, one process | Account / Agent / Binding are orthogonal concepts; routing is an explicit table, not hard-coded per channel. |
| Configuration churn | Validate-then-swap hot reload: an invalid config keeps the previous one running; only socket resources require a restart. |
| Crash safety | Every inbound message is a durable intent; effects sit between intent and result records, so restarts resume instead of duplicating. |
| Automation | Workflows are `trigger → condition → action` with approvals, budgets, leases, and an auditable ledger. |
| Extensibility | A sandboxed script layer keeps custom actions out of the core binary. |
| Your data | Local-first: state lives in SQLite on your machine, secrets live in the OS keyring. |

## Features

- **Channels** — Email (IMAP IDLE / SMTP), WeCom (企业微信), Lark/Feishu; N accounts each.
- **Routing** — Most-specific binding resolution across `channel / account / peer → agent`.
- **Orchestration** — Durable workflow engine with cron, event, webhook, and account triggers;
  conditions; approval center (fail-closed); ledger, budget circuit-breaker, and leases.
- **Hot reload** — File-watch plus IPC reload; components re-apply selectively (data hot-swap,
  listeners flagged as restart-required).
- **Agents** — Multiple agent personas with independent memory, loop-guarded inter-agent messaging,
  subagent concurrency limits.
- **Credentials** — AES-256-GCM vault; master key in the Windows Credential Manager with a
  file fallback on other platforms.
- **Admin surfaces** — Local HTTP + IPC admin API and a terminal UI (NDJSON).

## Requirements

- [Crystal](https://crystal-lang.org/install/) **>= 1.22** and [Shards](https://github.com/crystal-lang/shards)
- A C toolchain plus development headers for **SQLite3**, **OpenSSL**, and **PCRE2**
- Windows, macOS, or Linux

## Install

### Build from source

```sh
git clone https://github.com/ShiningRay/sebas.git
cd sebas
shards install
make release          # -> bin/sebas (bin/sebas.exe on Windows)
```

`shards build sebas` also works if you prefer the Shards default output directory.

### Prebuilt binaries

Starting with `v0.1.0`, release assets are attached to each
[GitHub release](https://github.com/ShiningRay/sebas/releases) for Linux, macOS, and
Windows. Download the archive for your platform, extract it, and run `sebas`.

> On Windows, building needs the MSVC Crystal distribution plus a SQLite3 development
> library (for example `vcpkg install sqlite3`), or an MSYS2 UCRT64 toolchain.

## Quick start

```sh
# 1. Copy and edit the example configuration, and give the agent a persona file
#    (the loader rejects a dangling agents.<name>.persona_file)
cp examples/config.example.yaml config.yaml
mkdir -p agents/main && printf '# main\n\nYou are my personal assistant.\n' > agents/main/SOUL.md

# 2. Export the values referenced by ${...} in the config
export MAIL_USER=you@example.com
export MAIL_PASSWORD=...
export LLM_API_KEY=...

# 3. Run the resident gateway (-c is an alias for --config)
#    Logs go to stderr; a rejected config exits 1 with the reason on stderr.
./bin/sebas gateway --config config.yaml

# Inspect the CLI surface
./bin/sebas --help
```

The gateway:

1. loads and validates the config (an invalid config refuses to start; during reload the old one is kept);
2. opens the SQLite store and replays unfinished intents;
3. binds channel accounts and starts the trigger engine;
4. serves the local admin API and the terminal UI.

Configuration hot reload is on by default — editing `config.yaml` re-applies the change
without restarting the process.

## Configuration

See [`examples/config.example.yaml`](examples/config.example.yaml) for the full shape and
[`docs/design/design.md`](docs/design/design.md) §3.4 for the config tree.

```yaml
channels:
  email:
    accounts:
      - id: personal-mailbox
        platform: imap.example.com
        receive: imap-idle
        smtp: { port: 465, tls: implicit }
        credentials:
          user: ${MAIL_USER}
          password: ${MAIL_PASSWORD}

# Provider layer: vendor-level config (key / base_url / protocol);
# multiple agents share one key by referencing the provider by name
providers:
  deepseek:
    api_key: ${LLM_API_KEY}
    base_url: https://api.deepseek.com
    protocol: openai-compatible   # openai-compatible | anthropic

agents:
  main:
    provider: deepseek
    model: deepseek-chat          # bare model name, no `<provider>/` prefix

bindings:
  - { channel: email, account: personal-mailbox, peer: "*", agent: main }

gateway:
  http: { bind: 127.0.0.1, port: 18790, auth: token }
  ipc: { mode: auto, port: 18791 }
  data_dir: data
```

Secrets are never stored in the config file: `${VAR}` is expanded from the environment,
and provider credentials are served from the encrypted vault (one key per provider,
rotated via hot reload for every referencing agent). The legacy per-agent
`agents.<name>.api_key` + `<provider>/<model>` form still loads with a readable
migration hint logged at startup.

## Architecture

```
src/
  platform/       config, store (SQLite), keys/vault, supervisor, bus, CLI, admin
  channels/       email, wecom, lark + shared rate limiting / markdown
  routing/        binding resolution
  agents/         persona pool, skills, subagents
  orchestration/  DSL, engine, triggers, approvals, ledger, runs view
  tools/          tool registry and executor
  providers/      LLM provider pool (fake provider for tests)
  plugins/        mruby script layer
```

Design documents (Chinese, as-authored) — start at [`docs/design/README.md`](docs/design/README.md):

- [`docs/design/design.md`](docs/design/design.md) — design overview; the 16 chapters live in [`docs/design/spec/`](docs/design/spec/README.md)
- [`docs/design/development-plan.md`](docs/design/development-plan.md) — plan overview; WBS, schedule and gates live in [`docs/design/plan/`](docs/design/plan/README.md)
- [`docs/design/proposals/`](docs/design/proposals/) — approved proposals not yet implemented
- [`docs/design/review/`](docs/design/review/) — milestone gate evidence (`m0-gate.md` … `m3-gate.md`)
- [`docs/design/research/`](docs/design/research/) — prior-art research notes

## Project status

| Milestone | Scope | Status |
| --- | --- | --- |
| M0 | Single-account MVP: email + agent + store + tools + TUI | Gate passed |
| M1 | Multi-account, multi-channel, hot reload, keyring | Gate passed |
| M2 | Orchestration DSL, durable tasks, approvals, budget/lease, ledger | Gate passed |
| M3 | Multi-agent collaboration, loop guard, subagents, plugin sandbox | Gate passed (plugin layer validated as a feasibility study) |

Pre-1.0: APIs and configuration may change between minor releases. See [CHANGELOG.md](CHANGELOG.md).

## Development

```sh
make build     # debug build
make spec      # crystal spec
make lint      # ameba
make release   # optimized build
make format    # crystal tool format
```

The three gates that must stay green (they mirror CI):

```sh
crystal spec
crystal tool format --check
crystal build bin/ameba lib/ameba/bin/ameba.cr && ./bin/ameba
```

CI runs these on **Windows, Linux, and macOS**, then performs a release build and a
crash-recovery drill against the built binary.

## Contributing

Issues and pull requests are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md)
and our [Code of Conduct](CODE_OF_CONDUCT.md) first. `main` is protected: every change
lands through a pull request with green CI.

## Security

See [SECURITY.md](SECURITY.md). Report vulnerabilities privately through GitHub security
advisories; do not open a public issue.

## License

[MIT](LICENSE) © 2026 ShiningRay
