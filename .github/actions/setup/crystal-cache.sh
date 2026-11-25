#!/usr/bin/env bash
# Crystal 工具链跨 job 复用（只对自托管类 Unix runner 有意义）。
#
# 【问题】crystal-lang/install-crystal 把官方预编译包解压到 $RUNNER_TEMP，而
# runner 每个 job 开始时都会清空 RUNNER_TEMP（TempDirectoryManager），于是
# 同一台自托管机器每个 job 都要重下 ~57MB 再解压。实测 Setup toolchain 因此
# 固定多花 10-15s。
#
# 【做法】把工具链装进 runner 自己的工具缓存 <work>/_tool（跨 job 持久）下，
# 按版本分目录。下一个 job 命中就只导出 PATH，跳过下载与解压。判断上游最新版
# 只发一个 HEAD 读 302 的 Location——打在 github.com 而非 api.github.com，
# 既比下载便宜两个数量级，也不吃 token 限流。
#
# 【并发】两台 job 可以同时未命中同一版本，若都往缓存目录解压会交叉写文件。
# 用 <base>/<version>.lock 目录当锁：抢到的 job 直接装进缓存（收尾步骤放锁），
# 抢不到的装进自己的 RUNNER_TEMP 暂存目录、不碰缓存——这一轮白装，下个 job
# 就命中了。
#
# 【兜底】任何判据不成立（无网络、目录不可写、版本钉不住）都降级为「未命中且
# 不接管目录」，让 install-crystal 用自己默认的路径——这个优化本身不允许让
# CI 变红。
#
# 用法：
#   crystal-cache.sh prepare   # 写 hit/destination/lock；命中时追加 GITHUB_PATH
#   crystal-cache.sh release   # 放锁
#
# 环境：RUNNER_TOOL_CACHE 或 AGENT_TOOLSDIRECTORY（都缺时由 RUNNER_TEMP 推导）、
#       RUNNER_OS、RUNNER_TEMP、CRYSTAL_REQUESTED、GITHUB_OUTPUT、GITHUB_PATH
set -uo pipefail

# 持锁超过这个秒数就当持有者已被强杀，可以接管。正常安装只要几十秒，
# 留足余量避免误抢正在进行的安装。
LOCK_TTL=1800

emit() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

warn() {
  printf '::warning::%s\n' "$1"
}

# 目录的最后修改时间（BSD/GNU 两种 stat 都试）。
mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# 不接管安装目录：destination 留空，install-crystal 用自己默认的
# $RUNNER_TEMP/crystal-<version>-<shards>-<arch>，与改动前完全一致。
miss() {
  emit "hit" "false"
  emit "destination" ""
  emit "lock" ""
  if [ -n "${1:-}" ]; then warn "$1"; fi
  return 0
}

# 找跨 job 持久的工具缓存根目录。托管 runner 有 RUNNER_TOOL_CACHE /
# AGENT_TOOLSDIRECTORY；自托管 runner 默认不导出它们，但工具目录固定是
# <work>/_tool，而 RUNNER_TEMP 是 <work>/_temp，所以由 RUNNER_TEMP 推得。
tool_cache_root() {
  local candidate
  for candidate in "${RUNNER_TOOL_CACHE:-}" "${AGENT_TOOLSDIRECTORY:-}"; do
    if [ -n "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [ -n "${RUNNER_TEMP:-}" ]; then
    printf '%s\n' "$(dirname "$RUNNER_TEMP")/_tool"
    return 0
  fi
  return 1
}

# 把请求版本钉成一个具体版本号，成功时打印它。
# 返回 1 表示钉不住：nightly / branch / 离线 / 前缀式版本（如 1.22）。
resolve_version() {
  local requested="${1:-latest}" resolved candidate
  case "$requested" in
    "" | latest)
      resolved="$(curl -fsSI -o /dev/null -w '%{redirect_url}' \
        https://github.com/crystal-lang/crystal/releases/latest 2>/dev/null || true)"
      # 拿不到重定向时这是空串或原 URL，统一交给下面的格式校验拦掉。
      candidate="${resolved##*/}"
      ;;
    *)
      # 只认严格的 x.y.z：nightly/master/branch:* 天天在变，缓存没有意义；
      # 前缀式（1.22）解析出的实际 tag 与输入字样不同，拿它当目录名永远不命中。
      candidate="$requested"
      ;;
  esac
  printf '%s\n' "$candidate" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  printf '%s\n' "$candidate"
}

# $1 目录里是否是一份可直接使用的、自报版本为 $2 的工具链。
reusable() {
  local root="$1" wanted="$2" actual
  # macOS 包的 bin/crystal 是 bash wrapper，真正的二进制在 embedded/bin。
  if [ "${RUNNER_OS:-}" = "macOS" ]; then
    [ -x "${root}/embedded/bin/crystal" ] || return 1
  fi
  [ -x "${root}/bin/crystal" ] || return 1
  # install-crystal 默认 shards=true：删掉包里自带的 shards，另建 "-shards"
  # 目录放现场编译的 Shards。两个目录都在才算完整。
  [ -x "${root}-shards/bin/shards" ] || return 1
  # 缓存可能停在上次中断的半截安装，用二进制自报版本兜底确认。
  actual="$("${root}/bin/crystal" --version 2>/dev/null |
    sed -n '1s/^Crystal \([0-9][0-9.]*\).*/\1/p')"
  [ "$actual" = "$wanted" ]
}

prepare() {
  local cache_root base root wanted lock age staging

  if ! cache_root="$(tool_cache_root)"; then
    miss "cannot locate the tool cache (no RUNNER_TEMP); installing Crystal for this job only"
    return 0
  fi

  if ! wanted="$(resolve_version "${CRYSTAL_REQUESTED:-latest}")"; then
    miss "Crystal version '${CRYSTAL_REQUESTED:-latest}' cannot be pinned to a cache entry; installing for this job only"
    return 0
  fi

  # 每个版本约 210MB（含 embedded）；需要回收时删整个 crystal-toolchain 目录。
  base="${cache_root}/crystal-toolchain"
  root="${base}/${wanted}"
  lock="${root}.lock"
  staging="${RUNNER_TEMP:-/tmp}/crystal-staging-${wanted}-$$"

  if reusable "$root" "$wanted"; then
    emit "hit" "true"
    emit "destination" "$root"
    emit "lock" ""
    printf 'Reusing Crystal %s from %s\n' "$wanted" "$root"
    # GITHUB_PATH 是 prepend：runner 反转行序后拼进 PATH，后写的行更靠前。
    # 这里复刻 install-crystal 的 addPath 顺序（shards 目录最后加、因而最前）。
    if [ "${RUNNER_OS:-}" = "macOS" ]; then
      printf '%s\n' "${root}/embedded/bin" "${root}/bin" "${root}-shards/bin" >> "$GITHUB_PATH"
    else
      printf '%s\n' "${root}/bin" "${root}-shards/bin" >> "$GITHUB_PATH"
    fi
    return 0
  fi

  emit "hit" "false"
  printf 'Crystal %s is not cached at %s\n' "$wanted" "$root"

  if ! mkdir -p "$base" 2>/dev/null; then
    miss "cache directory ${base} is not writable; installing Crystal for this job only"
    return 0
  fi

  # 抢锁要在碰 $root 之前：mkdir 是原子的，同一版本同时未命中时只有一个 job
  # 往缓存目录里写，其余只写自己的 RUNNER_TEMP 暂存目录。
  if [ -e "$lock" ]; then
    age=$(( $(date +%s) - $(mtime "$lock") ))
    if [ "$age" -gt "$LOCK_TTL" ]; then
      printf 'Taking over stale lock %s (age %ss)\n' "$lock" "$age"
      rm -rf "$lock" 2>/dev/null || true
    fi
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    emit "destination" "$staging"
    emit "lock" ""
    printf 'Another job holds %s; installing into %s without touching the cache\n' "$lock" "$staging"
    return 0
  fi

  # 持锁期间没人会写 $root：清掉上次中断留下的、reusable() 判不过的半截目录。
  # install-crystal 的 extractTar 只做 mkdirP、不删旧内容，残留文件会混进新版本。
  if [ -e "$root" ] || [ -e "${root}-shards" ]; then
    if rm -rf "$root" "${root}-shards" 2>/dev/null; then
      printf 'Cleared the incomplete toolchain at %s\n' "$root"
    else
      rmdir "$lock" 2>/dev/null || true
      emit "destination" "$staging"
      emit "lock" ""
      warn "could not clear ${root}; installing Crystal for this job only"
      return 0
    fi
  fi

  emit "destination" "$root"
  emit "lock" "$lock"
  printf 'Installing Crystal %s into the shared cache (lock %s)\n' "$wanted" "$lock"
}

release() {
  local lock="${1:-}"
  [ -n "$lock" ] || return 0
  rmdir "$lock" 2>/dev/null ||
    warn "could not remove cache lock ${lock}; it will be taken over after ${LOCK_TTL}s"
}

case "${1:-}" in
  prepare) prepare ;;
  release) release "${2:-}" ;;
  *)
    printf 'usage: %s {prepare | release <lock>}\n' "$0" >&2
    exit 2
    ;;
esac
