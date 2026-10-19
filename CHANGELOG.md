# Changelog

## 1.4.0 - 2026-10-19

### Highlights

- **Local History**: Godit keeps snapshots of your files as you save, every few minutes and before a git operation rewrites them, so a script or scene can go back to how it was an hour ago, even if you never committed it. Right-click a file or folder > Git: Local History…. No commits, and git status stays as it is.
- **Godit Settings**: every option in one window like the editor's own settings, kept for all your projects.
- **⇅ Sync**: one button fetches, pulls and pushes, and switching branches takes your uncommitted changes along.
- **From anywhere in the editor**: the current branch in the toolbar, `Alt+C` to commit with the dock closed, every Godit command in the Command Palette, with shortcuts.
- **Check Setup**: finds what keeps git from working for the project (your name, the remote, logging in, line endings, Git LFS) and fixes it or says how.

### Added

- **Local History**: Godit keeps snapshots of the project's files, a few seconds after a save, every 5 minutes and when the editor loses focus if anything changed, and before a pull, checkout, revert or another git operation rewrites them. Right-click a file, a folder or `res://` > Git: Local History… (also in the script editor, Changes, Git Log, Project > Tools > Godit and the Command Palette, "Local History of the Open Scene or Script" and "of the Project") lists the versions with the lines they changed; pick one to compare it with now and Restore This Version. A folder or the whole project lists what differs from now, files deleted since included, filtered by name and grouped by folder if you like, to restore one by one or all at once. Open scenes and scripts reload, and the version you replaced is kept too. Snapshots aren't commits: branches, the index and git status stay as they are, and they live under a hidden ref that `git log --all` and a normal push leave out. They're kept 7 days; files over 5 MB, Git LFS files, ignored files and `.godot/` are left out. Godit Settings > Local History changes that or turns it off.
- **Branch in the toolbar**: the current branch next to the run buttons, with the commits to push (↑) and pull (↓), whichever dock is open. A click, or "Godit: Switch Branch…" in the Command Palette, lists the branches filtered as you type: Enter switches, a remote branch becomes a local one tracking it, New Branch… creates one. Godit Settings > Editor hides it.
- **Quick commit**: `Alt+C`, or "Godit: Commit…" in the Command Palette, opens a small commit window from anywhere, with the dock closed: the changed files with checkboxes (checked = staged, as in File Status), the message and Amend, Commit or Commit and Push. The message is the one in File Status, and the checks before committing are the same.
- **Dock title**: "Godit (5)" counts the changed files, like the editor's "Debugger (2)", and turns yellow while there are commits to pull and red on conflicts, so it shows behind other tabs too. On Godot 4.4 and 4.5 the side Git dock keeps its plain name.
- **Sync**: the ⇅ Sync button (and "Godit: Sync with Remote") fetches, pulls the new commits with your uncommitted changes stashed around it, and pushes yours, so you don't have to know which of the three is due. A branch without an upstream gets published.
- **Switching branches with uncommitted changes**: when they're in the way, Godit offers Stash, Switch, Re-apply and takes them along to the other branch, new files too. If they conflict there, they're also kept in the stash. Works from the toolbar, the sync bar and Branches.
- **Reminders**: a toast when changed files stay uncommitted, or commits stay only on this computer, for 2 hours, and again after as long if they still do. The time counts across editor restarts. Godit Settings > Sync changes it or turns the reminders off.
- **Suggested commit message**: while the message is empty, it suggests one from what's staged ("Update player.gd", "Add enemy.gd and enemy.tscn", "Update 7 files in scenes/"), and Tab takes it, in File Status and the quick commit window.
- **Check Setup**: Tools > Godit > Check Setup… (or "Godit: Check Setup…") checks git, your name for commits, the remote, logging in to it (tried for real, in the background), `.godot/` ignored, line endings, Git LFS and big committed files, each with what's wrong and a fix: set your name and email, add a remote, stop tracking `.godot/`, add the missing lines, track big files with Git LFS, let git use the GitHub CLI's login, or copy your public SSH key and the commands to run. When a fetch, pull or push is refused for the login, "Help Me Log In" opens it.
- **Godit updating itself**: when a checkout, pull, reset or another git operation changes Godit's own files (`addons/godit/` in your repository), Godit offers to restart the editor instead of letting Godot reload the running plugin's scripts, which can lose its state or crash the editor.
- **Command Palette**: every Godit command (`Ctrl/Cmd+Shift+P`, "Godit: …"): show File Status, History, Branches or Console, Commit, Fetch All Remotes, Pull Current Branch, Push Current Branch, Switch Branch, the three layouts, Toggle Sidebar, Toggle Blame, Settings, and the history of the open scene or script.
- **Shortcuts**: `Ctrl/Cmd+1` to `4` open File Status, History, Branches and Console in any layout (by the key's place, so they work on layouts where the digits need Shift), `Alt+G` shows or hides the Godit dock like `Alt+O` the Output. On Godot 4.5+ they're in Editor Settings > Shortcuts > Godit, where the other commands can get keys too.
- **Keys in File Status**: `Space` stages or unstages the selected files (new files are added), `Delete` or `Ctrl/Cmd+Backspace` reverts them after asking, `Ctrl/Cmd+C` copies their paths, `Ctrl/Cmd+F` goes to the filter.
- **Filter in File Status**: next to the changelist, it shows only the files whose path contains what you type. `Esc` clears it, `Down` or `Enter` goes to the first file. Conflicts always show, the dock title still counts every change, and Commit takes every checked file, shown or not.
- **Show in FileSystem** in the right-click menu of files and folders in Changes and of files in Git Log: selects it in the FileSystem dock, or the nearest folder when the file is gone.
- **Layout menu** in the combined dock's toolbar and in the tab bars of the Git dock, Git Log and the bottom tabs; switching shows where the panels went.
- **Combined dock**: the toolbar button hides the sidebar (remembered); the view buttons move into the toolbar and Branches becomes a view.
- Dividers remember where they were dragged, across resizes and restarts: Changes list and diff, Git Log graph, details and file diff, the combined dock's sidebar.
- **Godit Settings**: a window like Godot's Editor Settings, from Tools > Godit > Settings…, the docks' ⋮ menu or "Godit: Settings…" in the Command Palette: the sections on the left, the chosen one's options on the right with a line on what each does and Reset, and a filter that narrows both. Background fetch and auto-save get their intervals there.

### Changed

- Revert and Remove in Changes and Restore File in Git Log say Local History keeps the current version, instead of "This can't be undone", while it's on.
- Preferences are kept for all projects (`godit_settings.cfg` next to the editor's own settings) instead of per project: the layout, the Godit tab, diff options, History columns, blame, the Inspector rows, auto-stage and auto-add, confirmations and the sync options. A value an earlier version saved in a project still applies there until it's changed. The auto-add ignore masks are saved in `project.godot`, so the team shares them. The open view, divider positions and Git Log's Remotes/Stashes filters stay per project.
- Project > Tools > Godit holds Settings…, Check Setup… and Local History of the Project…; the switches and the layout are in Godit Settings (blame also in the script editor's menu, the layout also in the docks' menus).
- A diff option changed in one diff applies to every open diff.
- The Godit tab is off by default; Godit Settings > Layout turns it on. While it's open, a file clicked in Changes or Git Log shows its diff there.
- The Godit tab, opened before any file is selected, says how to get a diff there instead of "No diff to show."

### Fixed

- Fetch/Pull/Push didn't turn into icons after switching to a layout with a narrow Git dock, or with longer translated labels: the bar held the panel wider than the dock, which cut it off on both sides.
- In an editor set to another language, Godit was half translated: the editor's own catalog translated the words it happens to have (in Czech Fetch became "Stáhnout změny", Amend "Doplnit", History "Historie", Revert, Cancel and dialog titles too) and left the rest in English. Godit's docks, the Godit tab, its dialogs, menus, tooltips, the Inspector rows and the change preview stay in English now.
- Editor Settings > Shortcuts > Godit showed Fetch, Pull and Push translated in a non-English editor; the commands are called Fetch All Remotes, Pull Current Branch and Push Current Branch now (in the Command Palette too), which the editor doesn't translate.

## 1.3.0 - 2026-10-18

### Added

- **Godit tab**: the expand button in a diff (Changes, Git Log) shows it full size in a Godit tab next to 2D, 3D and Script; opening the tab shows the Changes diff. Staging hunks and lines, the diff options and double-click to open work there as in the panel, and leaving the tab puts the diff back. Tools > Godit can turn the tab off.
- **Script editor**: the changed words of a changed line are highlighted, compared with the line it most likely came from, and recomputed after a short pause in typing.
- **Inspector**: a property of a node or `.tres` that changed since the last commit gets a "Last commit" row with the old value and Revert (undoable); a node added since then is marked.
- **Scene dock**: nodes of the edited scene added or changed since the last commit are colored green or yellow (comparing the saved scene). Tools > Godit turns this and the Inspector rows off.
- **Commit check**: before committing, staged scenes, resources, scripts and `project.godot` are searched for `res://` (and `uid://`) references to files the commit won't contain: not added to git, deleted, or in git with different letter case (works on Windows and macOS, breaks on Linux). "Add and Commit" adds the ones that exist. Ignored files are left out.
- **Image diff**: besides side by side, Swipe (drag a line between Before and After) and Onion Skin (fade After over Before), both over a checkerboard.
- **Git Log**: Interactive Rebase from Here reorders, rewords, squashes, fixes up or drops the commit and the newer ones in one dialog. Open This Version opens a scene or resource as it was in a commit, from a copy in `.godot` (saving it changes nothing).
- **Console**: error dialogs offer Show in Console when a git command just failed. The console asks before `reset --hard`, `clean`, force or delete pushes, `branch -D`, `stash drop/clear`, discarding checkouts and restores, `config --global` writes and shell aliases, and saves open files before commands that change them.
- **FileSystem dock**: changed files show git's letter (M, A, D, R, ?, !) next to the name.
- **Narrow docks**: Changes works in a side dock down to 200 px: its rows wrap, the diff is left out below 480 px ("Show Diff in the Godit Tab" in the file menu), and Fetch/Pull/Push shrink to icons.
- The tests run on Windows and macOS too (Godot 4.4 and 4.7), and on Linux with every minor version from 4.4 to 4.7.

### Changed

- Git Log: Reword and Fixup are one Edit Commit… dialog: a new message and the staged changes folded in, in one rewrite.

### Fixed

- Changes: right-clicking a folder, a changelist or New Files did nothing, so their menus (Ignore Folder, Add New Files, Rename, Shelve…) never opened. Right-clicking a checkbox opens its file's menu too.
- Ignore wrote the path as a pattern: ignoring `icon.png` at the top also ignored every `icon.png` in subfolders, `build/` every `build` folder, and `[`, `*` or `?` in a name made a wildcard. Rules are anchored to the repository root (`/icon.png`) and escaped now, and a `.gitignore` with CRLF line endings keeps them without duplicates.
- Diff view: lines indented with tabs showed no indentation.

## 1.2.0 - 2026-10-02

### Added

- Tests (a headless runner and 100+ tests) and a GitHub Actions workflow that runs them on Godot 4.4.1 and 4.7.1. Neither is part of the addon package.

### Fixed

- Every background git job (fetch, pull, push, blame, history search) leaked its thread, mutex and two regexes: the job and its thread, and the job and its own `finished` listener, held each other.
- Staging a hunk, the script gutter and blame silently did nothing when the cache folder (`~/.cache` on Linux) didn't exist yet. Their temp files go to a `godit` folder in it, which is created.
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
- Every pull, checkout or stash reloaded all open scenes, even those it didn't touch (losing their undo history), and a pull that brought nothing did too. Only scenes whose file changed on disk are reloaded now.
- A failed `git status` (empty output) cleared the changelist assignments of all files.
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
