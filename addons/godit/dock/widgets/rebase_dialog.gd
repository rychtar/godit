@tool
## Interactive rebase of a commit and the ones after it, newest on top: each gets an action, Move Up/Down reorders them, and a reworded one takes its new message below.
extends ConfirmationDialog

const UiScale := preload("res://addons/godit/util/ui_scale.gd")

const ACTIONS := ["pick", "reword", "squash", "fixup", "drop"]

## Confirmed: [{"action", "oid", "message"}] oldest first, for GitCliRepo.interactive_rebase().
signal rebase_requested(steps: Array)

## Newest first: {"oid", "summary", "message", "action"}.
var _commits: Array = []
var _original_order: Array = []
var _tree: Tree
var _message: TextEdit
var _problem: Label


func _init(commits: Array, warning := "") -> void:
	title = "Interactive Rebase"
	ok_button_text = "Rebase"
	for c: Dictionary in commits:
		var commit := c.duplicate()
		commit["action"] = "pick"
		_commits.append(commit)
		_original_order.append(c["oid"])

	var box := VBoxContainer.new()
	add_child(box)
	var hint := Label.new()
	hint.text = "Newest on top. Squash and fixup fold a commit into the one below it (fixup drops its message). Reword takes the message below." + ("\n" + warning if not warning.is_empty() else "")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = UiScale.px(560)
	box.add_child(hint)

	var row := HBoxContainer.new()
	box.add_child(row)
	_tree = Tree.new()
	_tree.columns = 2
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, UiScale.px(100))
	_tree.custom_minimum_size = UiScale.size(560, 240)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.item_edited.connect(_on_item_edited)
	_tree.item_selected.connect(_show_message)
	row.add_child(_tree)
	var buttons := VBoxContainer.new()
	row.add_child(buttons)
	for delta in [-1, 1]:
		var move := Button.new()
		move.text = "Move Up" if delta == -1 else "Move Down"
		move.pressed.connect(_move.bind(delta))
		buttons.add_child(move)

	_message = TextEdit.new()
	_message.custom_minimum_size.y = UiScale.px(90)
	_message.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_message.placeholder_text = "Pick reword for a commit to change its message here."
	_message.text_changed.connect(func() -> void:
		var selected := _selected_index()
		if selected != -1 and _commits[selected]["action"] == "reword":
			_commits[selected]["message"] = _message.text
			_update_problem()
	)
	box.add_child(_message)

	_problem = Label.new()
	_problem.add_theme_color_override(&"font_color", Color(0.95, 0.6, 0.5))
	_problem.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_problem)

	confirmed.connect(func() -> void: rebase_requested.emit(steps()))
	_rebuild(0)


## The rows oldest first, as GitCliRepo.interactive_rebase() takes them.
func steps() -> Array:
	var out: Array = []
	for i in range(_commits.size() - 1, -1, -1):
		var c: Dictionary = _commits[i]
		out.append({ "action": c["action"], "oid": c["oid"], "message": c["message"] })
	return out


## Why Rebase can't run as set up, or "".
func problem() -> String:
	var oldest_kept := ""
	for step: Dictionary in steps():
		if step["action"] == "drop":
			continue
		oldest_kept = step["action"]
		break
	if oldest_kept in ["squash", "fixup"]:
		return "The lowest kept commit has nothing below it to fold into."
	if oldest_kept.is_empty():
		return "Every commit is dropped; use Reset Current Branch to Here on the commit below instead."
	var reworded_empty := _commits.any(func(c: Dictionary) -> bool: return c["action"] == "reword" and String(c["message"]).strip_edges().is_empty())
	if reworded_empty:
		return "A reworded commit needs a message."
	var unchanged := _commits.all(func(c: Dictionary) -> bool: return c["action"] == "pick") and _commits.map(func(c: Dictionary) -> String: return c["oid"]) == _original_order
	return "Nothing to change yet." if unchanged else ""


func _rebuild(select: int) -> void:
	_tree.clear()
	var root := _tree.create_item()
	for i in _commits.size():
		var c: Dictionary = _commits[i]
		var item := _tree.create_item(root)
		item.set_cell_mode(0, TreeItem.CELL_MODE_RANGE)
		item.set_text(0, ",".join(ACTIONS))
		item.set_range(0, ACTIONS.find(c["action"]))
		item.set_editable(0, true)
		item.set_text(1, "%s  %s" % [String(c["oid"]).substr(0, 7), c["summary"]])
		item.set_tooltip_text(1, c["message"])
		if c["action"] == "drop":
			item.set_custom_color(1, Color(1, 1, 1, 0.4))
		item.set_metadata(0, i)
	if select >= 0 and select < _commits.size():
		root.get_child(select).select(1)
	_update_problem()


func _selected_index() -> int:
	var item := _tree.get_selected()
	return item.get_metadata(0) if item != null else -1


func _on_item_edited() -> void:
	var item := _tree.get_edited()
	var index: int = item.get_metadata(0)
	_commits[index]["action"] = ACTIONS[int(item.get_range(0))]
	_rebuild(index)
	_show_message()


func _show_message() -> void:
	var index := _selected_index()
	if index == -1:
		return
	var c: Dictionary = _commits[index]
	_message.editable = c["action"] == "reword"
	_message.text = c["message"]


func _move(delta: int) -> void:
	var index := _selected_index()
	var target := index + delta
	if index == -1 or target < 0 or target >= _commits.size():
		return
	var moved: Dictionary = _commits[index]
	_commits[index] = _commits[target]
	_commits[target] = moved
	_rebuild(target)


func _update_problem() -> void:
	_problem.text = problem()
	get_ok_button().disabled = not _problem.text.is_empty()
