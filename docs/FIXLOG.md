# 修复日志

工作窗口：2026-09-01 起，做到 **2026-09-15 23:59:59（Asia/Shanghai）**。每约 30 分钟测一轮、修一轮、更新文档并推送到 GitHub / Gitee。

## 2026-09-01 第一轮（无界面）

- **Godot：** 本机 `/Applications/Godot.app` 为 4.6.stable。未使用编辑器 GUI，改用  
  `Godot --headless --path . --script res://tools/dump_engine_errors.gd`
- **用例：** `fixtures/generated/` 下 26 个故意写坏的脚本，外加根目录 `static_check_sample.gd`（用户截图里的悬空 `@export`）。共 28 个文件。
- **引擎结果：** 28/28 都拿到官方 Parse Error 原文。`@export` 原文为  
  `Annotation "@export" does not precede a valid target, so it will have no effect.`  
  分别出现在 `annotation_export_orphan.gd:7` 和 `static_check_sample.gd:11`。
- **漏报/缺陷：** 引擎日志里的文件路径是内存地址 `gdscript://...`，面板无法跳转，也容易对不上真实脚本。
- **修复：** 每编译一个脚本就立刻收 Logger，把空路径 / `gdscript://` / 非 `res://` 映射回当前文件。没有为 `@export` 或任何具体英文错误加启发式分支。
- **验证：** `cargo test` 12 通过，`cargo check` 通过。原始引擎输出见 `docs/headless_engine_errors.json`。

## 2026-09-01 第二轮（收尾，约 10:22）

- **卡住：** 本想继续查 Godot 4.6 源码/网页文档扩 API，网络请求挂起约 80 分钟，没有产出。没有再生成新的成批 fixtures。
- **已有成果（上一轮已入库）：** `fixtures/generated/` 26 个坏脚本 + `static_check_sample.gd`；headless dump 已证明引擎会报悬空 `@export` 原文；Logger 路径映射已提交 `0b81b3d`。
- **本轮最小修复：** 脚本编辑器整棵控件树（含父级、Tree、RichTextLabel 原文）里的引擎报错行原样进右上角面板；对不上固定格式的行只要带有引擎错误字样，也按原文显示。没有为 `@export` 或任何具体错误加 case。
- **验证：** `cargo test` 12 通过，`cargo check` 通过。无界面 dump 再跑一遍：`RS_GODOT_EDIT_HEADLESS_CASES=28`，含 `static_check_sample.gd` 的 `@export` 引擎原文。未开 Godot GUI。
- **再次卡住：** GitHub 推送 SSL 失败后等待确认超时；本轮已停掉长任务，只补这一行说明。

## 2026-09-01 第三轮（约 23:50，新窗口第一轮）

- **Godot：** 4.6.stable，仍只用 `--headless`。卡住进程会按二进制路径杀掉。
- **用例：** 新增 29 个故意写坏的脚本（break/continue、缺 const、非法 lambda、`@export` 标在 func 上等）。引擎接受的 `@export_group` 未当错误，已丢掉。现 **57/57** 都有官方 Parse Error 原文，共 61 条 Logger 记录。路径已从 `gdscript://` 映回真实 `res://` 文件。
- **API：** ClassDB 里脚本语言几乎没有暴露 get_error 列表；真正能拿到行号/原文/级别的是 `Logger._log_error`。dump 改用插件同一份 `editor_logger.gd`。插件对编辑器/语言对象只按方法名泛化调用（`debug_get_error` 等），没有为某句英文报错加分支。
- **验证：** `cargo test` 12 通过，`cargo check` 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。原始输出 `docs/headless_engine_errors.json`，API 探测 `docs/engine_error_api.json`。
- **缺口：** 无 GUI 时拿不到列号（Logger 无 column）；脚本编辑器控件树那条路仍需编辑器会话才能测。

## 2026-09-02 第四轮（无界面，约 07:35）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 2 秒结束。无 Godot 僵尸进程。
- **用例：** 只新增 5 个坏脚本（重复 `class_name`、残缺 getter、const 再赋值、typed Dictionary 错类型、内部 class 无冒号）。现 **62/62** 都有官方 Parse Error 原文，67 条 Logger。路径仍从 `gdscript://` 映回 `res://`。没有为具体错误加 if/启发式。
- **列号：** 引擎 Logger 给出行号；`Logger._log_error` 没有 column，记录恒为 1。脚本语言 API 仍无 get_error 列表。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。原始输出 `docs/headless_engine_errors.json`。

## 2026-09-02 第五轮（无界面，约 08:40）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 1 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（重复形参、void 函数有返回值、enum 字符串值、嵌套命名 func、函数体内 `signal`）。现 **67/67** 都有官方 Parse Error 原文，72 条 Logger。没有为具体错误加 if/启发式。
- **列号：** 探测 `Logger._log_error` 参数只有 file/line，没有 column；`ScriptBacktrace` 有 `get_frame_line` 无 `get_frame_column`；相关类没有带 column 的方法。记录仍恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第六轮（无界面，约 09:15）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 2 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（残缺 match `when`、裸 `await`、静态函数读实例成员、非法 `@rpc` 参数、推断类型后再赋冲突值）。现 **72/72** 都有官方 Parse Error 原文，78 条 Logger。没有为具体错误加 if/启发式。
- **列号：** `Logger._log_error` 仍无 column；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第七轮（无界面，约 11:27）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 1 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（`@static_unload` 放错位置、`for` 迭代类型冲突、残缺 `is not`、多行字符串未闭合、`extends` 未知类）。现 **77/77** 都有官方 Parse Error 原文，84 条 Logger。没有为具体错误加 if/启发式。未重复已有 `super`/`preload`/`@icon`/`@tool`/重复 enum 键。
- **列号：** `Logger._log_error` 仍无 column 参数；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第八轮（无界面，约 12:06）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 1 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（Godot 3 `setget`、`and()` 当函数、`@export_enum` 无参数、`String - int`、`var x:` 缺类型）。现 **82/82** 都有官方 Parse Error 原文，89 条 Logger。没有为具体错误加 if/启发式。未重复已有 `@onready`/`yield`/`func` 缺括号/`break`。
- **列号：** `Logger._log_error` 仍无 column；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第九轮（无界面，约 14:54）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 1 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（`or()` 当函数、`@export_range` 无参数、`while` 条件 `int == String`、内部 class 重复 `extends`、`@warning_ignore` 未知警告名）。现 **87/87** 都有官方 Parse Error 原文，94 条 Logger。没有为具体错误加 if/启发式。未重复已有 `and()`/`@export_enum`/`match` 缺冒号/`const` 无初值/`Array[int]` 塞 String/`while` 缺条件。
- **列号：** `Logger._log_error` 仍无 column；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第十轮（无界面，约 15:25）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 2 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（`not(true, false)`、`@export_flags` 无参数、`Dictionary[String, int]` 键类型错、重复 `signal` 名、`@export_node_path` 标在 `int` 上）。现 **92/92** 都有官方 Parse Error 原文，100 条 Logger。没有为具体错误加 if/启发式。未重复已有 `and()`/`or()`/`@export_range`/`@export_enum`/值类型错 Dictionary/`if` 缺条件/`return` 在类体/残缺 ternary。
- **列号：** `Logger._log_error` 仍无 column 参数；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 2026-09-02 第十一轮（无界面，约 16:00）

- **Godot：** 4.6.stable，`--headless` 单次 dump，约 1 秒结束。
- **用例：** 只新增 5 个新种类坏脚本（`1 in 2`、`1 as Node`、`&"Node"` 赋给 `int`（4.6 把 `&"..."` 当 StringName）、`PackedByteArray` 赋 String、`@export_multiline` 标在 `int` 上）。现 **97/97** 都有官方 Parse Error 原文，107 条 Logger。没有为具体错误加 if/启发式。未重复已有默认参数在必选前/裸 `await`/`and()`/`String as int`/`@export_flags`。
- **列号：** `Logger._log_error` 仍无 column 参数；`ScriptBacktrace` 无 `get_frame_column`。记录恒为 1。控件树 GUI 本轮跳过。
- **验证：** `cargo test` 12 通过。`RS_GODOT_EDIT_HEADLESS_EMPTY=0`。

## 如何复跑

```bash
cargo test
cargo check
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```
