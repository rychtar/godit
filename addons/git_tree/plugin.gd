@tool
extends EditorPlugin

const GitTreeDockScene := preload("res://addons/git_tree/dock/git_tree_dock.tscn")
const GitTreeHistoryDockScene := preload("res://addons/git_tree/dock/git_tree_history_dock.tscn")
const GitCli := preload("res://addons/git_tree/util/git_cli.gd")

## Changes + Branches: left dock, alongside FileSystem/Import.
var dock_instance: Control
## History (commit graph): bottom panel by default, like Output/Debugger
## reads better full-width than squeezed into a side dock. Just the
## starting position; the user can drag it anywhere.
var history_dock_instance: Control

## Same floor the Shader Editor uses, so the bottom panels can't be dragged down to an unusable sliver (they can still be hidden entirely).
const BOTTOM_PANEL_MIN_HEIGHT := 300


func _enter_tree() -> void:
	GitCli.prepare_environment()

	dock_instance = GitTreeDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GitTreeDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)

	history_dock_instance = GitTreeHistoryDockScene.instantiate()
	history_dock_instance.custom_minimum_size.y = BOTTOM_PANEL_MIN_HEIGHT
	add_control_to_bottom_panel(history_dock_instance, "Git Log")


func _exit_tree() -> void:
	remove_control_from_docks(dock_instance)
	dock_instance.free()

	remove_control_from_bottom_panel(history_dock_instance)
	history_dock_instance.free()

	GitCli.restore_environment()
