require "spec"
require "../../../src/platform/config/paths"

# 路径上下文测试（M5.0-WP3，sebas-home.md §5 测试主目录隔离）：
# 全部用例经 env/home_dir/cwd/exists 注入，临时根一律在 Dir.tempdir 下新建，
# 绝不读写真实 ~/.sebas，也不依赖开发者机器的 HOME/SEBAS_HOME/USERPROFILE。
# 注入式用例不改进程环境；仅「CLI 拒启文案」两例临时设 SEBAS_HOME 并在
# ensure 恢复——全仓 spec 无其他 SEBAS_HOME/HOME 读写点（本文件头部已核实
# 口径），按 sebas-home.md §5「串行或隔离子进程」的约定视同串行。
module Sebas
  def self.paths_spec_root : Path
    Path[Dir.tempdir, "sebas-paths-spec", Random::Secure.hex(4)]
  end

  module Platform
    module Config
      describe HomeResolver do
        it "SEBAS_HOME 未设置 → 注入主目录/.sebas（不触真实主目录）" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s)
          ctx.home.should eq(Path[root, "userhome", ".sebas"])
          ctx.config_path.should eq(Path[root, "userhome", ".sebas", "config.yaml"])
          ctx.legacy_fallback?.should be_false
        end

        it "平台主目录变量按平台分支读取（注入 env，不读真实变量）" do
          root = Sebas.paths_spec_root
          {% if flag?(:windows) %}
            ctx = PathContext.resolve(nil, cwd: root,
              env: {"USERPROFILE" => (root / "u").to_s, "HOME" => "C:\\posix-ignore"})
            ctx.home.should eq(Path[root, "u", ".sebas"])
          {% else %}
            ctx = PathContext.resolve(nil, cwd: root,
              env: {"HOME" => (root / "u").to_s, "USERPROFILE" => "/win-ignore"})
            ctx.home.should eq(Path[root, "u", ".sebas"])
          {% end %}
        end

        it "SEBAS_HOME 环境覆盖默认主目录" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve(nil, cwd: root,
            env: {"SEBAS_HOME" => (root / "srv" / "sebas").to_s})
          ctx.home.should eq(Path[root, "srv", "sebas"])
          ctx.config_path.should eq(ctx.home / "config.yaml")
        end

        it "空白 SEBAS_HOME（空串/纯空白）拒启并显示变量名" do
          root = Sebas.paths_spec_root
          {"", "   ", "\t\n"}.each do |blank|
            expect_raises(ConfigError, /SEBAS_HOME is set but blank/) do
              PathContext.resolve(nil, cwd: root, env: {"SEBAS_HOME" => blank})
            end
          end
        end

        it "~ 展开到注入主目录：~ 本身与 ~/子路径" do
          root = Sebas.paths_spec_root
          hd = root / "u"
          ctx = PathContext.resolve(nil, cwd: root,
            env: {"SEBAS_HOME" => "~"}, home_dir: hd.to_s)
          ctx.home.should eq(Path[hd])
          ctx = PathContext.resolve(nil, cwd: root,
            env: {"SEBAS_HOME" => "~/sebas-root"}, home_dir: hd.to_s)
          ctx.home.should eq(Path[hd, "sebas-root"])
        end

        it "相对 SEBAS_HOME 以启动 CWD 立即绝对化" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve(nil, cwd: root,
            env: {"SEBAS_HOME" => "rel-home"})
          ctx.home.should eq(Path[root, "rel-home"])
        end

        it "含空格与非 ASCII 的 SEBAS_HOME 原样保留" do
          root = Sebas.paths_spec_root
          target = root / "my home 中文"
          ctx = PathContext.resolve(nil, cwd: root,
            env: {"SEBAS_HOME" => target.to_s})
          ctx.home.should eq(Path[target])
        end

        it "主目录缺失且无 SEBAS_HOME：报错含指引" do
          expect_raises(ConfigError, /no user home directory available/) do
            HomeResolver.resolve_home(nil, nil, Path["/x"])
          end
        end
      end

      describe PathContext do
        it "显式 --config 只决定配置文件，不改 home（绝对路径）" do
          root = Sebas.paths_spec_root
          explicit = root / "cfg" / "config.yaml"
          ctx = PathContext.resolve(explicit.to_s, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s)
          ctx.config_path.should eq(explicit)
          ctx.home.should eq(Path[root, "userhome", ".sebas"])
        end

        it "显式相对 --config 相对启动 CWD 解析" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve("conf/app.yaml", cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s)
          ctx.config_path.should eq(Path[root, "conf", "app.yaml"])
        end

        {% if flag?(:windows) %}
          # Windows 根相对路径（`\foo`，无盘符 absolute? 为 false）：须继承基准
          # 盘符的根语义（expand(base:)），不得 join 进 cwd（CodeRabbit #304）
          it "Windows 根相对 --config 保留盘符根定位语义" do
            ctx = PathContext.resolve("\\cfg\\config.yaml", cwd: Path["C:\\work"],
              env: {} of String => String, home_dir: "C:\\userhome")
            ctx.config_path.should eq(Path["C:\\cfg\\config.yaml"])
          end

          it "Windows 根相对 SEBAS_HOME 保留盘符根定位语义" do
            ctx = PathContext.resolve(nil, cwd: Path["C:\\work"],
              env: {"SEBAS_HOME" => "\\root-home"})
            ctx.home.should eq(Path["C:\\root-home"])
          end

          it "Windows 根相对 data_dir 保留盘符根定位语义" do
            PathContext.resolve_data_dir("\\state", Path["C:\\h", ".sebas"], Path["C:\\cfg"])
              .should eq(Path["C:\\state"])
          end
        {% end %}

        it "旧布局受限回退：未显式传 --config、默认配置缺失且 CWD 有 config.yaml" do
          root = Sebas.paths_spec_root
          legacy = Path[root, "config.yaml"]
          exists = ->(p : String) { p == legacy.to_s }
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: exists)
          ctx.config_path.should eq(legacy)
          ctx.legacy_fallback?.should be_true
          ctx.config_dir.should eq(Path[root])
        end

        it "回退不越界：默认配置存在时不回退" do
          root = Sebas.paths_spec_root
          default_cfg = Path[root, "userhome", ".sebas", "config.yaml"]
          exists = ->(p : String) { p == default_cfg.to_s || p == Path[root, "config.yaml"].to_s }
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: exists)
          ctx.config_path.should eq(default_cfg)
          ctx.legacy_fallback?.should be_false
        end

        it "回退不越界：显式 --config 存在性失败也不回退" do
          root = Sebas.paths_spec_root
          missing = root / "nope" / "config.yaml"
          exists = ->(_p : String) { true } # 旧布局文件就在 CWD，也必须不回退
          ctx = PathContext.resolve(missing.to_s, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: exists)
          ctx.config_path.should eq(missing)
          ctx.legacy_fallback?.should be_false
        end

        it "回退不越界：CWD 无 config.yaml 时不回退（缺默认配置由调用方 fail-fast）" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: ->(_p : String) { false })
          ctx.config_path.should eq(Path[root, "userhome", ".sebas", "config.yaml"])
          ctx.legacy_fallback?.should be_false
        end

        it "旧布局回退警告同时展示配置路径、数据路径与不搬移承诺" do
          root = Sebas.paths_spec_root
          legacy = Path[root, "config.yaml"]
          exists = ->(p : String) { p == legacy.to_s }
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: exists)
          ctx2 = ctx.with_data_dir(nil) # 旧配置省略 data_dir
          ctx2.data_dir.should eq(Path[root, "userhome", ".sebas", "data"])
          warning = ctx2.warnings.find(&.includes?("legacy layout fallback")).should_not be_nil
          warning.should contain(ctx2.config_path.to_s)
          warning.should contain(ctx2.data_dir.to_s)
          warning.should contain("no files are copied or moved")
        end

        it "非回退启动无警告" do
          root = Sebas.paths_spec_root
          ctx = PathContext.resolve(nil, cwd: root, env: {} of String => String,
            home_dir: (root / "userhome").to_s, exists: ->(_p : String) { false })
          ctx2 = ctx.with_data_dir(nil)
          ctx2.warnings.should be_empty
        end

        describe "data_dir 优先级（sebas-home.md §2.3）" do
          # 路径用例平台中立：绝对路径一律从 Dir.tempdir 根构造（Windows 上
          # "/tmp/a" 无盘符不算绝对路径，不能直接用 POSIX 风格字面量）
          it "省略 → <home>/data" do
            home = Path[Dir.tempdir, "h", ".sebas"]
            PathContext.resolve_data_dir(nil, home, Path[Dir.tempdir, "cfg"])
              .should eq(home / "data")
          end

          it "显式 --config 不把默认数据目录改到该文件旁（省略键仍 <home>/data）" do
            home = Path[Dir.tempdir, "h", ".sebas"]
            PathContext.resolve_data_dir(nil, home, Path[Dir.tempdir, "a"])
              .should eq(home / "data")
          end

          it "显式相对值相对实际配置文件目录" do
            cfg_dir = Path[Dir.tempdir, "a"]
            PathContext.resolve_data_dir("state", Path[Dir.tempdir, "h", ".sebas"], cfg_dir)
              .should eq(cfg_dir / "state")
          end

          it "显式绝对值规范化原样保留" do
            root = Sebas.paths_spec_root
            absolute = root / "srv" / "sebas" / "data"
            PathContext.resolve_data_dir(absolute.to_s, root / "h" / ".sebas", root / "a")
              .should eq(absolute)
          end

          it "SEBAS_HOME=/srv/sebas + YAML data_dir: state → <sebas_home>/state" do
            root = Sebas.paths_spec_root
            ctx = PathContext.resolve(nil, cwd: root,
              env: {"SEBAS_HOME" => (root / "srv" / "sebas").to_s})
            ctx2 = ctx.with_data_dir("state")
            ctx2.data_dir.should eq(Path[root, "srv", "sebas", "state"])
          end
        end

        {% if flag?(:unix) %}
          it "POSIX 权限过宽目录只告警（组/其他可写）" do
            dir = Path[Dir.tempdir, "sebas-paths-spec", Random::Secure.hex(4)]
            Dir.mkdir_p(dir)
            File.chmod(dir, 0o777)
            begin
              warning = HomeResolver.wide_permission_warning(dir)
              warning.should_not be_nil
              warning.to_s.should contain(dir.to_s)
            ensure
              File.chmod(dir, 0o700)
            end
          end

          it "权限收紧的目录无告警" do
            dir = Path[Dir.tempdir, "sebas-paths-spec", Random::Secure.hex(4)]
            Dir.mkdir_p(dir)
            File.chmod(dir, 0o700)
            HomeResolver.wide_permission_warning(dir).should be_nil
          end
        {% else %}
          it "Windows 不伪造 ACL 校验：恒无告警" do
            dir = Path[Dir.tempdir, "sebas-paths-spec", Random::Secure.hex(4)]
            Dir.mkdir_p(dir)
            HomeResolver.wide_permission_warning(dir).should be_nil
          end
        {% end %}
      end

      # CLI 接线（拒启路径）的用例在 spec/platform/cli/cli_spec.cr——需要全量
      # src/sebas 依赖；本文件只承载纯函数与注入式解析，不触真实环境。
    end
  end
end
