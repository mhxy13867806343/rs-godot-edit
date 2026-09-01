# rs-godot-edit

A Rust + Godot project editing tool under active development.

> This repository is currently in its initial setup phase. Features and usage instructions will be updated as development progresses.

## Overview

`rs-godot-edit` aims to provide an editing tool for Godot projects, with its core implemented in Rust. Detailed features, architecture notes, and screenshots will be added after the first runnable implementation is available.

## Status

- Stage: Editor plugin plus Rust heuristics; diagnostics use Godot engine wording
- Version: 0.1.0 (in development)
- Overnight cadence: through **2026-09-02 09:30 (Asia/Shanghai)**, about every 30 minutes: test, log, and push to GitHub / Gitee
- API and project structure: Unstable and subject to breaking changes

## Development

Requirements: Rust stable and Godot 4.6+.

Build the Rust analyzer:

```bash
cargo test
cargo build
```

Use it in a Godot project:

1. Copy `addons/rs_godot_edit` into your Godot project's `addons/` directory.
2. Enable `RS Godot Edit` under Project > Project Settings > Plugins.
3. Open the `RS Godot Edit` bottom panel. The plugin checks automatically when the project opens, scripts are added/deleted, files are saved, or the active script has unsaved edits; you can also click `检查 GDScript` to run it manually.
4. The default analyzer path is `target/debug/rs-godot-edit` inside the project. A custom Rust executable can also be selected in the panel.

The analyzer recursively checks `.gd` files and emits JSON diagnostics. The editor plugin copies official Godot script-editor errors (annotations, parse, and compile, verbatim) into the dock panel, then uses the Godot compiler and Logger for scripts that are not open, and finally adds Rust heuristic checks. New syntax or annotation errors do not need handwritten rules. I/O failures, unreadable directories, a missing/timed-out/crashed analyzer, invalid protocol payloads, and unknown diagnostic shapes become visible diagnostics with fallback codes such as `UNKNOWN`, `IO_UNKNOWN`, and `PROC_UNKNOWN`.

Extra Rust heuristics still cover mixed or inconsistent indentation, unexpected indentation, empty blocks, mismatched brackets, function declaration format, misplaced `extends`, invalid `@abstract` usage, undefined function calls, invalid integer/String addition, assignments in conditions, unreachable statements after control-flow exits, potentially skipped elements caused by calling `remove_at(i)` while iterating an array forward, and mutable Dictionary/Array aliasing without `duplicate()`.

This version does not replace Godot's official type checker or runtime tests.

When diagnostics contain any error or warning, the plugin uses Godot 4.6's `_build()` hook to block running the project or scene. Running is allowed again after all diagnostics are fixed and the next check passes.

## Headless fixtures

Intentionally broken scripts live in `fixtures/generated/`. Compile them with the Godot 4.6 CLI so engine messages are collected (no handwritten per-error rules):

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```

Results are written to `docs/headless_engine_errors.json`. See [docs/FIXLOG.md](docs/FIXLOG.md) for the repair log. In the editor, the plugin also writes the current diagnostics to `docs/last_diagnostics.json`.

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code.

## Mirrors

- GitHub: [mhxy13867806343/rs-godot-edit](https://github.com/mhxy13867806343/rs-godot-edit)
- Gitee: [fangjiayu/rs-godot-edit](https://gitee.com/fangjiayu/rs-godot-edit)

## License

This project is released under the [MIT License](LICENSE).

## 中文

请查看[中文版 README](README.md)。
