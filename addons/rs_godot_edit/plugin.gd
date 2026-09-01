@tool
extends EditorPlugin

const SETTING_PATH := "rs_godot_edit/analyzer_path"
const ANALYZER_TIMEOUT_MSEC := 20000
const MAX_WALK_DEPTH := 64

var panel: VBoxContainer
var status_label: Label
var results: ItemList
var analyzer_path: LineEdit
var watched_files: Dictionary = {}
var watch_timer: Timer
var watched_unsaved_signature := ""
var analysis_has_errors := true
var analysis_busy := false
var editor_logger: Logger
var engine_error_line := RegEx.new()
var watched_engine_signature := ""

func _enter_tree() -> void:
	engine_error_line.compile("(?i)^(错误|警告|Error|Warning|Script Error)\\s*\\(\\s*(\\d+)(?:\\s*,\\s*(\\d+))?\\s*\\)\\s*:\\s*(.+)$")
	editor_logger = preload("res://addons/rs_godot_edit/editor_logger.gd").new()
	OS.add_logger(editor_logger)
	panel = VBoxContainer.new()
	panel.name = "RS Godot Edit"
	panel.custom_minimum_size = Vector2(560, 180)
	var toolbar := HBoxContainer.new()
	var scan_button := Button.new()
	scan_button.text = "检查 GDScript"
	scan_button.pressed.connect(_run_analysis)
	toolbar.add_child(scan_button)
	var path_button := Button.new()
	path_button.text = "分析器路径"
	path_button.pressed.connect(_choose_analyzer)
	toolbar.add_child(path_button)
	panel.add_child(toolbar)
	analyzer_path = LineEdit.new()
	analyzer_path.placeholder_text = "可选：Rust 可执行文件路径，默认使用 target/debug/rs-godot-edit"
	analyzer_path.text = str(ProjectSettings.get_setting(SETTING_PATH, ""))
	analyzer_path.text_submitted.connect(_save_analyzer_path)
	panel.add_child(analyzer_path)
	status_label = Label.new()
	status_label.text = "准备检查"
	panel.add_child(status_label)
	results = ItemList.new()
	results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	results.item_selected.connect(_open_result)
	panel.add_child(results)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, panel)
	add_tool_menu_item("RS Godot Edit: 检查 GDScript", _run_analysis)
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_run_analysis)
	var script_editor := EditorInterface.get_script_editor()
	if script_editor and not script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		script_editor.editor_script_changed.connect(_on_editor_script_changed)
	watch_timer = Timer.new()
	watch_timer.wait_time = 0.5
	watch_timer.timeout.connect(_poll_files)
	add_child(watch_timer)
	watch_timer.start()
	_update_file_snapshot()
	call_deferred("_run_analysis")

func _exit_tree() -> void:
	if EditorInterface.get_resource_filesystem().filesystem_changed.is_connected(_run_analysis):
		EditorInterface.get_resource_filesystem().filesystem_changed.disconnect(_run_analysis)
	var script_editor := EditorInterface.get_script_editor()
	if script_editor and script_editor.editor_script_changed.is_connected(_on_editor_script_changed):
		script_editor.editor_script_changed.disconnect(_on_editor_script_changed)
	remove_tool_menu_item("RS Godot Edit: 检查 GDScript")
	if panel:
		remove_control_from_docks(panel)
		panel.queue_free()
	if editor_logger:
		OS.remove_logger(editor_logger)
	if watch_timer:
		watch_timer.stop()
		watch_timer.queue_free()

func _run_analysis() -> void:
	_run_analysis_internal()

func _build() -> bool:
	return _run_analysis_internal()

func _run_analysis_internal() -> bool:
	if analysis_busy:
		return not analysis_has_errors
	analysis_busy = true
	var allowed := _analyze()
	analysis_busy = false
	return allowed

func _on_editor_script_changed(_script: Script) -> void:
	_run_analysis()

func _analyze() -> bool:
	if editor_logger:
		editor_logger.clear()
	if results:
		results.clear()
	_save_analyzer_path(analyzer_path.text if analyzer_path else "")

	var diagnostics: Array = []
	var walk := _walk_project("res://", 0)
	_update_file_snapshot_from(walk.files)
	diagnostics.append_array(walk.diagnostics)

	var unsaved := _get_unsaved_source()
	diagnostics.append_array(_collect_script_editor_diagnostics())
	diagnostics.append_array(_godot_validate_all(walk.files, unsaved))
	diagnostics.append_array(_rust_analyze(unsaved))
	watched_engine_signature = _engine_error_signature()

	var finalized := _finalize_diagnostics(diagnostics)
	for item in finalized:
		_add_result(item)

	var blocked := false
	for item in finalized:
		if item.severity == "error" or item.severity == "warning":
			blocked = true
			break
	if status_label:
		status_label.text = "检查完成：%d 个诊断" % finalized.size()
	_write_diagnostics_dump(finalized)
	_set_run_buttons_disabled(blocked)
	return not blocked

func _write_diagnostics_dump(items: Array) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	var file := FileAccess.open("res://docs/last_diagnostics.json", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(items, "\t"))
	file.close()

func _collect_script_editor_diagnostics() -> Array:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return []
	var editors: Array = []
	var scripts: Array = []
	if script_editor.has_method("get_open_script_editors"):
		editors = script_editor.get_open_script_editors()
	if script_editor.has_method("get_open_scripts"):
		scripts = script_editor.get_open_scripts()
	if editors.is_empty():
		var current := script_editor.get_current_editor()
		if current:
			editors = [current]
			scripts = [script_editor.get_current_script()]
	var result: Array = []
	var fallback_path := "res://"
	for i in editors.size():
		var editor: Node = editors[i]
		var path := "res://"
		if i < scripts.size() and scripts[i] is Script:
			path = str(scripts[i].resource_path)
			if path.is_empty():
				path = "res://[unsaved].gd"
		if fallback_path == "res://" and path != "res://":
			fallback_path = path
		result.append_array(_collect_from_editor_api(editor, path))
		result.append_array(_collect_engine_texts_from_control(editor, path))
	result.append_array(_collect_from_editor_api(script_editor, fallback_path))
	result.append_array(_collect_engine_texts_from_control(script_editor, fallback_path))
	return result

func _collect_from_editor_api(editor: Object, path: String) -> Array:
	var result: Array = []
	if editor == null:
		return result
	for method_name in ["get_errors", "get_script_errors", "get_error_list", "get_diagnostics"]:
		if editor.has_method(method_name):
			result.append_array(_diagnostics_from_unknown_payload(editor.call(method_name), path))
	if editor.has_method("get_base_editor"):
		var code_edit: Variant = editor.get_base_editor()
		if code_edit is Object:
			for method_name in ["get_errors", "get_error_messages", "get_diagnostics"]:
				if code_edit.has_method(method_name):
					result.append_array(_diagnostics_from_unknown_payload(code_edit.call(method_name), path))
	return result

func _diagnostics_from_unknown_payload(payload: Variant, path: String) -> Array:
	var result: Array = []
	match typeof(payload):
		TYPE_ARRAY:
			for item in payload:
				if item is Dictionary:
					var diagnostic := _normalize_diagnostic(item)
					if str(diagnostic.file).is_empty() or diagnostic.file == "res://":
						diagnostic["file"] = path
					diagnostic["source"] = "godot"
					if str(diagnostic.code) == "UNKNOWN":
						diagnostic["code"] = "GODOT_EDITOR"
					result.append(diagnostic)
				elif item is String:
					var parsed := _parse_engine_error_line(item, path)
					if parsed.is_empty():
						result.append(_diag(path, 1, 1, "error", "GODOT_EDITOR", item, "godot"))
					else:
						result.append(parsed)
				elif item != null:
					result.append(_diag(path, 1, 1, "error", "GODOT_EDITOR", str(item), "godot"))
		TYPE_DICTIONARY:
			for value in payload.values():
				result.append_array(_diagnostics_from_unknown_payload(value, path))
			if result.is_empty() and not payload.is_empty():
				var diagnostic := _normalize_diagnostic(payload)
				if str(diagnostic.file).is_empty() or diagnostic.file == "res://":
					diagnostic["file"] = path
				diagnostic["source"] = "godot"
				result.append(diagnostic)
		TYPE_STRING:
			if not str(payload).is_empty():
				var parsed := _parse_engine_error_line(str(payload), path)
				if parsed.is_empty():
					result.append(_diag(path, 1, 1, "error", "GODOT_EDITOR", str(payload), "godot"))
				else:
					result.append(parsed)
		TYPE_NIL:
			pass
		_:
			result.append(_diag(path, 1, 1, "error", "GODOT_UNKNOWN", str(payload), "godot"))
	return result

func _collect_engine_texts_from_control(node: Node, script_path: String) -> Array:
	var found: Array = []
	_walk_controls_for_engine_errors(node, script_path, found, 0)
	return found

func _walk_controls_for_engine_errors(node: Node, script_path: String, found: Array, depth: int) -> void:
	if node == null or depth > 40 or node == panel:
		return
	var texts: PackedStringArray = PackedStringArray()
	if node is RichTextLabel:
		var rich := node as RichTextLabel
		texts.append(rich.get_parsed_text())
		texts.append(rich.get_text())
	elif node is Label:
		texts.append((node as Label).text)
	elif node is LinkButton:
		texts.append((node as LinkButton).text)
	elif node is Button:
		texts.append((node as Button).text)
		texts.append((node as Button).tooltip_text)
	elif node is ItemList:
		var list := node as ItemList
		for i in list.item_count:
			texts.append(list.get_item_text(i))
	elif node is Tree:
		_collect_tree_texts(node as Tree, texts)
	for text in texts:
		for line in text.split("\n"):
			var parsed := _parse_engine_error_line(line.strip_edges(), script_path)
			if not parsed.is_empty():
				found.append(parsed)
	for child in node.get_children():
		_walk_controls_for_engine_errors(child, script_path, found, depth + 1)

func _collect_tree_texts(tree: Tree, texts: PackedStringArray) -> void:
	if tree == null:
		return
	var item := tree.get_root()
	while item:
		for column in tree.columns:
			texts.append(item.get_text(column))
			texts.append(item.get_tooltip_text(column))
		item = item.get_next_in_tree()

func _parse_engine_error_line(line: String, script_path: String) -> Dictionary:
	if line.is_empty() or engine_error_line.get_pattern().is_empty():
		return {}
	var matched := engine_error_line.search(line)
	if matched:
		var kind := matched.get_string(1)
		var severity := "warning" if kind.to_lower().contains("warn") or kind.contains("警告") else "error"
		var line_no := int(matched.get_string(2))
		var column_text := matched.get_string(3)
		var column := int(column_text) if not column_text.is_empty() else 1
		var message := matched.get_string(4).strip_edges()
		if not message.is_empty():
			return _diag(script_path, maxi(line_no, 1), maxi(column, 1), severity, "GODOT_EDITOR", message, "godot")
	var lowered := line.to_lower()
	var looks_like_engine := lowered.contains("parse error") or lowered.contains("script error") or line.contains("错误") or line.contains("警告") or lowered.begins_with("error") or lowered.begins_with("warning")
	if looks_like_engine:
		return _diag(script_path, 1, 1, "warning" if lowered.contains("warn") or line.contains("警告") else "error", "GODOT_EDITOR", line, "godot")
	return {}

func _engine_error_signature() -> String:
	var parts: PackedStringArray = PackedStringArray()
	for item in _collect_script_editor_diagnostics():
		parts.append("%s|%s|%s|%s" % [item.get("file", ""), item.get("line", 1), item.get("column", 1), item.get("message", "")])
	parts.sort()
	return "\n".join(parts)

func _godot_validate_all(files: Dictionary, unsaved: Dictionary) -> Array:
	var result: Array = []
	var unsaved_path := str(unsaved.get("path", ""))
	for path in files.keys():
		if path == unsaved_path:
			continue
		result.append_array(_validate_one_script(str(path), ""))
	if not unsaved.is_empty():
		result.append_array(_validate_one_script(unsaved_path if not unsaved_path.is_empty() else "res://[unsaved].gd", str(unsaved.get("source", ""))))
	return result

func _validate_one_script(path: String, source: String) -> Array:
	if source.is_empty():
		var opened := FileAccess.open(path, FileAccess.READ)
		if opened == null:
			return [_diag_from_engine_error(path, FileAccess.get_open_error(), "cannot read script")]
		source = opened.get_as_text()
		opened.close()
	if editor_logger:
		editor_logger.clear()
	var fallbacks := _compile_gdscript(path, source)
	var result: Array = []
	if editor_logger:
		for item in editor_logger.take_entries():
			var diagnostic := _normalize_diagnostic(item)
			diagnostic["source"] = "godot"
			if _is_noise(str(diagnostic.message)):
				continue
			diagnostic["file"] = _remap_engine_file(str(diagnostic.file), path)
			result.append(diagnostic)
	if result.is_empty():
		result.append_array(fallbacks)
	return result

func _remap_engine_file(file: String, fallback_path: String) -> String:
	if file.is_empty() or file.begins_with("gdscript://") or not file.begins_with("res://"):
		return fallback_path
	return file

func _compile_gdscript(path: String, source: String) -> Array:
	var script := GDScript.new()
	script.source_code = _isolated_validation_source(source)
	var err := script.reload(false)
	if err == OK:
		return []
	return [_diag(path, 1, 1, "error", "GODOT_ERR_%d" % err, "GDScript compile failed: %s" % _engine_error_text(err), "godot")]

func _isolated_validation_source(source: String) -> String:
	var lines := source.split("\n")
	var token := "RsGodotEditTmp_%d" % Time.get_ticks_usec()
	for i in lines.size():
		var stripped := lines[i].strip_edges()
		if stripped.begins_with("class_name "):
			var parts := stripped.split(" ", false)
			if parts.size() >= 2 and parts[1].is_valid_identifier():
				lines[i] = lines[i].replace(parts[1], token)
	return "\n".join(lines)

func _rust_analyze(unsaved: Dictionary) -> Array:
	var executable := analyzer_path.text.strip_edges() if analyzer_path else ""
	if executable.is_empty():
		executable = ProjectSettings.globalize_path("res://target/debug/rs-godot-edit")
	if not FileAccess.file_exists(executable):
		return [_diag("res://", 1, 1, "warning", "PROC_NOT_FOUND", "Rust analyzer not found at %s; Godot compile checks still ran. Run cargo build or set a custom path." % executable, "process")]

	var arguments := PackedStringArray(["--project-root", ProjectSettings.globalize_path("res://")])
	if not unsaved.is_empty():
		var temp_path := "user://rs_godot_edit_unsaved.gd"
		var temp_file := FileAccess.open(temp_path, FileAccess.WRITE)
		if temp_file == null:
			return [_diag(str(unsaved.get("path", "res://[unsaved].gd")), 1, 1, "error", "GODOT_ERR_%d" % FileAccess.get_open_error(), "cannot write unsaved buffer for analysis: %s" % _engine_error_text(FileAccess.get_open_error()), "io")]
		temp_file.store_string(str(unsaved.get("source", "")))
		temp_file.close()
		arguments.append_array(["--source-file", ProjectSettings.globalize_path(temp_path), "--source-path", str(unsaved.get("path", "res://[unsaved].gd"))])

	var spawned := _run_process(executable, arguments)
	match spawned.status:
		"ok":
			var parsed: Variant = _parse_analyzer_output(str(spawned.stdout))
			if parsed == null:
				var preview := str(spawned.stdout) if not str(spawned.stdout).is_empty() else str(spawned.stderr)
				return [_diag("res://", 1, 1, "error", "PROTO_INVALID", "analyzer output is not a JSON array: %s" % preview.left(500), "protocol")]
			var items: Array = []
			for item in parsed:
				var normalized := _normalize_diagnostic(item)
				if str(normalized.source) == "unknown":
					normalized["source"] = "rust"
				items.append(normalized)
			if int(spawned.exit_code) != 0 and items.is_empty():
				var detail := str(spawned.stderr) if not str(spawned.stderr).is_empty() else str(spawned.stdout)
				if detail.is_empty():
					detail = "no output"
				items.append(_diag("res://", 1, 1, "error", "PROC_EXIT", "analyzer exited with code %d: %s" % [spawned.exit_code, detail.left(500)], "process"))
			return items
		"timeout":
			return [_diag("res://", 1, 1, "error", "PROC_TIMEOUT", str(spawned.message), "process")]
		"spawn_failed":
			return [_diag("res://", 1, 1, "error", "PROC_SPAWN", str(spawned.message), "process")]
		_:
			return [_diag("res://", 1, 1, "error", "PROC_UNKNOWN", "analyzer process failed (%s): %s" % [spawned.status, spawned.message], "process")]

func _run_process(executable: String, arguments: PackedStringArray) -> Dictionary:
	if OS.has_method("execute_with_pipe"):
		var pipe: Variant = OS.call("execute_with_pipe", executable, arguments, false)
		if typeof(pipe) == TYPE_DICTIONARY and not pipe.is_empty() and pipe.has("pid"):
			var pid := int(pipe.pid)
			var started := Time.get_ticks_msec()
			while OS.is_process_running(pid):
				if Time.get_ticks_msec() - started > ANALYZER_TIMEOUT_MSEC:
					OS.kill(pid)
					return _process_result("timeout", -1, "", "", "analyzer exceeded %d ms" % ANALYZER_TIMEOUT_MSEC)
				OS.delay_msec(30)
			var stdout := ""
			var stderr := ""
			if pipe.has("stdio") and pipe.stdio is FileAccess:
				stdout = pipe.stdio.get_as_text()
			if pipe.has("stderr") and pipe.stderr is FileAccess:
				stderr = pipe.stderr.get_as_text()
			var exit_code := 0
			if stdout.strip_edges().is_empty():
				exit_code = 1
			return _process_result("ok", exit_code, stdout, stderr, "")
	return _run_process_blocking(executable, arguments)

func _run_process_blocking(executable: String, arguments: PackedStringArray) -> Dictionary:
	var output: Array = []
	var exit_code := OS.execute(executable, arguments, output, true)
	if exit_code == -1 and output.is_empty():
		return _process_result("spawn_failed", -1, "", "", "OS.execute failed to start %s" % executable)
	var stdout := ""
	for line in output:
		stdout += str(line)
		if not str(line).ends_with("\n"):
			stdout += "\n"
	return _process_result("ok", exit_code, stdout.strip_edges(), "", "")

func _process_result(status: String, exit_code: int, stdout: String, stderr: String, message: String) -> Dictionary:
	return {
		"status": status,
		"exit_code": exit_code,
		"stdout": stdout,
		"stderr": stderr,
		"message": message,
	}

func _parse_analyzer_output(raw: String) -> Variant:
	var text := raw.strip_edges()
	if text.is_empty():
		return []
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Array:
		return parsed
	var start := text.find("[")
	var end := text.rfind("]")
	if start >= 0 and end > start:
		parsed = JSON.parse_string(text.substr(start, end - start + 1))
		if parsed is Array:
			return parsed
	return null

func _walk_project(directory: String, depth: int) -> Dictionary:
	var files := {}
	var diagnostics: Array = []
	if depth > MAX_WALK_DEPTH:
		diagnostics.append(_diag(directory, 1, 1, "error", "IO_DEPTH", "directory tree exceeds maximum depth (%d)" % MAX_WALK_DEPTH, "io"))
		return {"files": files, "diagnostics": diagnostics}
	var dir := DirAccess.open(directory)
	if dir == null:
		diagnostics.append(_diag_from_engine_error(directory, DirAccess.get_open_error(), "cannot open directory"))
		return {"files": files, "diagnostics": diagnostics}
	dir.include_hidden = false
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var path := directory.path_join(name)
			if dir.current_is_dir():
				if name != ".godot" and name != "target" and path != "res://addons/rs_godot_edit":
					var child := _walk_project(path, depth + 1)
					files.merge(child.files)
					diagnostics.append_array(child.diagnostics)
			elif name.ends_with(".gd"):
				files[path] = [FileAccess.get_modified_time(path), FileAccess.get_size(path)]
		name = dir.get_next()
	dir.list_dir_end()
	return {"files": files, "diagnostics": diagnostics}

func _set_run_buttons_disabled(disabled: bool) -> void:
	analysis_has_errors = disabled
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var editor_theme := EditorInterface.get_editor_theme()
	var run_icons: Array = []
	if editor_theme:
		for icon_name in ["MainPlay", "PlayScene", "PlayCustom"]:
			if editor_theme.has_icon(icon_name, "EditorIcons"):
				run_icons.append(editor_theme.get_icon(icon_name, "EditorIcons"))
	for control in base.find_children("*", "Button", true, false):
		if not control is Button:
			continue
		var tooltip: String = control.tooltip_text.to_lower()
		var is_run_tooltip: bool = tooltip.contains("run") or tooltip.contains("play") or tooltip.contains("运行") or tooltip.contains("播放") or tooltip.contains("movie")
		if control.icon in run_icons or is_run_tooltip:
			control.disabled = disabled

func _get_unsaved_source() -> Dictionary:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return {}
	var current_script := script_editor.get_current_script()
	if current_script == null:
		return {}
	var current_editor := script_editor.get_current_editor()
	if current_editor == null:
		return {}
	var code_editor := current_editor.get_base_editor() as CodeEdit
	if code_editor == null or code_editor.get_version() == code_editor.get_saved_version():
		return {}
	return {"path": current_script.resource_path, "source": code_editor.text}

func _poll_files() -> void:
	_set_run_buttons_disabled(analysis_has_errors)
	_drain_editor_errors()
	var current: Dictionary = _walk_project("res://", 0).files
	var unsaved := _get_unsaved_source()
	var unsaved_signature := ""
	if not unsaved.is_empty():
		unsaved_signature = "%s:%s" % [unsaved.get("path", ""), str(unsaved.get("source", "").hash())]
	var engine_signature := _engine_error_signature()
	if current != watched_files or unsaved_signature != watched_unsaved_signature or engine_signature != watched_engine_signature:
		watched_unsaved_signature = unsaved_signature
		_run_analysis()

func _drain_editor_errors() -> void:
	if editor_logger == null or results == null:
		return
	for item in editor_logger.take_entries():
		var diagnostic := _normalize_diagnostic(item)
		if _is_noise(str(diagnostic.message)):
			continue
		diagnostic["source"] = "godot"
		_add_result(diagnostic)
		if diagnostic.severity == "error" or diagnostic.severity == "warning":
			analysis_has_errors = true
	_set_run_buttons_disabled(analysis_has_errors)

func _update_file_snapshot() -> void:
	_update_file_snapshot_from(_walk_project("res://", 0).files)

func _update_file_snapshot_from(files: Dictionary) -> void:
	watched_files = files

func _open_result(index: int) -> void:
	if results == null or index < 0 or index >= results.item_count:
		return
	var diagnostic := _normalize_diagnostic(results.get_item_metadata(index))
	var script_path := str(diagnostic.file)
	if not script_path.begins_with("res://"):
		if status_label:
			status_label.text = "无法打开非项目路径：%s" % script_path
		return
	if not ResourceLoader.exists(script_path):
		if status_label:
			status_label.text = "文件不存在：%s" % script_path
		return
	var script := ResourceLoader.load(script_path) as Script
	if script == null:
		if status_label:
			status_label.text = "不是可打开的脚本：%s" % script_path
		return
	EditorInterface.edit_script(script, maxi(int(diagnostic.line) - 1, 0), maxi(int(diagnostic.column) - 1, 0))

func _choose_analyzer() -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_selected.connect(func(path: String):
		if analyzer_path:
			analyzer_path.text = path
		_save_analyzer_path(path)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio()

func _save_analyzer_path(value: String) -> void:
	var cleaned := value.strip_edges()
	if str(ProjectSettings.get_setting(SETTING_PATH, "")) == cleaned:
		return
	ProjectSettings.set_setting(SETTING_PATH, cleaned)
	ProjectSettings.save()

func _add_result(diagnostic: Dictionary) -> void:
	if results == null:
		return
	var text := "%s  %s:%s  [%s] %s" % [_severity_label(str(diagnostic.severity)), diagnostic.file, diagnostic.line, diagnostic.code, diagnostic.message]
	for i in results.item_count:
		if results.get_item_text(i) == text:
			return
	var index := results.add_item(text)
	results.set_item_metadata(index, diagnostic)

func _finalize_diagnostics(items: Array) -> Array:
	var seen := {}
	var result: Array = []
	for item in items:
		var diagnostic := _normalize_diagnostic(item)
		var key := "%s|%s|%s|%s|%s" % [diagnostic.file, diagnostic.line, diagnostic.column, diagnostic.code, diagnostic.message]
		if seen.has(key):
			continue
		seen[key] = true
		result.append(diagnostic)
	result.sort_custom(func(a, b):
		if str(a.file) != str(b.file):
			return str(a.file) < str(b.file)
		return int(a.line) < int(b.line)
	)
	return result

func _normalize_diagnostic(item: Variant) -> Dictionary:
	if item is Dictionary:
		var message := str(item.get("message", item.get("msg", item.get("error", ""))))
		if message.is_empty():
			message = "unknown diagnostic"
		return {
			"file": str(item.get("file", "res://")),
			"line": maxi(int(item.get("line", 1)), 1),
			"column": maxi(int(item.get("column", 1)), 1),
			"severity": _normalize_severity(item.get("severity", "error")),
			"message": message,
			"code": str(item.get("code", "UNKNOWN")),
			"source": str(item.get("source", "unknown")),
		}
	return {
		"file": "res://",
		"line": 1,
		"column": 1,
		"severity": "error",
		"message": "unknown diagnostic payload: %s" % str(item),
		"code": "UNKNOWN",
		"source": "unknown",
	}

func _normalize_severity(value: Variant) -> String:
	match str(value).to_lower():
		"error", "err", "fatal", "script":
			return "error"
		"warning", "warn":
			return "warning"
		"info", "hint", "note":
			return "info"
		_:
			return "error"

func _severity_label(severity: String) -> String:
	match severity:
		"warning":
			return "警告"
		"info":
			return "信息"
		"error":
			return "错误"
		_:
			return "未知"

func _is_noise(message: String) -> bool:
	return message.is_empty() or message.begins_with("RS Godot Edit:")

func _diag(file: String, line: int, column: int, severity: String, code: String, message: String, source: String) -> Dictionary:
	return {
		"file": file,
		"line": line,
		"column": column,
		"severity": severity,
		"message": message,
		"code": code,
		"source": source,
	}

func _diag_from_engine_error(file: String, err: int, prefix: String) -> Dictionary:
	return _diag(file, 1, 1, "error", "GODOT_ERR_%d" % err, "%s: %s" % [prefix, _engine_error_text(err)], "io")

func _engine_error_text(err: int) -> String:
	match err:
		OK:
			return "ok"
		FAILED:
			return "generic failure"
		ERR_UNAVAILABLE:
			return "unavailable"
		ERR_UNCONFIGURED:
			return "unconfigured"
		ERR_UNAUTHORIZED:
			return "unauthorized"
		ERR_PARAMETER_RANGE_ERROR:
			return "parameter out of range"
		ERR_OUT_OF_MEMORY:
			return "out of memory"
		ERR_FILE_NOT_FOUND:
			return "file not found"
		ERR_FILE_BAD_DRIVE:
			return "bad drive"
		ERR_FILE_BAD_PATH:
			return "bad path"
		ERR_FILE_NO_PERMISSION:
			return "permission denied"
		ERR_FILE_ALREADY_IN_USE:
			return "file already in use"
		ERR_FILE_CANT_OPEN:
			return "cannot open file"
		ERR_FILE_CANT_WRITE:
			return "cannot write file"
		ERR_FILE_CANT_READ:
			return "cannot read file"
		ERR_FILE_UNRECOGNIZED:
			return "unrecognized file"
		ERR_FILE_CORRUPT:
			return "corrupt file"
		ERR_FILE_MISSING_DEPENDENCIES:
			return "missing dependencies"
		ERR_FILE_EOF:
			return "unexpected end of file"
		ERR_CANT_OPEN:
			return "cannot open"
		ERR_CANT_CREATE:
			return "cannot create"
		ERR_QUERY_FAILED:
			return "query failed"
		ERR_ALREADY_IN_USE:
			return "already in use"
		ERR_LOCKED:
			return "locked"
		ERR_TIMEOUT:
			return "timeout"
		ERR_CANT_CONNECT:
			return "cannot connect"
		ERR_CANT_RESOLVE:
			return "cannot resolve"
		ERR_CONNECTION_ERROR:
			return "connection error"
		ERR_CANT_ACQUIRE_RESOURCE:
			return "cannot acquire resource"
		ERR_CANT_FORK:
			return "cannot fork"
		ERR_INVALID_DATA:
			return "invalid data"
		ERR_INVALID_PARAMETER:
			return "invalid parameter"
		ERR_ALREADY_EXISTS:
			return "already exists"
		ERR_DOES_NOT_EXIST:
			return "does not exist"
		ERR_DATABASE_CANT_READ:
			return "database cannot read"
		ERR_DATABASE_CANT_WRITE:
			return "database cannot write"
		ERR_COMPILATION_FAILED:
			return "compilation failed"
		ERR_METHOD_NOT_FOUND:
			return "method not found"
		ERR_LINK_FAILED:
			return "link failed"
		ERR_SCRIPT_FAILED:
			return "script failed"
		ERR_CYCLIC_LINK:
			return "cyclic link"
		ERR_INVALID_DECLARATION:
			return "invalid declaration"
		ERR_DUPLICATE_SYMBOL:
			return "duplicate symbol"
		ERR_PARSE_ERROR:
			return "parse error"
		ERR_BUSY:
			return "busy"
		ERR_SKIP:
			return "skipped"
		ERR_HELP:
			return "help"
		ERR_BUG:
			return "internal bug"
		ERR_PRINTER_ON_FIRE:
			return "printer on fire"
		_:
			return "unknown engine error (%d)" % err
