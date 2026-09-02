extends SceneTree

const FIXTURE_ROOT := "res://fixtures"
const ERROR_API_HINTS := ["error", "diagnos", "warning", "logger", "parse", "column"]

func _initialize() -> void:
	var logger_script := load("res://addons/rs_godot_edit/editor_logger.gd")
	if logger_script == null:
		push_error("RS Godot Edit: missing editor_logger.gd")
		quit()
		return
	var logger: Logger = logger_script.new()
	OS.add_logger(logger)
	var api_probe := _probe_error_apis()
	var cases: Array = []
	_scan(FIXTURE_ROOT, logger, cases)
	if FileAccess.file_exists("res://static_check_sample.gd"):
		_check_file("res://static_check_sample.gd", logger, cases)
	var with_logs := 0
	var empty_files: PackedStringArray = PackedStringArray()
	var panel_items: Array = []
	for item in cases:
		if item.engine_logs.is_empty():
			empty_files.append(str(item.file))
		else:
			with_logs += 1
		panel_items.append_array(item.engine_logs)
	var report := {
		"godot_version": Engine.get_version_info(),
		"generated_at": Time.get_datetime_string_from_system(false, true),
		"case_count": cases.size(),
		"with_engine_logs": with_logs,
		"empty_engine_logs": empty_files.size(),
		"empty_files": empty_files,
		"panel_item_count": panel_items.size(),
		"cases": cases,
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	_write_json("res://docs/headless_engine_errors.json", report)
	_write_json("res://docs/engine_error_api.json", api_probe)
	print("RS_GODOT_EDIT_HEADLESS_CASES=%d" % cases.size())
	print("RS_GODOT_EDIT_HEADLESS_WITH_LOGS=%d" % with_logs)
	print("RS_GODOT_EDIT_HEADLESS_EMPTY=%d" % empty_files.size())
	print("RS_GODOT_EDIT_HEADLESS_PANEL_ITEMS=%d" % panel_items.size())
	quit()

func _write_json(path: String, value: Variant) -> void:
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		push_error("RS Godot Edit: cannot write %s" % path)
		return
	out.store_string(JSON.stringify(value, "\t"))
	out.close()

func _scan(dir_path: String, logger: Logger, cases: Array) -> void:
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

func _check_file(path: String, logger: Logger, cases: Array) -> void:
	if logger.has_method("clear"):
		logger.call("clear")
	var opened := FileAccess.open(path, FileAccess.READ)
	var source := ""
	if opened:
		source = opened.get_as_text()
		opened.close()
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload(false)
	var logs: Array = []
	if logger.has_method("take_entries"):
		for item in logger.call("take_entries"):
			var entry: Dictionary = item.duplicate(true)
			entry["file"] = _remap_engine_file(str(entry.get("file", "")), path)
			logs.append(entry)
	var language_errors := _collect_script_language_errors(path)
	cases.append({
		"file": path,
		"reload_error": err,
		"reload_error_text": _engine_error_text(err),
		"engine_logs": logs,
		"language_errors": language_errors,
	})

func _remap_engine_file(file: String, fallback_path: String) -> String:
	if file.is_empty() or file.begins_with("gdscript://") or not file.begins_with("res://"):
		return fallback_path
	return file

func _collect_script_language_errors(path: String) -> Array:
	var result: Array = []
	for index in Engine.get_script_language_count():
		var language := Engine.get_script_language(index)
		if language == null:
			continue
		var payload := {
			"language": language.get_class(),
		}
		var got_error := false
		if language.has_method("get_name"):
			payload["name"] = str(language.call("get_name"))
		for method_name in ["debug_get_error", "get_error", "get_errors", "get_parse_errors", "get_error_list", "get_diagnostics"]:
			if language.has_method(method_name):
				var value: Variant = language.call(method_name)
				if value == null or str(value).is_empty():
					continue
				payload[method_name] = value
				got_error = true
		if got_error:
			payload["file"] = path
			result.append(payload)
	return result

func _probe_error_apis() -> Dictionary:
	var class_names: PackedStringArray = PackedStringArray([
		"ScriptLanguage",
		"GDScript",
		"Script",
		"ScriptEditor",
		"ScriptEditorBase",
		"CodeEdit",
		"EditorInterface",
		"Logger",
		"ScriptBacktrace",
		"GDScriptSyntaxHighlighter",
	])
	var classes := {}
	for type_name in class_names:
		if not ClassDB.class_exists(type_name):
			classes[type_name] = {"exists": false, "methods": []}
			continue
		classes[type_name] = {
			"exists": true,
			"methods": _method_names_matching(ClassDB.class_get_method_list(type_name, false)),
		}
	var extra_classes: Array = []
	for type_name in ClassDB.get_class_list():
		var lowered := str(type_name).to_lower()
		if lowered.contains("error") or lowered.contains("diagnos") or lowered.contains("gdscript"):
			extra_classes.append({
				"class": type_name,
				"methods": _method_names_matching(ClassDB.class_get_method_list(type_name, false)),
			})
	var languages: Array = []
	for index in Engine.get_script_language_count():
		var language := Engine.get_script_language(index)
		if language == null:
			continue
		languages.append({
			"name": language.get_name() if language.has_method("get_name") else language.get_class(),
			"class": language.get_class(),
			"methods": _object_method_names_matching(language),
		})
	return {
		"godot_version": Engine.get_version_info(),
		"classes": classes,
		"extra_error_related_classes": extra_classes,
		"script_languages": languages,
		"column_probe": _probe_column_apis(),
	}

func _probe_column_apis() -> Dictionary:
	var logger_log_error := {}
	if ClassDB.class_exists("Logger"):
		for item in ClassDB.class_get_method_list("Logger", true):
			if str(item.get("name", "")) == "_log_error":
				var args: PackedStringArray = PackedStringArray()
				for arg in item.get("args", []):
					args.append(str(arg.get("name", "")))
				logger_log_error = {
					"name": "_log_error",
					"args": args,
					"has_column_arg": args.find("column") >= 0 or args.find("col") >= 0,
				}
				break
	var backtrace_location_methods: PackedStringArray = PackedStringArray()
	if ClassDB.class_exists("ScriptBacktrace"):
		for item in ClassDB.class_get_method_list("ScriptBacktrace", true):
			var method_name := str(item.get("name", ""))
			if method_name.begins_with("get_frame_"):
				backtrace_location_methods.append(method_name)
		backtrace_location_methods.sort()
	var column_methods: PackedStringArray = PackedStringArray()
	for type_name in ["Logger", "ScriptBacktrace", "GDScript", "Script", "ScriptLanguage"]:
		if not ClassDB.class_exists(type_name):
			continue
		for item in ClassDB.class_get_method_list(type_name, true):
			var method_name := str(item.get("name", ""))
			if method_name.to_lower().contains("column"):
				column_methods.append("%s.%s" % [type_name, method_name])
	column_methods.sort()
	return {
		"logger_log_error": logger_log_error,
		"script_backtrace_frame_methods": backtrace_location_methods,
		"methods_with_column": column_methods,
	}

func _method_names_matching(methods: Array) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	for item in methods:
		var method_name := str(item.get("name", ""))
		if _looks_like_error_api(method_name):
			names.append(method_name)
	names.sort()
	return names

func _object_method_names_matching(object: Object) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if object == null:
		return names
	for item in object.get_method_list():
		var method_name := str(item.get("name", ""))
		if _looks_like_error_api(method_name):
			names.append(method_name)
	names.sort()
	return names

func _looks_like_error_api(method_name: String) -> bool:
	var lowered := method_name.to_lower()
	for hint in ERROR_API_HINTS:
		if lowered.contains(hint):
			return true
	return false

func _engine_error_text(err: int) -> String:
	match err:
		OK:
			return "ok"
		ERR_PARSE_ERROR:
			return "parse error"
		ERR_COMPILATION_FAILED:
			return "compilation failed"
		ERR_INVALID_DECLARATION:
			return "invalid declaration"
		ERR_DUPLICATE_SYMBOL:
			return "duplicate symbol"
		ERR_SCRIPT_FAILED:
			return "script failed"
		_:
			return "unknown engine error (%d)" % err
