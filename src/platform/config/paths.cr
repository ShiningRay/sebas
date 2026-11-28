require "../../log"
require "./loader"

# 应用根目录契约（M5.0-WP3，Proposal #274 sebas-home.md §2/§3）：
# 唯一应用根 `home`，默认 `~/.sebas`，`SEBAS_HOME` 覆盖。
# - `SEBAS_HOME` 已设置但空白 → 拒启（显示变量名），不回退默认目录或工作目录
# - `~` 在路径层展开；相对 `SEBAS_HOME` 以启动 CWD 立即绝对化；解析后进程内不再改变
# - 未传 `--config`/`-c` 时配置文件为 `<home>/config.yaml`；显式参数只决定配置文件，
#   不反向改变 home
# - `gateway.data_dir` 省略时解析期取 `<home>/data`；显式绝对值规范化原样保留；
#   显式相对值相对实际配置文件所在目录解析；不向 YAML 配置树注入机器相关绝对路径
# - 一个版本的受限旧布局回退：仅未显式传 --config、新默认配置不存在且启动 CWD 有
#   config.yaml 时读旧文件并警告；不自动复制、合并或搬移任何文件
# - POSIX 目录权限过宽只告警；Windows 不伪造 ACL 校验
# 环境注入（env/home_dir/cwd）供测试与未来 setup 复用；纯函数优先，不改进程环境。
module Sebas
  module Platform
    module Config
      module HomeResolver
        extend self

        # 平台实际读取的主目录变量：Windows 用 USERPROFILE（回退 HOMEDRIVE+HOMEPATH），
        # POSIX 用 HOME。env 参数注入测试环境；nil 读真实 ENV。
        def platform_home_dir(env : Hash(String, String)? = nil) : String?
          get = ->(key : String) { env ? env[key]? : ENV[key]? }
          {% if flag?(:windows) %}
            get.call("USERPROFILE") || begin
              drive = get.call("HOMEDRIVE")
              path = get.call("HOMEPATH")
              drive && path ? drive + path : nil
            end
          {% else %}
            get.call("HOME")
          {% end %}
        end

        # 应用根解析（sebas-home.md §2.1）：SEBAS_HOME 非空白取其值（~ 展开、
        # 相对值以 cwd 绝对化），未设置取平台主目录下 .sebas。
        # 直接 expand(base: cwd) 而非先拼接：Windows 根相对路径（`\foo`，无盘符
        # absolute? 为 false）须继承基准盘符的根语义，join 会错挂到 cwd 下
        def resolve_home(sebas_home : String?, home_dir : String?, cwd : Path) : Path
          if raw = sebas_home
            if raw.strip.empty?
              raise ConfigError.new("SEBAS_HOME is set but blank; set it to a non-empty path or unset the variable")
            end
            expand_tilde(raw, home_dir).expand(base: cwd)
          else
            hd = home_dir || raise ConfigError.new("cannot resolve default home: no user home directory available (set SEBAS_HOME explicitly)")
            Path[hd, ".sebas"]
          end
        end

        # 前导 `~` 展开：`~` 本身或 `~<sep>...` 以平台主目录为基准；主目录缺失报错。
        def expand_tilde(raw : String, home_dir : String?) : Path
          if raw == "~" || raw.starts_with?("~/") || raw.starts_with?("~\\")
            hd = home_dir || raise ConfigError.new("cannot expand '~' in SEBAS_HOME: no user home directory available")
            rest = raw[1..]
            rest = rest.lstrip('/').lstrip('\\') if rest.size > 1
            rest.empty? ? Path[hd] : Path[hd, rest]
          else
            Path[raw]
          end
        end

        # POSIX 目录权限过宽（组/其他可写）返回告警文案；目录不存在或 Windows 返回 nil。
        def wide_permission_warning(path : Path) : String?
          {% if flag?(:unix) %}
            return nil unless File.exists?(path)
            mode = File.info(path).permissions
            return nil if (mode.value & 0o022).zero?
            "#{path} is group/world-writable (mode #{mode.value.to_s(8)}); consider tightening permissions"
          {% else %}
            nil # Windows 不伪造等价 ACL 校验
          {% end %}
        end
      end

      # 一次启动的路径上下文：home / 实际配置文件 / 配置目录解析为绝对路径，
      # 启动期固定；热更新不重读 SEBAS_HOME、不改换数据路径。
      # data_dir 依赖配置内容（gateway.data_dir 省略与否），配置加载后经
      # with_data_dir 补全——两段构造，不向配置树注入机器相关绝对路径。
      class PathContext
        getter home : Path             # 绝对应用根（已规范化）
        getter config_path : Path      # 实际加载的配置文件（绝对）
        getter config_dir : Path       # config_path 所在目录（绝对）
        getter data_dir : Path         # 解析后的绝对数据目录（with_data_dir 后有效）
        getter? legacy_fallback : Bool # 是否命中旧布局受限回退（方法名 legacy_fallback?）
        getter warnings : Array(String)

        def initialize(@home, @config_path, @config_dir, @data_dir, @legacy_fallback, @warnings)
        end

        # 第一段解析（CLI 在检查配置文件之前调用一次）。全部输入可注入：
        # env 为 nil 时读真实进程环境（CLI 路径）；显式传入空 Hash 表示
        # 「SEBAS_HOME 未设置」的纯测试语义；home_dir 覆盖平台主目录（测试
        # 隔离用）；exists 覆盖文件存在性检查（缺省真实文件系统）。配置缺失
        # 不在此报错——由调用方 fail-fast 并展示实际查找的绝对路径（回退判定
        # 需先完成）。
        def self.resolve(explicit_config : String?, cwd : Path, env : Hash(String, String)? = nil,
                         home_dir : String? = nil, exists : Proc(String, Bool)? = nil) : PathContext
          sebas_home = env ? env["SEBAS_HOME"]? : ENV["SEBAS_HOME"]?
          hd = home_dir || HomeResolver.platform_home_dir(env)
          check = exists || ->(path : String) { File.exists?(path) }

          home = HomeResolver.resolve_home(sebas_home, hd, cwd)

          fallback = false
          config_path =
            if explicit_config
              # 直接交给末尾 expand(base: cwd)：Windows 根相对路径（`\foo`）
              # 继承基准盘符根，保留与旧 CLI 一致的定位语义（CodeRabbit #304）
              Path[explicit_config]
            else
              default = Path[home, "config.yaml"]
              legacy = Path[cwd, "config.yaml"]
              # 受限回退（sebas-home.md §4）：仅未显式传 --config、新默认配置
              # 不存在且启动 CWD 有 config.yaml；显式路径、空 SEBAS_HOME 与
              # 其他失败均不回退
              if !check.call(default.to_s) && check.call(legacy.to_s)
                fallback = true
                legacy
              else
                default
              end
            end
          config_path = config_path.expand(base: cwd)

          warnings = [] of String
          if w = HomeResolver.wide_permission_warning(home)
            warnings << w
          end

          PathContext.new(home, config_path, config_path.parent,
            Path[home, "data"], fallback, warnings)
        end

        # 第二段补全（配置加载后调用，sebas-home.md §2.2）：省略 data_dir →
        # <home>/data；绝对值规范化；相对值相对实际配置文件目录。显式 --config
        # 不把默认数据目录改到该文件旁边。旧布局回退的警告在此生成——必须同时
        # 展示配置与实际数据路径及「旧配置省略 data_dir 时数据库/vault 路径可能
        # 改变」的后果，不让用户误以为已沿用旧数据；绝不自动搬移任何文件。
        def with_data_dir(raw : String?) : PathContext
          data_dir = PathContext.resolve_data_dir(raw, @home, @config_dir)
          warnings = @warnings.dup
          if @legacy_fallback
            warnings << "legacy layout fallback: reading config from #{@config_path} (default #{Path[@home, "config.yaml"]} not found); " \
                        "data path resolves to #{data_dir} — if the legacy config omits gateway.data_dir, database/vault now live under the new default; no files are copied or moved"
          end
          if w = HomeResolver.wide_permission_warning(data_dir)
            warnings << w
          end
          PathContext.new(@home, @config_path, @config_dir, data_dir, @legacy_fallback, warnings)
        end

        # 数据目录解析纯函数：nil → <home>/data；显式值直接 expand(base: 配置
        # 目录)——普通相对值相对配置文件目录，Windows 根相对值继承配置文件所在
        # 盘符的根（与显式 --config 同一语义，CodeRabbit #304）；绝对值规范化。
        def self.resolve_data_dir(raw : String?, home : Path, config_dir : Path) : Path
          if raw
            Path[raw].expand(base: config_dir)
          else
            Path[home, "data"]
          end
        end
      end
    end
  end
end
