## Fetch/Pull/Push flows shared by the Changes and Branches panels: runs the operation in the background (with an OperationBar showing progress and Cancel), then turns the usual failures into a question with the obvious fix — set upstream, pull first, force-with-lease, merge vs rebase, autostash. Every function is a coroutine returning whether it succeeded. No class_name: internal helper, addressed via preload.
extends RefCounted

const Dialogs := preload("res://addons/godit/dock/widgets/dialogs.gd")
const SaveGuard := preload("res://addons/godit/dock/widgets/save_guard.gd")
const GitErrors := preload("res://addons/godit/util/git_errors.gd")
const EditorOpen := preload("res://addons/godit/util/editor_open.gd")

## Set by plugin.gd: opens the setup check, offered when a remote refuses the login.
static var open_setup_check: Callable


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
		await _report(parent, "Fetch failed", r["error"])
	return false


static func pull(parent: Control, repo: RefCounted, bar: Control, strategy: String = "", autostash: bool = false) -> bool:
	if not _check_idle(parent, repo) or not await SaveGuard.ensure_saved(parent, "Pull"):
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

	match GitErrors.classify(r["error"]):
		GitErrors.DIVERGED:
			var choice := await Dialogs.error_with_actions(parent, "Pull needs a strategy", GitErrors.explain(r["error"]),
					{ "merge": "Pull (Merge)", "rebase": "Pull (Rebase)" })
			if not choice.is_empty():
				return await pull(parent, repo, bar, choice, autostash)
		GitErrors.DIRTY:
			var choice := await Dialogs.error_with_actions(parent, "Pull blocked by local changes", GitErrors.explain(r["error"]),
					{ "autostash": "Stash, Pull, Re-apply" })
			if choice == "autostash":
				return await pull(parent, repo, bar, strategy, true)
		_:
			await _report(parent, "Pull failed", r["error"])
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

	match GitErrors.classify(r["error"]):
		GitErrors.NO_UPSTREAM:
			var branch: String = repo.get_current_branch()
			var remote := default_remote(repo)
			if branch.is_empty() or remote.is_empty():
				await _report(parent, "Push failed", r["error"])
				return false
			if await Dialogs.confirm(parent, "Publish Branch",
					"\"%s\" doesn't track a remote branch yet.\n\nPush it to %s/%s and track it from now on?" % [branch, remote, branch], "Push"):
				var next := options.duplicate()
				next.merge({ "remote": remote, "branch": branch, "set_upstream": true }, true)
				return await push(parent, repo, bar, next)
		GitErrors.NON_FAST_FORWARD:
			var choice := await Dialogs.error_with_actions(parent, "Push rejected", GitErrors.explain(r["error"]),
					{ "pull": "Pull, then Push", "force": "Force Push…" })
			if choice == "pull":
				if await pull(parent, repo, bar):
					return await push(parent, repo, bar, options)
			elif choice == "force":
				if await Dialogs.confirm(parent, "Force Push",
						"Overwrite the remote branch with your local one?\n\nUses --force-with-lease: it still refuses if someone pushed commits you haven't fetched.", "Force Push"):
					var next := options.duplicate()
					next["force_with_lease"] = true
					return await push(parent, repo, bar, next)
		_:
			await _report(parent, "Push failed", r["error"])
	return false


## Fetch, then pull the upstream's new commits (uncommitted changes stashed around it) and push the branch's own: one button for whichever is due. A branch without an upstream gets published.
static func sync(parent: Control, repo: RefCounted, bar: Control) -> bool:
	if repo.get_current_branch().is_empty():
		await Dialogs.error(parent, "Sync", "HEAD is detached, so there's no branch to sync. Switch to a branch first.")
		return false
	if repo.get_upstream().is_empty():
		return await push(parent, repo, bar) # asks to publish it
	if not await fetch(parent, repo, bar):
		return false
	var pulled := false
	if repo.get_sync_status()["behind"] > 0:
		if not await pull(parent, repo, bar, "", true):
			return false
		pulled = true
	var s: Dictionary = repo.get_sync_status()
	if s["ahead"] > 0:
		return await push(parent, repo, bar)
	bar.done("Pulled; nothing to push." if pulled else "In sync with %s." % s["upstream"])
	return true


## Git's error, explained; when the remote refused the login, it also offers the setup check, which says how to fix that for this remote.
static func _report(parent: Control, title: String, error: String) -> void:
	if GitErrors.classify(error) in [GitErrors.AUTH, GitErrors.HOST_KEY] and open_setup_check.is_valid():
		if await Dialogs.error_with_actions(parent, title, GitErrors.explain(error), { "setup": "Help Me Log In" }) == "setup":
			open_setup_check.call()
		return
	await Dialogs.error(parent, title, GitErrors.explain(error))


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
