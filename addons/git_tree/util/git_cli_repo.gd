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
