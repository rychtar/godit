## Everything in one dock, SourceTree-style (Tools > Godit > Layout: Combined): a sidebar with the views and Branches, the chosen view beside it — meant to be made floating, e.g. on a second monitor.
@tool
extends Control

const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const RepoInitView := preload("res://addons/godit/dock/widgets/repo_init_view.gd")

const VIEW_SETTING_KEY := "combined_view"
const SIDEBAR_WIDTH := 240
## Below this width (a side dock) the view buttons go in a row on top and Branches becomes a view of its own.
const WIDE_MIN_WIDTH := 720
const VIEWS := ["changes", "history", "branches", "console"]
const VIEW_TITLES := {"changes": "File Status", "history": "History", "branches": "Branches", "console": "Console"}
const VIEW_ICONS := {"changes": &"Edit", "history": &"History", "branches": &"GuiTreeArrowRight", "console": &"Terminal"}
const VIEW_TOOLTIPS := {
	"changes": "Changed files, staging and the commit box",
	"history": "Commit graph of the whole repository",
	"branches": "Local and remote branches, tags, stashes and remotes",
	"console": "Every git command Godit ran, and a prompt for your own",
}

var _panels: Dictionary = {}
var _sync_bar: Control
var _layout: VBoxContainer
var _sidebar: VBoxContainer
var _buttons: BoxContainer
var _views: TabContainer
var _view_buttons := {}
## Number of changed files, right-aligned on the File Status button.
var _changes_badge: Label
var _headers: Array[Label] = []
var _wide := true
## The view shown last, besides Branches while it sits in the sidebar.
var _view := "changes"


## panels: {"changes", "branches", "history", "console"} taken from the other two docks, or {} when the project has no repository yet.
func _init(panels: Dictionary) -> void:
	name = "Godit"
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	if panels.is_empty():
		add_child(RepoInitView.new("This project isn't a git repository yet."))
		return
	_panels = panels

	_layout = VBoxContainer.new()
	_layout.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(_layout)
	_sync_bar = panels["changes"].detach_sync_bar()
	_sync_bar.set_actions_first(true)
	_layout.add_child(_sync_bar)
	panels["branches"].set_sidebar_mode(true)
	panels["branches"].ref_selected.connect(_on_ref_selected)

	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	_layout.add_child(split)
	_sidebar = VBoxContainer.new()
	_sidebar.custom_minimum_size.x = UiScale.px(SIDEBAR_WIDTH)
	_sidebar.add_theme_constant_override("separation", int(UiScale.px(2)))
	split.add_child(_sidebar)
	_views = TabContainer.new()
	_views.tabs_visible = false
	_views.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(_views)

	_sidebar.add_child(_header("Workspace"))
	var gap := Control.new()
	gap.custom_minimum_size.y = UiScale.px(8)
	_sidebar.add_child(gap) # Branches below brings its own BRANCHES / TAGS / … headers

	_buttons = BoxContainer.new()
	_buttons.add_theme_constant_override("separation", int(UiScale.px(1)))
	var group := ButtonGroup.new()
	for view: String in VIEWS:
		var button := Button.new()
		button.text = VIEW_TITLES[view]
		button.tooltip_text = VIEW_TOOLTIPS[view]
		button.toggle_mode = true
		button.button_group = group
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = UiScale.px(26)
		button.pressed.connect(show_view.bind(view))
		_buttons.add_child(button)
		_view_buttons[view] = button

	_changes_badge = Label.new()
	_changes_badge.set_anchors_and_offsets_preset(PRESET_RIGHT_WIDE)
	_changes_badge.offset_left = -UiScale.px(48)
	_changes_badge.offset_right = -UiScale.px(8)
	_changes_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_changes_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_changes_badge.mouse_filter = MOUSE_FILTER_IGNORE
	_changes_badge.modulate.a = 0.6
	_view_buttons["changes"].add_child(_changes_badge)
	_set_change_count(panels["changes"].change_count)
	panels["changes"].changes_counted.connect(_set_change_count)

	for view: String in VIEWS:
		panels[view].visible = true # the tab containers they came from hid all but the current one
		panels[view].size_flags_vertical = SIZE_EXPAND_FILL
		_views.add_child(panels[view])
	_view = Settings.get_value(VIEW_SETTING_KEY, "changes")
	_set_wide(true)
	resized.connect(func() -> void:
		if (size.x >= UiScale.px(WIDE_MIN_WIDTH)) != _wide:
			_set_wide(not _wide)
	)


## Small dimmed section title, like SourceTree's WORKSPACE.
func _header(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.modulate.a = 0.55
	var margin := StyleBoxEmpty.new()
	margin.content_margin_left = UiScale.px(6)
	margin.content_margin_top = UiScale.px(4)
	label.add_theme_stylebox_override("normal", margin)
	_headers.append(label)
	return label


func _notification(what: int) -> void:
	if what != NOTIFICATION_THEME_CHANGED or _panels.is_empty():
		return
	for view: String in _view_buttons:
		if has_theme_icon(VIEW_ICONS[view], &"EditorIcons"):
			_view_buttons[view].icon = get_theme_icon(VIEW_ICONS[view], &"EditorIcons")
		_style_view_button(_view_buttons[view])
	var small := int(get_theme_font_size(&"font_size", &"Label") * 0.85)
	for header in _headers:
		header.add_theme_font_size_override("font_size", small)


## Flat rows with a hover tint and the current view marked by an accent bar and background, instead of the stock button look.
func _style_view_button(button: Button) -> void:
	var accent := get_theme_color(&"accent_color", &"Editor")
	var font_color := get_theme_color(&"font_color", &"Label")
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0, 0, 0, 0)
	normal.content_margin_left = UiScale.px(10)
	normal.content_margin_right = UiScale.px(8)
	normal.set_corner_radius_all(int(UiScale.px(3)))
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(font_color, 0.07)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(accent, 0.22)
	pressed.border_color = accent
	pressed.border_width_left = int(UiScale.px(3))
	pressed.content_margin_left = UiScale.px(7) # keeps the text in place next to the bar
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", Color(font_color, 0.75))
	button.add_theme_color_override("font_hover_color", font_color)
	button.add_theme_color_override("font_pressed_color", font_color)
	button.add_theme_color_override("font_hover_pressed_color", font_color)


func _set_change_count(count: int) -> void:
	_changes_badge.text = str(count) if count > 0 else ""


## Wide: buttons and Branches in a sidebar left of the views. Narrow: buttons in a row above, Branches a view like the rest.
func _set_wide(wide: bool) -> void:
	_wide = wide
	var branches: Control = _panels["branches"]
	if _buttons.get_parent() != null:
		_buttons.get_parent().remove_child(_buttons)
	branches.get_parent().remove_child(branches)
	_buttons.vertical = wide
	_view_buttons["branches"].visible = not wide
	_changes_badge.visible = wide # would sit on top of the clipped title in a row
	for button: Button in _view_buttons.values():
		button.size_flags_horizontal = SIZE_FILL if wide else SIZE_EXPAND_FILL
		button.clip_text = not wide # four titles in a row would otherwise hold the side dock wider than it is
	if wide:
		_sidebar.add_child(_buttons)
		_sidebar.move_child(_buttons, 1)
		_sidebar.add_child(branches)
		branches.visible = true # a TabContainer hid it as a background tab
	else:
		_layout.add_child(_buttons)
		_layout.move_child(_buttons, 1)
		_views.add_child(branches)
	_sidebar.visible = wide
	show_view("changes" if wide and _view == "branches" else _view)


## Brings "changes", "history", "branches" or "console" to front.
func show_view(view: String) -> void:
	if _views == null or not view in VIEWS:
		return
	if view == "branches" and _wide:
		return # always visible in the sidebar
	_view = view
	_views.current_tab = _panels[view].get_index()
	_view_buttons[view].button_pressed = true
	Settings.set_value(VIEW_SETTING_KEY, view)


## Hands every panel back (see _init), restoring the parts it rearranged.
func detach_panels() -> Dictionary:
	if _panels.is_empty():
		return {}
	_panels["branches"].ref_selected.disconnect(_on_ref_selected)
	_panels["branches"].set_sidebar_mode(false)
	_panels["changes"].changes_counted.disconnect(_set_change_count)
	_sync_bar.set_actions_first(false)
	_panels["changes"].reattach_sync_bar()
	for panel: Control in _panels.values():
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
	var panels := _panels
	_panels = {}
	return panels


## Selecting a branch, tag or stash in the sidebar shows its commit in History, like SourceTree.
func _on_ref_selected(ref: String) -> void:
	if not _wide or _view != "history":
		return
	var oid: String = _panels["history"]._repo.resolve_commit(ref)
	if not oid.is_empty():
		_panels["history"].show_commit(oid)
