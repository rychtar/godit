extends "res://tests/assertions.gd"

const SceneText = preload("res://addons/godit/util/scene_text.gd")

const SCENE := "[gd_scene load_steps=3 format=3 uid=\"uid://abc\"]\n\n[ext_resource type=\"Script\" path=\"res://a.gd\" id=\"1_aaa\"]\n[ext_resource type=\"Texture2D\" path=\"res://t.png\" id=\"2_bbb\"]\n\n[sub_resource type=\"RectangleShape2D\" id=\"Rect_1\"]\nsize = Vector2(10, 10)\n\n[node name=\"Root\" type=\"Node2D\"]\nscript = ExtResource(\"1_aaa\")\n\n[node name=\"Spr\" type=\"Sprite2D\" parent=\".\"]\ntexture = ExtResource(\"2_bbb\")\nposition = Vector2(1, 2)\n\n[connection signal=\"ready\" from=\"Spr\" to=\".\" method=\"_on_ready\"]\n"

func test_parse_a_scene() -> void:
	var parsed := SceneText.parse(SCENE)
	check("nodes", parsed.node_order, ["Root", "Root/Spr"])
	check("node type", parsed.nodes["Root/Spr"].type, "Sprite2D")
	check("ext resources are resolved to their path", parsed.nodes["Root"].props.script, "ExtResource(\"res://a.gd\")")
	check("ext resources", parsed.ext["2_bbb"].path, "res://t.png")
	check("sub resources", parsed.sub["Rect_1"].props.size, "Vector2(10, 10)")
	check("connections", parsed.connections, ["Root/Spr.ready → _on_ready() on Root"])

func test_parse_sections_and_multiline_values() -> void:
	var sections := SceneText.parse_sections("[node name=\"A\" type=\"Label\"]\ntext = \"line one\nline two\"\narr = [1,\n2]\n\n[node name=\"B\" type=\"Node\" parent=\".\"]\n")
	check("two sections", sections.size(), 2)
	check("attributes", [sections[0].attrs.name, sections[0].attrs.type], ["A", "Label"])
	check("a string over two lines", sections[0].props.text, "\"line one\nline two\"")
	check("an array over two lines", sections[0].props.arr, "[1,\n2]")
	check("raw attributes keep quotes", sections[0].raw_attrs.name, "\"A\"")

func test_attributes_with_brackets_and_quotes() -> void:
	var attrs := SceneText._parse_attributes("name=\"A B\" groups=[\"x\", \"y z\"] instance=ExtResource(\"1_a\")")
	check("a quoted name with a space", attrs.name, "A B")
	check("a list", attrs.groups, "[\"x\", \"y z\"]")
	check("a call", attrs.instance, "ExtResource(\"1_a\")")

func test_diff_ignores_renumbered_ids_and_noise() -> void:
	var renumbered := SCENE.replace("1_aaa", "9_zzz").replace("load_steps=3", "load_steps=4").replace("uid://abc", "uid://def")
	var diff := SceneText.diff(SCENE, renumbered)
	check("no node changes", diff.nodes.size(), 0)
	check("no resource changes", diff.resources.size(), 0)

func test_diff_reports_changes() -> void:
	var changed := SCENE.replace("position = Vector2(1, 2)", "position = Vector2(5, 2)") + "\n[node name=\"Kid\" type=\"Node\" parent=\"Spr\"]\n"
	var diff := SceneText.diff(SCENE, changed)
	check("two nodes", diff.nodes.map(func(n: Dictionary) -> String: return n.path + ":" + n.status), ["Root/Spr:changed", "Root/Spr/Kid:added"])
	var change: Dictionary = diff.nodes[0].props[0]
	check("the property", [change.key, change.old, change.new], ["position", "Vector2(1, 2)", "Vector2(5, 2)"])
	var removed := SceneText.diff(SCENE, SCENE.replace("\n[connection signal=\"ready\" from=\"Spr\" to=\".\" method=\"_on_ready\"]\n", ""))
	check("a removed connection", removed.connections_removed, ["Root/Spr.ready → _on_ready() on Root"])

func test_scene_and_config_files() -> void:
	check("scenes", [SceneText.is_scene_file("a.tscn"), SceneText.is_scene_file("a.TRES"), SceneText.is_scene_file("a.gd")], [true, true, false])
	check("config", [SceneText.is_config_file("project.godot"), SceneText.is_config_file("x.import"), SceneText.is_config_file("a.tscn")], [true, true, false])

func test_config_diff() -> void:
	var old := "config_version=5\n\n[application]\n\nconfig/name=\"A\"\nrun/main_scene=\"res://a.tscn\"\n\n[display]\n\nwindow/size/viewport_width=640\n"
	var new := "config_version=5\n\n[application]\n\nconfig/name=\"B\"\nrun/main_scene=\"res://a.tscn\"\n\n[rendering]\n\nx=1\n"
	var diff := SceneText.config_diff(old, new)
	check("sections", diff.nodes.map(func(n: Dictionary) -> String: return n.path + ":" + n.status), ["[application]:changed", "[rendering]:added", "[display]:removed"])
	check("the changed setting", [diff.nodes[0].props[0].key, diff.nodes[0].props[0].old, diff.nodes[0].props[0].new], ["config/name", "\"A\"", "\"B\""])

func test_input_actions_are_readable() -> void:
	var text := "[input]\n\njump={\n\"deadzone\": 0.2,\n\"events\": [Object(InputEventKey,\"resource_local_to_scene\":false,\"ctrl_pressed\":true,\"keycode\":0,\"physical_keycode\":83,\"echo\":false), Object(InputEventJoypadButton,\"button_index\":0,\"pressed\":false)]\n}\n"
	var parsed := SceneText.parse_config(text)
	check("the raw value is kept", parsed.input.jump.begins_with("{"), true)
	var readable := SceneText._readable_config("input", parsed.input)
	check("shortened", readable.jump, "deadzone 0.2: Ctrl+S, Joypad button 0")
