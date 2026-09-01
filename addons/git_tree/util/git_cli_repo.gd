## Runs every git operation by shelling out to the system `git` binary (see
## util/git_cli.gd) — no native extension, works anywhere `git` is on PATH.
## Status is encoded as GitStatusFlags' bitmask and GitIcons' DELTA_* codes,
## same as the rest of the addon expects. No class_name: internal helper,
## addressed via preload (see git_status_flags.gd for why).
extends RefCounted

const GitCli := preload("res://addons/git_tree/util/git_cli.gd")
const GitStatusFlags := preload("res://addons/git_tree/util/git_status_flags.gd")
const GitIcons := preload("res://addons/git_tree/util/git_icons.gd")

const US := GitCli.US

## Porcelain XY codes for unmerged paths (both sides touched the file, or one deleted what the other changed).
const CONFLICT_CODES := ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

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


func get_status() -> Array:
	var result := GitCli.run(_repo_root, ["status", "--porcelain=v1", "--untracked-files=all"])
	var entries: Array = []
	for line in GitCli.lines(result["text"]):
		if line.length() < 4:
			continue
		var xy := line.substr(0, 2)
		var rest := line.substr(3)
		var path := rest
		var renamed_from := ""
		var arrow := rest.find(" -> ")
		if arrow != -1:
			renamed_from = rest.substr(0, arrow)
			path = rest.substr(arrow + 4)
		entries.append({
			"path": path,
			"status": _status_bits(xy),
			"renamed_from": renamed_from,
		})
	return entries


## Maps porcelain v1's two-letter XY status into GitStatusFlags' bitmask.
func _status_bits(xy: String) -> int:
	if xy == "??":
		return GitStatusFlags.WT_NEW
	if xy in CONFLICT_CODES:
		return GitStatusFlags.CONFLICTED | GitStatusFlags.WT_MODIFIED
	var bits := 0
	match xy[0]:
		"M": bits |= GitStatusFlags.INDEX_MODIFIED
		"A": bits |= GitStatusFlags.INDEX_NEW
		"D": bits |= GitStatusFlags.INDEX_DELETED
		"R": bits |= GitStatusFlags.INDEX_RENAMED
		"C": bits |= GitStatusFlags.INDEX_RENAMED
		"T": bits |= GitStatusFlags.INDEX_TYPECHANGE
		"U": bits |= GitStatusFlags.CONFLICTED | GitStatusFlags.INDEX_MODIFIED
	match xy[1]:
		"M": bits |= GitStatusFlags.WT_MODIFIED
		"D": bits |= GitStatusFlags.WT_DELETED
		"R": bits |= GitStatusFlags.WT_RENAMED
		"C": bits |= GitStatusFlags.WT_RENAMED
		"T": bits |= GitStatusFlags.WT_TYPECHANGE
		"U": bits |= GitStatusFlags.CONFLICTED | GitStatusFlags.WT_MODIFIED
	return bits


## options: {"context": int (lines of context, -1 = whole file), "ignore_whitespace": bool}.
func get_diff(path: String, staged: bool, options: Dictionary = {}) -> String:
	var flags := _diff_flags(options)
	if staged:
		return GitCli.run(_repo_root, ["diff", "--cached"] + flags + ["--", path])["text"]

	# Plain `git diff` shows nothing for an untracked file; diffing against
	# /dev/null renders it as a full-file addition instead.
	if is_untracked(path):
		return GitCli.run(_repo_root, ["diff", "--no-index"] + flags + ["--", "/dev/null", path])["text"]

	return GitCli.run(_repo_root, ["diff"] + flags + ["--", path])["text"]


func is_untracked(path: String) -> bool:
	var status_result := GitCli.run(_repo_root, ["status", "--porcelain=v1", "--", path])
	return status_result["text"].strip_edges().begins_with("??")


static func _diff_flags(options: Dictionary) -> Array:
	var flags: Array = ["--no-color", "--no-ext-diff"]
	var context: int = options.get("context", 3)
	flags.append("--unified=%d" % (context if context >= 0 else 1000000))
	if options.get("ignore_whitespace", false):
		flags.append("--ignore-all-space")
	return flags


## Files that differ between two revisions; target "" = the working tree. Same shape as get_commit_files().
func get_changed_files_between(base: String, target: String) -> Array:
	var args := ["diff", "--name-status", "-M", base]
	if not target.is_empty():
		args.append(target)
	return _parse_name_status(GitCli.run(_repo_root, args)["text"])


## Diff of one file between two revisions; target "" = the working tree.
func get_diff_between(base: String, target: String, path: String, options: Dictionary = {}) -> String:
	var args := ["diff"] + _diff_flags(options) + [base]
	if not target.is_empty():
		args.append(target)
	args.append_array(["--", path])
	return GitCli.run(_repo_root, args)["text"]


## One file's changes in a single commit (against its first parent, or the empty tree for a root commit).
func get_commit_file_diff(oid: String, path: String, options: Dictionary = {}) -> String:
	var args := ["show", "--format=", "-M", "--first-parent"] + _diff_flags(options) + [oid, "--", path]
	return GitCli.run(_repo_root, args)["text"]


## Applies a patch built by DiffHunks.build_patch(). cached=true targets the index (stage/unstage), false the working tree (revert); reverse undoes the patch instead of applying it. --recount means partial-hunk patches needn't have exact line counts in their headers.
func apply_patch(patch: String, cached: bool, reverse: bool, check_only := false) -> Dictionary:
	var patch_path := OS.get_cache_dir().path_join("git_tree_patch_%d.patch" % Time.get_ticks_usec())
	var patch_file := FileAccess.open(patch_path, FileAccess.WRITE)
	if patch_file == null:
		return { "ok": false, "error": "couldn't write a temp patch file at %s" % patch_path, "output": "" }
	patch_file.store_string(patch)
	patch_file.close()

	var args := ["apply", "--recount", "--whitespace=nowarn"]
	if cached:
		args.append("--cached")
	if reverse:
		args.append("--reverse")
	if check_only:
		args.append("--check")
	args.append(patch_path)
	var result := _simple(args)
	DirAccess.remove_absolute(patch_path)
	return result


## Discards a staged hunk (patch from the staged diff) from both the index and the working tree; checks both first so a failure leaves nothing half-reverted.
func discard_staged_patch(patch: String) -> Dictionary:
	var worktree_check := apply_patch(patch, false, true, true)
	if not worktree_check["ok"]:
		return { "ok": false, "output": "", "error": "The working tree has further changes on these lines — revert or stage those first.\n\n" + worktree_check["error"] }
	var index_check := apply_patch(patch, true, true, true)
	if not index_check["ok"]:
		return index_check
	var result := apply_patch(patch, false, true)
	if not result["ok"]:
		return result
	return apply_patch(patch, true, true)


## Overwrites path in the working tree with its content at rev (deleting it if it didn't exist there). The index is left alone, so it shows up as an ordinary unstaged change.
func restore_file_from(rev: String, path: String) -> Dictionary:
	if GitCli.run(_repo_root, ["cat-file", "-e", "%s:%s" % [rev, path]])["exit_code"] != 0:
		var abs_path := _repo_root.path_join(path)
		if FileAccess.file_exists(abs_path) and DirAccess.remove_absolute(abs_path) != OK:
			return { "ok": false, "error": "couldn't delete %s" % path, "output": "" }
		return { "ok": true, "error": "", "output": "" }
	return _simple(["restore", "--source=" + rev, "--worktree", "--", path])


## Stages many paths in one `git add` (adding new files one by one is slow in big folders).
func stage_files(paths: Array) -> Dictionary:
	if paths.is_empty():
		return { "ok": true, "error": "", "output": "" }
	return _simple(["add", "--"] + paths)


func stage_file(path: String) -> bool:
	# `rm --cached` is the fallback for whatever `add` doesn't cover.
	if GitCli.run(_repo_root, ["add", "--", path])["exit_code"] == 0:
		return true
	return GitCli.run(_repo_root, ["rm", "--cached", "--", path])["exit_code"] == 0


func unstage_file(path: String) -> bool:
	if GitCli.run(_repo_root, ["reset", "--", path])["exit_code"] == 0:
		return true
	# Unborn branch, no HEAD to reset to — just drop it from the index.
	return GitCli.run(_repo_root, ["rm", "--cached", "--", path])["exit_code"] == 0


## Discards uncommitted changes to path. Restores from HEAD if committed,
## otherwise deletes it (nothing to restore to).
func revert_file(path: String) -> Dictionary:
	var result := { "ok": false, "error": "" }

	if GitCli.run(_repo_root, ["cat-file", "-e", "HEAD:" + path])["exit_code"] == 0:
		var checkout_result := GitCli.run(_repo_root, ["checkout", "HEAD", "--", path], true)
		if checkout_result["exit_code"] != 0:
			result["error"] = checkout_result["text"].strip_edges()
			return result
		result["ok"] = true
		return result

	GitCli.run(_repo_root, ["rm", "-f", "--cached", "--", path], true) # ok if not staged
	var abs_path := _repo_root.path_join(path)
	if FileAccess.file_exists(abs_path):
		var dir := DirAccess.open(_repo_root)
		if dir == null or dir.remove(abs_path) != OK:
			result["error"] = "couldn't delete %s from disk" % path
			return result
	result["ok"] = true
	return result


## Deletes path from disk and stages the removal (`git rm -f`) in one step —
## unlike revert_file(), which restores the file instead of removing it.
func remove_file(path: String) -> Dictionary:
	var result := { "ok": false, "error": "" }
	var rm_result := GitCli.run(_repo_root, ["rm", "-f", "--", path], true)
	if rm_result["exit_code"] != 0:
		result["error"] = rm_result["text"].strip_edges()
		return result
	result["ok"] = true
	return result


func commit(message: String, amend: bool = false) -> Dictionary:
	var result := { "ok": false, "oid": "", "error": "" }
	var args := ["commit", "-m", message]
	if amend:
		args.append("--amend")
	var commit_result := GitCli.run(_repo_root, args, true)
	if commit_result["exit_code"] != 0:
		result["error"] = commit_result["text"].strip_edges()
		return result

	result["ok"] = true
	result["oid"] = GitCli.run(_repo_root, ["rev-parse", "HEAD"])["text"].strip_edges()
	return result


func get_head_info() -> Dictionary:
	var fmt := "%H" + GitCli.US + "%B" + GitCli.US + "%an" + GitCli.US + "%ae" + GitCli.US + "%at"
	var result := GitCli.run(_repo_root, ["log", "-1", "--format=" + fmt])
	if result["exit_code"] != 0:
		return {} # unborn branch, no commits yet

	var text: String = result["text"]
	var fields := text.split(GitCli.US)
	if fields.size() < 5:
		return {}
	return {
		"oid": fields[0],
		"message": fields[1],
		"author_name": fields[2],
		"author_email": fields[3],
		"time": int(fields[4].strip_edges()),
	}


## Array[{name, is_head, is_remote, track ("[ahead 2, behind 1]" or ""), upstream, gone, oid, summary, date (relative)}].
func list_branches(local_only: bool = true) -> Array:
	var patterns := ["refs/heads"]
	if not local_only:
		patterns.append("refs/remotes")
	var fmt := US.join(["%(refname)", "%(HEAD)", "%(upstream:track)", "%(upstream:short)",
			"%(objectname:short)", "%(contents:subject)", "%(committerdate:relative)"])
	var args := ["for-each-ref", "--format=" + fmt]
	args.append_array(patterns)
	var result := GitCli.run(_repo_root, args)

	var entries: Array = []
	for line in GitCli.lines(result["text"]):
		var fields := line.split(US)
		if fields.size() < 7:
			continue
		var refname: String = fields[0]
		if refname.ends_with("/HEAD"):
			continue # refs/remotes/origin/HEAD isn't a real branch
		var is_remote := refname.begins_with("refs/remotes/")
		var short_name := refname.trim_prefix("refs/remotes/" if is_remote else "refs/heads/")
		var track: String = fields[2]
		entries.append({
			"name": short_name,
			"is_head": fields[1].strip_edges() == "*",
			"is_remote": is_remote,
			"track": track,
			"upstream": fields[3],
			"gone": track.contains("gone"),
			"oid": fields[4],
			"summary": fields[5],
			"date": fields[6],
		})
	return entries


## force=true deletes even if it isn't merged anywhere (-D).
func delete_branch(name: String, force: bool = false) -> Dictionary:
	return _simple(["branch", "-D" if force else "-d", name])


func rename_branch(old_name: String, new_name: String) -> Dictionary:
	return _simple(["branch", "-m", old_name, new_name])


## upstream "" unsets it.
func set_upstream(branch: String, upstream: String) -> Dictionary:
	if upstream.is_empty():
		return _simple(["branch", "--unset-upstream", branch])
	return _simple(["branch", "--set-upstream-to=" + upstream, branch])


## Checks out remote_branch ("origin/foo") as a local branch tracking it — or just switches to the local branch if one with that name already exists.
func checkout_remote_branch(remote_branch: String) -> Dictionary:
	var slash := remote_branch.find("/")
	var local_name := remote_branch.substr(slash + 1) if slash != -1 else remote_branch
	if GitCli.run(_repo_root, ["rev-parse", "--verify", "-q", "refs/heads/" + local_name])["exit_code"] == 0:
		return _checkout(local_name)
	return _simple(["checkout", "--track", "-b", local_name, remote_branch])


## Relays the running job's progress line ("Receiving objects:  45% (9/20)") for OperationBar.
signal job_progress(text: String)

## The background job currently running for this repo (fetch/pull/push...), or null. See cancel_current().
var current_job: RefCounted = null


## Kills whatever network operation is in flight; its awaiting caller gets {"ok": false, "cancelled": true}.
func cancel_current() -> void:
	if current_job != null:
		current_job.cancel()


func is_busy() -> bool:
	return current_job != null


## Runs git on a worker thread (see GitCli.start()). Coroutine — callers must await it. {"ok", "error", "output", "cancelled"}.
func _run_async(args: Array) -> Dictionary:
	var job := GitCli.start(_repo_root, args)
	job.progress.connect(job_progress.emit)
	current_job = job
	var r: Dictionary = await job.finished
	if current_job == job:
		current_job = null
	var text: String = String(r["text"]).strip_edges()
	return {
		"ok": r["exit_code"] == 0,
		"error": "" if r["exit_code"] == 0 else text,
		"output": text,
		"cancelled": r.get("cancelled", false),
	}


## Updates remote-tracking refs from remote_name, or every remote if empty.
## Doesn't touch any local branch or the working tree — see pull() for that.
## Coroutine (runs in the background).
func fetch(remote_name: String = "", prune: bool = false) -> Dictionary:
	var args := ["fetch", "--progress", "--all"] if remote_name.is_empty() else ["fetch", "--progress", remote_name]
	if prune:
		args.append("--prune")
	args.append("--tags")
	return await _run_async(args)


## Fetches and integrates the upstream; strategy "" (git config), "merge", "rebase" or "ff-only". Conflicts leave the repo mid-merge. Coroutine.
func pull(strategy: String = "", autostash: bool = false) -> Dictionary:
	var args := ["pull", "--progress"]
	match strategy:
		"merge": args.append("--no-rebase")
		"rebase": args.append("--rebase")
		"ff-only": args.append("--ff-only")
	if autostash:
		args.append("--autostash")
	return await _run_async(args)


## options (all optional): {"remote", "branch", "set_upstream", "force_with_lease", "tags"}; empty = plain `git push`. Coroutine.
func push(options: Dictionary = {}) -> Dictionary:
	var args := ["push", "--progress"]
	if options.get("set_upstream", false):
		args.append("--set-upstream")
	if options.get("force_with_lease", false):
		args.append("--force-with-lease")
	if options.get("tags", false):
		args.append("--follow-tags")
	var remote: String = options.get("remote", "")
	var branch: String = options.get("branch", "")
	if not remote.is_empty():
		args.append(remote)
		if not branch.is_empty():
			args.append(branch)
	return await _run_async(args)


## Current branch's short name, or "" on a detached HEAD.
func get_current_branch() -> String:
	var r := GitCli.run(_repo_root, ["symbolic-ref", "--short", "-q", "HEAD"])
	return r["text"].strip_edges() if r["exit_code"] == 0 else ""


## Short name of branch's upstream (e.g. "origin/main"), or "" if it has none. Empty branch = current.
func get_upstream(branch: String = "") -> String:
	var r := GitCli.run(_repo_root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", branch + "@{upstream}"])
	return r["text"].strip_edges() if r["exit_code"] == 0 else ""


## {"branch", "upstream"} for the current HEAD; upstream is "" when there's none.
func get_sync_status() -> Dictionary:
	var info := { "branch": get_current_branch(), "upstream": "" }
	if not info["branch"].is_empty():
		info["upstream"] = get_upstream()
	return info


## Array[{"name", "fetch_url", "push_url"}].
func list_remotes() -> Array:
	var r := GitCli.run(_repo_root, ["remote", "-v"])
	var by_name := {}
	var order: Array = []
	for line in GitCli.lines(r["text"]):
		var parts := line.split("\t")
		if parts.size() < 2:
			continue
		var name := parts[0]
		var url_and_kind := parts[1].split(" ")
		if not by_name.has(name):
			by_name[name] = { "name": name, "fetch_url": "", "push_url": "" }
			order.append(name)
		if url_and_kind.size() > 1 and url_and_kind[1] == "(push)":
			by_name[name]["push_url"] = url_and_kind[0]
		else:
			by_name[name]["fetch_url"] = url_and_kind[0]
	var result: Array = []
	for name in order:
		result.append(by_name[name])
	return result


## Runs a quick mutating command synchronously -> {"ok", "error", "output"}.
func _simple(args: Array) -> Dictionary:
	var r := GitCli.run(_repo_root, args, true)
	var text: String = r["text"].strip_edges()
	return { "ok": r["exit_code"] == 0, "error": "" if r["exit_code"] == 0 else text, "output": text }


## Checks out a local branch, moving HEAD and updating the working tree.
## `git checkout` already refuses rather than clobbering local changes.
func checkout_branch(name: String) -> Dictionary:
	return _checkout(name)


## Checks out an arbitrary commit, leaving HEAD detached.
func checkout_commit(oid: String) -> Dictionary:
	return _checkout(oid)


func _checkout(target: String) -> Dictionary:
	var result := { "ok": false, "error": "" }
	var checkout_result := GitCli.run(_repo_root, ["checkout", target], true)
	if checkout_result["exit_code"] != 0:
		result["error"] = checkout_result["text"].strip_edges()
		return result
	result["ok"] = true
	return result


func create_branch(name: String, start_point: String, checkout: bool) -> Dictionary:
	var result := { "ok": false, "error": "" }
	var point := start_point if not start_point.is_empty() else "HEAD"
	var args := ["checkout", "-b", name, point] if checkout else ["branch", name, point]
	var branch_result := GitCli.run(_repo_root, args, true)
	if branch_result["exit_code"] != 0:
		result["error"] = branch_result["text"].strip_edges()
		return result
	result["ok"] = true
	return result


## Flat parent-linked commit list (HEAD + local branches, lanes laid out in commit_graph.gd); options: {"remotes": bool, "ref": only this ref, "path": only commits touching it, "skip": int}.
func get_commit_graph(limit: int = 200, options: Dictionary = {}) -> Array:
	return _parse_commit_graph(GitCli.run(_repo_root, _commit_graph_args(limit, options))["text"])


## Searches the whole history (same options as get_commit_graph()) instead of just the loaded page. mode: "message" (also matches a hash), "author", or "code" (commits that add/remove query, git's -S). Coroutine, off the main thread — -S diffs every commit. null if superseded by cancel_search().
func search_commits(query: String, mode: String, limit: int, options: Dictionary = {}) -> Variant:
	var args := _commit_graph_args(limit, options)
	match mode:
		"author": args.insert(1, "--author=" + query)
		"code": args.insert(1, "-S" + query)
		_: args.insert(1, "--grep=" + query)
	args.insert(1, "-i")
	if mode != "code":
		args.insert(1, "--fixed-strings") # "fix(" is text here, not a broken regex
	cancel_search()
	var job := GitCli.start(_repo_root, args)
	_search_job = job
	var r: Dictionary = await job.finished
	if _search_job == job:
		_search_job = null
	if r["cancelled"]:
		return null
	var commits := _parse_commit_graph(r["text"]) if r["exit_code"] == 0 else []
	if mode == "message" and query.length() >= 4 and query.is_valid_hex_number():
		var hit := GitCli.run(_repo_root, ["rev-parse", "-q", "--verify", query + "^{commit}"])
		if hit["exit_code"] == 0 and not commits.any(func(c: Dictionary) -> bool: return c["oid"] == hit["text"].strip_edges()):
			commits = _parse_commit_graph(GitCli.run(_repo_root, _commit_graph_args(1, { "ref": query }))["text"]) + commits
	return commits


var _search_job: RefCounted = null


func cancel_search() -> void:
	if _search_job != null:
		_search_job.cancel()
		_search_job = null


func _commit_graph_args(limit: int, options: Dictionary) -> Array:
	var fmt := "%H" + GitCli.US + "%P" + GitCli.US + "%s" + GitCli.US + "%B" + GitCli.US + "%an" + GitCli.US + "%ae" + GitCli.US + "%at" + GitCli.RS
	var args := ["log", "--topo-order", "--date-order", "--format=" + fmt, "--max-count=%d" % limit]
	if options.get("skip", 0) > 0:
		args.append("--skip=%d" % options["skip"])
	var ref: String = options.get("ref", "")
	if not ref.is_empty():
		args.append(ref)
	else:
		args.append_array(["HEAD", "--branches"])
		if options.get("remotes", false):
			args.append("--remotes")
	var path: String = options.get("path", "")
	if not path.is_empty():
		# --parents rewrites %P to the nearest commit that also touched path, so the filtered graph stays connected.
		args.append_array(["--parents", "--", path])
	return args


func _parse_commit_graph(log_text: String) -> Array:
	var branch_refs := _refs_by_oid(["refs/heads", "refs/remotes"])
	var tag_refs := _tags_by_oid()
	var entries: Array = []
	for record in log_text.split(GitCli.RS):
		if record.strip_edges().is_empty():
			continue
		var fields := record.lstrip("\n").split(GitCli.US) # leading \n from the previous record's terminator
		if fields.size() < 7:
			continue
		var oid: String = fields[0]
		var parents := PackedStringArray()
		if not fields[1].strip_edges().is_empty():
			for p in fields[1].split(" "):
				if not p.is_empty():
					parents.append(p)
		entries.append({
			"oid": oid,
			"parents": parents,
			"summary": fields[2],
			"message": fields[3],
			"author_name": fields[4],
			"author_email": fields[5],
			"time": int(fields[6].strip_edges()),
			"refs": branch_refs.get(oid, PackedStringArray()),
			"tags": tag_refs.get(oid, PackedStringArray()),
		})
	return entries


func get_head_oid() -> String:
	var r := GitCli.run(_repo_root, ["rev-parse", "-q", "--verify", "HEAD"])
	return r["text"].strip_edges() if r["exit_code"] == 0 else ""


## The empty tree's id in this repo's hash format — the "parent" to diff a root commit against.
func empty_tree_oid() -> String:
	if GitCli.run(_repo_root, ["rev-parse", "--show-object-format"])["text"].strip_edges() == "sha256":
		return "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"
	return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


## rev's first parent, or the empty tree if it has none.
func parent_or_empty_tree(oid: String) -> String:
	return oid + "^" if has_parent(oid) else empty_tree_oid()


func has_parent(oid: String) -> bool:
	return GitCli.run(_repo_root, ["rev-parse", "-q", "--verify", oid + "^"])["exit_code"] == 0


## Files changed by this commit, diffed against its first parent (--root
## diffs a parentless commit against the empty tree, so its files show as
## additions). -M folds a delete+add pair into a single rename entry.
func get_commit_files(oid: String) -> Array:
	var result := GitCli.run(_repo_root, ["diff-tree", "--no-commit-id", "--name-status", "-r", "--root", "-M", oid])
	return _parse_name_status(result["text"])


func _parse_name_status(text: String) -> Array:
	var entries: Array = []
	for line in GitCli.lines(text):
		var fields := line.split("\t")
		if fields.size() < 2:
			continue
		var letter := fields[0].substr(0, 1) # strip the similarity score off R100/C100
		var path: String = fields[2] if (letter == "R" or letter == "C") and fields.size() > 2 else fields[1]
		var entry := { "path": path, "status": _delta_status(letter) }
		if letter == "R" or letter == "C":
			entry["old_path"] = fields[1]
		entries.append(entry)
	return entries


func _delta_status(letter: String) -> int:
	match letter:
		"A": return GitIcons.DELTA_ADDED
		"D": return GitIcons.DELTA_DELETED
		"R": return GitIcons.DELTA_RENAMED
		"C": return GitIcons.DELTA_COPIED
		"T": return GitIcons.DELTA_TYPECHANGE
		_: return GitIcons.DELTA_MODIFIED


## Branch names whose history contains oid, "HEAD" first if it qualifies
## too (a detached checkout has no branch name of its own).
func branches_containing(oid: String) -> PackedStringArray:
	var names := PackedStringArray()

	if GitCli.run(_repo_root, ["symbolic-ref", "-q", "HEAD"])["exit_code"] != 0:
		if GitCli.run(_repo_root, ["merge-base", "--is-ancestor", oid, "HEAD"])["exit_code"] == 0:
			names.append("HEAD")

	var result := GitCli.run(_repo_root, ["for-each-ref", "--contains", oid, "--format=%(refname:short)", "refs/heads", "refs/remotes"])
	for line in GitCli.lines(result["text"]):
		if line.ends_with("/HEAD"):
			continue
		names.append(line)
	return names


func _refs_by_oid(ref_prefixes: Array) -> Dictionary:
	var fmt := "%(objectname)" + GitCli.US + "%(refname:short)"
	var args := ["for-each-ref", "--format=" + fmt]
	args.append_array(ref_prefixes)
	var result := GitCli.run(_repo_root, args)

	var map := {}
	for line in GitCli.lines(result["text"]):
		var fields := line.split(GitCli.US)
		if fields.size() < 2:
			continue
		var oid: String = fields[0]
		var name: String = fields[1]
		if name.ends_with("/HEAD"):
			continue
		# Mutating a PackedStringArray fetched from a Dictionary in place
		# doesn't write back (COW) — reassign it instead.
		var arr: PackedStringArray = map.get(oid, PackedStringArray())
		arr.append(name)
		map[oid] = arr
	return map


func _tags_by_oid() -> Dictionary:
	# %(*objectname) is the peeled oid for an annotated tag, empty for a
	# lightweight one (falls back to %(objectname)).
	var fmt := "%(objectname)" + GitCli.US + "%(*objectname)" + GitCli.US + "%(refname:short)"
	var result := GitCli.run(_repo_root, ["for-each-ref", "--format=" + fmt, "refs/tags"])

	var map := {}
	for line in GitCli.lines(result["text"]):
		var fields := line.split(GitCli.US)
		if fields.size() < 3:
			continue
		var oid: String = fields[1] if not fields[1].is_empty() else fields[0]
		var name: String = fields[2]
		var arr: PackedStringArray = map.get(oid, PackedStringArray())
		arr.append(name)
		map[oid] = arr
	return map
