require "atomic"
require "file_watcher"
require "./loader"
require "./schema"
require "../../log"

# 配置热更新四正交件（M1-WP8，design.md §11）：
# ① 触发（file_watcher 目录 watch 主路 + mtime 轮询兜底 + IPC reload 命令；POSIX SIGHUP 留 POSIX 平台）
# ② 先验后换（纯函数校验器复用，失败保旧）
# ③ 换引用（Atomic(Config) 整根替换——EX-W1-03 冒烟已消 §15.1.8）
# ④ 每 turn 快照纪律（消费方从 CURRENT.get 取快照，turn 内语义一致）
module Sebas
  module Platform
    module Config
      # 进程级配置引用（整根替换宿主；EX-W1-03：reference type 全方法可用）
      CURRENT = Atomic(Config).new(Config.new)

      record ReloadResult, accepted : Bool, errors : Array(String), restart_required : Array(String)

      class ReloadManager
        Log = Sebas::Log.for("config.reload")

        DEBOUNCE = 300.milliseconds

        @watcher : ::FileWatcher::Watcher?
        @debouncing = Atomic(Bool).new(false)

        getter config_path : String

        # 组件重应用回调（§11.3 矩阵）：网关注册
        def initialize(@config_path : String | Path, &@on_apply : Config -> Array(String))
          @path = Path[@config_path].expand
          @mtime = File.exists?(@path) ? File.info(@path).modification_time : nil
        end

        # 读盘 → expand_env → YAML → validate → Atomic 换引用 → 组件重应用。
        # 校验失败保旧不崩溃（先验后换），返回 ReloadResult。
        def reload_from_content(raw : String) : ReloadResult
          config = Loader.from_content(raw) # 失败 raise ConfigError/ValidationError
          CURRENT.set(config)
          restart_required = @on_apply.call(config)
          @mtime = File.exists?(@path) ? File.info(@path).modification_time : nil
          Log.info { "config reloaded (path=#{@path})" }
          ReloadResult.new(true, [] of String, restart_required)
        rescue ex : ConfigError | ValidationError
          errors = ex.is_a?(ValidationError) ? ex.errors : [ex.message.to_s]
          Log.warn { "config reload rejected, keeping old config: #{errors.join("; ")}" }
          ReloadResult.new(false, errors, [] of String)
        end

        def reload_from_file : ReloadResult
          reload_from_content(File.read(@path))
        end

        # ① 触发主路：watch 配置文件所在目录（EX-W1-03：单文件 watch 无事件）
        # 按目标路径过滤 + 去抖合并（编辑器原子替换 = Created+Deleted+Renamed 三连，
        # Deleted 不等于配置被删）；mtime 轮询兜底保留（§15.1.7 已消项口径）。
        def start_watching(poll_interval : Time::Span = 2.seconds) : Nil
          parent = @path.parent
          watcher = FileWatcher.watcher
          watcher.watch([parent.to_s], recursive: false) do |event|
            next unless Path[event.path].expand.to_s.downcase == @path.to_s.downcase
            next unless {"Created", "Modified", "Renamed", "Deleted"}.includes?(event.kind.to_s)
            schedule_debounced_reload
          end
          @watcher = watcher

          spawn(name: "sebas-config-poll") do
            loop do
              sleep poll_interval
              reload_if_mtime_changed
            end
          end
          Log.info { "config watch started on #{parent} (target=#{@path.basename})" }
        end

        def stop_watching : Nil
          @watcher.try(&.close)
        end

        private def schedule_debounced_reload : Nil
          return if @debouncing.swap(true)
          spawn do
            sleep DEBOUNCE
            @debouncing.set(false)
            reload_if_mtime_changed
          end
        end

        private def reload_if_mtime_changed : Nil
          return unless File.exists?(@path)
          mtime = File.info(@path).modification_time
          return if @mtime == mtime
          reload_from_file
        rescue ex : ::Exception
          # 轮询兜底自身不得死亡（半写瞬态读文件等）；下轮重试
          Log.warn { "config poll error: #{ex.message}" }
        end
      end
    end
  end
end
