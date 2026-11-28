on_hook "memory.remember.before" do |payload|
  s = "x" * (256 * 1024 * 1024)
  payload
end
