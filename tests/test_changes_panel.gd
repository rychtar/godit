extends "res://tests/assertions.gd"

const ChangesPanel = preload("res://addons/godit/dock/panels/changes_panel.gd")
const ChangesPanelScene = preload("res://addons/godit/dock/panels/changes_panel.tscn")

func test_ignore_rules() -> void:
	check("a file is anchored to the root", ChangesPanel.ignore_rule("icon.png"), "/icon.png")
	check("a folder keeps its slash", ChangesPanel.ignore_rule("build/"), "/build/")
	check("glob characters are escaped", ChangesPanel.ignore_rule("art/a[1]*?.png"), "/art/a\\[1]\\*\\?.png")
	check("a backslash is escaped", ChangesPanel.ignore_rule("a\\b"), "/a\\\\b")
	check("# and ! are plain after the slash", ChangesPanel.ignore_rule("#notes!"), "/#notes!")
	check("trailing spaces are kept", ChangesPanel.ignore_rule("notes  "), "/notes\\ \\ ")

func test_ignore_rules_match_only_their_path() -> void:
	var root := make_repo().get_repo_root()
	var paths := ["icon.png", "sub/icon.png", "build/x.txt", "sub/build/x.txt", "a[1].png", "a1.png", "#notes.txt", "!bang.txt"]
	for path in paths:
		write_file(root.path_join(path), "x")
	var ignored := ["icon.png", "build/", "a[1].png", "#notes.txt", "!bang.txt"]
	write_file(root.path_join(".gitignore"), "\n".join(ignored.map(func(path: String) -> String: return ChangesPanel.ignore_rule(path))) + "\n")
	check("only the paths themselves are ignored", Array(git(root, ["check-ignore", "--"] + paths).split("\n")), ["icon.png", "build/x.txt", "a[1].png", "#notes.txt", "!bang.txt"])

func test_ignoring_adds_each_rule_once_in_the_files_line_endings() -> void:
	var repo := make_repo()
	var gitignore := repo.get_repo_root().path_join(".gitignore")
	write_file(gitignore, "/icon.png\r\n*.tmp")
	var panel := await _panel(repo)
	panel._ignore_paths(["icon.png", "build/", "build/"])
	check("appended", read_file(gitignore), "/icon.png\r\n*.tmp\r\n/build/\r\n")

func test_a_right_click_on_a_folder_or_changelist_row_opens_its_menu() -> void:
	var repo := make_repo()
	commit_file(repo, "art/old.png", "x", "first")
	write_file(repo.get_repo_root().path_join("art/old.png"), "y")
	var panel := await _panel(repo)
	var folder := _find_row(panel._tree.get_root(), "folder")
	await _right_click(panel, folder)
	check("folder menu", [panel._context_menu.visible, panel._context_target.get("kind"), panel._context_target.get("dir")], [true, "folder", "art"])
	panel._context_menu.hide()
	await tree.process_frame
	await _right_click(panel, _find_row(panel._tree.get_root(), "changelist_group"))
	check("changelist menu", [panel._context_menu.visible, panel._context_target.get("kind")], [true, "changelist_group"])

func test_space_stages_and_unstages_the_selected_files() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.txt", "1\n", "first")
	commit_file(repo, "b.txt", "1\n", "second")
	write_file(root.path_join("a.txt"), "2\n")
	write_file(root.path_join("b.txt"), "2\n")
	write_file(root.path_join("new.txt"), "x\n")
	var panel := await _panel(repo)
	check("staged in the active changelist", git(root, ["diff", "--cached", "--name-only"]), "a.txt\nb.txt")
	_select(panel, ["a.txt", "b.txt"])
	await _press(panel, KEY_SPACE)
	check("all staged: unstaged", git(root, ["diff", "--cached", "--name-only"]), "")
	_select(panel, ["a.txt", "new.txt"])
	await _press(panel, KEY_SPACE)
	check("staged, the new file added", git(root, ["diff", "--cached", "--name-only"]), "a.txt\nnew.txt")

func test_delete_asks_before_reverting_and_ctrl_c_copies_paths() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.txt", "1\n", "first")
	commit_file(repo, "b.txt", "1\n", "second")
	write_file(root.path_join("a.txt"), "2\n")
	write_file(root.path_join("b.txt"), "2\n")
	var panel := await _panel(repo)
	_select(panel, ["a.txt"])
	await _press(panel, KEY_DELETE)
	check("asked", [panel._revert_confirm_dialog.visible, panel._context_target.get("path")], [true, "a.txt"])
	check_contains("about that file", panel._revert_confirm_dialog.dialog_text, "\"a.txt\"")
	panel._revert_confirm_dialog.hide()
	check("nothing reverted yet", read_file(root.path_join("a.txt")), "2\n")
	_select(panel, ["a.txt", "b.txt"])
	await _press(panel, KEY_C, true)
	check("copied", panel._status_label.text, "Copied 2 paths.")

func test_the_filter_shows_matching_files_and_keeps_the_count() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.txt", "1\n", "first")
	commit_file(repo, "art/b.png", "1\n", "second")
	write_file(root.path_join("a.txt"), "2\n")
	write_file(root.path_join("art/b.png"), "2\n")
	var panel := await _panel(repo)
	panel._commit_message.text = "Update"
	panel._filter.text = "ART"
	panel._filter.text_changed.emit("ART")
	await tree.create_timer(ChangesPanel.FILTER_DELAY + 0.1).timeout
	check("only the match, in any letter case", _shown_paths(panel), ["art/b.png"])
	check("the dock title still counts every change", panel.change_count, 2)
	check_contains("the changelist says what's hidden", _find_row(panel._tree.get_root(), "changelist_group").get_text(ChangesPanel.TEXT_COLUMN), "1 of 2 files")
	check("its menu counts every file", panel._changelist_option.get_item_text(0), "Changelist: Default  (2)")
	check("commit still takes what's staged", panel._commit_button.disabled, false)
	panel._filter.text = "zzz"
	panel.refresh(panel._last_entries)
	check("no match", _shown_paths(panel), [])
	check("says so", panel._status_label.text, "No changed file matches \"zzz\".")
	panel.reveal("a.txt", 1)
	check("revealing a hidden file clears the filter", [panel._filter.text, panel._tree.get_selected().get_metadata(0)["path"]], ["", "a.txt"])

func test_esc_clears_the_filter_and_down_goes_to_the_first_file() -> void:
	var repo := make_repo()
	var root := repo.get_repo_root()
	commit_file(repo, "a.txt", "1\n", "first")
	write_file(root.path_join("a.txt"), "2\n")
	var panel := await _panel(repo)
	panel._tree.deselect_all()
	panel._filter.grab_focus()
	panel._filter.text = "a"
	await _key(KEY_ESCAPE)
	check("cleared", panel._filter.text, "")
	await tree.create_timer(ChangesPanel.FILTER_DELAY + 0.1).timeout # the list rebuilds after the pause
	await _key(KEY_DOWN)
	check("the list has focus", panel._tree.has_focus(), true)
	check("on the first file", panel._tree.get_selected().get_metadata(0)["path"], "a.txt")
	await _key(KEY_F, true)
	check("Ctrl/Cmd+F goes back to the filter", panel._filter.has_focus(), true)

func _select(panel: Control, paths: Array) -> void:
	panel._tree.deselect_all()
	for path: String in paths:
		panel._find_item_by_path(panel._tree.get_root(), path).select(ChangesPanel.TEXT_COLUMN)

func _shown_paths(panel: Control) -> Array:
	var out: Array = []
	var item: TreeItem = panel._tree.get_root()
	while item != null:
		if item.get_metadata(0) is Dictionary and item.get_metadata(0).has("path") and item.is_visible_in_tree():
			out.append(item.get_metadata(0)["path"])
		item = item.get_next_in_tree()
	return out

func _press(panel: Control, keycode: Key, command := false) -> void:
	panel._tree.grab_focus()
	await _key(keycode, command)

# a key press and release to whatever has focus, then the deferred refresh
func _key(keycode: Key, command := false) -> void:
	for pressed in [true, false]:
		var key := InputEventKey.new()
		key.keycode = keycode
		key.pressed = pressed
		if OS.get_name() == "macOS":
			key.meta_pressed = command
		else:
			key.ctrl_pressed = command
		tree.root.push_input(key)
	await tree.process_frame
	await tree.process_frame

func _panel(repo: GitCliRepo) -> Control:
	await tree.process_frame # the root isn't in the tree yet while the runner starts
	var panel: Control = track(ChangesPanelScene.instantiate())
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.size = Vector2(900, 600) # the headless window has no size to fill
	tree.root.add_child(panel)
	panel.set_repo(repo)
	await tree.process_frame
	await tree.process_frame
	return panel

func _find_row(item: TreeItem, kind: String) -> TreeItem:
	for child in item.get_children():
		if child.get_metadata(0) is Dictionary and child.get_metadata(0).get("kind", "") == kind:
			return child
		var found := _find_row(child, kind)
		if found != null:
			return found
	return null

func _right_click(panel: Control, item: TreeItem) -> void:
	var at: Vector2 = panel._tree.global_position + panel._tree.get_item_area_rect(item, ChangesPanel.TEXT_COLUMN).get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	tree.root.push_input(motion)
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_RIGHT
		click.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		click.pressed = pressed
		click.position = at
		click.global_position = at
		tree.root.push_input(click)
		await tree.process_frame
