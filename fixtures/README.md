# Fixtures

These `.gd` files are intentionally invalid. Godot should report errors; the plugin must forward the engine text instead of matching each case by hand.

Run headless:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/dump_engine_errors.gd
```

Output: `docs/headless_engine_errors.json`.
