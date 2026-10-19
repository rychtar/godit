extends "res://tests/assertions.gd"

const GitErrors = preload("res://addons/godit/util/git_errors.gd")

func test_classify() -> void:
	check("no upstream", GitErrors.classify("fatal: The current branch x has no upstream branch."), GitErrors.NO_UPSTREAM)
	check("rejected push", GitErrors.classify(" ! [rejected]  main -> main (non-fast-forward)"), GitErrors.NON_FAST_FORWARD)
	check("fetch first", GitErrors.classify("hint: Updates were rejected ... (fetch first)"), GitErrors.NON_FAST_FORWARD)
	check("divergent branches", GitErrors.classify("fatal: Need to specify how to reconcile divergent branches."), GitErrors.DIVERGED)
	check("host key", GitErrors.classify("Host key verification failed."), GitErrors.HOST_KEY)
	check("permission denied", GitErrors.classify("git@github.com: Permission denied (publickey)."), GitErrors.AUTH)
	check("no prompt possible", GitErrors.classify("fatal: could not read Username: terminal prompts disabled"), GitErrors.AUTH)
	check("conflict", GitErrors.classify("CONFLICT (content): ...\nAutomatic merge failed; fix conflicts and then commit"), GitErrors.CONFLICT)
	check("dirty tree", GitErrors.classify("error: Your local changes to the following files would be overwritten by merge"), GitErrors.DIRTY)
	check("no remote", GitErrors.classify("fatal: No configured push destination."), GitErrors.NO_REMOTE)
	check("anything else", GitErrors.classify("something unexpected"), "")

func test_explain_keeps_git_s_own_text() -> void:
	var text := "fatal: The current branch x has no upstream branch."
	var explained := GitErrors.explain(text)
	check_contains("hint", explained, "isn't tracking a remote branch")
	check_contains("original text", explained, text)
	check("unknown errors are untouched", GitErrors.explain("boom"), "boom")
