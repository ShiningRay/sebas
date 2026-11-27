on_action "install" do |payload|
  {"ran" => "install"}
end
on_action "enable" do |payload|
  {"ran" => "enable"}
end
on_action "disable" do |payload|
  {"ran" => "disable"}
end
on_hook "memory.remember.before" do |payload|
  {"ran" => "hook", "text" => (payload["entry"] || {})["text"].to_s}
end
