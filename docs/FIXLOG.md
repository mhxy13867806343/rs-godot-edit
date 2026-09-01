# 修复日志

工作窗口：2026-09-01 起，做到 **2026-09-02 09:30（Asia/Shanghai）**。每约 30 分钟测一轮、修一轮、更新文档并推送到 GitHub / Gitee。

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

## 如何复跑

```bash
cargo test
cargo check
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```
