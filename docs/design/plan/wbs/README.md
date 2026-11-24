# A. WBS 工作包分解总览（M0–M8）

> 导航：[设计总览](../../design.md) ｜ [文档索引](../../README.md) ｜ [计划总览](../../development-plan.md) ｜ 下一节：[0](../00-baseline.md)

> 拆包依据：design.md §13 模块归属 + §14 各期验收条目（**§14 每条验收必须落进至少一个 WP 的验收标准**，映射关系逐条标注）。每包字段：目标/范围/交付物/依赖/验收（可测）/估时/风险。

| 期 | 文件 | 行数 | 估时 | 期级验收主线 |
|---|---|---|---|---|
| M0 | [MVP（单账号闭环）](m0-mvp.md) | 77 | 17–25 pd | 收发全链路、强杀重启续跑、发信幂等 |
| M1 | [多账号完备 + 配置热更新](m1-multi-account.md) | 77 | 19.5–30 pd | 同渠道 N 账号不串扰、运行中改配置生效 |
| M2 | [编排完备](m2-orchestration.md) | 53 | 12.5–19 pd | 崩溃重放幂等、审批超时 deny、预算熔断 |
| M3 | [协作 + 插件脚本层](m3-collab-plugins.md) | 53 | 15–24 pd | max_hops 防环、并发上限、mruby 插件层 |
| M4 | [Fork/Join 影分身 + Agent 团队 + 会话治理](m4-fork-join.md) | 151 | 27.5–44.5 pd | fork/join 语义、会话元数据与休眠归档 |
| M5 | [持久意图、唤醒与提醒闭环](m5-commitments.md) | 133 | 22–36 pd | v0.3.0；九态生命周期、提醒纪律、cron 归位 |
| M6 | [外部日历/TODO 只读镜像与变化驱动重估](m6-calendar-mirror.md) | 87 | 20–34 pd | v0.4.0；三 provider 适配器、同步元数据、变化只触发评估 |
| M7 | [受控投影与撤销审计](m7-projection.md) | 42 | 6–10 pd | v0.5.0；写路径启停、整批撤销、审计 |
| M8 | [渠道扩展（Slack + Telegram）](m8-channels.md) | — | 10.5–16.5 pd | v0.6.0；Socket Mode + long-poll 多账号收发 |

合计 150–239.5 pd（M0–M8 全程序），逐周排期见 [B.2](../schedule/weekly.md)，依赖图见 [B.1](../schedule/dag.md)。

## 期与版本的对应

| 期 | 版本 | milestone |
|---|---|---|
| M0–M3 | v0.1.0（已发布） | 已完成，门禁结论见 [B.4–B.7](../schedule/gate-results.md) |
| M4 | v0.2.0 | #2 v0.2.0（Fork/Join 影分身） |
| M5 | v0.3.0 | #3 v0.3.0（承诺与提醒闭环） |
| M6 | v0.4.0 | #4 v0.4.0（外部日历只读镜像与重估） |
| M7 | v0.5.0 | #5 v0.5.0（受控投影与撤销审计） |
| M8 | v0.6.0 | M8 v0.6.0（渠道扩展 Slack + Telegram） |
