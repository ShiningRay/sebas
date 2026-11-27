require "json"
require "./manifest"

# 插件注册表（M3-WP4，#16）：扫描插件目录（每插件一个子目录，含
# manifest.json + 入口脚本），逐份 fail-closed 解析——单份非法只拒该份
# 并记可读错误，不炸其余插件。
#
# WP4 边界：装载的是「开发/源码布局」（目录直扫）；.sebas-plugin 包格式、
# versions/staging/registry.json 原子指针、启停状态机归 M3-WP6。本层把
# 目录内全部合法插件视为已启用（§12.5 开发语义：每次调用从盘读脚本，
# 改动即影响新调用）。
module Sebas
  module Plugins
    class Registry
      Log = Sebas::Log.for("plugins.registry")

      @plugins = Hash(String, LoadedPlugin).new
      @mutex = Mutex.new

      record LoadReport, loaded : Array(String), errors : Array(String) do
        def ok? : Bool
          errors.empty?
        end
      end

      # 目录扫描装载：目录不存在/单份解析失败/入口缺失/ID 冲突都进 errors
      # （可读、定位到目录），合法插件照常装载。
      def load_dir(dir : Path) : LoadReport
        loaded = Hash(String, LoadedPlugin).new
        errors = [] of String
        unless Dir.exists?(dir)
          errors << "plugins dir not found: #{dir}"
          return commit(loaded, errors)
        end
        Dir.children(dir).sort.each do |entry|
          plugin_dir = dir / entry
          next unless Dir.exists?(plugin_dir)
          manifest_path = plugin_dir / "manifest.json"
          unless File.exists?(manifest_path)
            errors << "#{plugin_dir}: missing manifest.json"
            next
          end
          begin
            manifest = Manifest.parse(File.read(manifest_path))
          rescue ex : ManifestError
            errors << "#{plugin_dir}: #{ex.message}"
            next
          end
          entry_file = plugin_dir / (manifest.entrypoint || "plugin.rb")
          unless File.exists?(entry_file)
            errors << "#{plugin_dir}: entrypoint '#{manifest.entrypoint || "plugin.rb"}' not found"
            next
          end
          if existing = loaded[manifest.id]?
            errors << "#{plugin_dir}: duplicate plugin id '#{manifest.id}' (already loaded from #{existing.dir})"
            next
          end
          loaded[manifest.id] = LoadedPlugin.new(plugin_dir, manifest)
        end
        commit(loaded, errors)
      end

      private def commit(loaded : Hash(String, LoadedPlugin), errors : Array(String)) : LoadReport
        @mutex.synchronize { @plugins = loaded }
        ids = loaded.keys
        ids.sort!
        LoadReport.new(ids, errors)
      end

      def plugin(id : String) : LoadedPlugin?
        @mutex.synchronize { @plugins[id]? }
      end

      def ids : Array(String)
        ids = @mutex.synchronize { @plugins.keys }
        ids.sort!
      end

      # hook → 订阅插件索引（§12.2：manifest 声明为授权上限，未声明不派发）。
      def subscribers_for_hook(hook : String) : Array(LoadedPlugin)
        @mutex.synchronize do
          subscribers = @plugins.values.select(&.manifest.declares_hook?(hook))
          subscribers.sort_by!(&.id)
          subscribers
        end
      end
    end
  end
end
