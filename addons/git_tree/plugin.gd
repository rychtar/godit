@tool
extends EditorPlugin

const GitTreeDockScene := preload("res://addons/git_tree/dock/git_tree_dock.tscn")
const GitCli := preload("res://addons/git_tree/util/git_cli.gd")

## Changes: left dock, alongside FileSystem/Import.
var dock_instance: Control


func _enter_tree() -> void:
	GitCli.prepare_environment()

	dock_instance = GitTreeDockScene.instantiate()
	dock_instance.plugin = self
	dock_instance.name = "Git" # dock tab label; scene root is named GitTreeDock in code
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, dock_instance)


func _exit_tree() -> void:
	remove_control_from_docks(dock_instance)
	dock_instance.free()

	GitCli.restore_environment()
