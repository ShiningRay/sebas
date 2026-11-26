module Sebas
  VERSION = "0.1.0"

  # 构建来源的 git 提交标识，编译期确定。取值顺序：
  #   1. 环境变量 SEBAS_BUILD_REV（无 .git 的源码包 / 受控构建用；40 位完整 SHA 截为 12 位）；
  #   2. 编译时仓库根 .git 的 `git rev-parse --short=12 HEAD`；
  #   3. "unknown"（两者都不可用，如 tarball 未注入环境变量、环境里没有 git）。
  # Crystal 每次构建都会重新执行宏命令，增量构建同样刷新 rev。
  # 两个必须踩准的细节：
  #   - 命令结果是 MacroId，必须 stringify 落成字符串字面量，否则数字开头的哈希
  #     会被当成变量名；env() 已是 StringLiteral，再加 stringify 会多出一层引号。
  #   - #{root} 插值出来自带引号（StringLiteral 的形态），外层不能再包 "..."：
  #     否则得到 `""D:\a\sebas\src/..""`。POSIX 的 sh 折叠空引号看不出问题，
  #     Windows 却把它原样交给 git，`-C` 路径就坏了（#224 windows-latest 实测）。
  # 重定向与 `||` 的写法按 host 分支：POSIX 走 /bin/sh，Windows 走 cmd.exe。
  {% begin %}
    {% root = __DIR__ + "/.." %}
    {% env_rev = env("SEBAS_BUILD_REV") %}
    {% if env_rev && !env_rev.strip.empty? %}
      {% rev = env_rev.strip %}
      {% rev = rev[0..11] if rev.size == 40 %}
    {% elsif file_exists?(root + "/.git") %}
      {% if host_flag?(:windows) %}
        {% rev = `git -C #{root} rev-parse --short=12 HEAD 2>nul || echo unknown`.strip.stringify %}
      {% else %}
        {% rev = `git -C #{root} rev-parse --short=12 HEAD 2>/dev/null || echo unknown`.strip.stringify %}
      {% end %}
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
