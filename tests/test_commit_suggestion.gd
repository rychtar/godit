extends "res://tests/assertions.gd"

const CommitSuggestion = preload("res://addons/godit/util/commit_suggestion.gd")
const F = preload("res://addons/godit/util/git_status_flags.gd")

func _e(path: String, status: int, renamed_from := "") -> Dictionary:
	return {"path": path, "status": status, "renamed_from": renamed_from}

func test_names_a_few_files() -> void:
	check("one", CommitSuggestion.suggest([_e("scripts/player.gd", F.INDEX_MODIFIED)]), "Update player.gd")
	check("a new file with its .uid", CommitSuggestion.suggest([_e("enemy.gd", F.INDEX_NEW), _e("enemy.gd.uid", F.INDEX_NEW), _e("enemy.tscn", F.INDEX_NEW)]), "Add enemy.gd and enemy.tscn")
	check("verbs mixed", CommitSuggestion.suggest([_e("old.png", F.INDEX_DELETED), _e("player.gd", F.INDEX_MODIFIED)]), "Update player.gd, delete old.png")
	check("a rename", CommitSuggestion.suggest([_e("b.gd", F.INDEX_RENAMED, "a.gd")]), "Rename a.gd to b.gd")

func test_counts_many_files() -> void:
	var same := [_e("scenes/a.tscn", F.INDEX_MODIFIED), _e("scenes/levels/b.tscn", F.INDEX_MODIFIED), _e("scenes/c.tscn", F.INDEX_MODIFIED), _e("scenes/levels/d.tscn", F.INDEX_MODIFIED)]
	check("one verb, their folder", CommitSuggestion.suggest(same), "Update 4 files in scenes/")
	var mixed := [_e("a.gd", F.INDEX_NEW), _e("b.gd", F.INDEX_MODIFIED), _e("c.gd", F.INDEX_DELETED), _e("d/e.gd", F.INDEX_MODIFIED)]
	check("mixed, no common folder", CommitSuggestion.suggest(mixed), "Change 4 files")

func test_only_what_is_staged() -> void:
	check("unstaged and untracked", CommitSuggestion.suggest([_e("a.gd", F.WT_MODIFIED), _e("b.gd", F.WT_NEW)]), "")
	check("partly staged counts", CommitSuggestion.suggest([_e("a.gd", F.INDEX_MODIFIED | F.WT_MODIFIED), _e("b.gd", F.WT_MODIFIED)]), "Update a.gd")
