## IntelliJ-style inline preview of one change: the HEAD lines it replaced, with prev/next, Rollback and Show in Changes. A plain child Control of the script's CodeEdit rather than a popup Window, which never reliably showed up on multi-monitor macOS.
extends PanelContainer

signal navigate_requested(delta: int)
signal rollback_requested
signal show_in_changes_requested
signal closed

const DiffHunks := preload("res://addons/git_tree/util/diff_hunks.gd")
const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")
const SyntaxColors := preload("res://addons/git_tree/util/syntax_colors.gd")

const MAX_VISIBLE_LINES := 15

var _code_edit: CodeEdit
## Last line (0-based) of the change; the panel sits right under it.
var _anchor_line := 0
## First line (0-based) of the change, for flipping the panel above it.
var _first_line := 0
var _opened_msec := 0
var _old_view: CodeEdit


func open(code_edit: CodeEdit, regions: Array, index: int, rel_path: String) -> void:
	_code_edit = code_edit
	var region: Dictionary = regions[index]
	var type := DiffHunks.region_type(region)
	_anchor_line = maxi(region["new_start"] - 1, 0) if type == "deleted" else region["new_start"] + region["new_count"] - 2
	_first_line = maxi(region["new_start"] - 1, 0)
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0

	var style := StyleBoxFlat.new()
	style.bg_color = _opaque_background(code_edit)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = int(10 * scale)
	style.border_color = GitIcons.COLOR_DELETED if type == "deleted" else (GitIcons.COLOR_ADDED if type == "added" else GitIcons.COLOR_MODIFIED)
	style.border_width_left = int(3 * scale)
	style.set_border_width(SIDE_TOP, 1)
	style.set_border_width(SIDE_BOTTOM, 1)
	style.set_content_margin_all(6 * scale)
	style.set_corner_radius_all(int(3 * scale))
	add_theme_stylebox_override("panel", style)

	var layout := VBoxContainer.new()
	add_child(layout)
	var toolbar := HBoxContainer.new()
	layout.add_child(toolbar)
	_add_button(toolbar, "", "ArrowUp", "Previous change", index > 0, func() -> void: navigate_requested.emit(-1))
	_add_button(toolbar, "", "ArrowDown", "Next change", index < regions.size() - 1, func() -> void: navigate_requested.emit(1))
	var title := Label.new()
	title.text = "Change %d of %d · %s" % [index + 1, regions.size(), _summary(region, type)]
	title.modulate.a = 0.75
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	title.clip_text = true
	toolbar.add_child(title)
	_add_button(toolbar, "Rollback", "Reload", "Put the HEAD version of these lines back in the editor (undo with Ctrl/Cmd+Z)", true, func() -> void: rollback_requested.emit())
	_add_button(toolbar, "Show in Changes", "", "Open this hunk in the Changes panel, where it can be staged", true, func() -> void: show_in_changes_requested.emit())
	_add_button(toolbar, "", "Close", "Close (Esc)", true, close)

	var old_lines: PackedStringArray = region["old_lines"]
	if not old_lines.is_empty():
		_old_view = CodeEdit.new()
		_old_view.text = "\n".join(old_lines)
		_old_view.editable = false
		_old_view.context_menu_enabled = false
		_old_view.scroll_fit_content_height = false
		_old_view.add_theme_font_override("font", code_edit.get_theme_font("font"))
		_old_view.add_theme_font_size_override("font_size", code_edit.get_theme_font_size("font_size"))
		_old_view.add_theme_color_override("background_color", GitIcons.COLOR_DELETED.lerp(style.bg_color, 0.85))
		_old_view.add_theme_color_override("font_color", code_edit.get_theme_color("font_color"))
		_old_view.add_theme_color_override("font_readonly_color", code_edit.get_theme_color("font_color"))
		var language := SyntaxColors.language_for(rel_path)
		if not language.is_empty():
			var highlighter := OldLinesHighlighter.new()
			highlighter.language = language
			highlighter.default_color = code_edit.get_theme_color("font_color")
			_old_view.syntax_highlighter = highlighter
		_old_view.size_flags_horizontal = SIZE_EXPAND_FILL
		var visible_lines := mini(old_lines.size(), MAX_VISIBLE_LINES)
		# Room for the horizontal scrollbar too, or a long line hides the last row under it.
		_old_view.custom_minimum_size.y = visible_lines * code_edit.get_line_height() + 10 * scale + _old_view.get_h_scroll_bar().get_combined_minimum_size().y
		layout.add_child(_old_view)

	code_edit.add_child(self)
	_opened_msec = Time.get_ticks_msec()
	code_edit.text_changed.connect(close)
	code_edit.caret_changed.connect(_on_caret_changed)
	code_edit.gui_input.connect(_on_code_edit_gui_input)
	_reposition()


func close() -> void:
	if is_queued_for_deletion():
		return
	if is_instance_valid(_code_edit):
		for pair in [[_code_edit.text_changed, close], [_code_edit.caret_changed, _on_caret_changed], [_code_edit.gui_input, _on_code_edit_gui_input]]:
			if (pair[0] as Signal).is_connected(pair[1]):
				(pair[0] as Signal).disconnect(pair[1])
	closed.emit()
	queue_free()


func _summary(region: Dictionary, type: String) -> String:
	match type:
		"added":
			return "%d line%s added" % [region["new_count"], "" if region["new_count"] == 1 else "s"]
		"deleted":
			return "%d line%s deleted" % [region["old_count"], "" if region["old_count"] == 1 else "s"]
	return "%d → %d line%s" % [region["old_count"], region["new_count"], "" if region["new_count"] == 1 else "s"]


## Solid, like a tooltip: the script editor's background_color is often transparent (the panel behind it paints the color).
static func _opaque_background(code_edit: CodeEdit) -> Color:
	var bg := code_edit.get_theme_color("background_color")
	if bg.a < 0.9 and Engine.is_editor_hint():
		bg = EditorInterface.get_editor_theme().get_color("base_color", "Editor")
	bg.a = 1.0
	return bg.lightened(0.05)


func _add_button(parent: Control, text: String, icon_name: String, tooltip: String, enabled: bool, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	if not icon_name.is_empty() and Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme.has_icon(icon_name, "EditorIcons"):
			b.icon = theme.get_icon(icon_name, "EditorIcons")
	if b.text.is_empty() and b.icon == null:
		b.text = {"ArrowUp": "▲", "ArrowDown": "▼", "Close": "✕"}.get(icon_name, "?")
	b.flat = true
	b.tooltip_text = tooltip
	b.disabled = not enabled
	b.focus_mode = FOCUS_NONE
	b.pressed.connect(action)
	parent.add_child(b)


## Every frame: scrolling (wheel, minimap, code) and resizing have no single signal to hook, and this is one cheap lookup.
func _process(_delta: float) -> void:
	_reposition()


func _reposition() -> void:
	if not is_instance_valid(_code_edit):
		return
	var pos := _code_edit.get_pos_at_line_column(clampi(_anchor_line, 0, _code_edit.get_line_count() - 1), 0)
	var first_pos := _code_edit.get_pos_at_line_column(_first_line, 0)
	visible = pos.y >= 0 or first_pos.y >= 0
	if not visible:
		return
	var left := float(_code_edit.get_total_gutter_width())
	var right_margin := _code_edit.get_v_scroll_bar().size.x + 6.0
	# Width through the minimum size: reset_size() (needed to fit the height) would otherwise shrink it to the toolbar.
	custom_minimum_size.x = maxf(_code_edit.size.x - left - right_margin, 200.0)
	reset_size()
	var below := pos.y + 2.0 if pos.y >= 0 else _code_edit.size.y
	var y := below
	# Flip above the change when there's no room below it.
	if below + size.y > _code_edit.size.y and first_pos.y >= 0:
		y = maxf(first_pos.y - _code_edit.get_line_height() - size.y - 2.0, 0.0)
	position = Vector2(left, minf(y, maxf(_code_edit.size.y - size.y, 0.0)))


## The click that opened this (or prev/next) may move the caret right away; anything later means the user moved on.
func _on_caret_changed() -> void:
	if Time.get_ticks_msec() - _opened_msec > 150:
		close()


func _on_code_edit_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		_code_edit.accept_event()


## Colors the old lines like the diff view does (SyntaxColors), since the script editor's own highlighter is bound to its CodeEdit.
class OldLinesHighlighter:
	extends SyntaxHighlighter

	var language := ""
	var default_color := Color.WHITE


	func _get_line_syntax_highlighting(line: int) -> Dictionary:
		var text := get_text_edit().get_line(line)
		var result := {}
		for span in SyntaxColors.spans(text, language):
			result[span[0]] = { "color": span[2] }
			result[span[0] + span[1]] = { "color": default_color }
		return result
