# 应用根目录：`~/.sebas` 与 `SEBAS_HOME` 路径契约（Proposal）

> 状态：**accepted**（2026-11-27 定稿），已排入 M5 · v0.3.0；尚未实现。
> Tracking：[#274](https://github.com/ShiningRay/sebas/issues/274)。
> 裁决：[Maintainer 定稿与排期](https://github.com/ShiningRay/sebas/issues/274#issuecomment-7210890184)。
> 关联：[核心概念 §3.4](../spec/03-core-concepts.md)、[热更新 §11](../spec/11-hot-reload.md)、[初始化提案](interactive-setup.md)。

## 1. 问题与目标

当前 gateway 未传 `--config` 时按启动工作目录读取 `config.yaml`；数据默认是相对配置文件的 `data`，persona 校验却使用进程工作目录。命令从不同目录或服务管理器启动时，缺少稳定的用户级位置。

本提案引入唯一应用根目录 `home`，默认 `~/.sebas`，由 `SEBAS_HOME` 覆盖。它只统一路径解析，不引入新的凭据存储、目录沙箱或自动迁移机制。

```text
~/.sebas/
├── config.yaml
└── data/
    ├── sebas.db
    ├── secrets.vault
    └── ...
```

## 2. 解析契约

### 2.1 根目录与配置文件

1. 仅当 `SEBAS_HOME` 未设置时，取跨平台用户主目录下的 `.sebas`；已设置且非空白时取其值。
2. 已设置但为空白的 `SEBAS_HOME` 拒绝启动并显示变量名，不回退到默认目录或工作目录。
3. `~` 在路径解析层展开；相对 `SEBAS_HOME` 以启动时工作目录为基准立即绝对化。解析后进程内不再改变。
4. 未传 `--config` / `-c` 时，配置文件为 `<home>/config.yaml`。显式参数只决定配置文件，不反向改变 `home`。
5. 默认配置不存在仍 fail-fast，错误包含实际查找的绝对路径；不自动生成、复制或覆盖配置。
6. Windows 同样使用用户主目录下的 `.sebas`；本期不引入 XDG、`%APPDATA%` 或多套默认路径。

### 2.2 数据与配置内相对路径

`gateway.data_dir` 的缺省值在解析期决定：省略时为 `<home>/data`。显式值保持现有配置形状：

- 绝对 `data_dir` 原样规范化；
- 相对 `data_dir` 相对实际加载的配置文件所在目录解析；
- 省略键不向 YAML 配置树注入机器相关绝对路径，热更新仍比较配置本身的语义；
- 显式 `--config` 不会把默认数据目录改到该文件旁边。

首期纳入 `agents.<name>.persona_file` 的**校验基准**：相对路径与相对 `data_dir` 一样，以实际配置文件目录为基准。现状核实（2026-11-27）：`persona_file` 只有 `Config::Loader` 的悬空引用校验与 `RegistryDualView` 的元数据透传，**运行期没有读取该文件的消费者**（agent 人格实际来自 `data_dir/agents/<id>/SOUL.md`）。因此本包只统一校验基准，不声称既有运行期读取链会随之改变；若要让配置人格生效，另立接线范围。

`plugins.dir` 同样按配置目录解析；`plugins.interpreter` 是程序查找规则，不是数据目录，本期不强制改成 `home` 下路径。其他尚无统一配置字段的资源路径，不借“所有路径”名义隐式扩张。

### 2.3 优先级示例

| 输入 | 配置文件 | 数据目录 |
|---|---|---|
| 无显式输入 | `~/.sebas/config.yaml` | `~/.sebas/data` |
| `SEBAS_HOME=/srv/sebas` | `/srv/sebas/config.yaml` | `/srv/sebas/data` |
| `SEBAS_HOME=/srv/sebas`，YAML 写 `data_dir: state` | `/srv/sebas/config.yaml` | `/srv/sebas/state` |
| `--config /tmp/a/config.yaml`，无 `SEBAS_HOME` | `/tmp/a/config.yaml` | `~/.sebas/data` |
| 上例且 YAML 写 `data_dir: state` | `/tmp/a/config.yaml` | `/tmp/a/state` |

## 3. 实现边界

新增 `src/platform/config/paths.cr`，提供可注入环境、主目录和启动工作目录的 `Paths` / `HomeResolver`。CLI 在检查配置文件之前构造一次路径上下文，再将结果传给 Loader、Gateway 与热更新。

- Loader 增加携带配置目录的入口；无路径上下文的纯内容入口保留既有显式路径测试语义，不能私自读取真实主目录。
- Gateway 接收解析后的绝对数据路径；vault、SQLite、会话、工作流和 IPC discovery 继续以该路径为根。
- 相对 persona 的 loader 校验使用同一基准；本包不新增 persona 运行期读取（现状无消费者，见 §2.2）。
- `home` 与解析后的数据路径是启动资源，不属于可热更新配置。热更新重新解析同一配置文件内的相对资源路径，但不重新读取 `SEBAS_HOME`，也不改换数据库、vault 或 IPC discovery；`data_dir` 变更一律标记 restart-required，不允许半途换根。环境变量变更需重启。
- `help` / `version` 保持无副作用；`gateway` 与未来 `setup` 等需要配置的命令共用 resolver。`crashwrite` 的显式演练路径不变。
- POSIX 目录权限过宽只告警，不新增拒启；Windows 不假装具备等价 ACL 校验。现有配置、vault 与数据库校验不放宽。

## 4. 兼容与迁移

采用一个版本的受限回退：仅当未显式传 `--config`、新默认配置不存在、启动工作目录存在 `config.yaml` 时，读取旧配置并输出迁移警告。显式路径、空 `SEBAS_HOME` 和其他失败均不回退。

- 回退不自动复制或搬移任何文件，不合并两个配置，也不主动改变磁盘上的数据库位置。
- 旧配置省略 `data_dir` 时，数据仍按新契约取 `<home>/data`；因此 gateway **实际使用的数据库/vault 路径可能改变**，虽然旧文件原地保留。警告须同时展示配置与实际数据路径及这一后果，不得让用户误以为已沿用旧数据。
- 旧配置显式 `data_dir: data` 时，按实际旧配置目录解析，数据位置不变。
- 文档给出显式 `--config` 与搬迁清单；迁移由用户执行，不由 gateway 代做。

`setup` 后续使用同一 resolver，默认写 `<home>/config.yaml`、创建 `<home>/data`；已有文件仍须按其事务与确认契约处理。#223 若接受，应把默认 `.env` 改为 `<home>/.env`，不在本工作包实现 dotenv。

## 5. 测试主目录隔离（Maintainer 附加约束）

任何 spec、端到端脚本及手工自动验收不得读写真实 `~/.sebas`，不得依赖开发者机器已有的 `HOME`、`SEBAS_HOME` 或配置。

- 环境覆盖等非默认路径用例在 `Dir.tempdir` 下建独立根目录并显式设置 `SEBAS_HOME`。
- 验证默认 `~/.sebas` 的用例必须先取消 `SEBAS_HOME`，再注入临时 `HOME`；不得让显式根目录覆盖被测的默认分支。两类用例均须覆盖。
- 环境变量修改在 `ensure` 中恢复原值；Windows 主目录测试使用平台实际读取的变量或 resolver 注入，不仅设置 POSIX 的 `HOME`。
- 并行运行不共享全局环境或目录。路径解析优先用纯函数注入；进程级用例如须改环境，应串行或使用隔离子进程，不能靠测试顺序碰巧通过。
- 启动失败用例也须先隔离主目录，防止“配置不存在”测试意外读到用户真实配置。
- 三平台覆盖绝对/相对根目录、空白值、`~`、空格与非 ASCII 路径；权限告警按平台分支验证。
- 增加防回归断言：测试完成后，除临时根目录外没有新建配置、数据库、vault 或 IPC discovery。

## 6. 验收与非目标

验收至少包括：默认值、环境覆盖、显式 CLI/YAML 优先级、受限旧布局回退、缺配置报错、热更新路径稳定、persona 与插件目录一致解析，以及真实临时目录上的 gateway 初始化。完整 Crystal 质量门禁由实现工作包执行。

本期不做自动数据迁移、XDG 多目录规范、端口自动分配、系统服务安装、dotenv、权限硬拒或新的沙箱边界。同机多实例以不同 `home` 隔离文件，端口仍由用户配置。

## 7. 裁决记录

Maintainer 于 2026-11-27 接受提案正文的目标与建议方案，明确纳入 M5，并要求测试显式隔离用户主目录。原提案开放项 1–6 未逐项明示选择；本快照按其建议默认值整理：

| 项目 | 采用值 |
|---|---|
| 旧布局 | 一个版本的受限回退，只读旧配置并警告，不搬移 |
| persona 等相对资源 | 纳入首期，统一相对配置目录 |
| `.env` | 留 #223 联动，不在本包实现 |
| 多实例 | 隔离文件，不自动分配端口 |
| `setup` | 复用 resolver，沿用已有文件保护 |
| POSIX 权限 | 过宽告警，不拒启 |

这些默认值来自已定稿评论对原提案的整体接受；细化项仍可在实现前由 Maintainer 明确推翻，本文不把未逐项勾选伪装成独立裁决。
