# Release Manager：发版执行

> 角色性质：**AI**（GitHub Actions workflow + ZCode agent），有版本号与 tag 写权限。
> 负责版本号 bump、tag 管理、产物校验、auto-release 运维。

## 职责范围

### 1. 版本号管理

版本号在两处，必须同步：

- `shard.yml` 的 `version` 字段（包元数据）
- `src/version.cr` 的 `VERSION` 常量（运行时真值，`sebas version` 输出）

bump 后必须 grep 复核两处一致。

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

输出 `sebas X.Y.Z` 才算发版完成。产物校验过了才关 milestone。

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

## 伪代码：auto-release 核心逻辑

```pseudo
function auto_release():
  # 只响应 main 上的 push
  assert github.ref == "refs/heads/main"

  # 取最近 tag
  latest_tag = git_describe_tags_abbrev0()
  current_version = parse_semver(latest_tag)  # 如 0.1.0

  # 检测变更类型
  commits = git_log("#{latest_tag}..HEAD", oneline=true)
  has_fix = commits.any? { |c| c =~ /^fix(\(|:)/ }
  has_feat = commits.any? { |c| c =~ /^feat(\(|:)/ }

  if has_feat:
    log("检测到 feat 类变更，跳过 patch 发版（属于 minor 轨）")
    if has_fix:
      log("警告：fix 被 feat 阻塞，紧急修复请走 hotfix 通道")
    return

  if !has_fix:
    log("无 fix 类变更，不发版")
    return

  # 版本号递增
  new_version = bump_patch(current_version)  # 0.1.0 → 0.1.1

  # 护栏
  assert new_version > current_version  # 严格递增
  git_fetch_tags()
  assert !tag_exists("v#{new_version}")  # tag 未占用

  # 改版本号两处
  update_file("shard.yml", "version: #{new_version}")
  update_file("src/version.cr", "VERSION = \"#{new_version}\"")
  assert grep("shard.yml", new_version) && grep("src/version.cr", new_version)

  # CHANGELOG 转正
  promote_unreleased("CHANGELOG.md", new_version, today())

  # 提交 + tag + push
  git_commit("chore(release): v#{new_version} [skip ci]")
  git_tag_annotated("v#{new_version}", "v#{new_version}")
  git_push("main", "v#{new_version}")

  log("已推送 tag v#{new_version}，release.yml 将自动构建")

  # 等 release.yml 跑完
  wait_for_workflow("release.yml", ref="v#{new_version}")

  # 产物校验
  verify_release_assets(new_version)

  log("v#{new_version} 发版完成")
```

## 伪代码：产物校验

```pseudo
function verify_release_assets(version):
  dir = "/tmp/sebas-v#{version}"
  gh_release_download("v#{version}", dir=dir)

  # sha256 校验
  for sidecar in glob("#{dir}/*.sha256"):
    result = run("cd #{dir} && sha256sum -c #{sidecar}")
    if result.exit_code != 0:
      raise "sha256 校验失败：#{sidecar}"

  # Linux 裸容器冒烟
  result = docker_run(
    image="ubuntu:24.04",
    volume="#{dir}:/assets",
    command="cd /assets && tar xzf sebas-linux-x86_64.tar.gz && ./sebas-linux-x86_64/sebas version"
  )
  if result.stdout.strip() != "sebas #{version}":
    raise "裸容器冒烟失败：期望 'sebas #{version}'，得到 '#{result.stdout}'"

  log("产物校验通过：sha256 全过 + 裸容器可运行")
```

## 与其他角色的交互

| 交互方 | 方向 | 内容 |
|---|---|---|
| Maintainer | Maintainer → Release Manager | 发版指令（minor dispatch / major 全人工） |
| Scribe | Scribe → Release Manager | CHANGELOG 就绪状态 |
| Verifier | Release Manager → Verifier | m-gate 验收请求（minor 发版前） |
| Maintainer | Release Manager → Maintainer | 发版完成通知 / 产物校验结果 |
