@tool
extends Control

const RepoOpener := preload("res://addons/godit/util/repo_opener.gd")
const GitConsole := preload("res://addons/godit/dock/widgets/git_console.gd")

@onready var _message_label: Label = %MessageLabel
@onready var _history_panel: Control = %HistoryPanel

## A git_cli_repo.gd instance, or null if this project isn't a git repo.
var _repo: RefCounted
var _tabs: TabContainer


func _ready() -> void:
	var opened := RepoOpener.open_current_project_repo()
	if opened["repo"] == null:
		_message_label.text = opened["error"]
		_message_label.visible = true
		_history_panel.visible = false
		return

	_repo = opened["repo"]
	_message_label.visible = false
	_history_panel.visible = true
	_history_panel.set_repo(_repo)
	_add_console_tab()


## Log and Console share the bottom panel as tabs — the console lists every git command the plugin ran and can run your own.
func _add_console_tab() -> void:
	var tabs := TabContainer.new()
	tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tabs)
	remove_child(_history_panel)
	_history_panel.name = "Log"
	tabs.add_child(_history_panel)
	var console := GitConsole.new()
	console.name = "Console"
	tabs.add_child(console)
	console.set_repo(_repo)
	_tabs = tabs


## Brings the Log tab to front with oid selected.
func show_commit(oid: String) -> void:
	if _repo == null:
		return
	if _tabs != null:
		_tabs.current_tab = _history_panel.get_index()
	_history_panel.show_commit(oid)


## Filters the log to one file and brings the Log tab to front (Changes panel → Show History).
func show_file_history(path: String) -> void:
	if _repo == null:
		return
	if _tabs != null:
		_tabs.current_tab = _history_panel.get_index()
	_history_panel.set_path_filter(path)
