## Godit Settings (Tools > Godit, the docks' ⋮ menus, the Command Palette): the sections listed on the left like Godot's Editor Settings, the chosen one's options on the right with a line on what each does and Reset; the filter narrows both. Changes apply right away; where each one is kept is settings.gd's business.
@tool
extends AcceptDialog

const Settings := preload("res://addons/godit/util/settings.gd")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")
const ChangesPanel := preload("res://addons/godit/dock/panels/changes_panel.gd")
const CommitGraph := preload("res://addons/godit/dock/widgets/commit_graph.gd")
const GoditDock := preload("res://addons/godit/dock/godit_dock.gd")
const SplitMemory := preload("res://addons/godit/util/split_memory.gd")

const SECTIONS := ["Layout", "Changes", "Diff", "History", "Editor", "Sync"]
const HELP_INDENT := 26
const SIDEBAR_WIDTH := 170

## Set by plugin.gd before the window enters the tree: [layout, title] pairs and the default one, how to read and switch the layout, and the repository's fast status ({"on", "available"} and a setter).
var layouts: Array = []
var default_layout := ""
var get_layout: Callable
var set_layout: Callable
var get_fast_status: Callable
var set_fast_status: Callable
var _filter: LineEdit
## The sections on the left; only those with a setting matching the filter.
var _sidebar: Tree
var _scroll: ScrollContainer
var _no_match: Label
## Section -> {"box": its page, "rows": [row Controls]}; one page is visible at a time.
var _sections := {}
var _selected := ""
## Each entry (see _entries()) with "row" and "control" added once built.
var _built: Array = []
var _masks_edit: TextEdit


func _init() -> void:
	title = "Godit Settings"
	ok_button_text = "Close"
	min_size = UiScale.size_i(480, 360)
	auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd


func _ready() -> void:
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", int(UiScale.px(8)))
	add_child(layout)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter settings"
	_filter.clear_button_enabled = true
	_filter.right_icon = get_theme_icon(&"Search", &"EditorIcons")
	_filter.text_changed.connect(func(_t: String) -> void: _apply_filter())
	layout.add_child(_filter)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(split)
	_sidebar = Tree.new()
	_sidebar.hide_root = true
	_sidebar.custom_minimum_size.x = UiScale.px(SIDEBAR_WIDTH)
	_sidebar.item_selected.connect(func() -> void:
		var section: String = _sidebar.get_selected().get_metadata(0)
		if section != _selected:
			show_section(section)
	)
	split.add_child(_sidebar)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(_scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", int(UiScale.px(10)))
	margin.add_theme_constant_override("margin_right", int(UiScale.px(6)))
	_scroll.add_child(margin)
	var pages := VBoxContainer.new()
	margin.add_child(pages)
	for section: String in SECTIONS:
		pages.add_child(_section_box(section))
	_no_match = Label.new()
	_no_match.text = "No setting matches the filter."
	_no_match.modulate.a = 0.65
	_no_match.visible = false
	pages.add_child(_no_match)
	SplitMemory.keep_offset(split, "settings_sidebar")
	var hint := Label.new()
	hint.text = "Changes apply right away and are kept for all your projects, except where a setting says otherwise."
	hint.tooltip_text = hint.text
	hint.mouse_filter = Control.MOUSE_FILTER_PASS
	hint.clip_text = true # not wrapped: a wrapping label here would size the window to its height at no width
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint.modulate.a = 0.65
	layout.add_child(hint)
	for entry: Dictionary in _entries():
		_add_row(entry)
	_apply_filter()
	refresh()
	Settings.notifier().changed.connect(func(_key: String) -> void: refresh())
	about_to_popup.connect(refresh)
	visibility_changed.connect(func() -> void:
		if not visible:
			_commit_masks()
	)


## Opens centered, as large as fits.
func open() -> void:
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	popup_centered(Vector2i(mini(int(UiScale.px(860)), int(screen.x * 0.8)), mini(int(UiScale.px(620)), int(screen.y * 0.85))))
	_filter.grab_focus()


## The settings shown, in order. kind: "bool", "choice" ("choices": [[value, title]…]), "flags" (an Array of "choices" values), "masks"; "amount" adds a number after a bool; "get"/"set" replace Settings for values kept elsewhere; "reset_keys" are reset with the section too.
func _entries() -> Array:
	return [
		{ "section": "Layout", "key": "dock_layout", "kind": "choice", "label": "Panels", "choices": layouts,
			"get": get_layout, "set": set_layout,
			"help": "Where Changes, History, Branches and Console live. The Combined Dock can float on Godot 4.6+, e.g. on a second monitor." },
		{ "section": "Layout", "key": "diff_main_screen", "kind": "bool", "default": false, "label": "Godit tab next to 2D, 3D and Script",
			"help": "Full-size diffs: the expand button in a diff opens it there, and while the tab is open a file clicked in Changes or Git Log shows there. Turning it on or off reloads Godit." },

		{ "section": "Changes", "key": ChangesPanel.AUTO_STAGE_SETTING_KEY, "kind": "bool", "default": true, "label": "Auto-stage changes in the active changelist",
			"help": "A file that starts changing is checked for the next commit right away." },
		{ "section": "Changes", "key": ChangesPanel.AUTO_ADD_SETTING_KEY, "kind": "bool", "default": true, "label": "Auto-add new files to Git",
			"help": "New files join the active changelist unless they match an ignore mask below." },
		{ "section": "Changes", "key": ChangesPanel.AUTO_ADD_MASKS_SETTING_KEY, "kind": "masks", "default": ChangesPanel.DEFAULT_AUTO_ADD_MASKS, "label": "Auto-add ignore masks",
			"help": "One glob per line: *.psd matches file names, build/ a folder, addons/*.tmp a path. Kept in project.godot, so the whole team shares them." },
		{ "section": "Changes", "key": ChangesPanel.CONFIRM_SHORTCUT_COMMIT_SETTING_KEY, "kind": "bool", "default": true, "label": "Confirm Ctrl/Cmd+Enter commits",
			"help": "Ask before the shortcut in the commit message commits." },

		{ "section": "Diff", "key": "diff_side_by_side", "kind": "bool", "default": false, "label": "Side by side",
			"help": "Old and new lines next to each other instead of in one column." },
		{ "section": "Diff", "key": "diff_ignore_whitespace", "kind": "bool", "default": false, "label": "Ignore whitespace",
			"help": "Changes to indentation and spacing alone aren't shown." },
		{ "section": "Diff", "key": "diff_syntax", "kind": "bool", "default": true, "label": "Syntax highlighting",
			"help": "Code in diffs is colored like in the script editor." },
		{ "section": "Diff", "key": "diff_hide_noise", "kind": "bool", "default": true, "label": "Dim Godot noise (uid / load_steps)",
			"help": "Lines Godot rewrites by itself in scenes and resources are grayed out." },
		{ "section": "Diff", "key": "diff_context", "kind": "choice", "default": 3, "label": "Context",
			"choices": [[3, "3 lines"], [10, "10 lines"], [25, "25 lines"], [-1, "Whole file"]],
			"help": "Unchanged lines shown around each change." },
		{ "section": "Diff", "key": "diff_scene_view", "kind": "bool", "default": true, "label": "Scenes and settings files node by node",
			"help": "Scenes, resources and project.godot list their changed nodes and properties; the Scene button in a diff switches to text." },
		{ "section": "Diff", "key": "diff_image_mode", "kind": "choice", "default": "side", "label": "Images",
			"choices": [["side", "Side by Side"], ["swipe", "Swipe"], ["onion", "Onion Skin"]],
			"help": "How a changed image is compared with the previous version." },

		{ "section": "History", "key": CommitGraph.VISIBLE_COLUMNS_SETTING_KEY, "kind": "flags", "default": CommitGraph.COLUMNS, "label": "Columns",
			"choices": CommitGraph.COLUMNS.map(func(c: String) -> Array: return [c, CommitGraph.COLUMN_TITLES[c]]),
			"reset_keys": CommitGraph.COLUMNS.map(func(c: String) -> String: return "history_%s_col_width" % c),
			"help": "Shown right of the commit message in Git Log; drag their edges there to resize them." },
		{ "section": "History", "key": CommitGraph.ABSOLUTE_DATES_SETTING_KEY, "kind": "bool", "default": false, "label": "Absolute dates",
			"help": "2026-10-19 14:05 instead of \"3 hours ago\"." },

		{ "section": "Editor", "key": "show_blame", "kind": "bool", "default": false, "label": "Show blame in the script editor",
			"help": "Author and age of each line next to the line numbers; click one to see its commit." },
		{ "section": "Editor", "key": "toolbar_branch", "kind": "bool", "default": true, "label": "Current branch in the editor's toolbar",
			"help": "With the commits to push (↑) and pull (↓); click it for a list of branches to switch to. \"Godit: Switch Branch…\" in the Command Palette opens the same list." },
		{ "section": "Editor", "key": "inspector_changes", "kind": "bool", "default": true, "label": "Changes since the last commit in the Inspector and Scene dock",
			"help": "A \"Last commit\" row with Revert under changed properties, and added or changed nodes colored." },

		{ "section": "Sync", "key": GoditDock.AUTO_FETCH_SETTING_KEY, "kind": "bool", "default": false, "label": "Fetch remotes in the background every",
			"amount": { "key": GoditDock.AUTO_FETCH_MINUTES_KEY, "default": GoditDock.AUTO_FETCH_DEFAULT_MINUTES, "min": 1, "max": 240, "suffix": "min" },
			"help": "New commits show up in Git Log and the sync bar, and a toast says when they arrive; pulling stays up to you." },
		{ "section": "Sync", "key": "reminders", "kind": "bool", "default": true, "label": "Remind me of work that isn't committed or pushed after",
			"amount": { "key": "reminder_hours", "default": 2, "min": 1, "max": 48, "suffix": "h" },
			"help": "A toast when changed files stay uncommitted, or commits stay only on this computer, this long; again after as long if they still do." },
		{ "section": "Sync", "key": "auto_save_scripts", "kind": "bool", "default": false, "label": "Auto-save scripts every",
			"amount": { "key": "auto_save_seconds", "default": 3, "min": 1, "max": 600, "suffix": "s" },
			"help": "Sets the editor's own autosave interval while on, and gives yours back when turned off." },
		{ "section": "Sync", "key": "auto_reload_external_changes", "kind": "bool", "default": true, "label": "Auto-reload files changed outside the editor",
			"help": "Open scripts that git changed on disk reload without the editor asking first." },
		{ "section": "Sync", "key": "save_before_git", "kind": "bool", "default": false, "label": "Save open files before git operations without asking",
			"help": "Otherwise Godit asks when a pull, checkout or other operation would leave unsaved edits behind." },
		{ "section": "Sync", "key": "", "kind": "bool", "label": "Faster git status for large projects (file system monitor)",
			"get": func() -> Variant: return get_fast_status.call()["on"], "set": set_fast_status,
			"enabled": func() -> bool: return get_fast_status.call()["available"],
			"help": "Git's fsmonitor daemon and untracked cache: git status asks what changed instead of scanning every file. Set in this repository's git config, not reset with the section." },
	]


func _section_box(section: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(UiScale.px(6)))
	var header := HBoxContainer.new()
	var title_label := Label.new()
	title_label.text = section
	title_label.theme_type_variation = &"HeaderSmall"
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_label)
	var reset := Button.new()
	reset.text = "Reset"
	reset.flat = true
	reset.tooltip_text = "Put the %s settings back to their defaults" % section
	reset.pressed.connect(reset_section.bind(section))
	header.add_child(reset)
	box.add_child(header)
	box.add_child(HSeparator.new())
	_sections[section] = {"box": box, "rows": []}
	return box


func _add_row(entry: Dictionary) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", int(UiScale.px(2)))
	var line := HBoxContainer.new()
	row.add_child(line)
	var control: Control
	match entry["kind"]:
		"bool":
			var check := CheckBox.new()
			check.text = entry["label"]
			check.toggled.connect(func(on: bool) -> void: _store(entry, on))
			control = check
			line.add_child(check)
			if entry.has("amount"):
				var spin := _amount_spin(entry["amount"])
				line.add_child(spin)
				entry["spin"] = spin
		"choice":
			line.add_child(_label(entry["label"]))
			var option := OptionButton.new()
			for choice: Array in entry["choices"]:
				option.add_item(choice[1])
			option.item_selected.connect(func(i: int) -> void: _store(entry, entry["choices"][i][0]))
			control = option
			line.add_child(option)
		"flags":
			line.add_child(_label(entry["label"]))
			var checks := {}
			for choice: Array in entry["choices"]:
				var check := CheckBox.new()
				check.text = choice[1]
				check.toggled.connect(func(_on: bool) -> void:
					_store(entry, entry["choices"].map(func(c: Array) -> Variant: return c[0]).filter(func(v: Variant) -> bool: return checks[v].button_pressed))
				)
				checks[choice[0]] = check
				line.add_child(check)
			entry["checks"] = checks
			control = line
		"masks":
			line.add_child(_label(entry["label"]))
			_masks_edit = TextEdit.new()
			_masks_edit.custom_minimum_size.y = UiScale.px(110)
			_masks_edit.focus_exited.connect(_commit_masks)
			control = _masks_edit
			row.add_child(_masks_edit)
	var help := Label.new()
	help.text = entry["help"]
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate.a = 0.65
	var indent := MarginContainer.new()
	indent.add_theme_constant_override("margin_left", int(UiScale.px(HELP_INDENT)) if entry["kind"] == "bool" else 0)
	indent.add_child(help)
	row.add_child(indent)
	entry["row"] = row
	entry["control"] = control
	_built.append(entry)
	_sections[entry["section"]]["rows"].append(row)
	_sections[entry["section"]]["box"].add_child(row)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = UiScale.px(120)
	return label


func _amount_spin(amount: Dictionary) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = amount["min"]
	spin.max_value = amount["max"]
	spin.suffix = amount["suffix"]
	spin.value_changed.connect(func(v: float) -> void: Settings.set_value(amount["key"], int(v)))
	return spin


func _value(entry: Dictionary) -> Variant:
	if entry.has("get"):
		return entry["get"].call()
	return Settings.get_value(entry["key"], entry["default"])


func _store(entry: Dictionary, value: Variant) -> void:
	if entry.has("set"):
		entry["set"].call(value)
	else:
		Settings.set_value(entry["key"], value)


## Every control shows the stored value, also after a change made elsewhere (a diff's ⚙ menu, the Tools menu).
func refresh() -> void:
	for entry: Dictionary in _built:
		var value: Variant = _value(entry)
		match entry["kind"]:
			"bool":
				(entry["control"] as CheckBox).set_pressed_no_signal(bool(value))
				(entry["control"] as CheckBox).disabled = entry.has("enabled") and not entry["enabled"].call()
				if entry.has("spin"):
					(entry["spin"] as SpinBox).set_value_no_signal(Settings.get_value(entry["amount"]["key"], entry["amount"]["default"]))
			"choice":
				var option := entry["control"] as OptionButton
				var index: int = entry["choices"].map(func(c: Array) -> Variant: return c[0]).find(value)
				option.select(index)
			"flags":
				for v: Variant in entry["checks"]:
					(entry["checks"][v] as CheckBox).set_pressed_no_signal((value as Array).has(v))
			"masks":
				if not _masks_edit.has_focus():
					_masks_edit.text = "\n".join(value)


func _commit_masks() -> void:
	if _masks_edit == null:
		return
	var cleaned: Array = []
	for line in _masks_edit.text.split("\n"):
		if not line.strip_edges().is_empty():
			cleaned.append(line.strip_edges())
	if cleaned != Settings.get_value(ChangesPanel.AUTO_ADD_MASKS_SETTING_KEY, ChangesPanel.DEFAULT_AUTO_ADD_MASKS):
		Settings.set_value(ChangesPanel.AUTO_ADD_MASKS_SETTING_KEY, cleaned)


## Defaults for the section's settings (and the numbers and widths that go with them); the repository's fast status stays.
func reset_section(section: String) -> void:
	for entry: Dictionary in _built:
		if entry["section"] != section or String(entry["key"]).is_empty():
			continue
		if entry["key"] == "dock_layout":
			set_layout.call(default_layout)
			continue
		if _masks_edit != null and entry["kind"] == "masks":
			_masks_edit.release_focus()
		Settings.reset(entry["key"])
		if entry.has("amount"):
			Settings.reset(entry["amount"]["key"])
		for key: String in entry.get("reset_keys", []):
			Settings.reset(key)


## Shows a section's page and selects it on the left.
func show_section(section: String) -> void:
	_selected = section
	for other: String in _sections:
		(_sections[other]["box"] as Control).visible = other == section
	_scroll.scroll_vertical = 0
	var item := _sidebar.get_root().get_first_child() if _sidebar.get_root() != null else null
	while item != null:
		if item.get_metadata(0) == section and not item.is_selected(0):
			item.select(0)
		item = item.get_next()


## The sections listed on the left right now.
func listed_sections() -> Array:
	var out: Array = []
	var item := _sidebar.get_root().get_first_child() if _sidebar.get_root() != null else null
	while item != null:
		out.append(item.get_metadata(0))
		item = item.get_next()
	return out


## Lists only the sections with a setting whose label or help contains the filter, and hides the other rows.
func _apply_filter() -> void:
	var query := _filter.text.strip_edges().to_lower()
	var matching := {}
	for entry: Dictionary in _built:
		var shown: bool = query.is_empty() or (entry["section"] + " " + entry["label"] + " " + entry["help"]).to_lower().contains(query)
		(entry["row"] as Control).visible = shown
		if shown:
			matching[entry["section"]] = true
	var listed := SECTIONS.filter(func(section: String) -> bool: return matching.has(section))
	_sidebar.clear()
	var root := _sidebar.create_item()
	for section: String in listed:
		var item := _sidebar.create_item(root)
		item.set_text(0, section)
		item.set_metadata(0, section)
	_no_match.visible = listed.is_empty()
	if listed.is_empty():
		for other: String in _sections:
			(_sections[other]["box"] as Control).visible = false
	else:
		show_section(_selected if listed.has(_selected) else listed[0])
