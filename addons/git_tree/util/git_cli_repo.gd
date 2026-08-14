## Runs every git operation by shelling out to the system `git` binary (see
## util/git_cli.gd) — no native extension, works anywhere `git` is on PATH.
## No class_name: internal helper, addressed via preload, so the addon
## doesn't add names to the project's global namespace.
extends RefCounted

const GitCli := preload("res://addons/git_tree/util/git_cli.gd")

var _repo_root: String = ""


func open(path: String) -> bool:
	var result := GitCli.run(path, ["rev-parse", "--show-toplevel"])
	if result["exit_code"] != 0:
		return false
	var root: String = result["text"].strip_edges()
	if root.is_empty():
		return false
	_repo_root = root
	return true


func is_valid() -> bool:
	return not _repo_root.is_empty()


func get_repo_root() -> String:
	return _repo_root
