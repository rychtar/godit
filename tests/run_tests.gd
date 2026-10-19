extends SceneTree

# Runs every test_*.gd in this folder, each method starting with "test_" is one test:
#   godot --headless --path . --script tests/run_tests.gd
# Exits with code 1 when a test fails.

const TESTS_DIR = "res://tests"
const Settings = preload("res://addons/godit/util/settings.gd")
const ChangelistStore = preload("res://addons/godit/util/changelist_store.gd")

# Settings and changelists the tests write go here: a copy of the repo has the project's name, so its user:// is the real project's.
var _user_dir := OS.get_temp_dir().path_join("godit_test_user_%d" % OS.get_process_id())

func _init() -> void:
	_run()

func _run() -> void:
	var total := 0
	var failed := 0
	for file in _test_files():
		var script: GDScript = load(TESTS_DIR.path_join(file))
		if not script or not script.can_instantiate():
			total += 1
			failed += 1
			print("FAIL %s: the script can't be loaded (see the errors above)" % file)
			continue
		var test = script.new()
		test.tree = self
		for method in test.get_method_list():
			if not method.name.begins_with("test_"):
				continue
			_isolate_user_data()
			total += 1
			test.failures.clear()
			# a test can await signals (a frame, a git job)
			await test.call(method.name)
			test.cleanup()
			if not test.failures.is_empty():
				failed += 1
				print("FAIL %s::%s" % [file, method.name])
				for failure in test.failures:
					print("  " + failure.replace("\n", "\n  "))

	DirAccess.remove_absolute(OS.get_temp_dir().path_join("godit_test_gitconfig_%d" % OS.get_process_id()))
	for file in DirAccess.get_files_at(_user_dir):
		DirAccess.remove_absolute(_user_dir.path_join(file))
	DirAccess.remove_absolute(_user_dir)
	print("%d tests, %d failed" % [total, failed])
	quit(1 if failed > 0 else 0)

func _isolate_user_data() -> void:
	DirAccess.make_dir_recursive_absolute(_user_dir)
	Settings.local_path_override = _user_dir.path_join("settings.cfg")
	Settings.global_path_override = _user_dir.path_join("global_settings.cfg")
	Settings.project_file_override = _user_dir.path_join("project.godot")
	ChangelistStore.path_override = _user_dir.path_join("changelists.cfg")

func _test_files() -> PackedStringArray:
	var files := PackedStringArray()
	for file in DirAccess.get_files_at(TESTS_DIR):
		if file.begins_with("test_") and file.ends_with(".gd"):
			files.append(file)
	files.sort()
	return files
