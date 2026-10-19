## "Console" tab next to the Git Log: every mutating git command the plugin ran (with its output), plus a prompt for running your own for anything the UI doesn't cover.
@tool
extends VBoxContainer

const GitCli := preload("res://addons/godit/util/git_cli.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const SaveGuard := preload("res://addons/godit/dock/widgets/save_guard.gd")

const POLL_INTERVAL := 0.5
## Commands whose output can rewrite the working tree, so the editor reloads open files after them.
const TREE_CHANGING := ["checkout", "switch", "reset", "merge", "rebase", "pull", "cherry-pick", "revert", "stash", "restore", "apply", "am", "clean", "rm", "mv"]
## Options before the command that take the next argument as their value.
const OPTIONS_WITH_VALUE := ["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"]

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


## Index of the git command in args, after the options that come before it; -1 if there's none.
static func command_index(args: PackedStringArray) -> int:
	var i := 0
	while i < args.size() and args[i].begins_with("-"):
		i += 2 if args[i] in OPTIONS_WITH_VALUE else 1
	return i if i < args.size() else -1


## Why a typed command gets a confirmation first (it throws work away or rewrites what others see), or "". alias: what git config has for alias.<command>.
static func risk(args: PackedStringArray, alias := "") -> String:
	for i in args.size() - 1:
		if args[i] == "-c" and args[i + 1].to_lower().begins_with("alias."):
			return "It defines a git alias for this command, which can run anything."
	var index := command_index(args)
	if index == -1:
		return ""
	var rest := args.slice(index + 1)
	var flags := rest.slice(0, rest.find("--")) if rest.has("--") else rest
	match args[index]:
		"reset":
			if flags.has("--hard"):
				return "It throws away uncommitted changes to tracked files."
		"clean":
			if not flags.has("--dry-run") and not _has_short_flag(flags, "n"):
				return "It deletes untracked files for good."
		"push":
			if _has_short_flag(flags, "f") or _has_short_flag(flags, "d") or Array(flags).any(func(f: String) -> bool:
					return f.begins_with("--force") or f in ["--mirror", "--delete", "--prune"] or f.begins_with("+") or (f.begins_with(":") and f.length() > 1)):
				return "It can overwrite or delete branches and history on the remote."
		"checkout", "switch":
			if flags.has("-f") or flags.has("--force") or flags.has("--discard-changes") or rest.has("--") or rest.has("."):
				return "It throws away uncommitted changes to files."
		"restore":
			if not (flags.has("--staged") or flags.has("-S")) or flags.has("--worktree") or flags.has("-W"):
				return "It throws away uncommitted changes to files."
		"branch":
			if flags.has("-D") or ((flags.has("-d") or flags.has("--delete")) and (flags.has("-f") or flags.has("--force"))):
				return "It deletes a branch even if its commits aren't merged anywhere."
		"stash":
			if not rest.is_empty() and rest[0] in ["drop", "clear"]:
				return "It deletes stashed changes for good."
		"rm":
			if (flags.has("-f") or flags.has("--force")) and not flags.has("--cached"):
				return "It deletes the files from disk, changes and all."
		"filter-branch", "filter-repo":
			return "It rewrites the whole history."
		"config":
			if (flags.has("--global") or flags.has("--system")) and not _is_config_read(flags):
				return "It changes git settings outside this project."
	if alias.begins_with("!"):
		return "It's an alias that runs a shell command: " + alias.substr(1)
	if not alias.is_empty():
		var expanded := args.slice(0, index)
		expanded.append_array(split_args(alias))
		expanded.append_array(rest)
		return risk(expanded)
	return ""


## Whether one of the single-dash flags ("-fd") has letter in it.
static func _has_short_flag(flags: PackedStringArray, letter: String) -> bool:
	return Array(flags).any(func(f: String) -> bool: return f.length() > 1 and f[0] == "-" and f[1] != "-" and letter in f)


static func _is_config_read(flags: PackedStringArray) -> bool:
	for f in flags:
		if f in ["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "get", "list"]:
			return true
		if f in ["--unset", "--unset-all", "--add", "--replace-all", "--rename-section", "--remove-section", "-e", "--edit", "set", "unset", "edit", "rename-section", "remove-section"]:
			return false
	return Array(flags).filter(func(f: String) -> bool: return not f.begins_with("-")).size() <= 1 # just a key: the old way of reading it


func _run() -> void:
	var line := _input.text.strip_edges()
	if line.begins_with("git "):
		line = line.substr(4)
	if line.is_empty() or _repo == null or _repo.is_busy() or not _input.editable:
		return
	var args := split_args(line)
	var index := command_index(args)
	var alias := "" if index == -1 else String(GitCli.run(_repo.get_repo_root(), ["config", "--get", "alias." + args[index]])["text"]).strip_edges()
	var reason := risk(args, alias)
	if not reason.is_empty() and not await Dialogs.confirm(self, "Run This Command?", "%s\n\ngit %s" % [reason, line], "Run"):
		return
	var changes_tree := index != -1 and TREE_CHANGING.has(args[index]) and not (args[index] == "stash" and args.size() > index + 1 and args[index + 1] in ["list", "show"])
	if changes_tree and not await SaveGuard.ensure_saved(self, "Run git " + args[index]):
		return
	_history.append(line)
	_history_index = _history.size()
	_input.text = ""
	_input.editable = false
	_run_button.disabled = true
	var job := GitCli.start(_repo.get_repo_root(), args)
	_repo.current_job = job
	await job.finished
	if _repo.current_job == job:
		_repo.current_job = null
	_input.editable = true
	_run_button.disabled = false
	_input.grab_focus()
	if changes_tree:
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
