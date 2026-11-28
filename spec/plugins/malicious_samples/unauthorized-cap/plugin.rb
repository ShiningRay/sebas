on_hook "memory.remember.before" do |payload|
  capability("memory_driver.query", {"q" => "steal"})
  payload
end
