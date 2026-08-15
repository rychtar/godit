## Runs every git operation by shelling out to the system `git` binary (see
## util/git_cli.gd) — no native extension, works anywhere `git` is on PATH.
## Status is encoded as GitStatusFlags' bitmask, same as the rest of the
## addon expects. No class_name: internal helper,
## addressed via preload (see git_status_flags.gd for why).
extends RefCounted

const GitCli := preload("res://addons/git_tree/util/git_cli.gd")
const GitStatusFlags := preload("res://addons/git_tree/util/git_status_flags.gd")

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


func commit(message: String) -> Dictionary:
	var result := { "ok": false, "oid": "", "error": "" }
	var commit_result := GitCli.run(_repo_root, ["commit", "-m", message], true)
	if commit_result["exit_code"] != 0:
		result["error"] = commit_result["text"].strip_edges()
		return result

	result["ok"] = true
	result["oid"] = GitCli.run(_repo_root, ["rev-parse", "HEAD"])["text"].strip_edges()
	return result


## Runs a quick mutating command synchronously -> {"ok", "error", "output"}.
func _simple(args: Array) -> Dictionary:
	var r := GitCli.run(_repo_root, args, true)
	var text: String = r["text"].strip_edges()
	return { "ok": r["exit_code"] == 0, "error": "" if r["exit_code"] == 0 else text, "output": text }
