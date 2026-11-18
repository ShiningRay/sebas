# EX-W1-03 前置冒烟记录（M1-WP8 开工前置，development-plan.md E.2）

> 日期：2026-11-18。环境：Windows 10 x64（10.0.26300）、Crystal 1.22.1（x86_64-w64-windows-gnu）、MSYS2 UCRT64。
> 依据 development-plan.md C 节 EX-W1-03 与 design.md §15.1.7/§15.1.8：结果无论正负均回写 design.md 消项。

## 冒烟 ①：`Atomic(Config)` 编译冒烟（§15.1.8）

脚本：`dev/smoke/atomic_config_smoke.cr`（reference type `SmokeConfig` 作泛型参数）。

| 方法 | 编译 | 运行 |
|---|---|---|
| `Atomic(T).new(ref)` | ✅ | 初值读取正常 |
| `get` / `set` | ✅ | 整根替换生效 |
| `swap` | ✅ | 返回旧引用，语义正确 |
| `compare_and_set` | ✅ | 返回 `(旧值, 成功标志)`，成功路径正常 |
| 跨 fiber `get`（spawn 内取快照） | ✅ | 快照一致 |

输出留档：

```text
get:        initial
set:        set
swap:       set -> swap
cas:        true swap -> cas
cross-fiber get: cas
ATOMIC_SMOKE_OK
```

**结论：§15.1.8 消项（PASS）**——`Atomic#swap` 详注「T cannot contain any reference types」指算术版 swap 的注释歧义，实测 reference type 全部方法可用；`Atomic(Config)` 整根替换路线成立。

## 冒烟 ②：`naqvis/file_watcher` Windows demo（§15.1.7）

脚本：`dev/smoke/file_watcher_demo.cr`。shard 为 naqvis/file_watcher@main（35cb809，无版本 tag；API 为 `FileWatcher.watcher` + `watch(paths, recursive:, &block)` + `close`，事件 `kind ∈ {Created, Modified, Deleted, Renamed, Metadata}`）。

### 实测结果

1. **watch 单个文件路径 → 零事件**（Windows ReadDirectoryChangesW 后端不投递文件级 watch）。
2. **watch 父目录（recursive: false）+ 按路径过滤 → 事件正常**。
3. 原地覆盖写 → `Modified(target)`。
4. 编辑器原子替换（tmp+rename 覆盖）→ `Created(tmp)` + `Deleted(target)` + `Renamed(target)` 三连事件，rename 配对由 shard 内部聚合（safety-rescan 间隔内）。

输出留档：

```text
Modified C:\Users\ShiningRay\AppData\Local\Temp\smoke-watch.yaml
Modified C:\Users\ShiningRay\AppData\Local\Temp\smoke-watch.yaml
Created C:\Users\ShiningRay\AppData\Local\Temp\smoke-watch.yaml.tmp
Deleted C:\Users\ShiningRay\AppData\Local\Temp\smoke-watch.yaml
Renamed C:\Users\ShiningRay\AppData\Local\Temp\smoke-watch.yaml
TOTAL=5
TARGET_EVENTS_OK
```

**结论：§15.1.7 消项（PASS，带两条实现约束）**——
- file_watcher 可用作 M1-WP8 触发主路，但 **watch 对象必须是配置文件所在目录**，管线内按目标路径过滤；
- 原子替换会产生 `Deleted`+`Renamed` 序列：**`Deleted` 不得解释为「配置被删」**，去抖合并窗口（200–500ms）内按路径聚合判定最终状态；mtime 轮询兜底保留（设计内不变）。

## 对设计文档的回写

- design.md §15.1.7/§15.1.8 已标记「已冒烟验证（本文档）」。
- development-plan.md E.2 表 15.1.7/15.1.8 行已标记完成。
