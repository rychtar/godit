## No class_name: internal helper, addressed via preload (this project
## keeps its scripts out of the global namespace).
extends RefCounted

const GitCliRepo := preload("res://addons/git_tree/util/git_cli_repo.gd")

## Opens a git repo backend for the current editor project. Returns
## {"repo": RefCounted or null, "error": String}, error ready to show
## directly in a dock. Both docks call this separately and open their own
## repo instance — opening is cheap.
static func open_current_project_repo() -> Dictionary:
	var repo := GitCliRepo.new()
	if not repo.open(ProjectSettings.globalize_path("res://")):
		return {
			"repo": null,
			"error": "Git Tree: this project isn't inside a git repository, or the `git` command isn't on PATH.",
		}

	return { "repo": repo, "error": "" }
