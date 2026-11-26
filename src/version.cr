module Sebas
  VERSION = "0.1.0"

  # 构建来源的 git 提交标识，编译期确定。取值顺序：
  #   1. 环境变量 SEBAS_BUILD_REV（无 .git 的源码包 / 受控构建用；40 位完整 SHA 截为 12 位）；
  #   2. 编译时仓库根 .git 的 `git rev-parse --short=12 HEAD`；
  #   3. "unknown"（无 .git，如 tarball 且未注入环境变量）。
  # Crystal 每次构建都会重新执行宏命令，增量构建同样刷新 rev。
  # 三个必须踩准的细节：
  #   - 命令结果是 MacroId，必须 stringify 落成字符串字面量，否则数字开头的哈希
  #     会被当成变量名；env() 已是 StringLiteral，再加 stringify 会多出一层引号。
  #   - #{root} 插值出来自带引号（StringLiteral 的形态），外层不能再包 "..."：
  #     否则得到 `""D:\a\sebas\src/..""`。
  #   - 宏命令不经过 shell：Windows 走 CreateProcessW 直接起可执行文件，POSIX 也不保证
  #     经 /bin/sh。因此 `2>/dev/null || echo unknown` 这类语法在 Windows 会原样成为
  #     git 的实参（`git rev-parse HEAD 2>nul || echo unknown` → exit 128，git 不认）。
  #     兜底只放在文件层：无 .git 才降级，有 .git 就必须能取到 rev，取不到让构建失败。
  {% begin %}
    {% root = __DIR__ + "/.." %}
    {% env_rev = env("SEBAS_BUILD_REV") %}
    {% if env_rev && !env_rev.strip.empty? %}
      {% rev = env_rev.strip %}
      {% rev = rev[0..11] if rev.size == 40 %}
    {% elsif file_exists?(root + "/.git") %}
      {% rev = `git -C #{root} rev-parse --short=12 HEAD`.strip.stringify %}
    {% else %}
      {% rev = "unknown" %}
    {% end %}
    {% rev = "unknown" if rev.empty? %}
    GIT_REV = {{ rev }}
  {% end %}

  # `sebas version` 与 `--help` 首行的版本串：`X.Y.Z (<git rev>)`。
  def self.version_string : String
    "#{VERSION} (#{GIT_REV})"
  end
end
