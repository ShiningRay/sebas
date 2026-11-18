# M0 门禁演练记录（M0-WP8 · M-gate 证据）

> 日期：2026-11-19。环境：Windows 10 x64、Crystal 1.22.1（x86_64-w64-windows-gnu）。
> 依据 design.md §14 M0 验收三条与 development-plan.md M0-WP8。每条均有可复现 spec。

## M0 验收勾稽（design.md §14 L749 三条）

### 1. 收发消息全链路 ✅

`crystal spec spec/platform/cli/gateway_spec.cr -e "runs the full loop"`

- 链路：InboundMessage 入总线 → bus consumer → per-session worker 池 →
  intent 落库（requestId）→ FakeProvider turn → checkpoint(phase 1) →
  message.send（幂等键 `send:test-acc:evt-e2e-1`）→ SMTP 出站 →
  转录双写（user+agent）→ intent=done、task=done。
- 断言：假 SMTP 收到一封，收件人=peer、正文=provider 回复；
  `agent:main:test-acc:email:alice@example.com` 转录角色序 ["user","agent"]。

### 2. 强制杀进程后重启续跑 ✅

`make drill`（构建 release → 跑演练 spec）

- **进程级强杀**：`bin/sebas.exe crashwrite` 子进程写 intent+task+checkpoint(phase 1)
  并挂起 → 父进程 `taskkill /F /PID`（Windows kill -9 口径）→
  重开存储：intent=pending、task=running、phase=1 → `recover!` →
  interrupted 列表含 `turn:evt-crash`（从最近 checkpoint 续跑）。
- **重启重放**：第一进程 intent=dispatched 即「崩溃」→ 第二进程
  `replay_unfinished` → 继续 dispatch → 发信一次 → intent=done。

### 3. 发信幂等键生效（重复投递不重发）✅

`crystal spec spec/tools/executor_spec.cr` + `-e "does not re-deliver"`

- message.send 派生幂等键 `send:<account_id>:<event_id>`；
  intent memo → 效应 → done memo 三明治；
- 同 requestId 二次投递：memo=done → 返回既有结果，适配器只收到一次；
- 崩溃残留 intent memo：fail-closed 返回 interrupted，不重发；
- 发送失败：memo=failed，允许上层重试（重试≠重放重复投递）。

## 门禁三命令（本记录时点）

| 命令 | 结果 |
|---|---|
| `crystal spec` | 52 examples, 0 failures |
| `./bin/ameba` | 0 failures（47 files） |
| `make release` | bin/sebas.exe 构建成功，`--version`/`gateway`/`crashwrite` 可用 |

## 已知环境边界（沙箱口径）

- ZCode 沙箱下，项目外目录（如 %TEMP%）由 spec 进程创建 SQLite 库可用；
  但 **exe 位于 bin/ 时对项目外绝对路径建库受限（sqlite CANTOPEN）**——
  演练子进程因此使用 `chdir: 项目内 tmp-drill-*` + 相对路径（生产部署无沙箱不受影响，
  /tmp 下同一 exe 绝对路径验证通过）。

## 外部依赖未清项（E.1）

- M0-WP4 真实邮箱集成验收（IMAP IDLE 收信/SMTP 发信对真实服务）：等待用户提供
  测试邮箱（应用专用密码）——协议层已按假服务器全链路验证。
