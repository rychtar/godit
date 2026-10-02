# Changelog

## 1.1.1 - 2026-10-02

### Fixed

- Staging or unstaging a hunk failed when the git config has `diff.noprefix` or `diff.mnemonicPrefix`. Diffs now always use `a/` and `b/` prefixes.
- Reword and Fixup in Git Log flattened merge commits that came after the commit. They are disabled in that case, and a rebase that fails drops its helper `amend!`/`fixup!` commit.
- Reverting a staged rename deleted the file from disk. The old file is restored too.
- Fetch, pull and push ignored `core.sshCommand`. It is kept now and only extended with `-o BatchMode=yes`.
- Scene conflicts: `ext_resource` ids that differ between the two sides showed up as a conflict, e.g. when both sides add the same resource.
- Conflict resolver: choosing a side with no lines left a blank line behind.
- Script editor: a file added to git (every new file, with auto-add on) had no change markers in the gutter.
- Git Log: double-clicking a diff line in a `.md`, `.json` or other text file failed instead of opening it at that line.
- The Auto-save option overwrote your own autosave interval in Editor Settings. It is put back when the option is switched off.
- Branches: double-clicking a section, a remote or the current branch asked to save open files for nothing.
- Changes: a file name containing ` -> ` was read as a rename.
- Projects reached through a symlink: the repository root now keeps the spelling of the path it was opened with.
- "Changes/Branches at the bottom" layout in a project without a repository showed empty tabs instead of "Initialize Repository".
- Resolvers, `.gitignore` edits and temporary diff files report a failed write instead of ignoring it.
- The watcher no longer creates a timer outside a git repository.

- Godit didn't load on Godot 4.4-4.6: saving open files before git operations used methods that only exist from 4.7. Older versions offer to save scripts and text files only; unsaved scenes can't be listed there.
- The gutter and conflict diffs broke when `diff.external` is set in the git config.
- Conflict resolver: choosing a side that is a single blank line removed it.
- `log.showSignature` in the git config put gpg lines into the History.
- The FileSystem dock's right-click menu ran `git status` on the spot, which was slow in big projects. It uses the last status now.

### Changed

- "Push with Tags" is now "Push with Annotated Tags", which is what `--follow-tags` does. A lightweight tag is pushed from Branches (right-click, Push Tag).
- The scene conflict resolver names its columns "branch rebased onto" and "your commit being replayed" during a rebase, where the sides swap.
- Initialize Repository looks up the GitHub CLI and makes the first commit in the background, so a big project doesn't freeze the editor.
- Removed unused code (`DiffHunks.classify_lines`, `get_diff_against_head`).

## 1.1.0 - 2026-09-26

### Added

- **Combined dock**: changes, history, branches and console in one SourceTree-like dock with a toolbar and sidebar. It is the default layout, starts in the bottom panel and on Godot 4.6+ can be moved to a side dock or floated.
- **Scene view** for `.tscn`/`.tres` diffs: added and removed nodes, changed properties, signal connections.
- **Node-by-node scene merge**: changes on one side merge on their own, you only choose where both sides changed the same property. A node deleted on one side and given new children on the other is a choice.
- **Settings view** for `project.godot`, `.cfg` and `.import` diffs: changes by section, input actions as readable keys.
- **FileSystem dock**: git status colors (also in the split-mode file list) and Git items in the right-click menu.
- **Web links**: open commits, files, lines and branches on GitHub, GitLab or Bitbucket, and start a pull request.
- **Git Log**: an "Uncommitted changes" row with commit, stash and revert; stashes in the graph; drag and drop to cherry-pick, merge or rebase; an Undo button for the last commit, checkout, merge, pull, rebase or reset.
- **Initialize Repository** from the dock, with Godot's `.gitignore` and `.gitattributes`, optional Git LFS and publish to GitHub.
- Unsaved scenes and scripts are saved (after asking) before commit, checkout, pull and other git operations.
- A warning before committing large files, with Git LFS or ignore as the fix.
- Recent commit messages: Up/Down in an empty message box and a History button.
- A toast when the background fetch brings new commits, and a warning (in Changes and in the toast) when they change files you changed too.
- Tools > Godit: faster `git status` for large projects, using git's file system monitor and untracked cache.
- Script editor: change gutter, blame and the Git menu items also work in text file tabs (`.md`, `.json`...).
- Branches: messages show in the combined toolbar next to Fetch/Pull/Push.

### Changed

- `.uid` and `.import` files follow their file: nested under it in Changes, staged, reverted, stashed and ignored together. `.import` is no longer skipped by auto-add.
- One watcher runs `git status` and the refs for every panel on a worker thread every 10 seconds; saves and refocusing the editor still poll right away. `git status` doesn't take `index.lock`, so it doesn't get in the way of git in a terminal.
- Reverting a file refreshes its open script or text tab too, including one with unsaved edits.
- Git commands run without a shell and read quoted paths: commit messages with quotes work, files with spaces or diacritics can be staged, and `$()` in a name or message is never executed.
- Addon packaging: LICENSE and README are included in `addons/godit`, and only the addons folder is exported.

### Fixed

- Git Log: the graph redraws when its viewport grows (rows below the old height stayed blank).
- A missing settings key no longer logs an error when the default is null.

## 1.0.0 - 2026-09-25

First release.

- **Changes panel**: stage files, folders or single lines with a checkbox, then commit or push.
- **Changelists**: group changes and commit or shelve them separately; changes are staged and new files added automatically in the active changelist.
- **Diff view**: side by side or unified, with syntax colors and image previews.
- **Branches**: switch, merge and rebase; fetch, pull and push run in the background.
- **Git Log**: commit graph with search, cherry-pick and history editing.
- **Conflict resolver**: pick Ours, Theirs or both, side by side.
- **Script editor**: changed lines in the gutter with one-click rollback, plus optional blame.
