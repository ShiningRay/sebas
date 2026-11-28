# 资源限额对照样本（M3-WP5 review）：与 memory-bomb 同解释器同限额下的
# 低占用成功对照——证明限额配置合法、解释器可在其下完成调用，
# 使 bomb 用例的失败可归因于配额本身而非装配。
on_hook "memory.remember.before" do |payload|
  {ok: true, note: "small footprint"}
end
