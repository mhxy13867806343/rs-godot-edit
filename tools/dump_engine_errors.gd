extends SceneTree

const FIXTURE_ROOT := "res://fixtures"

class CaptureLogger extends Logger:
	var entries: Array = []

	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		var message := rationale if not rationale.is_empty() else code
		if message.is_empty():
			message = "unknown engine error"
		entries.append({
			"file": file,
			"line": line if line > 0 else 1,
			"column": 1,
			"message": message,
			"severity": "warning" if error_type == ERROR_TYPE_WARNING else "error",
			"code": "GODOT_HEADLESS",
			"source": "godot",
		})

	func _log_message(message: String, error: bool) -> void:
		if not error:
			return
		entries.append({
			"file": "",
			"line": 1,
			"column": 1,
			"message": message if not message.is_empty() else "unknown engine message",
			"severity": "error",
			"code": "GODOT_MESSAGE",
			"source": "godot",
		})

func _initialize() -> void:
	var logger := CaptureLogger.new()
	OS.add_logger(logger)
	var cases: Array = []
	_scan(FIXTURE_ROOT, logger, cases)
	if FileAccess.file_exists("res://static_check_sample.gd"):
		_check_file("res://static_check_sample.gd", logger, cases)
	var report := {
		"godot_version": Engine.get_version_info(),
		"generated_at": Time.get_datetime_string_from_system(false, true),
		"case_count": cases.size(),
		"cases": cases,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	var json := JSON.stringify(report, "\t")
	var out := FileAccess.open("res://docs/headless_engine_errors.json", FileAccess.WRITE)
	if out:
		out.store_string(json)
		out.close()
	print("RS_GODOT_EDIT_HEADLESS_CASES=%d" % cases.size())
	quit()

func _scan(dir_path: String, logger: CaptureLogger, cases: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var path := dir_path.path_join(name)
			if dir.current_is_dir():
				_scan(path, logger, cases)
			elif name.ends_with(".gd"):
				_check_file(path, logger, cases)
		name = dir.get_next()
	dir.list_dir_end()

func _check_file(path: String, logger: CaptureLogger, cases: Array) -> void:
	logger.entries.clear()
	var opened := FileAccess.open(path, FileAccess.READ)
	var source := ""
	if opened:
		source = opened.get_as_text()
		opened.close()
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload(false)
	var logs: Array = []
	for item in logger.entries:
		var entry: Dictionary = item.duplicate(true)
		var logged_file := str(entry.get("file", ""))
		if logged_file.is_empty() or logged_file.begins_with("gdscript://") or not logged_file.begins_with("res://"):
			entry["file"] = path
		logs.append(entry)
	cases.append({
		"file": path,
		"reload_error": err,
		"engine_logs": logs,
	})
