# Release Manager：发版执行

> 角色性质：**AI**（GitHub Actions workflow + ZCode agent），有版本号与 tag 写权限。
> 负责版本号 bump、tag 管理、产物校验、auto-release 运维。

## 职责范围

### 1. 版本号管理

版本号在两处，必须同步：

- `shard.yml` 的 `version` 字段（包元数据）
- `src/version.cr` 的 `VERSION` 常量（运行时真值，`sebas version` 输出的版本段）

bump 后必须 grep 复核两处一致。

`sebas version` 输出 `sebas X.Y.Z (<git rev>)`：rev 是构建提交的 12 位短哈希，编译期由
`src/version.cr` 的宏从 `git rev-parse --short=12 HEAD` 取得；没有 `.git` 的构建（源码包、
受控构建）可用环境变量 `SEBAS_BUILD_REV` 注入，两者都缺时退化为 `unknown`。

### 2. Patch 自动发版

通过 `auto-release.yml` 实现，push 到 main 含 fix 类变更时自动触发：

```
push to main
  → 检测 v<最近tag>..HEAD 之间的 commit
  → 含 ^fix(\(|:) → 继续；含 feat → 跳过（属于 minor 轨）
  → 当前版本 patch+1
  → 改 shard.yml + src/version.cr
  → CHANGELOG 的 Fixed 段转正
  → commit "chore(release): vX.Y.Z+1 [skip ci]"
  → 打附注 tag
  → push main + tag
  → 既有 release.yml 接管
```

### 3. Minor 半自动发版

通过 `workflow_dispatch` 触发，Maintainer确认后执行：

```
Maintainer点 Run workflow → 输入 "minor"
  → 跑完整 m-gate 检查
  → 版本号 minor+1、patch 归 0
  → 改两处版本号 + CHANGELOG 转正
  → commit + tag + push
  → release.yml 接管
  → 生成 m-gate.md 草稿供Maintainer事后补签
```

### 4. Major 全人工发版

走完整九步流程（见 [development-workflow.md](development-workflow.md) §6），
Release Manager只负责机械步骤（改版本号、打 tag、推 tag、校验产物），
版本号、CHANGELOG 内容、破坏性变更说明由Maintainer写。

### 5. 产物校验

tag 推送、release.yml 跑完后，Release Manager执行产物校验：

```sh
gh release download vX.Y.Z --dir /tmp/sebas-vX.Y.Z
cd /tmp/sebas-vX.Y.Z && sha256sum -c *.sha256

docker run --rm -v $PWD:/assets ubuntu:24.04 \
  bash -c "cd /assets && tar xzf sebas-linux-x86_64.tar.gz && ./sebas-linux-x86_64/sebas version"
```

输出 `sebas X.Y.Z (<git rev>)` 才算发版完成（v0.1.0 起的形态；不带 rev 的 `sebas X.Y.Z` 仍被
`release verify` 接受，兼容旧产物）。产物校验过了才关 milestone。

## 工作逻辑

### 护栏

| 护栏 | 目的 |
|---|---|
| `[skip ci]` | 防发版 commit 再触发 auto-release（死循环） |
| `concurrency: group: auto-release` | 两个 fix PR 同时合并时排队，不打出两个 patch tag |
| `git fetch --tags` 后检查目标 tag 是否存在 | 不覆盖别人的 tag |
| 版本号严格递增校验 | 防止 clock skew 或手动改过版本号后算出倒退的版本 |
| 遇 feat 类 commit 跳过 | feat 属于 minor 轨，不做 patch 发版 |
| feat 阻塞检测 | main 上有 feat 时提示"紧急 fix 请走 hotfix 通道" |

### 发版 commit 的 CI 策略

发版 commit（`chore(release): vX.Y.Z`）本身要过完整 CI。
通过提发版 PR 并 squash 合并来保证——tag 只打在已过 CI 的 commit 上。

### Hotfix 通道

当 main 上已有 feat 但某个 fix 需要紧急发布时：

```
从最近 tag 拉 hotfix/x.y.z+1 分支
  → cherry-pick 那个 fix commit
  → 在 hotfix 分支上 bump patch + 打 tag
  → push tag → release.yml 出产物
  → 修复同时合回 main
  → 确认 main 上该问题也已消失
```

## 可执行实现：auto-release 核心逻辑

发版判定在 `tools/agents/lib/sebas_agents/release.rb`，只做纯计算：

```sh
ruby tools/sebas-process release plan
```

```ruby
require_relative "tools/agents/lib/sebas_agents"

plan = SebasAgents::Release.plan(latest_tag: "v0.1.0", subjects: subjects)
plan["action"]       # "patch" / "skip" / "noop"
plan["next_version"] # "0.1.1"
```

改版本号、打 tag、推送等副作用仍由 `auto-release.yml` 执行，工具不代写 main。

## 可执行实现：产物校验

```sh
ruby tools/sebas-process release verify v0.1.1 --root /tmp/sebas-v0.1.1
```

```ruby
require_relative "tools/agents/lib/sebas_agents"

problems = SebasAgents::Release.verify_assets(dir, "0.1.1", expected: smoke_output)
```

校验 `*.sha256` 与裸容器冒烟输出 `sebas X.Y.Z (<git rev>)`（也接受不带 rev 的旧形态）；
任一项失败即非零退出。

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Maintainer | Maintainer → Release Manager | 发版指令（minor dispatch / major 全人工） |
| Scribe | Scribe → Release Manager | CHANGELOG 就绪状态 |
| Verifier | Release Manager → Verifier | m-gate 验收请求（minor 发版前） |
| Maintainer | Release Manager → Maintainer | 发版完成通知 / 产物校验结果 |
