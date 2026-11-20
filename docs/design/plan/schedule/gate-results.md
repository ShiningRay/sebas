# development-plan B.4–B.7 M0–M3 门禁结论

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 上一节：[B.3](gates.md) ｜ 下一节：[B.8](m4.md)

## B.4 M0 门禁结论（2026-11-19）

M0 三条验收全过（收发全链路 / 强杀续跑 / 发信幂等），门禁三命令绿；证据与边界记录见 [review/m0-gate.md](../../review/m0-gate.md)。真实邮箱集成验收挂外部依赖 E.1（用户测试邮箱未就绪），协议层已按假服务器全链路验证。M1 允许开工。

## B.5 M1 门禁结论（2026-11-19）

M1 九包全部落地；§14 M1 七条验收全过（N 账号不串扰 / receiveid / token 刷新重取 / 限流退避 / 热更新三态 / 端口 restart 提示），门禁三命令绿；证据见 [review/m1-gate.md](../../review/m1-gate.md)。企微 AIBot 主路（§15.1.1 首日核对）与飞书 WS 帧协议（对照官方 SDK 核对）为真实账号集成前置，回调/webhook 形态已协议完整；不阻塞 M2 开工。

## B.6 M2 门禁结论（2026-11-19）

M2 六包全部落地；§14 M2 四条验收全过（崩溃重放幂等 / 审批超时 deny 注入时钟实测 / 预算熔断留痕 / runs 回放审计），门禁三命令绿；证据见 [review/m2-gate.md](../../review/m2-gate.md)。期间关键缺陷回写：intents_with_prefix LIKE 参数漏传（已修，详见 m2-gate.md）。M3 允许开工。

## B.7 M3 门禁结论（2026-11-19）

M3 WP1/2/3 验收全过（max_hops=4 拦截互发死循环 / 并发上限排队不失控 / subagent 崩溃经 ownerTaskId 找回同一子任务），门禁三命令绿。WP4~6（mrb.cr 插件层）按 B.3 预设条款降级为技术预研：mrb.cr 甄别通过（84/84）但本机 Windows 工具链当日无法链接新 mruby.exe（环境级 blocker，恢复路径已列），架构与构件（sebas-stdio gem、build_config 补丁、子进程沙盒解释器方案）已产出——详见 [review/m3-plugin-feasibility.md](../../review/m3-plugin-feasibility.md) 与 [review/m3-gate.md](../../review/m3-gate.md)。M0–M2 全部产品化验收保持有效。
