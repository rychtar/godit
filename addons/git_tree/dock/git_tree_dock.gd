@tool
extends Control

const RepoOpener := preload("res://addons/git_tree/util/repo_opener.gd")

## Set by plugin.gd right after instantiation.
var plugin: EditorPlugin

@onready var _message_label: Label = %MessageLabel
@onready var _tab_container: TabContainer = %TabContainer
@onready var _changes_panel: Control = %Changes

## A git_cli_repo.gd instance, or null if this project isn't a git repo.
var _repo: RefCounted


func _ready() -> void:
	var opened := RepoOpener.open_current_project_repo()
	if opened["repo"] == null:
		_show_message(opened["error"])
		return

	_repo = opened["repo"]
	_message_label.visible = false
	_tab_container.visible = true
	_changes_panel.set_repo(_repo)


func _show_message(text: String) -> void:
	_message_label.text = text
	_message_label.visible = true
	_tab_container.visible = false
