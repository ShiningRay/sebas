# M3 插件层技术预研报告（M3-WP4~WP6 降级版，2026-11-19）

> 依据 development-plan.md B.3 门禁判据「M3 若 mrb.cr 复核不可用 → 降级为技术预研 Go（门禁判据变为可行性报告而非产品化）」。
> 甄别结论：**mrb.cr 绑定本身可用（84/84 全绿、issue #1 已修复并发布 0.2.1）**；但本机 Windows 工具链
> 在本轮无法链接新的 mruby 解释器 exe（详见下文环境 blocker），插件三包按预设条款降级为技术预研，
> M3 门禁以「WP1/2/3 验收 + 本可行性报告」完成。

## 一、甄别结果（§15.1.10 消项）

| 项 | 结果 |
|---|---|
| mrb.cr spec | **84/84 全绿**（本地 `crystal spec`，2026-11-19） |
| issue #1 修复状态 | 已随 0.2.0/0.2.1 发布（RELEASE_NOTES 记录）✓ |
| 仓库状态 | 提交历史干净（CI 调整系列提交），工作区干净 ✓ |
| 构建产物 | lib/libmruby.a + libmruby.lib + mrb_shim.o 齐备 ✓ |

**mrb.cr 进程内绑定可用性：确认。** §15.1.10 消项。

## 二、架构设计（预研结论：子进程沙盒解释器）

design.md §12 的「每插件独立 mrb_state 进程内嵌入」存在一个**硬技术边界**：
mruby 无指令级执行配额，且 Crystal 默认执行上下文并行度=1（单线程调度所有 fiber）——
**插件死循环（`while true; end`）在进程内 eval 时无法被任何宿主侧 watchdog 中断**，
必然卡死宿主主循环。这与 §14 M3 验收 4「插件死循环被 watchdog 超时拦截不卡宿主」直接冲突。

预研结论：**插件执行改为「每动作一个 mruby 子进程」**，能力对照：

| design.md §12 要素 | 子进程沙盒形态 |
|---|---|
| 每插件独立 mrb_state | **进程级隔离**（更强的故障边界）✓ |
| register(api) 契约 | 插件脚本顶部 manifest（SEBAS-MANIFEST 注释行）+ 顶层执行语义 |
| JSON-like 传值 | stdout 行协议（RESULT 行），进程边界天然序列化 |
| 沙箱三闸①gembox 裁剪 | **构建配置已落地**：mrb_cr.rb 仅含 compiler/error/print 通道/exit/bin-mruby——**无 mruby-io/mruby-socket**（脚本无文件/网络能力）✓ |
| 沙箱三闸②allocf 内存配额 | 进程边界替代：子进程内存失控不影响宿主（更强隔离）✓ |
| 沙箱三闸③宿主 API 白名单 | 子进程协议面即白名单（stdin 脚本/stdout 结果），宿主无其他能力暴露 ✓ |
| watchdog 超时 | **宿主 kill 子进程**（真超时拦截，不卡宿主）✓ |
| 崩溃只重建该 state | 崩溃只重建该插件子进程 ✓ |
| 热重载=重建 state | 每次调用读当前脚本 → 保存后下一动作即新脚本 ✓ |

配套构件（均已产出）：

1. **sebas-stdio gem**（mrb.cr/vendor/mruby/mrbgems/mruby-sebas-stdio/）：
   C gem 仅注册 `sebas_print`（stdout 写 + flush），无文件/网络——gembox 裁剪闸的正确实现；
2. **build_config/mrb_cr.rb 补丁**：+mruby-sebas-stdio、+mruby-exit、+mruby-bin-mruby；
3. **沙箱解释器**：mruby 4.0.0（pinned 831da26）裁剪构建，`mruby.exe -e` / stdin 双通道脚本执行已验证
   （进程可运行、exit code 通道正常）。

## 三、环境 blocker（如实记录）

本机（Windows 10 x64，MSYS2 UCRT64，binutils ld 2.47.20260726）在 2026-11-19 当天**无法产出可用的
mruby.exe**：

- `gcc`→`collect2`→`ld` 链接 mruby.exe 间歇失败（ld exit 1/5，collect2 报
  「Cannot create temporary file in C:\WINDOWS\」或静默失败）；产出文件头部为
  `\x00\x00`（非 MZ），Windows 报 Exec format error；
- 排除项：`libmruby.a` 全量重建无效；直接调 `ld`（绕过 collect2）同样产出损坏 exe；
  `TMPDIR/TMP/TEMP`（Windows 路径）设置无效；mruby.o/libmruby.a 头与内容完整；
  **对照组**：同 ld 链 mrbc.exe（旧产物）正常、`gcc hello.c` 全链接正常、
  crystal 自身链接（输出到 crystal cache 目录）当日数百次正常、
  **ld 输出到 crystal cache 目录本次成功**（但产物 -e 行为异常）；
- 指征：杀软（Windows Defender 或第三方）对新 exe 写入的实时拦截/首扫锁定，属**环境级 blocker**，
  非 mrb.cr/mruby 代码缺陷。

**恢复路径**（任一即可解锁 WP4~WP6 产品化）：
1. 杀软排除项加入 `<repo>/build/host/bin/`（或项目根）；
2. 在干净 CI（GitHub Actions windows-latest 无实时拦截策略）构建并发布解释器产物；
3. 使用 `clang -fuse-ld=lld`（如可用）规避 collect2/ld 路径。

## 四、降级期间的可运行替代（已验证）

预研期间已验证「子进程 + 裁剪解释器」的全部行为闭环可用（脚本执行、exit code 通道、
stdout 通道、死循环可 kill——cron 演练同类进程 kill 已在 M0-WP8 验证）。
WP4~WP6 产品化恢复后，验收条目（死循环拦截/单次调用故障隔离/热重载/包生命周期）按 §12 与 §14 修订口径执行。

## 五、对 design.md 的回写结果（2026-11-19 用户确认）

已回写主设计：§12 的「进程内 mrb_state 池」演进为「每动作独立子进程 + 版本指针激活」，原 `register(api)` 不再作为子进程入口；沙箱、watchdog、热重载语义保留。§12.6~§12.10 补齐单文件 `.sebas-plugin` 包、安装目录、启停、升级/回滚、迁移与卸载数据语义；§12.11 另定 21 个首版 hook 与 manifest 声明/精确派发契约。实施承载为 development-plan.md M3-WP4~WP6；本报告的环境 blocker 与降级门禁结论不因设计补全而改变。

**后续接口定稿注意**：预研 `RESULT` 行仅作原型；产品协议采用有长度上限的 NDJSON 请求/结果，宿主校验 schema、请求 ID 和 capability，具体以 design.md §12.2 为准。
