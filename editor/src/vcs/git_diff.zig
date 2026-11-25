//! vcs-git's diff panel, `vcs_git_diff`: one file's changes on one side of the index, or one
//! commit's, as an outline of files, hunks and their lines drawn with `mesha.ui.diff`. A part
//! of vcs-git's system (`git_status.zig`): what the panel shows, its cursor and its folds are
//! this file's tables, while the diffs it reads, the jobs, the commands and what is told on the
//! message line are the status's (`git_status.Work`), which these functions are handed.
//!
//! - `show` opens the panel at the left of the status panel (beside the focused panel while the
//!   status is not open), gives it the focus, and shows a `Shown`: RET on a file of the status's
//!   unmerged, unstaged or staged sections, and on a commit of its recent ones or of the log.
//!   `follow` shows another while the panel is open, leaving the focus where it is: the status
//!   calls it as its cursor moves onto another file. The panel's title says what it shows
//!   (`a.txt (unstaged)`, a commit's short hash and subject).
//! - A file is its part of the side's diff the status keeps (`git diff`, or `git diff --cached`,
//!   one process for the whole tree, asked once between refreshes): showing one asks for the
//!   side's diff only when it is not held, so going from file to file runs nothing. A commit is
//!   one `git show`, kept until another is shown: its hash, author, date, message and summary,
//!   then its files, open to their hunks for a small commit and folded for a larger one.
//! - Its keys (mode `vcs_git_diff`, under `vcs`): `n` `p` `C-n` `C-p` by line, `M-n` `M-p` by
//!   hunk (`ui.diff.stepHunk`), `^` to the line it is under, `M-<` `M->` the first and the last,
//!   `C-v` `M-v` a page; `tab` folds the hunk or the file the cursor is in and `S-tab` every
//!   hunk; `RET` opens the working tree's file at the line (`ui.diff.newLine`); `s`, `u` and `k`
//!   stage, unstage and discard the hunk the cursor is in, or the file on its own line, through
//!   the status's commands (one `git apply` with the hunk's bytes on its input; `k` after a
//!   dialog, and only when the hunk is still what the dialog named), and on a commit tell
//!   `Not in a commit`, and in the run whose diff read took the line under the cursor away they
//!   act on nothing (`The diff changed under the cursor`), as the status's keys do; `g` asks git
//!   again; `q` and `C-x 0` close the panel, and the focus goes
//!   back to the panel that had it before (the panels system's focus history).
//! - After a hunk or a file is acted on, the status refreshes and the panel shows the file's
//!   part again, the cursor on the hunk that took the acted one's place, else the last hunk,
//!   else the first line; a file with nothing left on its side says `No changes`.
//!
//! What the panel keeps is in its tables, `editor_vcs_git_diff` and `editor_vcs_git_diff_folds`,
//! which hold no pointer across frames. Its lines are built anew each run from them and the
//! status's tables, by the kernels that move the cursor and by the draw, which writes nothing.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const resources = mesha.resources;
const roop = mesha.roop;
const sequencer = mesha.sequencer;
const input = mesha.input;
const ui = mesha.ui;
const outline = mesha.ui.outline;
const diff_widget = mesha.ui.diff;
const keybinds = mesha.keybinds;
const git = @import("git.zig");
const status = @import("git_status.zig");
const process_log = @import("process_log.zig");
const modes = @import("../modes.zig");
const open = @import("../open.zig");
const panel_frame = @import("../panel_frame.zig");
const text_panel = @import("../text_panel.zig");
const workspaces = @import("../workspaces.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");

// ---- the panel -----------------------------------------------------------------------------

/// The panel's id.
pub const panel_name = "vcs_git_diff";
/// The panel's id, as an atom.
pub const panel = Atom.from(panel_name);

/// The panel, a fixed panel the workspaces system declares while it is shown: at the left of
/// the status panel, half of the space they share, taking the focus. Its title is set to what it
/// shows (`workspaces.setPanelTitle`).
pub const fixed_panel: plugin.panels.Open = .{
    .id = panel,
    .title = "vcs-git diff",
    .root = status.vcs_git_root,
    .beside = status.panel,
    .side = .left,
    .share = 0.5,
};

/// What the panel shows. Its slices are the caller's, read during the call: the panel keeps a
/// copy.
pub const Shown = union(enum) {
    /// A file's part of the status's diff of `side`: the unstaged one for a file of the
    /// unmerged or the unstaged section, the staged one for a file of the staged section.
    file: File,
    /// A commit, one `git show`.
    commit: Commit,

    /// A file shown, by its side and its path from the repository's root, as the status's
    /// entries name it.
    pub const File = struct { side: git.Side, path: []const u8 };
    /// A commit shown, by its full hash.
    pub const Commit = struct { hash: []const u8 };
};

/// What the panel shows, as `PanelRow.shown` keeps it.
pub const ShownKind = enum(u8) {
    /// Nothing yet, or since the project changed.
    none,
    file,
    commit,
};

// ---- the messages, the actions and their keys ----------------------------------------------

/// What the panel's part of vcs-git's system takes: its actions, and what its drawing and its
/// dialog send.
pub const Msg = enum(u64) {
    vcs_git_diff_next = Atom.from("vcs_git_diff_next").value(),
    vcs_git_diff_previous = Atom.from("vcs_git_diff_previous").value(),
    vcs_git_diff_next_hunk = Atom.from("vcs_git_diff_next_hunk").value(),
    vcs_git_diff_previous_hunk = Atom.from("vcs_git_diff_previous_hunk").value(),
    vcs_git_diff_parent = Atom.from("vcs_git_diff_parent").value(),
    vcs_git_diff_first = Atom.from("vcs_git_diff_first").value(),
    vcs_git_diff_last = Atom.from("vcs_git_diff_last").value(),
    vcs_git_diff_page_down = Atom.from("vcs_git_diff_page_down").value(),
    vcs_git_diff_page_up = Atom.from("vcs_git_diff_page_up").value(),
    vcs_git_diff_toggle = Atom.from("vcs_git_diff_toggle").value(),
    vcs_git_diff_toggle_all = Atom.from("vcs_git_diff_toggle_all").value(),
    vcs_git_diff_visit = Atom.from("vcs_git_diff_visit").value(),
    vcs_git_diff_stage = Atom.from("vcs_git_diff_stage").value(),
    vcs_git_diff_unstage = Atom.from("vcs_git_diff_unstage").value(),
    vcs_git_diff_discard = Atom.from("vcs_git_diff_discard").value(),
    vcs_git_diff_refresh = Atom.from("vcs_git_diff_refresh").value(),
    vcs_git_diff_close = Atom.from("vcs_git_diff_close").value(),
    /// A click on a line, the line's key (`u64`) its user data.
    vcs_git_diff_click = Atom.from("vcs_git_diff_click").value(),
    /// A click on a line's chevron, the line's key its user data.
    vcs_git_diff_chevron = Atom.from("vcs_git_diff_chevron").value(),
    /// The wheel over the list, an `input.MouseScrollMsg`.
    vcs_git_diff_wheel = Atom.from("vcs_git_diff_wheel").value(),
    /// The discard dialog's answer, a palette event, its user data a `git_status.DiscardAsked`.
    vcs_git_diff_discard_chosen = Atom.from("vcs_git_diff_discard_chosen").value(),
    _,
};

/// The actions of mode `vcs_git_diff`.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = @tagName(Msg.vcs_git_diff_next), .doc = "Move to the next line" },
    .{ .name = "previous", .tag = @tagName(Msg.vcs_git_diff_previous), .doc = "Move to the line before" },
    .{ .name = "next_hunk", .tag = @tagName(Msg.vcs_git_diff_next_hunk), .doc = "Move to the next hunk" },
    .{ .name = "previous_hunk", .tag = @tagName(Msg.vcs_git_diff_previous_hunk), .doc = "Move to the hunk before" },
    .{ .name = "parent", .tag = @tagName(Msg.vcs_git_diff_parent), .doc = "Move to the hunk or the file this line is in" },
    .{ .name = "first", .tag = @tagName(Msg.vcs_git_diff_first), .doc = "Move to the first line" },
    .{ .name = "last", .tag = @tagName(Msg.vcs_git_diff_last), .doc = "Move to the last line" },
    .{ .name = "page_down", .tag = @tagName(Msg.vcs_git_diff_page_down), .doc = "Move a page down" },
    .{ .name = "page_up", .tag = @tagName(Msg.vcs_git_diff_page_up), .doc = "Move a page up" },
    .{ .name = "toggle", .tag = @tagName(Msg.vcs_git_diff_toggle), .doc = "Fold or open the hunk or the file at the cursor" },
    .{ .name = "toggle_all", .tag = @tagName(Msg.vcs_git_diff_toggle_all), .doc = "Fold every hunk, or open them all" },
    .{ .name = "visit", .tag = @tagName(Msg.vcs_git_diff_visit), .doc = "Open the file at the cursor's line" },
    .{ .name = "stage", .tag = @tagName(Msg.vcs_git_diff_stage), .doc = "Stage the hunk or the file at the cursor" },
    .{ .name = "unstage", .tag = @tagName(Msg.vcs_git_diff_unstage), .doc = "Unstage the hunk or the file at the cursor" },
    .{ .name = "discard", .tag = @tagName(Msg.vcs_git_diff_discard), .doc = "Throw away the unstaged hunk or file at the cursor, after asking" },
    .{ .name = "refresh", .tag = @tagName(Msg.vcs_git_diff_refresh), .doc = "Ask git again" },
    .{ .name = "close", .tag = @tagName(Msg.vcs_git_diff_close), .doc = "Close the diff" },
};

/// The keys of mode `vcs_git_diff`, over `vcs`'s, which they shadow where they bind the same
/// key: Emacs's for moving and folding, `M-n` and `M-p` by hunk, and Emacs's `C-x 0`, which
/// closes a window, beside `q`. A symbol is written as the key that types it with Shift (`S-6`
/// is `^`, `M-S-comma` `M-<`).
pub const keys = [_]keybinds.KeyDef{
    .{ .chord = "n", .action = .{ "vcs_git_diff", "next" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "vcs_git_diff", "next" }, .trigger = .repeat },
    .{ .chord = "p", .action = .{ "vcs_git_diff", "previous" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "vcs_git_diff", "previous" }, .trigger = .repeat },
    .{ .chord = "M-n", .action = .{ "vcs_git_diff", "next_hunk" }, .trigger = .repeat },
    .{ .chord = "M-p", .action = .{ "vcs_git_diff", "previous_hunk" }, .trigger = .repeat },
    .{ .chord = "S-6", .action = .{ "vcs_git_diff", "parent" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "vcs_git_diff", "first" } },
    .{ .chord = "M-S-period", .action = .{ "vcs_git_diff", "last" } },
    .{ .chord = "C-v", .action = .{ "vcs_git_diff", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "vcs_git_diff", "page_up" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "vcs_git_diff", "toggle" } },
    .{ .chord = "S-tab", .action = .{ "vcs_git_diff", "toggle_all" } },
    .{ .chord = "RET", .action = .{ "vcs_git_diff", "visit" } },
    .{ .chord = "s", .action = .{ "vcs_git_diff", "stage" } },
    .{ .chord = "u", .action = .{ "vcs_git_diff", "unstage" } },
    .{ .chord = "k", .action = .{ "vcs_git_diff", "discard" } },
    .{ .chord = "g", .action = .{ "vcs_git_diff", "refresh" } },
    .{ .chord = "q", .action = .{ "vcs_git_diff", "close" } },
    .{ .chord = "C-x 0", .action = .{ "vcs_git_diff", "close" } },
};

/// Offers the actions of mode `vcs_git_diff`, `inbox` taking them: vcs-git's system's.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    for (actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_git_diff, inbox, &.{.{ .def = def }});
}

/// Whether `tag` is one of the panel's messages.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

// ---- the tables ----------------------------------------------------------------------------

/// `editor_vcs_git_diff`: the panel's own row, one (`PanelRow`).
pub const panel_table_name = "editor_vcs_git_diff";
/// `editor_vcs_git_diff_folds`: the keys of the lines folded or opened against how they show
/// by default (`process_log.FoldRow`): a hunk or a heading folded, a file of a small commit or
/// of a file's diff folded, a file of a large commit opened. Emptied as the panel shows
/// something else.
pub const folds_table_name = "editor_vcs_git_diff_folds";

/// The most lines the panel keeps folded or opened.
pub const max_folds = 1024;
/// The most hunks of one file a build reads: past them, a dimmed line under the file says so.
pub const max_diff_hunks = 65_536;

/// The row of `editor_vcs_git_diff`.
pub const PanelRow = struct {
    /// A `ShownKind`.
    shown: *u8,
    /// For a file, a `git.Side`.
    side: *u8,
    /// For a file, its path from the repository's root. A commit's hash is the status's
    /// (`git_status.StateRow.shown_hash`), whose bytes it is kept with.
    path: *Table.String,
    /// The panel's `outline.Cursor`: its line's key, position and scroll.
    cursor_key: *u64,
    cursor_index: *u32,
    cursor_scroll: *f32,
    /// The height of the list the last run settled the scroll for, in pixels.
    view_height: *f32,
    /// 1 from a command run on a hunk or a file of the panel's until the side's diff is read
    /// again after it: the cursor then goes to `acted_hunk`.
    acted: *u8,
    /// The place, among the hunks the panel showed, of the hunk acted on; 0 for a file.
    acted_hunk: *u32,
    /// 1 when the commit shown was asked and will not answer: it failed, or was given up.
    show_failed: *u8,
    /// 1 from a diff read in this run that took the line under the cursor away, another in its
    /// place that nobody has seen there, until the run ends (`endRun`): `s`, `u` and `k` act on
    /// nothing meanwhile, as the status's keys do (`page.changedUnderCursor`).
    cursor_moved_under: *u8,
};

/// `PanelRow` read, its text a slice of the table's.
pub const PanelRead = struct {
    shown: *u8,
    side: *u8,
    path: []const u8,
    cursor_key: *u64,
    cursor_index: *u32,
    cursor_scroll: *f32,
    view_height: *f32,
    acted: *u8,
    acted_hunk: *u32,
    show_failed: *u8,

    /// What the row says is shown; the commit's hash from `state`, the status's row.
    pub fn shownIn(row: PanelRead, state: status.StateRead) ?Shown {
        const kind = std.enums.fromInt(ShownKind, row.shown.*) orelse .none;
        return switch (kind) {
            .none => null,
            .file => .{ .file = .{ .side = sideOf(row.side.*), .path = row.path } },
            .commit => .{ .commit = .{ .hash = state.shown_hash } },
        };
    }

    /// The panel's cursor.
    pub fn cursor(row: PanelRead) outline.Cursor {
        return .{ .key = row.cursor_key.*, .index = row.cursor_index.*, .scroll = row.cursor_scroll.* };
    }
};

fn sideOf(byte: u8) git.Side {
    return std.enums.fromInt(git.Side, byte) orelse .unstaged;
}

const panel_table = Atom.from(panel_table_name);
const folds_table = Atom.from(folds_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const shown_panels_table = Atom.from(workspaces.shown_panels_table_name);
const font_metrics_table = Atom.from(resources.font_metrics_table_name);

/// Makes the panel's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ panel_table_name, folds_table_name, panel_name });

    var row: Table.Schema = undefined;
    try row.init(scratch.allocator, atoms, 11);
    defer row.deinit();
    try row.addFieldFallible("shown", u8, .int);
    try row.addFieldFallible("side", u8, .int);
    try row.addFieldFallible("path", Table.String, .text_field);
    try row.addFieldFallible("cursor_key", u64, .int);
    try row.addFieldFallible("cursor_index", u32, .int);
    try row.addFieldFallible("cursor_scroll", f32, .int);
    try row.addFieldFallible("view_height", f32, .int);
    try row.addFieldFallible("acted", u8, .int);
    try row.addFieldFallible("acted_hunk", u32, .int);
    try row.addFieldFallible("show_failed", u8, .int);
    try row.addFieldFallible("cursor_moved_under", u8, .int);
    const defaults = .{
        .shown = @as(u8, @intFromEnum(ShownKind.none)),
        .side = @as(u8, @intFromEnum(git.Side.unstaged)),
        .path = Table.String{},
        .cursor_key = @as(u64, 0),
        .cursor_index = @as(u32, 0),
        .cursor_scroll = @as(f32, 0),
        .view_height = @as(f32, 0),
        .acted = @as(u8, 0),
        .acted_hunk = @as(u32, 0),
        .show_failed = @as(u8, 0),
        .cursor_moved_under = @as(u8, 0),
    };
    _ = try tables.ensureSingleton(&row, panel_table, defaults, .durable);

    var folds: Table.Schema = undefined;
    try folds.init(scratch.allocator, atoms, 1);
    defer folds.deinit();
    try folds.addFieldFallible("key", u64, .hex);
    _ = try tables.ensure(&folds, max_folds, folds_table, .durable);
}

/// What vcs-git's system writes for the panel: its two tables.
pub fn declareAccess(result: *sequencer.Access) void {
    result.writeAll(&.{ panel_table, folds_table });
}

// ---- showing ---------------------------------------------------------------------------------

/// Shows `shown` in the panel, opening it at the left of the status panel, or beside the
/// focused panel while the status is not open, and gives it the focus. A file's side's diff is
/// asked for when it is not held; a commit is one `show`, unless it is the one held. Nothing
/// opens for a commit while the repository's root is not known, or one git cannot be given:
/// that is told.
pub fn show(work: status.Work, shown: Shown) !void {
    const changed = !try isShowing(work, shown);
    switch (shown) {
        .file => |file| try work.askDiff(file.side),
        .commit => |commit| if (changed or try commitFailed(work)) {
            const asked = try askCommit(work, commit.hash);
            if (asked == .refused) return;
        },
    }
    try keep(work, shown, changed);
    const frame = work.pass.frame;
    const placement: workspaces.Placement = if (statusOpen(work.pass)) .arranged else .beside_focused;
    workspaces.showPanel(frame.tables, frame.atoms, panel, placement, .take);
    try retitle(work);
}

/// Shows `shown` in the panel as `show` does, while it is open, leaving the focus where it is;
/// nothing while it is closed, or when it shows `shown` already. What the status calls as its
/// cursor moves onto another file: going from file to file runs no program while the side's
/// diff is held.
pub fn follow(work: status.Work, shown: Shown) !void {
    if (!isOpen(work.pass)) return;
    if (try isShowing(work, shown)) return;
    switch (shown) {
        .file => |file| try work.askDiff(file.side),
        .commit => |commit| {
            const asked = try askCommit(work, commit.hash);
            if (asked == .refused) return;
        },
    }
    try keep(work, shown, true);
    try retitle(work);
}

/// Whether the panel is shown: declared, open or about to open.
pub fn isOpen(pass: *const sequencer.Pass) bool {
    if (!pass.declares(shown_panels_table)) return false;
    return workspaces.panelShown(pass.frame.tables, panel);
}

/// Whether the status panel is open in the panels' tree, which the panel opens beside.
fn statusOpen(pass: *const sequencer.Pass) bool {
    if (!pass.declares(panel_state_table)) return false;
    const frame = pass.frame;
    return panels_mod.panelFor(frame.tables, frame.atoms, status.panel) != null;
}

/// Whether the panel shows `shown` already.
fn isShowing(work: status.Work, shown: Shown) !bool {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const state = try work.pass.readSingleton(Atom.from(status.state_table_name), status.StateRead);
    const showing = row.shownIn(state) orelse return false;
    return switch (shown) {
        .file => |file| switch (showing) {
            .file => |held| held.side == file.side and std.mem.eql(u8, held.path, file.path),
            .commit => false,
        },
        .commit => |commit| switch (showing) {
            .commit => |held| std.mem.eql(u8, held.hash, commit.hash),
            .file => false,
        },
    };
}

/// Whether the commit held was asked and will not answer.
fn commitFailed(work: status.Work) !bool {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    return row.show_failed.* != 0;
}

/// Whether a commit was asked for, or why not.
const Asked = enum { asked, refused };

/// Asks for the commit `hash`, one `show`, in place of the one held.
fn askCommit(work: status.Work, hash: []const u8) !Asked {
    if (work.rootUnknown()) return .refused;
    const allocator = try work.scratch();
    var argv: std.Io.Writer.Allocating = .init(allocator);
    git.writeArgv(&argv.writer, .{ .show = hash }) catch |err| switch (err) {
        error.UnpassableArgument => {
            work.tell("git cannot be given that commit");
            return .refused;
        },
        error.WriteFailed => return error.OutOfMemory,
    };
    const epoch = try work.forgetShown(hash);
    work.queueQuery(.show, argv.written(), epoch);
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.show_failed.* = 0;
    return .asked;
}

/// Records `shown` as what the panel shows; when it `changed`, the cursor goes to the top and
/// the folds of what it showed are let go.
fn keep(work: status.Work, shown: Shown, changed: bool) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    const cells = try work.pass.writeTable(panel_table);
    switch (shown) {
        .file => |file| {
            // A file in the commit's place: the commit's bytes are let go.
            if (row.shown.* == @intFromEnum(ShownKind.commit)) _ = try work.forgetShown("");
            row.shown.* = @intFromEnum(ShownKind.file);
            row.side.* = @intFromEnum(file.side);
            try cells.assignString(row.path, file.path);
        },
        .commit => {
            row.shown.* = @intFromEnum(ShownKind.commit);
            try cells.assignString(row.path, "");
        },
    }
    if (changed) try startOver(work);
}

/// The cursor to the top, no command's end awaited, and the folds of what the panel showed let
/// go: for something else shown.
fn startOver(work: status.Work) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.cursor_key.* = 0;
    row.cursor_index.* = 0;
    row.cursor_scroll.* = 0;
    row.acted.* = 0;
    const folds = try work.pass.writeTable(folds_table);
    folds.clear();
}

/// Titles the panel with what it shows: a file's path and side, or a commit's short hash and,
/// once `show` has answered, its subject.
fn retitle(work: status.Work) !void {
    const allocator = try work.scratch();
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const state = try work.pass.readSingleton(Atom.from(status.state_table_name), status.StateRead);
    const shown = row.shownIn(state) orelse return;
    const title = switch (shown) {
        .file => |file| blk: {
            const path = try ui.displayText(allocator, file.path);
            break :blk try std.fmt.allocPrint(allocator, "{s} ({t})", .{ path, file.side });
        },
        .commit => |commit| blk: {
            const short = commit.hash[0..@min(commit.hash.len, 7)];
            const said = git.parseShow(state.shown_commit) orelse break :blk short;
            const subject_end = std.mem.indexOfScalar(u8, said.message, '\n') orelse said.message.len;
            const subject = try ui.displayText(allocator, said.message[0..subject_end]);
            break :blk try std.fmt.allocPrint(allocator, "{s} {s}", .{ short, subject });
        },
    };
    workspaces.setPanelTitle(work.pass.frame.tables, panel, title);
}

/// Shows nothing, titled as `fixed_panel` is: the project changed, and what the panel showed is
/// of the one before.
pub fn forget(work: status.Work) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    const cells = try work.pass.writeTable(panel_table);
    row.shown.* = @intFromEnum(ShownKind.none);
    row.show_failed.* = 0;
    try cells.assignString(row.path, "");
    try startOver(work);
    workspaces.setPanelTitle(work.pass.frame.tables, panel, "");
}

// ---- what the status's work tells the panel ------------------------------------------------

/// The side whose diff the panel needs, while it is open on a file; null otherwise. The
/// status asks for it as a refresh ends.
pub fn wantedSide(work: status.Work) !?git.Side {
    if (!isOpen(work.pass)) return null;
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    if (row.shown.* != @intFromEnum(ShownKind.file)) return null;
    return sideOf(row.side.*);
}

/// The side `side`'s diff was read again: after a command of the panel's, the cursor goes to the
/// hunk that took the acted one's place, else the last hunk, else the first line; otherwise,
/// when the line under the cursor is gone, the keys act on nothing until the run ends
/// (`PanelRow.cursor_moved_under`).
pub fn diffRead(work: status.Work, side: git.Side) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    if (row.shown.* != @intFromEnum(ShownKind.file) or sideOf(row.side.*) != side) return;
    if (row.acted.* == 0) return noteMovedUnder(work);
    row.acted.* = 0;
    const acted_hunk = row.acted_hunk.*;
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    if (shown.len == 0) return;
    var hunk_positions: std.ArrayList(u32) = .empty;
    const allocator = try work.scratch();
    for (shown, 0..) |line_index, position| {
        if (built.lines[line_index].kind != @intFromEnum(LineKind.hunk)) continue;
        try hunk_positions.append(allocator, @intCast(position));
    }
    const found = hunk_positions.items;
    const position: u32 = if (found.len == 0) 0 else found[@min(acted_hunk, found.len - 1)];
    var placed = try storedCursor(work);
    placed.key = built.lines[shown[position]].key;
    placed.index = position;
    try setCursor(work, shown, placed, .follow);
}

/// A diff read that left the stored cursor's line nowhere among the lines shown: another line is
/// under the cursor now, which nobody has seen there.
fn noteMovedUnder(work: status.Work) !void {
    const stored = try storedCursor(work);
    if (stored.key == 0) return;
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    for (shown) |line_index| {
        if (built.lines[line_index].key == stored.key) return;
    }
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.cursor_moved_under.* = 1;
}

/// The run's messages are taken: a line under the cursor that a diff read took away is the
/// person's to act on from the next run.
pub fn endRun(work: status.Work) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    if (row.cursor_moved_under.* != 0) row.cursor_moved_under.* = 0;
}

/// `show`'s answer: kept, with where each file's part of its diff is, and the panel titled with
/// its subject. An answer of an earlier show is dropped; a failure is told, and the panel says
/// so.
pub fn takeShow(work: status.Work, epoch: u32, said: ?[]const u8) !void {
    if (epoch != work.state.show_serial.*) return;
    const bytes = said orelse return showFailed(work);
    const shown = git.parseShow(bytes) orelse return showFailed(work);
    try work.keepShown(bytes, shown.diff);
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    if (row.shown.* == @intFromEnum(ShownKind.commit)) try retitle(work);
}

fn showFailed(work: status.Work) !void {
    work.tell("git show failed; $ shows why");
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.show_failed.* = 1;
}

/// A give-up (`C-g`) or a change of project moved the panel's generation on: a commit asked
/// and not answered never will, and the panel says so.
pub fn abandon(work: status.Work) !void {
    const loaded = work.state.diffs_loaded.* & status.DiffSource.shown.bit() != 0;
    if (loaded) return;
    const hash = work.cells.textOf(work.state.shown_hash.*);
    if (hash.len == 0) return;
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.show_failed.* = 1;
}

/// A kernel's part of vcs-git's system: keeps the scroll fit to the panel's view as it is
/// resized, the cursor in view; once the panel is closed, by its keys or any other way, a
/// commit it showed is let go, its bytes with it.
pub fn followLayout(pass: *sequencer.Pass) !void {
    if (!isOpen(pass)) return forgetClosedCommit(pass);
    const layout = process_log.layoutOf(pass, panel);
    const stored = try pass.readSingleton(panel_table, struct { view_height: *f32 });
    if (stored.view_height.* == layout.view_height) return;
    const work = try status.Work.of(pass);
    const row = try pass.writeSingleton(panel_table, PanelRow);
    row.view_height.* = layout.view_height;
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    const settled = outline.settle(built.lines, shown, try storedCursor(work));
    try setCursor(work, shown, settled, .follow);
}

/// The panel closed while it showed a commit: the commit's bytes, and where its files are, are
/// let go, and the panel shows nothing, so showing it again asks for it.
fn forgetClosedCommit(pass: *sequencer.Pass) !void {
    const row = try pass.readSingleton(panel_table, PanelRead);
    if (row.shown.* != @intFromEnum(ShownKind.commit)) return;
    const work = try status.Work.of(pass);
    _ = try work.forgetShown("");
    const written = try pass.writeSingleton(panel_table, PanelRow);
    written.shown.* = @intFromEnum(ShownKind.none);
    written.show_failed.* = 0;
}

// ---- what a message does -------------------------------------------------------------------

/// One of the panel's messages.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_git_diff_next => try move(work, .next),
        .vcs_git_diff_previous => try move(work, .previous),
        .vcs_git_diff_parent => try move(work, .parent),
        .vcs_git_diff_first => try move(work, .first),
        .vcs_git_diff_last => try move(work, .last),
        .vcs_git_diff_page_down => try move(work, .page_down),
        .vcs_git_diff_page_up => try move(work, .page_up),
        .vcs_git_diff_next_hunk => try moveByHunk(work, .next),
        .vcs_git_diff_previous_hunk => try moveByHunk(work, .previous),
        .vcs_git_diff_toggle => try toggleAtCursor(work),
        .vcs_git_diff_toggle_all => try toggleAll(work),
        .vcs_git_diff_visit => try visit(work),
        .vcs_git_diff_stage => try changeAtCursor(work, .stage),
        .vcs_git_diff_unstage => try changeAtCursor(work, .unstage),
        .vcs_git_diff_discard => try changeAtCursor(work, .discard),
        .vcs_git_diff_refresh => try askAgain(work),
        .vcs_git_diff_close => close(work),
        .vcs_git_diff_click => {
            const key = (try received.userDataAs(u64)).*;
            try putCursorOn(work, key);
        },
        .vcs_git_diff_chevron => {
            const key = (try received.userDataAs(u64)).*;
            try toggleKey(work, key);
        },
        .vcs_git_diff_wheel => {
            const scrolled = try received.payloadAs(input.MouseScrollMsg);
            try wheel(work, scrolled.y);
        },
        .vcs_git_diff_discard_chosen => {
            const asked = try status.confirmedDiscard(work, received) orelse return;
            try discardConfirmed(work, asked);
        },
        _ => {},
    }
}

/// `q` and `C-x 0`: the panel closes, and the focus goes where closing a panel sends it, the
/// panel that had it before: nothing is asked for by name.
fn close(work: status.Work) void {
    workspaces.hidePanel(work.pass.frame.tables, panel);
}

/// `g`: a file's diff asked again, through a refresh of the status, whose end asks for the
/// side the panel shows; a commit's `show` asked again.
fn askAgain(work: status.Work) !void {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const kind = std.enums.fromInt(ShownKind, row.shown.*) orelse .none;
    switch (kind) {
        .none => {},
        .file => try work.refresh(.by_rule),
        .commit => {
            const allocator = try work.scratch();
            const held = work.cells.textOf(work.state.shown_hash.*);
            const hash = try allocator.dupe(u8, held);
            _ = try askCommit(work, hash);
        },
    }
}

/// Whether a cursor's change scrolls the view to follow it, or keeps the scroll it has.
const Scroll = enum { follow, keep };

fn storedCursor(work: status.Work) !outline.Cursor {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    return row.cursor();
}

/// Keeps `cursor` as the panel's, the view scrolled to show it when `scroll` says so.
fn setCursor(work: status.Work, shown: []const u32, cursor: outline.Cursor, scroll: Scroll) !void {
    var placed = cursor;
    if (scroll == .follow) {
        const layout = process_log.layoutOf(work.pass, panel);
        placed.scroll = outline.scrollTo(shown, placed, layout.line_height, layout.view_height);
    }
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.cursor_key.* = placed.key;
    row.cursor_index.* = placed.index;
    row.cursor_scroll.* = placed.scroll;
}

fn move(work: status.Work, step: outline.Step) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    const layout = process_log.layoutOf(work.pass, panel);
    const moved = outline.move(built.lines, shown, try storedCursor(work), step, layout.pageLines());
    try setCursor(work, shown, moved, .follow);
}

/// `M-n` and `M-p`: to the next hunk's line, or the one before, across files.
fn moveByHunk(work: status.Work, direction: diff_widget.Direction) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    const hunk_kind: u8 = @intFromEnum(LineKind.hunk);
    const moved = diff_widget.stepHunk(built.lines, shown, try storedCursor(work), hunk_kind, direction);
    try setCursor(work, shown, moved, .follow);
}

/// A click on the line `key`: the cursor goes there.
fn putCursorOn(work: status.Work, key: u64) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    for (shown, 0..) |line_index, position| {
        if (built.lines[line_index].key != key) continue;
        var placed = try storedCursor(work);
        placed.key = key;
        placed.index = @intCast(position);
        return setCursor(work, shown, placed, .follow);
    }
}

/// The wheel moved `notches` (up positive): the view scrolls three lines a notch, and the cursor
/// follows into it.
fn wheel(work: status.Work, notches: f32) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    const layout = process_log.layoutOf(work.pass, panel);
    var scrolled = outline.settle(built.lines, shown, try storedCursor(work));
    const wanted = scrolled.scroll - notches * process_log.wheel_lines * layout.line_height;
    scrolled.scroll = outline.clampScroll(shown, wanted, layout.line_height, layout.view_height);
    const followed = outline.cursorInView(built.lines, shown, scrolled, layout.line_height, layout.view_height);
    try setCursor(work, shown, followed, .keep);
}

/// `tab`: folds or opens the hunk or the file the cursor is in: its own line's, or, on a line
/// that has none, the one it is under.
fn toggleAtCursor(work: status.Work) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    if (shown.len == 0) return;
    const settled = outline.settle(built.lines, shown, try storedCursor(work));
    var line_index = shown[settled.index];
    while (!built.lines[line_index].expandable) {
        line_index = outline.parentOf(built.lines, line_index) orelse return;
    }
    try toggleLine(work, built.lines[line_index].key);
    // The cursor stays on what it was on, or the folded line that hides it.
    const rebuilt = try buildIn(work);
    const reshown = try visibleOf(work, rebuilt);
    const resettled = outline.settle(rebuilt.lines, reshown, settled);
    try setCursor(work, reshown, resettled, .follow);
}

/// A chevron's click: folds or opens the line `key`.
fn toggleKey(work: status.Work, key: u64) !void {
    const built = try buildIn(work);
    for (built.lines) |line| {
        if (line.key != key or !line.expandable) continue;
        return toggleLine(work, key);
    }
}

/// Turns the line `key` from how it shows by default, or back.
fn toggleLine(work: status.Work, key: u64) !void {
    const folds = try work.pass.writeTable(folds_table);
    if (process_log.findFold(folds, key)) |handle| {
        folds.free(handle);
        return;
    }
    if (folds.count() >= folds.rowCapacity()) return;
    _ = try folds.tryInsert(.{ .key = key });
}

/// `S-tab`: folds every hunk shown, or, while any is folded, opens them all.
fn toggleAll(work: status.Work) !void {
    const built = try buildIn(work);
    const folds = try work.pass.writeTable(folds_table);
    const hunk_kind: u8 = @intFromEnum(LineKind.hunk);
    var any_folded = false;
    for (built.lines) |line| {
        if (line.kind != hunk_kind) continue;
        if (std.mem.indexOfScalar(u64, built.folded, line.key) != null) any_folded = true;
    }
    for (built.lines) |line| {
        if (line.kind != hunk_kind) continue;
        const found = process_log.findFold(folds, line.key);
        if (any_folded) {
            if (found) |handle| folds.free(handle);
            continue;
        }
        if (found != null or folds.count() >= folds.rowCapacity()) continue;
        _ = try folds.tryInsert(.{ .key = line.key });
    }
    const rebuilt = try buildIn(work);
    const reshown = try visibleOf(work, rebuilt);
    const resettled = outline.settle(rebuilt.lines, reshown, try storedCursor(work));
    try setCursor(work, reshown, resettled, .follow);
}

/// `RET`: opens the file the cursor's line is of, in the working tree whichever side or commit
/// it is of: on a hunk's line at the new file's line it is at (`ui.diff.newLine`; the hunk's
/// first on its `@@` line), elsewhere where its kind goes (`open.openPath`). A deleted file is
/// told so.
fn visit(work: status.Work) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    if (shown.len == 0) return;
    const settled = outline.settle(built.lines, shown, try storedCursor(work));
    const line_index = shown[settled.index];
    const line = built.lines[line_index];
    const target = built.targets[line_index];
    const allocator = try work.scratch();
    const kind: LineKind = @enumFromInt(line.kind);
    const part: ?Part = if (target.file != diff_widget.none) built.files[target.file] else null;
    const path, const deleted = if (part) |found|
        .{ found.path, found.change == .deleted }
    else switch (built.shown) {
        // A line of the file shown that is none of its parts': `No changes`, a conflict.
        .file => .{ built.path, false },
        .commit, .none => return,
    };
    if (deleted) {
        const sentence = try std.fmt.allocPrint(allocator, "{s} is deleted: there is no file to open", .{path});
        return work.tell(sentence);
    }
    const root = work.cells.textOf(work.state.root.*);
    if (root.len == 0) return work.tell(status.root_unknown);
    const joined = try open.joinedPath(allocator, root, path);
    const on_hunk = kind == .hunk or kind == .line;
    if (!on_hunk or part == null or target.hunk == diff_widget.none) return open.openPath(work.pass, joined, .present);
    const hunk = part.?.hunks[target.hunk];
    const line_number = if (kind == .line) diff_widget.newLine(hunk, target.line) else hunk.new_start;
    // `openAt` counts lines from 0, a hunk's header from 1.
    text_panel.openAt(work.pass.frame.tables, joined, line_number -| 1, 0);
}

/// `s`, `u` or `k`: `change` of the hunk the cursor is in, or of the file on its own line. A
/// discard asks first.
fn changeAtCursor(work: status.Work, change: status.Change) !void {
    const built = try buildIn(work);
    if (built.shown == .commit) return work.tell("Not in a commit");
    const row = try work.pass.readSingleton(panel_table, struct { cursor_moved_under: *u8 });
    if (row.cursor_moved_under.* != 0) return work.tell("The diff changed under the cursor");
    if (work.rootUnknown()) return;
    const shown = try visibleOf(work, built);
    if (shown.len == 0) return work.tell(change.nothingHere());
    const settled = outline.settle(built.lines, shown, try storedCursor(work));
    const line_index = shown[settled.index];
    const planned = try planOf(work, built, line_index, change);
    switch (planned) {
        .tell => |sentence| work.tell(sentence),
        .run => |plan| switch (change) {
            .discard => {
                const key = built.lines[line_index].key;
                const reply_tag = Atom.from(Msg.vcs_git_diff_discard_chosen);
                try work.askToDiscard(plan, key, reply_tag);
            },
            .stage, .unstage => try runActed(work, built, line_index, plan),
        },
    }
}

/// The discard dialog's yes: the line it was asked on, found again by its key in the lines as
/// they are now, is thrown away, but only when what would be thrown away is what the dialog
/// named; gone meanwhile, or changed, it is told and nothing runs.
fn discardConfirmed(work: status.Work, asked: status.DiscardAsked) !void {
    if (work.rootUnknown()) return;
    const built = try buildIn(work);
    if (built.shown == .commit) return work.tell("Not in a commit");
    const line_index = for (built.lines, 0..) |line, index| {
        if (line.key == asked.key) break index;
    } else return work.tell("It is no longer there");
    const planned = try planOf(work, built, @intCast(line_index), .discard);
    switch (planned) {
        .tell => |sentence| work.tell(sentence),
        .run => |plan| {
            const now = status.fingerprintOf(plan.run);
            if (now != asked.fingerprint) return work.tell("It changed meanwhile; k asks again");
            try runActed(work, built, @intCast(line_index), plan);
        },
    }
}

/// Runs `plan`, made on the line `line_index` of `built`, noting the hunk it acts on, which the
/// cursor goes to once the side's diff is read again; nothing is noted when no command was
/// queued (a path git cannot be given), as no diff will be read again for it.
fn runActed(work: status.Work, built: Built, line_index: u32, plan: status.Plan) !void {
    const running_before = work.state.commands_running.*;
    try work.runPlanned(plan);
    if (work.state.commands_running.* == running_before) return;
    const target = built.targets[line_index];
    var acted_hunk: u32 = 0;
    if (target.file != diff_widget.none and target.hunk != diff_widget.none) {
        for (built.files[0..target.file]) |before| acted_hunk += @intCast(before.hunks.len);
        acted_hunk += target.hunk;
    }
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.acted.* = 1;
    row.acted_hunk.* = acted_hunk;
}

/// What `change` of the line `line_index` of `built`, a file's, runs, or what is told in its
/// place: on a hunk or one of its lines, the hunk's patch, its bytes as git said them; on a
/// file's line, or its note, the file, as on its line in the status.
fn planOf(work: status.Work, built: Built, line_index: u32, change: status.Change) !status.Planned {
    const section = built.section;
    if (change.refusal(section)) |sentence| return .{ .tell = sentence };
    const target = built.targets[line_index];
    if (target.file == diff_widget.none) return .{ .tell = change.nothingHere() };
    const part = built.files[target.file];
    const allocator = try work.scratch();
    if (target.hunk == diff_widget.none) {
        const entry = entryShown(work.files, built) orelse return .{ .tell = change.nothingHere() };
        return status.planFile(allocator, entry, section, change, work.hasCommit());
    }
    if (section == .unmerged) return .{ .tell = change.nothingHere() };
    const file = part.diff orelse return .{ .tell = change.nothingHere() };
    const hunk = part.hunks[target.hunk];
    const how: git.Apply = switch (change) {
        .stage => .stage,
        .unstage => .unstage,
        .discard => .discard,
    };
    const shown_path = try ui.displayText(allocator, part.path);
    return .{ .run = .{
        .run = .{ .hunk = .{ .how = how, .header = file.header, .hunk = hunk } },
        .question = .{ .title = "Discard hunk?", .body = shown_path, .confirm = "Discard" },
    } };
}

/// The status's file the panel shows, under its section, as the status's tables hold it: null
/// once the status no longer lists it there.
fn entryShown(files: status.FileTables, built: Built) ?git.Entry {
    const side = built.section.side() orelse return null;
    const found = status.fileOn(files, side, built.path) orelse return null;
    if (found.section != built.section) return null;
    return found.entry;
}

// ---- the lines -----------------------------------------------------------------------------

/// What a line is, as `outline.Line.kind` keeps it.
pub const LineKind = enum(u8) {
    /// The commit shown's hash, author or date.
    info,
    /// A line of the commit shown's message.
    message,
    /// A line of git's summary of the commit shown's changes.
    stat,
    /// `Files`, over the commit shown's files.
    heading,
    /// What the panel says in place of what it would show, dimmed: `Loading...`, `No changes`.
    notice,
    /// A file's line.
    file,
    /// What a file shows in place of hunks: a binary file, a mode changed.
    note,
    /// A hunk's `@@` line.
    hunk,
    /// A line of a hunk.
    line,
};

/// The kinds `ui.diff.lines` gives the lines it builds under a file's line.
const diff_kinds: diff_widget.Kinds = .{
    .file = @intFromEnum(LineKind.file),
    .note = @intFromEnum(LineKind.note),
    .hunk = @intFromEnum(LineKind.hunk),
    .line = @intFromEnum(LineKind.line),
};

/// What a line is about: its file among `Built.files`, its hunk among the file's, and its place
/// in the hunk's body, each `ui.diff.none` where that does not apply.
pub const Target = struct {
    file: u32 = diff_widget.none,
    hunk: u32 = diff_widget.none,
    line: u32 = diff_widget.none,
};

/// A file of what the panel shows, as `editor_vcs_git_diff_files` records it, and, when its
/// lines were built, what its part of the diff says.
pub const Part = struct {
    /// Its path from the root, unquoted: its new one, or the old one of a deleted file.
    path: []const u8,
    /// The path it had, for a renamed or copied file; its path otherwise.
    old_path: []const u8,
    /// What became of it.
    change: git.Change,
    /// Its part of the diff's bytes.
    bytes: []const u8,
    /// Its headers as git wrote them, read from `bytes`; null while it is folded, its part not
    /// parsed.
    diff: ?git.FileDiff = null,
    /// Its hunks, the first `max_diff_hunks`; none while it is folded.
    hunks: []const diff_widget.Hunk = &.{},
};

/// The lines the panel shows, what each is about, the keys of those folded, as
/// `outline.visible` and `outline.record` take them, and the files they were built from. All in
/// the allocator `build` was given, or the tables', good for the frame.
pub const Built = struct {
    lines: []outline.Line,
    targets: []Target,
    /// The keys of the lines folded.
    folded: []u64,
    /// The files shown, which a line's `Target.file` counts in.
    files: []Part,
    /// What the panel shows.
    shown: ShownKind,
    /// For a file, the status's section it is under (`unmerged`, `unstaged` or `staged`), which
    /// staging acts on; `none` for a commit.
    section: status.SectionKind,
    /// For a file, its path; empty for a commit.
    path: []const u8,
};

/// What the lines are built from: the panel's tables and the status's, as a kernel's run or the
/// draw reads them.
pub const Sources = struct {
    /// The status's row, the diffs' bytes and the commit shown among it.
    state: status.StateRead,
    /// The panel's row.
    row: PanelRead,
    /// The status's files, a table a section, which say what a file shown is.
    files: status.FileTables,
    /// `editor_vcs_git_diff_files` and `editor_vcs_git_diff_folds`.
    diff_files: *Table,
    folds: *Table,
};

/// The panel's tables as the draw reads them; null without them.
pub fn sourcesOf(tables: *Table.Registry) ?Sources {
    const state_table = tables.findByName(Atom.from(status.state_table_name)) orelse return null;
    const state = state_table.getRow(.{ .row = 0, .generation = state_table.rowGeneration(0) }, status.StateRead) orelse return null;
    const row_table = tables.findByName(panel_table) orelse return null;
    const row = row_table.getRow(.{ .row = 0, .generation = row_table.rowGeneration(0) }, PanelRead) orelse return null;
    return .{
        .state = state,
        .row = row,
        .files = status.FileTables.in(tables) orelse return null,
        .diff_files = tables.findByName(Atom.from(status.diff_files_table_name)) orelse return null,
        .folds = tables.findByName(folds_table) orelse return null,
    };
}

/// The lines as the kernel's run reads the tables.
fn buildIn(work: status.Work) !Built {
    const allocator = try work.scratch();
    const sources: Sources = .{
        .state = try work.pass.readSingleton(Atom.from(status.state_table_name), status.StateRead),
        .row = try work.pass.readSingleton(panel_table, PanelRead),
        .files = work.files,
        .diff_files = work.diff_files,
        .folds = try work.pass.writeTable(folds_table),
    };
    return build(allocator, sources);
}

fn visibleOf(work: status.Work, built: Built) ![]u32 {
    const allocator = try work.scratch();
    const out = try allocator.alloc(u32, built.lines.len);
    return outline.visible(built.lines, built.folded, out);
}

/// Lines and their targets as they are built, and the folded keys among them.
const LineList = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(outline.Line) = .empty,
    targets: std.ArrayList(Target) = .empty,
    folded: std.ArrayList(u64) = .empty,
    files: std.ArrayList(Part) = .empty,
    /// The keys turned from how they show by default, sorted (`process_log.sortedKeys`).
    toggled: []const u64,

    fn add(list: *LineList, line: outline.Line, target: Target) !void {
        try list.lines.append(list.allocator, line);
        try list.targets.append(list.allocator, target);
    }

    /// A line of `kind` at the top, of one colour, about nothing.
    fn plain(list: *LineList, kind: LineKind, key_text: []const u8, text: []const u8, colour: ui.Color) !void {
        const line: outline.Line = .{ .depth = 0, .kind = @intFromEnum(kind), .key = keyOf(kind, key_text), .text = text, .colour = colour };
        try list.add(line, .{});
    }

    /// A dimmed line at `depth` saying `text`.
    fn notice(list: *LineList, depth: u8, key_text: []const u8, text: []const u8) !void {
        const line: outline.Line = .{ .depth = depth, .kind = @intFromEnum(LineKind.notice), .key = keyOf(.notice, key_text), .text = text, .colour = style.col.text_dim };
        try list.add(line, .{});
    }

    /// Whether the line `key`, which shows as `by_default` says while nothing says otherwise, is
    /// folded now; noted among the folded keys when it is.
    fn isFolded(list: *LineList, key: u64, by_default: Fold) !bool {
        const toggled = process_log.holds(list.toggled, key);
        const folded = switch (by_default) {
            .open => toggled,
            .folded => !toggled,
        };
        if (folded) try list.folded.append(list.allocator, key);
        return folded;
    }
};

/// How a line that has lines under it shows them while nothing says otherwise.
const Fold = enum { open, folded };

/// A line's key: its kind, and the text that names it among them. Never 0.
fn keyOf(kind: LineKind, text: []const u8) u64 {
    const key = std.hash.Wyhash.hash(@intFromEnum(kind), text);
    return if (key == 0) 1 else key;
}

/// The lines of what `sources.row` says the panel shows, in `allocator`, which is an arena's.
pub fn build(allocator: std.mem.Allocator, sources: Sources) !Built {
    var list: LineList = .{ .allocator = allocator, .toggled = try process_log.sortedKeys(allocator, sources.folds) };
    var built: Built = .{ .lines = &.{}, .targets = &.{}, .folded = &.{}, .files = &.{}, .shown = .none, .section = .none, .path = "" };
    if (sources.row.shownIn(sources.state)) |shown| switch (shown) {
        .file => |file| {
            built.shown = .file;
            built.path = file.path;
            built.section = try fileLines(&list, sources, file);
        },
        .commit => |commit| {
            built.shown = .commit;
            try commitLines(&list, sources, commit);
        },
    } else try list.notice(0, "nothing", "Nothing to show");
    built.lines = list.lines.items;
    built.targets = list.targets.items;
    built.folded = list.folded.items;
    built.files = list.files.items;
    return built;
}

/// A file's lines: each of its parts of the side's diff (two for a rename staged, which the
/// status's diff sees as a file deleted and one added), with its hunks; or one line that says
/// why there are none. Returns the status's section it is under.
fn fileLines(list: *LineList, sources: Sources, file: Shown.File) !status.SectionKind {
    const allocator = list.allocator;
    const state = sources.state;
    const listed_file = status.fileOn(sources.files, file.side, file.path);
    const entry: ?git.Entry = if (listed_file) |listed| listed.entry else null;
    const section: status.SectionKind = if (listed_file) |listed| listed.section else switch (file.side) {
        .staged => .staged,
        .unstaged => .unstaged,
    };
    if (state.diffs_loaded.* & status.diffBit(file.side) == 0) {
        // The ui font has ASCII only: three dots, not an ellipsis.
        try list.notice(0, "loading", "Loading...");
        return section;
    }
    const source = status.DiffSource.ofSide(file.side);
    const bytes = switch (file.side) {
        .unstaged => state.unstaged_diff,
        .staged => state.staged_diff,
    };
    const files_seen = switch (file.side) {
        .unstaged => state.unstaged_files_seen.*,
        .staged => state.staged_files_seen.*,
    };
    const renamed = section == .staged and entry != null and entry.?.kind == .renamed and entry.?.original_path.len != 0;
    var paths: [2][]const u8 = .{ file.path, "" };
    if (renamed) paths[1] = entry.?.original_path;
    const path_count: usize = if (renamed) 2 else 1;
    var found = false;
    for (paths[0..path_count]) |path| {
        const indexed = partOf(sources.diff_files, source, bytes, path) orelse continue;
        found = true;
        try partLines(list, indexed, 0, .open);
    }
    if (found) return section;
    if (files_seen > status.max_diff_files) {
        // The ui font has ASCII only: three dots, not an ellipsis.
        const text = try std.fmt.allocPrint(allocator, "... the diff is cut: {d} of {d} files read", .{ status.max_diff_files, files_seen });
        try list.notice(0, "cut", text);
        return section;
    }
    // git gives a conflict as a combined diff, which is not read: the file is resolved in it.
    const missing = if (section == .unmerged) "Conflicted: RET opens the file to resolve it" else "No changes";
    try list.notice(0, "none", missing);
    return section;
}

/// The file at `path` of `source`'s diff, `bytes`, as `diff_files` (`editor_vcs_git_diff_files`)
/// records it; null for a file the diff does not hold.
fn partOf(diff_files: *Table, source: status.DiffSource, bytes: []const u8, path: []const u8) ?Part {
    var rows = diff_files.readQuery(status.DiffFileRow);
    while (rows.next()) |row| {
        if (row.view.source.* != @intFromEnum(source)) continue;
        if (!std.mem.eql(u8, row.view.path, path)) continue;
        return partOfRow(row.view, bytes);
    }
    return null;
}

/// The file a row of `editor_vcs_git_diff_files` records, its part a slice of `bytes`; null
/// when the part is past them.
fn partOfRow(row: Table.ReadView(status.DiffFileRow), bytes: []const u8) ?Part {
    const end = @as(usize, row.offset.*) + row.length.*;
    if (end > bytes.len) return null;
    const change = std.enums.fromInt(git.Change, row.change.*) orelse .modified;
    return .{ .path = row.path, .old_path = row.old_path, .change = change, .bytes = bytes[row.offset.*..end] };
}

/// A file's line at `depth`, its path (a rename's two) and its change as a word, and, unless it
/// is folded, under it its note or its hunks with their lines, as `ui.diff` builds them from
/// its part alone. `by_default` says whether it shows open while nothing says otherwise.
fn partLines(list: *LineList, indexed: Part, depth: u8, by_default: Fold) !void {
    const allocator = list.allocator;
    const file_index: u32 = @intCast(list.files.items.len);
    const path = try ui.displayText(allocator, indexed.path);
    const moved = indexed.change == .renamed or indexed.change == .copied;
    const old_path = try ui.displayText(allocator, indexed.old_path);
    const text = if (moved) try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ old_path, path }) else path;
    const key = keyOf(.file, indexed.path);
    const file_line: outline.Line = .{ .depth = depth, .kind = @intFromEnum(LineKind.file), .key = key, .text = text, .detail = changeWord(indexed.change), .colour = style.col.text, .expandable = true };
    try list.add(file_line, .{ .file = file_index });
    var part = indexed;
    const folded = try list.isFolded(key, by_default);
    if (!folded) {
        if (try parsePart(allocator, part.bytes)) |parsed| {
            part.diff = parsed.diff;
            part.hunks = parsed.hunks;
            try hunkLines(list, part, key, depth, file_index, parsed.cut);
        }
    }
    try list.files.append(allocator, part);
}

/// A part of a diff parsed: its file and its hunks, as many as a build reads.
const Parsed = struct {
    diff: git.FileDiff,
    hunks: []const diff_widget.Hunk,
    /// Whether it had more hunks than a build reads.
    cut: bool,
};

/// Parses `bytes`, one file's part of a diff; null when it holds no file git's parser reads (a
/// conflict's combined diff).
fn parsePart(allocator: std.mem.Allocator, bytes: []const u8) !?Parsed {
    var file: [1]git.FileDiff = undefined;
    // Room for every hunk the part has, up to the most a build reads.
    const part_hunks = diff_widget.parseHunks(bytes, &.{});
    const hunk_room = @min(part_hunks.seen, max_diff_hunks);
    const hunks = try allocator.alloc(diff_widget.Hunk, hunk_room);
    const counts = try git.parseDiff(bytes, allocator, &file, hunks);
    if (counts.files.kept == 0) return null;
    const cut = counts.hunks.seen > counts.hunks.kept;
    return .{ .diff = file[0], .hunks = hunks[0..counts.hunks.kept], .cut = cut };
}

/// Under a file's line, keyed `file_key`: its note, or its hunks and their lines, built by
/// `ui.diff.lines` in the editor's colours, each hunk open unless folded.
fn hunkLines(list: *LineList, part: Part, file_key: u64, depth: u8, file_index: u32, cut: bool) !void {
    const allocator = list.allocator;
    const file = part.diff.?;
    const note: []const u8 = if (file.binary)
        "Binary file"
    else if (part.hunks.len == 0)
        (if (file.mode_changed) "mode changed" else "No changes to show")
    else
        "";
    const files = [1]diff_widget.File{.{ .label = part.path, .note = note, .hunks = part.hunks }};
    const file_keys = [1]u64{file_key};
    const keys_of: diff_widget.Keys = .{ .files = &file_keys, .kinds = diff_kinds, .depth = depth, .file_lines = .left_to_caller };
    var built: diff_widget.Lines = .{};
    try diff_widget.lines(allocator, &files, keys_of, style.diffStyle(), &built);
    for (built.lines.items, built.at.items) |line, at| {
        if (line.kind == diff_kinds.hunk) _ = try list.isFolded(line.key, .open);
        try list.add(line, .{ .file = file_index, .hunk = at.hunk, .line = at.line });
    }
    if (!cut) return;
    // The ui font has ASCII only: three dots, not an ellipsis.
    const text = try std.fmt.allocPrint(allocator, "... the diff is cut: a file's hunks past {d} are not read", .{max_diff_hunks});
    const line: outline.Line = .{ .depth = depth +| 1, .kind = @intFromEnum(LineKind.notice), .key = keyOf(.notice, part.path), .text = text, .colour = style.col.text_dim };
    try list.add(line, .{ .file = file_index });
}

/// The most files, and bytes of diff, of a commit whose files the panel shows open.
pub const small_commit_files = 16;
pub const small_commit_bytes = 64 * 1024;

/// A commit's lines: its hash, author and date, its message, git's summary of its changes, then
/// `Files` and each file it changed, for a small commit open to its hunks until folded, for a
/// larger one folded until opened, so a build reads only those opened. While `show` has not
/// answered, its hash and `Loading...`; once it will not, its hash and what to do.
fn commitLines(list: *LineList, sources: Sources, commit: Shown.Commit) !void {
    const allocator = list.allocator;
    const state = sources.state;
    const hash = try ui.displayText(allocator, commit.hash);
    const hash_text = try std.fmt.allocPrint(allocator, "Commit:  {s}", .{hash});
    try list.plain(.info, "commit", hash_text, style.col.accent_bright);
    const loaded = state.diffs_loaded.* & status.DiffSource.shown.bit() != 0;
    const shown = (if (loaded) git.parseShow(state.shown_commit) else null) orelse {
        // The ui font has ASCII only: three dots, not an ellipsis.
        const waiting = if (sources.row.show_failed.* != 0) "Not shown; g asks again" else "Loading...";
        return list.notice(0, "loading", waiting);
    };
    const author_name = try ui.displayText(allocator, shown.author);
    const author = try std.fmt.allocPrint(allocator, "Author:  {s}", .{author_name});
    try list.plain(.info, "author", author, style.col.text);
    const date_text = try ui.displayText(allocator, shown.date);
    const date = try std.fmt.allocPrint(allocator, "Date:    {s}", .{date_text});
    try list.plain(.info, "date", date, style.col.text);
    try textLines(list, .message, shown.message, .text, style.col.text);
    try textLines(list, .stat, shown.stat, .code, style.col.text_dim);

    const indexed = try shownParts(allocator, sources.diff_files, shown.diff);
    if (indexed.len == 0) return;
    const files_seen = state.shown_files_seen.*;
    const heading = try std.fmt.allocPrint(allocator, "Files ({d})", .{files_seen});
    const heading_key = keyOf(.heading, "files");
    const heading_line: outline.Line = .{ .depth = 0, .kind = @intFromEnum(LineKind.heading), .key = heading_key, .text = heading, .colour = style.col.accent_bright, .expandable = true };
    _ = try list.isFolded(heading_key, .open);
    try list.add(heading_line, .{});
    // A small commit's files are open; a larger one's folded, so a build reads only those opened.
    const small = files_seen <= small_commit_files and shown.diff.len <= small_commit_bytes;
    if (!small) {
        const note = try std.fmt.allocPrint(allocator, "{d} files; tab opens one", .{files_seen});
        try list.notice(1, "folded", note);
    }
    const by_default: Fold = if (small) .open else .folded;
    for (indexed) |part| try partLines(list, part, 1, by_default);
    if (files_seen <= status.max_diff_files) return;
    // The ui font has ASCII only: three dots, not an ellipsis.
    const text = try std.fmt.allocPrint(allocator, "... the diff is cut: {d} of {d} files read", .{ status.max_diff_files, files_seen });
    try list.notice(1, "cut", text);
}

/// The files of the commit shown, in the order its diff, `diff`, has them, in `allocator`.
fn shownParts(allocator: std.mem.Allocator, diff_files: *Table, diff: []const u8) ![]Part {
    var parts: std.ArrayList(Part) = .empty;
    var offsets: std.ArrayList(u32) = .empty;
    var rows = diff_files.readQuery(status.DiffFileRow);
    while (rows.next()) |row| {
        if (row.view.source.* != @intFromEnum(status.DiffSource.shown)) continue;
        const part = partOfRow(row.view, diff) orelse continue;
        try parts.append(allocator, part);
        try offsets.append(allocator, row.view.offset.*);
    }
    const Order = struct {
        offsets: []const u32,
        fn before(order: @This(), a: usize, b: usize) bool {
            return order.offsets[a] < order.offsets[b];
        }
    };
    const order = try allocator.alloc(usize, parts.items.len);
    for (order, 0..) |*slot, index| slot.* = index;
    std.mem.sort(usize, order, Order{ .offsets = offsets.items }, Order.before);
    const sorted = try allocator.alloc(Part, parts.items.len);
    for (sorted, order) |*slot, index| slot.* = parts.items[index];
    return sorted;
}

/// Each line of `text`, git's, as a line of `kind` at the top, in `font` and `colour`; a blank
/// line of a message stays, as the space between its paragraphs.
fn textLines(list: *LineList, kind: LineKind, text: []const u8, font: outline.Font, colour: ui.Color) !void {
    if (text.len == 0) return;
    const allocator = list.allocator;
    var text_lines = std.mem.splitScalar(u8, text, '\n');
    var index: u32 = 0;
    while (text_lines.next()) |raw| : (index += 1) {
        const trimmed = std.mem.trimEnd(u8, raw, "\r");
        const shown = try ui.displayText(allocator, trimmed);
        const index_bytes = std.mem.asBytes(&index);
        const key = keyOf(kind, index_bytes);
        try list.add(.{ .depth = 0, .kind = @intFromEnum(kind), .key = key, .text = shown, .colour = colour, .font = font }, .{});
    }
}

/// What became of a file, as a word.
fn changeWord(change: git.Change) []const u8 {
    return switch (change) {
        .modified => "modified",
        .added => "new file",
        .deleted => "deleted",
        .renamed => "renamed",
        .copied => "copied",
    };
}

// ---- drawing -----------------------------------------------------------------------------------

/// Draws the panel: its header, its title what it shows, then its lines, scrolled as its
/// kernels left them. `frame` is the panel's frame in the window and `ctx` begins at its corner.
/// Writes no table.
pub fn render(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
    panel_frame.drawPlainHeader(memory, tables, atoms, panel, frame, ctx);
    const viewport = panel_frame.beginContent(tables, atoms, panel, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const scratch = memory.frameScratchAllocator() catch return;
    const allocator = scratch.allocator;
    const sources = sourcesOf(tables) orelse return;
    const built = build(allocator, sources) catch return;
    const out = allocator.alloc(u32, built.lines.len) catch return;
    const shown = outline.visible(built.lines, built.folded, out);
    const cursor = outline.settle(built.lines, shown, sources.row.cursor());
    const line_height = process_log.lineHeight(tables.findByName(font_metrics_table));
    const view_lines: u32 = @intFromFloat(@ceil(@max(viewport.height, 0) / line_height));
    const inbox = sequencer.inboxOf(status.system());
    var tree = ui.Tree.init(scratch, atoms, outline.elementCount(view_lines) + 2) catch return;
    if (tree.beginRect(panel_name, .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        outline.record(&tree, built.lines, shown, cursor, .{
            .inbox = inbox,
            .click_tag = .from(Msg.vcs_git_diff_click),
            .toggle_tag = .from(Msg.vcs_git_diff_chevron),
            .scroll_tag = .from(Msg.vcs_git_diff_wheel),
            .collapsed = built.folded,
            .view_height = viewport.height,
            .line_height = line_height,
            // The status's list may be drawn at once, its keys made the same way.
            .salt = panel.value(),
            .style = style.outlineStyle(),
        });
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, editor_state.hitRegions(tables, atoms));
}
