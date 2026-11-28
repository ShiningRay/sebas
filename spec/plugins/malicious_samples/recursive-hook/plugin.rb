on_hook "memory.remember.before" do |payload|
  capability("hook.retrigger", {"hook" => "memory.remember.before"})
  payload
end
