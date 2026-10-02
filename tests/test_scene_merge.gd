extends "res://tests/assertions.gd"

const SceneMerge = preload("res://addons/godit/util/scene_merge.gd")

const HEADER := "[gd_scene load_steps=2 format=3 uid=\"uid://abc\"]\n\n"
const BASE := HEADER + "[ext_resource type=\"Script\" path=\"res://a.gd\" id=\"1_aaa\"]\n\n[node name=\"Root\" type=\"Node2D\"]\nscript = ExtResource(\"1_aaa\")\n\n[node name=\"Spr\" type=\"Sprite2D\" parent=\".\"]\nposition = Vector2(0, 0)\nvisible = true\n"

func _conflict_labels(result: Dictionary) -> Array:
	return result.conflicts.map(func(c: Dictionary) -> String: return "%s %s" % [c.label, c.prop])

func test_changes_on_different_properties_merge_on_their_own() -> void:
	var ours := BASE.replace("Vector2(0, 0)", "Vector2(5, 5)")
	var theirs := BASE.replace("visible = true", "visible = false")
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("ok", result.ok, true)
	check("no conflicts", result.conflicts.size(), 0)
	var merged := SceneMerge.result_text(result, {})
	check_contains("our change", merged, "position = Vector2(5, 5)")
	check_contains("their change", merged, "visible = false")

func test_the_same_property_changed_differently_is_a_conflict() -> void:
	var ours := BASE.replace("Vector2(0, 0)", "Vector2(5, 5)")
	var theirs := BASE.replace("Vector2(0, 0)", "Vector2(9, 9)")
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("one conflict", _conflict_labels(result), ["Root/Spr position"])
	check("ours by default", SceneMerge.result_text(result, {}).contains("Vector2(5, 5)"), true)
	var theirs_text := SceneMerge.result_text(result, { 0: "theirs" })
	check_contains("theirs when chosen", theirs_text, "Vector2(9, 9)")
	check("and only theirs", theirs_text.contains("Vector2(5, 5)"), false)

func test_the_same_change_on_both_sides_is_not_a_conflict() -> void:
	var both := BASE.replace("Vector2(0, 0)", "Vector2(5, 5)")
	check("no conflicts", SceneMerge.merge(BASE, both, both).conflicts.size(), 0)

func test_both_sides_adding_the_same_resource_with_different_ids() -> void:
	var ours := BASE.replace("\n[node name=\"Root\"", "[ext_resource type=\"Texture2D\" path=\"res://t.png\" id=\"2_bbb\"]\n\n[node name=\"Root\"").replace("load_steps=2", "load_steps=3") + "texture = ExtResource(\"2_bbb\")\n"
	var theirs := BASE.replace("\n[node name=\"Root\"", "[ext_resource type=\"Texture2D\" path=\"res://t.png\" id=\"2_zzz\"]\n\n[node name=\"Root\"").replace("load_steps=2", "load_steps=3") + "texture = ExtResource(\"2_zzz\")\n"
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("the id difference is no conflict", result.conflicts.size(), 0)
	var merged := SceneMerge.result_text(result, {})
	check("one texture resource", merged.count("path=\"res://t.png\""), 1)

func test_nodes_added_on_each_side_both_stay() -> void:
	var ours := BASE + "\n[node name=\"Mine\" type=\"Node\" parent=\".\"]\n"
	var theirs := BASE + "\n[node name=\"Theirs\" type=\"Node\" parent=\".\"]\n"
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("no conflicts", result.conflicts.size(), 0)
	var merged := SceneMerge.result_text(result, {})
	check_contains("ours", merged, "[node name=\"Mine\"")
	check_contains("theirs", merged, "[node name=\"Theirs\"")

func test_a_node_deleted_on_one_side_and_edited_on_the_other() -> void:
	var ours := BASE.substr(0, BASE.find("\n[node name=\"Spr\"")) # deleted
	var theirs := BASE.replace("Vector2(0, 0)", "Vector2(9, 9)")
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("a whole-node conflict", _conflict_labels(result), ["Root/Spr "])
	check("keeping ours deletes it", SceneMerge.result_text(result, {}).contains("Spr"), false)
	check_contains("taking theirs brings it back changed", SceneMerge.result_text(result, { 0: "theirs" }), "Vector2(9, 9)")

func test_a_deleted_node_with_new_children_on_the_other_side_is_a_choice() -> void:
	var ours := BASE.substr(0, BASE.find("\n[node name=\"Spr\"")) # deleted
	var theirs := BASE + "\n[node name=\"Kid\" type=\"Node\" parent=\"Spr\"]\n"
	var result := SceneMerge.merge(BASE, ours, theirs)
	check("asks", result.conflicts.size(), 1)
	var dropped := SceneMerge.result_text(result, {})
	check("deleting takes the child along", dropped.contains("Kid"), false)
	check_contains("keeping it keeps the child", SceneMerge.result_text(result, { 0: "theirs" }), "[node name=\"Kid\"")

func test_unreadable_input_is_reported() -> void:
	var result := SceneMerge.merge(BASE, "", BASE)
	check("not ok", result.ok, false)

func test_the_merged_file_is_a_valid_scene_text() -> void:
	var ours := BASE.replace("Vector2(0, 0)", "Vector2(5, 5)")
	var theirs := BASE.replace("visible = true", "visible = false")
	var merged := SceneMerge.result_text(SceneMerge.merge(BASE, ours, theirs), {})
	check("starts with the header", merged.begins_with("[gd_scene "), true)
	check("load_steps follows the resources", merged.contains("load_steps=2"), true)
	check("ends with a newline", merged.ends_with("\n"), true)
	var parsed := SceneText.parse(merged)
	check("both nodes survive", parsed.node_order, ["Root", "Root/Spr"])

const SceneText = preload("res://addons/godit/util/scene_text.gd")
