## Gentle nudges as toasts: changed files left uncommitted for hours, commits only on this computer for as long. Follows the watcher's polls (only while the editor has focus); the clocks are kept per project, so yesterday's work gets its reminder the next day. Godit Settings > Sync turns them off.
@tool
extends Node

const Settings := preload("res://addons/godit/util/settings.gd")
const RepoWatcher := preload("res://addons/godit/util/repo_watcher.gd")
const GitStatusFlags := preload("res://addons/godit/util/git_status_flags.gd")

const ENABLED_KEY := "reminders"
const HOURS_KEY := "reminder_hours"
const DEFAULT_HOURS := 2
## {"since": unix time it started, "last": unix time of the last reminder} per project, or unset while it isn't so.
const UNCOMMITTED_KEY := "reminder_uncommitted"
const UNPUSHED_KEY := "reminder_unpushed"

## Refs and config the ahead count was last read for.
var _counted_for := ""
var _ahead := 0


func _ready() -> void:
	RepoWatcher.watch(self, _on_polled)


func _on_polled(snapshot: Dictionary) -> void:
	var repo: RefCounted = RepoWatcher.instance.repo if is_instance_valid(RepoWatcher.instance) else null
	if repo == null:
		return
	var changed: int = repo.parse_status(snapshot["status"]).filter(func(e: Dictionary) -> bool: return not e["status"] & GitStatusFlags.IGNORED).size()
	var key: String = snapshot["refs"] + snapshot["config"]
	if key != _counted_for:
		_counted_for = key
		_ahead = repo.get_sync_status()["ahead"]
	var now := int(Time.get_unix_time_from_system())
	var hours: int = Settings.get_value(HOURS_KEY, DEFAULT_HOURS)
	var uncommitted := due(UNCOMMITTED_KEY, changed > 0, now, hours)
	var unpushed := due(UNPUSHED_KEY, _ahead > 0, now, hours)
	if not Settings.get_value(ENABLED_KEY, true):
		return
	var toaster := EditorInterface.get_editor_toaster()
	if uncommitted > 0:
		toaster.push_toast("Godit: %d changed file%s not committed for %s. Alt+C commits them." % [changed, "" if changed == 1 else "s", _duration(uncommitted)])
	if unpushed > 0:
		toaster.push_toast("Godit: %d commit%s only on this computer for %s. ⇅ Sync pushes them." % [_ahead, "" if _ahead == 1 else "s", _duration(unpushed)])


## Seconds the condition has held when a reminder is due (since it started, or the last reminder, longer than hours ago), else 0. Starts the clock when it becomes true and clears it when it stops.
static func due(key: String, active: bool, now: int, hours: int) -> int:
	var clock: Variant = Settings.get_value(key, null)
	if not active:
		if clock != null:
			Settings.reset(key)
		return 0
	if not clock is Dictionary:
		Settings.set_value(key, {"since": now, "last": now})
		return 0
	if now - int(clock["last"]) < hours * 3600:
		return 0
	Settings.set_value(key, {"since": clock["since"], "last": now})
	return now - int(clock["since"])


static func _duration(seconds: int) -> String:
	var hours := int(seconds / 3600.0)
	if hours >= 48:
		return "%d days" % int(hours / 24.0)
	return "%d hour%s" % [hours, "" if hours == 1 else "s"]
