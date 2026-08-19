## Thin ConfigFile wrapper for small per-user preferences (e.g. History's
## column widths) that shouldn't live in the project itself. No class_name:
## internal helper, addressed via preload (see git_status_flags.gd for why).
extends RefCounted

const CONFIG_PATH := "user://git_tree_settings.cfg"
const SECTION := "git_tree"


static func get_value(key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH) # missing file is fine: falls through to `default` below
	return cfg.get_value(SECTION, key, default)


static func set_value(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value(SECTION, key, value)
	cfg.save(CONFIG_PATH)
