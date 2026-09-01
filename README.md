# rs-godot-edit

Rust + Godot 项目编辑工具（开发中）。

> 项目目前处于初始化阶段，功能和使用方式会随着开发推进持续更新。

## 项目简介

`rs-godot-edit` 计划提供一个面向 Godot 项目的编辑工具，核心部分使用 Rust 开发。详细功能、架构和截图将在第一版可运行实现完成后补充。

## 状态

- 当前阶段：编辑器插件 + Rust 启发式检查，错误以 Godot 引擎原文为准
- 当前版本：0.1.0（开发中）
- 夜测节奏：从现在到 **2026-09-02 09:30（Asia/Shanghai）** 约每 30 分钟测一轮、记日志、推送到 GitHub / Gitee
- API 和项目结构：暂不稳定，可能发生不兼容变更

## 开发环境

要求：Rust stable、Godot 4.6+。

构建 Rust 分析器：

```bash
cargo test
cargo build
```

在 Godot 项目中使用：

1. 将 `addons/rs_godot_edit` 复制到你的 Godot 项目的 `addons/` 目录。
2. 在 Godot 的“项目 > 项目设置 > 插件”中启用 `RS Godot Edit`。
3. 在底部面板打开 `RS Godot Edit`；插件会在项目打开、脚本新增/删除、文件保存以及当前脚本未保存编辑时自动检查，也可以点击“检查 GDScript”手动检查。
4. 默认分析器路径为项目内的 `target/debug/rs-godot-edit`；也可以在面板中选择自定义 Rust 可执行文件。

分析器会递归检查项目中的 `.gd` 文件，并以 JSON 输出诊断结果。编辑器插件会把脚本编辑器里 Godot 已经报出的官方错误（含注解、解析、编译，原文原样）同步到右上角面板，再用 Godot 编译器和 Logger 补全未打开的脚本，最后叠加 Rust 启发式逻辑检查。不需要为每种语法或注解手写规则。读写失败、目录无法访问、分析器缺失/超时/崩溃、协议格式无效以及未知诊断载荷都会变成可见诊断，并带有 `UNKNOWN` / `IO_UNKNOWN` / `PROC_UNKNOWN` 等兜底码。

Rust 侧额外规则包括：缩进混用、意外/不一致缩进、空代码块、括号不匹配、函数声明格式、错误位置的 `extends`、非法 `@abstract` 用法、未定义函数调用、整数与字符串的非法 `+`、条件中的赋值、控制流后的不可达语句、正序遍历数组时调用 `remove_at(i)` 可能跳过元素，以及可变 Dictionary/Array 未 `duplicate()` 导致的别名修改。

当前版本不替代 Godot 官方类型检查器或运行时测试。

当检查结果包含任何 error 或 warning 时，插件会通过 Godot 4.6 的 `_build()` 钩子阻止运行项目或场景；修复所有诊断并重新检查通过后才允许运行。

## 无界面回归

故意写坏的脚本在 `fixtures/generated/`。用 Godot 4.6 CLI 编译它们，确认引擎原文被收集（不是手写每种错误）：

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```

结果写在 `docs/headless_engine_errors.json`。修复记录见 [docs/FIXLOG.md](docs/FIXLOG.md)。编辑器里跑检查时，插件还会把当前诊断写到 `docs/last_diagnostics.json`。

## 参与开发

欢迎提交 Issue 或 Pull Request。在提交代码前，请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 镜像仓库

- GitHub：[mhxy13867806343/rs-godot-edit](https://github.com/mhxy13867806343/rs-godot-edit)
- Gitee：[fangjiayu/rs-godot-edit](https://gitee.com/fangjiayu/rs-godot-edit)

## 许可证

本项目采用 [MIT License](LICENSE) 开源。

## English

查看 [English README](README.en.md)。
