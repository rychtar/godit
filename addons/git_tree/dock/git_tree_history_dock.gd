@tool
extends Control

const RepoOpener := preload("res://addons/git_tree/util/repo_opener.gd")

@onready var _message_label: Label = %MessageLabel
@onready var _history_panel: Control = %HistoryPanel

## A git_cli_repo.gd instance, or null if this project isn't a git repo.
var _repo: RefCounted


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
