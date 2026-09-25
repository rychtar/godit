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

var _panels: Dictionary = {}
var _layout: VBoxContainer
var _sidebar: VBoxContainer
var _buttons: BoxContainer
var _views: TabContainer
var _view_buttons := {}
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
	_layout.add_child(panels["changes"].detach_sync_bar())
	panels["branches"].set_sync_row_visible(false)
	panels["branches"].ref_selected.connect(_on_ref_selected)

	var split := HSplitContainer.new()
	split.size_flags_vertical = SIZE_EXPAND_FILL
	_layout.add_child(split)
	_sidebar = VBoxContainer.new()
	_sidebar.custom_minimum_size.x = UiScale.px(SIDEBAR_WIDTH)
	split.add_child(_sidebar)
	_views = TabContainer.new()
	_views.tabs_visible = false
	_views.size_flags_horizontal = SIZE_EXPAND_FILL
	split.add_child(_views)

	_buttons = BoxContainer.new()
	var group := ButtonGroup.new()
	for view: String in VIEWS:
		var button := Button.new()
		button.text = VIEW_TITLES[view]
		button.toggle_mode = true
		button.button_group = group
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(show_view.bind(view))
		_buttons.add_child(button)
		_view_buttons[view] = button
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		for view: String in _view_buttons:
			if has_theme_icon(VIEW_ICONS[view], &"EditorIcons"):
				_view_buttons[view].icon = get_theme_icon(VIEW_ICONS[view], &"EditorIcons")


## Wide: buttons and Branches in a sidebar left of the views. Narrow: buttons in a row above, Branches a view like the rest.
func _set_wide(wide: bool) -> void:
	_wide = wide
	var branches: Control = _panels["branches"]
	if _buttons.get_parent() != null:
		_buttons.get_parent().remove_child(_buttons)
	branches.get_parent().remove_child(branches)
	_buttons.vertical = wide
	_view_buttons["branches"].visible = not wide
	for button: Button in _view_buttons.values():
		button.size_flags_horizontal = SIZE_FILL if wide else SIZE_EXPAND_FILL
		button.clip_text = not wide # four titles in a row would otherwise hold the side dock wider than it is
		button.tooltip_text = "" if wide else button.text
	if wide:
		_sidebar.add_child(_buttons)
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
	_panels["branches"].set_sync_row_visible(true)
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
