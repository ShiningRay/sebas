# design.md §附 本文档未决事项

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ 上一节：[§16](16-sources.md)

## 附：本文档未决事项（向用户征求决策）

1. **平台命名**：**已定名 Seneschal**（[naming.md](../naming.md) 14 候选撞名全核实；用户可推翻，推翻则替换 development-plan.md 与本文两处 token——development-plan.md 侧已按「Seneschal」替换，届时直接搜该词）。
2. **MVP 首渠道**：建议 email（无公网要求、回调约束最松）先行，企微/飞书次之——若用户有优先渠道偏好请指定。
3. **Gmail 路线**：Gmail API（需 GCP 项目）vs 应用专用密码过渡——涉及个人 GCP 运维意愿。
4. **审批默认模式**：本草案默认 `manual`（每次问），可改 `smart`（LLM 辅助评风险）。
5. **插件 API 首批暴露能力**：**已定为工具/钩子/定时/受控 `memory.backend`**（§12.10）；memory 只经宿主 driver 读写，不开放任意 IO。插件注册工具默认 `risk: high`，不可由插件声明调低，只能由宿主全局策略按工具配置。首版 hook 闭集见 §12.11，自定义触发器、自由 claim 与任意消息改写仍不在首批。
