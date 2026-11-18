# Binding 路由（M1-WP1）：most-specific 纯函数路由表（design.md §3.2）。
# 层级：exact peer > account+peer wildcard > account > channel peer exact > channel > fallback。
# 同层按配置声明顺序；fail-closed：无匹配 → nil（调用方丢弃并记审计日志）。
module Sebas
  module Routing
    record BindingRule, channel : String, account : String, peer : String, agent : String

    module Table
      extend self

      # 解析入站事件 → agent_id；无匹配 binding 返回 nil（fail-closed，§3.2）
      def resolve(bindings : Array(BindingRule), channel_type : String,
                  account_id : String, peer : String) : String?
        best : BindingRule? = nil
        best_rank = -1
        bindings.each do |binding|
          next unless binding.channel == channel_type || binding.channel == "*"
          rank = specificity(binding, account_id, peer)
          next if rank < 0
          # 同级先声明者优先（rank 相同不替换）
          best = binding if rank > best_rank
          best_rank = rank if rank > best_rank
        end
        best.try(&.agent)
      end

      # 特异性分值：不匹配 -1；账号+exact peer 50 > 账号级 40 > 渠道+exact peer 20 > fallback 0
      private def specificity(binding : BindingRule, account_id : String, peer : String) : Int32
        return -1 unless binding.account == account_id || binding.account == "*"
        return -1 unless binding.peer == peer || binding.peer == "*"

        if binding.account == "*" && binding.peer == "*"
          0 # fallback
        elsif binding.account == account_id && binding.peer == peer
          50 # 账号级精确 peer
        elsif binding.account == account_id
          40 # 账号级通配 peer
        else
          20 # 渠道级精确 peer
        end
      end
    end
  end
end
