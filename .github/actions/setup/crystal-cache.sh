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
# 用 <base>/<version>.lock 目录当锁：抢到的 job 装进缓存（收尾步骤放锁），
# 抢不到的装进自己的 RUNNER_TEMP 暂存目录、不碰缓存——这一轮白装，下个 job
# 就命中了。抢到锁后要重新判一次缓存：等锁期间别人可能刚装完。
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

# 持锁超过这么多分钟就当持有者已被强杀，可以接管。正常安装只要几十秒，
# 留足余量避免误抢正在进行的安装。
LOCK_TTL_MIN=30

emit() {
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

warn() {
  printf '::warning::%s\n' "$1"
}

# 锁是否已经陈旧（持有者被强杀之类）。用 find -mmin 判年龄而不是解析 stat
# 输出：GNU 与 BSD 的 stat 语法互不兼容，且在对方系统上不一定报错——GNU 的
# `stat -f %m` 会把 `%m` 当路径、打印文件系统信息。find 报错时按「还活着」
# 处理：宁可跳过这一轮，也不抢别人正在写的缓存目录。
lock_is_stale() {
  local lock="$1"
  [ -e "$lock" ] || return 1
  [ -n "$(find "$lock" -maxdepth 0 -mmin "+${LOCK_TTL_MIN}" 2>/dev/null)" ]
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

hit() {
  emit "hit" "true"
  emit "destination" "$1"
  emit "lock" ""
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
      # 只发 HEAD 读重定向，带总超时：探测失败只是回落，不该拖住 setup。
      resolved="$(curl -fsSI --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{redirect_url}' \
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

# 缓存里那份工具链要加的 PATH 前缀，按优先级从高到低。复刻 install-crystal
# 的 addPath：macOS 先加 embedded/bin 再加 bin（bin 里的 crystal 是 wrapper，
# 应当优先）；Linux 包把 crystal 与 shards 都放在 bin。
toolchain_bin_dirs() {
  if [ "${RUNNER_OS:-}" = "macOS" ]; then
    printf '%s\n' "$1/bin" "$1/embedded/bin"
  else
    printf '%s\n' "$1/bin"
  fi
}

# $1 目录里是否是一份可直接使用的、自报版本为 $2 的工具链。
#
# 不假设 Shards 的落点：默认 shards=true 时 install-crystal 保留包里自带的
# Shards（macOS 在 embedded/bin，Linux 在 bin），不会建 "-shards" 目录。
# 因此按上面那份 PATH 真跑一次 crystal/shards 来确认。
reusable() {
  local root="$1" wanted="$2" dir path="" actual
  [ -x "${root}/bin/crystal" ] || return 1
  if [ "${RUNNER_OS:-}" = "macOS" ]; then
    [ -x "${root}/embedded/bin/crystal" ] || return 1
  fi
  while IFS= read -r dir; do
    path="${path:+$path:}$dir"
  done <<EOF
$(toolchain_bin_dirs "$root")
EOF
  actual="$(PATH="$path" crystal --version 2>/dev/null |
    sed -n '1s/^Crystal \([0-9][0-9.]*\).*/\1/p')"
  [ "$actual" = "$wanted" ] || return 1
  PATH="$path" shards --version >/dev/null 2>&1
}

# 命中后导出 PATH。GITHUB_PATH 是 prepend：runner 反转行序后拼进 PATH，
# 后写的行更靠前，所以先写低优先级的目录。
export_path() {
  local root="$1" dirs reversed=""
  dirs="$(toolchain_bin_dirs "$root")"
  while IFS= read -r dir; do
    reversed="$dir${reversed:+$'\n'$reversed}"
  done <<EOF
$dirs
EOF
  printf '%s\n' "$reversed" >> "$GITHUB_PATH"
}

prepare() {
  local cache_root base root wanted lock staging

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
    hit "$root"
    printf 'Reusing Crystal %s from %s\n' "$wanted" "$root"
    export_path "$root"
    return 0
  fi

  printf 'Crystal %s is not cached at %s\n' "$wanted" "$root"

  if ! mkdir -p "$base" 2>/dev/null; then
    miss "cache directory ${base} is not writable; installing Crystal for this job only"
    return 0
  fi

  # 抢锁要在碰 $root 之前：mkdir 是原子的，同一版本同时未命中时只有一个 job
  # 往缓存目录里写，其余只写自己的 RUNNER_TEMP 暂存目录。
  if [ -e "$lock" ] && lock_is_stale "$lock"; then
    printf 'Taking over stale lock %s\n' "$lock"
    rm -rf "$lock" 2>/dev/null || true
  fi
  if ! mkdir "$lock" 2>/dev/null; then
    emit "hit" "false"
    emit "destination" "$staging"
    emit "lock" ""
    printf 'Another job holds %s; installing into %s without touching the cache\n' "$lock" "$staging"
    return 0
  fi

  # 等锁期间别的 job 可能刚装完并放锁，此时缓存已经可用，直接复用。
  if reusable "$root" "$wanted"; then
    rmdir "$lock" 2>/dev/null || true
    hit "$root"
    printf 'Another job finished installing Crystal %s; reusing %s\n' "$wanted" "$root"
    export_path "$root"
    return 0
  fi

  # 持锁期间没人会写 $root：清掉上次中断留下的、reusable() 判不过的半截目录。
  # install-crystal 的 extractTar 只做 mkdirP、不删旧内容，残留文件会混进新版本。
  if [ -e "$root" ]; then
    if rm -rf "$root" 2>/dev/null; then
      printf 'Cleared the incomplete toolchain at %s\n' "$root"
    else
      rmdir "$lock" 2>/dev/null || true
      miss "could not clear ${root}; installing Crystal for this job only"
      return 0
    fi
  fi

  emit "hit" "false"
  emit "destination" "$root"
  emit "lock" "$lock"
  printf 'Installing Crystal %s into the shared cache (lock %s)\n' "$wanted" "$lock"
}

release() {
  local lock="${1:-}"
  [ -n "$lock" ] || return 0
  rmdir "$lock" 2>/dev/null ||
    warn "could not remove cache lock ${lock}; it will be taken over after ${LOCK_TTL_MIN}min"
}

case "${1:-}" in
  prepare) prepare ;;
  release) release "${2:-}" ;;
  *)
    printf 'usage: %s {prepare | release <lock>}\n' "$0" >&2
    exit 2
    ;;
esac
