## Takes the Local History snapshots (local_history.gd) on a worker thread: a few seconds after saves, every few minutes and when the editor loses focus if anything changed, and before git operations rewrite files. Godit Settings > Local History turns it off.
@tool
extends Node

const LocalHistory := preload("res://addons/godit/util/local_history.gd")
const Settings := preload("res://addons/godit/util/settings.gd")
const RepoOpener := preload("res://addons/godit/util/repo_opener.gd")

## Quiet seconds after the last save before a snapshot, and the least time between two taken for saves.
const SAVE_DELAY := 3.0
const SAVE_SPACING := 30
## The project as the editor opened it, once startup has settled.
const START_DELAY := 5.0

## After every snapshot, taken or not: LocalHistory.snapshot()'s result.
signal finished(result: Dictionary)

## The plugin's recorder while it's enabled.
static var instance: Node

## Null outside a git repository.
var repo: RefCounted
## Where res:// is in the repository; null = ask the editor (tests set it).
var project_dir: Variant = null
var _interval: Timer
var _after_save: Timer
var _thread: Thread
## Why the snapshot asked for while one was running is taken, or null.
var _queued: Variant = null
## Unix time of the last snapshot.
var _last := 0


## Whether snapshots are being taken: Godit runs in a repository with Local History on.
static func is_on() -> bool:
	return is_instance_valid(instance) and instance.repo != null and LocalHistory.is_enabled()


## Coroutine for git operations that rewrite files (SaveGuard, the reverts): Local History gets the files as they are first.
static func before(verb: String) -> void:
	if is_instance_valid(instance):
		await instance.take("Before " + verb)


func _enter_tree() -> void:
	instance = self


func _ready() -> void:
	set_repo(RepoOpener.open_current_project_repo()["repo"])


func set_repo(new_repo: RefCounted, new_project_dir: Variant = null) -> void:
	repo = new_repo
	project_dir = new_project_dir
	if repo == null or _interval != null:
		return
	_interval = Timer.new()
	_interval.timeout.connect(request.bind(""))
	add_child(_interval)
	_after_save = Timer.new()
	_after_save.one_shot = true
	_after_save.timeout.connect(_on_after_save)
	add_child(_after_save)
	var start := Timer.new()
	start.one_shot = true
	start.timeout.connect(func() -> void:
		request("")
		start.queue_free()
	)
	add_child(start)
	start.start(START_DELAY)
	Settings.notifier().changed.connect(_on_setting_changed)
	_apply_interval()


func _exit_tree() -> void:
	if instance == self:
		instance = null
	if Settings.notifier().changed.is_connected(_on_setting_changed):
		Settings.notifier().changed.disconnect(_on_setting_changed)
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func _notification(what: int) -> void:
	if repo == null:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_interval.stop()
		request("") # e.g. off to a terminal to run git
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_apply_interval()


## Called by plugin.gd for every saved scene and resource.
func on_saved() -> void:
	if repo != null and LocalHistory.is_enabled():
		_after_save.start(SAVE_DELAY)


func _on_after_save() -> void:
	var wait := _last + SAVE_SPACING - int(Time.get_unix_time_from_system())
	if wait > 0:
		_after_save.start(wait)
	else:
		request("")


## A snapshot in the background; one asked for while another runs follows it.
func request(why: String) -> void:
	if repo == null or not LocalHistory.is_enabled():
		return
	if _thread != null:
		if _queued == null or String(_queued).is_empty():
			_queued = why
		return
	_run(why)


## Coroutine: a snapshot now (after the one running), with its result; {"ok": false} when Local History is off or there's no repository.
func take(why: String) -> Dictionary:
	if repo == null or not LocalHistory.is_enabled():
		return {"ok": false, "error": "Local History is off.", "tree": "", "taken": false}
	while _thread != null:
		await finished
	return await _run(why)


## What LocalHistory's functions need for this project.
func context() -> Dictionary:
	return LocalHistory.context(repo, project_dir)


## Coroutine: deletes every snapshot, once the one running is done.
func clear() -> void:
	while _thread != null:
		await finished
	LocalHistory.clear(context())


func _run(why: String) -> Dictionary:
	var ctx := context()
	var now := int(Time.get_unix_time_from_system())
	_thread = Thread.new()
	_thread.start(func() -> Dictionary: return LocalHistory.snapshot(ctx, why, now))
	while _thread.is_alive():
		if not is_inside_tree():
			return {"ok": false, "error": "Godit stopped.", "tree": "", "taken": false} # _exit_tree() joins it
		await get_tree().process_frame
	var finished_with: Variant = _thread.wait_to_finish()
	_thread = null
	var result: Dictionary = finished_with if finished_with is Dictionary else {"ok": false, "error": "The snapshot stopped with an error.", "tree": "", "taken": false}
	_last = now
	if not result["ok"]:
		push_warning("Godit: Local History couldn't take a snapshot: " + result["error"])
	finished.emit(result)
	if _queued != null and _thread == null:
		var queued: String = _queued
		_queued = null
		_run(queued)
	return result


func _on_setting_changed(key: String) -> void:
	if key == LocalHistory.ENABLED_KEY or key == LocalHistory.MINUTES_KEY:
		_apply_interval()
		if key == LocalHistory.ENABLED_KEY:
			request("")


func _apply_interval() -> void:
	if not LocalHistory.is_enabled():
		_interval.stop()
		return
	var seconds := maxi(1, int(Settings.get_value(LocalHistory.MINUTES_KEY, LocalHistory.DEFAULT_MINUTES))) * 60.0
	if _interval.is_stopped() or not is_equal_approx(_interval.wait_time, seconds):
		_interval.start(seconds)
