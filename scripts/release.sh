#!/usr/bin/env bash
# sebas 人工发版脚本（major / minor 用）。
# patch 版本由 .github/workflows/auto-release.yml 全自动处理，不需要此脚本。
#
# 用法：
#   ./scripts/release.sh 0.3.0          # 发布 v0.3.0
#   ./scripts/release.sh --dry-run 0.3.0  # 只校验不实际推送
#
# 流程：前置校验 → 两处版本号 bump → 提示人工确认 CHANGELOG → commit → 附注 tag → push。
# 推送 tag 后 .github/workflows/release.yml 自动构建三平台资产。

set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

NEXT="${1:-}"
if [ -z "$NEXT" ]; then
  echo "用法: $0 [--dry-run] <X.Y.Z>" >&2
  exit 1
fi
if ! [[ "$NEXT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "错误: 版本号必须是 X.Y.Z 三段式（当前: $NEXT）" >&2
  exit 1
fi
# 显式拒绝预发布段（beta/rc 走 hotfix 通道，不走此脚本）
if [[ "$NEXT" == *-* ]]; then
  echo "错误: 预发布版本请走 hotfix 分支流程" >&2
  exit 1
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 前置校验 ──────────────────────────────────────────────
log "前置校验"

# 1. 在 main 分支
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || fail "必须在 main 分支（当前: $branch）"

# 2. 工作树干净
[ -z "$(git status --porcelain)" ] || fail "工作树不干净，先 commit 或 stash"

# 3. 与远端同步
git fetch origin main --tags --quiet
local_head=$(git rev-parse HEAD)
remote_head=$(git rev-parse origin/main)
[ "$local_head" = "$remote_head" ] || fail "本地 main 与 origin/main 不同步，先 pull"

# 4. 读当前版本
current=$(grep -oE 'VERSION\s*=\s*"[0-9]+\.[0-9]+\.[0-9]+"' src/version.cr \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
[ -n "$current" ] || fail "无法从 src/version.cr 读取 VERSION"
log "当前版本: $current → 目标版本: $NEXT"

# 5. 严格递增
ver_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}
ver_gt "$NEXT" "$current" || fail "目标版本 $NEXT 不大于当前版本 $current"

# 6. tag 未占用（本地 + 远端）
if git rev-parse "v$NEXT" >/dev/null 2>&1; then
  fail "本地 tag v$NEXT 已存在"
fi
if git ls-remote --tags origin "v$NEXT" | grep -q .; then
  fail "远端 tag v$NEXT 已存在"
fi

# 7. shard.yml 与 src/version.cr 当前一致
shard_ver=$(grep -oE '^version:\s*[0-9]+\.[0-9]+\.[0-9]+' shard.yml | grep -oE '[0-9.]+')
[ "$shard_ver" = "$current" ] || fail "shard.yml ($shard_ver) 与 src/version.cr ($current) 不一致"

# ── 版本号 bump ──────────────────────────────────────────
log "更新版本号到 $NEXT"
sed -i "s/^version: .*/version: $NEXT/" shard.yml
sed -i "s/VERSION = \"$current\"/VERSION = \"$NEXT\"/" src/version.cr

grep -q "^version: $NEXT" shard.yml || fail "shard.yml bump 失败"
grep -q "VERSION = \"$NEXT\"" src/version.cr || fail "src/version.cr bump 失败"
log "两处版本号已一致"

# ── CHANGELOG 提示 ───────────────────────────────────────
cat <<EOF

请手动编辑 CHANGELOG.md：
  1. 把 [Unreleased] 段落改名为 [$NEXT] - $(date +%F)
  2. 新增一个空的 [Unreleased] 段落
  3. 更新底部 [Unreleased] 比较链接为 compare/v$NEXT...HEAD
  4. 新增 [$NEXT] 的 releases 链接

完成后按回车继续；按 Ctrl+C 中止（版本号改动可用 git checkout -- shard.yml src/version.cr 回滚）。
EOF
read -r

if ! grep -q "## \[$NEXT\]" CHANGELOG.md; then
  fail "CHANGELOG.md 里未找到 ## [$NEXT] 段落"
fi

# ── Commit + Tag + Push ──────────────────────────────────
log "提交 chore(release) commit"
git add shard.yml src/version.cr CHANGELOG.md
git commit -m "chore(release): v$NEXT [skip ci]"

log "打附注 tag v$NEXT"
git tag -a "v$NEXT" -m "v$NEXT"

if [ "$DRY_RUN" = true ]; then
  log "[dry-run] 跳过 push。回滚命令："
  echo "  git tag -d v$NEXT"
  echo "  git reset --hard HEAD~1"
  exit 0
fi

log "推送 main + tag"
git push origin main
git push origin "v$NEXT"

cat <<EOF

发版已触发。
  - Actions: https://github.com/ShiningRay/sebas/actions/workflows/release.yml
  - 产物校验（release.yml 跑完后执行）：
      gh release download v$NEXT --dir /tmp/sebas-v$NEXT
      cd /tmp/sebas-v$NEXT && sha256sum -c *.sha256
      docker run --rm -v \$PWD:/assets ubuntu:24.04 \\
        bash -c "cd /assets && tar xzf sebas-linux-x86_64.tar.gz && ./sebas-linux-x86_64/sebas version"
  - 产物校验通过后关闭 milestone。
EOF
