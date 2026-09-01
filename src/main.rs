use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

const MAX_WALK_DEPTH: usize = 64;

#[derive(Debug, Clone)]
struct Diagnostic {
    file: String,
    line: usize,
    column: usize,
    severity: &'static str,
    message: String,
    code: &'static str,
    source: &'static str,
}

struct Args {
    project_root: PathBuf,
    source_file: Option<PathBuf>,
    source_path: Option<String>,
    unknown: Vec<String>,
    missing_values: Vec<String>,
}

fn main() {
    let args = parse_args();
    let root = args.project_root;
    let mut diagnostics = Vec::new();

    for flag in &args.unknown {
        diagnostics.push(cli_diagnostic(
            "warning",
            "CLI_UNKNOWN",
            &format!("unknown argument '{flag}' was ignored"),
        ));
    }
    for flag in &args.missing_values {
        diagnostics.push(cli_diagnostic(
            "error",
            "CLI_MISSING_VALUE",
            &format!("argument '{flag}' is missing a value"),
        ));
    }

    match root.try_exists() {
        Ok(true) if root.is_dir() => {
            let mut visited = HashSet::new();
            scan_dir(
                &root,
                &root,
                args.source_path.as_deref(),
                &mut visited,
                0,
                &mut diagnostics,
            );
        }
        Ok(true) => diagnostics.push(cli_diagnostic(
            "error",
            "IO_NOT_DIRECTORY",
            &format!("project root '{}' is not a directory", root.display()),
        )),
        Ok(false) => diagnostics.push(cli_diagnostic(
            "error",
            "IO_NOT_FOUND",
            &format!("project root '{}' does not exist", root.display()),
        )),
        Err(error) => diagnostics.push(io_diagnostic("res://", &error)),
    }

    if let Some(source_file) = args.source_file {
        let display_path = args
            .source_path
            .clone()
            .unwrap_or_else(|| "res://[unsaved].gd".into());
        check_file_with_display(&source_file, &display_path, &mut diagnostics);
    }

    diagnostics.sort_by(|a, b| a.file.cmp(&b.file).then(a.line.cmp(&b.line)));
    println!(
        "[{}]",
        diagnostics
            .iter()
            .map(Diagnostic::json)
            .collect::<Vec<_>>()
            .join(",")
    );
    if diagnostics.iter().any(|item| item.severity == "error") {
        std::process::exit(1);
    }
}

fn parse_args() -> Args {
    let mut parsed = Args {
        project_root: PathBuf::from("."),
        source_file: None,
        source_path: None,
        unknown: Vec::new(),
        missing_values: Vec::new(),
    };
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--project-root" => match args.next() {
                Some(value) => parsed.project_root = PathBuf::from(value),
                None => parsed.missing_values.push(arg),
            },
            "--source-file" => match args.next() {
                Some(value) => parsed.source_file = Some(PathBuf::from(value)),
                None => parsed.missing_values.push(arg),
            },
            "--source-path" => match args.next() {
                Some(value) => parsed.source_path = Some(value),
                None => parsed.missing_values.push(arg),
            },
            "--help" | "-h" => {}
            other => parsed.unknown.push(other.to_string()),
        }
    }
    parsed
}

fn scan_dir(
    root: &Path,
    dir: &Path,
    skip_res: Option<&str>,
    visited: &mut HashSet<PathBuf>,
    depth: usize,
    diagnostics: &mut Vec<Diagnostic>,
) {
    if depth > MAX_WALK_DEPTH {
        diagnostics.push(Diagnostic {
            file: res_path(root, dir),
            line: 1,
            column: 1,
            severity: "error",
            message: format!("directory tree exceeds maximum depth at {}", dir.display()),
            code: "IO_DEPTH",
            source: "io",
        });
        return;
    }
    let key = fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    if !visited.insert(key) {
        return;
    }
    match fs::read_dir(dir) {
        Err(error) => diagnostics.push(io_diagnostic(&res_path(root, dir), &error)),
        Ok(entries) => {
            for entry in entries {
                match entry {
                    Err(error) => diagnostics.push(io_diagnostic(&res_path(root, dir), &error)),
                    Ok(entry) => {
                        let path = entry.path();
                        if path
                            .file_name()
                            .is_some_and(|name| name == ".godot" || name == "target")
                        {
                            continue;
                        }
                        if path == root.join("addons").join("rs_godot_edit") {
                            continue;
                        }
                        if path.is_dir() {
                            scan_dir(root, &path, skip_res, visited, depth + 1, diagnostics);
                        } else if path.extension().is_some_and(|extension| extension == "gd") {
                            let file = res_path(root, &path);
                            if skip_res.is_some_and(|skip| skip == file) {
                                continue;
                            }
                            check_file_with_display(&path, &file, diagnostics);
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
fn check_file(root: &Path, path: &Path, diagnostics: &mut Vec<Diagnostic>) {
    let file = res_path(root, path);
    check_file_with_display(path, &file, diagnostics);
}

fn res_path(root: &Path, path: &Path) -> String {
    let relative = path
        .strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/");
    format!("res://{}", relative.trim_start_matches('/'))
}

fn check_file_with_display(path: &Path, file: &str, diagnostics: &mut Vec<Diagnostic>) {
    match fs::read_to_string(path) {
        Ok(source) => check_source(file, &source, diagnostics),
        Err(error) => diagnostics.push(io_diagnostic(file, &error)),
    }
}

fn check_source(file: &str, source: &str, diagnostics: &mut Vec<Diagnostic>) {
    let mut indents: Vec<usize> = vec![0];
    let mut previous_code = String::new();
    let mut previous_indent = 0;
    let mut seen_function = false;
    let mut block_header: Option<(usize, usize)> = None;
    let mut forward_array_loop_indent: Option<usize> = None;
    let mut abstract_annotation = false;
    let mut mutable_aliases: HashMap<String, String> = HashMap::new();
    let mut quote: Option<char> = None;
    let mut brackets: Vec<(char, usize, usize)> = Vec::new();
    let defined_functions: HashSet<String> = source
        .lines()
        .filter_map(|raw| raw.trim_start().strip_prefix("func "))
        .filter_map(|declaration| declaration.split('(').next())
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(String::from)
        .collect();

    for (index, raw) in source.lines().enumerate() {
        let line = index + 1;
        let leading = raw
            .chars()
            .take_while(|c| *c == ' ' || *c == '\t')
            .collect::<String>();
        let code = raw[leading.len()..]
            .split('#')
            .next()
            .unwrap_or("")
            .trim_end();
        if code.trim().is_empty() {
            continue;
        }
        let indent = leading
            .chars()
            .map(|c| if c == '\t' { 4 } else { 1 })
            .sum::<usize>();

        if let Some(loop_indent) = forward_array_loop_indent {
            if indent <= loop_indent && !code.trim_start().starts_with("for ") {
                forward_array_loop_indent = None;
            }
        }
        if code.trim_start().starts_with("for ")
            && code.contains("range(")
            && code.contains(".size()")
        {
            forward_array_loop_indent = Some(indent);
        }

        if leading.contains(' ') && leading.contains('\t') {
            diagnostics.push(diag(
                &file,
                line,
                1,
                "error",
                "leading indentation mixes tabs and spaces",
                "E001",
            ));
        }
        if has_numeric_string_addition(code) {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "cannot use '+' between an integer and a String; convert the value explicitly",
                "E013",
            ));
        }
        if code.trim_start() == "static" {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "'static' must be followed by 'func' or 'var'",
                "E016",
            ));
        }
        if has_missing_operator_operand(code) {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "operator is missing its right-hand expression",
                "E014",
            ));
        }
        if code.trim_start() == "@abstract" {
            abstract_annotation = true;
        } else if abstract_annotation {
            if code.trim_start().starts_with("var ") {
                diagnostics.push(diag(
                    &file,
                    line,
                    leading.len() + 1,
                    "error",
                    "annotation '@abstract' cannot be applied to a variable",
                    "E011",
                ));
            }
            abstract_annotation = false;
        }
        let previous_opens_block = previous_code.trim_end().ends_with(':')
            || previous_code.trim_end().ends_with('[')
            || previous_code.trim_end().ends_with('(')
            || previous_code.trim_end().ends_with('{');
        if indent > previous_indent && !previous_opens_block {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "unexpected indentation; the previous statement does not open a block",
                "E002",
            ));
        }
        if code.starts_with("func ") {
            seen_function = true;
        } else if seen_function && indent == 0 && code.starts_with("extends ") {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "extends declaration must appear before functions and other class members",
                "E009",
            ));
        }
        if indent > *indents.last().unwrap() {
            indents.push(indent);
        } else if !indents.contains(&indent) {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "inconsistent indentation level",
                "E003",
            ));
        } else {
            while *indents.last().unwrap() > indent {
                indents.pop();
            }
        }

        if let Some((header_line, header_indent)) = block_header {
            if indent <= header_indent && line > header_line + 1 {
                diagnostics.push(diag(
                    &file,
                    header_line,
                    1,
                    "error",
                    "block statement has no indented body",
                    "E004",
                ));
                block_header = None;
            }
        }
        if code.ends_with(':') {
            block_header = Some((line, indent));
        } else if block_header.is_some() && indent > previous_indent {
            block_header = None;
        }

        if (code.starts_with("if ") || code.starts_with("elif ") || code.starts_with("while "))
            && code.contains('=')
            && !code.contains("==")
            && !code.contains(">=")
            && !code.contains("<=")
            && !code.contains("!=")
        {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "warning",
                "assignment used in a conditional; use '==' for comparison",
                "W001",
            ));
        }
        if (previous_code.trim_start().starts_with("return")
            || previous_code.trim_start().starts_with("break")
            || previous_code.trim_start().starts_with("continue"))
            && indent == previous_indent
        {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "warning",
                "unreachable statement after control-flow exit",
                "W002",
            ));
        }
        if forward_array_loop_indent.is_some() && code.contains(".remove_at(") {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "warning",
                "removing from an array while iterating forward can skip the next element; iterate backwards instead",
                "W003",
            ));
        }
        if let Some((left, right)) = assignment_identifiers(code) {
            mutable_aliases.insert(left, right);
        }
        for (alias, original) in &mutable_aliases {
            if code.contains(&format!("{}[", alias)) && code.contains("] =") {
                diagnostics.push(diag(
                    &file,
                    line,
                    leading.len() + 1,
                    "warning",
                    &format!(
                        "mutable value '{}' aliases '{}'; use .duplicate() before modifying it",
                        alias, original
                    ),
                    "W004",
                ));
                break;
            }
        }
        for called in called_identifiers(code) {
            if !defined_functions.contains(&called) && !known_gdscript_function(&called) {
                diagnostics.push(diag(
                    &file,
                    line,
                    leading.len() + 1,
                    "error",
                    &format!("function '{}' is not defined in this script", called),
                    "E012",
                ));
            }
        }
        if code.starts_with("func ") && !code.contains(')') {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "function declaration is missing ')",
                "E005",
            ));
        } else if code.starts_with("func ") && !code.ends_with(':') {
            diagnostics.push(diag(
                &file,
                line,
                leading.len() + 1,
                "error",
                "function declaration must end with ':'",
                "E006",
            ));
        }

        for (column, ch) in code.char_indices() {
            if let Some(current) = quote {
                if ch == current {
                    quote = None;
                }
                continue;
            }
            if ch == '\'' || ch == '"' {
                quote = Some(ch);
                continue;
            }
            if matches!(ch, '(' | '[' | '{') {
                brackets.push((ch, line, column + leading.len() + 1));
            }
            if matches!(ch, ')' | ']' | '}') {
                let expected = match ch {
                    ')' => '(',
                    ']' => '[',
                    '}' => '{',
                    _ => unreachable!(),
                };
                if brackets.last().is_some_and(|entry| entry.0 == expected) {
                    brackets.pop();
                } else {
                    diagnostics.push(diag(
                        &file,
                        line,
                        column + leading.len() + 1,
                        "error",
                        "closing bracket does not match an opening bracket",
                        "E007",
                    ));
                }
            }
        }
        previous_indent = indent;
        previous_code = code.to_string();
    }
    if let Some((header_line, _)) = block_header {
        diagnostics.push(diag(
            &file,
            header_line,
            1,
            "error",
            "block statement has no indented body",
            "E004",
        ));
    }
    if quote.is_some() {
        diagnostics.push(diag(
            &file,
            source.lines().count(),
            1,
            "error",
            "string is not terminated",
            "E015",
        ));
    }
    if let Some((_, line, column)) = brackets.last() {
        diagnostics.push(diag(
            &file,
            *line,
            *column,
            "error",
            "opening bracket is never closed",
            "E008",
        ));
    }
}

fn diag(
    file: &str,
    line: usize,
    column: usize,
    severity: &'static str,
    message: &str,
    code: &'static str,
) -> Diagnostic {
    Diagnostic {
        file: file.into(),
        line,
        column,
        severity,
        message: message.into(),
        code,
        source: "heuristic",
    }
}

fn cli_diagnostic(severity: &'static str, code: &'static str, message: &str) -> Diagnostic {
    Diagnostic {
        file: "res://".into(),
        line: 1,
        column: 1,
        severity,
        message: message.into(),
        code,
        source: "cli",
    }
}

fn io_diagnostic(file: &str, error: &std::io::Error) -> Diagnostic {
    Diagnostic {
        file: file.into(),
        line: 1,
        column: 1,
        severity: "error",
        message: format!("cannot access '{file}': {error}"),
        code: io_code(error.kind()),
        source: "io",
    }
}

fn io_code(kind: ErrorKind) -> &'static str {
    match kind {
        ErrorKind::NotFound => "IO_NOT_FOUND",
        ErrorKind::PermissionDenied => "IO_PERMISSION",
        ErrorKind::AlreadyExists => "IO_EXISTS",
        ErrorKind::InvalidInput => "IO_INVALID_INPUT",
        ErrorKind::InvalidData => "IO_INVALID_DATA",
        ErrorKind::TimedOut => "IO_TIMEOUT",
        ErrorKind::Interrupted => "IO_INTERRUPTED",
        ErrorKind::UnexpectedEof => "IO_EOF",
        ErrorKind::WouldBlock => "IO_WOULD_BLOCK",
        ErrorKind::BrokenPipe => "IO_BROKEN_PIPE",
        ErrorKind::ConnectionRefused => "IO_CONN_REFUSED",
        ErrorKind::ConnectionReset => "IO_CONN_RESET",
        ErrorKind::ConnectionAborted => "IO_CONN_ABORTED",
        ErrorKind::NotConnected => "IO_NOT_CONNECTED",
        ErrorKind::AddrInUse => "IO_ADDR_IN_USE",
        ErrorKind::AddrNotAvailable => "IO_ADDR_UNAVAIL",
        ErrorKind::WriteZero => "IO_WRITE_ZERO",
        ErrorKind::OutOfMemory => "IO_OOM",
        ErrorKind::Unsupported => "IO_UNSUPPORTED",
        _ => "IO_UNKNOWN",
    }
}

fn assignment_identifiers(code: &str) -> Option<(String, String)> {
    let body = code.trim_start().strip_prefix("var ")?;
    let (left, right) = body.split_once('=')?;
    let left = left.split(':').next()?.trim();
    let right = right.trim().trim_end_matches(';');
    if left.is_empty() || !right.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some((left.to_string(), right.to_string()))
}

fn called_identifiers(code: &str) -> Vec<String> {
    let chars: Vec<char> = code.chars().collect();
    let mut calls = Vec::new();
    for (index, character) in chars.iter().enumerate() {
        if *character != '(' || index == 0 {
            continue;
        }
        let mut start = index;
        while start > 0 && (chars[start - 1].is_ascii_alphanumeric() || chars[start - 1] == '_') {
            start -= 1;
        }
        if start == index || (start > 0 && chars[start - 1] == '.') {
            continue;
        }
        let name: String = chars[start..index].iter().collect();
        if !matches!(name.as_str(), "if" | "for" | "while" | "match" | "func") {
            calls.push(name);
        }
    }
    calls
}

fn known_gdscript_function(name: &str) -> bool {
    matches!(
        name,
        "print"
            | "print_rich"
            | "printerr"
            | "push_error"
            | "push_warning"
            | "range"
            | "str"
            | "len"
            | "int"
            | "float"
            | "bool"
            | "Vector2"
            | "Vector3"
            | "Color"
            | "Array"
            | "Dictionary"
            | "typeof"
            | "is_instance_valid"
            | "load"
            | "preload"
            | "abs"
            | "min"
            | "max"
            | "clamp"
    )
}

fn has_numeric_string_addition(code: &str) -> bool {
    let compact = code.replace(' ', "");
    compact.contains("+\"")
        || compact.contains("+'")
        || compact.contains("\"+")
        || compact.contains("'+")
}

fn has_missing_operator_operand(code: &str) -> bool {
    let compact = code.replace(' ', "");
    [
        "+)", "+]", "+}", "-)", "-]", "-}", "*)", "*]", "*}", "/)", "/]", "/}",
    ]
    .iter()
    .any(|token| compact.contains(token))
}

impl Diagnostic {
    fn json(&self) -> String {
        format!(
            r#"{{"file":"{}","line":{},"column":{},"severity":"{}","message":"{}","code":"{}","source":"{}"}}"#,
            escape(&self.file),
            self.line,
            self.column,
            self.severity,
            escape(&self.message),
            self.code,
            self.source
        )
    }
}

fn escape(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(source: &str) -> Vec<Diagnostic> {
        let path = env::temp_dir().join(format!("rs-godot-edit-test-{}.gd", source.len()));
        fs::write(&path, source).unwrap();
        let mut result = Vec::new();
        check_file(Path::new("/"), &path, &mut result);
        let _ = fs::remove_file(path);
        result
    }

    #[test]
    fn detects_inconsistent_indentation() {
        let result = check("func test():\n    a = 1\n       b = 2\n");
        assert!(result.iter().any(|item| item.code == "E002"));
    }

    #[test]
    fn detects_unreachable_code() {
        let result = check("func test():\n    return\n    print('never')\n");
        assert!(result.iter().any(|item| item.code == "W002"));
    }

    #[test]
    fn detects_forward_array_mutation() {
        let result = check(
            "func clean(items):\n    for i in range(items.size()):\n        items.remove_at(i)\n",
        );
        assert!(result.iter().any(|item| item.code == "W003"));
    }

    #[test]
    fn detects_mutable_dictionary_alias() {
        let result = check(
            "var defaults = {\"hp\": 100}\nfunc make():\n    var enemy = defaults\n    enemy[\"hp\"] = 50\n",
        );
        assert!(result.iter().any(|item| item.code == "W004"));
    }

    #[test]
    fn detects_missing_function() {
        let result = check("func ready():\n    create_enemy(\"Goblin\")\n");
        assert!(result.iter().any(|item| item.code == "E012"));
    }

    #[test]
    fn detects_numeric_string_addition() {
        let result = check("func ready():\n    print(1 + \"2\")\n");
        assert!(result.iter().any(|item| item.code == "E013"));
    }

    #[test]
    fn detects_empty_block_at_end_of_file() {
        let result = check("func ready():\n");
        assert!(result.iter().any(|item| item.code == "E004"));
    }

    #[test]
    fn detects_missing_operator_operand() {
        let result = check("func ready():\n    print(3+)\n");
        assert!(result.iter().any(|item| item.code == "E014"));
    }

    #[test]
    fn detects_incomplete_static_declaration() {
        let result = check("func ready():\n    static\n");
        assert!(result.iter().any(|item| item.code == "E016"));
    }

    #[test]
    fn reports_missing_source_file() {
        let mut result = Vec::new();
        check_file_with_display(
            Path::new("/this/does/not/exist-rs-godot-edit.gd"),
            "res://missing.gd",
            &mut result,
        );
        assert!(result.iter().any(|item| item.code == "IO_NOT_FOUND"));
        assert!(result.iter().any(|item| item.source == "io"));
    }

    #[test]
    fn maps_unknown_io_kind_to_fallback() {
        assert_eq!(io_code(ErrorKind::NotFound), "IO_NOT_FOUND");
        assert_eq!(io_code(ErrorKind::Other), "IO_UNKNOWN");
    }

    #[test]
    fn json_escapes_control_characters() {
        assert_eq!(escape("a\"b\\c\n\t"), r#"a\"b\\c\n\t"#);
        assert!(escape("\u{0007}").contains("\\u0007"));
    }
}
