## Blame column in the script editor, left of the diff gutter: author and age on every line, dimmed where it repeats the line above. Clicking one emits commit_clicked, which plugin.gd routes to the Git Log.
extends Node

signal commit_clicked(oid: String)
## From the script editor's context menu; plugin.gd saves the setting and calls set_enabled().
signal toggle_requested(enabled: bool)

const DiffGutter := preload("res://addons/godit/dock/gutter/diff_gutter.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const PollTimer := preload("res://addons/godit/util/poll_timer.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")
const GutterPainter := preload("res://addons/godit/dock/gutter/gutter_painter.gd")

const GUTTER_NAME := "godit_blame"
## Upper bound for the column, before editor scale; the actual width fits the longest label.
const MAX_GUTTER_WIDTH := 260
const REFRESH_INTERVAL := 2.0

const META_BLAME := GutterPainter.META_BLAME
## What the current blame was computed from (path, text, HEAD), so the timer only reruns git when one of them changes.
const META_SIGNATURE := "godit_blame_signature"

var _script_editor: ScriptEditor
var _refresh_timer: PollTimer
var _enabled := false
var _in_flight := false
## [CodeEdit, Callable] pairs connected to gutter_clicked, so disable() can disconnect them.
var _connections: Array = []
## CodeEdits given the gutter, so turning blame off can collapse it everywhere.
var _code_edits: Array = []


## _init, not _ready: plugin.gd calls set_enabled() from its _enter_tree, before children get _ready.
func _init() -> void:
	_refresh_timer = PollTimer.new(REFRESH_INTERVAL)
	_refresh_timer.poll.connect(_refresh_current)
	add_child(_refresh_timer)


func is_enabled() -> bool:
	return _enabled


## Commit (oid) that last changed 0-based line as the editor shows it, "" if uncommitted. Coroutine.
func commit_at(res_path: String, code_edit: CodeEdit, line: int) -> String:
	var resolved := DiffGutter.resolve_repo(res_path)
	if resolved.is_empty():
		return ""
	var lines: Variant = await resolved["repo"].blame(resolved["rel_path"], code_edit.text)
	return lines[line]["oid"] if lines != null and line < lines.size() else ""


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_refresh_timer.active = enabled
	if enabled:
		_refresh_current()
		return
	# Collapsed rather than removed: removing a gutter would shift the diff gutter's (and Godot's own) indices under open tabs.
	for code_edit in _code_edits:
		if is_instance_valid(code_edit):
			var index := DiffGutter.gutter_index(code_edit, GUTTER_NAME)
			if index != -1:
				code_edit.set_gutter_width(index, 0)
			code_edit.remove_meta(META_SIGNATURE)


func disable() -> void:
	set_enabled(false)
	for pair in _connections:
		if is_instance_valid(pair[0]) and pair[0].gutter_clicked.is_connected(pair[1]):
			pair[0].gutter_clicked.disconnect(pair[1])
	_connections.clear()


func _refresh_current() -> void:
	if not _enabled or _in_flight:
		return
	if _script_editor == null:
		_script_editor = EditorInterface.get_script_editor()
	var editor_base := _script_editor.get_current_editor()
	var res_path := EditorOpen.current_tab_path()
	if editor_base == null or not res_path.begins_with("res://"):
		return
	var code_edit := editor_base.get_base_editor() as CodeEdit
	if code_edit == null:
		return

	var resolved := DiffGutter.resolve_repo(res_path)
	if resolved.is_empty():
		return
	var text := code_edit.text
	var signature := "%s|%d|%s" % [resolved["rel_path"], text.hash(), resolved["repo"].read_head_oid()]
	_install_gutter(code_edit)
	if code_edit.get_meta(META_SIGNATURE, "") == signature:
		return

	_in_flight = true
	var lines: Variant = await resolved["repo"].blame(resolved["rel_path"], text)
	_in_flight = false
	if not is_instance_valid(code_edit):
		return
	# Untracked or not yet committed at all: nothing to blame, keep the column empty.
	code_edit.set_meta(META_BLAME, lines if lines != null else [])
	code_edit.set_meta(META_SIGNATURE, signature)
	_fit_width(code_edit)
	code_edit.queue_redraw()


## Widest run label plus padding, so "Author · 3w" is never cut off (and a short name doesn't waste space).
func _fit_width(code_edit: CodeEdit) -> void:
	var index := DiffGutter.gutter_index(code_edit, GUTTER_NAME)
	if index == -1 or not _enabled:
		return
	var font := code_edit.get_theme_font("font")
	var font_size := GutterPainter.blame_font_size(code_edit)
	var lines: Array = code_edit.get_meta(META_BLAME, [])
	var widest := 0.0
	for i in lines.size():
		if i == 0 or lines[i - 1]["oid"] != lines[i]["oid"]:
			widest = maxf(widest, font.get_string_size(GutterPainter.blame_label(lines[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	var scale := EditorInterface.get_editor_scale()
	code_edit.set_gutter_width(index, int(minf(widest + 14 * scale, MAX_GUTTER_WIDTH * scale)) if widest > 0 else 0)


func _install_gutter(code_edit: CodeEdit) -> void:
	var index := DiffGutter.gutter_index(code_edit, GUTTER_NAME)
	if index == -1:
		index = maxi(DiffGutter.gutter_index(code_edit, DiffGutter.GUTTER_NAME), 0)
		code_edit.add_gutter(index)
		code_edit.set_gutter_name(index, GUTTER_NAME)
		code_edit.set_gutter_type(index, TextEdit.GUTTER_TYPE_CUSTOM)
		code_edit.set_meta(META_BLAME, [])
	_fit_width(code_edit)
	# Re-bound every time, like the diff gutter: a plugin reload replaces this Node but not the CodeEdit.
	code_edit.set_gutter_custom_draw(index, GutterPainter.draw_blame.bind(code_edit))
	code_edit.set_gutter_clickable(index, true)
	if not _code_edits.has(code_edit):
		_code_edits.append(code_edit)
	if not _connections.any(func(pair: Array) -> bool: return pair[0] == code_edit):
		var on_click := _on_gutter_clicked.bind(code_edit)
		code_edit.gutter_clicked.connect(on_click)
		_connections.append([code_edit, on_click])


func _on_gutter_clicked(line: int, gutter: int, code_edit: CodeEdit) -> void:
	if gutter != DiffGutter.gutter_index(code_edit, GUTTER_NAME):
		return
	var lines: Array = code_edit.get_meta(META_BLAME, [])
	if line < lines.size() and not String(lines[line]["oid"]).is_empty():
		commit_clicked.emit(lines[line]["oid"])
