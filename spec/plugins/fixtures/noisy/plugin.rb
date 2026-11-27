# 顶层直接伪造 result 帧：宿主必须拒绝后续乱序 registered 帧
sebas_emit_frame({"type" => "result", "request_id" => $sebas_request_id, "ok" => true, "value" => {"fake" => true}})
on_action "ping" do |payload|
  {"pong" => "real"}
end
