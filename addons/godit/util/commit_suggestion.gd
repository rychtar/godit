## A commit message suggested from what's staged: "Update player.gd", "Add enemy.gd and enemy.tscn", "Update player.gd, delete old.png", "Update 7 files in scenes/". Shown in an empty message and taken with Tab. No class_name: internal helper, addressed via preload.
extends RefCounted

const GitStatusFlags := preload("res://addons/godit/util/git_status_flags.gd")
const CompanionFiles := preload("res://addons/godit/util/companion_files.gd")

## File names spelled out; more are counted.
const NAMED := 3
const VERBS := ["Add", "Update", "Delete", "Rename"]


## entries: get_status()'s {"path", "status", "renamed_from"}; "" when nothing is staged. A .uid or .import staged with its file isn't mentioned.
static func suggest(entries: Array) -> String:
	var staged := {}
	for e: Dictionary in entries:
		if GitStatusFlags.is_staged(e["status"]) and not e["status"] & GitStatusFlags.CONFLICTED:
			staged[e["path"]] = e
	var by_verb := {}
	var paths: Array = []
	for path: String in staged:
		var owner := CompanionFiles.owner_of(path)
		if not owner.is_empty() and staged.has(owner):
			continue
		var e: Dictionary = staged[path]
		var verb := _verb(e["status"])
		if not by_verb.has(verb):
			by_verb[verb] = []
		var renamed_from: String = e.get("renamed_from", "")
		by_verb[verb].append("%s to %s" % [renamed_from.get_file(), path.get_file()] if verb == "Rename" and not renamed_from.is_empty() else path.get_file())
		paths.append(path)
	if paths.is_empty():
		return ""
	if paths.size() > NAMED:
		var folder := _common_folder(paths)
		return "%s %d files%s" % [by_verb.keys()[0] if by_verb.size() == 1 else "Change", paths.size(), " in %s/" % folder if not folder.is_empty() else ""]
	var parts: Array = []
	for verb: String in VERBS:
		if by_verb.has(verb):
			parts.append("%s %s" % [verb if parts.is_empty() else verb.to_lower(), _and(by_verb[verb])])
	return ", ".join(parts)


static func _verb(status: int) -> String:
	if status & GitStatusFlags.INDEX_NEW:
		return "Add"
	if status & GitStatusFlags.INDEX_DELETED:
		return "Delete"
	if status & GitStatusFlags.INDEX_RENAMED:
		return "Rename"
	return "Update"


## "a", "a and b", "a, b and c".
static func _and(names: Array) -> String:
	if names.size() == 1:
		return names[0]
	return ", ".join(names.slice(0, names.size() - 1)) + " and " + names[-1]


## The deepest folder every path is in, or "".
static func _common_folder(paths: Array) -> String:
	var common: PackedStringArray = String(paths[0]).get_base_dir().split("/", false)
	for path: String in paths:
		var parts := path.get_base_dir().split("/", false)
		var n := 0
		while n < common.size() and n < parts.size() and common[n] == parts[n]:
			n += 1
		common = common.slice(0, n)
	return "/".join(common)
