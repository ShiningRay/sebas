# development-plan C. 首迭代执行计划（W1–W2）

> 导航：[设计总览](../design.md) ｜ [文档索引](../README.md) ｜ [计划总览](../development-plan.md) ｜ 上一节：[B.9](schedule/m5-m7.md) ｜ 下一节：[D](coverage.md)

## C. 首迭代执行计划（W1–W2）

> 目标：交付 M0 骨架与首条纵深（配置→持久层开工），并完成影响 M1 排期的两项前置冒烟。单人全职，块容量 5 pd/周。

| 块 | 任务 ID | 对应 WP | 内容 | 交付物 | 验证方式 | 预估（pd） | 依赖 |
|---|---|---|---|---|---|---|---|
| W1-D1 | EX-W1-01 | M0-WP1 | 基线记录：`crystal --version`、空仓 `crystal spec`/`./bin/ameba`/`make release` 试跑 | 基线记录 | 命令输出可复现 | 0.5 | 无 |
| W1-D1~D2 | EX-W1-02 | M0-WP1 | 项目骨架：shard.yml、§13 目录空实现、构建脚本、统一日志 | 可编译单二进制骨架 | 三命令全绿；`--version` 可执行 | 1–1.5 | EX-W1-01 |
| W1-D2~D3 | EX-W1-03 | 前置冒烟 | **Atomic(Config) 编译冒烟**（`Atomic#swap` 详注歧义实测，5 分钟级 [来源: design.md §15.1.8]）+ **naqvis/file_watcher Windows demo**（~10 行验证编辑器原子写事件语义 [来源: design.md §15.1.7]） | 冒烟记录二则（结果无论正负均回写 design.md §15.1 消项） | 编译/运行输出留档 | 0.5–1 | EX-W1-01 |
| W1-D3~D5 | EX-W1-04 | M0-WP2 | 配置加载与 schema：loader 纯函数校验器+宏样板 | config 模块+示例 YAML+spec | 坏配置报错含行号；合法配置出 typed 对象 | 1.5–2 | EX-W1-02 |
| W2-D1~D3 | EX-W2-05 | M0-WP3 | 持久层开工：SQLite WAL 四表+requestId 幂等+三明治次序 spec | store 模块+spec | 次序断言+排重用例通过 | 2.5–3 | EX-W1-04 |
| W2-D3~D5 | EX-W2-06 | M0-WP4 | email 适配器开工：IMAP IDLE（应用专用密码）+markdown 转换器【A8】 | channels/email+收信 spec | 真实邮箱收信入总线（集成口径） | 1.5–2.5 | EX-W1-04 |

- W1 块合计 3.5–5 pd（容量 5 内）；W2 块合计 4–5.5 pd，**超容量 ≤0.5 pd 顺延 W3-D1**，不压缩 EX-W2-05 spec 范围（Tessell 溢出规则同款）。[推演]
- EX-W2-06 集成测试依赖真实测试邮箱就绪——外部依赖第 1 项（E 节），须 W1 期间完成申请。
