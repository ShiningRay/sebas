# EX-W1-03 前置冒烟 ②：naqvis/file_watcher Windows 事件语义 demo（design.md §15.1.7 消项）
# 实测结论（2026-11-18，Windows 10 / ReadDirectoryChangesW 后端）：
# 1. watch 单个文件路径不产生任何事件；必须 watch 父目录并按路径过滤。
# 2. 原地覆盖写 → Modified(target)。
# 3. 编辑器原子替换（tmp+rename）→ Created(tmp) + Deleted(target) + Renamed(target)：
#    reload 管线须对目标路径做过滤+去抖，Deleted 不等于配置被删。
# 4. mtime 轮询兜底（M1-WP8 设计内）仍然保留。
require "file_watcher"

dir = ENV["TEMP"]
target = File.expand_path("smoke-watch.yaml", dir)
File.delete(target) if File.exists?(target)
File.write(target, "initial: true\n")

events = Channel(String).new
watcher = FileWatcher.watcher
watcher.watch([dir], recursive: false) do |event|
  events.send("#{event.kind} #{event.path}")
end

sleep 1.seconds
File.write(target, "edited: in-place\n")
sleep 1.seconds
tmp = "#{target}.tmp"
File.write(tmp, "edited: atomic\n")
File.rename(tmp, target)
sleep 1.seconds

watcher.close
got = [] of String
loop do
  select
  when e = events.receive
    got << e
  when timeout 0.5.seconds
    break
  end
end
got.each { |e| puts e }
puts "TOTAL=#{got.size}"
puts got.any?(&.includes?("smoke-watch.yaml")) ? "WATCHER_SMOKE_OK" : "WATCHER_SMOKE_MISSING"
File.delete(target)
