## "Console" tab next to the Git Log: every mutating git command the plugin ran (with its output), plus a prompt for running your own for anything the UI doesn't cover.
@tool
extends VBoxContainer

const GitCli := preload("res://addons/godit/util/git_cli.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")

const POLL_INTERVAL := 0.5
## Commands whose output can rewrite the working tree, so the editor reloads open files after them.
const TREE_CHANGING := ["checkout", "switch", "reset", "merge", "rebase", "pull", "cherry-pick", "revert", "stash", "restore", "apply", "am", "clean", "rm", "mv"]

var _repo: RefCounted
var _output: RichTextLabel
var _input: LineEdit
var _run_button: Button
var _timer: Timer
var _shown_revision := -1
## Command-line history for Up/Down in the prompt.
var _history: PackedStringArray = []
var _history_index := 0


func _init() -> void:
	var bar := HBoxContainer.new()
	var hint := Label.new()
	hint.text = "Every git command Godit runs is logged here."
	hint.modulate.a = 0.6
	hint.size_flags_horizontal = SIZE_EXPAND_FILL
	hint.clip_text = true
	bar.add_child(hint)
	var copy := Button.new()
	copy.text = "Copy"
	copy.flat = true
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(_output.get_parsed_text()))
	bar.add_child(copy)
	var clear := Button.new()
	clear.text = "Clear"
	clear.flat = true
	clear.pressed.connect(func() -> void:
		GitCli.command_log.clear()
		GitCli.command_log_revision += 1
	)
	bar.add_child(clear)
	add_child(bar)

	_output = RichTextLabel.new()
	_output.bbcode_enabled = true
	_output.scroll_following = true
	_output.selection_enabled = true
	_output.context_menu_enabled = true
	_output.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_output)

	var prompt_row := HBoxContainer.new()
	var prompt := Label.new()
	prompt.text = "git"
	prompt.modulate = Color(0.6, 0.8, 1.0)
	prompt_row.add_child(prompt)
	_input = LineEdit.new()
	_input.size_flags_horizontal = SIZE_EXPAND_FILL
	_input.placeholder_text = "status, log --oneline -5, reflog, bisect start … (runs in the repo root; no interactive commands)"
	_input.text_submitted.connect(func(_t: String) -> void: _run())
	_input.gui_input.connect(_on_input_gui_input)
	prompt_row.add_child(_input)
	_run_button = Button.new()
	_run_button.text = "Run"
	_run_button.pressed.connect(_run)
	prompt_row.add_child(_run_button)
	add_child(prompt_row)

	_timer = Timer.new()
	_timer.wait_time = POLL_INTERVAL
	_timer.timeout.connect(_update)
	add_child(_timer)


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	_notification(NOTIFICATION_VISIBILITY_CHANGED)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _timer != null:
		if is_visible_in_tree() and _repo != null:
			_timer.start()
			_update()
		else:
			_timer.stop()


func _update() -> void:
	if _shown_revision == GitCli.command_log_revision:
		return
	_shown_revision = GitCli.command_log_revision
	_output.clear()
	for entry in GitCli.command_log:
		var time := Time.get_time_string_from_unix_time(entry["time"])
		var ok: bool = entry["exit_code"] == 0
		_output.push_color(Color(0.55, 0.55, 0.6))
		_output.add_text("[%s] " % time)
		_output.pop()
		_output.push_color(Color(0.6, 0.8, 1.0))
		_output.add_text("$ git " + " ".join(_quote_args(entry["args"])))
		_output.pop()
		_output.push_color(Color(0.55, 0.85, 0.55) if ok else Color(0.95, 0.5, 0.5))
		_output.add_text("   ✓\n" if ok else "   ✗ exit %d\n" % entry["exit_code"])
		_output.pop()
		var text: String = String(entry["text"]).strip_edges(false, true)
		if not text.is_empty():
			_output.push_color(Color(0.8, 0.8, 0.82) if ok else Color(0.95, 0.7, 0.7))
			_output.add_text(text + "\n")
			_output.pop()
		_output.add_text("\n")


static func _quote_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for a in args:
		out.append("\"%s\"" % a if a.contains(" ") or a.contains("\n") else a)
	return out


## Splits a command line into argv, honoring "double" and 'single' quotes (no shell is involved, so no other expansion happens).
static func split_args(line: String) -> PackedStringArray:
	var args := PackedStringArray()
	var current := ""
	var quote := ""
	var has_token := false
	for ch in line:
		if not quote.is_empty():
			if ch == quote:
				quote = ""
			else:
				current += ch
		elif ch == "\"" or ch == "'":
			quote = ch
			has_token = true
		elif ch == " " or ch == "\t":
			if has_token or not current.is_empty():
				args.append(current)
			current = ""
			has_token = false
		else:
			current += ch
	if has_token or not current.is_empty():
		args.append(current)
	return args


func _run() -> void:
	var line := _input.text.strip_edges()
	if line.begins_with("git "):
		line = line.substr(4)
	if line.is_empty() or _repo == null or _repo.is_busy():
		return
	_history.append(line)
	_history_index = _history.size()
	_input.text = ""
	_input.editable = false
	_run_button.disabled = true
	var args := split_args(line)
	var job := GitCli.start(_repo.get_repo_root(), args)
	_repo.current_job = job
	await job.finished
	if _repo.current_job == job:
		_repo.current_job = null
	_input.editable = true
	_run_button.disabled = false
	_input.grab_focus()
	if not args.is_empty() and TREE_CHANGING.has(args[0]):
		EditorOpen.refresh_all_external_changes()


func _on_input_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed) or _history.is_empty():
		return
	if event.keycode == KEY_UP:
		_history_index = maxi(0, _history_index - 1)
	elif event.keycode == KEY_DOWN:
		_history_index = mini(_history.size(), _history_index + 1)
	else:
		return
	_input.text = _history[_history_index] if _history_index < _history.size() else ""
	_input.caret_column = _input.text.length()
	_input.accept_event()
