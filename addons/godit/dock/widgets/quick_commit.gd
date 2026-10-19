## Commit from anywhere ("Godit: Commit…" or its shortcut), with the dock closed: the changed files with a checkbox each (checked = staged, as in Changes), the message and Amend, then Commit or Commit and Push. It drives the Changes panel, so the message draft and the checks before committing (unsaved, large and missing files) are the same.
@tool
extends ConfirmationDialog

const GitStatusFlags := preload("res://addons/godit/util/git_status_flags.gd")
const GitIcons := preload("res://addons/godit/util/git_icons.gd")
const ChangelistStore := preload("res://addons/godit/util/changelist_store.gd")
const UiScale := preload("res://addons/godit/util/ui_scale.gd")

const PUSH_ACTION := &"godit_commit_push"

## changes_panel.gd, which commits.
var _panel: Control
var _summary: Label
var _tree: Tree
var _message: TextEdit
var _amend: CheckBox
var _push_button: Button


func _init(panel: Control) -> void:
	_panel = panel
	title = "Commit"
	ok_button_text = "Commit"
	dialog_hide_on_ok = false # stays open when a check before committing cancels it
	auto_translate_mode = AUTO_TRANSLATE_MODE_DISABLED # English throughout, see godit_dock.gd
	_push_button = add_button("Commit and Push", true, PUSH_ACTION)
	custom_action.connect(func(action: StringName) -> void:
		if action == PUSH_ACTION:
			_commit(true)
	)
	confirmed.connect(_commit.bind(false))

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", int(UiScale.px(6)))
	add_child(layout)
	_summary = Label.new()
	_summary.modulate.a = 0.7
	layout.add_child(_summary)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size.y = UiScale.px(160)
	_tree.item_edited.connect(_on_item_edited)
	layout.add_child(_tree)
	_message = TextEdit.new()
	_message.placeholder_text = "Commit message (Ctrl/Cmd+Enter commits, with Shift also pushes)"
	_message.custom_minimum_size.y = UiScale.px(90)
	_message.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_message.text_changed.connect(func() -> void:
		_panel._commit_message.text = _message.text # one draft, also when the dock is opened later
		_update_buttons()
	)
	_message.gui_input.connect(_on_message_gui_input)
	layout.add_child(_message)
	_amend = CheckBox.new()
	_amend.text = "Amend the last commit"
	_amend.toggled.connect(func(on: bool) -> void:
		_panel._amend_check.button_pressed = on # the panel puts the last commit's message in, or takes it out
		_message.text = _panel._commit_message.text
		_update_buttons()
	)
	layout.add_child(_amend)


## Opens with the panel's message and the current changes.
func open() -> void:
	_message.text = _panel._commit_message.text
	_amend.set_pressed_no_signal(_panel._amend_check.button_pressed)
	_fill()
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	popup_centered(Vector2i(mini(int(UiScale.px(620)), int(screen.x * 0.8)), mini(int(UiScale.px(520)), int(screen.y * 0.8))))
	_message.grab_focus()
	_message.set_caret_line(_message.get_line_count() - 1)
	_message.set_caret_column(_message.get_line(_message.get_line_count() - 1).length())


## Every change but ignored files and the .uid/.import sidecars that go with their file.
func _fill() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var repo: RefCounted = _panel._repo
	var staged := 0
	var shown := 0
	for entry: Dictionary in repo.get_status():
		var path: String = entry["path"]
		var status: int = entry["status"]
		if status & GitStatusFlags.IGNORED or _panel._nests_under_owner(path):
			continue
		var item := _tree.create_item(root)
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_text(0, "%s  %s" % [GitIcons.status_letter(status), path])
		item.set_custom_color(0, GitIcons.status_color(status))
		item.set_metadata(0, path)
		var conflicted := status & GitStatusFlags.CONFLICTED != 0
		item.set_editable(0, not conflicted)
		var is_staged := GitStatusFlags.is_staged(status)
		item.set_checked(0, is_staged and not GitStatusFlags.is_unstaged(status))
		item.set_indeterminate(0, is_staged and GitStatusFlags.is_unstaged(status) and not GitStatusFlags.is_untracked(status))
		var changelist: String = _panel._changelist_for_path(path)
		if conflicted:
			item.set_suffix(0, "conflict: resolve it in Changes")
		elif changelist != ChangelistStore.DEFAULT_NAME:
			item.set_suffix(0, changelist)
		shown += 1
		if is_staged:
			staged += 1
	var branch: String = repo.get_current_branch()
	_summary.text = "%s  ·  %d of %d changed file%s staged" % [branch if not branch.is_empty() else "detached HEAD", staged, shown, "" if shown == 1 else "s"]
	title = "Commit to %s" % branch if not branch.is_empty() else "Commit"
	_update_buttons(staged > 0)


func _on_item_edited() -> void:
	var item := _tree.get_edited()
	if item != null:
		set_staged.call_deferred(item.get_metadata(0), item.is_checked(0)) # not while the Tree is still handling the click


## A checkbox: stages or unstages the file with its sidecars, through the panel.
func set_staged(path: String, staged: bool) -> void:
	_panel._set_staged([path], staged)
	_panel.refresh()
	_fill()


func _update_buttons(any_staged: Variant = null) -> void:
	if any_staged == null:
		any_staged = _panel._repo.get_status().any(func(e: Dictionary) -> bool: return GitStatusFlags.is_staged(e["status"]))
	var can_commit: bool = not _message.text.strip_edges().is_empty() and (any_staged or _amend.button_pressed)
	get_ok_button().disabled = not can_commit
	_push_button.disabled = not can_commit


func _on_message_gui_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode in [KEY_ENTER, KEY_KP_ENTER] and (key.ctrl_pressed or key.meta_pressed):
		_message.accept_event()
		if not get_ok_button().disabled:
			_commit(key.shift_pressed)


func _commit(push_after: bool) -> void:
	_panel._commit_message.text = _message.text
	var branch: String = _panel._repo.get_current_branch()
	if await _panel._do_commit(push_after):
		hide()
		EditorInterface.get_editor_toaster().push_toast("Godit: committed to %s%s." % [branch, ", pushing" if push_after else ""])
	else:
		_fill()
