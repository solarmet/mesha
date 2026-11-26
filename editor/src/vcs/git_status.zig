//! vcs-git, the editor's git panel: the status of the repository the working directory is in,
//! as a document (`editor/assets/documents/vcs-git.org`, drawn by `editor/src/document/`) over
//! tables and values vcs-git publishes, with the keys of mode `vcs` and the commands of mode
//! `vcs_git`. This file is the panel's system: its tables, how it opens, the refresh and the
//! answers that fill the tables, and what its keys do. The panel's drawing is
//! `git_status_view.zig`'s; the command lines and what git says back are `git.zig`'s; the
//! programs run through `runner.zig`.
//!
//! - What it publishes (`document/sources.zig`), as each answer comes: the sources
//!   `vcs-git.untracked`, `vcs-git.unmerged`, `vcs-git.unstaged` and `vcs-git.staged`, a table
//!   each, a row a file (`FileRow`: the change as a word and the path, shown; the path as git
//!   gave it, a rename's original path and the entry's letters, for the commands), and
//!   `vcs-git.commits`, the recent commits, at most `git.recent_count` (`CommitRow`); the values
//!   `vcs-git.branch`, `vcs-git.head-subject`, `vcs-git.upstream`, `vcs-git.ahead-behind`,
//!   `vcs-git.stashes`, `vcs-git.operation`, `vcs-git.unlisted` (what is counted and not
//!   listed, past `max_entries`) and `vcs-git.clean`, each empty when there is nothing to say
//!   so its line is left out, and the counts the headings say, `vcs-git.untracked-count` and
//!   the three beside it: the files the status counted, listed or not. The source tables are the one
//!   place the status's files are kept: the commands read them. They are written in order
//!   (`table_view.rowsInOrder`), a cell only when what it holds changed.
//! - `global.vcs_git_status` (`C-x g`) shows the panel at the window's right,
//!   gives it the focus and refreshes; invoked while the panel has
//!   the focus it refreshes. `global.vcs_status`, the project menu's `v`, does the same, but
//!   when the status answers that the working directory is in no git repository, or git is not
//!   there, hides vcs-git and shows vcs-p4 (`p4_status.zig`) in its place.
//! - A refresh asks git as few processes as git allows, run together: `status` and `recent`
//!   always; `operation` when `git.InProgress` says (the first refresh, while the last answer
//!   was not none, while the status the panel holds shows conflicts or a detached head, or after
//!   one of the panel's own commands that may start or end one); the repository's root, which
//!   `status` does not tell, once for a working directory; then, when their answers show it is
//!   needed, `operation` (the status shows conflicts or a detached head the panel did not hold)
//!   and `rebase_check` (`operation` read none with the head detached at a commit not checked
//!   yet). A refresh of a clean repository on a branch is two processes; the first for a
//!   project four. No diff is asked by a refresh.
//! - A refresh follows the panel's opening; its taking the focus, except from its own diff
//!   panel; `g`; every command of its own that ends (`refresh`); a buffer saved while the panel
//!   is shown (`followSaves`); the timer's wake (`followTimer`, a quiet refresh); and a change
//!   of project while it is shown, seen as the working directory moves (`followProject`). One
//!   asked while one runs is noted, and runs when it ends, asking for the operation in progress
//!   when any of those noted asked it.
//! - Each job carries the panel's generation, which `C-g` and a change of project move on: an
//!   answer of an earlier generation, or one whose job the runner no longer holds, is released
//!   and dropped.
//! - A job that fails tells `git <subcommand> failed; $ shows why` on the message line, and the
//!   panel keeps what it showed; `$` shows the runner's log of the panel's jobs. A working
//!   directory in no repository, and a git that is not there, show one line in place of the
//!   document and tell nothing.
//! - The keys act on what the document's cursor is on (`document.at`). `RET` on a file of the
//!   unmerged, unstaged or staged table, or on a recent commit, shows its changes in the diff
//!   panel (`git_diff.zig`), at the panel's left; while that panel is open, the person's move of
//!   the cursor onto another file shows that one's (`git_diff.follow`), decided for each move,
//!   never for a cursor a refresh settled. `RET` on an untracked file opens it.
//! - A refresh that rewrote a table keeps the cursor on the same file or commit while it is
//!   still in that table (`document.cursorOnRow`), and the scroll as it was.
//! - The two diffs, the unstaged (`git diff`, for the unmerged and unstaged files) and the
//!   staged (`git diff --cached`), are asked for once each, one process for the whole tree,
//!   when the diff panel first shows a file of their side, and kept until the next status: a
//!   refresh forgets them, and an answer asked before it, and once it ends asks again for the
//!   side the diff panel shows. While a refresh or a command of the panel's runs none is asked:
//!   its end asks. As a diff answers, the panel records where each file's part of its bytes is
//!   (`editor_vcs_git_diff_files`), so the diff panel parses a file's part alone.
//! - Mode `vcs_git`'s keys stage (`s`), unstage (`u`) and discard (`k`) what the cursor is on: a
//!   file's row (`planFile`), or every row of a table on its heading (`planSection`), each in one
//!   process with the paths on its input (a hunk is staged from the diff panel, through the same
//!   commands, its patch on the input); `S` stages the changes of every tracked file, and `U`
//!   unstages every staged one. None runs until the repository's root is known, as the paths are
//!   the root's. A discard asks first, in a dialog, and acts on the row or the heading it was
//!   asked on only when what it would throw away is what the dialog named. A command writes the
//!   index, so it runs alone; each queues behind the one before, and once the last that was
//!   queued ends the panel refreshes, whether it failed or not.
//! - `c` shows the commit menu, and a commit's message is written in a buffer of its own
//!   (`git_commit.zig`); a commit's end refreshes asking for the operation in progress, as a
//!   commit ends a merge.
//! - `l` shows the log menu, which writes the log's query and runs it; the log view is a second
//!   page (`git_log.zig`): the query, which `e` edits, and a table of the commits git gave;
//!   `RET` on one shows it in the diff panel. The views go `status` to `log` or `rebase`, and
//!   `$` from any; `q` goes back one, leaving the rebase list as `C-c C-k` does.
//! - `b` and `m` show the branch and merge menus (`git_branch.zig`, which also owns the prompts
//!   that read a branch, a remote or a new name, and the dialog a command that throws work away
//!   asks first in); `P`, `F` and `f` the push, pull and fetch menus (`git_remote.zig`); `r` the
//!   rebase menu, whose interactive rebase shows its list as a third page (`git_rebase.zig`),
//!   the view `rebase`; `?` the menu of menus, each command's menu opening from it.
//! - A rebase or a merge stopped shows on the operation's line with what to press: for a
//!   rebase, where it stopped (`git.RebaseStop`: on a commit, at a break, on a conflict).
//! - Each page (`page.Page`) keeps its own cursor, scroll, view, folds and `MovedUnder` flag, follows
//!   the panel's size with its own reader, and takes its own messages while its view is shown.
//!
//! Everything the panel keeps is in its tables (`editor_vcs_git` and those beside it), which
//! hold no pointer across frames. The page is laid out anew each run, from those tables, by the
//! kernels that move the cursor and by the draw, which writes nothing.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const process = mesha.process;
const resources = mesha.resources;
const sequencer = mesha.sequencer;
const input = mesha.input;
const ui = mesha.ui;
const outline = mesha.ui.outline;
const diff_widget = mesha.ui.diff;
const keybinds = mesha.keybinds;
const text_editor = plugin.text_editor_api;
const git = @import("git.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const vcs_timer = @import("timer.zig");
const process_log = @import("process_log.zig");
const vcs_ask = @import("ask.zig");
const git_commit = @import("git_commit.zig");
const git_log = @import("git_log.zig");
const git_diff = @import("git_diff.zig");
const git_branch = @import("git_branch.zig");
const git_remote = @import("git_remote.zig");
const git_rebase = @import("git_rebase.zig");
const modes = @import("../modes.zig");
const open = @import("../open.zig");
const transient = @import("../transient.zig");
const action_palette = @import("../action_palette.zig");
const fixed_panels = @import("../fixed_panels.zig");
const table_view = @import("../table_view.zig");
const document = @import("../document/document.zig");
const document_view = @import("../document/view.zig");
const document_sources = @import("../document/sources.zig");
const org = @import("../document/org.zig");

const Log = mesha.log.scope("vcs_git");

/// The status's page, `editor/assets/documents/vcs-git.org`, compiled in.
pub const status_document = @embedFile("vcs_git_document");

// ---- the panel -----------------------------------------------------------------------------

/// The panel's id.
pub const panel_name = "vcs_git";
/// The panel's id, as an atom.
pub const panel = Atom.from(panel_name);
/// The root of the panel's system: its panel draws again when the system changes a table.
pub const vcs_git_root = Atom.from("vcs_git");

/// The panel, a fixed panel `fixed_panels` declares while it is shown: along the right
/// edge of the window.
pub const fixed_panel: plugin.panels.Open = .{ .id = panel, .title = "vcs-git", .root = vcs_git_root, .side = .right, .share = 0.45 };

// ---- the messages, the actions and their keys ------------------------------------------------

/// What the panel's system takes: its actions, the runner's answers, what its drawing sends and
/// the menu's answer.
pub const Msg = enum(u64) {
    /// Shows the panel, or refreshes it while it has the focus.
    vcs_git_status = Atom.from("vcs_git_status").value(),
    /// The project menu's `v`: shows vcs-git in a git repository, else hands over to vcs-p4.
    vcs_status = Atom.from("vcs_status").value(),
    vcs_git_next = Atom.from("vcs_git_next").value(),
    vcs_git_previous = Atom.from("vcs_git_previous").value(),
    vcs_git_next_sibling = Atom.from("vcs_git_next_sibling").value(),
    vcs_git_previous_sibling = Atom.from("vcs_git_previous_sibling").value(),
    vcs_git_parent = Atom.from("vcs_git_parent").value(),
    vcs_git_first = Atom.from("vcs_git_first").value(),
    vcs_git_last = Atom.from("vcs_git_last").value(),
    vcs_git_page_down = Atom.from("vcs_git_page_down").value(),
    vcs_git_page_up = Atom.from("vcs_git_page_up").value(),
    vcs_git_toggle = Atom.from("vcs_git_toggle").value(),
    vcs_git_toggle_all = Atom.from("vcs_git_toggle_all").value(),
    vcs_git_visit = Atom.from("vcs_git_visit").value(),
    vcs_git_refresh = Atom.from("vcs_git_refresh").value(),
    vcs_git_quit = Atom.from("vcs_git_quit").value(),
    vcs_git_process_log = Atom.from("vcs_git_process_log").value(),
    vcs_git_give_up = Atom.from("vcs_git_give_up").value(),
    vcs_git_menu = Atom.from("vcs_git_menu").value(),
    /// The runner's answer, a `runner.Finished`, its user data a `JobData`.
    vcs_git_finished = Atom.from("vcs_git_finished").value(),
    /// A click on a line of the runner's log view, the line's key (`u64`) its user data.
    vcs_git_click = Atom.from("vcs_git_click").value(),
    /// A click on a line's chevron in the runner's log view, the line's key its user data.
    vcs_git_chevron = Atom.from("vcs_git_chevron").value(),
    /// The wheel over the runner's log view, an `input.MouseScrollMsg`.
    vcs_git_wheel = Atom.from("vcs_git_wheel").value(),
    /// A click on a heading or a line of the status's page, a `document.Click` its user data.
    vcs_git_document_click = Atom.from("vcs_git_document_click").value(),
    /// A click on a heading's fold mark, a `document.Click`.
    vcs_git_document_toggle = Atom.from("vcs_git_document_toggle").value(),
    /// The wheel over the status's page, an `input.MouseScrollMsg`, a `document.Click`.
    vcs_git_document_wheel = Atom.from("vcs_git_document_wheel").value(),
    /// The refresh timer's wake, a `mesha.time.WakeMsg`, as the time system delivers it.
    vcs_git_timer = Atom.from("vcs_git_timer").value(),
    /// The menu of menus' answer, a `transient.Chosen`.
    vcs_git_menu_chosen = Atom.from("vcs_git_menu_chosen").value(),
    /// `s`: stages what the cursor is on.
    vcs_git_stage = Atom.from("vcs_git_stage").value(),
    /// `u`: unstages what the cursor is on.
    vcs_git_unstage = Atom.from("vcs_git_unstage").value(),
    /// `S`: stages the changes of every tracked file.
    vcs_git_stage_all = Atom.from("vcs_git_stage_all").value(),
    /// `U`: unstages everything staged.
    vcs_git_unstage_all = Atom.from("vcs_git_unstage_all").value(),
    /// `k`: asks whether to throw away what the cursor is on.
    vcs_git_discard = Atom.from("vcs_git_discard").value(),
    /// The discard dialog's answer, a palette event, its user data a `DiscardAsked`.
    vcs_git_discard_chosen = Atom.from("vcs_git_discard_chosen").value(),
    _,
};

/// The panel's action of `global`, offered from anywhere.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "vcs_git_status", .tag = @tagName(Msg.vcs_git_status), .doc = "Show the git status of the project's repository" },
    .{ .name = "vcs_status", .tag = @tagName(Msg.vcs_status), .doc = "Show the project's version control: vcs-git in a git repository, else vcs-p4" },
};

/// The keys of `actions`, of `global`: `C-x g`, where Emacs's own git status is bound.
pub const global_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-x g", .action = .{ "global", "vcs_git_status" } },
};

/// The actions of mode `vcs`, which every version-control panel shares: moving through what it
/// shows, folding it, the views and the work that runs. This system takes them for vcs-git.
pub const vcs_actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = @tagName(Msg.vcs_git_next), .doc = "Move to the next line or row" },
    .{ .name = "previous", .tag = @tagName(Msg.vcs_git_previous), .doc = "Move to the line or row before" },
    .{ .name = "next_sibling", .tag = @tagName(Msg.vcs_git_next_sibling), .doc = "Move to the next heading" },
    .{ .name = "previous_sibling", .tag = @tagName(Msg.vcs_git_previous_sibling), .doc = "Move to the heading before" },
    .{ .name = "parent", .tag = @tagName(Msg.vcs_git_parent), .doc = "Move to the heading this line or row is under" },
    .{ .name = "first", .tag = @tagName(Msg.vcs_git_first), .doc = "Move to the first line" },
    .{ .name = "last", .tag = @tagName(Msg.vcs_git_last), .doc = "Move to the last line" },
    .{ .name = "page_down", .tag = @tagName(Msg.vcs_git_page_down), .doc = "Move a page down" },
    .{ .name = "page_up", .tag = @tagName(Msg.vcs_git_page_up), .doc = "Move a page up" },
    .{ .name = "toggle", .tag = @tagName(Msg.vcs_git_toggle), .doc = "Fold or open the heading the cursor is under, or the job of the runner's log" },
    .{ .name = "toggle_all", .tag = @tagName(Msg.vcs_git_toggle_all), .doc = "Fold every heading, or open them all; in the runner's log, every job" },
    .{ .name = "visit", .tag = @tagName(Msg.vcs_git_visit), .doc = "Show the changes of the file or the commit at the cursor, or open an untracked file" },
    .{ .name = "refresh", .tag = @tagName(Msg.vcs_git_refresh), .doc = "Ask git again" },
    .{ .name = "quit", .tag = @tagName(Msg.vcs_git_quit), .doc = "Leave this view for the one before, or close the panel" },
    .{ .name = "process_log", .tag = @tagName(Msg.vcs_git_process_log), .doc = "Show the commands run and what they said" },
    .{ .name = "give_up", .tag = @tagName(Msg.vcs_git_give_up), .doc = "Give up the commands that run" },
    .{ .name = "menu", .tag = @tagName(Msg.vcs_git_menu), .doc = "Show the menu of what the panel does" },
};

/// The keys of mode `vcs`, Emacs's for moving and folding. A symbol is written as the key that
/// types it with Shift on a US layout (`S-6` is `^`, `S-4` `$`, `S-slash` `?`, `M-S-comma`
/// `M-<`), as a chord names keys, not the characters they type.
pub const vcs_keys = [_]keybinds.KeyDef{
    .{ .chord = "n", .action = .{ "vcs", "next" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "vcs", "next" }, .trigger = .repeat },
    .{ .chord = "p", .action = .{ "vcs", "previous" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "vcs", "previous" }, .trigger = .repeat },
    .{ .chord = "M-n", .action = .{ "vcs", "next_sibling" }, .trigger = .repeat },
    .{ .chord = "M-p", .action = .{ "vcs", "previous_sibling" }, .trigger = .repeat },
    .{ .chord = "S-6", .action = .{ "vcs", "parent" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "vcs", "first" } },
    .{ .chord = "M-S-period", .action = .{ "vcs", "last" } },
    .{ .chord = "C-v", .action = .{ "vcs", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "vcs", "page_up" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "vcs", "toggle" } },
    .{ .chord = "S-tab", .action = .{ "vcs", "toggle_all" } },
    .{ .chord = "RET", .action = .{ "vcs", "visit" } },
    .{ .chord = "g", .action = .{ "vcs", "refresh" } },
    .{ .chord = "q", .action = .{ "vcs", "quit" } },
    .{ .chord = "S-4", .action = .{ "vcs", "process_log" } },
    .{ .chord = "C-g", .action = .{ "vcs", "give_up" } },
    .{ .chord = "S-slash", .action = .{ "vcs", "menu" } },
};

/// The actions of mode `vcs_git`, git's own commands on what the cursor is on.
pub const vcs_git_actions = [_]plugin.action_api.Def{
    .{ .name = "stage", .tag = @tagName(Msg.vcs_git_stage), .doc = "Stage the file at the cursor, or every file of the table under the heading at it" },
    .{ .name = "unstage", .tag = @tagName(Msg.vcs_git_unstage), .doc = "Unstage the file at the cursor, or every file of the table under the heading at it" },
    .{ .name = "stage_all", .tag = @tagName(Msg.vcs_git_stage_all), .doc = "Stage every unstaged change of the tracked files" },
    .{ .name = "unstage_all", .tag = @tagName(Msg.vcs_git_unstage_all), .doc = "Unstage everything staged" },
    .{ .name = "discard", .tag = @tagName(Msg.vcs_git_discard), .doc = "Throw away the unstaged file or table at the cursor, or delete the untracked file, after asking" },
    git_commit.commit_action,
    git_log.log_action,
    git_branch.branch_action,
    git_branch.merge_action,
    git_remote.push_action,
    git_remote.pull_action,
    git_remote.fetch_action,
    git_rebase.rebase_action,
};

/// The keys of mode `vcs_git`, git's own commands, over `vcs_keys`: `S-s` is `S`, `S-u` `U`,
/// `S-p` `P` and `S-f` `F`.
pub const vcs_git_keys = [_]keybinds.KeyDef{
    .{ .chord = "s", .action = .{ "vcs_git", "stage" } },
    .{ .chord = "u", .action = .{ "vcs_git", "unstage" } },
    .{ .chord = "S-s", .action = .{ "vcs_git", "stage_all" } },
    .{ .chord = "S-u", .action = .{ "vcs_git", "unstage_all" } },
    .{ .chord = "k", .action = .{ "vcs_git", "discard" } },
    .{ .chord = "c", .action = .{ "vcs_git", "commit" } },
    .{ .chord = "l", .action = .{ "vcs_git", "log" } },
    .{ .chord = "b", .action = .{ "vcs_git", "branch" } },
    .{ .chord = "m", .action = .{ "vcs_git", "merge" } },
    .{ .chord = "S-p", .action = .{ "vcs_git", "push" } },
    .{ .chord = "S-f", .action = .{ "vcs_git", "pull" } },
    .{ .chord = "f", .action = .{ "vcs_git", "fetch" } },
    .{ .chord = "r", .action = .{ "vcs_git", "rebase" } },
};

/// Offers the actions of modes `vcs`, `vcs_git`, `vcs_log`, `vcs_rebase`, `vcs_git_diff` and
/// `vcs_message`,
/// this system taking them, every frame: the modes decide when they are live.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const inbox = sequencer.inboxOf(system());
    for (vcs_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs, inbox, &.{.{ .def = def }});
    for (vcs_git_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_git, inbox, &.{.{ .def = def }});
    git_log.pushActions(atoms, sink, inbox);
    git_rebase.pushActions(atoms, sink, inbox);
    git_diff.pushActions(atoms, sink, inbox);
    for (git_commit.message_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_message, inbox, &.{.{ .def = def }});
}

// ---- the menu of menus ---------------------------------------------------------------------

/// What the menu of menus (`?`) offers, by its items' ids; `dispatch` runs each.
pub const MenuCommand = enum(u32) {
    refresh = 1,
    process_log,
    quit,
    commit,
    log,
    branch,
    merge,
    rebase,
    push,
    pull,
    fetch,
};

/// The menu of menus, `?`: what the panel does, by the keys that do it; each of the commands'
/// menus opens from it as its own key opens it.
pub const menu: ui.transient.Menu = .{
    .title = "vcs-git",
    .groups = &.{
        .{ .title = "Status", .items = &.{
            ui.transient.Item.command("g", "Refresh", @intFromEnum(MenuCommand.refresh)),
            ui.transient.Item.command("$", "Process log", @intFromEnum(MenuCommand.process_log)),
            ui.transient.Item.command("q", "Back or close", @intFromEnum(MenuCommand.quit)),
        } },
        .{ .title = "Commands", .items = &.{
            ui.transient.Item.menu("c", "Commit", @intFromEnum(MenuCommand.commit)),
            ui.transient.Item.menu("b", "Branch", @intFromEnum(MenuCommand.branch)),
            ui.transient.Item.menu("l", "Log", @intFromEnum(MenuCommand.log)),
            ui.transient.Item.menu("m", "Merge", @intFromEnum(MenuCommand.merge)),
            ui.transient.Item.menu("r", "Rebase", @intFromEnum(MenuCommand.rebase)),
        } },
        .{ .title = "Remotes", .items = &.{
            ui.transient.Item.menu("P", "Push", @intFromEnum(MenuCommand.push)),
            ui.transient.Item.menu("F", "Pull", @intFromEnum(MenuCommand.pull)),
            ui.transient.Item.menu("f", "Fetch", @intFromEnum(MenuCommand.fetch)),
        } },
    },
};

// ---- the tables ----------------------------------------------------------------------------

/// `editor_vcs_git`: the panel's own row, one (`StateRow`).
pub const state_table_name = "editor_vcs_git";
/// `editor_vcs_git_untracked`, `_unmerged`, `_unstaged` and `_staged`: the files of the last
/// status, a row each, in the order git gave them, under the table of each section they are in
/// (`FileRow`); a file changed in the index and in the working tree is in both of theirs. The
/// sources `vcs-git.untracked` and so on.
pub const untracked_table_name = "editor_vcs_git_untracked";
pub const unmerged_table_name = "editor_vcs_git_unmerged";
pub const unstaged_table_name = "editor_vcs_git_unstaged";
pub const staged_table_name = "editor_vcs_git_staged";
/// `editor_vcs_git_commits`: the recent commits, newest first (`CommitRow`): the source
/// `vcs-git.commits`.
pub const commits_table_name = "editor_vcs_git_commits";
/// `editor_vcs_git_collapsed`: the status page's folds, a heading's key a row
/// (`document.FoldRow`).
pub const collapsed_table_name = "editor_vcs_git_collapsed";
/// `editor_vcs_git_expanded`: the keys of the lines, folded unless opened, that are open: a job
/// of the runner's log view (`FoldRow`).
pub const expanded_table_name = "editor_vcs_git_expanded";
/// `editor_vcs_git_diff_files`: where each file's part of a diff's bytes is, a row per file of
/// each diff the panel holds, the two of the status and the commit the diff panel shows, at most
/// `max_diff_files` each (`DiffFileRow`). Its offsets index the diff's bytes in
/// the panel's row, and are forgotten with them.
pub const diff_files_table_name = "editor_vcs_git_diff_files";
/// The panel's modes, a `modes.PanelModesRow`.
pub const panel_modes_table_name = "editor_vcs_git_panel_modes";

/// The most files the panel keeps of a status, across its tables: those past it are not listed,
/// and a command on a table's heading says how many it left as they are.
pub const max_entries = 4096;
/// The most headings the panel keeps folded.
pub const max_collapsed = 1024;
/// The most jobs the panel keeps opened.
pub const max_expanded = 1024;

/// Which view the panel shows.
pub const View = enum(u8) {
    /// The repository's status.
    status,
    /// The runner's log of the panel's jobs (`$`).
    process_log,
    /// The log's query and the commits it listed, a page (`git_log.zig`).
    log,
    /// An interactive rebase's list, a page (`git_rebase.zig`).
    rebase,
};

/// The table of the status a row is in, or the heading of which a key acts on: a section of the
/// status. `none` for what is in none (a line of text).
pub const SectionKind = enum(u8) {
    none,
    untracked,
    unmerged,
    unstaged,
    staged,
    /// The recent commits.
    recent,

    /// The name the section's table is published under, as the page's text names it; empty for
    /// `none`.
    pub fn sourceName(section: SectionKind) []const u8 {
        return switch (section) {
            .none => "",
            .untracked => "vcs-git.untracked",
            .unmerged => "vcs-git.unmerged",
            .unstaged => "vcs-git.unstaged",
            .staged => "vcs-git.staged",
            .recent => "vcs-git.commits",
        };
    }

    /// The section published as `name`; `none` for a name that is none of vcs-git's.
    pub fn ofSource(name: []const u8) SectionKind {
        for (std.enums.values(SectionKind)) |section| {
            if (section == .none) continue;
            if (std.mem.eql(u8, section.sourceName(), name)) return section;
        }
        return .none;
    }

    /// The name of the value that says how many files the status counted in the section,
    /// listed or not (`vcs-git.untracked-count`); empty for `none` and `recent`.
    pub fn countName(section: SectionKind) []const u8 {
        return switch (section) {
            .untracked => "vcs-git.untracked-count",
            .unmerged => "vcs-git.unmerged-count",
            .unstaged => "vcs-git.unstaged-count",
            .staged => "vcs-git.staged-count",
            .recent, .none => "",
        };
    }

    /// What one of the section's files is called, and more than one.
    fn nouns(section: SectionKind) [2][]const u8 {
        return switch (section) {
            .untracked => .{ "untracked file", "untracked files" },
            .unmerged => .{ "unmerged file", "unmerged files" },
            .unstaged => .{ "unstaged change", "unstaged changes" },
            .staged => .{ "staged change", "staged changes" },
            .recent, .none => .{ "", "" },
        };
    }

    /// The section's table, by its name's atom.
    pub fn table(section: SectionKind) ?Atom {
        return switch (section) {
            .none => null,
            .untracked => untracked_table,
            .unmerged => unmerged_table,
            .unstaged => unstaged_table,
            .staged => staged_table,
            .recent => commits_table,
        };
    }

    /// The side of the status's diff a file of the section has its changes in, which the diff
    /// panel shows; null for a section whose rows have none there.
    pub fn side(section: SectionKind) ?git.Side {
        return switch (section) {
            .unmerged, .unstaged => .unstaged,
            .staged => .staged,
            .untracked, .recent, .none => null,
        };
    }
};

/// The sections a row is a file of, in the order the page shows them.
pub const file_sections = [_]SectionKind{ .untracked, .unmerged, .unstaged, .staged };

/// What the panel says in place of its page.
pub const Notice = enum(u8) {
    /// Nothing: it shows the page.
    none,
    /// The working directory is in no repository: `status` failed with git's exit code 128.
    not_repository,
    /// `git` could not be started: it is not on `PATH`.
    git_missing,
};

/// What a job of the panel's was for: what its answer fills.
pub const Purpose = enum(u8) {
    status,
    recent,
    operation,
    rebase_check,
    root,
    /// A command of the panel's own that writes the index or the working tree (`CommandName`
    /// says which): the end of the last one queued refreshes.
    command,
    /// The unstaged diff, for the files a person opens.
    unstaged_diff,
    /// The staged diff, likewise.
    staged_diff,
    /// `HEAD`'s message, for a commit that amends or rewords it (`git_commit.zig`).
    head_message,
    /// The commits a log view lists (`git_log.zig`).
    log,
    /// The branches the log's revision prompt lists.
    refs,
    /// A commit the diff panel shows.
    show,
    /// The remotes a push's prompt lists.
    remotes,
    /// The commits an interactive rebase lists (`git_rebase.zig`).
    rebase_list,
    /// What is left of the list of the rebase in progress.
    rebase_todo,
    /// The commit a revision typed for `r i` names (`git_branch.zig`).
    resolve,

    /// The bit of `StateRow.refresh_asked` and `refresh_failed` that stands for a refresh's
    /// purpose, `status` to `root`; the others have none.
    fn bit(purpose: Purpose) u8 {
        return @as(u8, 1) << @intCast(@intFromEnum(purpose));
    }

    /// The command line a person reads for a job of a refresh or a diff.
    fn shown(purpose: Purpose) []const u8 {
        return switch (purpose) {
            .status => "git status",
            .recent => "git log (recent commits)",
            .operation => "git log (operation in progress)",
            .rebase_check => "git rebase --edit-todo (rebase in progress?)",
            .root => "git rev-parse --show-toplevel",
            .command => "git",
            .unstaged_diff => "git diff",
            .staged_diff => "git diff --cached",
            .head_message => "git log -1 --format=%B",
            .log => "git log",
            .refs => "git for-each-ref",
            .show => "git show",
            .remotes => "git remote",
            .rebase_list => "git log (commits to rebase)",
            .rebase_todo => "git rebase --edit-todo (the rest of the list)",
            .resolve => "git rev-parse --verify",
        };
    }

    /// The subcommand a person knows the job by, as a failure names it.
    fn subcommand(purpose: Purpose) []const u8 {
        return switch (purpose) {
            .status => "status",
            .recent, .operation, .head_message, .log => "log",
            .refs => "for-each-ref",
            .show => "show",
            .remotes => "remote",
            .rebase_list => "log",
            .rebase_todo => "rebase",
            .resolve => "rev-parse",
            .rebase_check => "rebase",
            .root => "rev-parse",
            .command => "command",
            .unstaged_diff, .staged_diff => "diff",
        };
    }

    /// The command of a job that is no command of the panel's.
    fn gitCommand(purpose: Purpose) git.Command {
        return switch (purpose) {
            .status => .status,
            .recent => .recent,
            .operation => .operation,
            .rebase_check => .rebase_check,
            .root => .root,
            .unstaged_diff => .{ .diff = .unstaged },
            .staged_diff => .{ .diff = .staged },
            .head_message => .head_message,
            .refs => .refs,
            .remotes => .remotes,
            .rebase_todo => .rebase_todo,
            // Their command lines are their asker's own: `Work.queueQuery`, `Work.queueRead`.
            .command, .log, .show, .rebase_list, .resolve => unreachable,
        };
    }

    /// The diff's job for `side`.
    fn ofDiff(side: git.Side) Purpose {
        return switch (side) {
            .unstaged => .unstaged_diff,
            .staged => .staged_diff,
        };
    }
};

/// Which git command a job of `Purpose.command` runs: what its failure says, and what the log
/// and the spinner show.
pub const CommandName = enum(u8) {
    none,
    add,
    restore_staged,
    rm_cached,
    restore_worktree,
    apply_cached,
    apply_cached_reverse,
    apply_reverse,
    clean,
    /// A commit with a message: new, amend or reword.
    commit,
    commit_extend,
    commit_fixup,
    switch_branch,
    create_switch,
    create_branch,
    delete_branch,
    delete_branch_force,
    rename_branch,
    merge,
    merge_abort,
    rebase,
    rebase_continue,
    rebase_skip,
    rebase_abort,
    rebase_edit_todo,
    push,
    pull,
    fetch,

    /// The command that runs `command`; `none` for one that is no command of the panel's.
    fn of(command: git.Command) CommandName {
        return switch (command) {
            .stage => .add,
            .unstage => .restore_staged,
            .unstage_unborn => .rm_cached,
            .discard => .restore_worktree,
            .apply => |how| switch (how) {
                .stage => .apply_cached,
                .unstage => .apply_cached_reverse,
                .discard => .apply_reverse,
            },
            .commit => |commit| switch (commit.kind) {
                .new, .amend, .reword => .commit,
                .extend => .commit_extend,
                .fixup => .commit_fixup,
            },
            .switch_to, .switch_track => .switch_branch,
            .create_branch => |branch| switch (branch.after) {
                .switch_to => .create_switch,
                .stay => .create_branch,
            },
            .delete_branch => |branch| switch (branch.how) {
                .merged => .delete_branch,
                .force => .delete_branch_force,
            },
            .rename_branch => .rename_branch,
            .merge => .merge,
            .merge_abort => .merge_abort,
            .rebase => .rebase,
            .rebase_continue => .rebase_continue,
            .rebase_skip => .rebase_skip,
            .rebase_abort => .rebase_abort,
            .rebase_edit_todo => .rebase_edit_todo,
            .push => .push,
            .pull, .pull_from => .pull,
            .fetch, .fetch_all => .fetch,
            else => .none,
        };
    }

    /// The subcommand a person knows it by, as a failure names it.
    fn subcommand(name: CommandName) []const u8 {
        return switch (name) {
            .none => "command",
            .add => "add",
            .restore_staged, .restore_worktree => "restore",
            .rm_cached => "rm",
            .apply_cached, .apply_cached_reverse, .apply_reverse => "apply",
            .clean => "clean",
            .commit, .commit_extend, .commit_fixup => "commit",
            .switch_branch, .create_switch => "switch",
            .create_branch, .delete_branch, .delete_branch_force, .rename_branch => "branch",
            .merge, .merge_abort => "merge",
            .rebase, .rebase_continue, .rebase_skip, .rebase_abort, .rebase_edit_todo => "rebase",
            .push => "push",
            .pull => "pull",
            .fetch => "fetch",
        };
    }

    /// Whether the refresh after it asks for the operation in progress whatever the rule says:
    /// a commit ends a merge, a cherry-pick or a revert; a merge, a pull and a rebase may start
    /// or end one.
    fn operationCheck(name: CommandName) OperationCheck {
        return switch (name) {
            .commit, .commit_extend, .commit_fixup => .ask,
            .merge, .merge_abort, .pull => .ask,
            .rebase, .rebase_continue, .rebase_skip, .rebase_abort, .rebase_edit_todo => .ask,
            else => .by_rule,
        };
    }

    /// Whether it may move `HEAD`, or the branch it is on, to another commit: a log to come back
    /// to is run again as it ends.
    fn movesHead(name: CommandName) bool {
        return switch (name) {
            .commit, .commit_extend, .commit_fixup => true,
            .switch_branch, .create_switch, .merge, .merge_abort, .pull => true,
            .rebase, .rebase_continue, .rebase_skip, .rebase_abort => true,
            else => false,
        };
    }

    /// Its command line as a person reads it, without the paths.
    fn shown(name: CommandName) []const u8 {
        return switch (name) {
            .none => "git",
            .add => "git add",
            .restore_staged => "git restore --staged",
            .rm_cached => "git rm --cached",
            .restore_worktree => "git restore --worktree",
            .apply_cached => "git apply --cached",
            .apply_cached_reverse => "git apply --cached --reverse",
            .apply_reverse => "git apply --reverse",
            .clean => "git clean",
            .commit => "git commit -F -",
            .commit_extend => "git commit --amend --no-edit",
            .commit_fixup => "git commit --fixup",
            .switch_branch => "git switch",
            .create_switch => "git switch -c",
            .create_branch => "git branch",
            .delete_branch => "git branch -d",
            .delete_branch_force => "git branch -D",
            .rename_branch => "git branch -m",
            .merge => "git merge",
            .merge_abort => "git merge --abort",
            .rebase => "git rebase -i",
            .rebase_continue => "git rebase --continue",
            .rebase_skip => "git rebase --skip",
            .rebase_abort => "git rebase --abort",
            .rebase_edit_todo => "git rebase --edit-todo",
            .push => "git push",
            .pull => "git pull",
            .fetch => "git fetch",
        };
    }
};

/// A job's user data: what it was for, and the panel's generation as it was queued.
pub const JobData = extern struct {
    /// `StateRow.generation` as the job was queued.
    generation: u32,
    /// A `Purpose`.
    purpose: u8,
    /// A `CommandName`: for `Purpose.command`, which; `none` for any other purpose.
    command: u8 = @intFromEnum(CommandName.none),
    /// Zero, so the bytes are all set.
    reserved: [2]u8 = @splat(0),
    /// For a diff's job, `StateRow.diff_epoch` as it was asked: an answer of an earlier epoch is
    /// of a diff forgotten since, and is dropped. For a log's, the refs' or a show's, the count
    /// of its kind asked as it was: an answer of an earlier one is dropped.
    epoch: u32 = 0,
    /// For a fixup's commit, the short hash of the commit it fixes, which its end tells
    /// (`fixupTarget`); zeros for any other job.
    fixup_target: [fixup_target_length]u8 = @splat(0),
    /// Zero, so the bytes are all set.
    reserved_end: [1]u8 = @splat(0),

    /// The short hash `fixup_target` holds, without the zeros after a shorter one.
    pub fn fixupTarget(data: *const JobData) []const u8 {
        const length = std.mem.indexOfScalar(u8, &data.fixup_target, 0) orelse fixup_target_length;
        return data.fixup_target[0..length];
    }
};

/// How many characters of the commit a fixup fixes its job carries (`JobData.fixup_target`).
pub const fixup_target_length = 7;

/// A diff the panel holds: the status's two, and the shown commit's.
pub const DiffSource = enum(u8) {
    unstaged,
    staged,
    shown,

    /// The status's diff of `side`.
    pub fn ofSide(side: git.Side) DiffSource {
        return switch (side) {
            .unstaged => .unstaged,
            .staged => .staged,
        };
    }

    /// Its bit of `StateRow.diffs_loaded` and `diffs_asked`.
    pub fn bit(source: DiffSource) u8 {
        return @as(u8, 1) << @as(u3, @intCast(@intFromEnum(source)));
    }
};

/// The bit of `StateRow.diffs_loaded` and `diffs_asked` that stands for `side`'s diff.
pub fn diffBit(side: git.Side) u8 {
    return DiffSource.ofSide(side).bit();
}

/// The row of `editor_vcs_git`. Text a person reads is in its text cells.
pub const StateRow = struct {
    /// The working directory the data is for, absolute; empty before the first refresh.
    working_directory: *Table.String,
    /// The root of its repository, from `git.Command.root`; empty until it is known.
    root: *Table.String,
    /// The person's home directory as the last refresh found it, which a path under it is
    /// shown from as `~`.
    home_directory: *Table.String,
    /// A `View`.
    view: *u8,
    /// The runner's log view's `outline.Cursor`.
    process_log_key: *u64,
    process_log_index: *u32,
    process_log_scroll: *f32,
    /// The `View` the runner's log view goes back to.
    process_log_return: *u8,
    /// The height of the runner's log view the last run settled its scroll for, in pixels.
    view_height: *f32,
    /// Counts the give-ups and the changes of project: an answer of an earlier one is dropped.
    generation: *u32,
    /// The jobs of the refresh that runs not answered yet; 0 while none runs.
    refresh_jobs: *u8,
    /// Whether a refresh was asked for while one ran, another to run when it ends: 0 none, 1 one
    /// by rule, 2 one asking for the operation in progress (`OperationCheck.ask`), which a later
    /// ask by rule does not lower.
    refresh_again: *u8,
    /// The `Purpose`s the refresh that runs has asked, a bit each.
    refresh_asked: *u8,
    /// The `Purpose`s of the refresh that runs whose jobs failed, a bit each.
    refresh_failed: *u8,
    /// 1 once a status was read for the working directory.
    answered: *u8,
    /// A `Notice`.
    notice: *u8,
    /// A `git.Head`.
    head: *u8,
    /// The branch `HEAD` is on; empty when detached.
    branch: *Table.String,
    /// The commit `HEAD` is at, whole; empty before the first commit.
    oid: *Table.String,
    /// The branch's upstream; empty for none.
    upstream: *Table.String,
    /// A `git.Upstream`.
    upstream_state: *u8,
    /// As `git.Status` counts them.
    ahead: *u32,
    behind: *u32,
    stash_count: *u32,
    staged_count: *u32,
    unstaged_count: *u32,
    untracked_count: *u32,
    unmerged_count: *u32,
    /// A `git.Operation`: what is in progress.
    operation: *u8,
    /// A `git.RebaseStop`: where a rebase in progress is stopped.
    operation_stop: *u8,
    /// The commit the operation stopped on or brings in (`git.InProgress.commit`); empty for
    /// none.
    operation_commit: *Table.String,
    /// At a rebase's `edit` stop, `HEAD` as it stopped (`git.InProgress.amend`); empty otherwise.
    operation_amend: *Table.String,
    /// 1 from git not running a list of the panel's (`git_rebase.refreshEnded`: it refused it as
    /// lacking commits, or failed before its first line) until a refresh reads the rebase ended:
    /// the operation's line says so for as long as it lasts, offering `r a` alone, and `r r`,
    /// `r s` and `r e` run nothing. Kept in a durable table, it outlives a reload of the editor,
    /// not a restart, after which `rebase.missingCommitsCheck`, which every rebase command runs
    /// with, is what refuses, and its refusal sets this again.
    rebase_refused: *u8,
    /// The detached commit `Command.rebase_check` last found no rebase at; empty for none.
    checked_oid: *Table.String,
    /// The runner's `phase`, copied each frame a job runs: the spinner the header draws.
    phase: *u32,
    /// The unstaged and the staged diff, as git said them, for the files the diff panel shows;
    /// empty until asked for, and again once a status replaces what they were of.
    unstaged_diff: *Table.Bytes,
    staged_diff: *Table.Bytes,
    /// Which of the two diffs are loaded, a bit each (`diffBit`).
    diffs_loaded: *u8,
    /// Which of the two diffs are asked for and not answered yet, a bit each.
    diffs_asked: *u8,
    /// Counts the times the diffs were forgotten: a diff's answer asked in an earlier epoch is
    /// dropped.
    diff_epoch: *u32,
    /// How many files each diff holds, the first `max_diff_files` of them in
    /// `editor_vcs_git_diff_files`.
    unstaged_files_seen: *u32,
    staged_files_seen: *u32,
    /// The panel's commands queued or running, not answered yet: the panel refreshes as the
    /// last ends.
    commands_running: *u8,
    /// An `OperationCheck`: `ask` once a command queued since the last refresh may have started
    /// or ended an operation, which the refresh after the last asks about.
    command_check: *u8,
    /// The commit the diff panel shows, as `show` said it (`git.parseShow`); empty until it
    /// answers. Its diff's files are in `editor_vcs_git_diff_files`.
    shown_commit: *Table.Bytes,
    /// The commit asked to show, as it was given to `show`.
    shown_hash: *Table.String,
    /// How many files the shown commit's diff holds.
    shown_files_seen: *u32,
    /// Counts the commits asked to show: an answer of an earlier one is dropped.
    show_serial: *u32,
    /// 1 while the refresh that runs was the timer's: its status, if it is what the last one
    /// said, keeps the diffs held, so the diff panel shows what it showed and nothing more runs.
    refresh_quiet: *u8,
    /// A hash of what the last status said.
    status_fingerprint: *u64,
    /// The status page's `MovedUnder`: 1 from a refresh that took the row under the page's
    /// cursor away, its place now another file's, to the end of that run: a staging key, `RET`
    /// or a command on the commit under the cursor later in the run acts on nothing.
    cursor_moved_under: *u8,
    /// 1 while a wake of the time system's is asked for the timer's next refresh.
    timer_armed: *u8,
    /// The interval in seconds the pending wake was asked for.
    timer_seconds: *u32,
    /// The instant on the awake clock (`mesha.time.AwakeView`), in nanoseconds, the pending wake
    /// was asked at: a wake not heard within twice its interval of it was rejected, and is asked
    /// again.
    timer_asked_at: *i64,
    /// 1 from the project menu's `v` (`global.vcs_status`) until the status answers: a working
    /// directory in no git repository, or no git, then hides vcs-git and shows vcs-p4 in its
    /// place.
    hand_off: *u8,
};

/// `StateRow` read, its text as slices of the table's: what the page's values and the runner's
/// log's lines are made from.
pub const StateRead = struct {
    working_directory: []const u8,
    root: []const u8,
    home_directory: []const u8,
    view: *u8,
    process_log_key: *u64,
    process_log_index: *u32,
    process_log_scroll: *f32,
    answered: *u8,
    notice: *u8,
    head: *u8,
    branch: []const u8,
    oid: []const u8,
    upstream: []const u8,
    upstream_state: *u8,
    ahead: *u32,
    behind: *u32,
    stash_count: *u32,
    staged_count: *u32,
    unstaged_count: *u32,
    untracked_count: *u32,
    unmerged_count: *u32,
    operation: *u8,
    operation_stop: *u8,
    operation_commit: []const u8,
    operation_amend: []const u8,
    rebase_refused: *u8,
    phase: *u32,
    unstaged_diff: []const u8,
    staged_diff: []const u8,
    diffs_loaded: *u8,
    unstaged_files_seen: *u32,
    staged_files_seen: *u32,
    shown_commit: []const u8,
    shown_hash: []const u8,
    shown_files_seen: *u32,

    /// The runner's log view's cursor, while it is shown: none for the status, a page with a
    /// cursor of its own (`document.StateRow`), or the log, a page too.
    pub fn cursor(state: StateRead) outline.Cursor {
        return switch (viewOf(state.view.*)) {
            .process_log => .{ .key = state.process_log_key.*, .index = state.process_log_index.*, .scroll = state.process_log_scroll.* },
            .status, .log, .rebase => .{},
        };
    }
};

/// A row of a file table (`editor_vcs_git_untracked` and the three beside it): a file of the
/// status under one section, its text the table's.
pub const FileRow = struct {
    /// What became of it, a word a person reads (`modified`, `added`, `renamed`, `both
    /// modified`, ...), `submodule` after it for a submodule: shown.
    change: []const u8,
    /// Its path as a person reads it, a staged rename's as `old -> new`: shown.
    path: []const u8,
    /// Its path from the repository's root, `/`-separated, as git gave it, which a command
    /// names.
    git_path: []const u8,
    /// A renamed file's path before; empty otherwise.
    original_path: []const u8,
    /// The index's letter and the working tree's, as `git.Entry` has them (`MM`, `.M`, `R.`,
    /// `UU`, `??`).
    letters: []const u8,
};

/// The fields of a file table, in order; the first two are shown.
const file_fields = [_][]const u8{ "change", "path", "git_path", "original_path", "letters" };
/// The fields of a file table a page shows.
const file_shown = [_][]const u8{ "change", "path" };

/// A row of `editor_vcs_git_commits`: a recent commit, as `git.LogEntry` has it, its text the
/// table's.
pub const CommitRow = struct {
    /// Its hash as short as git keeps it unambiguous: shown.
    hash: []const u8,
    /// The references at it, as git decorates them: shown.
    refs: []const u8,
    /// Its message's first line: shown.
    subject: []const u8,
    /// Its author's name: shown.
    author: []const u8,
    /// Its author's date, as `--date=short` gives it: shown.
    date: []const u8,
    /// Its full hash, which a command names.
    full_hash: []const u8,
};

/// The fields of `editor_vcs_git_commits`, in order; all but the last are shown.
const commit_fields = [_][]const u8{ "hash", "refs", "subject", "author", "date", "full_hash" };
/// The fields of the commits a page shows.
const commit_shown = [_][]const u8{ "hash", "refs", "subject", "author", "date" };

/// A row of `editor_vcs_git_diff_files`: a file of a diff and its part of the diff's bytes.
pub const DiffFileRow = struct {
    /// A `DiffSource`: which diff.
    source: *u8,
    /// The file's path, as `diffPath` names it: from the root, unquoted.
    path: []const u8,
    /// The path it had, unquoted, when it was renamed or copied; its path otherwise.
    old_path: []const u8,
    /// A `git.Change`: what became of it.
    change: *u8,
    /// Where the file's part begins in the diff's bytes, and how long it is: from its
    /// `diff --git` line to the next file's.
    offset: *u32,
    length: *u32,
};

/// A view's selection of `View` from its byte, the status for a byte that names none.
pub fn viewOf(byte: u8) View {
    return std.enums.fromInt(View, byte) orelse .status;
}

const state_table = Atom.from(state_table_name);
const untracked_table = Atom.from(untracked_table_name);
const unmerged_table = Atom.from(unmerged_table_name);
const unstaged_table = Atom.from(unstaged_table_name);
const staged_table = Atom.from(staged_table_name);
const commits_table = Atom.from(commits_table_name);
const collapsed_table = Atom.from(collapsed_table_name);
const expanded_table = Atom.from(expanded_table_name);
const diff_files_table = Atom.from(diff_files_table_name);
const places_table = Atom.from(mesha.os.places_table_name);
const runner_requests_table = Atom.from(runner.requests_table_name);
const runner_log_table = Atom.from(runner.log_table_name);
const text_editor_requests = Atom.from(text_editor.commands_table_name);
const transient_requests = Atom.from(transient.requests_table_name);
const palette_requests = Atom.from(action_palette.requests_table_name);
const shown_panels_table = Atom.from(fixed_panels.shown_panels_table_name);
const panel_requests_table = Atom.from(plugin.panels.commands_table_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const font_metrics_table = Atom.from(resources.font_metrics_table_name);
const document_sources_table = Atom.from(document_sources.sources_table_name);
const document_values_table = Atom.from(document_sources.values_table_name);
/// The status's page: `vcs-git.org`, its state in the panel's row, its folds in
/// `editor_vcs_git_collapsed`.
pub const status_page: vcs_page.Page = .{
    .document = vcs_page.parsePage(status_document, "vcs-git.org"),
    .name = "vcs_git_document",
    .state_table = state_table,
    .folds_table = collapsed_table,
    .tags = .{
        .click = Atom.from(Msg.vcs_git_document_click),
        .toggle = Atom.from(Msg.vcs_git_document_toggle),
        .wheel = Atom.from(Msg.vcs_git_document_wheel),
    },
    .resize_reader_name = "vcs_git_document_resizes",
    .moved_under_sentence = "The status changed under the cursor",
};

/// No atom: the panel that lost the focus, before one is told.
const no_atom: Atom = @enumFromInt(0);
/// The name the panel reads the text editors' events under, for a buffer saved.
const save_reader_name = "vcs_git_saves";
const save_reader = Atom.from(save_reader_name);
const settings_table = Atom.from(keybinds.editor_settings_name);
const time_commands = Atom.from(mesha.time.commands_table_name);
/// The name the panel reads the focus moves under.
const focus_reader_name = "vcs_git_focus";
const focus_reader = Atom.from(focus_reader_name);
/// The owner the panel's dialogs are presented as.
const prompt_owner_name = "vcs_git_prompt";
const prompt_owner = Atom.from(prompt_owner_name);

/// Makes the panel's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ state_table_name, untracked_table_name, unmerged_table_name, unstaged_table_name, staged_table_name, commits_table_name, collapsed_table_name, expanded_table_name, diff_files_table_name, focus_reader_name });

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 55 + std.meta.fields(document.StateRow).len);
    defer state.deinit();
    try state.addFieldFallible("working_directory", Table.String, .text_field);
    try state.addFieldFallible("root", Table.String, .text_field);
    try state.addFieldFallible("home_directory", Table.String, .text_field);
    try state.addFieldFallible("view", u8, .int);
    try state.addFieldFallible("process_log_key", u64, .int);
    try state.addFieldFallible("process_log_index", u32, .int);
    try state.addFieldFallible("process_log_scroll", f32, .int);
    try state.addFieldFallible("process_log_return", u8, .int);
    try state.addFieldFallible("view_height", f32, .int);
    try state.addFieldFallible("generation", u32, .int);
    try state.addFieldFallible("refresh_jobs", u8, .int);
    try state.addFieldFallible("refresh_again", u8, .int);
    try state.addFieldFallible("refresh_asked", u8, .int);
    try state.addFieldFallible("refresh_failed", u8, .int);
    try state.addFieldFallible("answered", u8, .int);
    try state.addFieldFallible("notice", u8, .int);
    try state.addFieldFallible("head", u8, .int);
    try state.addFieldFallible("branch", Table.String, .text_field);
    try state.addFieldFallible("oid", Table.String, .text_field);
    try state.addFieldFallible("upstream", Table.String, .text_field);
    try state.addFieldFallible("upstream_state", u8, .int);
    try state.addFieldFallible("ahead", u32, .int);
    try state.addFieldFallible("behind", u32, .int);
    try state.addFieldFallible("stash_count", u32, .int);
    try state.addFieldFallible("staged_count", u32, .int);
    try state.addFieldFallible("unstaged_count", u32, .int);
    try state.addFieldFallible("untracked_count", u32, .int);
    try state.addFieldFallible("unmerged_count", u32, .int);
    try state.addFieldFallible("operation", u8, .int);
    try state.addFieldFallible("operation_stop", u8, .int);
    try state.addFieldFallible("operation_commit", Table.String, .text_field);
    try state.addFieldFallible("operation_amend", Table.String, .text_field);
    try state.addFieldFallible("rebase_refused", u8, .int);
    try state.addFieldFallible("checked_oid", Table.String, .text_field);
    try state.addFieldFallible("phase", u32, .int);
    try state.addFieldFallible("unstaged_diff", Table.Bytes, .bytes);
    try state.addFieldFallible("staged_diff", Table.Bytes, .bytes);
    try state.addFieldFallible("diffs_loaded", u8, .int);
    try state.addFieldFallible("diffs_asked", u8, .int);
    try state.addFieldFallible("diff_epoch", u32, .int);
    try state.addFieldFallible("unstaged_files_seen", u32, .int);
    try state.addFieldFallible("staged_files_seen", u32, .int);
    try state.addFieldFallible("commands_running", u8, .int);
    try state.addFieldFallible("command_check", u8, .int);
    try state.addFieldFallible("shown_commit", Table.Bytes, .bytes);
    try state.addFieldFallible("shown_hash", Table.String, .text_field);
    try state.addFieldFallible("shown_files_seen", u32, .int);
    try state.addFieldFallible("show_serial", u32, .int);
    try state.addFieldFallible("refresh_quiet", u8, .int);
    try state.addFieldFallible("status_fingerprint", u64, .hex);
    try state.addFieldFallible("cursor_moved_under", u8, .int);
    try state.addFieldFallible("timer_armed", u8, .int);
    try state.addFieldFallible("timer_seconds", u32, .int);
    try state.addFieldFallible("timer_asked_at", i64, .int);
    try state.addFieldFallible("hand_off", u8, .int);
    // The status's page: its cursor, scroll and view (`document.StateRow`).
    try document.addStateFields(&state);
    const defaults = .{
        .working_directory = Table.String{},
        .root = Table.String{},
        .home_directory = Table.String{},
        .view = @as(u8, @intFromEnum(View.status)),
        .process_log_key = @as(u64, 0),
        .process_log_index = @as(u32, 0),
        .process_log_scroll = @as(f32, 0),
        .process_log_return = @as(u8, @intFromEnum(View.status)),
        .view_height = @as(f32, 0),
        .generation = @as(u32, 0),
        .refresh_jobs = @as(u8, 0),
        .refresh_again = @as(u8, 0),
        .refresh_asked = @as(u8, 0),
        .refresh_failed = @as(u8, 0),
        .answered = @as(u8, 0),
        .notice = @as(u8, @intFromEnum(Notice.none)),
        .head = @as(u8, @intFromEnum(git.Head.branch)),
        .branch = Table.String{},
        .oid = Table.String{},
        .upstream = Table.String{},
        .upstream_state = @as(u8, @intFromEnum(git.Upstream.none)),
        .ahead = @as(u32, 0),
        .behind = @as(u32, 0),
        .stash_count = @as(u32, 0),
        .staged_count = @as(u32, 0),
        .unstaged_count = @as(u32, 0),
        .untracked_count = @as(u32, 0),
        .unmerged_count = @as(u32, 0),
        .operation = @as(u8, @intFromEnum(git.Operation.none)),
        .operation_stop = @as(u8, @intFromEnum(git.RebaseStop.none)),
        .operation_commit = Table.String{},
        .operation_amend = Table.String{},
        .rebase_refused = @as(u8, 0),
        .checked_oid = Table.String{},
        .phase = @as(u32, 0),
        .unstaged_diff = Table.Bytes{},
        .staged_diff = Table.Bytes{},
        .diffs_loaded = @as(u8, 0),
        .diffs_asked = @as(u8, 0),
        .diff_epoch = @as(u32, 0),
        .unstaged_files_seen = @as(u32, 0),
        .staged_files_seen = @as(u32, 0),
        .commands_running = @as(u8, 0),
        .command_check = @as(u8, @intFromEnum(OperationCheck.by_rule)),
        .shown_commit = Table.Bytes{},
        .shown_hash = Table.String{},
        .shown_files_seen = @as(u32, 0),
        .show_serial = @as(u32, 0),
        .refresh_quiet = @as(u8, 0),
        .status_fingerprint = @as(u64, 0),
        .cursor_moved_under = @as(u8, 0),
        .timer_armed = @as(u8, 0),
        .timer_seconds = @as(u32, 0),
        .timer_asked_at = @as(i64, 0),
        .hand_off = @as(u8, 0),
        // The page's, as the document starts them.
        .document_block = document.initial_state.document_block,
        .document_row = document.initial_state.document_row,
        .document_row_id = document.initial_state.document_row_id,
        .document_row_generation = document.initial_state.document_row_generation,
        .document_index = document.initial_state.document_index,
        .document_landing = document.initial_state.document_landing,
        .document_scroll = document.initial_state.document_scroll,
        .document_view_width = document.initial_state.document_view_width,
        .document_view_height = document.initial_state.document_view_height,
        .document_warned = document.initial_state.document_warned,
    };
    _ = try tables.ensureSingleton(&state, state_table, defaults, .durable);

    const file_tables = [_]Atom{ untracked_table, unmerged_table, unstaged_table, staged_table };
    for (file_tables) |file_table| {
        var files: Table.Schema = undefined;
        try files.init(scratch.allocator, atoms, file_fields.len);
        defer files.deinit();
        for (file_fields) |field| try files.addFieldFallible(field, Table.String, .text_field);
        _ = try tables.ensure(&files, max_entries, file_table, .durable);
    }

    var commits: Table.Schema = undefined;
    try commits.init(scratch.allocator, atoms, commit_fields.len);
    defer commits.deinit();
    for (commit_fields) |field| try commits.addFieldFallible(field, Table.String, .text_field);
    _ = try tables.ensure(&commits, git.recent_count, commits_table, .durable);

    var diff_files: Table.Schema = undefined;
    try diff_files.init(scratch.allocator, atoms, 6);
    defer diff_files.deinit();
    try diff_files.addFieldFallible("source", u8, .int);
    try diff_files.addFieldFallible("path", Table.String, .text_field);
    try diff_files.addFieldFallible("old_path", Table.String, .text_field);
    try diff_files.addFieldFallible("change", u8, .int);
    try diff_files.addFieldFallible("offset", u32, .int);
    try diff_files.addFieldFallible("length", u32, .int);
    const sources = std.enums.values(DiffSource).len;
    _ = try tables.ensure(&diff_files, sources * max_diff_files, diff_files_table, .durable);

    const fold_tables = [_]struct { name: Atom, capacity: u32 }{
        .{ .name = collapsed_table, .capacity = max_collapsed },
        .{ .name = expanded_table, .capacity = max_expanded },
    };
    for (fold_tables) |fold_table| {
        var folds: Table.Schema = undefined;
        try folds.init(scratch.allocator, atoms, 1);
        defer folds.deinit();
        try document.addFoldFields(&folds);
        _ = try tables.ensure(&folds, fold_table.capacity, fold_table.name, .durable);
    }
    try document_sources.ensure(scratch, atoms, tables);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
    try git_commit.ensure(scratch, atoms, tables);
    try git_log.ensure(scratch, atoms, tables);
    try git_diff.ensure(scratch, atoms, tables);
    try git_branch.ensure(scratch, atoms, tables);
    try git_rebase.ensure(scratch, atoms, tables);
}

// ---- the system ----------------------------------------------------------------------------

/// The panel's system, and the diff panel's (`git_diff.zig`): its kernels take the panels'
/// messages, refresh as the focus comes to the status and as the project changes, keep each
/// view fit to its panel as it is resized, turn the spinner while a job runs, and ask for the
/// panels' modes. It publishes the status's sources and values, and is its page's owner. After
/// the runner in the editor's frame, so the jobs it queues are taken in the next frame's run of
/// the runner.
pub fn system() sequencer.System {
    return .{
        .name = "vcs_git",
        .names = comptime &(sequencer.enumNames(Msg) ++ sequencer.enumNames(git_commit.Msg) ++ sequencer.enumNames(git_log.Msg) ++ sequencer.enumNames(git_diff.Msg) ++ sequencer.enumNames(git_branch.Msg) ++ sequencer.enumNames(git_remote.Msg) ++ sequencer.enumNames(git_rebase.Msg) ++
            sequencer.enumNames(ui.grid.Msg) ++ [_][]const u8{ focus_reader_name, panel_modes_table_name, prompt_owner_name, save_reader_name } ++ status_page.names() ++ git_log.names ++ git_branch.names ++ git_rebase.names ++ document_view.element_names),
        .root = vcs_git_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "vcs_git.take_messages", .run = takeMessages },
            .{ .name = "vcs_git.follow_focus", .run = followFocus },
            .{ .name = "vcs_git.follow_saves", .run = followSaves },
            .{ .name = "vcs_git.follow_timer", .run = followTimer },
            .{ .name = "vcs_git.follow_project", .run = followProject },
            .{ .name = "vcs_git.follow_commit", .run = git_commit.followCommit },
            .{ .name = "vcs_git.follow_layout", .run = followLayout },
            .{ .name = "vcs_git.turn_spinner", .run = turnSpinner },
            .{ .name = "vcs_git.follow_modes", .run = followModes },
        },
    };
}

fn claims(tag: Atom) bool {
    if (git_commit.claims(tag)) return true;
    if (git_log.claims(tag)) return true;
    if (git_diff.claims(tag)) return true;
    if (git_branch.claims(tag)) return true;
    if (git_remote.claims(tag)) return true;
    if (git_rebase.claims(tag)) return true;
    // The grids of the pages' tables send theirs to the system: a click on a row is the page's.
    switch (tag.to(ui.grid.Msg)) {
        _ => {},
        else => return true,
    }
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.writeAll(&.{ state_table, untracked_table, unmerged_table, unstaged_table, staged_table, commits_table, expanded_table, diff_files_table });
    // What it publishes for the status's page, and what the page reads: the sources the text
    // names, which are its own tables, and the values.
    result.writeIfPresent(tables, document_sources_table);
    result.writeIfPresent(tables, document_values_table);
    status_page.declareAccess(&result, tables);
    // The diff panel's row and folds.
    git_diff.declareAccess(&result);
    // The jobs, their answers read from their programs' tables, and their log, the `$` view.
    result.write(runner_requests_table);
    runner.declareJobs(&result, tables, sequencer.inboxOf(system()));
    if (tables.findByName(runner_log_table) != null) result.read(runner_log_table);
    // Where git runs, and the host's path, which git runs as its editor.
    if (tables.findByName(places_table) != null) result.read(places_table);
    // The project menu's `v` handing over to vcs-p4 (`global.vcs_p4_status`).
    result.writeIfPresent(tables, Atom.from(plugin.action_api.commands_table_name));
    // Telling the person, the menu of menus, the discard dialog, and visiting a file.
    result.writeIfPresent(tables, text_editor_requests);
    result.writeIfPresent(tables, transient_requests);
    result.writeIfPresent(tables, palette_requests);
    open.declareOpenAccess(&result, tables);
    // Showing, focusing and closing the panel.
    result.writeIfPresent(tables, shown_panels_table);
    result.writeIfPresent(tables, panel_requests_table);
    if (tables.findByName(panel_state_table) != null) result.readAll(&.{ panel_nodes_table, panel_state_table });
    // How tall a line is.
    if (tables.findByName(font_metrics_table) != null) result.read(font_metrics_table);
    plugin.panels.Events.declare(&result, tables, plugin.panels.events_table_name);
    // A buffer saved, and what the refresh's timer reads.
    text_editor.Events.declare(&result, tables, text_editor.events_table_name);
    vcs_timer.declareTimerAccess(&result, tables);
    modes.declarePanelModes(&result, tables, panel_modes_table_name);
    // The commit being written, its message buffer and the window it shows in.
    git_commit.declareAccess(&result, tables);
    // The log's commits and its page.
    git_log.declareAccess(&result, tables);
    // What the prompts and dialogs wait on, and the rebase's list and its page.
    git_branch.declareAccess(&result);
    git_rebase.declareAccess(&result, tables);
    return result;
}

/// Each message the panel's system claimed this frame, in order; then the views settled: the
/// runner's log's cursor brought into view when one moved it, the status's page's cursor settled
/// against the page as it is now and the folds of headings gone let go, and the log's page
/// likewise. While the diff panel is open, each move of the person's that took the
/// status's cursor onto another file shows that file in it: decided for each move, comparing the
/// row the cursor was on before it with the row after, so a refresh that settles the cursor in
/// the same frame never moves the diff panel.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const work = try Work.of(pass);
    var follow: Follow = .stay;
    for (frame.messages) |received| {
        const before = try work.statusRowAt();
        const taken = work.take(received) catch |err| {
            received.unreadable(err);
            continue;
        };
        switch (taken) {
            .stay => {},
            .cursor => follow = .cursor,
            .moved => {
                const after = try work.statusRowAt();
                if (!sameRow(before, after)) try work.followFileAtCursor();
            },
        }
    }
    if (follow == .cursor) try work.settleView();
    try vcs_page.settle(work.pass, status_page, .keep);
    try vcs_page.settle(work.pass, git_log.page, .keep);
    try vcs_page.settle(work.pass, git_rebase.page, .keep);
    for (pages) |page| {
        const moved_under = try vcs_page.movedUnder(work.pass, page);
        if (moved_under.* != 0) moved_under.* = 0;
    }
    try git_diff.endRun(work);
}

/// vcs-git's pages: the status's, the log's and the rebase list's.
const pages = [_]vcs_page.Page{ status_page, git_log.page, git_rebase.page };

/// What a message did: nothing that moves a view (`stay`), moved the runner's log's cursor or
/// brought it new lines (`cursor`), or was the person's move of the status's cursor (`moved`).
const Follow = enum { stay, cursor, moved };

/// A row of one of the status's tables, as the cursor is on it.
const RowAt = struct { table: *Table, row: Table.RowHandle };

fn sameRow(before: ?RowAt, after: ?RowAt) bool {
    const was = before orelse return after == null;
    const is = after orelse return false;
    return was.table == is.table and was.row.row == is.row.row and was.row.generation == is.row.generation;
}

/// A refresh as the focus comes to the panel, unless one runs, or a command whose end refreshes:
/// one runs as the panel opens. The focus coming back from vcs-git's own diff panel refreshes
/// nothing: what the diff panel did refreshed as it ended, and moving between the two stays
/// quick.
fn followFocus(pass: *sequencer.Pass) !void {
    const events = plugin.panels.Events.of(pass.frame.tables, plugin.panels.events_table_name);
    // All the events table keeps, so a run of sizes never pushes a focus move out unread.
    var told: [plugin.panels.Events.retained]plugin.panels.Event = undefined;
    const taken = try events.read(pass, focus_reader, &told);
    // The panels system tells the panel that lost the focus just before the one that took it.
    var lost: Atom = no_atom;
    var focused = false;
    for (taken) |event| {
        switch (event) {
            .unfocused => |id| lost = id,
            .focused => |id| {
                if (id == panel) focused = lost != git_diff.panel;
                lost = no_atom;
            },
            .resized => {},
        }
    }
    if (!focused) return;
    const work = try Work.of(pass);
    if (work.state.refresh_jobs.* != 0 or work.state.commands_running.* != 0) return;
    try work.refresh(.by_rule);
}

/// A refresh as a buffer is saved (its `changed` event says it was written to its file), while
/// the panel is shown, unless a command runs, whose end refreshes; one asked while a refresh
/// runs runs once it ends, as the save may come after what that refresh read.
fn followSaves(pass: *sequencer.Pass) !void {
    const events = text_editor.Events.of(pass.frame.tables, text_editor.events_table_name);
    var told: [text_editor.Events.retained]text_editor.Event = undefined;
    const taken = try events.read(pass, save_reader, &told);
    const saved = for (taken) |event| {
        switch (event) {
            .changed => |changed| if (changed.saved) break true,
            .opened, .closed, .copied, .paste_wanted => {},
        }
    } else false;
    if (!saved or !isShown(pass)) return;
    const work = try Work.of(pass);
    if (work.state.answered.* == 0 or work.state.commands_running.* != 0) return;
    try work.refresh(.by_rule);
}

/// The refresh's timer: while `timerInterval` says it runs, a wake of the time system's is
/// pending (`mesha.time.CmdPayload.wake`), asked for the interval as the timer starts and again
/// as each refresh starts, so it counts from the last refresh; while it does not run, the wake
/// is cancelled. The host sleeps between wakes. The wake's message (`vcs_git_timer`) is taken
/// by `Work.timerFired`. A changed interval asks the wake again.
fn followTimer(pass: *sequencer.Pass) !void {
    const stored = try pass.readSingleton(state_table, struct { timer_armed: *u8, timer_seconds: *u32, timer_asked_at: *i64 });
    const wanted = try timerInterval(pass);
    const armed_for: ?u32 = if (stored.timer_armed.* != 0) stored.timer_seconds.* else null;
    if (wanted == armed_for) {
        const seconds = wanted orelse return;
        // The time system logs a wake it cannot hold and never answers it: one not heard within
        // twice its interval is asked again.
        if (!vcs_timer.wakeOverdue(pass, stored.timer_asked_at.*, seconds)) return;
        const work = try Work.of(pass);
        return work.armTimer(seconds);
    }
    const work = try Work.of(pass);
    if (wanted) |seconds| return work.armTimer(seconds);
    work.disarmTimer();
}

/// How many seconds the refresh's timer waits between refreshes now; null while it does not
/// run: the panel not shown, another of its views shown, the engine's window without the focus
/// (the person elsewhere), or the interval 0. The interval is the setting
/// `vcs_refresh_seconds` when it is set, else the page's `#+REFRESH:`.
fn timerInterval(pass: *const sequencer.Pass) !?u32 {
    if (!isShown(pass)) return null;
    const state = try pass.readSingleton(state_table, struct { view: *u8, answered: *u8 });
    if (viewOf(state.view.*) != .status or state.answered.* == 0) return null;
    if (!vcs_timer.windowFocused(pass)) return null;
    const seconds = settingSeconds(pass) orelse pageRefreshSeconds() orelse return null;
    if (seconds == 0) return null;
    return seconds;
}

/// The setting `vcs_refresh_seconds`, when its cell is set; null when it is absent.
fn settingSeconds(pass: *const sequencer.Pass) ?u32 {
    if (!pass.declares(settings_table)) return null;
    const settings = pass.table(settings_table) catch return null;
    if (settings.getSchema().fieldIndex(keybinds.vcs_refresh_field) == null) return null;
    var rows = settings.readQuery(struct { vcs_refresh_seconds: *u32 });
    const row = rows.next() orelse return null;
    return row.view.vcs_refresh_seconds.*;
}

/// The page's `#+REFRESH:`, in seconds; null when its text says none.
fn pageRefreshSeconds() ?u32 {
    for (status_page.document.blocks) |block| {
        switch (block.content) {
            .refresh => |seconds| return seconds,
            else => {},
        }
    }
    return null;
}

/// While the panel is shown and has data, a change of the working directory, another project,
/// gives up what runs, forgets the data and refreshes.
fn followProject(pass: *sequencer.Pass) !void {
    if (!isShown(pass)) return;
    const state = try pass.readSingleton(state_table, StateRead);
    if (state.working_directory.len == 0) return;
    const where = placesOf(pass);
    if (where.working_directory.len == 0) return;
    if (std.mem.eql(u8, where.working_directory, state.working_directory)) return;
    const work = try Work.of(pass);
    try work.refresh(.by_rule);
}

/// Keeps each view fit to its panel as it is resized: the status's page keeps the size the
/// panels system told (`document.followResizes`) and its cursor in view, as the log's page
/// does, and the runner's log its scroll.
fn followLayout(pass: *sequencer.Pass) !void {
    try git_diff.followLayout(pass);
    try vcs_page.followSize(pass, status_page, panel);
    try vcs_page.followSize(pass, git_log.page, panel);
    try vcs_page.followSize(pass, git_rebase.page, panel);
    if (!isShown(pass)) return;
    const layout = process_log.layoutOf(pass, panel);
    const stored = try pass.readSingleton(state_table, struct { view_height: *f32 });
    if (stored.view_height.* == layout.view_height) return;
    const work = try Work.of(pass);
    work.state.view_height.* = layout.view_height;
    try work.settleView();
}

/// Copies the runner's `phase` while a job of the panel's runs: its change draws the panel
/// again, which turns the spinner.
fn turnSpinner(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const inbox = sequencer.inboxOf(system());
    if (!runner.busy(tables, inbox)) return;
    const turned = runner.phase(tables);
    const stored = try pass.readSingleton(state_table, struct { phase: *u32 });
    if (stored.phase.* == turned) return;
    const state = try pass.writeSingleton(state_table, struct { phase: *u32 });
    state.phase.* = turned;
}

/// The panels' major modes: the status's `vcs_git`, but in the log view the log's (`vcs_log`)
/// and in the rebase view the list's (`vcs_rebase`); the diff panel's `vcs_git_diff`.
fn followModes(pass: *sequencer.Pass) !void {
    const state = try pass.readSingleton(state_table, struct { view: *u8 });
    const major = switch (viewOf(state.view.*)) {
        .log => modes.vcs_log,
        .rebase => modes.vcs_rebase,
        .status, .process_log => modes.vcs_git,
    };
    const wanted = [_]modes.PanelMajor{
        .{ .panel = panel, .major = major },
        .{ .panel = git_diff.panel, .major = modes.vcs_git_diff },
    };
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

/// Whether the panel is shown: declared, open or about to open.
fn isShown(pass: *const sequencer.Pass) bool {
    if (!pass.declares(shown_panels_table)) return false;
    return fixed_panels.panelShown(pass.frame.tables, panel);
}

/// What the panel reads of `os_places`, each empty without it.
const Places = struct { working_directory: []const u8, home_directory: []const u8, executable: []const u8 };

fn placesOf(pass: *const sequencer.Pass) Places {
    const unknown: Places = .{ .working_directory = "", .home_directory = "", .executable = "" };
    if (!pass.declares(places_table)) return unknown;
    return pass.readSingleton(places_table, Places) catch unknown;
}

// ---- the work of a run -----------------------------------------------------------------------

/// Whether a refresh asks `Command.operation` by `git.InProgress`'s rule (`by_rule`), or asks
/// it whatever the rule says (`ask`), after a command of the panel's that may start or end an
/// operation: a merge, a rebase, a pull, a cherry-pick or a commit.
pub const OperationCheck = enum { by_rule, ask };

/// What the kernels hand their helpers: the run's pass and the panel's tables as the run writes
/// them.
pub const Work = struct {
    pass: *sequencer.Pass,
    state: StateRow,
    /// The panel's own row's table, which holds its text.
    cells: *Table,
    /// The status's files, a table a section (`FileRow`): what the page shows and the commands
    /// read.
    files: FileTables,
    commits: *Table,
    /// The page's folds (`document.FoldRow`).
    collapsed: *Table,
    expanded: *Table,
    diff_files: *Table,

    pub fn of(pass: *sequencer.Pass) !Work {
        return .{
            .pass = pass,
            .state = try pass.writeSingleton(state_table, StateRow),
            .cells = try pass.writeTable(state_table),
            .files = .{
                .untracked = try pass.writeTable(untracked_table),
                .unmerged = try pass.writeTable(unmerged_table),
                .unstaged = try pass.writeTable(unstaged_table),
                .staged = try pass.writeTable(staged_table),
            },
            .commits = try pass.writeTable(commits_table),
            .collapsed = try pass.writeTable(collapsed_table),
            .expanded = try pass.writeTable(expanded_table),
            .diff_files = try pass.writeTable(diff_files_table),
        };
    }

    fn tables(work: Work) *Table.Registry {
        return work.pass.frame.tables;
    }

    fn memory(work: Work) *memory_mod.Memory {
        return work.pass.frame.memory;
    }

    /// The frame's scratch, which the run's texts are copied into: good for the frame.
    pub fn scratch(work: Work) !std.mem.Allocator {
        const frame_scratch = try work.memory().frameScratchAllocator();
        return frame_scratch.allocator;
    }

    /// The table `name`, one of the system's, written, its text cells' dead bytes let go at the
    /// end of the frame: for a run that assigns its text.
    pub fn writeCells(work: Work, name: Atom) !*Table {
        const cells = try work.pass.writeTable(name);
        cells.compact_payloads_wanted = true;
        return cells;
    }

    /// Tells the person `text`, on the message line.
    pub fn tell(work: Work, text: []const u8) void {
        text_editor.message(work.memory(), work.tables(), text);
    }

    /// One message; returns what it did to the views' cursors.
    fn take(work: Work, received: sequencer.Message) !Follow {
        if (git_commit.claims(received.tag)) {
            try git_commit.take(work, received);
            return .stay;
        }
        if (git_branch.claims(received.tag)) {
            try git_branch.take(work, received);
            return .stay;
        }
        if (git_remote.claims(received.tag)) {
            try git_remote.take(work, received);
            return .stay;
        }
        const shown_view = viewOf(work.state.view.*);
        // The shown page's own messages, and a click on a row of one of its tables, which is
        // the grid's message.
        if (try work.takeOnPage(received)) |follow| return follow;
        if (git_log.claims(received.tag)) {
            try git_log.take(work, received);
            return .stay;
        }
        if (git_rebase.claims(received.tag)) {
            try git_rebase.take(work, received);
            return .stay;
        }
        if (git_diff.claims(received.tag)) {
            try git_diff.take(work, received);
            return .stay;
        }
        const message = received.tag.to(Msg);
        switch (shown_view) {
            .log => if (try work.takeInLog(message)) return .stay,
            .rebase => if (try work.takeInRebase(message)) return .stay,
            .status => if (try work.takeInStatus(message)) |follow| return follow,
            .process_log => if (try work.takeInProcessLog(message, received)) |follow| return follow,
        }
        switch (message) {
            .vcs_git_status => try work.show(),
            .vcs_status => {
                work.state.hand_off.* = 1;
                try work.show();
            },
            .vcs_git_refresh => try work.refresh(.by_rule),
            .vcs_git_quit => try work.quit(),
            .vcs_git_process_log => try work.showProcessLog(),
            .vcs_git_give_up => try work.giveUp(),
            .vcs_git_menu => {
                const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_git_menu_chosen));
                transient.present(work.memory(), work.tables(), .{ .menu = &menu, .reply = reply });
            },
            .vcs_git_menu_chosen => {
                const chosen = try received.payloadAs(transient.Chosen);
                if (chosen.cancelled != 0) return .stay;
                const command = std.enums.fromInt(MenuCommand, chosen.id) orelse return .stay;
                try work.dispatch(command);
            },
            .vcs_git_finished => try work.takeFinished(received),
            .vcs_git_timer => {
                try work.timerFired();
                return .stay;
            },
            .vcs_git_stage => try work.changeAtCursor(.stage),
            .vcs_git_unstage => try work.changeAtCursor(.unstage),
            .vcs_git_discard => try work.changeAtCursor(.discard),
            .vcs_git_stage_all => try work.changeSection(.unstaged, .stage),
            .vcs_git_unstage_all => try work.changeSection(.staged, .unstage),
            .vcs_git_discard_chosen => {
                const asked = try confirmedDiscard(work, received) orelse return .stay;
                try work.discardConfirmed(asked);
            },
            else => return .stay,
        }
        return .cursor;
    }

    /// A message of the shown view's page, the status's or the log's (a click, a fold mark, the
    /// wheel), or a click on a row of one of its tables (`ui.grid.Msg.cell_click`), through
    /// `document.take`: what it did, or null for a message that is not that page's. A click on
    /// what the cursor is already on is chosen, as RET chooses it. The runner's log is no page.
    fn takeOnPage(work: Work, received: sequencer.Message) !?Follow {
        const shown_view = viewOf(work.state.view.*);
        const page = switch (shown_view) {
            .status => status_page,
            .log => git_log.page,
            .rebase => git_rebase.page,
            .process_log => return null,
        };
        const tags = page.tags;
        const own = received.tag == tags.click or received.tag == tags.toggle or received.tag == tags.wheel;
        const grid_click = received.tag == Atom.from(ui.grid.Msg.cell_click);
        if (!own and !grid_click) return null;
        const laid_out = try vcs_page.laidOut(work.pass, page);
        const state = try vcs_page.stateOf(work.pass, page);
        const folds = try vcs_page.foldRows(work.pass, page);
        switch (try document.take(received, laid_out, state, folds, page.input())) {
            .ignored => return if (own) .stay else null,
            .moved, .scrolled => return .moved,
            .toggled => return .stay,
            .chosen => |chosen| {
                switch (shown_view) {
                    .status => if (!try vcs_page.changedUnderCursor(work.pass, status_page)) try work.visitAt(chosen),
                    .log => try git_log.chooseAt(work, chosen),
                    .rebase => try git_rebase.chooseAt(work, chosen),
                    .process_log => {},
                }
                return .stay;
            },
        }
    }

    /// The panel's own keys in the status, a page: moves of its cursor, folds, and `RET`.
    /// Returns null for a message the views share; the runner's log's clicks, which come late,
    /// do nothing.
    fn takeInStatus(work: Work, message: Msg) !?Follow {
        const way: document.Step = switch (message) {
            .vcs_git_next => .next,
            .vcs_git_previous => .previous,
            .vcs_git_next_sibling => .next_heading,
            .vcs_git_previous_sibling => .previous_heading,
            .vcs_git_parent => .parent,
            .vcs_git_first => .first,
            .vcs_git_last => .last,
            .vcs_git_page_down => .page_down,
            .vcs_git_page_up => .page_up,
            .vcs_git_toggle => {
                try vcs_page.fold(work.pass, status_page, .at_cursor);
                return .stay;
            },
            .vcs_git_toggle_all => {
                try vcs_page.fold(work.pass, status_page, .every);
                return .stay;
            },
            .vcs_git_visit => {
                try work.visit();
                return .stay;
            },
            .vcs_git_click, .vcs_git_chevron, .vcs_git_wheel => return .stay,
            else => return null,
        };
        const laid_out = try vcs_page.laidOut(work.pass, status_page);
        document.step(laid_out, try vcs_page.stateOf(work.pass, status_page), way);
        return .moved;
    }

    /// The panel's own keys in the runner's log view, a list of lines: its moves, folds, clicks
    /// and wheel; what acts on files tells it is not there. Returns null for a message the views
    /// share.
    fn takeInProcessLog(work: Work, message: Msg, received: sequencer.Message) !?Follow {
        const log_view = try work.processLog() orelse return null;
        switch (message) {
            .vcs_git_next => try log_view.move(.next),
            .vcs_git_previous => try log_view.move(.previous),
            .vcs_git_next_sibling => try log_view.move(.next_sibling),
            .vcs_git_previous_sibling => try log_view.move(.previous_sibling),
            .vcs_git_parent => try log_view.move(.parent),
            .vcs_git_first => try log_view.move(.first),
            .vcs_git_last => try log_view.move(.last),
            .vcs_git_page_down => try log_view.move(.page_down),
            .vcs_git_page_up => try log_view.move(.page_up),
            .vcs_git_toggle => try log_view.toggleAtCursor(),
            .vcs_git_toggle_all => try log_view.toggleAll(),
            .vcs_git_visit => {},
            .vcs_git_stage, .vcs_git_unstage, .vcs_git_discard => {
                const change: Change = switch (message) {
                    .vcs_git_stage => .stage,
                    .vcs_git_unstage => .unstage,
                    else => .discard,
                };
                work.tell(change.nothingHere());
                return .stay;
            },
            .vcs_git_click => {
                const key = (try received.userDataAs(u64)).*;
                try log_view.putCursorOn(key);
            },
            .vcs_git_chevron => {
                const key = (try received.userDataAs(u64)).*;
                try log_view.toggleKey(key);
            },
            .vcs_git_wheel => {
                const scrolled = try received.payloadAs(input.MouseScrollMsg);
                try log_view.wheel(scrolled.y);
                return .stay;
            },
            .vcs_git_document_click, .vcs_git_document_toggle, .vcs_git_document_wheel => return .stay,
            else => return null,
        }
        return .cursor;
    }

    /// The panel's own keys in the log view, a page: its moves move the page's cursor, `RET`
    /// edits the query on its line and shows the commit on a row, `g` runs the query again;
    /// what acts on files is told it is not there. Returns false for a message the views share.
    fn takeInLog(work: Work, message: Msg) !bool {
        const way: document.Step = switch (message) {
            .vcs_git_next => .next,
            .vcs_git_previous => .previous,
            .vcs_git_next_sibling => .next_heading,
            .vcs_git_previous_sibling => .previous_heading,
            .vcs_git_parent => .parent,
            .vcs_git_first => .first,
            .vcs_git_last => .last,
            .vcs_git_page_down => .page_down,
            .vcs_git_page_up => .page_up,
            .vcs_git_toggle => {
                try vcs_page.fold(work.pass, git_log.page, .at_cursor);
                return true;
            },
            .vcs_git_toggle_all => {
                try vcs_page.fold(work.pass, git_log.page, .every);
                return true;
            },
            .vcs_git_visit => {
                try git_log.visit(work);
                return true;
            },
            .vcs_git_refresh => {
                try git_log.refresh(work);
                return true;
            },
            .vcs_git_stage, .vcs_git_unstage, .vcs_git_stage_all, .vcs_git_unstage_all, .vcs_git_discard => {
                work.tell("Not in the log");
                return true;
            },
            // The status page's and the runner's log's clicks, come late.
            .vcs_git_click, .vcs_git_chevron, .vcs_git_wheel, .vcs_git_document_click, .vcs_git_document_toggle, .vcs_git_document_wheel => return true,
            else => return false,
        };
        const laid_out = try vcs_page.laidOut(work.pass, git_log.page);
        document.step(laid_out, try vcs_page.stateOf(work.pass, git_log.page), way);
        return true;
    }

    /// The panel's own keys in the rebase view, a page: its moves move the page's cursor, `RET`
    /// shows the commit of a row; what acts on files is told it is not there. `p`, which `vcs`
    /// moves with, is the list's own, as is `q`. Returns false for a message the views share.
    fn takeInRebase(work: Work, message: Msg) !bool {
        const way: document.Step = switch (message) {
            .vcs_git_next => .next,
            .vcs_git_previous => .previous,
            .vcs_git_next_sibling => .next_heading,
            .vcs_git_previous_sibling => .previous_heading,
            .vcs_git_parent => .parent,
            .vcs_git_first => .first,
            .vcs_git_last => .last,
            .vcs_git_page_down => .page_down,
            .vcs_git_page_up => .page_up,
            .vcs_git_toggle, .vcs_git_toggle_all => return true,
            .vcs_git_visit => {
                try git_rebase.visit(work);
                return true;
            },
            .vcs_git_stage, .vcs_git_unstage, .vcs_git_stage_all, .vcs_git_unstage_all, .vcs_git_discard => {
                work.tell("Not in the rebase list");
                return true;
            },
            // The other pages' and the runner's log's clicks, come late.
            .vcs_git_click, .vcs_git_chevron, .vcs_git_wheel, .vcs_git_document_click, .vcs_git_document_toggle, .vcs_git_document_wheel => return true,
            else => return false,
        };
        const laid_out = try vcs_page.laidOut(work.pass, git_rebase.page);
        document.step(laid_out, try vcs_page.stateOf(work.pass, git_rebase.page), way);
        return true;
    }

    /// Runs what the menu of menus chose: a command, or the menu of the commands it names.
    pub fn dispatch(work: Work, command: MenuCommand) !void {
        switch (command) {
            .refresh => try work.refresh(.by_rule),
            .process_log => try work.showProcessLog(),
            .quit => try work.quit(),
            .commit => git_commit.presentMenu(work),
            .log => try git_log.presentMenu(work),
            .branch => git_branch.presentBranchMenu(work),
            .merge => git_branch.presentMergeMenu(work),
            .rebase => git_rebase.presentMenu(work),
            .push => git_remote.presentPushMenu(work),
            .pull => git_remote.presentPullMenu(work),
            .fetch => git_remote.presentFetchMenu(work),
        }
    }

    /// `global.vcs_git_status`: shows the panel and gives it the focus,
    /// refreshing; while it has the focus, refreshes.
    fn show(work: Work) !void {
        const frame = work.pass.frame;
        const tables_now = work.tables();
        const atoms = frame.atoms;
        fixed_panels.showPanel(tables_now, atoms, panel, .arranged, .take);
        work.state.view.* = @intFromEnum(View.status);
        // What the page shows is published before the first answer, so no table of it reads as
        // not published.
        try work.publish();
        try work.refresh(.by_rule);
    }

    /// The project menu's `v` found no git repository here, or no git: vcs-git is hidden and
    /// vcs-p4 shown in its place (`global.vcs_p4_status`, invoked as the actions system next
    /// applies its requests).
    fn handOff(work: Work) void {
        fixed_panels.hidePanel(work.tables(), panel);
        plugin.action_api.requestInvoke(work.tables(), .{ plugin.action_api.global_mode, Atom.from("vcs_p4_status") });
    }

    /// `q`: back one view, the runner's log to the view it was shown from, the log to the
    /// status, the rebase list left as `C-c C-k` leaves it; the status closes the panel, and the
    /// focus goes where closing a panel sends it.
    fn quit(work: Work) !void {
        const state = work.state;
        switch (viewOf(state.view.*)) {
            .process_log => state.view.* = state.process_log_return.*,
            .log => state.view.* = @intFromEnum(View.status),
            .rebase => try git_rebase.leave(work),
            .status => fixed_panels.hidePanel(work.tables(), panel),
        }
    }

    /// Shows `wanted`, noting, for the runner's log, the view it goes back to.
    pub fn enterView(work: Work, wanted: View) void {
        const state = work.state;
        const current = viewOf(state.view.*);
        if (current == wanted) return;
        if (wanted == .process_log) state.process_log_return.* = @intFromEnum(current);
        state.view.* = @intFromEnum(wanted);
    }

    /// Whether the log is shown, or a view to come back to: the runner's log shown from it.
    pub fn logOnStack(work: Work) bool {
        const state = work.state;
        return switch (viewOf(state.view.*)) {
            .log => true,
            .process_log => viewOf(state.process_log_return.*) == .log,
            .status, .rebase => false,
        };
    }

    /// `$`: the runner's log of the panel's jobs, the cursor on the newest.
    fn showProcessLog(work: Work) !void {
        work.enterView(.process_log);
        const log_view = try work.processLog() orelse return;
        try log_view.showNewest();
    }

    /// `C-g`: gives up every job of the panel's, and tells which ran. A refresh that waits on
    /// answers no job will give is forgotten too, so the next one runs.
    fn giveUp(work: Work) !void {
        const tables_now = work.tables();
        const inbox = sequencer.inboxOf(system());
        const busy = runner.busy(tables_now, inbox);
        const refreshing = work.state.refresh_jobs.* != 0;
        if (!busy and !refreshing) return;
        const allocator = try work.scratch();
        const running_now = runner.running(tables_now, inbox);
        // Kept past the give-up, which frees the job's row and its text.
        const running = try allocator.dupe(u8, running_now);
        if (busy) runner.giveUp(work.memory(), tables_now, inbox);
        try work.forgetRefresh();
        if (running.len == 0) return;
        const sentence = try std.fmt.allocPrint(allocator, "Gave up: {s}", .{running});
        work.tell(sentence);
    }

    /// Moves to a new generation: the jobs queued so far are no longer the panel's to answer, a
    /// log or a show among them (`git_log.abandon`, `git_diff.abandon`).
    fn forgetRefresh(work: Work) !void {
        work.state.generation.* +%= 1;
        work.state.refresh_jobs.* = 0;
        work.state.refresh_again.* = 0;
        work.state.refresh_asked.* = 0;
        work.state.refresh_failed.* = 0;
        work.state.diffs_asked.* = 0;
        work.state.commands_running.* = 0;
        work.state.command_check.* = @intFromEnum(OperationCheck.by_rule);
        try git_log.abandon(work);
        try git_diff.abandon(work);
        try git_rebase.abandon(work);
        try git_commit.abandon(work);
    }

    // ---- the refresh ------------------------------------------------------------------------

    /// Asks git again for what the panel shows: the jobs `status` and `recent`, and those the
    /// module's comment says, run together; noted while a refresh runs, to run once it ends. A
    /// working directory not the one the panel's data is for is another project: what runs is
    /// given up and the data forgotten first. Every command of the panel's own calls it as it
    /// ends, `check` saying whether that command may have started or ended an operation.
    pub fn refresh(work: Work, check: OperationCheck) !void {
        const state = work.state;
        const where = placesOf(work.pass);
        const working_directory = work.cells.textOf(state.working_directory.*);
        const moved = !std.mem.eql(u8, where.working_directory, working_directory);
        if (moved) {
            if (working_directory.len != 0) {
                runner.giveUp(work.memory(), work.tables(), sequencer.inboxOf(system()));
                try work.forgetRefresh();
                try work.forgetData();
            }
            try work.cells.assignString(state.working_directory, where.working_directory);
        }
        if (state.refresh_jobs.* != 0) {
            const again: u8 = if (check == .ask) 2 else 1;
            state.refresh_again.* = @max(state.refresh_again.*, again);
            return;
        }
        state.refresh_asked.* = 0;
        state.refresh_failed.* = 0;
        state.refresh_quiet.* = 0;
        // The timer counts from each refresh's start.
        if (state.timer_armed.* != 0) work.armTimer(state.timer_seconds.*);
        try work.cells.assignString(state.home_directory, where.home_directory);
        try work.ask(.status);
        // In no repository, or with no git, only `status` is asked until it answers; the rest
        // follow then (`endRefresh`).
        const notice: Notice = std.enums.fromInt(Notice, state.notice.*) orelse .none;
        if (notice != .none) return;
        try work.ask(.recent);
        const ask_operation = check == .ask or operationWanted(state);
        if (ask_operation) try work.ask(.operation);
        try work.askRootUnlessKnown();
    }

    /// The timer's refresh: as `refresh`, but quiet, so a status that says what the last one
    /// said keeps the diffs held.
    fn refreshQuietly(work: Work) !void {
        try work.refresh(.by_rule);
        if (work.state.refresh_jobs.* != 0) work.state.refresh_quiet.* = 1;
    }

    /// Asks the time system for the timer's wake `seconds` from now, in place of any pending,
    /// noting when it was asked. A request the time system's table has no room for is logged
    /// and dropped, as one it rejects is: `followTimer` asks again once it is overdue.
    fn armTimer(work: Work, seconds: u32) void {
        work.state.timer_armed.* = 1;
        work.state.timer_seconds.* = seconds;
        work.state.timer_asked_at.* = vcs_timer.awakeNanoseconds(work.pass) orelse 0;
        const wake: mesha.time.Wake = .{ .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.vcs_git_timer), .after = @floatFromInt(seconds) };
        work.appendWake(.wake, wake);
    }

    /// Takes the timer's wake back: the timer does not run.
    fn disarmTimer(work: Work) void {
        work.state.timer_armed.* = 0;
        const wake: mesha.time.Wake = .{ .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.vcs_git_timer) };
        work.appendWake(.cancel_wake, wake);
    }

    /// Appends a wake's request to the time system's, which the run declared written; nothing
    /// without it.
    fn appendWake(work: Work, op: mesha.time.CommandOp, wake: mesha.time.Wake) void {
        if (!work.pass.writes(time_commands)) return;
        const commands = work.pass.writeTable(time_commands) catch return;
        mesha.time.appendWake(commands, op, wake) catch |err| {
            Log.warn("timer_request_dropped", .{ .@"error" = @errorName(err) });
        };
    }

    /// The timer's wake came: a quiet refresh, unless one or a command runs, whose end brings the
    /// tables up to date, so one is never doubled; the wake is asked again either way while the
    /// timer runs (a refresh's start asks it). A wake that comes after the timer stopped does
    /// nothing.
    fn timerFired(work: Work) !void {
        const state = work.state;
        if (state.timer_armed.* == 0) return;
        const seconds = try timerInterval(work.pass) orelse return work.disarmTimer();
        if (state.refresh_jobs.* != 0 or state.commands_running.* != 0) return work.armTimer(seconds);
        try work.refreshQuietly();
        // Not started (the working directory moved, the refresh noted): count again.
        if (state.refresh_jobs.* == 0) work.armTimer(seconds);
    }

    fn askRootUnlessKnown(work: Work) !void {
        const root_known = work.cells.textOf(work.state.root.*).len != 0;
        if (!root_known) try work.ask(.root);
    }

    /// Queues the job for `purpose`, a refresh's, counted in the refresh that runs.
    fn ask(work: Work, purpose: Purpose) !void {
        try work.queueAsked(purpose, 0);
        work.state.refresh_jobs.* += 1;
        work.state.refresh_asked.* |= purpose.bit();
    }

    /// Queues the job that asks git what `purpose` reads, with the panel's others: a diff's
    /// carries `diff_epoch`.
    fn queueAsked(work: Work, purpose: Purpose, diff_epoch: u32) !void {
        const allocator = try work.scratch();
        var argv: std.Io.Writer.Allocating = .init(allocator);
        const command = purpose.gitCommand();
        try git.writeArgv(&argv.writer, command);
        work.queue(.{ .purpose = purpose, .argv = argv.written(), .shown = purpose.shown(), .epoch = diff_epoch });
    }

    /// Queues a query of the log's (`log`, `refs` or `show`), its command line `argv`, with the
    /// panel's other jobs, carrying `epoch`, the count of its kind asked, which its answer is
    /// checked against.
    pub fn queueQuery(work: Work, purpose: Purpose, argv: []const u8, epoch: u32) void {
        work.queue(.{ .purpose = purpose, .argv = argv, .shown = purpose.shown(), .epoch = epoch });
    }

    /// Queues the job that asks git what `command` reads for `purpose`, with the panel's other
    /// jobs, carrying `epoch`, the count of its kind asked, which its answer is checked against;
    /// its environment's sequence editor is the one `command` runs with.
    pub fn queueRead(work: Work, purpose: Purpose, command: git.Command, epoch: u32) !void {
        const allocator = try work.scratch();
        var argv: std.Io.Writer.Allocating = .init(allocator);
        try git.writeArgv(&argv.writer, command);
        work.queue(.{ .purpose = purpose, .argv = argv.written(), .shown = purpose.shown(), .epoch = epoch, .sequence = git.sequenceEditorOf(command) });
    }

    /// Asks for `HEAD`'s message, which `git_commit.takeHeadMessage` takes as it answers.
    pub fn askHeadMessage(work: Work) !void {
        try work.queueAsked(.head_message, 0);
    }

    /// Queues `job` in the repository's root once it is known and the working directory before,
    /// with git's variables, the panel's generation in its user data.
    fn queue(work: Work, job: Queued) void {
        const state = work.state;
        const where = placesOf(work.pass);
        const root = work.cells.textOf(state.root.*);
        const directory = if (root.len != 0) root else work.cells.textOf(state.working_directory.*);
        var environment_buffer: [environment_bytes]u8 = undefined;
        const environment = environmentOf(&environment_buffer, where.executable, job.sequence);
        const data: JobData = .{ .generation = state.generation.*, .purpose = @intFromEnum(job.purpose), .command = @intFromEnum(job.command), .epoch = job.epoch, .fixup_target = job.fixup_target };
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_git_finished)).with(.of(&data));
        runner.run(work.memory(), work.tables(), .{
            .owner = reply,
            .argv = job.argv,
            .input = job.input,
            .environment = environment,
            .directory = directory,
            .order = job.order,
            .shown = job.shown,
        });
    }

    /// A job's answer: read, then released whatever came of it. An answer of an earlier
    /// generation, or of a job the runner no longer holds, is dropped. The last answer of a
    /// refresh ends it.
    fn takeFinished(work: Work, received: sequencer.Message) !void {
        const finished = (try received.payloadAs(runner.Finished)).*;
        const data = (try received.userDataAs(JobData)).*;
        defer runner.release(work.memory(), work.tables(), finished.job);
        const state = work.state;
        if (data.generation != state.generation.*) return;
        const purpose = std.enums.fromInt(Purpose, data.purpose) orelse return;
        switch (purpose) {
            .command => return work.takeCommandEnd(data, finished),
            .unstaged_diff => return work.takeDiff(.unstaged, data, finished),
            .staged_diff => return work.takeDiff(.staged, data, finished),
            .head_message, .log, .refs, .remotes, .show, .rebase_list, .rebase_todo, .resolve => {
                const said = runner.output(work.tables(), finished.job);
                const succeeded = runner.ranWell(finished, said);
                const answer: ?[]const u8 = if (succeeded) said.?.said else null;
                return switch (purpose) {
                    .head_message => git_commit.takeHeadMessage(work, answer),
                    .log => git_log.takeLog(work, data.epoch, answer),
                    .refs => git_branch.takeListing(work, .refs, data.epoch, answer),
                    .remotes => git_branch.takeListing(work, .remotes, data.epoch, answer),
                    .show => git_diff.takeShow(work, data.epoch, answer),
                    .rebase_list => git_rebase.takeList(work, data.epoch, answer),
                    .rebase_todo => git_rebase.takeRest(work, data.epoch, answer),
                    .resolve => git_branch.takeResolved(work, data.epoch, answer),
                    else => unreachable,
                };
            },
            .status, .recent, .operation, .rebase_check, .root => {},
        }
        state.refresh_jobs.* -|= 1;
        // The runner let the job go before its answer was read (released past
        // `max_unreleased`): what it said is lost, and the refresh counts it failed.
        const said = runner.output(work.tables(), finished.job) orelse {
            state.refresh_failed.* |= purpose.bit();
            // The status's answer lost: the project menu's hand-over decides nothing on it.
            if (purpose == .status) state.hand_off.* = 0;
            if (state.refresh_jobs.* == 0) try work.endRefresh();
            return;
        };
        const ran = finished.started == @intFromEnum(process.SpawnResult.spawned);
        const succeeded = runner.ranWell(finished, said);
        if (!succeeded) state.refresh_failed.* |= purpose.bit();
        switch (purpose) {
            .status => {
                if (succeeded) {
                    try work.takeStatus(said.said);
                } else if (finished.started == @intFromEnum(process.SpawnResult.not_found)) {
                    try work.showNotice(.git_missing);
                } else if (ran and finished.code == not_a_repository_code) {
                    try work.showNotice(.not_repository);
                }
                const not_git = !succeeded and std.enums.fromInt(Notice, state.notice.*) != .none;
                if (state.hand_off.* != 0 and not_git) work.handOff();
                state.hand_off.* = 0;
            },
            .recent => if (succeeded) try work.takeRecent(said.said),
            .operation => if (succeeded) {
                const found = git.parseInProgress(said.said);
                state.operation.* = @intFromEnum(found.operation);
                state.operation_stop.* = @intFromEnum(found.stop);
                try work.cells.assignString(state.operation_commit, found.commit);
                try work.cells.assignString(state.operation_amend, found.amend);
                // A refused list lasts as long as its rebase.
                if (found.operation != .rebasing) state.rebase_refused.* = 0;
            },
            .rebase_check => if (ran) switch (git.rebaseCheckAnswer(finished.code)) {
                .rebasing => {
                    state.operation.* = @intFromEnum(git.Operation.rebasing);
                    state.operation_stop.* = @intFromEnum(git.RebaseStop.none);
                    try work.cells.assignString(state.operation_commit, "");
                    try work.cells.assignString(state.operation_amend, "");
                    state.refresh_failed.* &= ~purpose.bit();
                },
                .not_rebasing => {
                    state.rebase_refused.* = 0;
                    const oid = work.cells.textOf(state.oid.*);
                    try work.cells.assignString(state.checked_oid, oid);
                    state.refresh_failed.* &= ~purpose.bit();
                },
                // git found a rebase, then failed: one is in progress, the failure told.
                .failed => {
                    state.operation.* = @intFromEnum(git.Operation.rebasing);
                    state.operation_stop.* = @intFromEnum(git.RebaseStop.none);
                    try work.cells.assignString(state.operation_commit, "");
                    try work.cells.assignString(state.operation_amend, "");
                },
                // git told nothing (a signal ended it): what the status held stands.
                .unknown => {},
            },
            .root => if (succeeded) {
                const root = git.parseRoot(said.said);
                try work.cells.assignString(state.root, root);
            },
            .command, .unstaged_diff, .staged_diff, .head_message, .log, .refs, .remotes, .show, .rebase_list, .rebase_todo, .resolve => unreachable,
        }
        try work.publish();
        if (state.refresh_jobs.* == 0) try work.endRefresh();
    }

    /// The refresh's last answer is in: what it showed is needed is asked next, as one more
    /// process; else each failure is told, and a refresh asked for meanwhile runs.
    fn endRefresh(work: Work) !void {
        const state = work.state;
        const notice: Notice = std.enums.fromInt(Notice, state.notice.*) orelse .none;
        if (notice == .none) {
            const asked = state.refresh_asked.*;
            const failed = state.refresh_failed.*;
            const head: git.Head = std.enums.fromInt(git.Head, state.head.*) orelse .branch;
            const operation: git.Operation = std.enums.fromInt(git.Operation, state.operation.*) orelse .none;
            const detached = head == .detached;
            const operation_asked = asked & Purpose.operation.bit() != 0;
            const operation_failed = failed & Purpose.operation.bit() != 0;
            const check_asked = asked & Purpose.rebase_check.bit() != 0;
            const status_read = failed & Purpose.status.bit() == 0;
            const recent_asked = asked & Purpose.recent.bit() != 0;
            // A status read after a notice: the rest of a first refresh follows.
            if (status_read and !recent_asked) {
                try work.ask(.recent);
                try work.ask(.operation);
                return work.askRootUnlessKnown();
            }
            const conflicted = state.unmerged_count.* != 0;
            if (status_read and !operation_asked and (detached or conflicted)) return work.ask(.operation);
            const oid = work.cells.textOf(state.oid.*);
            const checked = work.cells.textOf(state.checked_oid.*);
            const unchecked = !std.mem.eql(u8, oid, checked);
            const wants_check = operation_asked and !operation_failed and !check_asked and operation == .none and detached and unchecked;
            if (wants_check) return work.ask(.rebase_check);
            try work.tellFailures();
        }
        // Read before the bits go: whether what the status holds is this refresh's.
        const status_read = notice == .none and state.refresh_failed.* & Purpose.status.bit() == 0;
        const status_outcome: git_rebase.StatusRead = if (status_read) .read else .unread;
        state.refresh_asked.* = 0;
        state.refresh_failed.* = 0;
        if (state.refresh_again.* == 0) {
            // The refresh that follows no other: what it read is what is now, its status read or
            // not.
            try git_rebase.refreshEnded(work, status_outcome);
            try git_commit.refreshEnded(work, status_outcome);
            return work.askWantedDiffs();
        }
        const again_check: OperationCheck = if (state.refresh_again.* == 2) .ask else .by_rule;
        state.refresh_again.* = 0;
        try work.refresh(again_check);
    }

    /// A command's answer: a failure is told, a commit's end is the commit's to take up, and the
    /// end of the last command queued refreshes, whether it failed or not, asking for the
    /// operation in progress when one of those queued may have changed it.
    fn takeCommandEnd(work: Work, data: JobData, finished: runner.Finished) !void {
        const state = work.state;
        state.commands_running.* -|= 1;
        const name = std.enums.fromInt(CommandName, data.command) orelse .none;
        if (name.operationCheck() == .ask) state.command_check.* = @intFromEnum(OperationCheck.ask);
        // An answer whose job the runner let go is lost: the command counts as failed.
        const said = runner.output(work.tables(), finished.job);
        const succeeded = runner.ranWell(finished, said);
        if (!succeeded) {
            const allocator = try work.scratch();
            const sentence = try std.fmt.allocPrint(allocator, "git {s} failed; $ shows why", .{name.subcommand()});
            work.tell(sentence);
        }
        switch (name) {
            .commit => {
                const outcome: git_commit.Outcome = if (succeeded) .succeeded else .failed;
                try git_commit.commitEnded(work, outcome);
            },
            .commit_extend => if (succeeded) try git_commit.otherCommitEnded(work, .extend, ""),
            .commit_fixup => if (succeeded) try git_commit.otherCommitEnded(work, .fixup, data.fixupTarget()),
            .delete_branch => {
                // git refuses `-d` of a branch not merged with its exit code 1.
                const ran = finished.started == @intFromEnum(process.SpawnResult.spawned);
                const refused = !succeeded and ran and finished.code == 1 and said != null;
                try git_branch.deleteEnded(work, refused);
            },
            .rebase, .rebase_edit_todo, .rebase_continue, .rebase_skip => {
                const given: git_rebase.Given = switch (name) {
                    .rebase => .new_rebase,
                    .rebase_edit_todo => .rest,
                    else => .go_on,
                };
                const outcome: git_rebase.Outcome = if (succeeded) .succeeded else .failed;
                try git_rebase.commandEnded(work, given, outcome);
            },
            else => {},
        }
        // `HEAD` moved, by a commit made or another: a log to come back to lists what it is now.
        if (succeeded and name.movesHead()) try git_log.followCommit(work);
        if (state.commands_running.* != 0) return;
        const check = std.enums.fromInt(OperationCheck, state.command_check.*) orelse .by_rule;
        state.command_check.* = @intFromEnum(OperationCheck.by_rule);
        try work.refresh(check);
    }

    /// A diff's answer: kept for the files the diff panel shows, unless a status or a give-up
    /// forgot it meanwhile. A failure is told, and the diff counts as loaded and empty, so the
    /// diff panel shows no hunks until the next refresh asks again.
    fn takeDiff(work: Work, side: git.Side, data: JobData, finished: runner.Finished) !void {
        const state = work.state;
        if (data.epoch != state.diff_epoch.*) return;
        const bit = diffBit(side);
        state.diffs_asked.* &= ~bit;
        const said = runner.output(work.tables(), finished.job);
        const succeeded = runner.ranWell(finished, said);
        const bytes = if (succeeded) said.?.said else "";
        const cell = switch (side) {
            .unstaged => state.unstaged_diff,
            .staged => state.staged_diff,
        };
        cell.* = .{ .payload = try work.cells.appendPayload(bytes, .@"16") };
        state.diffs_loaded.* |= bit;
        try work.indexDiff(.ofSide(side), bytes);
        if (!succeeded) work.tell("git diff failed; $ shows why");
        try git_diff.diffRead(work, side);
    }

    /// Records in `editor_vcs_git_diff_files` where each file's part of `bytes`, `source`'s diff,
    /// is, the first `max_diff_files` of them, and how many the diff holds: parsed once, as the
    /// diff answers, so the diff panel parses a file's part alone.
    fn indexDiff(work: Work, source: DiffSource, bytes: []const u8) !void {
        const allocator = try work.scratch();
        const file_room = @min(countFiles(bytes), max_diff_files);
        const files = try allocator.alloc(git.FileDiff, file_room);
        const counts = try git.parseDiff(bytes, allocator, files, &.{});
        const kept = files[0..counts.files.kept];
        for (kept, 0..) |file, index| {
            const offset = @intFromPtr(file.header.ptr) - @intFromPtr(bytes.ptr);
            const end = if (index + 1 < kept.len)
                @intFromPtr(kept[index + 1].header.ptr) - @intFromPtr(bytes.ptr)
            else
                nextFileOffset(bytes, offset + file.header.len);
            const path = diffPath(file);
            const old_path = if (file.old_path.len != 0) file.old_path else path;
            _ = try work.diff_files.tryInsert(.{
                .source = @as(u8, @intFromEnum(source)),
                .path = path,
                .old_path = old_path,
                .change = @as(u8, @intFromEnum(file.change)),
                .offset = @as(u32, @intCast(offset)),
                .length = @as(u32, @intCast(end - offset)),
            });
        }
        const seen = switch (source) {
            .unstaged => work.state.unstaged_files_seen,
            .staged => work.state.staged_files_seen,
            .shown => work.state.shown_files_seen,
        };
        seen.* = counts.files.seen;
    }

    /// Asks for the diff the diff panel shows a file of, unless it is loaded or asked for.
    fn askWantedDiffs(work: Work) !void {
        const side = try git_diff.wantedSide(work) orelse return;
        try work.askDiff(side);
    }

    /// Asks for `side`'s diff, one process for the whole tree, unless it is loaded or asked
    /// for, or a refresh or a command runs, whose end asks for it once what they change is
    /// read.
    pub fn askDiff(work: Work, side: git.Side) !void {
        const state = work.state;
        const bit = diffBit(side);
        if ((state.diffs_loaded.* | state.diffs_asked.*) & bit != 0) return;
        if (state.refresh_jobs.* != 0 or state.commands_running.* != 0) return;
        const notice: Notice = std.enums.fromInt(Notice, state.notice.*) orelse .none;
        if (state.answered.* == 0 or notice != .none) return;
        const purpose = Purpose.ofDiff(side);
        try work.queueAsked(purpose, state.diff_epoch.*);
        state.diffs_asked.* |= bit;
    }

    /// Tells each job of the refresh that failed, but `recent` when the status read shows no
    /// commit yet, as it fails then.
    fn tellFailures(work: Work) !void {
        const state = work.state;
        const status_read = state.refresh_failed.* & Purpose.status.bit() == 0;
        const no_commit = work.cells.textOf(state.oid.*).len == 0;
        if (status_read and no_commit) {
            state.refresh_failed.* &= ~Purpose.recent.bit();
            work.commits.clear();
            try work.publish();
        }
        const allocator = try work.scratch();
        const told = [_]Purpose{ .status, .recent, .operation, .rebase_check, .root };
        for (told) |purpose| {
            if (state.refresh_failed.* & purpose.bit() == 0) continue;
            const sentence = try std.fmt.allocPrint(allocator, "git {s} failed; $ shows why", .{purpose.subcommand()});
            work.tell(sentence);
        }
    }

    /// What `status` said, in place of what the panel held: its files written into their
    /// tables, a cell only where what it holds changed, and the page's cursor kept on the file it
    /// was on while that is still in its table.
    fn takeStatus(work: Work, said: []const u8) !void {
        const state = work.state;
        const allocator = try work.scratch();
        const parsed_entries = try allocator.alloc(git.Entry, max_entries);
        const status = git.parseStatus(said, parsed_entries);
        state.notice.* = @intFromEnum(Notice.none);
        state.answered.* = 1;
        state.head.* = @intFromEnum(status.head);
        try work.cells.assignString(state.branch, status.branch);
        try work.cells.assignString(state.oid, status.oid);
        try work.cells.assignString(state.upstream, status.upstream);
        state.upstream_state.* = @intFromEnum(status.upstream_state);
        state.ahead.* = status.ahead;
        state.behind.* = status.behind;
        state.stash_count.* = status.stash_count;
        state.staged_count.* = status.staged_count;
        state.unstaged_count.* = status.unstaged_count;
        state.untracked_count.* = status.untracked_count;
        state.unmerged_count.* = status.unmerged_count;
        // The diffs read before, and those asked before, are of what this status replaces;
        // but a quiet refresh's status that says what the last one said keeps them, so the diff
        // panel shows what it showed and asks nothing. The status says only which files changed,
        // not how: a file changed again outside the editor, still modified as it was, keeps its
        // diff as it was read, stale until `g` or another refresh asks again; a stale hunk staged
        // or discarded from it is one `git apply` that no longer applies, which fails and changes
        // nothing.
        const fingerprint = std.hash.Wyhash.hash(0, said);
        const unchanged = state.refresh_quiet.* != 0 and fingerprint == state.status_fingerprint.*;
        state.status_fingerprint.* = fingerprint;
        if (!unchanged) try work.forgetDiffs();
        const kept = try work.cursorRow();
        const entries = parsed_entries[0..status.entries.kept];
        for (file_sections) |section| try work.writeFiles(section, entries);
        try work.keepCursorOn(kept);
    }

    /// The rows of `section`'s table written from `entries`, those of them under it, in order:
    /// the rows the table needs kept, in its own order (`table_view.rowsInOrder`), each cell
    /// written only when it changed.
    fn writeFiles(work: Work, section: SectionKind, entries: []const git.Entry) !void {
        const table = work.files.of(section) orelse return;
        var count: u32 = 0;
        for (entries) |entry| {
            if (belongs(entry, section)) count += 1;
        }
        const allocator = try work.scratch();
        const handles = try table_view.rowsInOrder(table, count, allocator);
        var index: usize = 0;
        for (entries) |entry| {
            if (!belongs(entry, section)) continue;
            const handle = handles[index];
            index += 1;
            const change = try changeOf(allocator, entry, section);
            const shown_path = try shownPathOf(allocator, entry, section);
            const letters = [2]u8{ entry.staged, entry.unstaged };
            // Each leaves a cell that holds its text as it is.
            try table.setString(handle, "change", change);
            try table.setString(handle, "path", shown_path);
            try table.setString(handle, "git_path", entry.path);
            try table.setString(handle, "original_path", entry.original_path);
            try table.setString(handle, "letters", &letters);
        }
    }

    /// What `recent` said, in place of the commits the panel held, written as `writeFiles`
    /// writes files, the cursor kept on its commit.
    fn takeRecent(work: Work, said: []const u8) !void {
        var parsed: [git.recent_count]git.LogEntry = undefined;
        // `recent`'s own query: what it could not read is nothing to say.
        const read = git.parseLog(said, &parsed);
        const kept = try work.cursorRow();
        const commits = parsed[0..read.commits.kept];
        const allocator = try work.scratch();
        const handles = try table_view.rowsInOrder(work.commits, @intCast(commits.len), allocator);
        for (commits, handles) |commit, handle| {
            const refs = try ui.displayText(allocator, commit.refs);
            const subject = try ui.displayText(allocator, commit.subject);
            const author = try ui.displayText(allocator, commit.author);
            // Each leaves a cell that holds its text as it is.
            try work.commits.setString(handle, "hash", commit.short_hash);
            try work.commits.setString(handle, "refs", refs);
            try work.commits.setString(handle, "subject", subject);
            try work.commits.setString(handle, "author", author);
            try work.commits.setString(handle, "date", commit.date);
            try work.commits.setString(handle, "full_hash", commit.hash);
        }
        try work.keepCursorOn(kept);
    }

    /// Publishes what the page shows: the five tables as its sources, and the values its text
    /// names, from the panel's row and its newest commit. What is published already as it is,
    /// is not written again, so each answer may publish.
    pub fn publish(work: Work) !void {
        const publishing = try document_sources.Publishing.of(work.pass) orelse return;
        const sources = [_]SectionKind{ .untracked, .unmerged, .unstaged, .staged, .recent };
        for (sources) |section| {
            const shown: []const []const u8 = if (section == .recent) &commit_shown else &file_shown;
            publishing.publishSource(publisher, .{ .name = section.sourceName(), .table = section.table().?, .shown = shown });
        }
        const allocator = try work.scratch();
        const state = try work.pass.readSingleton(state_table, StateRead);
        const values = try valuesOf(allocator, state, work.commits);
        publishing.publishValue(publisher, "vcs-git.branch", values.branch);
        publishing.publishValue(publisher, "vcs-git.head-subject", values.head_subject);
        publishing.publishValue(publisher, "vcs-git.upstream", values.upstream);
        publishing.publishValue(publisher, "vcs-git.ahead-behind", values.ahead_behind);
        publishing.publishValue(publisher, "vcs-git.operation", values.operation);
        const stashes = if (state.stash_count.* == 0) "" else try std.fmt.allocPrint(allocator, "{d}", .{state.stash_count.*});
        publishing.publishValue(publisher, "vcs-git.stashes", stashes);
        // Each heading says how many files the status counted, listed or not.
        for (file_sections) |section| {
            const counted = try std.fmt.allocPrint(allocator, "{d}", .{countOf(state, section)});
            publishing.publishValue(publisher, section.countName(), counted);
        }
        publishing.publishValue(publisher, "vcs-git.unlisted", try unlistedOf(allocator, state, work.files));
        const clean = state.answered.* != 0 and state.untracked_count.* == 0 and state.unmerged_count.* == 0 and state.unstaged_count.* == 0 and state.staged_count.* == 0;
        publishing.publishValue(publisher, "vcs-git.clean", if (clean) "Nothing to commit, working tree clean" else "");
    }

    /// Shows `notice` in place of the page, the data forgotten.
    fn showNotice(work: Work, notice: Notice) !void {
        try work.forgetData();
        work.state.notice.* = @intFromEnum(notice);
    }

    /// Forgets the status's two diffs: their bytes and where their files are are let go,
    /// neither is loaded, and the answer of one asked before is dropped as it comes (a new
    /// epoch). The shown commit's stays.
    fn forgetDiffs(work: Work) !void {
        const state = work.state;
        state.unstaged_diff.* = .{};
        state.staged_diff.* = .{};
        const status_bits = DiffSource.unstaged.bit() | DiffSource.staged.bit();
        state.diffs_loaded.* &= ~status_bits;
        state.diffs_asked.* &= ~status_bits;
        state.diff_epoch.* +%= 1;
        state.unstaged_files_seen.* = 0;
        state.staged_files_seen.* = 0;
        try work.forgetDiffFiles(&.{ .unstaged, .staged });
    }

    /// Frees the rows of `editor_vcs_git_diff_files` of the diffs `sources`.
    fn forgetDiffFiles(work: Work, sources: []const DiffSource) !void {
        const allocator = try work.scratch();
        var gone: std.ArrayList(Table.RowHandle) = .empty;
        var rows = work.diff_files.readQuery(DiffFileRow);
        while (rows.next()) |row| {
            const source = std.enums.fromInt(DiffSource, row.view.source.*) orelse continue;
            if (std.mem.indexOfScalar(DiffSource, sources, source) == null) continue;
            try gone.append(allocator, row.handle);
        }
        for (gone.items) |handle| work.diff_files.free(handle);
    }

    /// Forgets the commit shown, to show `hash` in its place: its bytes and where its files are
    /// are let go, and the answer of a show asked before is dropped as it comes. Returns the
    /// count of shows asked, the new show's epoch.
    pub fn forgetShown(work: Work, hash: []const u8) !u32 {
        const state = work.state;
        state.shown_commit.* = .{};
        state.diffs_loaded.* &= ~DiffSource.shown.bit();
        state.shown_files_seen.* = 0;
        state.show_serial.* +%= 1;
        try work.cells.assignString(state.shown_hash, hash);
        try work.forgetDiffFiles(&.{.shown});
        return state.show_serial.*;
    }

    /// Keeps `bytes`, what `show` said of the commit shown, and where each file's part of
    /// `diff`, its changes, a slice of `bytes`, is.
    pub fn keepShown(work: Work, bytes: []const u8, diff: []const u8) !void {
        const state = work.state;
        state.shown_commit.* = .{ .payload = try work.cells.appendPayload(bytes, .@"16") };
        state.diffs_loaded.* |= DiffSource.shown.bit();
        try work.indexDiff(.shown, diff);
    }

    /// Forgets everything read of the repository, and where the cursors were: a diff asked for
    /// is dropped as it answers.
    fn forgetData(work: Work) !void {
        const state = work.state;
        try work.cells.assignString(state.root, "");
        try work.cells.assignString(state.branch, "");
        try work.cells.assignString(state.oid, "");
        try work.cells.assignString(state.upstream, "");
        try work.cells.assignString(state.checked_oid, "");
        try work.forgetDiffs();
        _ = try work.forgetShown("");
        try git_log.forgetLog(work);
        try git_diff.forget(work);
        try git_rebase.forget(work);
        state.answered.* = 0;
        state.notice.* = @intFromEnum(Notice.none);
        state.head.* = @intFromEnum(git.Head.branch);
        state.upstream_state.* = @intFromEnum(git.Upstream.none);
        state.operation.* = @intFromEnum(git.Operation.none);
        state.operation_stop.* = @intFromEnum(git.RebaseStop.none);
        try work.cells.assignString(state.operation_commit, "");
        try work.cells.assignString(state.operation_amend, "");
        state.rebase_refused.* = 0;
        state.ahead.* = 0;
        state.behind.* = 0;
        state.stash_count.* = 0;
        state.staged_count.* = 0;
        state.unstaged_count.* = 0;
        state.untracked_count.* = 0;
        state.unmerged_count.* = 0;
        document.setCursor(try vcs_page.stateOf(work.pass, status_page), .{});
        for (file_sections) |section| work.files.of(section).?.clear();
        work.commits.clear();
        work.collapsed.clear();
        work.expanded.clear();
        try work.publish();
    }

    // ---- the runner's log view: a list of lines ---------------------------------------------

    /// The runner's log view as this run moves through it: its lines from the panel's jobs the
    /// runner logged, its cursor in the panel's row. Only while it is shown: its cursor is not
    /// kept for another view.
    fn processLog(work: Work) !?process_log.View {
        if (viewOf(work.state.view.*) != .process_log) return null;
        const log: ?*Table = if (work.pass.declares(runner_log_table)) try work.pass.table(runner_log_table) else null;
        return .{
            .pass = work.pass,
            .sources = .{ .expanded = work.expanded, .log = log, .owner = sequencer.inboxOf(system()) },
            .cursor = .{ .key = work.state.process_log_key, .index = work.state.process_log_index, .scroll = work.state.process_log_scroll },
            .panel = panel,
        };
    }

    /// The runner's log's cursor settled against its lines as they are, while it is shown, and
    /// the view scrolled to show it.
    fn settleView(work: Work) !void {
        const log_view = try work.processLog() orelse return;
        try log_view.settle();
    }

    // ---- the pages -----------------------------------------------------------------------------

    /// The row of a table the status's cursor is on, while the status is shown; null on a
    /// heading or a line, or in another view.
    fn statusRowAt(work: Work) !?RowAt {
        if (viewOf(work.state.view.*) != .status) return null;
        return switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| .{ .table = row.table, .row = row.row },
            .heading, .group, .text, .none => null,
        };
    }

    /// The row the cursor is on, remembered across a refresh that writes its table again: its
    /// table's section, its block's key, and the cell that names it (a file's path as git gave
    /// it, a commit's full hash), in the frame's memory. Null off a row.
    fn cursorRow(work: Work) !?KeptRow {
        const row = switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| row,
            .heading, .group, .text, .none => return null,
        };
        const section = SectionKind.ofSource(row.source);
        const allocator = try work.scratch();
        const named = switch (section) {
            .none => return null,
            .recent => blk: {
                const commit = row.table.getRow(row.row, CommitRow) orelse return null;
                break :blk commit.full_hash;
            },
            else => blk: {
                const file = row.table.getRow(row.row, FileRow) orelse return null;
                break :blk file.git_path;
            },
        };
        return .{ .section = section, .block = row.key, .name = try allocator.dupe(u8, named) };
    }

    /// The cursor put back on the row that names what `kept` named, its table written again,
    /// the scroll as it was; where nothing names it now, the cursor is left for the page's
    /// settle, which keeps its place.
    fn keepCursorOn(work: Work, kept: ?KeptRow) !void {
        const remembered = kept orelse return;
        const handle = work.rowNaming(remembered.section, remembered.name) orelse {
            // The row under the cursor now holds what nobody has seen there yet.
            const moved_under = try vcs_page.movedUnder(work.pass, status_page);
            moved_under.* = 1;
            return;
        };
        try vcs_page.putCursorOnRow(work.pass, status_page, remembered.block, handle);
    }

    /// The row of `section`'s table that names `name`: a file's path as git gave it, a commit's
    /// full hash.
    fn rowNaming(work: Work, section: SectionKind, name: []const u8) ?Table.RowHandle {
        if (section == .recent) {
            var commits = work.commits.readQuery(CommitRow);
            while (commits.next()) |row| {
                if (std.mem.eql(u8, row.view.full_hash, name)) return row.handle;
            }
            return null;
        }
        const table = work.files.of(section) orelse return null;
        var files = table.readQuery(FileRow);
        while (files.next()) |row| {
            if (std.mem.eql(u8, row.view.git_path, name)) return row.handle;
        }
        return null;
    }

    /// `RET`: what the cursor is on, shown or opened (`visitAt`).
    fn visit(work: Work) !void {
        if (try vcs_page.changedUnderCursor(work.pass, status_page)) return;
        try work.visitAt(try vcs_page.atCursor(work.pass, status_page));
    }

    /// `RET` on `at`, or a click on what the cursor is on: a file of the unmerged, unstaged or
    /// staged table, or a recent commit, shown in the diff panel; an untracked file opened in a
    /// text window, or told why it cannot be. A heading or a line does nothing.
    fn visitAt(work: Work, at: document.At) !void {
        const row = switch (at) {
            .row => |row| row,
            .heading, .group, .text, .none => return,
        };
        const section = SectionKind.ofSource(row.source);
        const allocator = try work.scratch();
        switch (section) {
            .none => {},
            .recent => {
                const commit = row.table.getRow(row.row, CommitRow) orelse return;
                const hash = try allocator.dupe(u8, commit.full_hash);
                try git_diff.show(work, .{ .commit = .{ .hash = hash } });
            },
            .untracked => {
                const file = row.table.getRow(row.row, FileRow) orelse return;
                try work.visitFile(entryOfRow(section, file), section);
            },
            .unmerged, .unstaged, .staged => {
                const file = row.table.getRow(row.row, FileRow) orelse return;
                const path = try allocator.dupe(u8, file.git_path);
                try git_diff.show(work, .{ .file = .{ .side = section.side().?, .path = path } });
            },
        }
    }

    /// The status's cursor moved onto another row by the person: while the diff panel is open, a
    /// file of the unmerged, unstaged or staged table is shown in it (`git_diff.follow`). A
    /// heading, an untracked file or a commit leaves it showing what it showed.
    fn followFileAtCursor(work: Work) !void {
        if (viewOf(work.state.view.*) != .status) return;
        if (!git_diff.isOpen(work.pass)) return;
        const row = switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| row,
            .heading, .group, .text, .none => return,
        };
        const section = SectionKind.ofSource(row.source);
        const side = section.side() orelse return;
        const file = row.table.getRow(row.row, FileRow) orelse return;
        const allocator = try work.scratch();
        const path = try allocator.dupe(u8, file.git_path);
        try git_diff.follow(work, .{ .file = .{ .side = side, .path = path } });
    }

    // ---- staging ----------------------------------------------------------------------------

    /// `s`, `u` or `k`: `change` of what the cursor is on. A discard asks first.
    fn changeAtCursor(work: Work, change: Change) !void {
        if (work.rootUnknown()) return;
        if (try vcs_page.changedUnderCursor(work.pass, status_page)) return;
        const at = try vcs_page.atCursor(work.pass, status_page);
        const planned = try work.planAt(at, change);
        switch (planned) {
            .tell => |sentence| work.tell(sentence),
            .run => |plan| switch (change) {
                .discard => {
                    const reply_tag = Atom.from(Msg.vcs_git_discard_chosen);
                    try work.askToDiscard(plan, try work.discardKeyOf(at), reply_tag);
                },
                .stage, .unstage => try work.runPlanned(plan),
            },
        }
    }

    /// What `change` of `at` runs, or what is told in its place: a file's row, by `planFile`; a
    /// heading over a table, every row of it, by `planSection`; anything else, nothing.
    fn planAt(work: Work, at: document.At, change: Change) !Planned {
        switch (at) {
            .row => |row| {
                const section = SectionKind.ofSource(row.source);
                if (change.refusal(section)) |sentence| return .{ .tell = sentence };
                const file = row.table.getRow(row.row, FileRow) orelse return .{ .tell = change.nothingHere() };
                const allocator = try work.scratch();
                return planFile(allocator, entryOfRow(section, file), section, change, work.hasCommit());
            },
            .heading => |heading| {
                const source = heading.source orelse return .{ .tell = change.nothingHere() };
                return work.planSectionOf(SectionKind.ofSource(source), change);
            },
            .group, .text, .none => return .{ .tell = change.nothingHere() },
        }
    }

    /// What `change` of every file of `section`'s table runs, as on its heading.
    fn planSectionOf(work: Work, section: SectionKind, change: Change) !Planned {
        if (change.refusal(section)) |sentence| return .{ .tell = sentence };
        const allocator = try work.scratch();
        const table = work.files.of(section) orelse return .{ .tell = change.nothingHere() };
        const entries = try entriesOf(allocator, section, table);
        const counted = try work.countedIn(section);
        return planSection(allocator, entries, section, counted, change, work.hasCommit());
    }

    /// `S` and `U`: `change` of every file of `section`, as on its heading.
    fn changeSection(work: Work, section: SectionKind, change: Change) !void {
        if (work.rootUnknown()) return;
        switch (try work.planSectionOf(section, change)) {
            .tell => |sentence| work.tell(sentence),
            .run => |plan| try work.runPlanned(plan),
        }
    }

    /// What names `at` for the discard dialog, to be found again as it answers: a file's row by
    /// its section and its path as git gave it, a heading by its table's section.
    fn discardKeyOf(work: Work, at: document.At) !u64 {
        _ = work;
        switch (at) {
            .row => |row| {
                const section = SectionKind.ofSource(row.source);
                const file = row.table.getRow(row.row, FileRow) orelse return 0;
                return discardKey(section, file.git_path);
            },
            .heading => |heading| {
                const source = heading.source orelse return 0;
                return discardKey(SectionKind.ofSource(source), "");
            },
            .group, .text, .none => return 0,
        }
    }

    /// The discard dialog's yes: the row or the heading it was asked on, found again in the
    /// tables as they are now, is thrown away, but only when what would be thrown away is what
    /// the dialog named (`asked.fingerprint`); gone meanwhile, or changed, it is told and nothing
    /// runs.
    fn discardConfirmed(work: Work, asked: DiscardAsked) !void {
        if (work.rootUnknown()) return;
        const planned = try work.planDiscardOf(asked.key) orelse return work.tell("It is no longer there");
        switch (planned) {
            .tell => |sentence| work.tell(sentence),
            .run => |plan| {
                const now = fingerprintOf(plan.run);
                if (now != asked.fingerprint) return work.tell("It changed meanwhile; k asks again");
                try work.runPlanned(plan);
            },
        }
    }

    /// The discard of what `key` names (`discardKey`), planned again over the tables as they
    /// are; null when nothing it names is there.
    fn planDiscardOf(work: Work, key: u64) !?Planned {
        const allocator = try work.scratch();
        for (file_sections) |section| {
            if (discardKey(section, "") == key) return try work.planSectionOf(section, .discard);
            const table = work.files.of(section).?;
            var rows = table.readQuery(FileRow);
            while (rows.next()) |row| {
                if (discardKey(section, row.view.git_path) != key) continue;
                const entry = entryOfRow(section, fileRowOf(row.view));
                return try planFile(allocator, entry, section, .discard, work.hasCommit());
            }
        }
        return null;
    }

    /// Whether the repository's root is not known yet, which the paths the commands are given
    /// are from: it is told then, and nothing runs.
    pub fn rootUnknown(work: Work) bool {
        const root = work.cells.textOf(work.state.root.*);
        if (root.len != 0) return false;
        work.tell(root_unknown);
        return true;
    }

    /// How many files the last status counted in `section`, listed or not.
    fn countedIn(work: Work, section: SectionKind) !u32 {
        const state = try work.pass.readSingleton(state_table, StateRead);
        return countOf(state, section);
    }

    /// Runs `plan`, then tells of the files of its table the panel does not list, which it
    /// left as they are.
    pub fn runPlanned(work: Work, plan: Plan) !void {
        try work.runPlan(plan.run);
        if (plan.unlisted == 0) return;
        const allocator = try work.scratch();
        const sentence = try std.fmt.allocPrint(allocator, "{d} more were not listed and were left as they are", .{plan.unlisted});
        work.tell(sentence);
    }

    /// Whether `HEAD` has a commit, as the last status said.
    pub fn hasCommit(work: Work) HeadCommit {
        const oid = work.cells.textOf(work.state.oid.*);
        return if (oid.len != 0) .committed else .unborn;
    }

    /// Asks, in a dialog, whether to discard what `plan` throws away: its answer comes to this
    /// system as `reply_tag` (the status's `vcs_git_discard_chosen`, or the diff panel's), with
    /// `key`, what names what it was asked on, and the plan's fingerprint as its user data
    /// (`DiscardAsked`), which `confirmedDiscard` reads.
    pub fn askToDiscard(work: Work, plan: Plan, key: u64, reply_tag: Atom) !void {
        const asked: DiscardAsked = .{ .key = key, .fingerprint = fingerprintOf(plan.run) };
        const reply = sequencer.ReplyTo.of(system(), reply_tag).with(.of(&asked));
        try vcs_ask.presentDialog(work.memory(), work.tables(), prompt_owner, plan.question, reply);
    }

    /// Queues what `run` says, each process alone, as each writes the index or the working
    /// tree; a path git cannot be given is told and nothing more runs.
    fn runPlan(work: Work, run: Run) !void {
        const allocator = try work.scratch();
        switch (run) {
            .paths => |batch| {
                var paths: std.Io.Writer.Allocating = .init(allocator);
                git.writePaths(&paths.writer, batch.paths) catch |err| return work.tellUnpassable(err);
                try work.runCommand(batch.command, paths.written());
            },
            .hunk => |one| {
                var patch: std.Io.Writer.Allocating = .init(allocator);
                try diff_widget.patch(&patch.writer, one.header, one.hunk);
                try work.runCommand(.{ .apply = one.how }, patch.written());
            },
            .clean => |paths| {
                var rest = paths;
                while (rest.len != 0) {
                    var argv: std.Io.Writer.Allocating = .init(allocator);
                    const taken = git.writeClean(&argv.writer, rest) catch |err| return work.tellUnpassable(err);
                    work.queueCommand(.clean, argv.written(), "");
                    rest = rest[taken..];
                }
            },
        }
    }

    fn tellUnpassable(work: Work, err: git.WriteError) !void {
        switch (err) {
            error.UnpassableArgument => work.tell("A path git cannot be given: nothing more was run"),
            error.WriteFailed => return error.OutOfMemory,
        }
    }

    /// Queues `command` with `input`, alone.
    /// Its command line is as long as its arguments are: a long name is git's to refuse.
    pub fn runCommand(work: Work, command: git.Command, input_bytes: []const u8) !void {
        const allocator = try work.scratch();
        var argv: std.Io.Writer.Allocating = .init(allocator);
        try git.writeArgv(&argv.writer, command);
        var fixup_target: [fixup_target_length]u8 = @splat(0);
        switch (command) {
            .commit => |commit| if (commit.kind == .fixup) {
                const short = commit.target[0..@min(commit.target.len, fixup_target_length)];
                @memcpy(fixup_target[0..short.len], short);
            },
            else => {},
        }
        work.queue(.{ .purpose = .command, .command = CommandName.of(command), .argv = argv.written(), .input = input_bytes, .order = .alone, .shown = CommandName.of(command).shown(), .fixup_target = fixup_target });
        work.state.commands_running.* +|= 1;
    }

    /// Queues a command of the panel's, alone, counted until it answers.
    fn queueCommand(work: Work, name: CommandName, argv: []const u8, input_bytes: []const u8) void {
        work.queue(.{ .purpose = .command, .command = name, .argv = argv, .input = input_bytes, .order = .alone, .shown = name.shown() });
        work.state.commands_running.* +|= 1;
    }

    /// `RET` on an untracked file, `entry`, of `section`: opened in a text window, or told why
    /// it cannot be.
    fn visitFile(work: Work, entry: git.Entry, section: SectionKind) !void {
        const allocator = try work.scratch();
        const deleted = switch (section) {
            .unstaged => entry.unstaged == 'D',
            .staged => entry.staged == 'D',
            else => false,
        };
        if (deleted) {
            const sentence = try std.fmt.allocPrint(allocator, "{s} is deleted: there is no file to open", .{entry.path});
            return work.tell(sentence);
        }
        if (std.mem.endsWith(u8, entry.path, "/")) {
            const sentence = try std.fmt.allocPrint(allocator, "{s} is a directory: open its files with C-x C-f", .{entry.path});
            return work.tell(sentence);
        }
        const root = work.cells.textOf(work.state.root.*);
        if (root.len == 0) return work.tell(root_unknown);
        const path = try open.joinedPath(allocator, root, entry.path);
        try open.openPath(work.pass, path, .present);
    }

    /// The commit the cursor is on, for a command that takes one (`c f`): the one entry point
    /// every such command goes through. Its full hash, the table's text, good for the run, on a
    /// recent commit's row of the status or a row of the log; `none` off a commit; `changed`,
    /// told, when an answer earlier in the run put another commit under the cursor
    /// (`changedUnderCursor`), so nothing acts on a commit the person has not seen there.
    pub fn commitAtCursor(work: Work) !CommitAt {
        const shown_view = viewOf(work.state.view.*);
        // The runner's log and the rebase list show no status: its cursor is not the person's
        // to act on from there (`?` opens the commit, branch and rebase menus in every view).
        if (shown_view == .process_log or shown_view == .rebase) return .none;
        const page = if (shown_view == .log) git_log.page else status_page;
        if (try vcs_page.changedUnderCursor(work.pass, page)) return .changed;
        if (shown_view == .log) {
            const hash = try git_log.commitAtCursor(work) orelse return .none;
            return .{ .commit = hash };
        }
        const row = switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| row,
            .heading, .group, .text, .none => return .none,
        };
        if (SectionKind.ofSource(row.source) != .recent) return .none;
        const commit = row.table.getRow(row.row, CommitRow) orelse return .none;
        return .{ .commit = commit.full_hash };
    }
};

/// What `Work.commitAtCursor` found under the cursor.
pub const CommitAt = union(enum) {
    /// A commit: its full hash, the table's text, good for the run.
    commit: []const u8,
    /// No commit is there.
    none,
    /// An answer earlier in the run put another commit there, which was told.
    changed,
};

/// The status's files, a table a section, as a run writes them or the draw reads them.
pub const FileTables = struct {
    untracked: *Table,
    unmerged: *Table,
    unstaged: *Table,
    staged: *Table,

    /// The table of `section`; null for one that has none of files.
    pub fn of(files: FileTables, section: SectionKind) ?*Table {
        return switch (section) {
            .untracked => files.untracked,
            .unmerged => files.unmerged,
            .unstaged => files.unstaged,
            .staged => files.staged,
            .recent, .none => null,
        };
    }

    /// The tables as the draw reads them; null without them.
    pub fn in(tables: *Table.Registry) ?FileTables {
        return .{
            .untracked = tables.findByName(untracked_table) orelse return null,
            .unmerged = tables.findByName(unmerged_table) orelse return null,
            .unstaged = tables.findByName(unstaged_table) orelse return null,
            .staged = tables.findByName(staged_table) orelse return null,
        };
    }
};

/// A file of the status, as the diff panel finds it: its entry and the section it is under.
pub const FileFound = struct { entry: git.Entry, section: SectionKind };

/// The status's file at `path` on `side`, its text the table's: under the staged table for the
/// staged side, the unmerged or the unstaged for the other; null once the status no longer
/// lists it there.
pub fn fileOn(files: FileTables, side: git.Side, path: []const u8) ?FileFound {
    const sections: []const SectionKind = switch (side) {
        .staged => &.{.staged},
        .unstaged => &.{ .unmerged, .unstaged },
    };
    for (sections) |section| {
        var rows = files.of(section).?.readQuery(FileRow);
        while (rows.next()) |row| {
            if (!std.mem.eql(u8, row.view.git_path, path)) continue;
            return .{ .entry = entryOfRow(section, fileRowOf(row.view)), .section = section };
        }
    }
    return null;
}

/// A file table's row read by a query, as a `FileRow`: its text the table's.
fn fileRowOf(read: Table.ReadView(FileRow)) FileRow {
    return .{ .change = read.change, .path = read.path, .git_path = read.git_path, .original_path = read.original_path, .letters = read.letters };
}

/// A file's row as `git.Entry` has it, for `planFile` and the diff panel: its kind from its
/// table (a rename's from its original path), its letters, its paths as git gave them.
pub fn entryOfRow(section: SectionKind, file: FileRow) git.Entry {
    const staged_letter: u8 = if (file.letters.len > 0) file.letters[0] else '.';
    const unstaged_letter: u8 = if (file.letters.len > 1) file.letters[1] else '.';
    const kind: git.EntryKind = switch (section) {
        .untracked => .untracked,
        .unmerged => .unmerged,
        else => if (file.original_path.len != 0) .renamed else .changed,
    };
    return .{ .kind = kind, .staged = staged_letter, .unstaged = unstaged_letter, .path = file.git_path, .original_path = file.original_path };
}

/// The files of `table`, `section`'s, in the order of its rows, which is the order git gave
/// them; their text the table's.
fn entriesOf(allocator: std.mem.Allocator, section: SectionKind, table: *Table) ![]git.Entry {
    const found = try allocator.alloc(git.Entry, table.count());
    var count: usize = 0;
    var rows = table.readQuery(FileRow);
    while (rows.next()) |row| {
        if (count == found.len) break;
        found[count] = entryOfRow(section, fileRowOf(row.view));
        count += 1;
    }
    return found[0..count];
}

/// A row remembered across a refresh (`Work.cursorRow`).
const KeptRow = struct { section: SectionKind, block: u64, name: []const u8 };

/// What publishes the status's sources and values: the system, by its root's name.
const publisher = vcs_git_root;

/// The key the discard dialog names a row by, its section and its path as git gave it, or a
/// heading by its section and no path. Never 0.
fn discardKey(section: SectionKind, path: []const u8) u64 {
    const key = std.hash.Wyhash.hash(@intFromEnum(section), path);
    return if (key == 0) 1 else key;
}

/// Whether `entry` is listed under `section`: a file changed both in the index and the working
/// tree is under both.
pub fn belongs(entry: git.Entry, section: SectionKind) bool {
    const tracked = entry.kind == .changed or entry.kind == .renamed;
    return switch (section) {
        .untracked => entry.kind == .untracked,
        .unmerged => entry.kind == .unmerged,
        .unstaged => tracked and entry.unstaged != '.',
        .staged => tracked and entry.staged != '.',
        .recent, .none => false,
    };
}

/// How many files the status counted in `section`, listed or not.
pub fn countOf(state: StateRead, section: SectionKind) u32 {
    return switch (section) {
        .untracked => state.untracked_count.*,
        .unmerged => state.unmerged_count.*,
        .unstaged => state.unstaged_count.*,
        .staged => state.staged_count.*,
        .recent, .none => 0,
    };
}

/// What became of `entry` under `section`, as a word a person reads, in `allocator`.
fn changeOf(allocator: std.mem.Allocator, entry: git.Entry, section: SectionKind) ![]const u8 {
    const word = switch (section) {
        .untracked => "untracked",
        .unmerged => unmergedWord(entry.staged, entry.unstaged),
        .unstaged => changeWord(entry.unstaged),
        .staged => changeWord(entry.staged),
        .recent, .none => "",
    };
    if (entry.submodule != .submodule) return word;
    return std.fmt.allocPrint(allocator, "{s} submodule", .{word});
}

/// `entry`'s path as a person reads it under `section`, a staged rename as `old -> new`, in
/// `allocator`.
fn shownPathOf(allocator: std.mem.Allocator, entry: git.Entry, section: SectionKind) ![]const u8 {
    const path = try ui.displayText(allocator, entry.path);
    const renamed = section == .staged and entry.kind == .renamed and entry.original_path.len != 0;
    if (!renamed) return path;
    const original = try ui.displayText(allocator, entry.original_path);
    return std.fmt.allocPrint(allocator, "{s} -> {s}", .{ original, path });
}

/// A change's letter as a word.
fn changeWord(letter: u8) []const u8 {
    return switch (letter) {
        'M' => "modified",
        'T' => "typechange",
        'A' => "added",
        'D' => "deleted",
        'R' => "renamed",
        'C' => "copied",
        else => "changed",
    };
}

/// A conflict's two letters as words: who changed, added or deleted the file.
fn unmergedWord(ours: u8, theirs: u8) []const u8 {
    const pair = [2]u8{ ours, theirs };
    const words = [_]struct { letters: []const u8, word: []const u8 }{
        .{ .letters = "UU", .word = "both modified" },
        .{ .letters = "AA", .word = "both added" },
        .{ .letters = "DD", .word = "both deleted" },
        .{ .letters = "AU", .word = "added by us" },
        .{ .letters = "UA", .word = "added by them" },
        .{ .letters = "DU", .word = "deleted by us" },
        .{ .letters = "UD", .word = "deleted by them" },
    };
    for (words) |known| {
        if (std.mem.eql(u8, known.letters, &pair)) return known.word;
    }
    return "unmerged";
}

/// The values the page's text names, as a person reads them, in `allocator` or the tables'.
const Values = struct {
    branch: []const u8,
    head_subject: []const u8,
    upstream: []const u8,
    ahead_behind: []const u8,
    operation: []const u8,
};

/// The page's values from `state`, the panel's row, and `commits`, its recent commits: the
/// branch (or the commit the head is detached at), the subject of the head's commit, the
/// upstream and how far ahead and behind of it, and the operation in progress with what to
/// press; each empty where there is nothing to say.
fn valuesOf(allocator: std.mem.Allocator, state: StateRead, commits: *Table) !Values {
    const head: git.Head = std.enums.fromInt(git.Head, state.head.*) orelse .branch;
    const branch = switch (head) {
        .branch => try ui.displayText(allocator, state.branch),
        .detached => try std.fmt.allocPrint(allocator, "detached at {s}", .{state.oid[0..@min(state.oid.len, 7)]}),
    };
    var newest = commits.readQuery(CommitRow);
    const first = newest.next();
    const at_head = if (first) |row| std.mem.eql(u8, row.view.full_hash, state.oid) else false;
    const head_subject = if (state.answered.* == 0)
        ""
    else if (state.oid.len == 0)
        "no commits yet"
    else if (at_head)
        first.?.view.subject
    else
        "";
    const upstream_state: git.Upstream = std.enums.fromInt(git.Upstream, state.upstream_state.*) orelse .none;
    const has_upstream = state.upstream.len != 0;
    const upstream = if (has_upstream) try ui.displayText(allocator, state.upstream) else "";
    const ahead_behind = if (!has_upstream)
        ""
    else switch (upstream_state) {
        .gone => "gone",
        .none, .tracking => try aheadBehind(allocator, state.ahead.*, state.behind.*),
    };
    const operation: git.Operation = std.enums.fromInt(git.Operation, state.operation.*) orelse .none;
    const stop: git.RebaseStop = std.enums.fromInt(git.RebaseStop, state.operation_stop.*) orelse .none;
    const sentence = operationSentence(.{
        .operation = operation,
        .stop = stop,
        .conflicted = state.unmerged_count.* != 0,
        .amended_since = state.operation_amend.len != 0 and !std.mem.eql(u8, state.operation_amend, state.oid),
        .list_refused = state.rebase_refused.* != 0,
    });
    return .{ .branch = branch, .head_subject = head_subject, .upstream = upstream, .ahead_behind = ahead_behind, .operation = sentence };
}

/// What the page says of the files the status counted and the panel does not list, past the
/// `max_entries` it keeps, in `allocator`: each section with some, by its count and its name,
/// as `7 untracked files are not listed (the panel lists at most 4096 files)`, so a section dropped
/// whole, whose heading the page leaves out with its empty table, is told too; empty when
/// every file is listed.
fn unlistedOf(allocator: std.mem.Allocator, state: StateRead, files: FileTables) ![]const u8 {
    var said: std.Io.Writer.Allocating = .init(allocator);
    var parts: usize = 0;
    var total: u32 = 0;
    for (file_sections) |section| {
        const counted = countOf(state, section);
        const listed = files.of(section).?.count();
        if (counted <= listed) continue;
        total += counted - listed;
        parts += 1;
    }
    if (parts == 0) return "";
    var written: usize = 0;
    for (file_sections) |section| {
        const counted = countOf(state, section);
        const listed = files.of(section).?.count();
        if (counted <= listed) continue;
        const left = counted - listed;
        const nouns = section.nouns();
        const noun = if (left == 1) nouns[0] else nouns[1];
        const between = if (written == 0) "" else if (written + 1 == parts) " and " else ", ";
        try said.writer.print("{s}{d} {s}", .{ between, left, noun });
        written += 1;
    }
    const verb = if (total == 1) "is" else "are";
    // At most: a file in two sections is a row in each, so the panel may list fewer files.
    try said.writer.print(" {s} not listed (the panel lists at most {d} files)", .{ verb, max_entries });
    return said.written();
}

/// How far ahead and behind of the upstream, as `+2 -1`, each count only when it is not 0:
/// the ui font has no arrows. `up to date` when both are.
fn aheadBehind(allocator: std.mem.Allocator, ahead: u32, behind: u32) ![]const u8 {
    if (ahead == 0 and behind == 0) return "up to date";
    if (behind == 0) return std.fmt.allocPrint(allocator, "+{d}", .{ahead});
    if (ahead == 0) return std.fmt.allocPrint(allocator, "-{d}", .{behind});
    return std.fmt.allocPrint(allocator, "+{d} -{d}", .{ ahead, behind });
}

/// What `operationSentence` reads: the operation, and for a rebase where it stopped, whether a
/// conflict is unresolved, whether a commit was made since an `edit` stopped (`HEAD` no longer
/// what `rebase-merge/amend` holds), and whether git refused the panel's list.
const Stopped = struct {
    operation: git.Operation,
    stop: git.RebaseStop,
    conflicted: bool,
    amended_since: bool,
    list_refused: bool,
};

/// What the operation in progress waits for, by the keys of the menus that go on or give up;
/// empty while none is.
fn operationSentence(stopped: Stopped) []const u8 {
    return switch (stopped.operation) {
        .none => "",
        .merging => "Merging; resolve the conflicts, stage them, then c c to commit, or m a to abort",
        // A list git did not run: `r r`, `r s` and `r e` run nothing then and tell this, so
        // `r a` is all there is to offer.
        .rebasing => if (stopped.list_refused)
            "Rebasing, but git did not run the list ($ shows why): r a aborts and leaves the branch as it was, then r i lists again"
        else if (stopped.conflicted)
            "Rebasing, stopped on a conflict; resolve it and stage it, then r r continues; r s skips the commit, r a aborts, r e edits the rest"
        else switch (stopped.stop) {
            .on_commit => if (stopped.amended_since)
                // `--continue` amends only while HEAD is the commit it stopped on.
                "Rebasing, stopped on a commit, and HEAD moved since it stopped: r r goes on from where it is; r s skips, r a aborts, r e edits the rest"
            else
                "Rebasing, stopped on a commit; change it (c a amends, c w rewords), then r r continues; r s skips it, r a aborts, r e edits the rest",
            // HEAD is the commit before the one that conflicted: an amend would fold that one
            // into it.
            .on_conflict => "Rebasing, stopped on a resolved conflict; r r commits it and goes on, r s skips it, r a aborts, r e edits the rest",
            .between_commits => "Rebasing, stopped at a break; c w rewords HEAD, then r r continues; r a aborts, r e edits the rest",
            .none => "Rebasing; r r continues, r s skips, r a aborts, r e edits the rest",
        },
        .cherry_picking => "Cherry-picking; resolve the conflicts, stage them, then c c to commit",
        .reverting => "Reverting; resolve the conflicts, stage them, then c c to commit",
        .bisecting => "Bisecting",
    };
}

/// The most files of a diff the panel indexes (`editor_vcs_git_diff_files`): past them, the
/// diff panel says the diff is cut.
pub const max_diff_files = 4096;

/// The path a file of a diff is known by: its new one, or the old one of a deleted file. A diff
/// without renames names a file by one path.
pub fn diffPath(file: git.FileDiff) []const u8 {
    return if (file.new_path.len != 0) file.new_path else file.old_path;
}

/// A job as `Work.queue` takes it: its slices are copied as it is queued.
const Queued = struct {
    purpose: Purpose,
    /// For `Purpose.command`, which.
    command: CommandName = .none,
    argv: []const u8,
    input: []const u8 = "",
    order: runner.Order = .shared,
    shown: []const u8,
    /// For a diff's job, the epoch it was asked in; for a log's, the refs' or a show's, the
    /// count of its kind asked.
    epoch: u32 = 0,
    /// What git's sequence editor does in the job's environment (`git.sequenceEditorOf`).
    sequence: git.SequenceEditor = .write_input,
    /// For a fixup's commit, `JobData.fixup_target`.
    fixup_target: [fixup_target_length]u8 = @splat(0),
};

// ---- what staging runs -------------------------------------------------------------------------

/// What a staging key does to what the cursor is on, of the status or the diff panel.
pub const Change = enum {
    stage,
    unstage,
    discard,

    /// What is told when the cursor is on nothing `change` acts on.
    pub fn nothingHere(change: Change) []const u8 {
        return switch (change) {
            .stage => "Nothing to stage here",
            .unstage => "Nothing to unstage here",
            .discard => "Nothing to discard here",
        };
    }

    /// What is told for `change` on a line of `section` it does not apply to; null where it
    /// applies.
    pub fn refusal(change: Change, section: SectionKind) ?[]const u8 {
        return switch (change) {
            .stage => switch (section) {
                .untracked, .unmerged, .unstaged => null,
                .staged => "Already staged",
                .recent, .none => change.nothingHere(),
            },
            .unstage => switch (section) {
                .staged => null,
                .untracked, .unmerged, .unstaged => "Not staged",
                .recent, .none => change.nothingHere(),
            },
            .discard => switch (section) {
                .untracked, .unstaged => null,
                .staged => "Unstage it first",
                .unmerged => "Resolve it, or abort the merge",
                .recent, .none => change.nothingHere(),
            },
        };
    }
};

/// Whether `HEAD` has a commit: before the first, unstaging takes the files out of the index.
pub const HeadCommit = enum { committed, unborn };

/// The discard dialog's user data: the line it was asked on, and what it named.
pub const DiscardAsked = extern struct {
    /// The line's key.
    key: u64,
    /// `fingerprintOf` the plan the dialog named.
    fingerprint: u64,
};

/// The discard dialog's answer, `received`: the line it was asked on and what it named when the
/// person confirmed, the dialog acknowledged; null for a cancel, a dismissal, or an event that
/// is not the dialog's end.
pub fn confirmedDiscard(work: Work, received: sequencer.Message) !?DiscardAsked {
    const event = try action_palette.eventOf(received);
    if (event.kind != .completed) return null;
    action_palette.request(work.memory(), work.tables(), .{ .acknowledge = .{ .owner = prompt_owner } });
    if (!vcs_ask.confirmed(event.completion)) return null;
    return (try received.userDataAs(DiscardAsked)).*;
}

/// A hash of what `run` acts on: its kind, its command, and its paths in order or its patch's
/// bytes. Two plans with the same fingerprint throw away the same changes.
pub fn fingerprintOf(run: Run) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(@tagName(run));
    switch (run) {
        .paths => |batch| {
            hasher.update(@tagName(batch.command));
            hashPaths(&hasher, batch.paths);
        },
        .hunk => |one| {
            hasher.update(@tagName(one.how));
            hasher.update(one.header);
            hasher.update(one.hunk.header);
            hasher.update(one.hunk.body);
        },
        .clean => |paths| hashPaths(&hasher, paths),
    }
    return hasher.final();
}

fn hashPaths(hasher: *std.hash.Wyhash, paths: []const []const u8) void {
    for (paths) |path| {
        hasher.update(path);
        hasher.update("\x00");
    }
}

/// What a staging key runs: each in as few processes as git allows.
pub const Run = union(enum) {
    /// `stage`, `unstage`, `unstage_unborn` or `discard`, its paths on its input: one process.
    paths: struct { command: git.Command, paths: []const []const u8 },
    /// `apply` of one hunk, its patch on its input: one process.
    hunk: struct { how: git.Apply, header: []const u8, hunk: diff_widget.Hunk },
    /// `clean` of untracked files, its paths as arguments: a process for each batch
    /// `git.writeClean` takes.
    clean: []const []const u8,
};

/// What a staging key runs, for a discard what its dialog asks, and how many files of its
/// section it leaves as they are, not being listed.
pub const Plan = struct {
    run: Run,
    question: vcs_ask.Question = .{},
    unlisted: u32 = 0,
};

/// What a staging key does: runs a plan, or tells why it does not.
pub const Planned = union(enum) {
    tell: []const u8,
    run: Plan,
};

/// What `change` runs for `entry`, a file of `section`'s table, where it applies: the status's
/// row, or the diff panel's file.
pub fn planFile(allocator: std.mem.Allocator, entry: git.Entry, section: SectionKind, change: Change, head: HeadCommit) !Planned {
    const shown_path = try ui.displayText(allocator, entry.path);
    if (change == .discard and section == .untracked) {
        if (std.mem.endsWith(u8, entry.path, "/")) return .{ .tell = "Cannot delete a directory here" };
        const paths = try allocator.dupe([]const u8, &.{entry.path});
        return .{ .run = .{ .run = .{ .clean = paths }, .question = .{ .title = "Delete file?", .body = shown_path, .confirm = "Delete" } } };
    }
    var paths: std.ArrayList([]const u8) = .empty;
    try appendPaths(allocator, &paths, entry, change);
    const command = commandOf(change, head);
    return .{ .run = .{
        .run = .{ .paths = .{ .command = command, .paths = paths.items } },
        .question = .{ .title = "Discard changes?", .body = shown_path, .confirm = "Discard" },
    } };
}

/// What `change` runs for every file of `section` the panel lists, `entries`, of `counted`, as
/// on its heading: one process with all their paths, but for deleting untracked files, which
/// `clean` takes in batches.
fn planSection(allocator: std.mem.Allocator, entries: []const git.Entry, section: SectionKind, counted: u32, change: Change, head: HeadCommit) !Planned {
    if (change.refusal(section)) |sentence| return .{ .tell = sentence };
    // Untracked files are deleted with `clean`, which is not given a directory.
    const deletes = change == .discard and section == .untracked;
    var paths: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;
    var listed: u32 = 0;
    for (entries) |entry| {
        if (!belongs(entry, section)) continue;
        listed += 1;
        if (deletes and std.mem.endsWith(u8, entry.path, "/")) continue;
        try appendPaths(allocator, &paths, entry, change);
        files += 1;
    }
    if (files == 0) return .{ .tell = change.nothingHere() };
    const unlisted = counted -| listed;
    if (deletes) {
        const title = try std.fmt.allocPrint(allocator, "Delete all {d} untracked files?", .{files});
        return .{ .run = .{ .run = .{ .clean = paths.items }, .question = .{ .title = title, .confirm = "Delete" }, .unlisted = unlisted } };
    }
    const command = commandOf(change, head);
    const run: Run = .{ .paths = .{ .command = command, .paths = paths.items } };
    if (change != .discard) return .{ .run = .{ .run = run, .unlisted = unlisted } };
    const title = try std.fmt.allocPrint(allocator, "Discard all {d} unstaged changes?", .{files});
    return .{ .run = .{ .run = run, .question = .{ .title = title, .confirm = "Discard" }, .unlisted = unlisted } };
}

/// The paths `change` of `entry` names: its own, and for unstaging a rename its original's too,
/// as unstaging a rename whole takes both.
fn appendPaths(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), entry: git.Entry, change: Change) !void {
    try paths.append(allocator, entry.path);
    const renamed = entry.kind == .renamed and entry.original_path.len != 0;
    if (change == .unstage and renamed) try paths.append(allocator, entry.original_path);
}

/// The command that does `change` with paths on its input.
fn commandOf(change: Change, head: HeadCommit) git.Command {
    return switch (change) {
        .stage => .stage,
        .unstage => switch (head) {
            .committed => .unstage,
            .unborn => .unstage_unborn,
        },
        .discard => .discard,
    };
}

/// What is told when the repository's root, which a file's path is from, is not known yet.
pub const root_unknown = "The repository's root is not known yet: g asks again";

/// git's exit code when the directory is in no repository.
const not_a_repository_code = 128;

/// Room for git's variables: the host's path twice, quoted, and the names.
const environment_bytes = 2 * (2 * mesha.resources.max_path + 64);

/// `git.writeEnvironment`'s variables for the host at `executable`, its sequence editor as
/// `sequence` says, in `buffer`; only
/// `GIT_TERMINAL_PROMPT=0` when the host's path is not known or cannot be passed, so git never
/// waits on a password, and a command that starts git's editor fails.
fn environmentOf(buffer: []u8, executable: []const u8, sequence: git.SequenceEditor) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    git.writeEnvironment(&writer, executable, sequence) catch return "GIT_TERMINAL_PROMPT=0";
    return writer.buffered();
}

/// How many files `bytes`, a diff, may hold, at most: its lines that begin as a file's
/// (`diff `), which is all `git.parseDiff` needs room for.
fn countFiles(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff ")) count += 1;
    }
    return count;
}

/// Where the next file of `bytes`, a diff, begins: the first line from `from`, the end of a
/// file's header, that begins `diff `; the end when there is none.
fn nextFileOffset(bytes: []const u8, from: usize) usize {
    // The header ends with its line break: the search begins on it.
    const newline = std.mem.indexOfPos(u8, bytes, from -| 1, "\ndiff ") orelse return bytes.len;
    return newline + 1;
}

/// Whether a refresh asks `Command.operation` by `git.InProgress`'s rule, from what the panel
/// holds: on the first refresh, while the last answer was not none, and while the status shows
/// conflicts or a detached head.
fn operationWanted(state: StateRow) bool {
    if (state.answered.* == 0) return true;
    if (state.operation.* != @intFromEnum(git.Operation.none)) return true;
    if (state.unmerged_count.* != 0) return true;
    return state.head.* == @intFromEnum(git.Head.detached);
}
