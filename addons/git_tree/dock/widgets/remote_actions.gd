## Fetch/Pull/Push flows shared by the Changes and Branches panels: runs the operation in the background, with an OperationBar showing progress and Cancel, and reports failures. Every function is a coroutine returning whether it succeeded. No class_name: internal helper, addressed via preload.
extends RefCounted

const Dialogs := preload("res://addons/git_tree/dock/widgets/dialogs.gd")
const EditorOpen := preload("res://addons/git_tree/util/editor_open.gd")


static func fetch(parent: Control, repo: RefCounted, bar: Control, remote: String = "", prune: bool = false) -> bool:
	if not _check_idle(parent, repo):
		return false
	bar.busy("Fetching %s…" % (remote if not remote.is_empty() else "all remotes"), repo)
	var r: Dictionary = await repo.fetch(remote, prune)
	if r["ok"]:
		bar.done("Fetched.")
		return true
	bar.done("Fetch cancelled." if r["cancelled"] else "Fetch failed.", not r["cancelled"])
	if not r["cancelled"]:
		await Dialogs.error(parent, "Fetch failed", r["error"])
	return false


static func pull(parent: Control, repo: RefCounted, bar: Control, strategy: String = "", autostash: bool = false) -> bool:
	if not _check_idle(parent, repo):
		return false
	bar.busy("Pulling…", repo)
	var r: Dictionary = await repo.pull(strategy, autostash)
	EditorOpen.refresh_all_external_changes()
	if r["ok"]:
		bar.done("Pulled." if not r["output"].contains("Already up to date") else "Already up to date.")
		return true
	if r["cancelled"]:
		bar.done("Pull cancelled.")
		return false
	bar.done("Pull failed.", true)
	await Dialogs.error(parent, "Pull failed", r["error"])
	return false


## options: see GitCliRepo.push().
static func push(parent: Control, repo: RefCounted, bar: Control, options: Dictionary = {}) -> bool:
	if not _check_idle(parent, repo):
		return false
	bar.busy("Pushing…", repo)
	var r: Dictionary = await repo.push(options)
	if r["ok"]:
		bar.done("Pushed." if not r["output"].contains("Everything up-to-date") else "Everything up to date.")
		return true
	if r["cancelled"]:
		bar.done("Push cancelled.")
		return false
	bar.done("Push failed.", true)
	await Dialogs.error(parent, "Push failed", r["error"])
	return false


## "origin" if it exists, otherwise the first configured remote, or "".
static func default_remote(repo: RefCounted) -> String:
	var remotes: Array = repo.list_remotes()
	for remote in remotes:
		if remote["name"] == "origin":
			return "origin"
	return remotes[0]["name"] if not remotes.is_empty() else ""


static func _check_idle(parent: Control, repo: RefCounted) -> bool:
	if repo.is_busy():
		Dialogs.error(parent, "Busy", "Another git operation is still running — wait for it or cancel it first.")
		return false
	return true
