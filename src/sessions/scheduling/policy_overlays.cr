# frozen_string_literal: true

require "yaml"

# scheduling policy overlay 解析/叠加（M4.5-WP6，自 policy.cr 拆分——gzjs 体量闸）。
# Policy extend self 已含 resolve_chain/snapshot_from_fields（同文件模块级私有方法
# 经 include 展开——本文件 reopen Policy extend 复用）。
module Sebas
  module Sessions
    module Scheduling
      module Policy
        # overlay 叠加解析（M4.5-WP6）：链 = builtin → gateway.session →
        # gateway overlay → agents.<name>.session → agent overlay（overlay 为
        # partial SessionPolicyConfig，字段级覆盖上一层）；非法 patch 抛 PolicyError
        def resolve_session_with_overlays(gateway : SessionPolicyConfig?, agent : SessionPolicyConfig?,
                                          gateway_overlay : SessionPolicyConfig?,
                                          agent_overlay : SessionPolicyConfig?) : PolicySnapshot
          snapshot_from_fields(resolve_chain(builtin_fields, [gateway, gateway_overlay, agent, agent_overlay]))
        end

        # overlay patch 文本（YAML）→ partial SessionPolicyConfig；YAML 语法错误
        # 转换为 PolicyError（调用方按 400 校验结果返回——gzjz），保留位置信息
        def parse_overlay(patch_yaml : String) : SessionPolicyConfig
          SessionPolicyConfig.from_any(YAML.parse(patch_yaml))
        rescue ex : YAML::ParseException
          raise PolicyError.new("invalid overlay YAML: #{ex.message}")
        end
      end
    end
  end
end
