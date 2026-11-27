on_action "ping" do |payload|
  if payload["cap"]
    {"cap_result" => capability(payload["cap"].to_s, payload["cap_params"] || {})}
  else
    {"pong" => payload["msg"].to_s}
  end
end
