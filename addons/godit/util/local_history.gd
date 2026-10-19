## Local History: snapshots of the project's files that aren't commits and leave the index, the working tree and the branches alone. Each is a tree written from a private index in <git dir>/godit/local-history (a git dir sharing the repo's objects, refs and config); a ref pointing at a tree of them (day > hour > snapshot), which `git log --all` skips, keeps them from git gc, and snapshots.jsonl lists them with what changed. Static and free of static vars, so it runs on a worker thread. No class_name: internal helper, addressed via preload.
extends RefCounted

const GitCli := preload("res://addons/godit/util/git_cli.gd")
const Settings := preload("res://addons/godit/util/settings.gd")

const REF := "refs/godit/local-history"
const LOG_FILE := "snapshots.jsonl"
const DAY := 86400
const HOUR := 3600

const ENABLED_KEY := "local_history"
const MINUTES_KEY := "local_history_minutes"
const DAYS_KEY := "local_history_days"
const MAX_MB_KEY := "local_history_max_mb"
const DEFAULT_MINUTES := 5
const DEFAULT_DAYS := 7
const DEFAULT_MAX_MB := 5

## Characters of paths per git call: Windows command lines end at 32767.
const ARGS_BUDGET := 24000


static func is_enabled() -> bool:
	return Settings.get_value(ENABLED_KEY, true)


## Everything a snapshot needs, read on the main thread. project_dir: where res:// is, relative to the repo root (read from the editor when null).
static func context(repo: RefCounted, project_dir: Variant = null) -> Dictionary:
	var root: String = repo.get_repo_root()
	var git_dir: String = repo.get_git_dir()
	if project_dir == null:
		var res := ProjectSettings.globalize_path("res://").trim_suffix("/")
		project_dir = res.trim_prefix(root + "/") if res.begins_with(root + "/") else ""
	# A linked worktree has files of its own, so it gets its own history, and a ref of its own among the shared ones.
	var ref := REF
	if FileAccess.file_exists(git_dir.path_join("commondir")):
		ref += "-"
		for c in git_dir.get_file():
			ref += c if c.is_valid_int() or c.is_valid_identifier() or c == "-" else "_"
	return {
		"root": root,
		"dir": git_dir.path_join("godit/local-history"),
		"common_dir": repo.get_common_dir(),
		"ref": ref,
		"prefix": project_dir + "/" if not String(project_dir).is_empty() else "",
		"max_bytes": int(Settings.get_value(MAX_MB_KEY, DEFAULT_MAX_MB)) * 1024 * 1024,
		"days": maxi(1, int(Settings.get_value(DAYS_KEY, DEFAULT_DAYS))),
	}


## Records the project's files if they changed since the last snapshot: {"ok", "error", "tree" (the files as they are now), "taken", "entry"}; drops snapshots older than ctx["days"] on the way.
static func snapshot(ctx: Dictionary, why: String, now: int) -> Dictionary:
	if not _prepare(ctx):
		return {"ok": false, "error": "Couldn't create %s." % ctx["dir"], "tree": "", "taken": false}
	var index_path: String = ctx["dir"].path_join("index")
	if _resolve(ctx, ctx["ref"]).is_empty():
		# First run, or the ref was deleted: start over, so nothing refers to snapshots git may have dropped.
		DirAccess.remove_absolute(index_path)
		DirAccess.remove_absolute(ctx["dir"].path_join(LOG_FILE))
	_update_index(ctx, not FileAccess.file_exists(index_path))
	var written := _git(ctx, ["write-tree"])
	if written["exit_code"] != 0:
		return {"ok": false, "error": written["error"].strip_edges(), "tree": "", "taken": false}
	var tree: String = written["text"].strip_edges()
	var last := _last_entry(ctx)
	if not last.is_empty() and last["tree"] == tree:
		return {"ok": true, "error": "", "tree": tree, "taken": false}
	var t := maxi(now, int(last.get("t", 0)) + 1)
	var entry := {"t": t, "tree": tree, "why": why, "files": null if last.is_empty() else changes(ctx, last["tree"], tree, "")}
	var stored := _store(ctx, tree, t)
	if not stored["ok"]:
		return {"ok": false, "error": stored["error"], "tree": tree, "taken": false}
	_append_entry(ctx, entry)
	if stored["cutoff"] > 0:
		_prune_log(ctx, stored["cutoff"])
	return {"ok": true, "error": "", "tree": tree, "taken": true, "entry": entry}


## The snapshots, oldest first: [{"t", "tree", "why", "files": [[status, added, deleted, path]…], or null for the first one}]; added/deleted are -1 for binary files.
static func entries(ctx: Dictionary) -> Array:
	var path: String = ctx["dir"].path_join(LOG_FILE)
	if not FileAccess.file_exists(path) or _resolve(ctx, ctx["ref"]).is_empty():
		return []
	var out: Array = []
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var entry := _parse_entry(line)
		if not entry.is_empty():
			out.append(entry)
	return out


## A file's versions, newest first: one per snapshot that changed it ({"t", "tree", "why", "status": "A"/"M"/"D", "added", "deleted"}), and the snapshot before the oldest change (status "") when the file existed then.
static func file_versions(all: Array, path: String) -> Array:
	var versions: Array = []
	var first := -1
	for i in all.size():
		if all[i]["files"] == null:
			continue
		for f: Array in all[i]["files"]:
			if f[3] == path:
				if first == -1:
					first = i
				versions.push_front(_version(all[i], f[0], f[1], f[2]))
				break
	if first > 0 and versions[-1]["status"] != "A":
		versions.append(_version(all[first - 1], "", 0, 0))
	return versions


## Snapshots that changed something in folder (repo-relative, "" = everything) whose path contains query, newest first, each with those files ({"t", "tree", "why", "files"}), and the snapshot before the oldest one.
static func folder_versions(all: Array, folder: String, query := "") -> Array:
	var prefix := folder.trim_suffix("/") + "/" if not folder.is_empty() else ""
	var needle := query.strip_edges().to_lower()
	var versions: Array = []
	var first := -1
	for i in all.size():
		if all[i]["files"] == null:
			continue
		var files: Array = all[i]["files"].filter(func(f: Array) -> bool: return String(f[3]).begins_with(prefix) and (needle.is_empty() or String(f[3]).to_lower().contains(needle)))
		if files.is_empty():
			continue
		if first == -1:
			first = i
		var version := _version(all[i], "", 0, 0)
		version["files"] = files
		versions.push_front(version)
	if first > 0:
		var before := _version(all[first - 1], "", 0, 0)
		before["files"] = []
		versions.append(before)
	return versions


## Files that differ between two snapshot trees, in folder ("" = everything): [[status ("A" added in to_tree, "D" deleted, "M"), added lines, deleted lines, path]].
static func changes(ctx: Dictionary, from_tree: String, to_tree: String, folder: String) -> Array:
	var args := ["diff-tree", "-r", "--no-renames", "--no-ext-diff", "--no-textconv", "--raw", "--numstat", from_tree, to_tree]
	if not folder.is_empty():
		args.append_array(["--", ":(literal)" + folder.trim_suffix("/") + "/"])
	var status := {}
	var counts := {}
	for line in GitCli.lines(_git(ctx, args)["text"]):
		var tab := line.find("\t")
		if line.begins_with(":"):
			status[GitCli.unquote(line.substr(tab + 1))] = line.substr(tab - 1, 1)
		else:
			var parts := line.split("\t", true, 2)
			if parts.size() == 3:
				counts[GitCli.unquote(parts[2])] = [-1 if parts[0] == "-" else parts[0].to_int(), -1 if parts[1] == "-" else parts[1].to_int()]
	var out: Array = []
	for path: String in status:
		var c: Array = counts.get(path, [0, 0])
		out.append([status[path], c[0], c[1], path])
	return out


## Whether path is in a snapshot tree.
static func has_file(ctx: Dictionary, tree: String, path: String) -> bool:
	return _git(ctx, ["cat-file", "-e", "%s:%s" % [tree, path]])["exit_code"] == 0


## Puts paths back as they were in a snapshot tree, through the repo's filters and line endings; a path the tree doesn't have is deleted. {"ok", "error", "written": the paths changed on disk}.
static func restore(ctx: Dictionary, tree: String, paths: Array) -> Dictionary:
	var errors: Array = []
	var written: Array = []
	for path: String in paths:
		var abs_path: String = ctx["root"].path_join(path)
		if not has_file(ctx, tree, path):
			if FileAccess.file_exists(abs_path):
				if DirAccess.remove_absolute(abs_path) == OK:
					written.append(path)
				else:
					errors.append("%s: couldn't delete it" % path)
			continue
		var r := GitCli.execute("git", _argv(ctx, ["cat-file", "--filters", "%s:%s" % [tree, path]]))
		if r["exit_code"] != 0:
			errors.append("%s: %s" % [path, r["err"].get_string_from_utf8().strip_edges()])
			continue
		DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
		var file := FileAccess.open(abs_path, FileAccess.WRITE)
		if file == null:
			errors.append("%s: couldn't write it" % path)
			continue
		file.store_buffer(r["out"])
		file.close()
		written.append(path)
	return {"ok": errors.is_empty(), "error": "\n".join(errors), "written": written}


## Deletes every snapshot: the ref, the private index and the list. git gc frees the space later.
static func clear(ctx: Dictionary) -> void:
	if not _resolve(ctx, ctx["ref"]).is_empty():
		_git(ctx, ["update-ref", "-d", ctx["ref"]])
	var dir: String = ctx["dir"]
	if DirAccess.dir_exists_absolute(dir):
		for file in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(file))
		DirAccess.remove_absolute(dir)


## The private git dir: its own index, the repo's objects, refs and config through commondir (relative, so a moved project keeps pointing at its own repo).
static func _prepare(ctx: Dictionary) -> bool:
	var dir: String = String(ctx["dir"]).simplify_path()
	var common: String = String(ctx["common_dir"]).simplify_path()
	var commondir := common
	if dir.begins_with(common + "/"):
		commondir = "../".repeat(dir.trim_prefix(common + "/").split("/").size()).trim_suffix("/")
	if FileAccess.get_file_as_string(dir.path_join("commondir")).strip_edges() == commondir:
		return true
	DirAccess.make_dir_recursive_absolute(dir)
	return _write(dir.path_join("commondir"), commondir + "\n") and _write(dir.path_join("HEAD"), "ref: refs/godit/unborn\n")


## Brings the private index up to the files on disk: new, changed and deleted ones; big, Git LFS and ignored files stay out, and so does .godot/. fresh: an empty index, which also takes what the repo tracks though it's ignored.
static func _update_index(ctx: Dictionary, fresh: bool) -> void:
	var prefix: String = ctx["prefix"]
	var scope := [":(literal)" + (prefix if not prefix.is_empty() else "."), ":(exclude,literal)%s.godot" % prefix]
	var candidates := {}
	for path in _split_z(GitCli.execute("git", _argv(ctx, ["ls-files", "-z", "-m", "-o", "--exclude-standard", "--"] + scope))["out"]):
		candidates[path] = true
	if fresh:
		for path in _split_z(GitCli.execute("git", GitCli.argv(ctx["root"], ["ls-files", "-z", "--"] + scope))["out"]):
			candidates[path] = true
	var add: Array = []
	var drop: Array = []
	for path: String in candidates:
		if path.ends_with("/"):
			continue # a nested repository
		var abs_path: String = ctx["root"].path_join(path)
		if DirAccess.dir_exists_absolute(abs_path):
			drop.append(path) # a file that became a folder
		elif _size(abs_path) > int(ctx["max_bytes"]):
			drop.append(path)
		else:
			add.append(path)
	var lfs := _lfs_paths(ctx, add.filter(func(p: String) -> bool: return FileAccess.file_exists(ctx["root"].path_join(p))))
	if not lfs.is_empty():
		add = add.filter(func(p: String) -> bool: return not lfs.has(p))
		drop.append_array(lfs.keys())
	_run_chunked(ctx, ["update-index", "--add", "--remove", "--replace"], add)
	_run_chunked(ctx, ["update-index", "--force-remove"], drop)


## Bytes in a file, -1 when it's missing or can't be read (update-index skips those).
static func _size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ) if FileAccess.file_exists(path) else null
	return file.get_length() if file != null else -1


## Paths whose filter attribute is lfs.
static func _lfs_paths(ctx: Dictionary, paths: Array) -> Dictionary:
	var out := {}
	for chunk in _chunks(paths):
		var parts := _split_z(GitCli.execute("git", _argv(ctx, ["check-attr", "-z", "filter", "--"] + chunk))["out"])
		for i in range(0, parts.size() - 2, 3):
			if parts[i + 2] == "lfs":
				out[parts[i]] = true
	return out


## Runs `git <args> -- <paths>` in chunks; a chunk that fails goes path by path, so one unreadable file doesn't keep the rest out.
static func _run_chunked(ctx: Dictionary, args: Array, paths: Array) -> void:
	for chunk in _chunks(paths):
		if _git(ctx, args + ["--"] + chunk)["exit_code"] != 0 and chunk.size() > 1:
			for path in chunk:
				_git(ctx, args + ["--", path])


static func _chunks(paths: Array) -> Array:
	var out: Array = []
	var chunk: Array = []
	var length := 0
	for path: String in paths:
		if not chunk.is_empty() and length + path.length() > ARGS_BUDGET:
			out.append(chunk)
			chunk = []
			length = 0
		chunk.append(path)
		length += path.length() + 3
	if not chunk.is_empty():
		out.append(chunk)
	return out


## Adds a snapshot to the ref's tree (day > hour > unix time) and drops the days older than ctx["days"]: {"ok", "error", "cutoff": the time snapshots before it were dropped, 0 if none were}.
static func _store(ctx: Dictionary, tree: String, t: int) -> Dictionary:
	var old_root := _resolve(ctx, ctx["ref"])
	var root := _ls_tree(ctx, old_root)
	var day := str(floori(float(t) / DAY))
	var hour := str(floori(float(t) / HOUR))
	var hours := _ls_tree(ctx, root.get(day, ""))
	var snapshots := _ls_tree(ctx, hours.get(hour, ""))
	snapshots[str(t)] = tree
	hours[hour] = _mktree(ctx, snapshots)
	root[day] = _mktree(ctx, hours)
	var cutoff_day := floori(float(t - int(ctx["days"]) * DAY) / DAY)
	var pruned := false
	for name: String in root.keys():
		if name.to_int() < cutoff_day:
			root.erase(name)
			pruned = true
	var new_root := _mktree(ctx, root)
	if new_root.is_empty() or String(hours[hour]).is_empty() or String(root[day]).is_empty():
		return {"ok": false, "error": "Couldn't write the snapshot's tree.", "cutoff": 0}
	# The old value is checked, so a second editor on the project can't overwrite this one's snapshot; no reflog, which would keep dropped snapshots alive.
	var r := _git(ctx, ["-c", "core.logAllRefUpdates=false", "update-ref", ctx["ref"], new_root, old_root])
	if r["exit_code"] != 0:
		return {"ok": false, "error": r["error"].strip_edges(), "cutoff": 0}
	return {"ok": true, "error": "", "cutoff": cutoff_day * DAY if pruned else 0}


## name -> oid of a tree's entries; {} for "".
static func _ls_tree(ctx: Dictionary, oid: String) -> Dictionary:
	var out := {}
	if oid.is_empty():
		return out
	for line in GitCli.lines(_git(ctx, ["ls-tree", oid])["text"]):
		var tab := line.find("\t")
		out[line.substr(tab + 1)] = line.substr(0, tab).get_slice(" ", 2)
	return out


## Writes a tree of subtrees (name -> oid) the way git stores it, since `git mktree` only reads stdin; "" on failure.
static func _mktree(ctx: Dictionary, subtrees: Dictionary) -> String:
	var names := subtrees.keys()
	names.sort() # numbers of the same length: git's order
	var bytes := PackedByteArray()
	for name: String in names:
		bytes.append_array(("40000 " + name).to_utf8_buffer())
		bytes.append(0)
		bytes.append_array(String(subtrees[name]).hex_decode())
	var path: String = ctx["dir"].path_join("tree.tmp")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(bytes)
	file.close()
	var r := _git(ctx, ["hash-object", "-w", "-t", "tree", path])
	DirAccess.remove_absolute(path)
	return r["text"].strip_edges() if r["exit_code"] == 0 else ""


static func _resolve(ctx: Dictionary, ref: String) -> String:
	var r := _git(ctx, ["rev-parse", "-q", "--verify", ref])
	return r["text"].strip_edges() if r["exit_code"] == 0 else ""


static func _last_entry(ctx: Dictionary) -> Dictionary:
	var text := FileAccess.get_file_as_string(ctx["dir"].path_join(LOG_FILE)).strip_edges()
	return _parse_entry(text.substr(text.rfind("\n") + 1)) if not text.is_empty() else {}


static func _append_entry(ctx: Dictionary, entry: Dictionary) -> void:
	var path: String = ctx["dir"].path_join(LOG_FILE)
	var file := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) else FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify(entry))
	file.close()


static func _prune_log(ctx: Dictionary, cutoff: int) -> void:
	var path: String = ctx["dir"].path_join(LOG_FILE)
	var kept := PackedStringArray()
	for line in FileAccess.get_file_as_string(path).split("\n", false):
		var entry := _parse_entry(line)
		if not entry.is_empty() and entry["t"] >= cutoff:
			kept.append(line)
	_write(path, "\n".join(kept) + "\n" if not kept.is_empty() else "")


## A snapshots.jsonl line, with JSON's floats made ints again; {} for anything else.
static func _parse_entry(line: String) -> Dictionary:
	var data: Variant = JSON.parse_string(line)
	if not data is Dictionary or not data.has("t") or not data.has("tree"):
		return {}
	var files: Variant = null
	if data.get("files") is Array:
		files = (data["files"] as Array).map(func(f: Array) -> Array: return [String(f[0]), int(f[1]), int(f[2]), String(f[3])])
	return {"t": int(data["t"]), "tree": String(data["tree"]), "why": String(data.get("why", "")), "files": files}


static func _version(entry: Dictionary, status: String, added: int, deleted: int) -> Dictionary:
	return {"t": entry["t"], "tree": entry["tree"], "why": entry["why"], "status": status, "added": added, "deleted": deleted}


## NUL-separated output, split before decoding: get_string_from_utf8() turns NULs into U+FFFD.
static func _split_z(bytes: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	var start := 0
	while start < bytes.size():
		var end := bytes.find(0, start)
		if end == -1:
			end = bytes.size()
		out.append(bytes.slice(start, end).get_string_from_utf8())
		start = end + 1
	return out


static func _write(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	return true


## git in the private git dir: its index, the repo's working tree. No fsmonitor: its daemon belongs to the repo's own index.
static func _argv(ctx: Dictionary, args: Array) -> PackedStringArray:
	return GitCli.argv(ctx["root"], ["--git-dir=" + ctx["dir"], "--work-tree=" + ctx["root"], "-c", "core.fsmonitor=false"] + args)


static func _git(ctx: Dictionary, args: Array) -> Dictionary:
	var r := GitCli.execute("git", _argv(ctx, args))
	return {"exit_code": r["exit_code"], "text": r["out"].get_string_from_utf8(), "error": r["err"].get_string_from_utf8()}
