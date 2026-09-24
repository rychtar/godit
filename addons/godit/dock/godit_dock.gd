@tool
extends Control

const RepoOpener := preload("res://addons/godit/util/repo_opener.gd")
const ChangesetDialog := preload("res://addons/godit/dock/widgets/changeset_dialog.gd")
const Settings := preload("res://addons/godit/util/settings.gd")

const AUTO_FETCH_SETTING_KEY := "auto_fetch"
const AUTO_FETCH_INTERVAL_SECS := 600.0

## Forwarded from the Changes panel; plugin.gd routes it to the Git Log panel. 
signal file_history_requested(path: String)

## Set by plugin.gd right after instantiation.
var plugin: EditorPlugin

@onready var _message_label: Label = %MessageLabel
@onready var _tab_container: TabContainer = %TabContainer
@onready var _changes_panel: Control = %Changes
@onready var _branches_panel: Control = %Branches

## A git_cli_repo.gd instance, or null if this project isn't a git repo.
var _repo: RefCounted
var _auto_fetch_timer: Timer


func _ready() -> void:
	var opened := RepoOpener.open_current_project_repo()
	if opened["repo"] == null:
		_show_message(opened["error"])
		return

	_repo = opened["repo"]
	_message_label.visible = false
	_tab_container.visible = true
	_changes_panel.set_repo(_repo)
	_branches_panel.set_repo(_repo)
	_changes_panel.file_history_requested.connect(func(path: String) -> void: file_history_requested.emit(path))
	_branches_panel.compare_requested.connect(func(title: String, base: String, target: String) -> void:
		# Parented to the panel, not this dock: in bottom-panel mode the dock itself isn't in the scene tree.
		var dialog := ChangesetDialog.new()
		_branches_panel.add_child(dialog)
		dialog.open(_repo, title, base, target)
	)

	_auto_fetch_timer = Timer.new()
	_auto_fetch_timer.wait_time = AUTO_FETCH_INTERVAL_SECS
	_auto_fetch_timer.timeout.connect(_on_auto_fetch_timeout)
	# On a panel, not this dock: in bottom-panel mode the dock is out of the tree and its timers wouldn't tick.
	_changes_panel.add_child(_auto_fetch_timer)
	apply_auto_fetch_setting()


## Called by plugin.gd when the Tools menu toggle changes.
func apply_auto_fetch_setting() -> void:
	if _auto_fetch_timer == null:
		return
	if Settings.get_value(AUTO_FETCH_SETTING_KEY, false):
		if _auto_fetch_timer.is_stopped():
			_auto_fetch_timer.start()
	else:
		_auto_fetch_timer.stop()


## Silent on failure (offline, no credentials): the manual Fetch button is where errors get explained.
func _on_auto_fetch_timeout() -> void:
	var r: Dictionary = await _repo.auto_fetch()
	if r.get("ok", false) and is_instance_valid(_changes_panel):
		_changes_panel.refresh()
		_branches_panel.refresh()


## Scrolls the Changes diff to path/line, e.g. from a click on the script editor's change gutter.
func reveal_change(path: String, line: int) -> void:
	if _changes_panel.get_parent() == _tab_container:
		_tab_container.current_tab = _changes_panel.get_index()
	_changes_panel.reveal(path, line)


func _show_message(text: String) -> void:
	_message_label.text = text
	_message_label.visible = true
	_tab_container.visible = false


## Pulls Changes and Branches out of the tab bar together, so plugin.gd can dock both at the bottom instead.
func detach_panels() -> Dictionary:
	_tab_container.remove_child(_changes_panel)
	_tab_container.remove_child(_branches_panel)
	return {"changes": _changes_panel, "branches": _branches_panel}


## Reverses detach_panels() when the toggle is switched back off.
func reattach_panels(panels: Dictionary) -> void:
	_changes_panel = panels["changes"]
	_branches_panel = panels["branches"]
	_tab_container.add_child(_changes_panel)
	_tab_container.add_child(_branches_panel)
