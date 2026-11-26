# TokenProvider 统一抽象（M0-WP4 骨架，M1-WP3 全量：design.md §5.3）。
# 三渠道 token 生命周期同构：缓存 + 临期提前刷新 + 失效重取。
# email 应用专用密码路线无 token 流——StaticTokenProvider 占位。
require "http/client"
require "json"
require "uri"

module Sebas
  module Channels
    module Common
      record Token, value : String, expires_at : Time do
        def expired?(buffer : Time::Span = 30.minutes) : Bool
          Time.utc >= expires_at - buffer
        end
      end

      abstract class TokenProvider
        # 返回有效 token：缓存命中直返；临期（剩余<30min）提前刷新
        abstract def token : Token

        # 上游报失效（401/错误码）时标记失效，下次 token 重取
        abstract def invalidate : Nil
      end

      # 静态 token（email 应用专用密码；永不过期）
      class StaticTokenProvider < TokenProvider
        def initialize(@secret : String)
        end

        def token : Token
          Token.new(@secret, Time.utc + 3650.days)
        end

        def invalidate : Nil
          # 静态凭据无可刷新语义；换 secret 走配置热更新（M1-WP8）
        end
      end

      # 通用缓存型 provider：fetch 回调由渠道子类注入（M1-WP3 企微/飞书）
      class CachedTokenProvider < TokenProvider
        @cached : Token?
        @mutex = Mutex.new

        def initialize(@refresh_buffer : Time::Span = 30.minutes, &@fetch : -> Token)
        end

        def token : Token
          @mutex.synchronize do
            cached = @cached
            return cached if cached && !cached.expired?(@refresh_buffer)
            @cached = @fetch.call
          end
        end

        def invalidate : Nil
          @mutex.synchronize { @cached = nil }
        end
      end

      # 企微 gettoken（§5.3）：expires_in 7200s；有效期内重复获取返回相同 token
      class WecomTokenProvider < CachedTokenProvider
        def initialize(corpid : String, secret : String, base_url : String = "https://qyapi.weixin.qq.com")
          super(30.minutes) do
            resp = HTTP::Client.post("#{base_url}/cgi-bin/gettoken?corpid=#{URI.encode_www_form(corpid)}&secret=#{URI.encode_www_form(secret)}")
            body = JSON.parse(resp.body)
            errcode = body["errcode"]?.try(&.as_i?) || 0
            raise TokenFetchError.new("wecom gettoken errcode=#{errcode} errmsg=#{body["errmsg"]?}") unless errcode.zero? && resp.success?
            expires = body["expires_in"]?.try(&.as_i?) || 7200
            Token.new(body["access_token"].as_s, Time.utc + expires.seconds)
          end
        end
      end

      # 飞书 tenant_access_token（§5.3）：最长 2h 以 expires_in 为准；Header 预留 4KB（§15.2.19）
      class LarkTokenProvider < CachedTokenProvider
        def initialize(app_id : String, app_secret : String, base_url : String = "https://open.feishu.cn")
          super(30.minutes) do
            resp = HTTP::Client.post("#{base_url}/auth/v3/tenant_access_token/internal",
              headers: HTTP::Headers{"Content-Type" => "application/json"},
              body: {app_id: app_id, app_secret: app_secret}.to_json)
            body = JSON.parse(resp.body)
            code = body["code"]?.try(&.as_i?) || 0
            raise TokenFetchError.new("lark tenant_access_token code=#{code} msg=#{body["msg"]?}") unless code.zero? && resp.success?
            expires = body["expire"]?.try(&.as_i?) || 7200
            Token.new(body["tenant_access_token"].as_s, Time.utc + expires.seconds)
          end
        end
      end

      class TokenFetchError < ::Exception; end
    end
  end
end
