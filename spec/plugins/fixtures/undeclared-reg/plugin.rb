on_action "ping" do |payload|
  {"pong" => "ok"}
end
on_action "extra" do |payload|
  {"extra" => true}
end
