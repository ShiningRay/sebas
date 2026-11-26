module Sebas
  VERSION = "0.1.0"

  # 构建来源的 git 提交标识，编译期确定。取值顺序：
  #   1. 环境变量 SEBAS_BUILD_REV（无 .git 的源码包 / 受控构建用；40 位完整 SHA 截为 12 位）；
  #   2. 编译时仓库根 `.git` 的 HEAD 所指提交，取前 12 位；
  #   3. "unknown"（读不到就降级，构建永不因取 rev 失败而中断）。
  # Crystal 每次构建都会重新执行宏，增量构建同样刷新 rev。
  #
  # 为什么自己解析 .git 文件而不是 `git rev-parse`：
  #   - 宏命令不经过 shell（Windows 走 CreateProcessW 直接起可执行文件，POSIX 也不保证经
  #     /bin/sh），`2>nul || echo unknown` 之类会成为 git 的实参而不是语法，
  #     实测 Windows 上得到 `Needed a single revision` / exit 128。
  #   - 宏里命令以非零码退出会直接中断编译，无法兜底；而三平台构建必须都能编过。
  #   - 显式走 `cmd.exe /c` 只是把引号转义再叠一层，仍然依赖构建机装有 git。
  #   直接读文件则零依赖、零平台差异：.git 的布局是 git 的稳定契约。
  # 覆盖 layout：普通仓、packed-refs、detached HEAD、worktree、submodule、bare。
  # 所有读取都用 read_file?（失败返回 nil 而非中断宏展开），任何一步取不到或
  # 内容不像 SHA 一律 unknown。
  {% begin %}
    {% root = (__DIR__ + "/..").tr("\\", "/") %}
    {% env_rev = env("SEBAS_BUILD_REV") %}
    {% rev = "" %}
    {% rev_failed = false %}

    {% if env_rev && !env_rev.strip.empty? %}
      {% rev = env_rev.strip %}
      {% rev = rev[0..11] if rev.size == 40 %}
    {% else %}
      {% gitdir = "" %}
      {% dotgit = root + "/.git" %}
      {% if file_exists?(dotgit + "/") %}
        {% gitdir = dotgit %}
      {% else %}
        {% raw_ptr = read_file?(dotgit) %}
        {% if raw_ptr %}
          {% ptr = raw_ptr.strip %}
          {% if ptr.starts_with?("gitdir:") %}
            {% target = ptr["gitdir:".size..].strip.tr("\\", "/") %}
            {% if target.starts_with?("/") || target.split("/")[0].ends_with?(":") %}
              {% gitdir = target %}
            {% else %}
              {% gitdir = root + "/" + target %}
            {% end %}
          {% end %}
        {% end %}
      {% end %}

      {% if !gitdir.empty? %}
        {% raw_head = read_file?(gitdir + "/HEAD") %}
        {% head = raw_head ? raw_head.strip : "" %}
        {% if head.starts_with?("ref:") %}
          {% refname = head["ref:".size..].strip %}
          {% bases = [gitdir] %}
          {% raw_common = read_file?(gitdir + "/commondir") %}
          {% if raw_common %}
            {% common = raw_common.strip.tr("\\", "/") %}
            {% if common.starts_with?("/") || common.split("/")[0].ends_with?(":") %}
              {% bases = bases + [common] %}
            {% else %}
              {% bases = bases + [gitdir + "/" + common] %}
            {% end %}
          {% end %}
          {% for base in bases %}
            {% if rev.empty? && !rev_failed %}
              {% refpath = base + "/" + refname %}
              {% raw_ref = read_file?(refpath) %}
              {% if raw_ref %}
                {% rev = raw_ref.strip %}
              {% elsif file_exists?(refpath) %}
                {% rev_failed = true %}
              {% end %}
            {% end %}
          {% end %}
          {% if rev.empty? && !rev_failed %}
            {% for base in bases %}
              {% if rev.empty? %}
                {% raw_packed = read_file?(base + "/packed-refs") %}
                {% if raw_packed %}
                  {% hit = raw_packed.lines.find(&.ends_with?(" " + refname)) %}
                  {% rev = hit.split(" ")[0] if hit %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% elsif !head.empty? %}
          {% rev = head %}
        {% end %}
      {% end %}

      {% if rev.size == 40 && rev.downcase.tr("0123456789abcdef", "").empty? %}
        {% rev = rev.downcase[0..11] %}
      {% else %}
        {% rev = "unknown" %}
      {% end %}
    {% end %}

    GIT_REV = {{ rev }}
  {% end %}

  # `sebas version` 与 `--help` 首行的版本串：`X.Y.Z (<git rev>)`。
  def self.version_string : String
    "#{VERSION} (#{GIT_REV})"
  end
end
