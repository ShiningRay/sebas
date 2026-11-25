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
# 【完成标记】`<root>/.sebas-complete` 记录已装好的版本号，由装完的那个 job
# 在放锁前写入。它比「检查 bin 和标准库在不在」可靠得多：
# install-crystal 的 onlySubdir 逐个 mv 子目录，中断时 bin 可能已就位而标准库
# 或 embedded/lib 还没到，那种目录 `crystal --version` 照样跑得通（不需要标准
# 库），但编译一定失败。没有标记就一律当半成品重装。
#
# 【并发】同一版本可能被多个 job 同时未命中，都往缓存目录解压会交叉写文件。
# 用 <root>.lock 目录当锁，协议是：
#   - 读之前先看锁：锁新鲜说明有人正在写，直接走私有暂存目录，不去读半成品；
#   - 抢锁靠 mkdir 的原子性，抢不到就走私有暂存目录，不碰缓存；
#   - 抢到锁后重判一次完成标记：等锁期间别人可能刚装完并放锁；
#   - 锁超过 TTL 视为持有者已被强杀，可以接管，但接管本身也要互斥：先
#     mkdir 一个 <root>.takeover 令牌，拿到令牌的那一个才执行「确认 owner 仍是
#     当初看到的那个 → 删旧锁 → mkdir 新锁」。凭空 rm -rf 旧锁会让两个 job
#     同时成为持有者。
#
# 【兜底】任何判据不成立（无网络、目录不可写、版本钉不住、抢不到锁）都退到
# 「这一轮不缓存」，让 install-crystal 用自己默认的路径——这个优化本身不允许
# 让 CI 变红。
#
# 用法：
#   crystal-cache.sh prepare
#       # 输出 hit / destination / lock / owner / version；命中时追加 GITHUB_PATH
#   crystal-cache.sh release <lock> <owner> <root> <version>
#       # 装完则写完成标记，然后只释放本 job 持有的锁
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

# 目录是否已超过 TTL 没被改动。用 find -mmin 判年龄而不是解析 stat 输出：
# GNU 与 BSD 的 stat 语法互不兼容，且不一定报错——GNU 的 `stat -f %m` 会把
# `%m` 当路径、打印文件系统信息，喂进算术展开就炸。find 报错按「没过期」
# 处理：宁可这一轮不缓存，也不抢别人正在写的目录。
is_stale() {
  local path="$1"
  [ -e "$path" ] || return 1
  [ -n "$(find "$path" -maxdepth 0 -mmin "+${LOCK_TTL_MIN}" 2>/dev/null)" ]
}

# 这一轮不缓存：destination 留空，install-crystal 用自己默认的
# $RUNNER_TEMP/crystal-<version>-<shards>-<arch>，与改动前完全一致。
fallback() {
  emit "hit" "false"
  emit "destination" ""
  emit "lock" ""
  emit "owner" ""
  if [ -n "${1:-}" ]; then warn "$1"; fi
  return 0
}

hit() {
  emit "hit" "true"
  emit "destination" "$1"
  emit "lock" ""
  emit "owner" ""
}

# 抢不到锁时用：仍是未命中，但装到私有目录，绝不碰共享缓存。
private_install() {
  emit "hit" "false"
  emit "destination" "$1"
  emit "lock" ""
  emit "owner" ""
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
      # --max-time 是必需的，连接建立后迟迟不回响应时 `|| true` 根本轮不到。
      resolved="$(curl -fsSI --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{redirect_url}' \
        https://github.com/crystal-lang/crystal/releases/latest 2>/dev/null || true)"
      # 拿不到重定向时这是空串或原 URL，交给下面的格式校验拦掉。
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

# 标准库是否就位。两平台的包布局不同：macOS 解到 <root>/src，Linux 解到
# <root>/share/crystal/src（install-crystal 另在 <root>/src 建软链）。
stdlib_present() {
  if [ "${RUNNER_OS:-}" = "macOS" ]; then
    [ -f "$1/src/prelude.cr" ]
  else
    [ -f "$1/share/crystal/src/prelude.cr" ]
  fi
}

# $1 目录里是否是一份装完的、版本为 $2 的工具链。
#
# 完成标记是「装完了」的凭据；installed_ok 是「装完的内容物确实在」的检查。
# 两者都过才算可复用——标记在但文件被删（比如有人手动清理）时不该硬用它。
reusable() {
  local root="$1" wanted="$2"
  [ -f "${root}/.sebas-complete" ] || return 1
  [ "$(cat "${root}/.sebas-complete" 2>/dev/null)" = "$wanted" ] || return 1
  installed_ok "$root" "$wanted"
}

# 工具链内容物是否完整、能否真的跑起来。收尾时用同一份判据决定要不要打完成
# 标记：只有真装完的才打，半截目录留给下一个 job 重装。
#
# 不假设 Shards 的落点：默认 shards=true 时 install-crystal 保留包里自带的
# Shards（macOS 在 embedded/bin，Linux 在 bin），不会建 "-shards" 目录。
installed_ok() {
  local root="$1" wanted="$2" dir path="" actual

  stdlib_present "$root" || return 1

  if [ "${RUNNER_OS:-}" = "macOS" ]; then
    # macOS 的 bin/crystal 是 `#!/usr/bin/env bash` 的 wrapper，内部还要用
    # dirname / realpath。只给工具链那两个目录会让 wrapper 起不来（env 找不到
    # bash，退出 127），完好的缓存就被判成未命中，本 PR 在 macOS 上的收益归零。
    # 工具链目录排前面保证用的是缓存里那份，系统目录只做兜底。
    [ -x "${root}/bin/crystal" ] || return 1
    [ -x "${root}/embedded/bin/crystal" ] || return 1
  else
    [ -x "${root}/bin/crystal" ] || return 1
    [ -x "${root}/bin/shards" ] || return 1
  fi

  while IFS= read -r dir; do
    path="${path:+$path:}$dir"
  done <<EOF
$(toolchain_bin_dirs "$root")
EOF
  # 只追加最小的系统目录，不继承宿主 PATH：次序不变（缓存优先），也不会让
  # 宿主自带的 crystal/shards 在对应用例失败时顶上、把坏缓存判成可用。
  path="$path:/usr/bin:/bin:/usr/sbin:/sbin"

  actual="$(PATH="$path" crystal --version 2>/dev/null |
    sed -n '1s/^Crystal \([0-9][0-9.]*\).*/\1/p')"
  [ "$actual" = "$wanted" ] || return 1
  PATH="$path" shards --version >/dev/null 2>&1
}

# 命中后导出 PATH。GITHUB_PATH 是 prepend：runner 反转行序后拼进 PATH，
# 后写的行更靠前，所以先写低优先级的目录。
export_path() {
  local root="$1" dir dirs reversed=""
  dirs="$(toolchain_bin_dirs "$root")"
  while IFS= read -r dir; do
    reversed="$dir${reversed:+$'\n'$reversed}"
  done <<EOF
$dirs
EOF
  printf '%s\n' "$reversed" >> "$GITHUB_PATH"
}

# 本 job 的锁所有权凭据。pid 只便于排查，唯一性靠随机后缀。
new_owner_token() {
  printf '%s-%s-%s' "$$" "$(date -u +%Y%m%dT%H%M%SZ)" "${RANDOM}${RANDOM}"
}

# 接管一把陈旧锁。返回 0 表示已把新锁建好。
#
# 「先判 age 再 rm -rf」不安全：两个 job 可能同时判同一把锁过期，A 删掉旧锁并
# 建了新锁，B 随后按旧判断再 rm 一次，删的就是 A 的新锁——两个 job 同时成为
# 持有者，一起往 $root 写。
#
# 这里用 mkdir 一个 takeover 令牌做互斥：只有拿到令牌的那个才动旧锁，且动之前
# 再确认 owner 仍是当初看到的那个（不是就放弃）。删完立刻 mkdir 新锁；如果这
# 个瞬间被别的 job 抢先建成，本 job 就认输去私有目录——认输是安全的，抢建不
# 安全。
take_over_stale_lock() {
  local lock="$1" seen_owner="$2" takeover="$1.takeover"
  mkdir "$takeover" 2>/dev/null || return 1
  local ok=1
  if [ "$(cat "${lock}/owner" 2>/dev/null)" = "$seen_owner" ]; then
    rm -rf "$lock" 2>/dev/null || true
    if mkdir "$lock" 2>/dev/null; then
      ok=0
      printf 'Took over the stale lock %s\n' "$lock"
    fi
  fi
  rmdir "$takeover" 2>/dev/null || true
  return "$ok"
}

# 放锁，只放自己的。
#
# 两件事必须同时成立，否则会删掉别人的锁：
#   1. 锁里的 owner 是本 job 的——不是就说明这把锁已被 TTL 接管、换成了别的
#      job 的锁；
#   2. 整个「读 owner → 删锁」期间握着与接管共用的 takeover 令牌——否则本 job
#      在读完 owner 之后被暂停，锁随即过期，接管方重建了新锁，本 job 醒来照删
#      不误。
# 拿不到令牌就直接放手：这把锁要么正被接管，要么将被接管，交给 TTL 处理。
release_lock() {
  local lock="$1" owner="$2" takeover="${1}.takeover"
  [ -n "$lock" ] || return 0
  if ! mkdir "$takeover" 2>/dev/null; then
    warn "cache lock ${lock} is being taken over; leaving it alone"
    return 0
  fi
  if [ -n "$owner" ] && [ -f "${lock}/owner" ] &&
    [ "$(cat "${lock}/owner" 2>/dev/null)" != "$owner" ]; then
    rmdir "$takeover" 2>/dev/null || true
    warn "cache lock ${lock} is no longer owned by this job; leaving it alone"
    return 0
  fi
  # 目录里有 owner 文件，rmdir 必然失败，得用 rm -rf 连带清掉。
  rm -rf "$lock" 2>/dev/null ||
    warn "could not remove cache lock ${lock}; it will be taken over after ${LOCK_TTL_MIN}min"
  rmdir "$takeover" 2>/dev/null || true
}

# 认领锁：写 owner 凭据。写不进去就放弃这把锁，免得持有一把无法安全释放的锁。
claim_lock() {
  local lock="$1" owner="$2"
  printf '%s\n' "$owner" > "${lock}/owner" 2>/dev/null
}

prepare() {
  local cache_root base root wanted lock staging owner seen_owner

  if ! cache_root="$(tool_cache_root)"; then
    fallback "cannot locate the tool cache (no RUNNER_TEMP); installing Crystal for this job only"
    return 0
  fi

  if ! wanted="$(resolve_version "${CRYSTAL_REQUESTED:-latest}")"; then
    fallback "Crystal version '${CRYSTAL_REQUESTED:-latest}' cannot be pinned to a cache entry; installing for this job only"
    return 0
  fi
  emit "version" "$wanted"

  # 每个版本约 210MB（含 embedded）；需要回收时删整个 crystal-toolchain 目录。
  base="${cache_root}/crystal-toolchain"
  root="${base}/${wanted}"
  lock="${root}.lock"
  staging="${RUNNER_TEMP:-/tmp}/crystal-staging-${wanted}-$$"

  # 干净的接管令牌不该长时间留着：上一个接管者可能就在这两行之间被强杀。
  is_stale "${lock}.takeover" && rm -rf "${lock}.takeover" 2>/dev/null

  # 锁有效期内不读缓存：持有者可能正往 $root 里写，此时看到的不是完整工具链。
  if [ -e "$lock" ] && ! is_stale "$lock"; then
    private_install "$staging"
    printf 'Another job is installing Crystal %s; installing into %s\n' "$wanted" "$staging"
    return 0
  fi

  if reusable "$root" "$wanted"; then
    hit "$root"
    printf 'Reusing Crystal %s from %s\n' "$wanted" "$root"
    export_path "$root"
    return 0
  fi

  printf 'Crystal %s is not cached at %s\n' "$wanted" "$root"

  if ! mkdir -p "$base" 2>/dev/null; then
    fallback "cache directory ${base} is not writable; installing Crystal for this job only"
    return 0
  fi

  owner="$(new_owner_token)"
  seen_owner="$(cat "${lock}/owner" 2>/dev/null || true)"

  if [ -e "$lock" ]; then
    # 走到这里说明锁已过期。seen_owner 只用于接管后的确认，空也无妨：空值
    # 只会在 owner 文件也读不到时匹配，而那种锁本来就没有持有者。
    take_over_stale_lock "$lock" "$seen_owner" || {
      private_install "$staging"
      printf 'Could not take over %s; installing into %s without touching the cache\n' "$lock" "$staging"
      return 0
    }
  elif ! mkdir "$lock" 2>/dev/null; then
    private_install "$staging"
    printf 'Another job holds %s; installing into %s without touching the cache\n' "$lock" "$staging"
    return 0
  fi

  if ! claim_lock "$lock" "$owner"; then
    # 没有所有权凭据就没法安全地放锁，索性这把锁也不用。
    rm -rf "$lock" 2>/dev/null || true
    fallback "could not record the cache lock owner for ${lock}; installing Crystal for this job only"
    return 0
  fi

  # 等锁 / 抢锁期间别的 job 可能刚装完，此时缓存已经可用，直接复用。
  if reusable "$root" "$wanted"; then
    release_lock "$lock" "$owner"
    hit "$root"
    printf 'Another job finished installing Crystal %s; reusing %s\n' "$wanted" "$root"
    export_path "$root"
    return 0
  fi

  # 持锁期间没人会写 $root：清掉上次中断留下的、没有完成标记的半截目录。
  # install-crystal 的 extractTar 只做 mkdirP、不删旧内容，残留文件会混进新版本。
  if [ -e "$root" ]; then
    if rm -rf "$root" 2>/dev/null; then
      printf 'Cleared the incomplete toolchain at %s\n' "$root"
    else
      release_lock "$lock" "$owner"
      fallback "could not clear ${root}; installing Crystal for this job only"
      return 0
    fi
  fi

  emit "hit" "false"
  emit "destination" "$root"
  emit "lock" "$lock"
  emit "owner" "$owner"
  printf 'Installing Crystal %s into the shared cache (lock %s)\n' "$wanted" "$lock"
}

# 收尾：装成功就打完成标记，然后放锁。安装失败时不打标记，下一个 job 会把它
# 当半成品重装。
#
# 三件事必须同时成立才盖章：
#   1. 安装步骤报告成功。install-crystal 的 Linux 分支并行跑依赖安装与工具链
#      下载，依赖装失败时工具链可能已经解压好——只看内容物会把「缺 libssl-dev」
#      这种机器状态固化进缓存，之后每个 job 都跳过安装、一直编译失败。用
#      action.yml 里 Install Crystal 的步骤结论当依据（`CRYSTAL_INSTALL_OK`）。
#   2. 本 job 仍持有锁。本 job 被强杀后锁可能已被 TTL 接管，此时缓存目录里属于
#      别的 job 的半成品不能被我们盖章。
#   3. 内容物确实完整可跑。
#
# 整个「读 owner → 校验 → 盖章」期间握着 takeover 令牌：否则本 job 在这一段被
# 暂停、锁刚好过期，接管方删掉 $root 重建，本 job 醒来会把标记写进对方的半成品
# 目录。拿不到令牌就放弃盖章——宁可这一轮白装，也不留一个骗人的标记。
finish() {
  local lock="${1:-}" owner="${2:-}" root="${3:-}" wanted="${4:-}"
  local install_ok="${5:-}"
  [ -n "$lock" ] || return 0

  if [ "$install_ok" = "true" ] && [ -n "$root" ] && [ -n "$wanted" ]; then
    if mkdir "${lock}.takeover" 2>/dev/null; then
      if [ "$(cat "${lock}/owner" 2>/dev/null)" = "$owner" ]; then
        if installed_ok "$root" "$wanted"; then
          printf '%s\n' "$wanted" > "${root}/.sebas-complete" 2>/dev/null ||
            warn "could not write the completion marker in ${root}"
        else
          warn "Crystal ${wanted} is not usable in ${root}; the next job will reinstall it"
        fi
      fi
      rmdir "${lock}.takeover" 2>/dev/null || true
    else
      warn "cache lock ${lock} is being taken over; not marking ${root} as complete"
    fi
  elif [ -n "$root" ] && [ -n "$wanted" ]; then
    warn "the install step did not succeed; the next job will reinstall ${root}"
  fi

  release_lock "$lock" "$owner"
}

case "${1:-}" in
  prepare) prepare ;;
  # 第五个参数是安装步骤的结论，由 action.yml 的 `if: success()` 传进来。
  release) finish "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" ;;
  *)
    printf 'usage: %s {prepare | release <lock> <owner> <root> <version> <installed>}\n' "$0" >&2
    exit 2
    ;;
esac
