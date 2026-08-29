## Persists changelists per repo — named groups for organizing changed files.
## Pure IDE-side bookkeeping, git has no concept of this. "Default" always
## exists and can't be deleted/renamed. Keyed by repo root. No class_name:
## internal helper, addressed via preload (see git_status_flags.gd for why).
extends RefCounted

const DEFAULT_NAME := "Default"
const CONFIG_PATH := "user://git_tree_changelists.cfg"


static func _section(repo_root: String) -> String:
	return "repo:" + repo_root.md5_text()


## Loaded state per repo root, shared by every panel so a change made in one is seen by the others.
static var _cache: Dictionary = {}


## {"names": Array[String], "assignments": Dictionary[path, name], "active": String}. A path missing from assignments is just in Default.
static func load_state(repo_root: String) -> Dictionary:
	if _cache.has(repo_root):
		return _cache[repo_root]
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH) # missing file is fine, falls through to defaults
	var section := _section(repo_root)

	var names: Array = cfg.get_value(section, "names", [])
	if not names.has(DEFAULT_NAME):
		names.push_front(DEFAULT_NAME)

	var active: String = cfg.get_value(section, "active", DEFAULT_NAME)
	if not names.has(active):
		active = DEFAULT_NAME

	var state := {
		"names": names,
		"assignments": cfg.get_value(section, "assignments", {}),
		"active": active,
	}
	_cache[repo_root] = state
	return state


static func save_state(repo_root: String, state: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var section := _section(repo_root)
	cfg.set_value(section, "names", state["names"])
	cfg.set_value(section, "assignments", state["assignments"])
	cfg.set_value(section, "active", state["active"])
	cfg.save(CONFIG_PATH)
