extends "res://tests/assertions.gd"

const WebLinks = preload("res://addons/godit/util/web_links.gd")

func test_site_for_url() -> void:
	var github := WebLinks.site_for_url("git@github.com:owner/repo.git")
	check("scp style", [github.kind, github.base, github.name], ["github", "https://github.com/owner/repo", "GitHub"])
	check("https with subgroups", WebLinks.site_for_url("https://gitlab.com/group/sub/repo.git").base, "https://gitlab.com/group/sub/repo")
	check("ssh://", WebLinks.site_for_url("ssh://git@bitbucket.org/owner/repo.git").kind, "bitbucket")
	check("credentials are dropped", WebLinks.site_for_url("https://user:secret@github.com/o/r").base, "https://github.com/o/r")
	check("other hosts", WebLinks.site_for_url("https://example.com/o/r.git"), {})
	check("a local path", WebLinks.site_for_url("/home/me/github/repo"), {})
	check("nothing", WebLinks.site_for_url(""), {})

func test_commit_and_file_urls() -> void:
	var github := WebLinks.site_for_url("git@github.com:o/r.git")
	var gitlab := WebLinks.site_for_url("git@gitlab.com:o/r.git")
	var bitbucket := WebLinks.site_for_url("git@bitbucket.org:o/r.git")
	check("github commit", WebLinks.commit_url(github, "abc"), "https://github.com/o/r/commit/abc")
	check("gitlab commit", WebLinks.commit_url(gitlab, "abc"), "https://gitlab.com/o/r/-/commit/abc")
	check("bitbucket commit", WebLinks.commit_url(bitbucket, "abc"), "https://bitbucket.org/o/r/commits/abc")
	check("github line", WebLinks.file_url(github, "main", "scripts/f.gd", 12), "https://github.com/o/r/blob/main/scripts/f.gd#L12")
	check("bitbucket line", WebLinks.file_url(bitbucket, "main", "f.gd", 12), "https://bitbucket.org/o/r/src/main/f.gd#lines-12")
	check("no line", WebLinks.file_url(gitlab, "main", "f.gd"), "https://gitlab.com/o/r/-/blob/main/f.gd")
	check("spaces are encoded", WebLinks.file_url(github, "main", "my dir/f.gd"), "https://github.com/o/r/blob/main/my%20dir/f.gd")

func test_branch_and_pull_request_urls() -> void:
	var github := WebLinks.site_for_url("git@github.com:o/r.git")
	var gitlab := WebLinks.site_for_url("git@gitlab.com:o/r.git")
	var bitbucket := WebLinks.site_for_url("git@bitbucket.org:o/r.git")
	check("github branch", WebLinks.branch_url(github, "feature/x"), "https://github.com/o/r/tree/feature/x")
	check("github pull request", WebLinks.new_pull_request_url(github, "feature/x"), "https://github.com/o/r/compare/feature/x?expand=1")
	check("gitlab merge request", WebLinks.new_pull_request_url(gitlab, "feature/x"), "https://gitlab.com/o/r/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature%2Fx")
	check("bitbucket pull request", WebLinks.new_pull_request_url(bitbucket, "feature/x"), "https://bitbucket.org/o/r/pull-requests/new?source=feature%2Fx")
