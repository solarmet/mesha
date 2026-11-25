//! vcs-p4's diff panel, `vcs_p4_diff`: an opened file's changes against the revision it was
//! opened at, or a submitted change, as an outline of files, hunks and their lines drawn with
//! `mesha.ui.diff`. A part of vcs-p4's system (`p4_status.zig`): what the panel shows, its
//! cursor, its folds and the diffs it holds are this file's tables, while the jobs, what is told
//! and the commands are the system's (`p4_status.Work`), which these functions are handed.
//!
//! - `show` opens the panel at the left of the changelists panel and gives it the focus; `follow`
//!   shows another file while it is open, the focus left where it is, as the changelists' cursor
//!   is moved by the person onto another file.
//! - A file's diff is its changelist's: one `p4 -x - diff -du` for the changelist's files
//!   opened for edit or integrate, their depot paths on the job's input, run with
//!   `p4.internal_diff_environment` so `p4` runs its own diff, asked when one of its files is
//!   first shown and kept until the next refresh. A submitted change is one `describe -du`.
//! - What a file's part of the answer holds decides what is shown (`p4.diffBodyOf`): hunks, by
//!   the diff widget; another program's output (a person's `P4DIFF`, `DIFF`, or one a `P4CONFIG`
//!   file names, which still wins), as plain text under a dim line saying why; a binary file
//!   that differs; or nothing, which for a file whose type is not text means it was not compared
//!   (`p4 diff` compares one only with `-t`), not that it is unchanged. A file opened for add or
//!   delete is not compared at all: the panel says what it is opened for.
//! - Its keys (mode `vcs_p4_diff`, under `vcs`, every one of `vcs`'s shadowed so that it comes to
//!   this system): `n` `p` `C-n` `C-p` by line, `M-n` `M-p` by hunk, `^`, `M-<` `M->`, `C-v`
//!   `M-v`, `tab` and `S-tab` fold, `RET` opens the workspace's file at the line, `k` reverts the
//!   file shown after the changelists' dialog, `s` and `u` tell that Perforce has no index, `g`
//!   asks again, `$` `C-g` `?` as in the changelists, and `q` or `C-x 0` close the panel, the
//!   focus going back by the panels system's history.

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
const p4 = @import("p4.zig");
const status = @import("p4_status.zig");
const process_log = @import("process_log.zig");
const modes = @import("../modes.zig");
const open = @import("../open.zig");
const panel_frame = @import("../panel_frame.zig");
const text_panel = @import("../text_panel.zig");
const transient = @import("../transient.zig");
const workspaces = @import("../workspaces.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");

// ---- the panel -----------------------------------------------------------------------------------

/// The panel's id.
pub const panel_name = "vcs_p4_diff";
/// The panel's id, as an atom.
pub const panel = Atom.from(panel_name);

/// The panel, a fixed panel the workspaces system declares while it is shown: at the left of
/// the changelists panel, half of the space they share, taking the focus.
pub const fixed_panel: plugin.panels.Open = .{
    .id = panel,
    .title = "vcs-p4 diff",
    .root = status.vcs_p4_root,
    .beside = status.panel,
    .side = .left,
    .share = 0.5,
};

/// What the panel shows. Its slices are the caller's, read during the call.
pub const Shown = union(enum) {
    /// An opened file, by its changelist and its depot path.
    file: File,
    /// A submitted change, by its number.
    change: u32,

    pub const File = struct { change: p4.Changelist, depot_path: []const u8 };
};

/// What the panel shows, as `PanelRow.shown` keeps it.
pub const ShownKind = enum(u8) { none, file, change };

/// Where an asked answer is.
pub const Asked = enum(u8) {
    /// Not asked.
    none,
    /// Asked, not answered.
    asked,
    /// Answered.
    loaded,
    /// Failed, or given up: shown as not compared until asked again.
    failed,
};

// ---- the messages, the actions and their keys ----------------------------------------------------

/// What the panel's part of the system takes.
pub const Msg = enum(u64) {
    vcs_p4_diff_next = Atom.from("vcs_p4_diff_next").value(),
    vcs_p4_diff_previous = Atom.from("vcs_p4_diff_previous").value(),
    vcs_p4_diff_next_hunk = Atom.from("vcs_p4_diff_next_hunk").value(),
    vcs_p4_diff_previous_hunk = Atom.from("vcs_p4_diff_previous_hunk").value(),
    vcs_p4_diff_parent = Atom.from("vcs_p4_diff_parent").value(),
    vcs_p4_diff_first = Atom.from("vcs_p4_diff_first").value(),
    vcs_p4_diff_last = Atom.from("vcs_p4_diff_last").value(),
    vcs_p4_diff_page_down = Atom.from("vcs_p4_diff_page_down").value(),
    vcs_p4_diff_page_up = Atom.from("vcs_p4_diff_page_up").value(),
    vcs_p4_diff_toggle = Atom.from("vcs_p4_diff_toggle").value(),
    vcs_p4_diff_toggle_all = Atom.from("vcs_p4_diff_toggle_all").value(),
    vcs_p4_diff_visit = Atom.from("vcs_p4_diff_visit").value(),
    vcs_p4_diff_revert = Atom.from("vcs_p4_diff_revert").value(),
    vcs_p4_diff_no_index = Atom.from("vcs_p4_diff_no_index").value(),
    vcs_p4_diff_refresh = Atom.from("vcs_p4_diff_refresh").value(),
    vcs_p4_diff_close = Atom.from("vcs_p4_diff_close").value(),
    vcs_p4_diff_process_log = Atom.from("vcs_p4_diff_process_log").value(),
    vcs_p4_diff_give_up = Atom.from("vcs_p4_diff_give_up").value(),
    vcs_p4_diff_menu = Atom.from("vcs_p4_diff_menu").value(),
    /// A click on a line, the line's key (`u64`) its user data.
    vcs_p4_diff_click = Atom.from("vcs_p4_diff_click").value(),
    /// A click on a line's chevron, the line's key its user data.
    vcs_p4_diff_chevron = Atom.from("vcs_p4_diff_chevron").value(),
    /// The wheel over the list, an `input.MouseScrollMsg`.
    vcs_p4_diff_wheel = Atom.from("vcs_p4_diff_wheel").value(),
    _,
};

/// The actions of mode `vcs_p4_diff`.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = @tagName(Msg.vcs_p4_diff_next), .doc = "Move to the next line" },
    .{ .name = "previous", .tag = @tagName(Msg.vcs_p4_diff_previous), .doc = "Move to the line before" },
    .{ .name = "next_hunk", .tag = @tagName(Msg.vcs_p4_diff_next_hunk), .doc = "Move to the next hunk" },
    .{ .name = "previous_hunk", .tag = @tagName(Msg.vcs_p4_diff_previous_hunk), .doc = "Move to the hunk before" },
    .{ .name = "parent", .tag = @tagName(Msg.vcs_p4_diff_parent), .doc = "Move to the hunk or the file this line is in" },
    .{ .name = "first", .tag = @tagName(Msg.vcs_p4_diff_first), .doc = "Move to the first line" },
    .{ .name = "last", .tag = @tagName(Msg.vcs_p4_diff_last), .doc = "Move to the last line" },
    .{ .name = "page_down", .tag = @tagName(Msg.vcs_p4_diff_page_down), .doc = "Move a page down" },
    .{ .name = "page_up", .tag = @tagName(Msg.vcs_p4_diff_page_up), .doc = "Move a page up" },
    .{ .name = "toggle", .tag = @tagName(Msg.vcs_p4_diff_toggle), .doc = "Fold or open the hunk or the file at the cursor" },
    .{ .name = "toggle_all", .tag = @tagName(Msg.vcs_p4_diff_toggle_all), .doc = "Fold every hunk, or open them all" },
    .{ .name = "visit", .tag = @tagName(Msg.vcs_p4_diff_visit), .doc = "Open the workspace's file at the cursor's line" },
    .{ .name = "revert", .tag = @tagName(Msg.vcs_p4_diff_revert), .doc = "Revert the file shown, after asking" },
    .{ .name = "no_index", .tag = @tagName(Msg.vcs_p4_diff_no_index), .doc = "Perforce has no index: say where submitting is" },
    .{ .name = "refresh", .tag = @tagName(Msg.vcs_p4_diff_refresh), .doc = "Ask p4 again" },
    .{ .name = "close", .tag = @tagName(Msg.vcs_p4_diff_close), .doc = "Close the diff" },
    .{ .name = "process_log", .tag = @tagName(Msg.vcs_p4_diff_process_log), .doc = "Show the commands run and what they said" },
    .{ .name = "give_up", .tag = @tagName(Msg.vcs_p4_diff_give_up), .doc = "Give up the commands that run" },
    .{ .name = "menu", .tag = @tagName(Msg.vcs_p4_diff_menu), .doc = "Show the menu of what vcs-p4 does" },
};

/// The keys of mode `vcs_p4_diff`, over `vcs`'s, every one of which they shadow.
pub const keys = [_]keybinds.KeyDef{
    .{ .chord = "n", .action = .{ "vcs_p4_diff", "next" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "vcs_p4_diff", "next" }, .trigger = .repeat },
    .{ .chord = "p", .action = .{ "vcs_p4_diff", "previous" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "vcs_p4_diff", "previous" }, .trigger = .repeat },
    .{ .chord = "M-n", .action = .{ "vcs_p4_diff", "next_hunk" }, .trigger = .repeat },
    .{ .chord = "M-p", .action = .{ "vcs_p4_diff", "previous_hunk" }, .trigger = .repeat },
    .{ .chord = "S-6", .action = .{ "vcs_p4_diff", "parent" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "vcs_p4_diff", "first" } },
    .{ .chord = "M-S-period", .action = .{ "vcs_p4_diff", "last" } },
    .{ .chord = "C-v", .action = .{ "vcs_p4_diff", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "vcs_p4_diff", "page_up" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "vcs_p4_diff", "toggle" } },
    .{ .chord = "S-tab", .action = .{ "vcs_p4_diff", "toggle_all" } },
    .{ .chord = "RET", .action = .{ "vcs_p4_diff", "visit" } },
    .{ .chord = "k", .action = .{ "vcs_p4_diff", "revert" } },
    .{ .chord = "s", .action = .{ "vcs_p4_diff", "no_index" } },
    .{ .chord = "u", .action = .{ "vcs_p4_diff", "no_index" } },
    .{ .chord = "g", .action = .{ "vcs_p4_diff", "refresh" } },
    .{ .chord = "q", .action = .{ "vcs_p4_diff", "close" } },
    .{ .chord = "C-x 0", .action = .{ "vcs_p4_diff", "close" } },
    .{ .chord = "S-4", .action = .{ "vcs_p4_diff", "process_log" } },
    .{ .chord = "C-g", .action = .{ "vcs_p4_diff", "give_up" } },
    .{ .chord = "S-slash", .action = .{ "vcs_p4_diff", "menu" } },
};

/// Offers the actions of mode `vcs_p4_diff`, `inbox` taking them: vcs-p4's system's.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    for (actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_p4_diff, inbox, &.{.{ .def = def }});
}

/// Whether `tag` is one of the panel's messages.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

// ---- the tables ----------------------------------------------------------------------------------

/// `editor_vcs_p4_diff`: the panel's own row, one (`PanelRow`).
pub const panel_table_name = "editor_vcs_p4_diff";
/// `editor_vcs_p4_diff_folds`: the keys of the lines folded, or opened against how they show by
/// default (`process_log.FoldRow`). Emptied as the panel shows something else.
pub const folds_table_name = "editor_vcs_p4_diff_folds";
/// `editor_vcs_p4_diffs`: the changelists' diffs the panel holds, a row each (`DiffRow`),
/// forgotten by each refresh.
pub const diffs_table_name = "editor_vcs_p4_diffs";

/// The most lines the panel keeps folded or opened.
pub const max_folds = 1024;
/// The most changelists' diffs the panel holds at once.
pub const max_diffs = 64;
/// The most hunks a build reads of a diff.
pub const max_diff_hunks = 65_536;

/// The row of `editor_vcs_p4_diff`.
pub const PanelRow = struct {
    /// A `ShownKind`.
    shown: *u8,
    /// For a file, its changelist as the tables write it (`default`, or the number).
    file_change: *Table.String,
    /// For a file, its depot path.
    depot_path: *Table.String,
    /// For a submitted change, its number.
    number: *u32,
    /// The panel's `outline.Cursor`.
    cursor_key: *u64,
    cursor_index: *u32,
    cursor_scroll: *f32,
    /// The height of the list the last run settled the scroll for, in pixels.
    view_height: *f32,
    /// What `describe -du` said of the change shown.
    described: *Table.Bytes,
    /// An `Asked`: of the change shown's `describe`.
    describe_state: *u8,
    /// Counts the describes asked: an answer of an earlier one is dropped.
    describe_serial: *u32,
    /// Counts the diffs asked: each diff's row keeps its own, which its answer carries.
    diff_serial: *u32,
};

/// `PanelRow` read, its text as slices of the table's.
pub const PanelRead = struct {
    shown: *u8,
    file_change: []const u8,
    depot_path: []const u8,
    number: *u32,
    cursor_key: *u64,
    cursor_index: *u32,
    cursor_scroll: *f32,
    view_height: *f32,
    described: []const u8,
    describe_state: *u8,
    describe_serial: *u32,
    diff_serial: *u32,

    fn cursor(row: PanelRead) outline.Cursor {
        return .{ .key = row.cursor_key.*, .index = row.cursor_index.*, .scroll = row.cursor_scroll.* };
    }
};

/// A row of `editor_vcs_p4_diffs`: a changelist's diff.
pub const DiffRow = struct {
    /// The changelist, as the tables write it.
    change: []const u8,
    /// An `Asked`.
    state: *u8,
    /// `PanelRow.diff_serial` as it was asked, which its answer carries.
    serial: *u32,
    /// What `diff -du` said.
    bytes: []const u8,
};

const panel_table = Atom.from(panel_table_name);
const folds_table = Atom.from(folds_table_name);
const diffs_table = Atom.from(diffs_table_name);
const shown_panels_table = Atom.from(workspaces.shown_panels_table_name);
const font_metrics_table = Atom.from(resources.font_metrics_table_name);

/// Makes the panel's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ panel_table_name, folds_table_name, diffs_table_name, panel_name });
    var row: Table.Schema = undefined;
    try row.init(scratch.allocator, atoms, 12);
    defer row.deinit();
    try row.addFieldFallible("shown", u8, .int);
    try row.addFieldFallible("file_change", Table.String, .text_field);
    try row.addFieldFallible("depot_path", Table.String, .text_field);
    try row.addFieldFallible("number", u32, .int);
    try row.addFieldFallible("cursor_key", u64, .int);
    try row.addFieldFallible("cursor_index", u32, .int);
    try row.addFieldFallible("cursor_scroll", f32, .int);
    try row.addFieldFallible("view_height", f32, .int);
    try row.addFieldFallible("described", Table.Bytes, .bytes);
    try row.addFieldFallible("describe_state", u8, .int);
    try row.addFieldFallible("describe_serial", u32, .int);
    try row.addFieldFallible("diff_serial", u32, .int);
    const defaults = .{
        .shown = @as(u8, @intFromEnum(ShownKind.none)),
        .file_change = Table.String{},
        .depot_path = Table.String{},
        .number = @as(u32, 0),
        .cursor_key = @as(u64, 0),
        .cursor_index = @as(u32, 0),
        .cursor_scroll = @as(f32, 0),
        .view_height = @as(f32, 0),
        .described = Table.Bytes{},
        .describe_state = @as(u8, @intFromEnum(Asked.none)),
        .describe_serial = @as(u32, 0),
        .diff_serial = @as(u32, 0),
    };
    _ = try tables.ensureSingleton(&row, panel_table, defaults, .durable);

    var folds: Table.Schema = undefined;
    try folds.init(scratch.allocator, atoms, 1);
    defer folds.deinit();
    try folds.addFieldFallible("key", u64, .hex);
    _ = try tables.ensure(&folds, max_folds, folds_table, .durable);

    var diffs: Table.Schema = undefined;
    try diffs.init(scratch.allocator, atoms, 4);
    defer diffs.deinit();
    try diffs.addFieldFallible("change", Table.String, .text_field);
    try diffs.addFieldFallible("state", u8, .int);
    try diffs.addFieldFallible("serial", u32, .int);
    try diffs.addFieldFallible("bytes", Table.Bytes, .bytes);
    _ = try tables.ensure(&diffs, max_diffs, diffs_table, .durable);
}

/// What vcs-p4's system writes for the panel: its three tables. (Opening a file at a line, `RET`,
/// writes the text panels' requests, which the system declares through `open.declareOpenAccess`.)
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    _ = tables;
    result.writeAll(&.{ panel_table, folds_table, diffs_table });
}

// ---- showing -------------------------------------------------------------------------------------

/// Shows `shown` in the panel, opening it at the left of the changelists panel, and gives it the
/// focus; a file's changelist's diff is asked when it is not held, a change's `describe` when
/// it is not the one held.
pub fn show(work: status.Work, shown: Shown) !void {
    const changed = !try isShowing(work, shown);
    try keep(work, shown, changed);
    try askFor(work, shown, changed);
    const frame = work.pass.frame;
    workspaces.showPanel(frame.tables, frame.atoms, panel, .arranged, .take);
    try retitle(work);
}

/// Shows `shown` as `show` does while the panel is open, leaving the focus where it is; nothing
/// while it is closed or shows it already.
pub fn follow(work: status.Work, shown: Shown) !void {
    if (!isOpen(work.pass)) return;
    if (try isShowing(work, shown)) return;
    try keep(work, shown, true);
    try askFor(work, shown, true);
    try retitle(work);
}

/// Whether the panel is shown: declared, open or about to open.
pub fn isOpen(pass: *const sequencer.Pass) bool {
    if (!pass.declares(shown_panels_table)) return false;
    return workspaces.panelShown(pass.frame.tables, panel);
}

fn isShowing(work: status.Work, shown: Shown) !bool {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const kind = std.enums.fromInt(ShownKind, row.shown.*) orelse .none;
    const allocator = try work.scratch();
    return switch (shown) {
        .file => |file| blk: {
            const change_text = try status.changeText(allocator, file.change);
            break :blk kind == .file and std.mem.eql(u8, row.depot_path, file.depot_path) and std.mem.eql(u8, row.file_change, change_text);
        },
        .change => |number| kind == .change and row.number.* == number,
    };
}

/// Records `shown`; when it `changed`, the cursor goes to the top and the folds are let go.
fn keep(work: status.Work, shown: Shown, changed: bool) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    const cells = try work.writeCells(panel_table);
    const allocator = try work.scratch();
    switch (shown) {
        .file => |file| {
            row.shown.* = @intFromEnum(ShownKind.file);
            const change_text = try status.changeText(allocator, file.change);
            const depot_path = try allocator.dupe(u8, file.depot_path);
            try cells.assignString(row.file_change, change_text);
            try cells.assignString(row.depot_path, depot_path);
        },
        .change => |number| {
            if (row.shown.* != @intFromEnum(ShownKind.change) or row.number.* != number) {
                row.described.* = .{};
                row.describe_state.* = @intFromEnum(Asked.none);
            }
            row.shown.* = @intFromEnum(ShownKind.change);
            row.number.* = number;
            try cells.assignString(row.file_change, "");
            try cells.assignString(row.depot_path, "");
        },
    }
    if (!changed) return;
    row.cursor_key.* = 0;
    row.cursor_index.* = 0;
    row.cursor_scroll.* = 0;
    const folds = try work.pass.writeTable(folds_table);
    folds.clear();
}

/// What `shown` needs asked: its changelist's diff, unless held; its change's `describe`,
/// unless held (or `again`, after a failure).
fn askFor(work: status.Work, shown: Shown, again: bool) !void {
    switch (shown) {
        .file => |file| try askChange(work, file.change),
        .change => |number| {
            const row = try work.pass.readSingleton(panel_table, PanelRead);
            const state = std.enums.fromInt(Asked, row.describe_state.*) orelse .none;
            const held = state == .loaded or state == .asked;
            if (held and !again) return;
            if (state == .loaded and row.number.* == number) return;
            try askDescribe(work, number);
        },
    }
}

/// Asks `describe -du` of `number`, one program.
fn askDescribe(work: status.Work, number: u32) !void {
    if (work.refusedWithoutWorkspace()) return;
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.describe_serial.* +%= 1;
    row.describe_state.* = @intFromEnum(Asked.asked);
    row.described.* = .{};
    try work.queueRead(.describe, .{ .describe = number }, "", row.describe_serial.*);
}

/// Asks `change`'s diff, one `-x - diff -du` with its files opened for edit or integrate on the
/// input, unless it is held or asked, or a refresh or a command runs (whose end asks it), or
/// none of its files is compared.
pub fn askChange(work: status.Work, change: p4.Changelist) !void {
    const allocator = try work.scratch();
    const key = try status.changeText(allocator, change);
    const held = try work.pass.writeTable(diffs_table);
    if (diffRowOf(held, key) != null) return;
    if (work.state.refresh_jobs.* != 0 or work.state.commands_running.* != 0) return;
    if (work.state.info_known.* == 0) return;
    const files = try work.filesOf(change);
    var paths: std.ArrayList([]const u8) = .empty;
    for (files) |file| {
        if (compared(file.opened_for)) try paths.append(allocator, file.depot_path);
    }
    if (paths.items.len == 0) return;
    var input_bytes: std.Io.Writer.Allocating = .init(allocator);
    p4.writePaths(&input_bytes.writer, paths.items, .depot_paths, status.host_style) catch |err| return work.tellUnpassable(err);
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    row.diff_serial.* +%= 1;
    const serial = row.diff_serial.*;
    const diffs = try work.writeCells(diffs_table);
    if (diffs.count() >= diffs.rowCapacity()) diffs.clear();
    _ = try diffs.tryInsert(.{ .change = key, .state = @as(u8, @intFromEnum(Asked.asked)), .serial = serial, .bytes = Table.Bytes{} });
    try work.queueRead(.diff, .diff, input_bytes.written(), serial);
}

/// Whether `p4 diff` compares a file opened for `opened_for` (`p4_diff.html`: "the client file
/// must be open for `edit`"); an integrated file is opened for edit too.
fn compared(opened_for: []const u8) bool {
    return std.mem.eql(u8, opened_for, "edit") or std.mem.eql(u8, opened_for, "integrate");
}

/// The row of `diffs` of the changelist `key`; null for none.
fn diffRowOf(diffs: *Table, key: []const u8) ?Table.RowHandle {
    var rows = diffs.readQuery(DiffRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.change, key)) return row.handle;
    }
    return null;
}

/// A changelist's diff answered, `said` null for one that failed: kept for its files until the
/// next refresh; an answer of a diff forgotten meanwhile is dropped.
pub fn takeDiff(work: status.Work, serial: u32, said: ?[]const u8) !void {
    const diffs = try work.writeCells(diffs_table);
    var rows = diffs.readQuery(DiffRow);
    const handle = while (rows.next()) |row| {
        if (row.view.serial.* == serial) break row.handle;
    } else return;
    const row = diffs.getRow(handle, struct { state: *u8, bytes: *Table.Bytes }) orelse return;
    if (said) |bytes| {
        row.state.* = @intFromEnum(Asked.loaded);
        row.bytes.* = .{ .payload = try diffs.appendPayload(bytes, .@"16") };
    } else {
        row.state.* = @intFromEnum(Asked.failed);
        work.tell("p4 diff failed; $ shows why");
    }
}

/// A change's `describe` answered, `said` null for one that failed; an answer of an earlier one
/// is dropped.
pub fn takeDescribe(work: status.Work, serial: u32, said: ?[]const u8) !void {
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    if (serial != row.describe_serial.*) return;
    const cells = try work.writeCells(panel_table);
    const bytes = said orelse {
        row.describe_state.* = @intFromEnum(Asked.failed);
        return work.tell("p4 describe failed; $ shows why");
    };
    row.described.* = .{ .payload = try cells.appendPayload(bytes, .@"16") };
    row.describe_state.* = @intFromEnum(Asked.loaded);
}

/// Each refresh forgets the changelists' diffs, what they were of having changed.
pub fn forgetDiffs(work: status.Work) !void {
    const diffs = try work.pass.writeTable(diffs_table);
    diffs.clear();
}

/// A give-up moved the generation on: what was asked and not answered never will be.
pub fn abandon(work: status.Work) !void {
    const diffs = try work.pass.writeTable(diffs_table);
    var asked: std.ArrayList(Table.RowHandle) = .empty;
    const allocator = try work.scratch();
    var rows = diffs.readQuery(DiffRow);
    while (rows.next()) |row| {
        if (row.view.state.* == @intFromEnum(Asked.asked)) try asked.append(allocator, row.handle);
    }
    for (asked.items) |handle| {
        const held = diffs.getRow(handle, struct { state: *u8 }) orelse continue;
        held.state.* = @intFromEnum(Asked.failed);
    }
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    if (row.describe_state.* == @intFromEnum(Asked.asked)) row.describe_state.* = @intFromEnum(Asked.failed);
}

/// Another project: the panel shows nothing.
pub fn forget(work: status.Work) !void {
    try forgetDiffs(work);
    const row = try work.pass.writeSingleton(panel_table, PanelRow);
    const cells = try work.writeCells(panel_table);
    row.shown.* = @intFromEnum(ShownKind.none);
    row.described.* = .{};
    row.describe_state.* = @intFromEnum(Asked.none);
    try cells.assignString(row.file_change, "");
    try cells.assignString(row.depot_path, "");
    workspaces.setPanelTitle(work.tables(), panel, "");
}

/// As a refresh ends: the diff the panel shows a file of, asked again.
pub fn askWanted(work: status.Work) !void {
    if (!isOpen(work.pass)) return;
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    if (row.shown.* != @intFromEnum(ShownKind.file)) return;
    const change = status.changelistOf(row.file_change) orelse return;
    try askChange(work, change);
}

/// Titles the panel with what it shows.
fn retitle(work: status.Work) !void {
    const allocator = try work.scratch();
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const kind = std.enums.fromInt(ShownKind, row.shown.*) orelse .none;
    const title = switch (kind) {
        .none => return,
        .file => blk: {
            const change = status.changelistOf(row.file_change) orelse return;
            const named = try status.changelistName(allocator, change);
            const path = try ui.displayText(allocator, row.depot_path);
            break :blk try std.fmt.allocPrint(allocator, "{s} ({s})", .{ path, named });
        },
        .change => try std.fmt.allocPrint(allocator, "Change {d}", .{row.number.*}),
    };
    workspaces.setPanelTitle(work.tables(), panel, title);
}

/// A kernel's part of vcs-p4's system: the scroll kept fit to the panel's view as it is
/// resized.
pub fn followLayout(pass: *sequencer.Pass) !void {
    if (!isOpen(pass)) return;
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

// ---- what a message does -------------------------------------------------------------------------

/// One of the panel's messages.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_p4_diff_next => try move(work, .next),
        .vcs_p4_diff_previous => try move(work, .previous),
        .vcs_p4_diff_parent => try move(work, .parent),
        .vcs_p4_diff_first => try move(work, .first),
        .vcs_p4_diff_last => try move(work, .last),
        .vcs_p4_diff_page_down => try move(work, .page_down),
        .vcs_p4_diff_page_up => try move(work, .page_up),
        .vcs_p4_diff_next_hunk => try moveByHunk(work, .next),
        .vcs_p4_diff_previous_hunk => try moveByHunk(work, .previous),
        .vcs_p4_diff_toggle => try toggleAtCursor(work),
        .vcs_p4_diff_toggle_all => try toggleAll(work),
        .vcs_p4_diff_visit => try visit(work),
        .vcs_p4_diff_revert => try revert(work),
        .vcs_p4_diff_no_index => work.tell("Perforce has no index: s in the changelists panel submits"),
        .vcs_p4_diff_refresh => try askAgain(work),
        .vcs_p4_diff_close => workspaces.hidePanel(work.tables(), panel),
        .vcs_p4_diff_process_log => try work.showProcessLog(),
        .vcs_p4_diff_give_up => try work.giveUp(),
        .vcs_p4_diff_menu => {
            const reply = sequencer.ReplyTo.of(status.system(), .from(status.Msg.vcs_p4_menu_chosen));
            transient.present(work.memory(), work.tables(), .{ .menu = &status.menu, .reply = reply });
        },
        .vcs_p4_diff_click => {
            const key = (try received.userDataAs(u64)).*;
            try putCursorOn(work, key);
        },
        .vcs_p4_diff_chevron => {
            const key = (try received.userDataAs(u64)).*;
            try toggleLine(work, key);
        },
        .vcs_p4_diff_wheel => {
            const scrolled = try received.payloadAs(input.MouseScrollMsg);
            try wheel(work, scrolled.y);
        },
        _ => {},
    }
}

/// `g`: a file's changelist's diff asked again, a change's `describe` too.
fn askAgain(work: status.Work) !void {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    const kind = std.enums.fromInt(ShownKind, row.shown.*) orelse .none;
    switch (kind) {
        .none => {},
        .file => {
            const change = status.changelistOf(row.file_change) orelse return;
            const allocator = try work.scratch();
            const key = try status.changeText(allocator, change);
            const diffs = try work.pass.writeTable(diffs_table);
            if (diffRowOf(diffs, key)) |handle| diffs.free(handle);
            try askChange(work, change);
        },
        .change => try askDescribe(work, row.number.*),
    }
}

/// `k`: the file shown reverted, after the changelists' dialog; refused, as the changelists'
/// `k` is, while the lists could not be read.
fn revert(work: status.Work) !void {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    if (row.shown.* != @intFromEnum(ShownKind.file)) return work.tell("A submitted change: there is nothing to revert");
    if (work.refusedWhileUnread()) return;
    const change = status.changelistOf(row.file_change) orelse return;
    const allocator = try work.scratch();
    const depot_path = try allocator.dupe(u8, row.depot_path);
    try work.askRevert(.{ .change = change, .depot_path = depot_path });
}

/// Whether a cursor's change scrolls the view to follow it.
const Scroll = enum { follow, keep };

fn storedCursor(work: status.Work) !outline.Cursor {
    const row = try work.pass.readSingleton(panel_table, PanelRead);
    return row.cursor();
}

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

fn moveByHunk(work: status.Work, direction: diff_widget.Direction) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    const hunk_kind: u8 = @intFromEnum(LineKind.hunk);
    const moved = diff_widget.stepHunk(built.lines, shown, try storedCursor(work), hunk_kind, direction);
    try setCursor(work, shown, moved, .follow);
}

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
    const rebuilt = try buildIn(work);
    const reshown = try visibleOf(work, rebuilt);
    const resettled = outline.settle(rebuilt.lines, reshown, settled);
    try setCursor(work, reshown, resettled, .follow);
}

fn toggleLine(work: status.Work, key: u64) !void {
    const folds = try work.pass.writeTable(folds_table);
    if (process_log.findFold(folds, key)) |handle| {
        folds.free(handle);
        return;
    }
    if (folds.count() >= folds.rowCapacity()) return;
    _ = try folds.tryInsert(.{ .key = key });
}

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

/// `RET`: an opened file's local file opened at the line the cursor's hunk line is at in it
/// (`ui.diff.newLine`), or at its start; a submitted change's file is not in the workspace.
fn visit(work: status.Work) !void {
    const built = try buildIn(work);
    const shown = try visibleOf(work, built);
    if (shown.len == 0) return;
    if (built.local_path.len == 0) return work.tell("A submitted change's file: RET opens a file opened in the workspace");
    const settled = outline.settle(built.lines, shown, try storedCursor(work));
    const line_index = shown[settled.index];
    const line = built.lines[line_index];
    const target = built.targets[line_index];
    const allocator = try work.scratch();
    const path = try allocator.dupe(u8, built.local_path);
    const kind: LineKind = @enumFromInt(line.kind);
    const on_hunk = (kind == .hunk or kind == .line) and target.hunk != diff_widget.none;
    if (!on_hunk) return open.openPath(work.pass, path, .present);
    const hunk = built.hunks[target.hunk];
    const line_number = if (kind == .line) diff_widget.newLine(hunk, target.line) else hunk.new_start;
    text_panel.openAt(work.tables(), path, line_number -| 1, 0);
}

// ---- the lines -----------------------------------------------------------------------------------

/// What a line is, as `outline.Line.kind` keeps it.
pub const LineKind = enum(u8) {
    /// A submitted change's own lines: its number, who, when, its description.
    info,
    /// What the panel says in place of what it would show, dimmed.
    notice,
    /// A file's line.
    file,
    /// What a file shows in place of hunks.
    note,
    /// A hunk's `@@` line.
    hunk,
    /// A line of a hunk.
    line,
    /// A line of another program's diff, shown as it is.
    text,
};

const diff_kinds: diff_widget.Kinds = .{
    .file = @intFromEnum(LineKind.file),
    .note = @intFromEnum(LineKind.note),
    .hunk = @intFromEnum(LineKind.hunk),
    .line = @intFromEnum(LineKind.line),
};

/// What a line is about: its hunk among `Built.hunks` and its place in the hunk's body.
pub const Target = struct {
    hunk: u32 = diff_widget.none,
    line: u32 = diff_widget.none,
};

/// The lines the panel shows, what each is about and the keys of those folded. All in the
/// allocator `build` was given, or the tables', good for the frame.
pub const Built = struct {
    lines: []outline.Line,
    targets: []Target,
    folded: []u64,
    /// The hunks the lines were built from, which a line's `Target.hunk` counts in.
    hunks: []const diff_widget.Hunk,
    /// For an opened file, its local path; empty for a submitted change.
    local_path: []const u8,
};

/// What the lines are built from, as a kernel's run or the draw reads the tables.
pub const Sources = struct {
    row: PanelRead,
    diffs: *Table,
    folds: *Table,
    default_files: *Table,
    opened_files: *Table,
};

/// The panel's tables as the draw reads them; null without them.
pub fn sourcesOf(tables: *Table.Registry) ?Sources {
    const row_table = tables.findByName(panel_table) orelse return null;
    const row = row_table.getRow(.{ .row = 0, .generation = row_table.rowGeneration(0) }, PanelRead) orelse return null;
    return .{
        .row = row,
        .diffs = tables.findByName(diffs_table) orelse return null,
        .folds = tables.findByName(folds_table) orelse return null,
        .default_files = tables.findByName(Atom.from(status.default_table_name)) orelse return null,
        .opened_files = tables.findByName(Atom.from(status.opened_table_name)) orelse return null,
    };
}

fn buildIn(work: status.Work) !Built {
    const allocator = try work.scratch();
    const sources: Sources = .{
        .row = try work.pass.readSingleton(panel_table, PanelRead),
        .diffs = try work.pass.writeTable(diffs_table),
        .folds = try work.pass.writeTable(folds_table),
        .default_files = work.default_files,
        .opened_files = work.opened_files,
    };
    return build(allocator, sources);
}

fn visibleOf(work: status.Work, built: Built) ![]u32 {
    const allocator = try work.scratch();
    const out = try allocator.alloc(u32, built.lines.len);
    return outline.visible(built.lines, built.folded, out);
}

/// Lines and their targets as they are built.
const LineList = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(outline.Line) = .empty,
    targets: std.ArrayList(Target) = .empty,
    folded: std.ArrayList(u64) = .empty,
    hunks: std.ArrayList(diff_widget.Hunk) = .empty,
    /// The keys turned from how they show by default, sorted.
    toggled: []const u64,

    fn add(list: *LineList, line: outline.Line, target: Target) !void {
        try list.lines.append(list.allocator, line);
        try list.targets.append(list.allocator, target);
    }

    fn notice(list: *LineList, depth: u8, key_text: []const u8, text: []const u8) !void {
        const line: outline.Line = .{ .depth = depth, .kind = @intFromEnum(LineKind.notice), .key = keyOf(.notice, key_text), .text = text, .colour = style.col.text_dim };
        try list.add(line, .{});
    }

    /// Whether the line `key`, open by default, is folded now; noted among the folded when it
    /// is.
    fn isFolded(list: *LineList, key: u64) !bool {
        const folded = process_log.holds(list.toggled, key);
        if (folded) try list.folded.append(list.allocator, key);
        return folded;
    }
};

/// A line's key: its kind, and the text that names it among them. Never 0.
fn keyOf(kind: LineKind, text: []const u8) u64 {
    const key = std.hash.Wyhash.hash(@intFromEnum(kind), text);
    return if (key == 0) 1 else key;
}

/// The lines of what `sources.row` says the panel shows, in `allocator`, an arena's.
pub fn build(allocator: std.mem.Allocator, sources: Sources) !Built {
    var list: LineList = .{ .allocator = allocator, .toggled = try process_log.sortedKeys(allocator, sources.folds) };
    var local_path: []const u8 = "";
    const kind = std.enums.fromInt(ShownKind, sources.row.shown.*) orelse .none;
    switch (kind) {
        .none => try list.notice(0, "nothing", "Nothing to show"),
        .file => local_path = try fileLines(&list, sources),
        .change => try changeLines(&list, sources),
    }
    return .{ .lines = list.lines.items, .targets = list.targets.items, .folded = list.folded.items, .hunks = list.hunks.items, .local_path = local_path };
}

/// An opened file's lines: what it is opened for when that is not compared, else its part of
/// its changelist's diff as `p4.diffBodyOf` reads it. Returns its local path.
fn fileLines(list: *LineList, sources: Sources) ![]const u8 {
    const allocator = list.allocator;
    const row = sources.row;
    const table = if (std.mem.eql(u8, row.file_change, "default")) sources.default_files else sources.opened_files;
    const file = fileRowOf(table, row.depot_path, row.file_change) orelse {
        try list.notice(0, "gone", "No longer opened in that changelist: g asks again");
        return "";
    };
    if (!compared(file.opened_for)) {
        const text = if (std.mem.eql(u8, file.opened_for, "add") or std.mem.eql(u8, file.opened_for, "move/add"))
            try std.fmt.allocPrint(allocator, "Opened for {s}: there is no revision it was opened at to compare it with", .{file.opened_for})
        else if (std.mem.eql(u8, file.opened_for, "delete") or std.mem.eql(u8, file.opened_for, "move/delete"))
            try std.fmt.allocPrint(allocator, "Opened for {s}: it goes from the depot when its changelist is submitted", .{file.opened_for})
        else
            try std.fmt.allocPrint(allocator, "Opened for {s}: p4 diff compares only files opened for edit", .{file.opened_for});
        try list.notice(0, "not compared", text);
        return file.local_path;
    }
    const diff_row = diffOf(sources.diffs, row.file_change) orelse {
        try list.notice(0, "loading", "Loading...");
        return file.local_path;
    };
    const state = std.enums.fromInt(Asked, diff_row.state) orelse .none;
    switch (state) {
        .none, .asked => {
            // The ui font has ASCII only: three dots, not an ellipsis.
            try list.notice(0, "loading", "Loading...");
            return file.local_path;
        },
        .failed => {
            try list.notice(0, "failed", "Not compared: p4 diff failed ($ shows why); g asks again");
            return file.local_path;
        },
        .loaded => {},
    }
    const parsed = try parseAll(allocator, diff_row.bytes);
    for (parsed.files) |part| {
        if (!std.mem.eql(u8, part.depot_path, file.depot_path)) continue;
        try partLines(list, parsed, part, 0, file.file_type, .opened);
        return file.local_path;
    }
    try list.notice(0, "none", try emptyText(allocator, file.file_type, .opened));
    return file.local_path;
}

/// Whether a part is of an opened file or of a submitted change, which words its emptiness.
const Of = enum { opened, submitted };

/// What the panel says of a file whose part holds nothing.
fn emptyText(allocator: std.mem.Allocator, file_type: []const u8, of: Of) ![]const u8 {
    if (file_type.len == 0) return "Nothing to show (its type is not known)";
    if (!isTextType(file_type)) return std.fmt.allocPrint(allocator, "Not compared: p4 diff compares a file of type {s} only with -t", .{file_type});
    return switch (of) {
        .opened => "No changes since it was opened",
        .submitted => "No differences shown",
    };
}

/// Whether `file_type` is one `p4 diff` compares without `-t`: of the text kinds (`text`,
/// `ktext`, `unicode`, `utf8`, `utf16`).
fn isTextType(file_type: []const u8) bool {
    const text_kinds = [_][]const u8{ "text", "unicode", "utf8", "utf16" };
    for (text_kinds) |kind| {
        if (std.mem.indexOf(u8, file_type, kind) != null) return true;
    }
    return false;
}

/// A diff parsed: its files and their hunks, in the frame's memory.
const Parsed = struct {
    files: []p4.FileDiff,
    hunks: []diff_widget.Hunk,
};

fn parseAll(allocator: std.mem.Allocator, bytes: []const u8) !Parsed {
    const sized = p4.parseDiff(bytes, &.{}, &.{});
    const files = try allocator.alloc(p4.FileDiff, sized.files.seen);
    const hunk_room = @min(sized.hunks.seen, max_diff_hunks);
    const hunks = try allocator.alloc(diff_widget.Hunk, hunk_room);
    const counts = p4.parseDiff(bytes, files, hunks);
    return .{ .files = files[0..counts.files.kept], .hunks = hunks[0..counts.hunks.kept] };
}

/// A file's part at `depth`, as `p4.diffBodyOf` reads it: its hunks, or what else it holds.
fn partLines(list: *LineList, parsed: Parsed, part: p4.FileDiff, depth: u8, file_type: []const u8, of: Of) !void {
    const allocator = list.allocator;
    const file_key = keyOf(.file, part.depot_path);
    switch (p4.diffBodyOf(part)) {
        .hunks => {
            const hunks = parsed.hunks[part.first_hunk..][0..part.hunk_count];
            const first_hunk: u32 = @intCast(list.hunks.items.len);
            try list.hunks.appendSlice(allocator, hunks);
            const files = [1]diff_widget.File{.{ .label = part.depot_path, .note = "", .hunks = hunks }};
            const file_keys = [1]u64{file_key};
            const keys_of: diff_widget.Keys = .{ .files = &file_keys, .kinds = diff_kinds, .depth = depth, .file_lines = .left_to_caller };
            var built: diff_widget.Lines = .{};
            try diff_widget.lines(allocator, &files, keys_of, style.diffStyle(), &built);
            for (built.lines.items, built.at.items) |line, at| {
                if (line.kind == diff_kinds.hunk) _ = try list.isFolded(line.key);
                const hunk = if (at.hunk == diff_widget.none) diff_widget.none else first_hunk + at.hunk;
                try list.add(line, .{ .hunk = hunk, .line = at.line });
            }
        },
        .binary => try list.notice(depth, part.depot_path, "Binary file: it differs"),
        .empty => try list.notice(depth, part.depot_path, try emptyText(allocator, if (part.file_type.len != 0) part.file_type else file_type, of)),
        .other => {
            const why = "Not a unified diff: P4DIFF or DIFF (perhaps set in a P4CONFIG file) names another program, whose output is shown as it is";
            try list.notice(depth, part.depot_path, why);
            var text_lines = std.mem.splitScalar(u8, part.body, '\n');
            var index: u32 = 0;
            while (text_lines.next()) |raw| : (index += 1) {
                const trimmed = std.mem.trimEnd(u8, raw, "\r");
                const shown = try ui.displayText(allocator, trimmed);
                var key_bytes: std.Io.Writer.Allocating = .init(allocator);
                try key_bytes.writer.print("{s}\x00{d}", .{ part.depot_path, index });
                const line: outline.Line = .{ .depth = depth, .kind = @intFromEnum(LineKind.text), .key = keyOf(.text, key_bytes.written()), .text = shown, .colour = style.col.text, .font = .code };
                try list.add(line, .{});
            }
        },
    }
}

/// A submitted change's lines: what `describe` said before its files, then each file's line
/// and its part.
fn changeLines(list: *LineList, sources: Sources) !void {
    const allocator = list.allocator;
    const row = sources.row;
    const heading = try std.fmt.allocPrint(allocator, "Change {d}", .{row.number.*});
    try list.add(.{ .depth = 0, .kind = @intFromEnum(LineKind.info), .key = keyOf(.info, "change"), .text = heading, .colour = style.col.accent_bright }, .{});
    const state = std.enums.fromInt(Asked, row.describe_state.*) orelse .none;
    switch (state) {
        .none, .asked => return list.notice(0, "loading", "Loading..."),
        .failed => return list.notice(0, "failed", "Not shown: p4 describe failed ($ shows why); g asks again"),
        .loaded => {},
    }
    const bytes = row.described;
    const first_header = std.mem.indexOf(u8, bytes, "\n==== //") orelse bytes.len;
    var head_lines = std.mem.splitScalar(u8, bytes[0..first_header], '\n');
    var index: u32 = 0;
    while (head_lines.next()) |raw| : (index += 1) {
        const trimmed = std.mem.trimEnd(u8, raw, "\r");
        const shown = try ui.displayText(allocator, trimmed);
        const line: outline.Line = .{ .depth = 0, .kind = @intFromEnum(LineKind.info), .key = keyOf(.info, std.mem.asBytes(&index)), .text = shown, .colour = style.col.text };
        try list.add(line, .{});
    }
    const parsed = try parseAll(allocator, bytes);
    for (parsed.files) |part| {
        const file_key = keyOf(.file, part.depot_path);
        const label = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ try ui.displayText(allocator, part.depot_path), part.revision });
        const file_line: outline.Line = .{ .depth = 0, .kind = @intFromEnum(LineKind.file), .key = file_key, .text = label, .detail = part.file_type, .colour = style.col.text, .expandable = true };
        try list.add(file_line, .{});
        if (try list.isFolded(file_key)) continue;
        try partLines(list, parsed, part, 1, part.file_type, .submitted);
    }
}

/// The file of `table` at `depot_path` in `change`, its text the table's; null for none.
fn fileRowOf(table: *Table, depot_path: []const u8, change: []const u8) ?status.FileRow {
    var rows = table.readQuery(status.FileRow);
    while (rows.next()) |row| {
        if (!std.mem.eql(u8, row.view.depot_path, depot_path) or !std.mem.eql(u8, row.view.change, change)) continue;
        const view = row.view;
        return .{ .action = view.action, .path = view.path, .depot_path = view.depot_path, .local_path = view.local_path, .change = view.change, .file_type = view.file_type, .unresolved = view.unresolved, .opened_for = view.opened_for };
    }
    return null;
}

/// A changelist's diff as its row holds it.
const HeldDiff = struct { state: u8, bytes: []const u8 };

fn diffOf(diffs: *Table, change: []const u8) ?HeldDiff {
    var rows = diffs.readQuery(DiffRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.change, change)) return .{ .state = row.view.state.*, .bytes = row.view.bytes };
    }
    return null;
}

// ---- drawing -------------------------------------------------------------------------------------

/// Draws the panel: its header, its title what it shows, then its lines, scrolled as its
/// kernels left them. Writes no table.
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
            .click_tag = .from(Msg.vcs_p4_diff_click),
            .toggle_tag = .from(Msg.vcs_p4_diff_chevron),
            .scroll_tag = .from(Msg.vcs_p4_diff_wheel),
            .collapsed = built.folded,
            .view_height = viewport.height,
            .line_height = line_height,
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
