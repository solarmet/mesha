//! vcs-p4, the editor's Perforce panel: the workspace's changelists as a document
//! (`editor/assets/documents/vcs-p4.org`, drawn by `editor/src/document/`) over tables and values
//! vcs-p4 publishes, with the keys of mode `vcs_p4`. This file is the panel's system: its tables,
//! how it opens, the refresh and the answers that fill the tables, and what its keys do. Its
//! drawing is `p4_status_view.zig`'s; the command lines and what `p4` says back are `p4.zig`'s,
//! written from Perforce's documentation alone (nothing here has run against a Perforce server);
//! the programs run through `runner.zig`. Its parts: the diff panel (`p4_diff.zig`), the
//! description buffer a changelist is described and submitted in (`p4_change.zig`) and the
//! history page (`p4_history.zig`).
//!
//! - What it publishes (`document/sources.zig`): the sources `vcs-p4.default` (the default
//!   changelist's opened files) and `vcs-p4.opened` (the files of the numbered pending
//!   changelists), a row a file (`FileRow`: the action and the path, shown; the depot and local
//!   paths, the changelist, the type and whether it waits for a resolve, for the commands),
//!   `vcs-p4.changelists` (`ChangeRow`: the number, the description's first line and how many
//!   files are shelved, shown; the whole description), and `vcs-p4.submitted`, the recent ten
//!   submitted changes (`SubmittedRow`); the values `vcs-p4.client`, `vcs-p4.user`,
//!   `vcs-p4.server`, `vcs-p4.note`, `vcs-p4.unlisted`, `vcs-p4.default-count` and
//!   `vcs-p4.pending-count`. The tables are written in order (`table_view.rowsInOrder`), a cell
//!   only when what it holds changed, so a refresh that changes nothing writes no row; both the
//!   changelists and the opened files write the changelist's number as the same text, which the
//!   page's group block matches them by.
//! - A refresh is `info` once a project (the workspace, its root, the user and the server), then
//!   four programs run together: the pending and the shelved changelists (`changes -s pending`,
//!   `changes -s shelved`, joined with `p4.mergeShelved`), every opened file (`fstat -Ro`), and
//!   the recent submitted changes (`changes -s submitted -m 10`); then, only when a changelist
//!   has shelved files, one `describe -S -s` for all of them. The tables are written once every
//!   answer is in, the cursor kept on the same file in the same changelist.
//! - It refreshes as the panel opens, on `g`, and as each of its own commands ends; never as the
//!   panel takes the focus or a buffer is saved, and on a timer only when the setting
//!   `vcs_p4_refresh_seconds` is not 0 (0, none, by default), while the panel shows its
//!   changelists and the engine's window has the focus.
//! - A refresh that fails keeps every row and marks the sources `unread` (drawn in the error
//!   colour), the reason in the note; then `info` and `login -s` say whether the session ended
//!   (`p4.sessionOf`), which puts `Run p4 login in a terminal, then g` in the note and is told
//!   once. No workspace (`p4.Info.hasClient`) and no `p4` are each a note, and nothing else runs.
//! - Each job carries the panel's generation, which `C-g` and a change of project move on: an
//!   answer of an earlier generation, or one whose job the runner no longer holds, is dropped.
//! - The keys act on what the document's cursor is on (`document.at`): a changelist's heading,
//!   the default changelist's heading, or a file's row. A command that changes the workspace runs
//!   alone; each is refused first from the panel's own rows where they say it cannot run.
//!
//! Everything the panel keeps is in its tables (`editor_vcs_p4` and those beside it), which hold
//! no pointer across frames.

const std = @import("std");
const builtin = @import("builtin");
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
const keybinds = mesha.keybinds;
const text_editor = plugin.text_editor_api;
const p4 = @import("p4.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const vcs_timer = @import("timer.zig");
const vcs_ask = @import("ask.zig");
const process_log = @import("process_log.zig");
const p4_diff = @import("p4_diff.zig");
const p4_change = @import("p4_change.zig");
const p4_history = @import("p4_history.zig");
const modes = @import("../modes.zig");
const open = @import("../open.zig");
const transient = @import("../transient.zig");
const action_palette = @import("../action_palette.zig");
const workspaces = @import("../workspaces.zig");
const table_view = @import("../table_view.zig");
const text_panel = @import("../text_panel.zig");
const document = @import("../document/document.zig");
const document_view = @import("../document/view.zig");
const document_sources = @import("../document/sources.zig");

const Log = mesha.log.scope("vcs_p4");

/// The changelists' page, `editor/assets/documents/vcs-p4.org`, compiled in.
pub const status_document = @embedFile("vcs_p4_document");

// ---- the panel -----------------------------------------------------------------------------------

/// The panel's id.
pub const panel_name = "vcs_p4";
/// The panel's id, as an atom.
pub const panel = Atom.from(panel_name);
/// The root of the panel's system: its panels draw again when the system changes a table.
pub const vcs_p4_root = Atom.from("vcs_p4");

/// The panel, a fixed panel the workspaces system declares while it is shown: along the right
/// edge of the window, as vcs-git's.
pub const fixed_panel: plugin.panels.Open = .{ .id = panel, .title = "vcs-p4", .root = vcs_p4_root, .side = .right, .share = 0.45 };

/// The local path syntax of the host, which the `p4` it runs writes and reads.
pub const host_style: p4.PathStyle = if (builtin.os.tag == .windows) .windows else .posix;

// ---- the messages, the actions and their keys ----------------------------------------------------

/// What the panel's system takes: its actions, the runner's answers, what its drawing sends and
/// the menus', prompts' and dialogs' answers.
pub const Msg = enum(u64) {
    /// Shows the panel, or refreshes it while it has the focus.
    vcs_p4_status = Atom.from("vcs_p4_status").value(),
    vcs_p4_next = Atom.from("vcs_p4_next").value(),
    vcs_p4_previous = Atom.from("vcs_p4_previous").value(),
    vcs_p4_next_sibling = Atom.from("vcs_p4_next_sibling").value(),
    vcs_p4_previous_sibling = Atom.from("vcs_p4_previous_sibling").value(),
    vcs_p4_parent = Atom.from("vcs_p4_parent").value(),
    vcs_p4_first = Atom.from("vcs_p4_first").value(),
    vcs_p4_last = Atom.from("vcs_p4_last").value(),
    vcs_p4_page_down = Atom.from("vcs_p4_page_down").value(),
    vcs_p4_page_up = Atom.from("vcs_p4_page_up").value(),
    vcs_p4_toggle = Atom.from("vcs_p4_toggle").value(),
    vcs_p4_toggle_all = Atom.from("vcs_p4_toggle_all").value(),
    vcs_p4_visit = Atom.from("vcs_p4_visit").value(),
    vcs_p4_refresh = Atom.from("vcs_p4_refresh").value(),
    vcs_p4_quit = Atom.from("vcs_p4_quit").value(),
    vcs_p4_process_log = Atom.from("vcs_p4_process_log").value(),
    vcs_p4_give_up = Atom.from("vcs_p4_give_up").value(),
    vcs_p4_menu = Atom.from("vcs_p4_menu").value(),
    /// `s`: submits the changelist under the cursor, its description written first.
    vcs_p4_submit = Atom.from("vcs_p4_submit").value(),
    /// `e`: edits the description of the changelist under the cursor.
    vcs_p4_describe = Atom.from("vcs_p4_describe").value(),
    /// `N`: makes a new changelist.
    vcs_p4_new_change = Atom.from("vcs_p4_new_change").value(),
    /// `m`: moves the file, or every file of the changelist, under the cursor to another.
    vcs_p4_move = Atom.from("vcs_p4_move").value(),
    /// `k`: reverts the file, or every file of the changelist, under the cursor, after asking.
    vcs_p4_revert = Atom.from("vcs_p4_revert").value(),
    /// `K`: reverts the unchanged files of the changelist under the cursor, after asking.
    vcs_p4_revert_unchanged = Atom.from("vcs_p4_revert_unchanged").value(),
    /// `d`: deletes the empty changelist under the cursor.
    vcs_p4_delete_change = Atom.from("vcs_p4_delete_change").value(),
    /// `z`: the shelve menu.
    vcs_p4_shelve_menu = Atom.from("vcs_p4_shelve_menu").value(),
    /// `F`: the sync menu.
    vcs_p4_sync_menu = Atom.from("vcs_p4_sync_menu").value(),
    /// `R`: resolves what merges cleanly.
    vcs_p4_resolve = Atom.from("vcs_p4_resolve").value(),
    /// `r`: reconciles the project's directory, what it would open shown first.
    vcs_p4_reconcile = Atom.from("vcs_p4_reconcile").value(),
    /// `a`: the menu that opens the visited buffer's file.
    vcs_p4_open_menu = Atom.from("vcs_p4_open_menu").value(),
    /// The runner's answer, a `runner.Finished`, its user data a `JobData`.
    vcs_p4_finished = Atom.from("vcs_p4_finished").value(),
    /// A click on a line of the runner's log view, the line's key (`u64`) its user data.
    vcs_p4_click = Atom.from("vcs_p4_click").value(),
    /// A click on a line's chevron in the runner's log view.
    vcs_p4_chevron = Atom.from("vcs_p4_chevron").value(),
    /// The wheel over the runner's log view, an `input.MouseScrollMsg`.
    vcs_p4_wheel = Atom.from("vcs_p4_wheel").value(),
    /// A click on a heading or a line of the changelists' page, a `document.Click`.
    vcs_p4_document_click = Atom.from("vcs_p4_document_click").value(),
    /// A click on a heading's fold mark, a `document.Click`.
    vcs_p4_document_toggle = Atom.from("vcs_p4_document_toggle").value(),
    /// The wheel over the changelists' page, an `input.MouseScrollMsg`.
    vcs_p4_document_wheel = Atom.from("vcs_p4_document_wheel").value(),
    /// The refresh timer's wake, a `mesha.time.WakeMsg`.
    vcs_p4_timer = Atom.from("vcs_p4_timer").value(),
    /// The menu of menus' answer, a `transient.Chosen`.
    vcs_p4_menu_chosen = Atom.from("vcs_p4_menu_chosen").value(),
    /// The shelve menu's answer.
    vcs_p4_shelve_chosen = Atom.from("vcs_p4_shelve_chosen").value(),
    /// The sync menu's answer.
    vcs_p4_sync_chosen = Atom.from("vcs_p4_sync_chosen").value(),
    /// The open menu's answer.
    vcs_p4_open_chosen = Atom.from("vcs_p4_open_chosen").value(),
    /// A dialog's answer, a palette event, its user data a `ConfirmAsked`.
    vcs_p4_confirm = Atom.from("vcs_p4_confirm").value(),
    /// The prompt of the changelists `m` moves to, a palette event.
    vcs_p4_move_chosen = Atom.from("vcs_p4_move_chosen").value(),
    _,
};

/// The panel's action of `global`, offered from anywhere.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "vcs_p4_status", .tag = @tagName(Msg.vcs_p4_status), .doc = "Show the pending changelists of the Perforce workspace" },
};

/// The keys of `actions`, of `global`: `C-x v p`, beside Emacs's version-control prefix.
pub const global_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-x v p", .action = .{ "global", "vcs_p4_status" } },
};

/// The actions of mode `vcs_p4`: moving and folding as mode `vcs`'s, whose keys they shadow so
/// that they come to this system and not vcs-git's, and Perforce's own commands.
pub const vcs_p4_actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = @tagName(Msg.vcs_p4_next), .doc = "Move to the next line or row" },
    .{ .name = "previous", .tag = @tagName(Msg.vcs_p4_previous), .doc = "Move to the line or row before" },
    .{ .name = "next_sibling", .tag = @tagName(Msg.vcs_p4_next_sibling), .doc = "Move to the next heading" },
    .{ .name = "previous_sibling", .tag = @tagName(Msg.vcs_p4_previous_sibling), .doc = "Move to the heading before" },
    .{ .name = "parent", .tag = @tagName(Msg.vcs_p4_parent), .doc = "Move to the heading this line or row is under" },
    .{ .name = "first", .tag = @tagName(Msg.vcs_p4_first), .doc = "Move to the first line" },
    .{ .name = "last", .tag = @tagName(Msg.vcs_p4_last), .doc = "Move to the last line" },
    .{ .name = "page_down", .tag = @tagName(Msg.vcs_p4_page_down), .doc = "Move a page down" },
    .{ .name = "page_up", .tag = @tagName(Msg.vcs_p4_page_up), .doc = "Move a page up" },
    .{ .name = "toggle", .tag = @tagName(Msg.vcs_p4_toggle), .doc = "Fold or open the changelist or heading the cursor is under" },
    .{ .name = "toggle_all", .tag = @tagName(Msg.vcs_p4_toggle_all), .doc = "Fold every heading, or open them all" },
    .{ .name = "visit", .tag = @tagName(Msg.vcs_p4_visit), .doc = "Show the diff of the file, or the submitted change, at the cursor" },
    .{ .name = "refresh", .tag = @tagName(Msg.vcs_p4_refresh), .doc = "Ask p4 again" },
    .{ .name = "quit", .tag = @tagName(Msg.vcs_p4_quit), .doc = "Leave this view for the one before, or close the panel" },
    .{ .name = "process_log", .tag = @tagName(Msg.vcs_p4_process_log), .doc = "Show the commands run and what they said" },
    .{ .name = "give_up", .tag = @tagName(Msg.vcs_p4_give_up), .doc = "Give up the commands that run" },
    .{ .name = "menu", .tag = @tagName(Msg.vcs_p4_menu), .doc = "Show the menu of what the panel does" },
    .{ .name = "submit", .tag = @tagName(Msg.vcs_p4_submit), .doc = "Submit the changelist at the cursor, its description written first" },
    .{ .name = "describe", .tag = @tagName(Msg.vcs_p4_describe), .doc = "Edit the description of the changelist at the cursor" },
    .{ .name = "new_change", .tag = @tagName(Msg.vcs_p4_new_change), .doc = "Make a new changelist" },
    .{ .name = "move", .tag = @tagName(Msg.vcs_p4_move), .doc = "Move the file, or every file of the changelist, at the cursor to another changelist" },
    .{ .name = "revert", .tag = @tagName(Msg.vcs_p4_revert), .doc = "Revert the file, or every file of the changelist, at the cursor, after asking" },
    .{ .name = "revert_unchanged", .tag = @tagName(Msg.vcs_p4_revert_unchanged), .doc = "Revert the unchanged files of the changelist at the cursor, after asking" },
    .{ .name = "delete_change", .tag = @tagName(Msg.vcs_p4_delete_change), .doc = "Delete the empty changelist at the cursor" },
    .{ .name = "shelve", .tag = @tagName(Msg.vcs_p4_shelve_menu), .doc = "Show the menu of the changelist's shelf" },
    .{ .name = "sync", .tag = @tagName(Msg.vcs_p4_sync_menu), .doc = "Show the sync menu" },
    .{ .name = "resolve", .tag = @tagName(Msg.vcs_p4_resolve), .doc = "Resolve the files that merge without a conflict" },
    .{ .name = "reconcile", .tag = @tagName(Msg.vcs_p4_reconcile), .doc = "Show what changed without being opened, then offer to open it" },
    .{ .name = "open_file", .tag = @tagName(Msg.vcs_p4_open_menu), .doc = "Open the visited buffer's file for edit, add or delete" },
    p4_history.history_action,
};

/// The keys of mode `vcs_p4`: vcs-git's keys for the same ideas (`n` `p` `M-n` `M-p` `^` `tab`
/// `RET` `g` `q` `$` `C-g` `?`, `k` throwing away, `F` pulling in, `l` the history), and
/// Perforce's commands. `S-n` is `N`, `S-k` `K`, `S-f` `F`, `S-r` `R`.
pub const vcs_p4_keys = [_]keybinds.KeyDef{
    .{ .chord = "n", .action = .{ "vcs_p4", "next" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "vcs_p4", "next" }, .trigger = .repeat },
    .{ .chord = "p", .action = .{ "vcs_p4", "previous" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "vcs_p4", "previous" }, .trigger = .repeat },
    .{ .chord = "M-n", .action = .{ "vcs_p4", "next_sibling" }, .trigger = .repeat },
    .{ .chord = "M-p", .action = .{ "vcs_p4", "previous_sibling" }, .trigger = .repeat },
    .{ .chord = "S-6", .action = .{ "vcs_p4", "parent" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "vcs_p4", "first" } },
    .{ .chord = "M-S-period", .action = .{ "vcs_p4", "last" } },
    .{ .chord = "C-v", .action = .{ "vcs_p4", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "vcs_p4", "page_up" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "vcs_p4", "toggle" } },
    .{ .chord = "S-tab", .action = .{ "vcs_p4", "toggle_all" } },
    .{ .chord = "RET", .action = .{ "vcs_p4", "visit" } },
    .{ .chord = "g", .action = .{ "vcs_p4", "refresh" } },
    .{ .chord = "q", .action = .{ "vcs_p4", "quit" } },
    .{ .chord = "S-4", .action = .{ "vcs_p4", "process_log" } },
    .{ .chord = "C-g", .action = .{ "vcs_p4", "give_up" } },
    .{ .chord = "S-slash", .action = .{ "vcs_p4", "menu" } },
    .{ .chord = "s", .action = .{ "vcs_p4", "submit" } },
    .{ .chord = "e", .action = .{ "vcs_p4", "describe" } },
    .{ .chord = "S-n", .action = .{ "vcs_p4", "new_change" } },
    .{ .chord = "m", .action = .{ "vcs_p4", "move" } },
    .{ .chord = "k", .action = .{ "vcs_p4", "revert" } },
    .{ .chord = "S-k", .action = .{ "vcs_p4", "revert_unchanged" } },
    .{ .chord = "d", .action = .{ "vcs_p4", "delete_change" } },
    .{ .chord = "z", .action = .{ "vcs_p4", "shelve" } },
    .{ .chord = "S-f", .action = .{ "vcs_p4", "sync" } },
    .{ .chord = "S-r", .action = .{ "vcs_p4", "resolve" } },
    .{ .chord = "r", .action = .{ "vcs_p4", "reconcile" } },
    .{ .chord = "a", .action = .{ "vcs_p4", "open_file" } },
    .{ .chord = "l", .action = .{ "vcs_p4", "history" } },
};

/// Offers the actions of modes `vcs_p4`, `vcs_p4_history`, `vcs_p4_diff` and `vcs_p4_message`,
/// this system taking them, every frame: the modes decide when they are live.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const inbox = sequencer.inboxOf(system());
    for (vcs_p4_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_p4, inbox, &.{.{ .def = def }});
    p4_history.pushActions(atoms, sink, inbox);
    p4_diff.pushActions(atoms, sink, inbox);
    p4_change.pushActions(atoms, sink, inbox);
}

// ---- the menus -----------------------------------------------------------------------------------

/// What the menu of menus (`?`) offers, by its items' ids.
pub const MenuCommand = enum(u32) {
    refresh = 1,
    process_log,
    quit,
    submit,
    describe,
    new_change,
    move,
    revert,
    revert_unchanged,
    delete_change,
    shelve,
    sync,
    open_file,
    resolve,
    reconcile,
    history,
};

/// The menu of menus, `?`: what the panel does, by the keys that do it.
pub const menu: ui.transient.Menu = .{
    .title = "vcs-p4",
    .groups = &.{
        .{ .title = "Changelists", .items = &.{
            ui.transient.Item.command("g", "Refresh", @intFromEnum(MenuCommand.refresh)),
            ui.transient.Item.command("$", "Process log", @intFromEnum(MenuCommand.process_log)),
            ui.transient.Item.command("q", "Back or close", @intFromEnum(MenuCommand.quit)),
        } },
        .{ .title = "Change", .items = &.{
            ui.transient.Item.command("s", "Submit", @intFromEnum(MenuCommand.submit)),
            ui.transient.Item.command("e", "Edit description", @intFromEnum(MenuCommand.describe)),
            ui.transient.Item.command("N", "New changelist", @intFromEnum(MenuCommand.new_change)),
            ui.transient.Item.command("m", "Move to a changelist", @intFromEnum(MenuCommand.move)),
            ui.transient.Item.command("k", "Revert", @intFromEnum(MenuCommand.revert)),
            ui.transient.Item.command("K", "Revert unchanged", @intFromEnum(MenuCommand.revert_unchanged)),
            ui.transient.Item.command("d", "Delete empty changelist", @intFromEnum(MenuCommand.delete_change)),
        } },
        .{ .title = "Menus", .items = &.{
            ui.transient.Item.menu("z", "Shelve", @intFromEnum(MenuCommand.shelve)),
            ui.transient.Item.menu("F", "Sync", @intFromEnum(MenuCommand.sync)),
            ui.transient.Item.menu("a", "Open a file", @intFromEnum(MenuCommand.open_file)),
        } },
        .{ .title = "Workspace", .items = &.{
            ui.transient.Item.command("R", "Resolve", @intFromEnum(MenuCommand.resolve)),
            ui.transient.Item.command("r", "Reconcile", @intFromEnum(MenuCommand.reconcile)),
            ui.transient.Item.command("l", "History", @intFromEnum(MenuCommand.history)),
        } },
    },
};

/// The shelve menu's items.
pub const ShelveItem = enum(u32) { shelve = 1, replace, unshelve, discard };

/// The shelve menu (`z`): of the numbered changelist under the cursor.
pub const shelve_menu: ui.transient.Menu = .{
    .title = "Shelve",
    .groups = &.{
        .{ .title = "Shelf", .items = &.{
            ui.transient.Item.command("z", "Shelve the open files", @intFromEnum(ShelveItem.shelve)),
            ui.transient.Item.command("r", "Replace the shelf with them (-r)", @intFromEnum(ShelveItem.replace)),
            ui.transient.Item.command("u", "Unshelve into the changelist", @intFromEnum(ShelveItem.unshelve)),
            ui.transient.Item.command("d", "Delete the shelf", @intFromEnum(ShelveItem.discard)),
        } },
    },
};

/// The sync menu's items.
pub const SyncItem = enum(u32) { sync = 1, preview };

/// The sync menu (`F`): the whole workspace to the head revision.
pub const sync_menu: ui.transient.Menu = .{
    .title = "Sync",
    .groups = &.{
        .{ .title = "Sync", .items = &.{
            ui.transient.Item.command("f", "Sync the workspace", @intFromEnum(SyncItem.sync)),
            ui.transient.Item.command("n", "Preview (-n): $ shows what it would do", @intFromEnum(SyncItem.preview)),
        } },
    },
};

/// The open menu's items.
pub const OpenItem = enum(u32) { edit = 1, add, delete };

/// The open menu (`a`): the visited buffer's file, into the changelist under the cursor.
pub const open_menu: ui.transient.Menu = .{
    .title = "Open the visited file",
    .groups = &.{
        .{ .title = "Open for", .items = &.{
            ui.transient.Item.command("e", "Edit", @intFromEnum(OpenItem.edit)),
            ui.transient.Item.command("a", "Add", @intFromEnum(OpenItem.add)),
            ui.transient.Item.command("d", "Delete (asks first)", @intFromEnum(OpenItem.delete)),
        } },
    },
};

// ---- the tables ----------------------------------------------------------------------------------

/// `editor_vcs_p4`: the panel's own row, one (`StateRow`).
pub const state_table_name = "editor_vcs_p4";
/// `editor_vcs_p4_default`: the default changelist's opened files (`FileRow`), the source
/// `vcs-p4.default`.
pub const default_table_name = "editor_vcs_p4_default";
/// `editor_vcs_p4_opened`: the files of the numbered pending changelists (`FileRow`), the source
/// `vcs-p4.opened`.
pub const opened_table_name = "editor_vcs_p4_opened";
/// `editor_vcs_p4_changelists`: the numbered pending changelists (`ChangeRow`), the source
/// `vcs-p4.changelists`.
pub const changelists_table_name = "editor_vcs_p4_changelists";
/// `editor_vcs_p4_submitted`: the recent submitted changes (`SubmittedRow`), the source
/// `vcs-p4.submitted`.
pub const submitted_table_name = "editor_vcs_p4_submitted";
/// `editor_vcs_p4_folds`: the changelists page's folds (`document.FoldRow`).
pub const folds_table_name = "editor_vcs_p4_folds";
/// `editor_vcs_p4_expanded`: the jobs of the runner's log view opened (`process_log.FoldRow`).
pub const expanded_table_name = "editor_vcs_p4_expanded";
/// `editor_vcs_p4_pending`: what a prompt or a dialog asks about, kept as it is asked
/// (`PendingRow`).
pub const pending_table_name = "editor_vcs_p4_pending";
/// The panels' modes, a `modes.PanelModesRow`.
pub const panel_modes_table_name = "editor_vcs_p4_panel_modes";

/// The most opened files the panel keeps across its two file tables: those past it are not
/// listed, and the page says how many.
pub const max_files = 4096;
/// The most pending changelists the panel keeps.
pub const max_changelists = 1024;
/// How many submitted changes the page lists.
pub const recent_count = 10;
/// The most headings the panel keeps folded.
pub const max_folds = 1024;
/// The most jobs the panel keeps opened in the runner's log view.
pub const max_expanded = 1024;

/// Which view the panel shows.
pub const View = enum(u8) {
    /// The workspace's changelists.
    status,
    /// The runner's log of the panel's jobs (`$`).
    process_log,
    /// The history's query and the changes it listed, a page (`p4_history.zig`).
    history,
};

/// A view's selection of `View` from its byte, the changelists for a byte that names none.
pub fn viewOf(byte: u8) View {
    return std.enums.fromInt(View, byte) orelse .status;
}

/// Where a refresh is.
pub const Phase = enum(u8) {
    /// None runs.
    idle,
    /// `info` runs: which workspace, which root.
    info,
    /// The four lists run together.
    lists,
    /// `describe -S -s` of the changelists with shelved files runs.
    shelved,
    /// After a failure, `info` and `login -s` run together: did the session end?
    session,
};

/// What the panel says in place of its changelists, in its note.
pub const Notice = enum(u8) {
    /// Nothing: it shows the changelists.
    none,
    /// `p4` could not be started: it is not on `PATH`.
    no_program,
    /// `info` names no workspace with a root.
    no_workspace,
    /// `info` failed: no server answered.
    no_server,
    /// `info` named a workspace whose name vcs-p4 does not pass (`p4.isClientName`).
    bad_client,
};

/// What a job of the panel's was for.
pub const Purpose = enum(u8) {
    info,
    pending,
    shelved_changes,
    opened,
    submitted,
    describe_shelved,
    session_info,
    login_status,
    /// A command of the panel's own (`CommandName` says which): the end of the last one queued
    /// refreshes.
    command,
    /// A changelist's `diff -du` (`p4_diff.zig`).
    diff,
    /// A submitted change's `describe -du` (`p4_diff.zig`).
    describe,
    /// The history's `changes` (`p4_history.zig`).
    history,

    /// The bit of `StateRow.refresh_failed` that stands for a refresh's job.
    fn bit(purpose: Purpose) u16 {
        return @as(u16, 1) << @intCast(@intFromEnum(purpose));
    }

    /// The command a person knows the job by, as a failure names it.
    pub fn subcommand(purpose: Purpose) []const u8 {
        return switch (purpose) {
            .info, .session_info => "info",
            .pending, .shelved_changes, .submitted, .history => "changes",
            .opened => "fstat",
            .describe_shelved, .describe => "describe",
            .login_status => "login -s",
            .command => "command",
            .diff => "diff",
        };
    }
};

/// Which command of the panel's a job of `Purpose.command` runs.
pub const CommandName = enum(u8) {
    none,
    change_form,
    save_change,
    submit,
    delete_change,
    reopen,
    revert,
    revert_unchanged,
    shelve,
    unshelve,
    sync,
    sync_preview,
    resolve,
    open_file,
    reconcile_preview,
    reconcile,

    /// The command that runs `command`.
    pub fn of(command: p4.Command) CommandName {
        return switch (command) {
            .change_form => .change_form,
            .save_change => .save_change,
            .submit => .submit,
            .delete_change => .delete_change,
            .reopen => .reopen,
            .revert => .revert,
            .revert_unchanged => .revert_unchanged,
            .shelve => .shelve,
            .unshelve => .unshelve,
            .sync => |mode| switch (mode) {
                .sync => .sync,
                .preview => .sync_preview,
            },
            .resolve => .resolve,
            .open => .open_file,
            .reconcile => |reconcile| switch (reconcile.mode) {
                .preview => .reconcile_preview,
                .open => .reconcile,
            },
            else => .none,
        };
    }

    /// The command a person knows it by, as a failure names it.
    pub fn subcommand(name: CommandName) []const u8 {
        return switch (name) {
            .none => "command",
            .change_form => "change -o",
            .save_change => "change -i",
            .submit => "submit",
            .delete_change => "change -d",
            .reopen => "reopen",
            .revert, .revert_unchanged => "revert",
            .shelve => "shelve",
            .unshelve => "unshelve",
            .sync, .sync_preview => "sync",
            .resolve => "resolve",
            .open_file => "edit, add or delete",
            .reconcile_preview, .reconcile => "reconcile",
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
    /// For a diff's, a describe's or the history's job, the count of its kind asked as it was:
    /// an answer of an earlier one is dropped.
    epoch: u32 = 0,
};

/// The row of `editor_vcs_p4`. Text a person reads is in its text cells.
pub const StateRow = struct {
    /// The working directory the data is for, absolute; empty before the first refresh.
    working_directory: *Table.String,
    /// The person's home directory as the last refresh found it.
    home_directory: *Table.String,
    /// A `View`.
    view: *u8,
    /// The runner's log view's `outline.Cursor`, and the view it goes back to.
    process_log_key: *u64,
    process_log_index: *u32,
    process_log_scroll: *f32,
    process_log_return: *u8,
    /// The height of the runner's log view the last run settled its scroll for, in pixels.
    view_height: *f32,
    /// Counts the give-ups and the changes of project: an answer of an earlier one is dropped.
    generation: *u32,
    /// A `Phase`.
    phase: *u8,
    /// The jobs of the refresh's phase not answered yet.
    refresh_jobs: *u8,
    /// 1 when a refresh was asked for while one ran: another runs when it ends.
    refresh_again: *u8,
    /// The `Purpose`s of the refresh's jobs that failed, a bit each.
    refresh_failed: *u16,
    /// Of those, the ones whose program could not be started.
    refresh_unstarted: *u16,
    /// Of those, the ones never queued: `p4` cannot be given their command line (`p4.passes`).
    refresh_unpassable: *u16,
    /// 1 once `info` named a workspace for the working directory.
    info_known: *u8,
    /// A `Notice`.
    notice: *u8,
    /// `info`'s workspace, its root (`/`-separated), its user and its server.
    client: *Table.String,
    client_root: *Table.String,
    user: *Table.String,
    server: *Table.String,
    /// What the page's note says: why a refresh failed, a session that ended, `Loading...`.
    note: *Table.String,
    /// 1 once a session that ended was told, until a refresh reads the lists again.
    session_told: *u8,
    /// The exit codes of the session check's `info` and `login -s`, as they answer.
    session_info_code: *i32,
    session_login_code: *i32,
    /// 1 once the lists were read for the working directory.
    answered: *u8,
    /// What the refresh's four lists and the shelved files said, kept until all are in.
    pending_said: *Table.Bytes,
    shelved_said: *Table.Bytes,
    opened_said: *Table.Bytes,
    submitted_said: *Table.Bytes,
    /// How many files `fstat` listed in the default changelist, kept or not, and in all.
    default_count: *u32,
    opened_seen: *u32,
    /// How many pending changelists there are, listed or not.
    pending_count: *u32,
    /// The records of the last refresh's output that could not be read.
    unread_records: *u32,
    /// The runner's `phase`, copied each frame a job runs: the spinner the header draws.
    spinner: *u32,
    /// The panel's commands queued or running, not answered yet: the panel refreshes as the
    /// last ends.
    commands_running: *u8,
    /// 1 when a resolve ended: the refresh after it tells how many files still wait.
    tell_unresolved: *u8,
    /// 1 when a sync preview ended: the runner's log view shows what it said.
    show_log: *u8,
    /// 1 from a refresh that could not read the lists (their sources `unread`) until one reads
    /// them: the commands acting on rows are refused, as the rows may be stale.
    lists_unread: *u8,
    /// 1 when this refresh's `fstat` ended non-zero having printed no record
    /// (`listsAnswered`'s defensive reading).
    opened_empty: *u8,
    /// The page's `page.MovedUnder`.
    cursor_moved_under: *u8,
    /// 1 while a wake of the time system's is asked for the timer's next refresh.
    timer_armed: *u8,
    /// The interval in seconds the pending wake was asked for.
    timer_seconds: *u32,
    /// The instant on the awake clock the pending wake was asked at, in nanoseconds.
    timer_asked_at: *i64,
};

/// `StateRow` read, its text as slices of the table's.
pub const StateRead = struct {
    working_directory: []const u8,
    home_directory: []const u8,
    view: *u8,
    process_log_key: *u64,
    process_log_index: *u32,
    process_log_scroll: *f32,
    notice: *u8,
    client: []const u8,
    client_root: []const u8,
    user: []const u8,
    server: []const u8,
    note: []const u8,
    answered: *u8,
    pending_said: []const u8,
    shelved_said: []const u8,
    opened_said: []const u8,
    submitted_said: []const u8,
    default_count: *u32,
    opened_seen: *u32,
    pending_count: *u32,
    unread_records: *u32,
    spinner: *u32,

    /// The runner's log view's cursor.
    pub fn cursor(state: StateRead) mesha.ui.outline.Cursor {
        return .{ .key = state.process_log_key.*, .index = state.process_log_index.*, .scroll = state.process_log_scroll.* };
    }
};

/// A row of `editor_vcs_p4_default` or `editor_vcs_p4_opened`: a file opened in the workspace.
pub const FileRow = struct {
    /// What it is opened for (`edit`, `add`, `move/add`), `(unresolved)` after it while it waits
    /// for a resolve: shown.
    action: []const u8,
    /// Its local path from the workspace's root when it is under it, else its depot path: shown.
    path: []const u8,
    /// Its depot path, encoded as `p4` printed it, which the commands give back.
    depot_path: []const u8,
    /// Its local path, `/`-separated, as `p4` printed it.
    local_path: []const u8,
    /// Its changelist: `default`, or the number as text, as the changelists' rows write it.
    change: []const u8,
    /// Its type (`text`, `binary+l`).
    file_type: []const u8,
    /// `1` while it waits for a resolve, else empty.
    unresolved: []const u8,
    /// What it is opened for, as `p4` named it.
    opened_for: []const u8,
};

const file_fields = [_][]const u8{ "action", "path", "depot_path", "local_path", "change", "file_type", "unresolved", "opened_for" };
const file_shown = [_][]const u8{ "action", "path" };

/// A row of `editor_vcs_p4_changelists`: a numbered pending changelist.
pub const ChangeRow = struct {
    /// Its number as text, as the files' rows write it: shown.
    change: []const u8,
    /// Its description's first line: shown.
    description: []const u8,
    /// `2 shelved` when it has shelved files (`shelved` when how many is not known), else
    /// empty: shown.
    shelved: []const u8,
    /// Its whole description.
    full_description: []const u8,
    /// Its owner.
    user: []const u8,
};

const change_fields = [_][]const u8{ "change", "description", "shelved", "full_description", "user" };
const change_shown = [_][]const u8{ "change", "description", "shelved" };

/// A row of `editor_vcs_p4_submitted`: a submitted change.
pub const SubmittedRow = struct {
    /// Its number: shown.
    change: []const u8,
    /// Its owner: shown.
    user: []const u8,
    /// When it was submitted, `YYYY-MM-DD` in UTC: shown.
    date: []const u8,
    /// Its description's first line: shown.
    description: []const u8,
};

const submitted_fields = [_][]const u8{ "change", "user", "date", "description" };

/// A source the page shows, its table and its fields.
const SourceKind = enum {
    default,
    opened,
    changelists,
    submitted,

    fn name(kind: SourceKind) []const u8 {
        return switch (kind) {
            .default => "vcs-p4.default",
            .opened => "vcs-p4.opened",
            .changelists => "vcs-p4.changelists",
            .submitted => "vcs-p4.submitted",
        };
    }

    fn table(kind: SourceKind) Atom {
        return switch (kind) {
            .default => default_table,
            .opened => opened_table,
            .changelists => changelists_table,
            .submitted => submitted_table,
        };
    }

    fn shown(kind: SourceKind) []const []const u8 {
        return switch (kind) {
            .default, .opened => &file_shown,
            .changelists => &change_shown,
            .submitted => &submitted_fields,
        };
    }
};

const state_table = Atom.from(state_table_name);
const default_table = Atom.from(default_table_name);
const opened_table = Atom.from(opened_table_name);
const changelists_table = Atom.from(changelists_table_name);
const submitted_table = Atom.from(submitted_table_name);
const folds_table = Atom.from(folds_table_name);
const expanded_table = Atom.from(expanded_table_name);
const pending_table = Atom.from(pending_table_name);
const places_table = Atom.from(mesha.os.places_table_name);
const runner_requests_table = Atom.from(runner.requests_table_name);
const runner_log_table = Atom.from(runner.log_table_name);
const text_editor_requests = Atom.from(text_editor.commands_table_name);
const transient_requests = Atom.from(transient.requests_table_name);
const palette_requests = Atom.from(action_palette.requests_table_name);
const shown_panels_table = Atom.from(workspaces.shown_panels_table_name);
const workspace_table = Atom.from(workspaces.workspace_table_name);
const panel_requests_table = Atom.from(plugin.panels.commands_table_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const focus_history_table = Atom.from(panels_mod.focus_history_table_name);
const font_metrics_table = Atom.from(resources.font_metrics_table_name);
const document_sources_table = Atom.from(document_sources.sources_table_name);
const document_values_table = Atom.from(document_sources.values_table_name);
const settings_table = Atom.from(keybinds.editor_settings_name);
const time_commands = Atom.from(mesha.time.commands_table_name);
const text_windows_table = Atom.from(text_panel.table_name);
const buffers_table = Atom.from(text_editor.buffers_table_name);
/// The owner the panel's prompts and dialogs are presented as.
const prompt_owner_name = "vcs_p4_prompt";
const prompt_owner = Atom.from(prompt_owner_name);

/// What publishes the page's sources and values: the system, by its root's name.
pub const publisher = vcs_p4_root;

/// The changelists' page: `vcs-p4.org`, its state in the panel's row, its folds in
/// `editor_vcs_p4_folds`.
pub const status_page: vcs_page.Page = .{
    .document = vcs_page.parsePage(status_document, "vcs-p4.org"),
    .name = "vcs_p4_document",
    .state_table = state_table,
    .folds_table = folds_table,
    .tags = .{
        .click = Atom.from(Msg.vcs_p4_document_click),
        .toggle = Atom.from(Msg.vcs_p4_document_toggle),
        .wheel = Atom.from(Msg.vcs_p4_document_wheel),
    },
    .resize_reader_name = "vcs_p4_document_resizes",
    .moved_under_sentence = "The changelists changed under the cursor",
};

/// vcs-p4's pages: the changelists' and the history's.
const pages = [_]vcs_page.Page{ status_page, p4_history.page };

/// Makes the panel's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ state_table_name, default_table_name, opened_table_name, changelists_table_name, submitted_table_name, folds_table_name, expanded_table_name, pending_table_name, panel_name, prompt_owner_name });

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 51 + std.meta.fields(document.StateRow).len);
    defer state.deinit();
    try state.addFieldFallible("working_directory", Table.String, .text_field);
    try state.addFieldFallible("home_directory", Table.String, .text_field);
    try state.addFieldFallible("view", u8, .int);
    try state.addFieldFallible("process_log_key", u64, .int);
    try state.addFieldFallible("process_log_index", u32, .int);
    try state.addFieldFallible("process_log_scroll", f32, .int);
    try state.addFieldFallible("process_log_return", u8, .int);
    try state.addFieldFallible("view_height", f32, .int);
    try state.addFieldFallible("generation", u32, .int);
    try state.addFieldFallible("phase", u8, .int);
    try state.addFieldFallible("refresh_jobs", u8, .int);
    try state.addFieldFallible("refresh_again", u8, .int);
    try state.addFieldFallible("refresh_failed", u16, .int);
    try state.addFieldFallible("refresh_unstarted", u16, .int);
    try state.addFieldFallible("refresh_unpassable", u16, .int);
    try state.addFieldFallible("info_known", u8, .int);
    try state.addFieldFallible("notice", u8, .int);
    try state.addFieldFallible("client", Table.String, .text_field);
    try state.addFieldFallible("client_root", Table.String, .text_field);
    try state.addFieldFallible("user", Table.String, .text_field);
    try state.addFieldFallible("server", Table.String, .text_field);
    try state.addFieldFallible("note", Table.String, .text_field);
    try state.addFieldFallible("session_told", u8, .int);
    try state.addFieldFallible("session_info_code", i32, .int);
    try state.addFieldFallible("session_login_code", i32, .int);
    try state.addFieldFallible("answered", u8, .int);
    try state.addFieldFallible("pending_said", Table.Bytes, .bytes);
    try state.addFieldFallible("shelved_said", Table.Bytes, .bytes);
    try state.addFieldFallible("opened_said", Table.Bytes, .bytes);
    try state.addFieldFallible("submitted_said", Table.Bytes, .bytes);
    try state.addFieldFallible("default_count", u32, .int);
    try state.addFieldFallible("opened_seen", u32, .int);
    try state.addFieldFallible("pending_count", u32, .int);
    try state.addFieldFallible("unread_records", u32, .int);
    try state.addFieldFallible("spinner", u32, .int);
    try state.addFieldFallible("commands_running", u8, .int);
    try state.addFieldFallible("tell_unresolved", u8, .int);
    try state.addFieldFallible("show_log", u8, .int);
    try state.addFieldFallible("lists_unread", u8, .int);
    try state.addFieldFallible("opened_empty", u8, .int);
    try state.addFieldFallible("cursor_moved_under", u8, .int);
    try state.addFieldFallible("timer_armed", u8, .int);
    try state.addFieldFallible("timer_seconds", u32, .int);
    try state.addFieldFallible("timer_asked_at", i64, .int);
    try document.addStateFields(&state);
    const defaults = .{
        .working_directory = Table.String{},
        .home_directory = Table.String{},
        .view = @as(u8, @intFromEnum(View.status)),
        .process_log_key = @as(u64, 0),
        .process_log_index = @as(u32, 0),
        .process_log_scroll = @as(f32, 0),
        .process_log_return = @as(u8, @intFromEnum(View.status)),
        .view_height = @as(f32, 0),
        .generation = @as(u32, 0),
        .phase = @as(u8, @intFromEnum(Phase.idle)),
        .refresh_jobs = @as(u8, 0),
        .refresh_again = @as(u8, 0),
        .refresh_failed = @as(u16, 0),
        .refresh_unstarted = @as(u16, 0),
        .refresh_unpassable = @as(u16, 0),
        .info_known = @as(u8, 0),
        .notice = @as(u8, @intFromEnum(Notice.none)),
        .client = Table.String{},
        .client_root = Table.String{},
        .user = Table.String{},
        .server = Table.String{},
        .note = Table.String{},
        .session_told = @as(u8, 0),
        .session_info_code = @as(i32, 0),
        .session_login_code = @as(i32, 0),
        .answered = @as(u8, 0),
        .pending_said = Table.Bytes{},
        .shelved_said = Table.Bytes{},
        .opened_said = Table.Bytes{},
        .submitted_said = Table.Bytes{},
        .default_count = @as(u32, 0),
        .opened_seen = @as(u32, 0),
        .pending_count = @as(u32, 0),
        .unread_records = @as(u32, 0),
        .spinner = @as(u32, 0),
        .commands_running = @as(u8, 0),
        .tell_unresolved = @as(u8, 0),
        .show_log = @as(u8, 0),
        .lists_unread = @as(u8, 0),
        .opened_empty = @as(u8, 0),
        .cursor_moved_under = @as(u8, 0),
        .timer_armed = @as(u8, 0),
        .timer_seconds = @as(u32, 0),
        .timer_asked_at = @as(i64, 0),
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

    const text_tables = [_]struct { name: Atom, fields: []const []const u8, capacity: u32 }{
        .{ .name = default_table, .fields = &file_fields, .capacity = max_files },
        .{ .name = opened_table, .fields = &file_fields, .capacity = max_files },
        .{ .name = changelists_table, .fields = &change_fields, .capacity = max_changelists },
        .{ .name = submitted_table, .fields = &submitted_fields, .capacity = recent_count },
    };
    for (text_tables) |text_table| {
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, atoms, @intCast(text_table.fields.len));
        defer schema.deinit();
        for (text_table.fields) |field| try schema.addFieldFallible(field, Table.String, .text_field);
        _ = try tables.ensure(&schema, text_table.capacity, text_table.name, .durable);
    }

    const fold_tables = [_]struct { name: Atom, capacity: u32 }{
        .{ .name = folds_table, .capacity = max_folds },
        .{ .name = expanded_table, .capacity = max_expanded },
    };
    for (fold_tables) |fold_table| {
        var folds: Table.Schema = undefined;
        try folds.init(scratch.allocator, atoms, 1);
        defer folds.deinit();
        try document.addFoldFields(&folds);
        _ = try tables.ensure(&folds, fold_table.capacity, fold_table.name, .durable);
    }

    var pending: Table.Schema = undefined;
    try pending.init(scratch.allocator, atoms, 10);
    defer pending.deinit();
    try pending.addFieldFallible("confirm", u8, .int);
    try pending.addFieldFallible("confirm_serial", u32, .int);
    try pending.addFieldFallible("subject_change", Table.String, .text_field);
    try pending.addFieldFallible("subject_paths", Table.Bytes, .bytes);
    try pending.addFieldFallible("moving", u8, .int);
    try pending.addFieldFallible("move_paths", Table.Bytes, .bytes);
    try pending.addFieldFallible("move_from", Table.String, .text_field);
    try pending.addFieldFallible("shelf_change", Table.String, .text_field);
    try pending.addFieldFallible("move_title", Table.String, .text_field);
    try pending.addFieldFallible("reconcile_change", Table.String, .text_field);
    const pending_defaults = .{
        .confirm = @as(u8, @intFromEnum(Confirm.none)),
        .confirm_serial = @as(u32, 0),
        .subject_change = Table.String{},
        .subject_paths = Table.Bytes{},
        .moving = @as(u8, 0),
        .move_paths = Table.Bytes{},
        .move_from = Table.String{},
        .shelf_change = Table.String{},
        .move_title = Table.String{},
        .reconcile_change = Table.String{},
    };
    _ = try tables.ensureSingleton(&pending, pending_table, pending_defaults, .durable);

    try document_sources.ensure(scratch, atoms, tables);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
    try p4_diff.ensure(scratch, atoms, tables);
    try p4_change.ensure(scratch, atoms, tables);
    try p4_history.ensure(scratch, atoms, tables);
}

// ---- the system ----------------------------------------------------------------------------------

/// The panel's system, and its diff panel's (`p4_diff.zig`): its kernels take the panels'
/// messages, refresh as the project changes and on the timer the setting asks for, keep each
/// view fit to its panel, turn the spinner while a job runs, and ask for the panels' modes. It
/// publishes the page's sources and values. After the runner in the editor's frame, so the jobs it
/// queues are taken in the next frame's run of the runner.
pub fn system() sequencer.System {
    return .{
        .name = "vcs_p4",
        .names = comptime &(sequencer.enumNames(Msg) ++ sequencer.enumNames(p4_diff.Msg) ++ sequencer.enumNames(p4_change.Msg) ++ sequencer.enumNames(p4_history.Msg) ++
            sequencer.enumNames(ui.grid.Msg) ++ [_][]const u8{ panel_modes_table_name, prompt_owner_name } ++ status_page.names() ++ p4_history.page.names() ++ p4_history.names ++ document_view.element_names),
        .root = vcs_p4_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "vcs_p4.take_messages", .run = takeMessages },
            .{ .name = "vcs_p4.follow_timer", .run = followTimer },
            .{ .name = "vcs_p4.follow_project", .run = followProject },
            .{ .name = "vcs_p4.follow_change", .run = p4_change.followChange },
            .{ .name = "vcs_p4.follow_layout", .run = followLayout },
            .{ .name = "vcs_p4.turn_spinner", .run = turnSpinner },
            .{ .name = "vcs_p4.follow_modes", .run = followModes },
        },
    };
}

fn claims(tag: Atom) bool {
    if (p4_diff.claims(tag)) return true;
    if (p4_change.claims(tag)) return true;
    if (p4_history.claims(tag)) return true;
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
    result.writeAll(&.{ state_table, default_table, opened_table, changelists_table, submitted_table, expanded_table, pending_table });
    result.writeIfPresent(tables, document_sources_table);
    result.writeIfPresent(tables, document_values_table);
    status_page.declareAccess(&result, tables);
    p4_diff.declareAccess(&result, tables);
    p4_change.declareAccess(&result, tables);
    p4_history.declareAccess(&result, tables);
    result.write(runner_requests_table);
    runner.declareJobs(&result, tables, sequencer.inboxOf(system()));
    if (tables.findByName(runner_log_table) != null) result.read(runner_log_table);
    if (tables.findByName(places_table) != null) result.read(places_table);
    result.writeIfPresent(tables, text_editor_requests);
    result.writeIfPresent(tables, transient_requests);
    result.writeIfPresent(tables, palette_requests);
    open.declareOpenAccess(&result, tables);
    result.writeIfPresent(tables, shown_panels_table);
    result.writeIfPresent(tables, workspace_table);
    result.writeIfPresent(tables, panel_requests_table);
    if (tables.findByName(panel_state_table) != null) result.readAll(&.{ panel_nodes_table, panel_state_table });
    // The visited buffer's file, which `a` opens: the newest text window in the focus history.
    const visited = [_]Atom{ focus_history_table, text_windows_table, buffers_table };
    for (visited) |name| {
        if (tables.findByName(name) != null) result.read(name);
    }
    if (tables.findByName(font_metrics_table) != null) result.read(font_metrics_table);
    plugin.panels.Events.declare(&result, tables, plugin.panels.events_table_name);
    vcs_timer.declareTimerAccess(&result, tables);
    modes.declarePanelModes(&result, tables, panel_modes_table_name);
    return result;
}

/// Each message the panel's system claimed this frame, in order; then the views settled: the
/// runner's log's cursor, and each page's cursor against the page as it is now, the folds of
/// headings gone let go. While the diff panel is open, each move of the person's that took the
/// changelists' cursor onto another file shows that one in it.
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
    if (follow == .cursor) try work.settleProcessLog();
    for (pages) |page| try vcs_page.settle(pass, page, .keep);
    for (pages) |page| {
        const moved_under = try vcs_page.movedUnder(pass, page);
        if (moved_under.* != 0) moved_under.* = 0;
    }
}

/// What a message did: nothing that moves a view (`stay`), moved the runner's log's cursor or
/// brought it new lines (`cursor`), or was the person's move of the changelists' cursor (`moved`).
pub const Follow = enum { stay, cursor, moved };

/// A row of one of the page's tables, as the cursor is on it.
const RowAt = struct { table: *Table, row: Table.RowHandle };

fn sameRow(before: ?RowAt, after: ?RowAt) bool {
    const was = before orelse return after == null;
    const is = after orelse return false;
    return was.table == is.table and was.row.row == is.row.row and was.row.generation == is.row.generation;
}

/// The refresh's timer: while `timerInterval` says it runs, a wake of the time system's is
/// pending, asked as the timer starts and again as each refresh starts; while it does not run,
/// the wake is cancelled. The interval is the setting `vcs_p4_refresh_seconds` alone: the page
/// has no `#+REFRESH:`, so with the setting 0 or absent no timer runs, each refresh being a round
/// trip to a server.
fn followTimer(pass: *sequencer.Pass) !void {
    const stored = try pass.readSingleton(state_table, struct { timer_armed: *u8, timer_seconds: *u32, timer_asked_at: *i64 });
    const wanted = try timerInterval(pass);
    const armed_for: ?u32 = if (stored.timer_armed.* != 0) stored.timer_seconds.* else null;
    if (wanted == armed_for) {
        const seconds = wanted orelse return;
        if (!vcs_timer.wakeOverdue(pass, stored.timer_asked_at.*, seconds)) return;
        const work = try Work.of(pass);
        return work.armTimer(seconds);
    }
    const work = try Work.of(pass);
    if (wanted) |seconds| return work.armTimer(seconds);
    work.disarmTimer();
}

/// How many seconds the timer waits between refreshes now; null while it does not run: the
/// panel not shown, another view shown, nothing read yet, the window without the focus, or the
/// setting 0 or absent.
fn timerInterval(pass: *const sequencer.Pass) !?u32 {
    if (!isShown(pass)) return null;
    const state = try pass.readSingleton(state_table, struct { view: *u8, answered: *u8 });
    if (viewOf(state.view.*) != .status or state.answered.* == 0) return null;
    if (!vcs_timer.windowFocused(pass)) return null;
    const seconds = settingSeconds(pass) orelse return null;
    if (seconds == 0) return null;
    return seconds;
}

/// The setting `vcs_p4_refresh_seconds`, when its cell is set; null when it is absent.
fn settingSeconds(pass: *const sequencer.Pass) ?u32 {
    if (!pass.declares(settings_table)) return null;
    const settings = pass.table(settings_table) catch return null;
    if (settings.getSchema().fieldIndex(keybinds.vcs_p4_refresh_field) == null) return null;
    var rows = settings.readQuery(struct { vcs_p4_refresh_seconds: *u32 });
    const row = rows.next() orelse return null;
    return row.view.vcs_p4_refresh_seconds.*;
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
    try work.refresh();
}

/// Keeps each view fit to its panel as it is resized.
fn followLayout(pass: *sequencer.Pass) !void {
    try p4_diff.followLayout(pass);
    for (pages) |page| try vcs_page.followSize(pass, page, panel);
    if (!isShown(pass)) return;
    const layout = process_log.layoutOf(pass, panel);
    const stored = try pass.readSingleton(state_table, struct { view_height: *f32 });
    if (stored.view_height.* == layout.view_height) return;
    const work = try Work.of(pass);
    work.state.view_height.* = layout.view_height;
    try work.settleProcessLog();
}

/// Copies the runner's `phase` while a job of the panel's runs: the spinner the header draws.
fn turnSpinner(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const inbox = sequencer.inboxOf(system());
    if (!runner.busy(tables, inbox)) return;
    const turned = runner.phase(tables);
    const stored = try pass.readSingleton(state_table, struct { spinner: *u32 });
    if (stored.spinner.* == turned) return;
    const state = try pass.writeSingleton(state_table, struct { spinner: *u32 });
    state.spinner.* = turned;
}

/// The panels' major modes: `vcs_p4`, but in the history view `vcs_p4_history`; the diff
/// panel's `vcs_p4_diff`.
fn followModes(pass: *sequencer.Pass) !void {
    const state = try pass.readSingleton(state_table, struct { view: *u8 });
    const major = switch (viewOf(state.view.*)) {
        .history => modes.vcs_p4_history,
        .status, .process_log => modes.vcs_p4,
    };
    const wanted = [_]modes.PanelMajor{
        .{ .panel = panel, .major = major },
        .{ .panel = p4_diff.panel, .major = modes.vcs_p4_diff },
    };
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

/// Whether the panel is shown: declared, open or about to open.
pub fn isShown(pass: *const sequencer.Pass) bool {
    if (!pass.declares(shown_panels_table)) return false;
    return workspaces.panelShown(pass.frame.tables, panel);
}

/// What the panel reads of `os_places`, each empty without it.
pub const Places = struct { working_directory: []const u8, home_directory: []const u8, executable: []const u8 };

pub fn placesOf(pass: *const sequencer.Pass) Places {
    const unknown: Places = .{ .working_directory = "", .home_directory = "", .executable = "" };
    if (!pass.declares(places_table)) return unknown;
    return pass.readSingleton(places_table, Places) catch unknown;
}

// ---- the work of a run ---------------------------------------------------------------------------

/// What the kernels hand their helpers: the run's pass and the panel's tables as the run writes
/// them.
pub const Work = struct {
    pass: *sequencer.Pass,
    state: StateRow,
    /// The panel's own row's table, which holds its text.
    cells: *Table,
    default_files: *Table,
    opened_files: *Table,
    changelists: *Table,
    submitted: *Table,
    expanded: *Table,

    pub fn of(pass: *sequencer.Pass) !Work {
        return .{
            .pass = pass,
            .state = try pass.writeSingleton(state_table, StateRow),
            .cells = try pass.writeTable(state_table),
            .default_files = try pass.writeTable(default_table),
            .opened_files = try pass.writeTable(opened_table),
            .changelists = try pass.writeTable(changelists_table),
            .submitted = try pass.writeTable(submitted_table),
            .expanded = try pass.writeTable(expanded_table),
        };
    }

    pub fn tables(work: Work) *Table.Registry {
        return work.pass.frame.tables;
    }

    pub fn memory(work: Work) *memory_mod.Memory {
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

    /// The workspace's name, as `info` gave it; empty until it is known.
    pub fn client(work: Work) []const u8 {
        return work.cells.textOf(work.state.client.*);
    }

    /// The context every command line carries: the workspace `info` named.
    pub fn context(work: Work) p4.Context {
        return .{ .client = work.client() };
    }

    /// One message; returns what it did to the views' cursors.
    fn take(work: Work, received: sequencer.Message) !Follow {
        if (p4_change.claims(received.tag)) {
            try p4_change.take(work, received);
            return .stay;
        }
        if (p4_diff.claims(received.tag)) {
            try p4_diff.take(work, received);
            return .stay;
        }
        const shown_view = viewOf(work.state.view.*);
        if (try work.takeOnPage(received)) |follow| return follow;
        if (p4_history.claims(received.tag)) {
            try p4_history.take(work, received);
            return .stay;
        }
        const message = received.tag.to(Msg);
        switch (shown_view) {
            .history => if (try p4_history.takeInHistory(work, message)) return .stay,
            .status => if (try work.takeInStatus(message)) |follow| return follow,
            .process_log => if (try work.takeInProcessLog(message, received)) |follow| return follow,
        }
        switch (message) {
            .vcs_p4_status => try work.show(),
            .vcs_p4_refresh => try work.refresh(),
            .vcs_p4_quit => work.quit(),
            .vcs_p4_process_log => try work.showProcessLog(),
            .vcs_p4_give_up => try work.giveUp(),
            .vcs_p4_menu => {
                const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_p4_menu_chosen));
                transient.present(work.memory(), work.tables(), .{ .menu = &menu, .reply = reply });
            },
            .vcs_p4_menu_chosen => {
                const chosen = try received.payloadAs(transient.Chosen);
                if (chosen.cancelled != 0) return .stay;
                const command = std.enums.fromInt(MenuCommand, chosen.id) orelse return .stay;
                try work.dispatch(command);
            },
            .vcs_p4_finished => try work.takeFinished(received),
            .vcs_p4_timer => {
                try work.timerFired();
                return .stay;
            },
            .vcs_p4_shelve_chosen => {
                const chosen = try received.payloadAs(transient.Chosen);
                if (chosen.cancelled != 0) return .stay;
                const item = std.enums.fromInt(ShelveItem, chosen.id) orelse return .stay;
                try work.chooseShelve(item);
            },
            .vcs_p4_sync_chosen => {
                const chosen = try received.payloadAs(transient.Chosen);
                if (chosen.cancelled != 0) return .stay;
                const item = std.enums.fromInt(SyncItem, chosen.id) orelse return .stay;
                const mode: p4.SyncMode = switch (item) {
                    .sync => .sync,
                    .preview => .preview,
                };
                try work.runCommand(.{ .sync = mode }, "");
            },
            .vcs_p4_open_chosen => {
                const chosen = try received.payloadAs(transient.Chosen);
                if (chosen.cancelled != 0) return .stay;
                const item = std.enums.fromInt(OpenItem, chosen.id) orelse return .stay;
                try work.chooseOpen(item);
            },
            .vcs_p4_confirm => try work.takeConfirm(received),
            .vcs_p4_move_chosen => try work.takeMoveChoice(received),
            else => return .stay,
        }
        return .cursor;
    }

    /// A message of the shown view's page (a click, a fold mark, the wheel), or a click on a row
    /// of one of its tables, through `document.take`: what it did, or null for a message that is
    /// not that page's. A click on what the cursor is already on is chosen, as RET chooses it.
    fn takeOnPage(work: Work, received: sequencer.Message) !?Follow {
        const shown_view = viewOf(work.state.view.*);
        const page = switch (shown_view) {
            .status => status_page,
            .history => p4_history.page,
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
                    .history => try p4_history.chooseAt(work, chosen),
                    .process_log => {},
                }
                return .stay;
            },
        }
    }

    /// The panel's own keys on the changelists' page: moves of its cursor, folds, RET and the
    /// commands. Returns null for a message the views share.
    fn takeInStatus(work: Work, message: Msg) !?Follow {
        const way: document.Step = switch (message) {
            .vcs_p4_next => .next,
            .vcs_p4_previous => .previous,
            .vcs_p4_next_sibling => .next_heading,
            .vcs_p4_previous_sibling => .previous_heading,
            .vcs_p4_parent => .parent,
            .vcs_p4_first => .first,
            .vcs_p4_last => .last,
            .vcs_p4_page_down => .page_down,
            .vcs_p4_page_up => .page_up,
            .vcs_p4_toggle => {
                try vcs_page.fold(work.pass, status_page, .at_cursor);
                return .stay;
            },
            .vcs_p4_toggle_all => {
                try vcs_page.fold(work.pass, status_page, .every);
                return .stay;
            },
            .vcs_p4_visit => {
                if (try vcs_page.changedUnderCursor(work.pass, status_page)) return .stay;
                try work.visitAt(try vcs_page.atCursor(work.pass, status_page));
                return .stay;
            },
            .vcs_p4_submit => {
                try work.submitAtCursor();
                return .stay;
            },
            .vcs_p4_describe => {
                try work.describeAtCursor();
                return .stay;
            },
            .vcs_p4_new_change => {
                try p4_change.start(work, .new_change, .{ .numbered = 0 }, "", &.{});
                return .stay;
            },
            .vcs_p4_move => {
                try work.moveAtCursor();
                return .stay;
            },
            .vcs_p4_revert => {
                try work.revertAtCursor();
                return .stay;
            },
            .vcs_p4_revert_unchanged => {
                try work.revertUnchangedAtCursor();
                return .stay;
            },
            .vcs_p4_delete_change => {
                try work.deleteAtCursor();
                return .stay;
            },
            .vcs_p4_shelve_menu => {
                try work.presentShelveMenu();
                return .stay;
            },
            .vcs_p4_sync_menu => {
                work.presentMenu(&sync_menu, .vcs_p4_sync_chosen);
                return .stay;
            },
            .vcs_p4_resolve => {
                try work.resolve();
                return .stay;
            },
            .vcs_p4_reconcile => {
                try work.reconcilePreview();
                return .stay;
            },
            .vcs_p4_open_menu => {
                work.presentMenu(&open_menu, .vcs_p4_open_chosen);
                return .stay;
            },
            .vcs_p4_click, .vcs_p4_chevron, .vcs_p4_wheel => return .stay,
            else => return null,
        };
        const laid_out = try vcs_page.laidOut(work.pass, status_page);
        document.step(laid_out, try vcs_page.stateOf(work.pass, status_page), way);
        return .moved;
    }

    /// The panel's own keys in the runner's log view: its moves, folds, clicks and wheel; what
    /// acts on a changelist tells it is not there. Returns null for a message the views share.
    fn takeInProcessLog(work: Work, message: Msg, received: sequencer.Message) !?Follow {
        const log_view = try work.processLog() orelse return null;
        switch (message) {
            .vcs_p4_next => try log_view.move(.next),
            .vcs_p4_previous => try log_view.move(.previous),
            .vcs_p4_next_sibling => try log_view.move(.next_sibling),
            .vcs_p4_previous_sibling => try log_view.move(.previous_sibling),
            .vcs_p4_parent => try log_view.move(.parent),
            .vcs_p4_first => try log_view.move(.first),
            .vcs_p4_last => try log_view.move(.last),
            .vcs_p4_page_down => try log_view.move(.page_down),
            .vcs_p4_page_up => try log_view.move(.page_up),
            .vcs_p4_toggle => try log_view.toggleAtCursor(),
            .vcs_p4_toggle_all => try log_view.toggleAll(),
            .vcs_p4_visit => {},
            .vcs_p4_submit, .vcs_p4_describe, .vcs_p4_move, .vcs_p4_revert, .vcs_p4_revert_unchanged, .vcs_p4_delete_change, .vcs_p4_shelve_menu => {
                work.tell("Not in the process log: q goes back to the changelists");
                return .stay;
            },
            .vcs_p4_click => {
                const key = (try received.userDataAs(u64)).*;
                try log_view.putCursorOn(key);
            },
            .vcs_p4_chevron => {
                const key = (try received.userDataAs(u64)).*;
                try log_view.toggleKey(key);
            },
            .vcs_p4_wheel => {
                const scrolled = try received.payloadAs(input.MouseScrollMsg);
                try log_view.wheel(scrolled.y);
                return .stay;
            },
            .vcs_p4_document_click, .vcs_p4_document_toggle, .vcs_p4_document_wheel => return .stay,
            else => return null,
        }
        return .cursor;
    }

    /// Runs what the menu of menus chose. `?` is offered in every view: what acts on the
    /// changelists' cursor, hidden outside the changelists, is refused there with the words its
    /// key is refused in.
    fn dispatch(work: Work, command: MenuCommand) !void {
        const on_cursor = switch (command) {
            .submit, .describe, .move, .revert, .revert_unchanged, .delete_change, .shelve, .open_file, .reconcile => true,
            .refresh, .process_log, .quit, .new_change, .sync, .resolve, .history => false,
        };
        if (on_cursor) switch (viewOf(work.state.view.*)) {
            .status => {},
            .process_log => return work.tell("Not in the process log: q goes back to the changelists"),
            .history => return work.tell("Not in the history: q goes back to the changelists"),
        };
        switch (command) {
            .refresh => try work.refresh(),
            .process_log => try work.showProcessLog(),
            .quit => work.quit(),
            .submit => try work.submitAtCursor(),
            .describe => try work.describeAtCursor(),
            .new_change => try p4_change.start(work, .new_change, .{ .numbered = 0 }, "", &.{}),
            .move => try work.moveAtCursor(),
            .revert => try work.revertAtCursor(),
            .revert_unchanged => try work.revertUnchangedAtCursor(),
            .delete_change => try work.deleteAtCursor(),
            .shelve => try work.presentShelveMenu(),
            .sync => work.presentMenu(&sync_menu, .vcs_p4_sync_chosen),
            .open_file => work.presentMenu(&open_menu, .vcs_p4_open_chosen),
            .resolve => try work.resolve(),
            .reconcile => try work.reconcilePreview(),
            .history => try p4_history.showHistory(work),
        }
    }

    /// Shows `the_menu`, its answer coming as `tag`.
    fn presentMenu(work: Work, the_menu: *const ui.transient.Menu, tag: Msg) void {
        const reply = sequencer.ReplyTo.of(system(), .from(tag));
        transient.present(work.memory(), work.tables(), .{ .menu = the_menu, .reply = reply });
    }

    /// `global.vcs_p4_status`: shows the panel in the text workspace and gives it the focus,
    /// refreshing; while it has the focus, refreshes.
    pub fn show(work: Work) !void {
        const frame = work.pass.frame;
        const tables_now = work.tables();
        const atoms = frame.atoms;
        const workspace = workspaces.activeWorkspace(tables_now, atoms);
        const elsewhere = workspace == .app or workspace == .figure;
        if (elsewhere and work.pass.writes(workspace_table)) workspaces.arrange(tables_now, atoms, .text);
        workspaces.showPanel(tables_now, atoms, panel, .arranged, .take);
        work.state.view.* = @intFromEnum(View.status);
        // What the page shows is published before the first answer, so no table of it reads as
        // not published.
        if (work.state.answered.* == 0) try work.publish();
        try work.refresh();
    }

    /// `q`: back one view, the runner's log to the view it was shown from, the history to the
    /// changelists; the changelists close the panel.
    pub fn quit(work: Work) void {
        const state = work.state;
        switch (viewOf(state.view.*)) {
            .process_log => state.view.* = state.process_log_return.*,
            .history => state.view.* = @intFromEnum(View.status),
            .status => workspaces.hidePanel(work.tables(), panel),
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

    /// `$`: the runner's log of the panel's jobs, the cursor on the newest.
    pub fn showProcessLog(work: Work) !void {
        work.enterView(.process_log);
        const log_view = try work.processLog() orelse return;
        try log_view.showNewest();
    }

    /// The runner's log view as this run moves through it, while it is shown.
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

    fn settleProcessLog(work: Work) !void {
        const log_view = try work.processLog() orelse return;
        try log_view.settle();
    }

    /// `C-g`: gives up every job of the panel's, and tells which ran. A refresh that waits on
    /// answers no job will give is forgotten too, so the next one runs.
    pub fn giveUp(work: Work) !void {
        const tables_now = work.tables();
        const inbox = sequencer.inboxOf(system());
        const busy = runner.busy(tables_now, inbox);
        const refreshing = work.state.refresh_jobs.* != 0;
        if (!busy and !refreshing) return;
        const allocator = try work.scratch();
        const running_now = runner.running(tables_now, inbox);
        const running = try allocator.dupe(u8, running_now);
        if (busy) runner.giveUp(work.memory(), tables_now, inbox);
        try work.forgetRefresh();
        try work.setNote("Gave up; g asks again");
        if (running.len == 0) return;
        const sentence = try std.fmt.allocPrint(allocator, "Gave up: {s}", .{running});
        work.tell(sentence);
    }

    /// Moves to a new generation: the jobs queued so far are no longer the panel's to answer.
    fn forgetRefresh(work: Work) !void {
        const state = work.state;
        state.generation.* +%= 1;
        state.phase.* = @intFromEnum(Phase.idle);
        state.refresh_jobs.* = 0;
        state.refresh_again.* = 0;
        state.refresh_failed.* = 0;
        state.refresh_unstarted.* = 0;
        state.refresh_unpassable.* = 0;
        state.commands_running.* = 0;
        try work.forgetSaid();
        try p4_diff.abandon(work);
        try p4_history.abandon(work);
    }

    /// Lets go of what the refresh's lists said, kept until all were in.
    fn forgetSaid(work: Work) !void {
        const state = work.state;
        state.pending_said.* = .{};
        state.shelved_said.* = .{};
        state.opened_said.* = .{};
        state.submitted_said.* = .{};
    }

    /// Marks every source of the changelists' page `unread`: the lists could not be read.
    fn markSourcesUnread(work: Work) !void {
        const publishing = try document_sources.Publishing.of(work.pass) orelse return;
        for (std.enums.values(SourceKind)) |kind| publishing.setSourceState(publisher, kind.name(), .unread);
    }

    /// The note the page shows, `text`; empty leaves its line out.
    pub fn setNote(work: Work, text: []const u8) !void {
        const allocator = try work.scratch();
        const kept = try allocator.dupe(u8, text);
        try work.cells.assignString(work.state.note, kept);
        if (try document_sources.Publishing.of(work.pass)) |publishing| publishing.publishValue(publisher, "vcs-p4.note", kept);
    }

    // ---- the refresh ----------------------------------------------------------------------------

    /// Asks `p4` again for what the panel shows: `info` while the workspace is not known, else
    /// the four lists, run together; noted while a refresh runs, to run once it ends. A working
    /// directory not the one the data is for is another project: what runs is given up and the
    /// data forgotten first.
    pub fn refresh(work: Work) !void {
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
            state.refresh_again.* = 1;
            return;
        }
        state.refresh_failed.* = 0;
        state.refresh_unstarted.* = 0;
        state.refresh_unpassable.* = 0;
        if (state.timer_armed.* != 0) work.armTimer(state.timer_seconds.*);
        try work.cells.assignString(state.home_directory, where.home_directory);
        if (state.answered.* == 0) try work.setNote("Loading...");
        if (state.info_known.* == 0) return work.askInfo();
        try work.askLists();
    }

    /// `info`, alone: the workspace, its root, the user and the server.
    fn askInfo(work: Work) !void {
        work.state.phase.* = @intFromEnum(Phase.info);
        try work.ask(.info, .info);
    }

    /// The four lists, run together; when none can be given to `p4`, the refresh ends here,
    /// which is why the error set is named (its end can begin another refresh).
    fn askLists(work: Work) anyerror!void {
        const state = work.state;
        state.phase.* = @intFromEnum(Phase.lists);
        state.opened_empty.* = 0;
        try work.forgetSaid();
        const client_name = work.client();
        const allocator = try work.scratch();
        const recent_path = try std.fmt.allocPrint(allocator, "//{s}/...", .{client_name});
        try work.ask(.pending, .{ .changes = .{ .status = .pending, .client = client_name } });
        try work.ask(.shelved_changes, .{ .changes = .{ .status = .shelved, .client = client_name } });
        try work.ask(.opened, .{ .opened = client_name });
        try work.ask(.submitted, .{ .history = .{ .max = recent_count, .path = recent_path } });
        // None could be given to `p4`: no answer comes to end the refresh, so it ends here.
        if (state.refresh_jobs.* == 0) try work.listsAnswered();
    }

    /// Queues the refresh's job for `purpose`, `command` with no input, counted in the refresh.
    fn ask(work: Work, purpose: Purpose, command: p4.Command) !void {
        // Counted only when queued: one `p4` cannot be given is told and marked failed and
        // unpassable, so the refresh ends unread rather than read with that list empty, its
        // note saying no program ran (`listsFailed`).
        if (!p4.passes(work.context(), command)) {
            work.state.refresh_failed.* |= purpose.bit();
            work.state.refresh_unpassable.* |= purpose.bit();
            return work.tellUnpassable(error.UnpassableArgument);
        }
        try work.queueRead(purpose, command, "", 0);
        work.state.refresh_jobs.* += 1;
    }

    /// Queues the job that reads `command` for `purpose`, `input_bytes` on its input, with the
    /// panel's others, carrying `epoch`: one whose names `p4` cannot be given is told, and
    /// nothing is queued.
    pub fn queueRead(work: Work, purpose: Purpose, command: p4.Command, input_bytes: []const u8, epoch: u32) !void {
        const allocator = try work.scratch();
        var argv: std.Io.Writer.Allocating = .init(allocator);
        p4.writeArgv(&argv.writer, work.context(), command) catch |err| return work.tellUnpassable(err);
        const environment = if (command == .diff) p4.internal_diff_environment else "";
        work.queue(.{ .purpose = purpose, .argv = argv.written(), .input = input_bytes, .environment = environment, .epoch = epoch });
    }

    /// Queues `command` of the panel's own, `input_bytes` on its input, alone, counted until it
    /// answers; its end refreshes when no other runs.
    pub fn runCommand(work: Work, command: p4.Command, input_bytes: []const u8) !void {
        if (work.refusedWithoutWorkspace()) return;
        const allocator = try work.scratch();
        var argv: std.Io.Writer.Allocating = .init(allocator);
        p4.writeArgv(&argv.writer, work.context(), command) catch |err| return work.tellUnpassable(err);
        work.queue(.{ .purpose = .command, .command = CommandName.of(command), .argv = argv.written(), .input = input_bytes, .order = .alone });
        work.state.commands_running.* +|= 1;
    }

    /// Whether no workspace is known, which every command line names: told then.
    pub fn refusedWithoutWorkspace(work: Work) bool {
        if (work.state.info_known.* != 0) return false;
        work.tell("No Perforce workspace is known yet: g asks p4 again");
        return true;
    }

    pub fn tellUnpassable(work: Work, err: p4.WriteError) !void {
        switch (err) {
            error.UnpassableArgument => work.tell("p4 cannot be given that name or path: it begins with -, holds ... or a control character"),
            error.WriteFailed => return error.OutOfMemory,
        }
    }

    /// Queues `job` in the working directory, the panel's generation in its user data.
    fn queue(work: Work, job: Queued) void {
        const state = work.state;
        const data: JobData = .{ .generation = state.generation.*, .purpose = @intFromEnum(job.purpose), .command = @intFromEnum(job.command), .epoch = job.epoch };
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_p4_finished)).with(.of(&data));
        runner.run(work.memory(), work.tables(), .{
            .owner = reply,
            .argv = job.argv,
            .input = job.input,
            .environment = job.environment,
            .directory = work.cells.textOf(state.working_directory.*),
            .order = job.order,
        });
    }

    /// The timer's wake came: a refresh, unless one or a command runs, whose end brings the
    /// tables up to date; the wake is asked again either way while the timer runs.
    fn timerFired(work: Work) !void {
        const state = work.state;
        if (state.timer_armed.* == 0) return;
        const seconds = try timerInterval(work.pass) orelse return work.disarmTimer();
        if (state.refresh_jobs.* != 0 or state.commands_running.* != 0) return work.armTimer(seconds);
        try work.refresh();
        if (state.refresh_jobs.* == 0) work.armTimer(seconds);
    }

    fn armTimer(work: Work, seconds: u32) void {
        work.state.timer_armed.* = 1;
        work.state.timer_seconds.* = seconds;
        work.state.timer_asked_at.* = vcs_timer.awakeNanoseconds(work.pass) orelse 0;
        const wake: mesha.time.Wake = .{ .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.vcs_p4_timer), .after = @floatFromInt(seconds) };
        work.appendWake(.wake, wake);
    }

    fn disarmTimer(work: Work) void {
        work.state.timer_armed.* = 0;
        const wake: mesha.time.Wake = .{ .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.vcs_p4_timer) };
        work.appendWake(.cancel_wake, wake);
    }

    fn appendWake(work: Work, op: mesha.time.CommandOp, wake: mesha.time.Wake) void {
        if (!work.pass.writes(time_commands)) return;
        const commands = work.pass.writeTable(time_commands) catch return;
        mesha.time.appendWake(commands, op, wake) catch |err| {
            Log.warn("timer_request_dropped", .{ .@"error" = @errorName(err) });
        };
    }

    /// A job's answer: read, then released whatever came of it. An answer of an earlier
    /// generation, or of a job the runner no longer holds, is dropped.
    fn takeFinished(work: Work, received: sequencer.Message) !void {
        const finished = (try received.payloadAs(runner.Finished)).*;
        const data = (try received.userDataAs(JobData)).*;
        defer runner.release(work.memory(), work.tables(), finished.job);
        const state = work.state;
        if (data.generation != state.generation.*) return;
        const purpose = std.enums.fromInt(Purpose, data.purpose) orelse return;
        const said = runner.output(work.tables(), finished.job);
        const succeeded = runner.ranWell(finished, said);
        const answer: ?[]const u8 = if (succeeded) said.?.said else null;
        switch (purpose) {
            .command => return work.takeCommandEnd(data, finished, said),
            .diff => return p4_diff.takeDiff(work, data.epoch, answer),
            .describe => return p4_diff.takeDescribe(work, data.epoch, answer),
            .history => return p4_history.takeHistory(work, data.epoch, answer),
            .session_info, .login_status => return work.takeSession(purpose, finished, said),
            .info, .pending, .shelved_changes, .opened, .submitted, .describe_shelved => {},
        }
        state.refresh_jobs.* -|= 1;
        // `fstat -Ro` in a workspace with nothing opened may end non-zero with a warning on its
        // errors and no record (`MsgDm::ExOPENCLIENT` "file(s) not opened on this client." is a
        // warning, E_WARN, and whether a warning alone makes the exit code non-zero is
        // UNVERIFIED): noted, and read as an empty list when every other list read
        // (`listsAnswered`).
        const ran = finished.started == @intFromEnum(process.SpawnResult.spawned);
        const printed_nothing = if (said) |output| std.mem.trim(u8, output.said, " \t\r\n").len == 0 else false;
        // ... and said nothing on its errors but that warning (`MsgDm::ExOPENCLIENT`, E_WARN, in
        // the saved message catalog `msgdm_2018-2.cc`): any other error is a failure.
        const errors_known = if (said) |output| notOpenedWarningOnly(output.errors) else false;
        if (purpose == .opened and !succeeded and ran and printed_nothing and errors_known) state.opened_empty.* = 1;
        if (!succeeded) {
            state.refresh_failed.* |= purpose.bit();
            const unstarted = finished.started == @intFromEnum(process.SpawnResult.not_found);
            if (unstarted) state.refresh_unstarted.* |= purpose.bit();
        }
        switch (purpose) {
            .info => return work.takeInfo(answer, finished),
            .pending => if (answer) |bytes| try work.keepSaid(state.pending_said, bytes),
            .shelved_changes => if (answer) |bytes| try work.keepSaid(state.shelved_said, bytes),
            .opened => if (answer) |bytes| try work.keepSaid(state.opened_said, bytes),
            .submitted => if (answer) |bytes| try work.keepSaid(state.submitted_said, bytes),
            .describe_shelved => return work.writeLists(answer),
            else => unreachable,
        }
        if (state.refresh_jobs.* != 0) return;
        try work.listsAnswered();
    }

    /// Keeps `bytes`, what a list said, in `cell` until every list is in.
    fn keepSaid(work: Work, cell: *Table.Bytes, bytes: []const u8) !void {
        cell.* = .{ .payload = try work.cells.appendPayload(bytes, .@"16") };
    }

    /// `info`'s answer, `said`, null for one that failed: the workspace kept and the lists
    /// asked; with none, or no `p4`, or no server, the note says so and nothing else runs.
    fn takeInfo(work: Work, said: ?[]const u8, finished: runner.Finished) !void {
        const state = work.state;
        const bytes = said orelse {
            const unstarted = finished.started == @intFromEnum(process.SpawnResult.not_found);
            const notice: Notice = if (unstarted) .no_program else .no_server;
            return work.endWithNotice(notice, "");
        };
        const allocator = try work.scratch();
        const info = try p4.parseInfo(bytes, host_style, allocator);
        try work.cells.assignString(state.user, info.user);
        try work.cells.assignString(state.server, info.server_address);
        if (!info.hasClient()) {
            try work.cells.assignString(state.client, "");
            try work.cells.assignString(state.client_root, "");
            return work.endWithNotice(.no_workspace, "");
        }
        if (!p4.isClientName(info.client)) {
            try work.cells.assignString(state.client, "");
            return work.endWithNotice(.bad_client, info.client);
        }
        try work.cells.assignString(state.client, info.client);
        try work.cells.assignString(state.client_root, info.client_root);
        state.info_known.* = 1;
        state.notice.* = @intFromEnum(Notice.none);
        try work.publish();
        try work.askLists();
    }

    /// The refresh ends on `notice`, said in the note: the workspace not known, nothing more
    /// asked. Rows listed before are kept, their sources marked `unread`.
    fn endWithNotice(work: Work, notice: Notice, client_named: []const u8) !void {
        const state = work.state;
        state.notice.* = @intFromEnum(notice);
        state.info_known.* = 0;
        if (state.answered.* != 0) {
            state.lists_unread.* = 1;
            try work.markSourcesUnread();
        }
        const allocator = try work.scratch();
        const note = switch (notice) {
            .none => "",
            .no_program => "p4 could not be run: it was not found on PATH",
            .no_server => "p4 info failed: no Perforce server answered ($ shows why); g asks again",
            .no_workspace => blk: {
                const directory = try open.shownFromHome(allocator, work.cells.textOf(state.working_directory.*), work.cells.textOf(state.home_directory.*));
                const shown = try ui.displayText(allocator, directory);
                break :blk try std.fmt.allocPrint(allocator, "No workspace here: p4 info names no client workspace with a root for {s} (P4CLIENT, P4CONFIG); g asks again", .{shown});
            },
            .bad_client => blk: {
                const shown = try ui.displayText(allocator, client_named);
                break :blk try std.fmt.allocPrint(allocator, "p4 info names the workspace {s}, a name vcs-p4 does not pass to p4 (all digits, a - first, a space, @ # * % / or ...)", .{shown});
            },
        };
        try work.setNote(note);
        if (state.answered.* == 0) try work.publish();
        try work.endRefresh(.unread);
    }

    /// Every list answered: a failure marks the sources unread and asks whether the session
    /// ended; else the shelved files are asked when a changelist has some, or the tables are
    /// written.
    fn listsAnswered(work: Work) !void {
        const state = work.state;
        // A defensive reading, UNVERIFIED: `fstat` alone failed, having printed no record, while
        // `changes` read in the same refresh: a workspace with nothing opened, not a failure.
        const only_opened = state.refresh_failed.* == Purpose.opened.bit();
        if (only_opened and state.opened_empty.* != 0) {
            state.refresh_failed.* = 0;
            try work.keepSaid(state.opened_said, "");
        }
        const failed = state.refresh_failed.*;
        if (failed != 0) return work.listsFailed();
        const allocator = try work.scratch();
        const read = try work.pass.readSingleton(state_table, StateRead);
        const shelved = try shelvedNumbers(allocator, read);
        if (shelved.len == 0) return work.writeLists(null);
        var numbers: std.Io.Writer.Allocating = .init(allocator);
        try p4.writeChangeNumbers(&numbers.writer, shelved);
        state.phase.* = @intFromEnum(Phase.shelved);
        try work.queueRead(.describe_shelved, .shelved, numbers.written(), 0);
        state.refresh_jobs.* += 1;
    }

    /// A list failed: every row is kept and each source marked `unread`, and the note says
    /// which failed. When `p4` was not found, or a list was never asked for because `p4` cannot
    /// be given its command line, the refresh ends there; else `info` with `login -s` ask
    /// whether the session ended (`takeSession`).
    fn listsFailed(work: Work) !void {
        const state = work.state;
        const failed = state.refresh_failed.*;
        try work.markSourcesUnread();
        state.lists_unread.* = 1;
        const allocator = try work.scratch();
        if (state.refresh_unstarted.* != 0) {
            try work.setNote("p4 could not be run: it was not found on PATH");
            return work.endRefresh(.unread);
        }
        // No program ran for a list `p4` cannot be given: there is no output for `$` to show
        // and the session is not in question, so the note says that and nothing more is asked.
        const unpassable = state.refresh_unpassable.*;
        if (unpassable != 0) {
            const unasked: Purpose = for (std.enums.values(Purpose)) |purpose| {
                if (unpassable & purpose.bit() != 0) break purpose;
            } else .pending;
            const unasked_note = try std.fmt.allocPrint(allocator, "p4 {s} was not asked for: p4 cannot be given the workspace's name or a path of its command line (one begins with -, holds ... or a control character)", .{unasked.subcommand()});
            try work.setNote(unasked_note);
            return work.endRefresh(.unread);
        }
        const first: Purpose = for (std.enums.values(Purpose)) |purpose| {
            if (failed & purpose.bit() != 0) break purpose;
        } else .pending;
        const sentence = try std.fmt.allocPrint(allocator, "p4 {s} failed; $ shows why", .{first.subcommand()});
        try work.setNote(sentence);
        work.tell(sentence);
        try work.forgetSaid();
        // Did the session end? `info` needs no ticket; `login -s` fails without one.
        state.phase.* = @intFromEnum(Phase.session);
        state.session_info_code.* = -1;
        state.session_login_code.* = -1;
        try work.queueRead(.session_info, .info, "", 0);
        try work.queueRead(.login_status, .login_status, "", 0);
        state.refresh_jobs.* = 2;
    }

    /// An answer of the session check: once both are in, a session that ended puts what to do
    /// in the note and is told once.
    fn takeSession(work: Work, purpose: Purpose, finished: runner.Finished, said: ?runner.Output) !void {
        const state = work.state;
        if (viewOfPhase(state.phase.*) != .session) return;
        const ran = finished.started == @intFromEnum(process.SpawnResult.spawned);
        const code: i32 = if (ran and said != null) finished.code else -1;
        switch (purpose) {
            .session_info => state.session_info_code.* = code,
            .login_status => state.session_login_code.* = code,
            else => unreachable,
        }
        state.refresh_jobs.* -|= 1;
        if (state.refresh_jobs.* != 0) return;
        const session = p4.sessionOf(state.session_info_code.*, state.session_login_code.*);
        // No server answered `info`: the next refresh asks it again before the lists.
        if (session == .unknown) state.info_known.* = 0;
        if (session == .not_signed_in) {
            try work.setNote("The Perforce session has ended: Run p4 login in a terminal, then g");
            if (state.session_told.* == 0) work.tell("The Perforce session has ended: Run p4 login in a terminal, then g");
            state.session_told.* = 1;
        }
        try work.endRefresh(.unread);
    }

    /// What the lists said, every one read, written into the tables, `shelved_said` the
    /// changelists' shelved files (null when none were asked or it failed, said then): the rows
    /// each table needs, in `p4`'s order, a cell only where it changed, the cursor kept on what
    /// it was on.
    fn writeLists(work: Work, shelved_said: ?[]const u8) !void {
        const state = work.state;
        const allocator = try work.scratch();
        const read = try work.pass.readSingleton(state_table, StateRead);
        const described_failed = viewOfPhase(state.phase.*) == .shelved and shelved_said == null;
        if (described_failed) work.tell("p4 describe failed; $ shows why");

        // The changelists: pending, with those listed as shelved joined in.
        const pending_room = try allocator.alloc(p4.Change, max_changelists);
        const pending = p4.parseChanges(read.pending_said, pending_room);
        const shelved_room = try allocator.alloc(p4.Change, max_changelists);
        const shelved = p4.parseChanges(read.shelved_said, shelved_room);
        const merged = p4.mergeShelved(pending_room, pending.records, shelved_room[0..shelved.records.kept]);
        const changes = pending_room[0..merged.kept];
        var shelved_files: ?[]const p4.ShelvedFile = null;
        if (shelved_said) |bytes| {
            const counted = p4.parseDescribe(bytes, &.{}, &.{});
            const described_changes = try allocator.alloc(p4.Change, counted.changes.seen);
            const files = try allocator.alloc(p4.ShelvedFile, counted.files.seen);
            const described = p4.parseDescribe(bytes, described_changes, files);
            shelved_files = files[0..described.files.kept];
        }

        // The opened files.
        const opened_room = try allocator.alloc(p4.Opened, max_files);
        const opened = try p4.parseOpened(read.opened_said, host_style, allocator, opened_room);
        const files = opened_room[0..opened.records.kept];

        // The recent submitted changes.
        var submitted_room: [recent_count]p4.Change = undefined;
        const submitted = p4.parseChanges(read.submitted_said, &submitted_room);

        const kept = try work.cursorKept();
        try work.writeFiles(work.default_files, files, .default);
        try work.writeFiles(work.opened_files, files, .numbered);
        try work.writeChanges(changes, shelved_files);
        try work.writeSubmitted(submitted_room[0..submitted.records.kept]);

        var default_count: u32 = 0;
        for (files) |file| {
            if (file.change == .default) default_count += 1;
        }
        state.default_count.* = default_count;
        state.opened_seen.* = opened.records.seen;
        state.pending_count.* = merged.seen;
        state.unread_records.* = pending.unread + shelved.unread + opened.unread + submitted.unread;
        state.answered.* = 1;
        state.lists_unread.* = 0;
        state.session_told.* = 0;
        try work.forgetSaid();
        try work.publish();
        try work.setNote("");
        try work.keepCursor(kept);
        try p4_diff.forgetDiffs(work);
        try work.endRefresh(.read);
    }

    /// The refresh is over, `read` saying whether it wrote the lists: a refresh asked for
    /// meanwhile runs; else what follows a refresh (a description waiting to be sent on what is
    /// now listed, the diff the diff panel shows, what a resolve left).
    fn endRefresh(work: Work, read: ListsRead) !void {
        const state = work.state;
        state.phase.* = @intFromEnum(Phase.idle);
        state.refresh_jobs.* = 0;
        if (state.refresh_again.* != 0) {
            state.refresh_again.* = 0;
            return work.refresh();
        }
        try p4_change.refreshEnded(work, read);
        if (state.tell_unresolved.* != 0) {
            state.tell_unresolved.* = 0;
            try work.tellUnresolved();
        }
        try p4_diff.askWanted(work);
    }

    /// After a resolve: how many files still wait for one.
    fn tellUnresolved(work: Work) !void {
        var waiting: u32 = 0;
        const file_tables = [_]*Table{ work.default_files, work.opened_files };
        for (file_tables) |table| {
            var rows = table.readQuery(FileRow);
            while (rows.next()) |row| {
                if (row.view.unresolved.len != 0) waiting += 1;
            }
        }
        if (waiting == 0) return work.tell("Resolved: no file waits for a resolve");
        const allocator = try work.scratch();
        const noun = if (waiting == 1) "file still waits" else "files still wait";
        const sentence = try std.fmt.allocPrint(allocator, "Resolved what merged cleanly; {d} {s} for a resolve (marked unresolved): resolve them in a terminal (p4 resolve)", .{ waiting, noun });
        work.tell(sentence);
    }

    /// Which changelists a file goes to a table for.
    const FileSide = enum { default, numbered };

    /// The rows of `table` written from `files`, those of `side`, in order.
    fn writeFiles(work: Work, table: *Table, files: []const p4.Opened, side: FileSide) !void {
        var count: u32 = 0;
        for (files) |file| {
            if (sideOf(file) == side) count += 1;
        }
        const allocator = try work.scratch();
        const handles = try table_view.rowsInOrder(table, count, allocator);
        const root = work.cells.textOf(work.state.client_root.*);
        var index: usize = 0;
        for (files) |file| {
            if (sideOf(file) != side) continue;
            const handle = handles[index];
            index += 1;
            const shown_path = try ui.displayText(allocator, shortPath(root, file.local_path, file.depot_path));
            const opened_for = actionWord(file.action);
            const action = if (file.resolve == .unresolved) try std.fmt.allocPrint(allocator, "{s} (unresolved)", .{opened_for}) else opened_for;
            const change = switch (file.change) {
                .default => "default",
                .numbered => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
            };
            try table.setString(handle, "action", action);
            try table.setString(handle, "path", shown_path);
            try table.setString(handle, "depot_path", file.depot_path);
            try table.setString(handle, "local_path", file.local_path);
            try table.setString(handle, "change", change);
            try table.setString(handle, "file_type", file.file_type);
            try table.setString(handle, "unresolved", if (file.resolve == .unresolved) "1" else "");
            try table.setString(handle, "opened_for", opened_for);
        }
    }

    /// The changelists' rows written from `changes`, `shelved_files` the shelved files of
    /// those with some (null when not known).
    fn writeChanges(work: Work, changes: []const p4.Change, shelved_files: ?[]const p4.ShelvedFile) !void {
        const allocator = try work.scratch();
        const handles = try table_view.rowsInOrder(work.changelists, @intCast(changes.len), allocator);
        for (changes, handles) |change, handle| {
            const number = try std.fmt.allocPrint(allocator, "{d}", .{change.number});
            const shelved = try shelvedText(allocator, change, shelved_files);
            const summary = try ui.displayText(allocator, change.summary);
            const user = try ui.displayText(allocator, change.user);
            try work.changelists.setString(handle, "change", number);
            try work.changelists.setString(handle, "description", summary);
            try work.changelists.setString(handle, "shelved", shelved);
            try work.changelists.setString(handle, "full_description", change.description);
            try work.changelists.setString(handle, "user", user);
        }
    }

    /// The recent submitted changes' rows written from `changes`.
    fn writeSubmitted(work: Work, changes: []const p4.Change) !void {
        const allocator = try work.scratch();
        const handles = try table_view.rowsInOrder(work.submitted, @intCast(changes.len), allocator);
        for (changes, handles) |change, handle| {
            const number = try std.fmt.allocPrint(allocator, "{d}", .{change.number});
            const user = try ui.displayText(allocator, change.user);
            const summary = try ui.displayText(allocator, change.summary);
            const date = try dateOf(allocator, change.time);
            try work.submitted.setString(handle, "change", number);
            try work.submitted.setString(handle, "user", user);
            try work.submitted.setString(handle, "date", date);
            try work.submitted.setString(handle, "description", summary);
        }
    }

    /// Publishes what the page shows: the four tables as its sources, and its values. What is
    /// published already as it is, is not written again.
    pub fn publish(work: Work) !void {
        const publishing = try document_sources.Publishing.of(work.pass) orelse return;
        for (std.enums.values(SourceKind)) |kind| {
            publishing.publishSource(publisher, .{ .name = kind.name(), .table = kind.table(), .shown = kind.shown() });
        }
        const allocator = try work.scratch();
        const state = try work.pass.readSingleton(state_table, StateRead);
        const shown_client = try ui.displayText(allocator, state.client);
        publishing.publishValue(publisher, "vcs-p4.client", shown_client);
        const shown_user = try ui.displayText(allocator, state.user);
        publishing.publishValue(publisher, "vcs-p4.user", shown_user);
        const shown_server = try ui.displayText(allocator, state.server);
        publishing.publishValue(publisher, "vcs-p4.server", shown_server);
        publishing.publishValue(publisher, "vcs-p4.note", state.note);
        const default_count = try std.fmt.allocPrint(allocator, "{d}", .{state.default_count.*});
        publishing.publishValue(publisher, "vcs-p4.default-count", default_count);
        const pending_count = try std.fmt.allocPrint(allocator, "{d}", .{state.pending_count.*});
        publishing.publishValue(publisher, "vcs-p4.pending-count", pending_count);
        publishing.publishValue(publisher, "vcs-p4.unlisted", try unlistedOf(allocator, state, work.default_files.count() + work.opened_files.count(), work.changelists.count()));
    }

    /// Forgets everything read of the workspace: another project.
    fn forgetData(work: Work) !void {
        const state = work.state;
        try work.cells.assignString(state.client, "");
        try work.cells.assignString(state.client_root, "");
        try work.cells.assignString(state.user, "");
        try work.cells.assignString(state.server, "");
        try work.cells.assignString(state.note, "");
        state.info_known.* = 0;
        state.answered.* = 0;
        state.notice.* = @intFromEnum(Notice.none);
        state.session_told.* = 0;
        state.default_count.* = 0;
        state.opened_seen.* = 0;
        state.pending_count.* = 0;
        state.unread_records.* = 0;
        document.setCursor(try vcs_page.stateOf(work.pass, status_page), .{});
        work.default_files.clear();
        work.opened_files.clear();
        work.changelists.clear();
        work.submitted.clear();
        work.expanded.clear();
        const folds = try work.pass.writeTable(folds_table);
        folds.clear();
        try p4_diff.forget(work);
        try p4_history.forget(work);
        try work.publish();
    }

    // ---- the cursor across a refresh ------------------------------------------------------------

    /// What the cursor is on, remembered across a refresh that writes the tables again: a file
    /// of the default changelist by its depot path, a changelist's heading or file by the
    /// group's key text and the file's depot path, a submitted change by its number.
    fn cursorKept(work: Work) !KeptAt {
        const allocator = try work.scratch();
        switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| {
                if (row.group) |group| {
                    const file = row.table.getRow(row.row, FileRow) orelse return .none;
                    return .{ .group = .{ .block = group.block, .key_text = try allocator.dupe(u8, group.key_text), .depot_path = try allocator.dupe(u8, file.depot_path) } };
                }
                if (std.mem.eql(u8, row.source, SourceKind.default.name())) {
                    const file = row.table.getRow(row.row, FileRow) orelse return .none;
                    return .{ .default_file = .{ .block = row.key, .depot_path = try allocator.dupe(u8, file.depot_path) } };
                }
                if (std.mem.eql(u8, row.source, SourceKind.submitted.name())) {
                    const change = row.table.getRow(row.row, SubmittedRow) orelse return .none;
                    return .{ .submitted = .{ .block = row.key, .change = try allocator.dupe(u8, change.change) } };
                }
                return .none;
            },
            .group => |group| return .{ .group = .{ .block = group.block, .key_text = try allocator.dupe(u8, group.key_text), .depot_path = "" } },
            .heading, .text, .none => return .none,
        }
    }

    /// The cursor put back on what `kept` named: the same file in the same changelist, else the
    /// changelist's heading; a changelist gone (submitted, deleted) leaves the cursor for the
    /// page's settle, which lands where its heading was, on the next changelist. Wherever the
    /// cursor is then not on what it was on, the page's `MovedUnder` is set, so a key in the same
    /// run acts on nothing.
    fn keepCursor(work: Work, kept: KeptAt) !void {
        const laid_out = try vcs_page.laidOut(work.pass, status_page);
        const state = try vcs_page.stateOf(work.pass, status_page);
        const scroll = document.cursorOf(state).scroll;
        switch (kept) {
            .none => {},
            .default_file => |file| {
                const handle = rowOfFile(work.default_files, file.depot_path, "default") orelse {
                    (try vcs_page.movedUnder(work.pass, status_page)).* = 1;
                    return;
                };
                var placed = document.cursorOnRow(laid_out, file.block, handle);
                placed.scroll = scroll;
                document.setCursor(state, placed);
            },
            .group => |group| {
                const handle: ?Table.RowHandle = if (group.depot_path.len == 0) null else rowOfFile(work.opened_files, group.depot_path, group.key_text);
                // The file left its changelist, or the changelist is gone: what the cursor is on
                // now is not what the person saw there, so a key in this run acts on nothing.
                const file_gone = group.depot_path.len != 0 and handle == null;
                const moved_under = try vcs_page.movedUnder(work.pass, status_page);
                if (file_gone) moved_under.* = 1;
                var placed = document.cursorOnGroup(laid_out, group.block, group.key_text, handle) orelse {
                    moved_under.* = 1;
                    return;
                };
                placed.scroll = scroll;
                document.setCursor(state, placed);
            },
            .submitted => |change| {
                const handle = rowOfChange(work.submitted, change.change) orelse return;
                var placed = document.cursorOnRow(laid_out, change.block, handle);
                placed.scroll = scroll;
                document.setCursor(state, placed);
            },
        }
    }

    // ---- what the cursor is on ------------------------------------------------------------------

    /// The row of a file table the changelists' cursor is on, while they are shown.
    fn statusRowAt(work: Work) !?RowAt {
        if (viewOf(work.state.view.*) != .status) return null;
        return switch (try vcs_page.atCursor(work.pass, status_page)) {
            .row => |row| .{ .table = row.table, .row = row.row },
            .heading, .group, .text, .none => null,
        };
    }

    /// What the cursor is on, as the commands read it: a file (its row's text, good for the run)
    /// and its changelist, a changelist's heading, the default changelist's heading, a submitted
    /// change, or none of these.
    pub fn targetAt(work: Work, at: document.At) !Target {
        const allocator = try work.scratch();
        switch (at) {
            .row => |row| {
                if (std.mem.eql(u8, row.source, SourceKind.submitted.name())) {
                    const change = row.table.getRow(row.row, SubmittedRow) orelse return .none;
                    const number = std.fmt.parseInt(u32, change.change, 10) catch return .none;
                    return .{ .submitted = number };
                }
                const is_file = std.mem.eql(u8, row.source, SourceKind.default.name()) or std.mem.eql(u8, row.source, SourceKind.opened.name());
                if (!is_file) return .none;
                const file = row.table.getRow(row.row, FileRow) orelse return .none;
                const change = changelistOf(file.change) orelse return .none;
                return .{ .file = .{ .file = try copyFile(allocator, file), .change = change } };
            },
            .group => |group| {
                const number = std.fmt.parseInt(u32, group.key_text, 10) catch return .none;
                return .{ .changelist = .{ .numbered = number } };
            },
            .heading => |heading| {
                const source = heading.source orelse return .none;
                if (std.mem.eql(u8, source, SourceKind.default.name())) return .{ .changelist = .default };
                return .none;
            },
            .text, .none => return .none,
        }
    }

    /// What the changelists' cursor is on, unless an answer earlier in the run changed it
    /// (told, and null).
    fn targetAtCursor(work: Work) !?Target {
        if (try vcs_page.changedUnderCursor(work.pass, status_page)) return null;
        const at = try vcs_page.atCursor(work.pass, status_page);
        return try work.targetAt(at);
    }

    /// Whether the lists were not read by the last refresh (their sources marked `unread`), so
    /// the rows a command would act on may be stale: told then.
    pub fn refusedWhileUnread(work: Work) bool {
        if (work.state.lists_unread.* == 0) return false;
        work.tell("The lists could not be read (see the note): g reads them again");
        return true;
    }

    /// How many opened files the last refresh counted that the panel does not list (past
    /// `max_files`).
    pub fn unlistedFiles(work: Work) u32 {
        const listed = work.default_files.count() + work.opened_files.count();
        return work.state.opened_seen.* -| listed;
    }

    /// Whether some opened files are not listed, so a command on a whole changelist could act
    /// on files the panel never showed (`submit -c` submits all of a changelist's): told then.
    fn refusedWhileUnlisted(work: Work) !bool {
        const unlisted = work.unlistedFiles();
        if (unlisted == 0) return false;
        const allocator = try work.scratch();
        const sentence = try std.fmt.allocPrint(allocator, "Not every opened file is listed ({d} are not): do this from a terminal", .{unlisted});
        work.tell(sentence);
        return true;
    }

    /// The files of `change` the panel lists, their rows' text, good for the run.
    pub fn filesOf(work: Work, change: p4.Changelist) ![]FileRow {
        const allocator = try work.scratch();
        var found: std.ArrayList(FileRow) = .empty;
        const table = switch (change) {
            .default => work.default_files,
            .numbered => work.opened_files,
        };
        const key = try changeText(allocator, change);
        var rows = table.readQuery(FileRow);
        while (rows.next()) |row| {
            if (!std.mem.eql(u8, row.view.change, key)) continue;
            try found.append(allocator, try copyFile(allocator, fileRowOf(row.view)));
        }
        return found.items;
    }

    /// The changelist row of `number`; null when the panel lists none.
    pub fn changelistRow(work: Work, number: u32) !?ChangeRow {
        const allocator = try work.scratch();
        const key = try std.fmt.allocPrint(allocator, "{d}", .{number});
        var rows = work.changelists.readQuery(ChangeRow);
        while (rows.next()) |row| {
            if (!std.mem.eql(u8, row.view.change, key)) continue;
            return .{
                .change = try allocator.dupe(u8, row.view.change),
                .description = try allocator.dupe(u8, row.view.description),
                .shelved = try allocator.dupe(u8, row.view.shelved),
                .full_description = try allocator.dupe(u8, row.view.full_description),
                .user = try allocator.dupe(u8, row.view.user),
            };
        }
        return null;
    }

    // ---- RET and the diff panel -----------------------------------------------------------------

    /// `RET` on `at`, or a click on what the cursor is on: a file's diff, or a submitted change,
    /// in the diff panel; anything else does nothing.
    fn visitAt(work: Work, at: document.At) !void {
        switch (try work.targetAt(at)) {
            .file => |file| try p4_diff.show(work, .{ .file = .{ .change = file.change, .depot_path = file.file.depot_path } }),
            .submitted => |number| try p4_diff.show(work, .{ .change = number }),
            .changelist, .none => {},
        }
    }

    /// The person's move took the cursor onto another row: while the diff panel is open, a
    /// file's diff is shown in it.
    fn followFileAtCursor(work: Work) !void {
        if (viewOf(work.state.view.*) != .status) return;
        if (!p4_diff.isOpen(work.pass)) return;
        const at = try vcs_page.atCursor(work.pass, status_page);
        switch (try work.targetAt(at)) {
            .file => |file| try p4_diff.follow(work, .{ .file = .{ .change = file.change, .depot_path = file.file.depot_path } }),
            .submitted, .changelist, .none => {},
        }
    }

    // ---- the commands ---------------------------------------------------------------------------

    /// `s`: the changelist under the cursor submitted, its description written first in the
    /// description buffer; refused, from the panel's rows, for a changelist with no files or with
    /// files waiting for a resolve, and while some opened files are not listed.
    fn submitAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        if (try work.refusedWhileUnlisted()) return;
        const target = try work.targetAtCursor() orelse return;
        const change = changelistOfTarget(target) orelse return work.tell("Put the cursor on a changelist or one of its files to submit it");
        const files = try work.filesOf(change);
        const allocator = try work.scratch();
        const named = try changelistName(allocator, change);
        if (files.len == 0) {
            const sentence = try std.fmt.allocPrint(allocator, "{s} has no files to submit", .{named});
            return work.tell(sentence);
        }
        var unresolved: u32 = 0;
        for (files) |file| {
            if (file.unresolved.len != 0) unresolved += 1;
        }
        if (unresolved != 0) {
            const noun = if (unresolved == 1) "file" else "files";
            const sentence = try std.fmt.allocPrint(allocator, "{s} has {d} {s} waiting for a resolve: R resolves what merges cleanly", .{ named, unresolved, noun });
            return work.tell(sentence);
        }
        const description = switch (change) {
            .default => "",
            .numbered => |number| if (try work.changelistRow(number)) |row| row.full_description else "",
        };
        try p4_change.start(work, .submit, change, description, files);
    }

    /// `e`: the description of the changelist under the cursor, in the description buffer.
    fn describeAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        const target = try work.targetAtCursor() orelse return;
        const change = changelistOfTarget(target) orelse return work.tell("Put the cursor on a changelist to edit its description");
        switch (change) {
            .default => work.tell("The default changelist has no description: N makes a new changelist, s submits it with one"),
            .numbered => |number| {
                const row = try work.changelistRow(number) orelse return work.tell("That changelist is no longer listed: g asks again");
                try p4_change.start(work, .describe, change, row.full_description, &.{});
            },
        }
    }

    /// `m`: the file under the cursor, or every file of the changelist under it, moved to a
    /// changelist chosen in a prompt of the panel's own changelists and `default`; the files
    /// are kept as the prompt opens, so its answer moves exactly those (one `reopen`). A whole
    /// changelist is refused while some opened files are not listed.
    fn moveAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        const target = try work.targetAtCursor() orelse return;
        const allocator = try work.scratch();
        const from: p4.Changelist, const files: []const FileRow = switch (target) {
            .file => |file| .{ file.change, try allocator.dupe(FileRow, &.{file.file}) },
            .changelist => |change| blk: {
                if (try work.refusedWhileUnlisted()) return;
                break :blk .{ change, try work.filesOf(change) };
            },
            .submitted, .none => return work.tell("Put the cursor on a file or a changelist to move it"),
        };
        if (files.len == 0) return work.tell("That changelist has no files to move");
        const paths = try joinedPaths(allocator, files);
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const cells = try work.writeCells(pending_table);
        const title = switch (target) {
            .file => |file| try std.fmt.allocPrint(allocator, "Move {s} to", .{file.file.path}),
            else => blk: {
                const named = try changelistName(allocator, from);
                const noun = if (files.len == 1) "file" else "files";
                break :blk try std.fmt.allocPrint(allocator, "Move the {d} {s} of {s} to", .{ files.len, noun, named });
            },
        };
        const from_text = try changeText(allocator, from);
        row.moving.* = 1;
        row.move_paths.* = .{ .payload = try cells.appendPayload(paths, .@"1") };
        try cells.assignString(row.move_from, from_text);
        try cells.assignString(row.move_title, title);
        try work.presentMoveChoice("", .open);
    }

    /// The prompt of the changelists `m` moves to: `default` and each listed but the one the
    /// files are in, those holding `query`.
    fn presentMoveChoice(work: Work, query: []const u8, prompting: Prompting) !void {
        const memory_now = work.memory();
        const allocator = try action_palette.completionAllocator(memory_now, .vcs);
        if (prompting == .open) action_palette.resetCompletionArena(memory_now, .vcs);
        const read = try work.pass.readSingleton(pending_table, PendingRead);
        const typed = std.mem.trim(u8, query, " ");
        var entries: std.ArrayList(action_palette.Completion) = .empty;
        if (!std.mem.eql(u8, read.move_from, "default") and std.mem.indexOf(u8, "default", typed) != null) {
            try entries.append(allocator, .{ .label = "default", .key = "default", .detail = "the default changelist" });
        }
        var rows = work.changelists.readQuery(ChangeRow);
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.view.change, read.move_from)) continue;
            const description = try ui.displayText(allocator, row.view.description);
            const label = try std.fmt.allocPrint(allocator, "{s}  {s}", .{ row.view.change, description });
            if (std.ascii.indexOfIgnoreCase(label, typed) == null) continue;
            try entries.append(allocator, .{ .label = label, .key = try allocator.dupe(u8, row.view.change) });
        }
        const completions = try allocator.create(action_palette.Completions);
        completions.* = .{
            .owner = prompt_owner,
            .presentation = .prompt,
            .title = try allocator.dupe(u8, read.move_title),
            .initial_query = try allocator.dupe(u8, query),
            .accepts_text = true,
            .entries = entries.items,
        };
        try action_palette.ownRequestText(allocator, completions);
        if (prompting == .narrow) {
            action_palette.request(memory_now, work.tables(), .{ .replace = .{ .completions = completions } });
            return;
        }
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_p4_move_chosen));
        action_palette.request(memory_now, work.tables(), .{ .present = .{ .completions = completions, .reply = reply } });
    }

    /// The move prompt's events: the list narrowed as the text changes; on Enter the files kept
    /// as it opened are moved to the changelist chosen, or typed: `default` or the number of one
    /// the panel lists, nothing else (a refused answer opens the prompt again holding it).
    fn takeMoveChoice(work: Work, received: sequencer.Message) !void {
        const event = try action_palette.eventOf(received);
        if (event.kind == .query_changed) return work.presentMoveChoice(event.query, .narrow);
        action_palette.request(work.memory(), work.tables(), .{ .acknowledge = .{ .owner = prompt_owner } });
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        if (row.moving.* == 0) return;
        if (event.completion != null and work.refusedWhileUnread()) {
            row.moving.* = 0;
            return;
        }
        const chosen = event.completion orelse {
            row.moving.* = 0;
            return;
        };
        const allocator = try work.scratch();
        const typed = std.mem.trim(u8, event.query, " ");
        const answer = try allocator.dupe(u8, if (chosen.key.len != 0) chosen.key else typed);
        if (answer.len == 0) {
            row.moving.* = 0;
            return;
        }
        const into = changelistOf(answer) orelse {
            work.tell("Move to default, or to the number of a pending changelist listed here");
            return work.presentMoveChoice(answer, .open);
        };
        switch (into) {
            .default => {},
            .numbered => |number| if (try work.changelistRow(number) == null) {
                const sentence = try std.fmt.allocPrint(allocator, "Change {d} is no pending changelist of this workspace listed here", .{number});
                work.tell(sentence);
                return work.presentMoveChoice(answer, .open);
            },
        }
        const read = try work.pass.readSingleton(pending_table, PendingRead);
        const paths = try splitPaths(allocator, read.move_paths);
        row.moving.* = 0;
        // What moves is what the prompt named as it opened, only while every one of those files
        // is still in that changelist.
        const from = changelistOf(read.move_from) orelse return;
        const now = try work.filesOf(from);
        for (paths) |path| {
            const still = for (now) |file| {
                if (std.mem.eql(u8, file.depot_path, path)) break true;
            } else false;
            if (!still) return work.tell("It changed meanwhile; m asks again");
        }
        var input_bytes: std.Io.Writer.Allocating = .init(allocator);
        p4.writePaths(&input_bytes.writer, paths, .depot_paths, host_style) catch |err| return work.tellUnpassable(err);
        try work.runCommand(.{ .reopen = into }, input_bytes.written());
    }

    /// `k`: the file under the cursor, or every file of the changelist under it, reverted after
    /// a dialog that names what and how many; its yes reverts only what the dialog named. A
    /// whole changelist is refused while some opened files are not listed.
    fn revertAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        const target = try work.targetAtCursor() orelse return;
        const subject: Subject = switch (target) {
            .file => |file| .{ .change = file.change, .depot_path = file.file.depot_path },
            .changelist => |change| blk: {
                if (try work.refusedWhileUnlisted()) return;
                break :blk .{ .change = change };
            },
            .submitted, .none => return work.tell("Put the cursor on a file or a changelist to revert it"),
        };
        try work.askRevert(subject);
    }

    /// The dialog before `subject`'s files are reverted: what and how many, and that a file
    /// opened for add is left in the workspace (`p4_revert.html`), with a fingerprint of what it
    /// named.
    pub fn askRevert(work: Work, subject: Subject) !void {
        if (work.refusedWithoutWorkspace()) return;
        const allocator = try work.scratch();
        const files = try work.filesOfSubject(subject);
        if (files.len == 0) return work.tell("Nothing to revert here");
        var adds: u32 = 0;
        for (files) |file| {
            if (std.mem.eql(u8, file.opened_for, "add") or std.mem.eql(u8, file.opened_for, "move/add")) adds += 1;
        }
        const named = try changelistName(allocator, subject.change);
        const title = if (subject.depot_path.len != 0)
            try std.fmt.allocPrint(allocator, "Revert {s}?", .{files[0].path})
        else
            try std.fmt.allocPrint(allocator, "Revert the {d} {s} of {s}?", .{ files.len, if (files.len == 1) "file" else "files", named });
        const body = if (adds == 0)
            "Their changes in the workspace are thrown away"
        else
            "Their changes in the workspace are thrown away; a file opened for add is left in the workspace, no longer opened";
        try work.askFirst(.revert, .{ .title = title, .body = body, .confirm = "Revert" }, subject, fingerprintOf(files));
    }

    /// `K`: the unchanged files of the changelist under the cursor reverted (`revert -a`), after
    /// a dialog; refused while some opened files are not listed.
    fn revertUnchangedAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        if (try work.refusedWhileUnlisted()) return;
        const target = try work.targetAtCursor() orelse return;
        const change = changelistOfTarget(target) orelse return work.tell("Put the cursor on a changelist to revert its unchanged files");
        const files = try work.filesOf(change);
        const allocator = try work.scratch();
        const named = try changelistName(allocator, change);
        if (files.len == 0) {
            const sentence = try std.fmt.allocPrint(allocator, "{s} has no files", .{named});
            return work.tell(sentence);
        }
        const title = try std.fmt.allocPrint(allocator, "Revert the unchanged files of {s}?", .{named});
        const body = "Of its files, those not changed since they were opened (and those opened for add and missing) are reverted; the others stay opened";
        try work.askFirst(.revert_unchanged, .{ .title = title, .body = body, .confirm = "Revert unchanged" }, .{ .change = change }, fingerprintOf(files));
    }

    /// `d`: the changelist under the cursor deleted, refused from the panel's rows when it has
    /// files or shelved files, or is the default one.
    fn deleteAtCursor(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        const target = try work.targetAtCursor() orelse return;
        const change = switch (target) {
            .changelist => |change| change,
            .file, .submitted, .none => return work.tell("Put the cursor on a changelist's heading to delete it"),
        };
        const number = switch (change) {
            .default => return work.tell("The default changelist cannot be deleted"),
            .numbered => |number| number,
        };
        const allocator = try work.scratch();
        const files = try work.filesOf(change);
        if (files.len != 0) {
            const noun = if (files.len == 1) "file: m moves it, k reverts it" else "files: m moves them, k reverts them";
            const sentence = try std.fmt.allocPrint(allocator, "Change {d} has {d} {s}", .{ number, files.len, noun });
            return work.tell(sentence);
        }
        const row = try work.changelistRow(number) orelse return work.tell("That changelist is no longer listed: g asks again");
        if (row.shelved.len != 0) {
            const sentence = try std.fmt.allocPrint(allocator, "Change {d} has shelved files: z d deletes the shelf first", .{number});
            return work.tell(sentence);
        }
        try work.runCommand(.{ .delete_change = number }, "");
    }

    /// `z`: the shelve menu of the numbered changelist under the cursor, kept as it opens; the
    /// default changelist cannot be shelved by number.
    fn presentShelveMenu(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        if (work.refusedWhileUnread()) return;
        const target = try work.targetAtCursor() orelse return;
        const change = changelistOfTarget(target) orelse return work.tell("Put the cursor on a changelist to shelve it");
        const number = switch (change) {
            .default => return work.tell("The default changelist cannot be shelved by number: m moves its files to a numbered one, N makes one"),
            .numbered => |number| number,
        };
        const allocator = try work.scratch();
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const cells = try work.writeCells(pending_table);
        const number_text = try std.fmt.allocPrint(allocator, "{d}", .{number});
        try cells.assignString(row.shelf_change, number_text);
        work.presentMenu(&shelve_menu, .vcs_p4_shelve_chosen);
    }

    /// What the shelve menu chose, for the changelist kept as it opened; deleting the shelf
    /// asks first.
    fn chooseShelve(work: Work, item: ShelveItem) !void {
        const read = try work.pass.readSingleton(pending_table, PendingRead);
        const number = std.fmt.parseInt(u32, read.shelf_change, 10) catch return;
        switch (item) {
            .shelve => try work.runCommand(.{ .shelve = .{ .change = number } }, ""),
            .replace => try work.runCommand(.{ .shelve = .{ .change = number, .action = .replace } }, ""),
            .unshelve => try work.runCommand(.{ .unshelve = .{ .from = number, .into = .{ .numbered = number } } }, ""),
            .discard => {
                const allocator = try work.scratch();
                const title = try std.fmt.allocPrint(allocator, "Delete the shelf of change {d}?", .{number});
                try work.askFirst(.discard_shelf, .{ .title = title, .body = "Its shelved files are deleted from the server; the files opened in the workspace stay", .confirm = "Delete shelf" }, .{ .change = .{ .numbered = number } }, 0);
            },
        }
    }

    /// `R`: what merges cleanly resolved (`resolve -am`); the refresh after tells what is left.
    fn resolve(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        try work.runCommand(.resolve, "");
        work.state.tell_unresolved.* = 1;
    }

    /// `r`: what changed under the project's directory without being opened, shown first
    /// (`reconcile -n`, in the runner's log view); a dialog then offers to open it into the
    /// changelist under the cursor (the default one off a changelist).
    fn reconcilePreview(work: Work) !void {
        if (work.refusedWithoutWorkspace()) return;
        const target = try work.targetAtCursor() orelse return;
        const into = changelistOfTarget(target) orelse .default;
        const allocator = try work.scratch();
        const path = try projectPath(allocator, work.cells.textOf(work.state.working_directory.*)) orelse return work.tellUnpassable(error.UnpassableArgument);
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const cells = try work.writeCells(pending_table);
        const into_text = try changeText(allocator, into);
        // Its own field: a dialog asked while the preview runs does not change where it opens.
        try cells.assignString(row.reconcile_change, into_text);
        try work.runCommand(.{ .reconcile = .{ .mode = .preview, .path = path } }, "");
    }

    /// `a`'s menu chose what to open the visited buffer's file for, into the changelist under
    /// the cursor; a delete asks first.
    fn chooseOpen(work: Work, item: OpenItem) !void {
        if (work.refusedWithoutWorkspace()) return;
        const file = visitedFile(work.pass);
        if (file.len == 0) return work.tell("No file is visited: open one in a text window first");
        const target = try work.targetAtCursor() orelse return;
        const into = changelistOfTarget(target) orelse .default;
        const allocator = try work.scratch();
        const path = try allocator.dupe(u8, file);
        const action: p4.OpenAction = switch (item) {
            .edit => .edit,
            .add => .add,
            .delete => {
                const shown = try ui.displayText(allocator, path);
                const title = try std.fmt.allocPrint(allocator, "Open {s} for delete?", .{shown});
                const row = try work.pass.writeSingleton(pending_table, PendingRow);
                const cells = try work.writeCells(pending_table);
                row.subject_paths.* = .{ .payload = try cells.appendPayload(path, .@"1") };
                return work.askFirst(.open_delete, .{ .title = title, .body = "p4 delete removes the file from the workspace now; submitting the changelist deletes it from the depot", .confirm = "Delete" }, .{ .change = into }, 0);
            },
        };
        try work.openFile(action, into, path);
    }

    /// One `edit`, `add -f` or `delete` of `path`, a local path, into `into`.
    fn openFile(work: Work, action: p4.OpenAction, into: p4.Changelist, path: []const u8) !void {
        const allocator = try work.scratch();
        const command: p4.Command = .{ .open = .{ .action = action, .into = into } };
        var input_bytes: std.Io.Writer.Allocating = .init(allocator);
        p4.writePaths(&input_bytes.writer, &.{path}, p4.inputOf(command), host_style) catch |err| return work.tellUnpassable(err);
        try work.runCommand(command, input_bytes.written());
    }

    // ---- dialogs --------------------------------------------------------------------------------

    /// The files `subject` names, as the panel lists them now: one file, or every file of a
    /// changelist.
    pub fn filesOfSubject(work: Work, subject: Subject) ![]FileRow {
        const files = try work.filesOf(subject.change);
        if (subject.depot_path.len == 0) return files;
        for (files) |file| {
            if (std.mem.eql(u8, file.depot_path, subject.depot_path)) {
                const allocator = try work.scratch();
                return allocator.dupe(FileRow, &.{file});
            }
        }
        return &.{};
    }

    /// Asks `question` before `confirm` runs on `subject`, kept with the dialog: its yes runs
    /// on what the panel lists then, and only when that is what `fingerprint` names (0: nothing
    /// to compare).
    pub fn askFirst(work: Work, confirm: Confirm, question: vcs_ask.Question, subject: Subject, fingerprint: u64) !void {
        const allocator = try work.scratch();
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const cells = try work.writeCells(pending_table);
        try cells.assignString(row.subject_change, try changeText(allocator, subject.change));
        if (subject.depot_path.len != 0 or confirm != .open_delete) {
            const depot_path = try allocator.dupe(u8, subject.depot_path);
            row.subject_paths.* = .{ .payload = try cells.appendPayload(depot_path, .@"1") };
        }
        row.confirm.* = @intFromEnum(confirm);
        row.confirm_serial.* +%= 1;
        const asked: ConfirmAsked = .{ .confirm = @intFromEnum(confirm), .serial = row.confirm_serial.*, .fingerprint = fingerprint };
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_p4_confirm)).with(.of(&asked));
        try vcs_ask.presentDialog(work.memory(), work.tables(), prompt_owner, question, reply);
    }

    /// A dialog's answer: its yes, to the dialog asked last, runs what it asked about, once what
    /// the panel lists is still what it named; anything else runs nothing.
    fn takeConfirm(work: Work, received: sequencer.Message) !void {
        const event = try action_palette.eventOf(received);
        if (event.kind != .completed) return;
        action_palette.request(work.memory(), work.tables(), .{ .acknowledge = .{ .owner = prompt_owner } });
        const asked = (try received.userDataAs(ConfirmAsked)).*;
        const row = try work.pass.writeSingleton(pending_table, PendingRow);
        const latest = asked.serial == row.confirm_serial.* and asked.confirm == row.confirm.*;
        if (!latest) return;
        row.confirm.* = @intFromEnum(Confirm.none);
        if (!vcs_ask.confirmed(event.completion)) return;
        const read = try work.pass.readSingleton(pending_table, PendingRead);
        const allocator = try work.scratch();
        const change = changelistOf(read.subject_change) orelse return;
        const subject_path = try allocator.dupe(u8, read.subject_paths);
        const confirm = std.enums.fromInt(Confirm, asked.confirm) orelse return;
        switch (confirm) {
            .none => {},
            .revert, .revert_unchanged => {
                const subject: Subject = .{ .change = change, .depot_path = if (confirm == .revert) subject_path else "" };
                const files = try work.filesOfSubject(subject);
                if (files.len == 0) return work.tell("It is no longer there");
                if (fingerprintOf(files) != asked.fingerprint) return work.tell("It changed meanwhile; k asks again");
                try work.revertFiles(files, confirm);
            },
            .discard_shelf => {
                const number = switch (change) {
                    .default => return,
                    .numbered => |number| number,
                };
                try work.runCommand(.{ .shelve = .{ .change = number, .action = .discard } }, "");
            },
            .open_delete => try work.openFile(.delete, change, subject_path),
            .reconcile => {
                const path = try projectPath(allocator, work.cells.textOf(work.state.working_directory.*)) orelse return work.tellUnpassable(error.UnpassableArgument);
                try work.runCommand(.{ .reconcile = .{ .mode = .open, .into = change, .path = path } }, "");
            },
        }
    }

    /// One `revert` (or, for `K`, `revert -a`) of `files`, their depot paths on its input.
    pub fn revertFiles(work: Work, files: []const FileRow, which: Confirm) !void {
        const allocator = try work.scratch();
        const paths = try allocator.alloc([]const u8, files.len);
        for (paths, files) |*path, file| path.* = file.depot_path;
        var input_bytes: std.Io.Writer.Allocating = .init(allocator);
        p4.writePaths(&input_bytes.writer, paths, .depot_paths, host_style) catch |err| return work.tellUnpassable(err);
        const command: p4.Command = if (which == .revert_unchanged) .revert_unchanged else .revert;
        try work.runCommand(command, input_bytes.written());
    }

    // ---- a command's end ------------------------------------------------------------------------

    /// A command's answer: a failure is told; the description buffer's commands are its to take
    /// up (the next of a submit's programs is queued there); a reconcile's preview offers to
    /// open what it found; and the end of the last command queued refreshes.
    fn takeCommandEnd(work: Work, data: JobData, finished: runner.Finished, said: ?runner.Output) !void {
        const state = work.state;
        state.commands_running.* -|= 1;
        const name = std.enums.fromInt(CommandName, data.command) orelse .none;
        const succeeded = runner.ranWell(finished, said);
        const answer: ?[]const u8 = if (succeeded) said.?.said else null;
        const handled = try p4_change.commandEnded(work, name, answer);
        if (!succeeded and !handled) {
            const allocator = try work.scratch();
            const sentence = try std.fmt.allocPrint(allocator, "p4 {s} failed; $ shows why", .{name.subcommand()});
            work.tell(sentence);
        }
        switch (name) {
            .sync_preview => if (succeeded) {
                work.tell("p4 sync -n: $ shows what a sync would do");
                try work.showProcessLog();
            },
            .reconcile_preview => if (succeeded) try work.offerReconcile(answer.?),
            .resolve => if (!succeeded) {
                state.tell_unresolved.* = 0;
            },
            else => {},
        }
        if (state.commands_running.* != 0) return;
        try work.refresh();
    }

    /// `reconcile -n` ended well: what it found is in the runner's log view, shown, and a dialog
    /// offers to open it into the changelist kept as `r` was pressed.
    fn offerReconcile(work: Work, said: []const u8) !void {
        try work.showProcessLog();
        const found = std.mem.trim(u8, said, " \t\r\n").len != 0;
        if (!found) return work.tell("p4 reconcile -n found nothing changed without being opened");
        const read = try work.pass.readSingleton(pending_table, PendingRead);
        const change = changelistOf(read.reconcile_change) orelse .default;
        const allocator = try work.scratch();
        const named = try changelistName(allocator, change);
        const title = try std.fmt.allocPrint(allocator, "Open what p4 reconcile found into {s}?", .{named});
        try work.askFirst(.reconcile, .{ .title = title, .body = "$ shows the files: each is opened for edit, add or delete as reconcile found it", .confirm = "Open" }, .{ .change = change }, 0);
    }
};

/// The changelist `target` is in: a changelist's heading's, or a file's; null for anything else.
fn changelistOfTarget(target: Target) ?p4.Changelist {
    return switch (target) {
        .changelist => |change| change,
        .file => |file| file.change,
        .submitted, .none => null,
    };
}

/// What a refresh's phase byte reads as.
fn viewOfPhase(byte: u8) Phase {
    return std.enums.fromInt(Phase, byte) orelse .idle;
}

/// A job as `Work.queue` takes it: its slices are copied as it is queued.
const Queued = struct {
    purpose: Purpose,
    command: CommandName = .none,
    argv: []const u8,
    input: []const u8 = "",
    environment: []const u8 = "",
    order: runner.Order = .shared,
    epoch: u32 = 0,
};

/// Whether a refresh wrote the lists (`read`) or ended without them.
pub const ListsRead = enum { read, unread };

/// What the cursor was on before a refresh (`Work.cursorKept`), in the frame's memory.
const KeptAt = union(enum) {
    none,
    default_file: struct { block: u64, depot_path: []const u8 },
    group: struct { block: u64, key_text: []const u8, depot_path: []const u8 },
    submitted: struct { block: u64, change: []const u8 },
};

/// What a command reads off the cursor (`Work.targetAt`).
pub const Target = union(enum) {
    none,
    /// A file's row: its text (good for the run) and its changelist.
    file: struct { file: FileRow, change: p4.Changelist },
    /// A changelist's heading, or the default changelist's.
    changelist: p4.Changelist,
    /// A submitted change's row, by its number.
    submitted: u32,
};

/// What a dialog asks about: a changelist, and one file of it by its depot path, or none for
/// every file.
pub const Subject = struct {
    change: p4.Changelist,
    depot_path: []const u8 = "",
};

/// Which dialog is asked.
pub const Confirm = enum(u8) {
    none,
    revert,
    revert_unchanged,
    discard_shelf,
    open_delete,
    reconcile,
};

/// A dialog's user data: what it asks, which time, and what it named.
pub const ConfirmAsked = extern struct {
    /// A `Confirm`.
    confirm: u8,
    reserved: [3]u8 = @splat(0),
    /// `PendingRow.confirm_serial` as it was asked.
    serial: u32,
    /// `fingerprintOf` the files it named; 0 when it names none.
    fingerprint: u64,
};

/// The row of `editor_vcs_p4_pending`.
pub const PendingRow = struct {
    /// A `Confirm`: the dialog asked last.
    confirm: *u8,
    /// Counts the dialogs asked: only the latest one's yes runs.
    confirm_serial: *u32,
    /// The changelist a dialog, or a reconcile's preview, is about, as text.
    subject_change: *Table.String,
    /// The file a dialog is about: a depot path, or for `a d` the local path; empty for a
    /// changelist's files.
    subject_paths: *Table.Bytes,
    /// 1 while the move prompt is open.
    moving: *u8,
    /// The depot paths `m` moves, a line each, kept as its prompt opened.
    move_paths: *Table.Bytes,
    /// The changelist they are in, as text.
    move_from: *Table.String,
    /// The changelist the shelve menu was opened on.
    shelf_change: *Table.String,
    /// What the move prompt's title says moves, as it opened.
    move_title: *Table.String,
    /// The changelist `r` opens what reconcile found into, kept apart from a dialog's subject.
    reconcile_change: *Table.String,
};

/// `PendingRow` read, its text as slices of the table's.
const PendingRead = struct {
    confirm: *u8,
    confirm_serial: *u32,
    subject_change: []const u8,
    subject_paths: []const u8,
    moving: *u8,
    move_paths: []const u8,
    move_from: []const u8,
    shelf_change: []const u8,
    move_title: []const u8,
    reconcile_change: []const u8,
};

/// Whether the move prompt opens or narrows what it lists to what is typed.
const Prompting = enum { open, narrow };

/// A file table's row read by a query, as a `FileRow`: its text the table's.
fn fileRowOf(read: Table.ReadView(FileRow)) FileRow {
    return .{ .action = read.action, .path = read.path, .depot_path = read.depot_path, .local_path = read.local_path, .change = read.change, .file_type = read.file_type, .unresolved = read.unresolved, .opened_for = read.opened_for };
}

/// `file` with its text copied into `allocator`.
fn copyFile(allocator: std.mem.Allocator, file: FileRow) !FileRow {
    return .{
        .action = try allocator.dupe(u8, file.action),
        .path = try allocator.dupe(u8, file.path),
        .depot_path = try allocator.dupe(u8, file.depot_path),
        .local_path = try allocator.dupe(u8, file.local_path),
        .change = try allocator.dupe(u8, file.change),
        .file_type = try allocator.dupe(u8, file.file_type),
        .unresolved = try allocator.dupe(u8, file.unresolved),
        .opened_for = try allocator.dupe(u8, file.opened_for),
    };
}

/// The row of `table`, a file table, holding `depot_path` in changelist `change`; null for none.
fn rowOfFile(table: *Table, depot_path: []const u8, change: []const u8) ?Table.RowHandle {
    var rows = table.readQuery(FileRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.depot_path, depot_path) and std.mem.eql(u8, row.view.change, change)) return row.handle;
    }
    return null;
}

fn rowOfChange(table: *Table, change: []const u8) ?Table.RowHandle {
    var rows = table.readQuery(SubmittedRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.change, change)) return row.handle;
    }
    return null;
}

/// Which table an opened file goes in.
fn sideOf(file: p4.Opened) Work.FileSide {
    return switch (file.change) {
        .default => .default,
        .numbered => .numbered,
    };
}

/// `default` or a number as a changelist; null for anything else.
pub fn changelistOf(text: []const u8) ?p4.Changelist {
    if (std.mem.eql(u8, text, "default")) return .default;
    const number = std.fmt.parseInt(u32, text, 10) catch return null;
    return .{ .numbered = number };
}

/// A changelist as the tables write it: `default`, or its number.
pub fn changeText(allocator: std.mem.Allocator, change: p4.Changelist) ![]const u8 {
    return switch (change) {
        .default => "default",
        .numbered => |number| std.fmt.allocPrint(allocator, "{d}", .{number}),
    };
}

/// A changelist as a sentence names it.
pub fn changelistName(allocator: std.mem.Allocator, change: p4.Changelist) ![]const u8 {
    return switch (change) {
        .default => "the default changelist",
        .numbered => |number| std.fmt.allocPrint(allocator, "change {d}", .{number}),
    };
}

/// What a file is opened for, as `p4` names it.
fn actionWord(action: p4.FileAction) []const u8 {
    return switch (action) {
        .add => "add",
        .edit => "edit",
        .delete => "delete",
        .branch => "branch",
        .move_add => "move/add",
        .move_delete => "move/delete",
        .integrate => "integrate",
        .import => "import",
        .purge => "purge",
        .archive => "archive",
        .other => "other",
    };
}

/// A file's path as the page shows it: from the workspace's root when it is under it, else its
/// depot path.
pub fn shortPath(root: []const u8, local_path: []const u8, depot_path: []const u8) []const u8 {
    if (root.len == 0 or local_path.len <= root.len) return depot_path;
    if (!std.mem.startsWith(u8, local_path, root)) return depot_path;
    const rest = local_path[root.len..];
    if (std.mem.endsWith(u8, root, "/")) return rest;
    if (rest[0] != '/') return depot_path;
    return rest[1..];
}

/// `2 shelved` for a changelist with shelved files, `shelved` when how many is not known; empty
/// for one with none.
fn shelvedText(allocator: std.mem.Allocator, change: p4.Change, shelved_files: ?[]const p4.ShelvedFile) ![]const u8 {
    if (change.status != .shelved) return "";
    const files = shelved_files orelse return "shelved";
    var count: u32 = 0;
    for (files) |file| {
        if (file.change == change.number) count += 1;
    }
    if (count == 0) return "shelved";
    return std.fmt.allocPrint(allocator, "{d} shelved", .{count});
}

/// The numbers of the changelists `read`'s lists say have shelved files.
fn shelvedNumbers(allocator: std.mem.Allocator, read: StateRead) ![]u32 {
    const shelved_room = try allocator.alloc(p4.Change, max_changelists);
    const shelved = p4.parseChanges(read.shelved_said, shelved_room);
    const pending_room = try allocator.alloc(p4.Change, max_changelists);
    const pending = p4.parseChanges(read.pending_said, pending_room);
    const merged = p4.mergeShelved(pending_room, pending.records, shelved_room[0..shelved.records.kept]);
    var numbers: std.ArrayList(u32) = .empty;
    for (pending_room[0..merged.kept]) |change| {
        if (change.status == .shelved) try numbers.append(allocator, change.number);
    }
    return numbers.items;
}

/// `seconds` since 1970 as `YYYY-MM-DD` in UTC; empty for 0: the changelists' dates and the
/// history's.
pub fn dateOf(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds <= 0) return "";
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

/// What the page says of the files and changelists `p4` listed that the panel does not, and of
/// the records it could not read; empty when there is nothing to say.
fn unlistedOf(allocator: std.mem.Allocator, state: StateRead, files_listed: u32, changelists_listed: u32) ![]const u8 {
    var said: std.Io.Writer.Allocating = .init(allocator);
    if (state.opened_seen.* > files_listed) {
        try said.writer.print("{d} opened files are not listed (the panel lists at most {d})", .{ state.opened_seen.* - files_listed, max_files });
    }
    if (state.pending_count.* > changelists_listed) {
        if (said.written().len != 0) try said.writer.writeAll("; ");
        try said.writer.print("{d} changelists are not listed (the panel lists at most {d})", .{ state.pending_count.* - changelists_listed, max_changelists });
    }
    if (state.unread_records.* != 0) {
        if (said.written().len != 0) try said.writer.writeAll("; ");
        const noun = if (state.unread_records.* == 1) "record" else "records";
        try said.writer.print("{d} {s} of what p4 said could not be read ($ shows it)", .{ state.unread_records.*, noun });
    }
    return said.written();
}

/// The depot paths of `files`, a line each.
fn joinedPaths(allocator: std.mem.Allocator, files: []const FileRow) ![]const u8 {
    var joined: std.Io.Writer.Allocating = .init(allocator);
    for (files) |file| {
        try joined.writer.writeAll(file.depot_path);
        try joined.writer.writeByte('\n');
    }
    return joined.written();
}

/// `joined`'s lines, as `joinedPaths` wrote them.
fn splitPaths(allocator: std.mem.Allocator, joined: []const u8) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, joined, '\n');
    while (lines.next()) |line| try paths.append(allocator, try allocator.dupe(u8, line));
    return paths.items;
}

/// Whether `errors`, what `fstat` wrote to its errors, is empty or every line of it the warning
/// `file(s) not opened on this client.` (`MsgDm::ExOPENCLIENT`), read without regard to case.
fn notOpenedWarningOnly(errors: []const u8) bool {
    var lines = std.mem.splitScalar(u8, errors, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // The warning beside another error is a failure.
        if (std.ascii.indexOfIgnoreCase(line, "not opened on this client") == null) return false;
    }
    return true;
}

/// A hash of what a submit submits, as `s` saw it: each file's depot path, what it is opened
/// for, whether it waits for a resolve and its type, sorted by depot path, so a file reopened for another
/// action changes it and the server's order of rows does not. Never 0.
pub fn submitFingerprint(allocator: std.mem.Allocator, files: []const FileRow) !u64 {
    const sorted = try allocator.dupe(FileRow, files);
    const byPath = struct {
        fn lessThan(_: void, a: FileRow, b: FileRow) bool {
            return std.mem.lessThan(u8, a.depot_path, b.depot_path);
        }
    }.lessThan;
    std.mem.sort(FileRow, sorted, {}, byPath);
    var hasher = std.hash.Wyhash.init(0);
    for (sorted) |file| {
        hasher.update(file.depot_path);
        hasher.update("\x00");
        hasher.update(file.opened_for);
        hasher.update("\x00");
        hasher.update(file.unresolved);
        hasher.update("\x00");
        hasher.update(file.file_type);
        hasher.update("\x00");
    }
    const hashed = hasher.final();
    return if (hashed == 0) 1 else hashed;
}

/// A hash of the depot paths of `files`, in order: what a dialog named. Never 0.
pub fn fingerprintOf(files: []const FileRow) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (files) |file| {
        hasher.update(file.depot_path);
        hasher.update("\x00");
    }
    const hashed = hasher.final();
    return if (hashed == 0) 1 else hashed;
}

/// The project's directory as a file specification `reconcile` takes: the working directory and
/// `...`, in the host's local syntax; null for a directory `p4` cannot be given.
fn projectPath(allocator: std.mem.Allocator, working_directory: []const u8) !?[]const u8 {
    // The directory written as a local path is (`p4.writePaths`: `@ # * %` encoded, so a name
    // holding one is no revision specifier, and the host's separators), then `...`.
    const trimmed = std.mem.trimEnd(u8, working_directory, "/");
    var encoded: std.Io.Writer.Allocating = .init(allocator);
    p4.writePaths(&encoded.writer, &.{trimmed}, .local_paths, host_style) catch |err| switch (err) {
        error.UnpassableArgument => return null,
        error.WriteFailed => return error.OutOfMemory,
    };
    const directory = std.mem.trimEnd(u8, encoded.written(), "\n");
    const separator_text: []const u8 = if (host_style == .windows) "\\" else "/";
    return try std.fmt.allocPrint(allocator, "{s}{s}...", .{ directory, separator_text });
}

/// The file the newest text window in the panels' focus history shows, by its absolute path;
/// empty when none shows a file. What `a` opens.
fn visitedFile(pass: *const sequencer.Pass) []const u8 {
    if (!pass.declares(focus_history_table) or !pass.declares(text_windows_table) or !pass.declares(buffers_table)) return "";
    const history = pass.rows(focus_history_table, struct { panel: *Atom }) catch return "";
    var newest: ?Atom = null;
    var entries = history.read();
    while (entries.next()) |entry| {
        if (text_panel.isPanel(entry.view.panel.*)) newest = entry.view.panel.*;
    }
    const window = newest orelse return "";
    const windows = pass.rows(text_windows_table, text_panel.WindowBufferRow) catch return "";
    const buffers = pass.rows(buffers_table, text_editor.BufferEntry) catch return "";
    return text_panel.windowFile(windows.read(), buffers.read(), window);
}

test "vcs p4: a path under the workspace's root is shown from it, any other by its depot path" {
    try std.testing.expectEqualStrings("src/a.c", shortPath("/ws", "/ws/src/a.c", "//depot/a.c"));
    try std.testing.expectEqualStrings("src/a.c", shortPath("/ws/", "/ws/src/a.c", "//depot/a.c"));
    try std.testing.expectEqualStrings("//depot/a.c", shortPath("/ws", "/wsx/a.c", "//depot/a.c"));
    try std.testing.expectEqualStrings("//depot/a.c", shortPath("", "/ws/a.c", "//depot/a.c"));
}
