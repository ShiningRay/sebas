on_hook "memory.remember.before" do |payload|
  t = Time.now
  while Time.now - t < 60
  end
end
