@tool
extends Control

const RepoOpener := preload("res://addons/git_tree/util/repo_opener.gd")

## Set by plugin.gd right after instantiation.
var plugin: EditorPlugin

@onready var _message_label: Label = %MessageLabel

## A git_cli_repo.gd instance, or null if this project isn't a git repo.
var _repo: RefCounted


func _ready() -> void:
	var opened := RepoOpener.open_current_project_repo()
	if opened["repo"] == null:
		_message_label.text = opened["error"]
		return
	_repo = opened["repo"]
	_message_label.text = "Repository: %s" % _repo.get_repo_root()
