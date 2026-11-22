require "json"

# NDJSON/IPC 协议（M0-WP7，复用 autobot 713ed632 已验证模式，旁证 §一.7）：
# 一帧一行 JSON；首帧 hello（协议名+版本+caps 协商）；单帧 8MiB 上限。
module Sebas
  module Admin
    module IPC
      PROTOCOL     = "sebas.ipc"
      VERSION      = 1
      MAX_FRAME    = 8 * 1024 * 1024 # 8MiB
      DEFAULT_PORT = 18791
      CAPABILITIES = %w[sessions.read events.subscribe approvals config.status]

      # 首帧 hello（客户端→服务端）
      record Hello, protocol : String, version : Int32, caps : Array(String), token : String? = nil do
        def to_frame : String
          {type: "hello", protocol: protocol, version: version, caps: caps}.to_json
        end

        def self.parse(frame : JSON::Any) : Hello?
          return unless frame["type"]?.try(&.as_s?) == "hello"
          protocol = frame["protocol"]?.try(&.as_s?) || ""
          version = frame["version"]?.try(&.as_i?) || 0
          caps = frame["caps"]?.try(&.as_a?).try(&.map { |cap| cap.as_s? || "" }) || [] of String
          token = frame["token"]?.try(&.as_s?)
          return unless protocol == PROTOCOL && version == VERSION
          new(protocol, version, caps, token)
        end
      end

      # 通用帧：请求 {type, id, ...} / 响应 {type, id, ok, ...} / 推送 {type, ...}
      class Frame
        getter data : Hash(String, JSON::Any)

        def initialize(@data)
        end

        def self.parse(line : String) : Frame?
          return if line.bytesize > MAX_FRAME
          data = JSON.parse(line).as_h?
          return unless data
          new(data)
        end

        def type : String?
          @data["type"]?.try(&.as_s?)
        end

        def id : String?
          @data["id"]?.try(&.as_s?)
        end

        def field(name : String) : JSON::Any?
          @data[name]?
        end

        def to_line : String
          JSON.build do |json|
            json.object do
              @data.each { |k, v| json.field(k) { v.to_json(json) } }
            end
          end
        end
      end

      # 服务端响应构造
      def self.ok(id : String?, payload : Hash(String, JSON::Any) = {} of String => JSON::Any) : String
        {type: "response", id: id, ok: true, payload: payload}.to_json
      end

      def self.error(id : String?, message : String) : String
        {type: "response", id: id, ok: false, error: message}.to_json
      end
    end
  end
end
