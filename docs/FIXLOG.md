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

## 2026-09-01 第二轮（收尾，约 10:22）

- **卡住：** 本想继续查 Godot 4.6 源码/网页文档扩 API，网络请求挂起约 80 分钟，没有产出。没有再生成新的成批 fixtures。
- **已有成果（上一轮已入库）：** `fixtures/generated/` 26 个坏脚本 + `static_check_sample.gd`；headless dump 已证明引擎会报悬空 `@export` 原文；Logger 路径映射已提交 `0b81b3d`。
- **本轮最小修复：** 脚本编辑器整棵控件树（含父级、Tree、RichTextLabel 原文）里的引擎报错行原样进右上角面板；对不上固定格式的行只要带有引擎错误字样，也按原文显示。没有为 `@export` 或任何具体错误加 case。
- **验证：** `cargo test` 12 通过，`cargo check` 通过。无界面 dump 再跑一遍：`RS_GODOT_EDIT_HEADLESS_CASES=28`，含 `static_check_sample.gd` 的 `@export` 引擎原文。未开 Godot GUI。
- **再次卡住：** GitHub 推送 SSL 失败后等待确认超时；本轮已停掉长任务，只补这一行说明。

## 如何复跑

```bash
cargo test
cargo check
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```
