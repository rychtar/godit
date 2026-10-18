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
