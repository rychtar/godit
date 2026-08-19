@tool
extends Control

## How many of the newest commits the log shows.
const LOG_LIMIT := 300

@onready var _graph_scroll: ScrollContainer = %GraphScroll
@onready var _graph: Control = %CommitGraph

## Set by git_tree_dock.gd; a git_cli_repo.gd instance.
var _repo: RefCounted
var _all_commits: Array = []


func _ready() -> void:
	_graph_scroll.get_v_scroll_bar().value_changed.connect(func(_v: float) -> void: _graph.queue_redraw())


func set_repo(repo: RefCounted) -> void:
	_repo = repo
	refresh()


func refresh() -> void:
	if _repo == null:
		return
	_all_commits = _repo.get_commit_graph(LOG_LIMIT)
	_graph.set_commits(_all_commits, _repo.get_head_oid())


func _on_refresh_button_pressed() -> void:
	refresh()
