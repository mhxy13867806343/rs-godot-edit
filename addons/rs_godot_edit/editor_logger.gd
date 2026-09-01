@tool
extends Logger

var entries: Array[Dictionary] = []
var mutex := Mutex.new()

func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	mutex.lock()
	var message := rationale if not rationale.is_empty() else code
	if message.is_empty():
		message = "unknown engine error"
	entries.append({
		"file": file,
		"line": line if line > 0 else 1,
		"column": 1,
		"message": message,
		"severity": _severity_from_error_type(error_type),
		"code": _code_from_error_type(error_type),
		"source": "godot",
	})
	mutex.unlock()

func _log_message(message: String, error: bool) -> void:
	if not error:
		return
	mutex.lock()
	entries.append({
		"file": "",
		"line": 1,
		"column": 1,
		"message": message if not message.is_empty() else "unknown engine message",
		"severity": "error",
		"code": "GODOT_MESSAGE",
		"source": "godot",
	})
	mutex.unlock()

func take_entries() -> Array[Dictionary]:
	mutex.lock()
	var result := entries.duplicate()
	entries.clear()
	mutex.unlock()
	return result

func clear() -> void:
	mutex.lock()
	entries.clear()
	mutex.unlock()

func _severity_from_error_type(error_type: int) -> String:
	match error_type:
		ERROR_TYPE_WARNING:
			return "warning"
		ERROR_TYPE_ERROR, ERROR_TYPE_SCRIPT, ERROR_TYPE_SHADER:
			return "error"
		_:
			return "error"

func _code_from_error_type(error_type: int) -> String:
	match error_type:
		ERROR_TYPE_ERROR:
			return "GODOT_ERROR"
		ERROR_TYPE_WARNING:
			return "GODOT_WARNING"
		ERROR_TYPE_SCRIPT:
			return "GODOT_SCRIPT"
		ERROR_TYPE_SHADER:
			return "GODOT_SHADER"
		_:
			return "GODOT_UNKNOWN_%d" % error_type
