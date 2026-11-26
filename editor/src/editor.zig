const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const sequencer = mesha.sequencer;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const input = mesha.input;
const resources = mesha.resources;
const style = @import("ui/style.zig");
const roop = mesha.roop;
const keybinds = mesha.keybinds;
const text_editor = @import("text_editor.zig");
const fixed_panels = @import("fixed_panels.zig");
const modes = @import("modes.zig");
pub const inspector = @import("inspector.zig");
const panel_frame = @import("panel_frame.zig");
pub const figure_workspace = @import("figure/workspace.zig");
pub const table_view = @import("table_view.zig");
pub const windows = @import("windows.zig");
pub const action_palette = @import("action_palette.zig");
pub const status_bar = @import("status_bar.zig");
pub const profiler = @import("profiler/profiler.zig");
pub const text_panel = @import("text_panel.zig");
pub const open = @import("open.zig");
pub const vcs_git = @import("vcs/git_status.zig");
pub const vcs_p4 = @import("vcs/p4_status.zig");
pub const text_tools = @import("text_tools.zig");
pub const plugins = @import("plugins.zig");
pub const plugin_list = @import("plugin_list.zig");
pub const transient = @import("transient.zig");
const editor_sequencer = @import("editor_sequencer.zig");
pub const authoring = @import("table_authoring.zig");
pub const state = @import("state.zig");
const git_log = @import("vcs/git_log.zig");
const git_rebase = @import("vcs/git_rebase.zig");
const git_diff = @import("vcs/git_diff.zig");
const git_commit = @import("vcs/git_commit.zig");
const p4_history = @import("vcs/p4_history.zig");
const p4_diff = @import("vcs/p4_diff.zig");
const p4_change = @import("vcs/p4_change.zig");
const stage_mod = @import("stage.zig");
const context_menu = @import("figure/context_menu.zig");
const motion = @import("figure/motion.zig");
const chrome = @import("figure/chrome.zig");
const canvas = @import("figure/canvas.zig");
const color_picker = @import("figure/color_picker.zig");
const panels = @import("figure/panels.zig");
const git_status_view = @import("vcs/git_status_view.zig");
const p4_status_view = @import("vcs/p4_status_view.zig");
const tests = @import("tests.zig");
const Log = mesha.log.scope("editor");
const panels_mod = mesha.panels;

/// This file's profile zones, in its log scope.
const Zone = enum { render_canvas };

/// The editor as a whole: its focus, action palette and prompts. A panel draws
/// again when systems under its root change a table; no panel has this root, so the editor's
/// own systems draw none, and what they change in a module's panel reaches that module as a
/// message of its own.
pub const editor_root = Atom.from("editor");
pub const kActionListOwner: Atom = Atom.from("editor.action_list");

pub const kHitDepth: u32 = 100;
/// Above stage chrome, for the figure's context menu.
const kModalDepth: u32 = kHitDepth + 2;

pub fn actionListOpen(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return action_palette.currentOwner(tables, atoms) == kActionListOwner;
}

const action_list_placeholder = "Search actions";

fn makeActionListRequest(memory: *memory_mod.Memory) ?*const action_palette.Completions {
    const allocator = action_palette.completionAllocator(memory, .action_list) catch return null;
    action_palette.resetCompletionArena(memory, .action_list);
    const completions = allocator.create(action_palette.Completions) catch return null;
    completions.* = .{
        .owner = kActionListOwner,
        .presentation = .prompt,
        .title = action_list_placeholder,
        .entries = &.{},
    };
    action_palette.ownRequestText(allocator, completions) catch return null;
    return completions;
}

fn queueActionListRequest(memory: *memory_mod.Memory, tables: *Table.Registry) void {
    const completions = makeActionListRequest(memory) orelse return;
    const reply = sequencer.ReplyTo.of(messagesSystem(), action_selected_tag);
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// Whether a click may move the focus, and where the keyboard is when it may not: the editor's
/// record of it (`state.ViewFocusView.focus_clicks_disabled`) keeps its value.
const FocusClicks = enum(u8) {
    /// A click focuses the panel under it.
    enabled = 0,
    /// Suspended for a field in the focused panel: an inline prompt or a form.
    field = 1,
    /// Suspended for the minibuffer, which has the keyboard.
    minibuffer = 2,
};

fn focusClicksWanted(tables: *Table.Registry, atoms: *Atom.Registry) FocusClicks {
    if (action_palette.minibufferHasKeyboard(tables, atoms)) return .minibuffer;
    if (action_palette.requestOpen(tables, atoms) or windows.isFormEditing(tables, atoms)) return .field;
    return .enabled;
}

/// Tells the panels whether a click may move the focus, and where the keyboard is.
fn requestFocusClicks(tables: *Table.Registry, wanted: FocusClicks) !void {
    const request: plugin.panels.CmdPayload = switch (wanted) {
        .enabled => .enable_focus_clicks,
        .field => .{ .disable_focus_clicks = .{ .keyboard = .focused_panel } },
        .minibuffer => .{ .disable_focus_clicks = .{ .keyboard = .outside_panels } },
    };
    const requests = plugin.panels.Requests.of(tables.memory, tables, plugin.panels.commands_table_name);
    try requests.tryPush(request);
}

/// The focus clicks the editor last told the panels, as it recorded them.
fn recordedFocusClicks(focus: state.ViewFocusView) FocusClicks {
    return std.enums.fromInt(FocusClicks, focus.focus_clicks_disabled.*) orelse .field;
}

pub fn initializeFocusClicks(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const wanted = focusClicksWanted(tables, atoms);
    state.viewFocus(tables, atoms).focus_clicks_disabled.* = @intFromEnum(wanted);
    requestFocusClicks(tables, wanted) catch |err| Log.err("focus_clicks_request_failed", .{ .@"error" = @errorName(err) });
}

pub fn syncFocusClicks(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const focus = state.viewFocus(tables, atoms);
    const wanted = focusClicksWanted(tables, atoms);
    if (recordedFocusClicks(focus) == wanted) return;
    // Recorded only once appended, so a refused request is tried again by the next sync.
    requestFocusClicks(tables, wanted) catch return;
    focus.focus_clicks_disabled.* = @intFromEnum(wanted);
}

/// The editor's command hook: a palette command is the palette's; an answer one of the editor's
/// systems gives another is delivered, or kept to deliver again while its inbox cannot take it.
pub fn processCmd(tables: *Table.Registry, atoms: *Atom.Registry, payload: *plugin.app_commands.Payload) sequencer.Applied {
    switch (payload.*) {
        .action_palette => |*command| return action_palette.processCmd(tables, atoms, command),
        .answer => |answering| {
            const inboxes: sequencer.Inboxes = .{ .memory = tables.memory, .tables = tables };
            inboxes.tryAnswerBytes(answering.reply, answering.payload) catch |err| {
                // An inbox that is not there will not be: its system is gone.
                if (err == error.MissingInbox) {
                    Log.warn("answer_dropped", .{ .inbox = answering.reply.inbox, .tag = answering.reply.tag });
                    return .done;
                }
                return .retry;
            };
            return .done;
        },
    }
}

const action_palette_toggle_tag = Atom.from("action_palette_toggle");

const pause_toggle_tag: Atom = Atom.from("pause_toggle");
const close_tag: Atom = Atom.from("close");
const quit_tag: Atom = Atom.from("quit");
const debug_toggle_tag: Atom = Atom.from("debug_toggle");
const volume_up_tag: Atom = Atom.from("volume_up");
const volume_down_tag: Atom = Atom.from("volume_down");
const subtitles_toggle_tag: Atom = Atom.from("subtitles_toggle");

pub const editor_actions = [_]plugin.action_api.Def{
    .{ .name = "create_tracker", .tag = "create_tracker", .doc = "Create a runtime tracker" },
    .{ .name = "delete_tracker", .tag = "delete_tracker", .doc = "Delete the focused tracker" },
    .{ .name = "picker_toggle", .tag = "picker_toggle", .doc = "Open the table picker" },
    .{ .name = "action_palette_toggle", .tag = "action_palette_toggle", .doc = "Search actions" },

    .{ .name = "window_close", .tag = "window_close", .doc = "Close the focused panel" },

    .{ .name = "add", .tag = "ctx_add", .doc = "Add row / metadata entry (context)" },
    .{ .name = "delete", .tag = "ctx_delete", .doc = "Delete row / metadata entry (context)" },
    .{ .name = "edit", .tag = "ctx_edit", .doc = "Edit selected metadata entry (context)" },
    .{ .name = "save", .tag = "save", .doc = "Save the focused table" },
    .{ .name = "row_add", .tag = "row_add", .doc = "Add a row to the focused table" },
    .{ .name = "row_delete", .tag = "row_delete", .doc = "Delete the selected row" },
    .{ .name = "schema_toggle", .tag = "schema_toggle", .doc = "Toggle the schema drawer" },
    .{ .name = "metadata_toggle", .tag = "metadata_toggle", .doc = "Toggle the metadata drawer" },
    .{ .name = "save", .tag = "form_save", .doc = "Commit the open form" },
    .{ .name = "cancel", .tag = "form_cancel", .doc = "Cancel the open form" },
    .{ .name = "meta_add", .tag = "meta_add", .doc = "Add a metadata entry" },
    .{ .name = "meta_edit", .tag = "meta_edit", .doc = "Edit the selected metadata entry" },
    .{ .name = "meta_delete", .tag = "meta_delete", .doc = "Delete the selected metadata entry" },
    .{ .name = "meta_save", .tag = "meta_save", .doc = "Commit the metadata form" },
    .{ .name = "meta_cancel_edit", .tag = "meta_cancel_edit", .doc = "Cancel the metadata form" },
    .{ .name = "cancel", .tag = "cancel", .doc = "Cancel editing" },
} ++ figure_workspace.actions ++ fixed_panels.actions ++ inspector.actions ++ profiler.actions ++ text_panel.actions ++ open.actions ++ text_tools.actions ++ plugins.actions ++ plugin_list.actions ++ vcs_git.actions ++ vcs_p4.actions;

/// The keys of the editor's own `global` actions, by Emacs's conventions.
pub const global_keys = [_]keybinds.KeyDef{
    .{ .chord = "M-x", .action = .{ "global", "action_palette_toggle" } },
    .{ .chord = "C-p", .action = .{ "global", "picker_toggle" } },
    .{ .chord = "C-x 0", .action = .{ "global", "window_close" } },
    .{ .chord = "C-S-w", .action = .{ "global", "window_close" } },
};

/// The keys of a table window while it is browsed: Org mode's table keys for moving and editing,
/// Emacs's for moving, copying and pasting, and those of the window's own commands. Org's `C-c`
/// chords are a prefix, so copy is `M-w` (and Super with `c` on macOS); see
/// `table_command_keys`.
pub const table_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-x C-s", .action = .{ "table", "save" } },
    .{ .chord = "C-enter", .action = .{ "table", "add" } },
    .{ .chord = "C-S-k", .action = .{ "table", "delete" } },
    .{ .chord = "M-S-down", .action = .{ "table", "row_add" } },
    .{ .chord = "M-S-up", .action = .{ "table", "row_delete" } },
    .{ .chord = "tab", .action = .{ "table", "next_cell" }, .trigger = .repeat },
    .{ .chord = "S-tab", .action = .{ "table", "previous_cell" }, .trigger = .repeat },
    .{ .chord = "enter", .action = .{ "table", "next_row" }, .trigger = .repeat },
    .{ .chord = "kp_enter", .action = .{ "table", "next_row" }, .trigger = .repeat },
    .{ .chord = "down", .action = .{ "table", "next_row" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "table", "next_row" }, .trigger = .repeat },
    .{ .chord = "up", .action = .{ "table", "previous_row" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "table", "previous_row" }, .trigger = .repeat },
    .{ .chord = "left", .action = .{ "table", "previous_column" }, .trigger = .repeat },
    .{ .chord = "C-b", .action = .{ "table", "previous_column" }, .trigger = .repeat },
    .{ .chord = "right", .action = .{ "table", "next_column" }, .trigger = .repeat },
    .{ .chord = "C-f", .action = .{ "table", "next_column" }, .trigger = .repeat },
    .{ .chord = "home", .action = .{ "table", "row_start" }, .trigger = .repeat },
    .{ .chord = "end", .action = .{ "table", "row_end" }, .trigger = .repeat },
    .{ .chord = "page_up", .action = .{ "table", "page_up" }, .trigger = .repeat },
    .{ .chord = "page_down", .action = .{ "table", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "table", "first_cell" }, .trigger = .repeat },
    .{ .chord = "M-S-period", .action = .{ "table", "last_cell" }, .trigger = .repeat },
    .{ .chord = "C-c grave_accent", .action = .{ "table", "edit_cell" } },
    .{ .chord = "C-c SPC", .action = .{ "table", "clear_cell" } },
    .{ .chord = "C-c S-6", .action = .{ "table", "sort_column" } },
    .{ .chord = "C-c C-c", .action = .{ "table", "toggle" } },
    .{ .chord = "SPC", .action = .{ "table", "toggle" } },
    .{ .chord = "M-w", .action = .{ "table", "copy" } },
    .{ .chord = "C-y", .action = .{ "table", "paste" } },
} ++ table_command_keys;

/// The table window's keys with the command modifier, Super on macOS and Control elsewhere, as
/// other programs have them: paste, and the first and last cell. Copy is one of them on macOS
/// only, as Control with `c` elsewhere is Org's prefix (`C-c SPC`, `C-c C-c` ...).
const table_command_keys = if (builtin.os.tag == .macos) [_]keybinds.KeyDef{
    .{ .chord = "s-c", .action = .{ "table", "copy" } },
    .{ .chord = "s-v", .action = .{ "table", "paste" } },
    .{ .chord = "s-home", .action = .{ "table", "first_cell" }, .trigger = .repeat },
    .{ .chord = "s-end", .action = .{ "table", "last_cell" }, .trigger = .repeat },
} else [_]keybinds.KeyDef{
    .{ .chord = "C-v", .action = .{ "table", "paste" } },
    .{ .chord = "C-home", .action = .{ "table", "first_cell" }, .trigger = .repeat },
    .{ .chord = "C-end", .action = .{ "table", "last_cell" }, .trigger = .repeat },
};

/// The keys of the actions `editor_actions` gathers and of those the editor's modules offer
/// while they edit text, each list beside the actions of its module, all defaults, which a
/// person's own keys of the same mode go over.
const default_keymaps = [_]keybinds.KeymapDef{
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &text_panel.global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &open.global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &inspector.global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &text_tools.global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &vcs_git.global_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &plugin_list.global_keys },
    .{ .mode = modes.vcs, .rank = .default, .keys = &vcs_git.vcs_keys },
    .{ .mode = modes.vcs_git, .rank = .default, .keys = &vcs_git.vcs_git_keys },
    .{ .mode = modes.vcs_log, .rank = .default, .keys = &git_log.log_keys },
    .{ .mode = modes.vcs_rebase, .rank = .default, .keys = &git_rebase.rebase_keys },
    .{ .mode = modes.vcs_git_diff, .rank = .default, .keys = &git_diff.keys },
    .{ .mode = modes.vcs_message, .rank = .default, .keys = &git_commit.message_keys },
    .{ .mode = plugin.action_api.global_mode, .rank = .default, .keys = &vcs_p4.global_keys },
    .{ .mode = modes.vcs_p4, .rank = .default, .keys = &vcs_p4.vcs_p4_keys },
    .{ .mode = modes.vcs_p4_history, .rank = .default, .keys = &p4_history.history_keys },
    .{ .mode = modes.vcs_p4_diff, .rank = .default, .keys = &p4_diff.keys },
    .{ .mode = modes.vcs_p4_message, .rank = .default, .keys = &p4_change.message_keys },
    .{ .mode = modes.plugin_list, .rank = .default, .keys = &plugin_list.list_keys },
    .{ .mode = modes.table, .rank = .default, .keys = &table_keys },
    .{ .mode = modes.form, .rank = .default, .keys = &windows.form_keys },
    .{ .mode = modes.table_cell, .rank = .default, .keys = &windows.table_cell_keys },
    .{ .mode = modes.prompt, .rank = .default, .keys = &action_palette.prompt_keys },
    .{ .mode = modes.isearch, .rank = .default, .keys = &text_panel.isearch_keys },
    .{ .mode = modes.figure, .rank = .default, .keys = &figure_workspace.figure_keys },
    .{ .mode = modes.figure_cua, .rank = .default, .keys = &figure_workspace.figure_cua_keys },
    .{ .mode = modes.text, .rank = .default, .keys = &text_editor.text_keys },
    .{ .mode = modes.buffer, .rank = .default, .keys = &text_panel.buffer_keys },
    .{ .mode = modes.cua, .rank = .default, .keys = &text_editor.cua_keys },
};

/// `default_keymaps` built (`keybinds.buildKeymap`), in that order, their bindings in
/// `allocator`. Interns the text of each action they bind.
pub fn buildKeymaps(allocator: std.mem.Allocator, atoms: *Atom.Registry) error{OutOfMemory}![]const plugin.action_api.Keymap {
    const built = try allocator.alloc(plugin.action_api.Keymap, default_keymaps.len);
    for (default_keymaps, built) |def, *keymap| keymap.* = try keybinds.buildKeymap(allocator, atoms, def);
    return built;
}

/// The scope that holds the editor's keymaps as built, for as long as the host's memory lasts.
const keymaps_scope_name = "editor.keymaps";
/// The record in that scope that says which keymaps the editor declares.
const keymaps_record_label = Atom.from("editor.keymaps.installed");

/// The keymaps the editor declares every frame, built once as it starts and again when it is
/// loaded again. The record of `keymaps_record_label` holds the ones installed.
const BuiltKeymaps = struct {
    /// The arena of `editor.keymaps` that holds every binding below; it is released when the
    /// keymaps of the next load are installed. First, so a load whose layout of the rest differs
    /// still finds it.
    arena: *memory_mod.Arena,
    /// `default_keymaps`, built.
    editor: []const plugin.action_api.Keymap,
    /// The app stage's keys, which apply while the app's tables are there.
    stage: plugin.action_api.Keymap,
};

/// Keymaps built for a load of the editor, and the record they are installed in once it is
/// admitted.
const PreparedKeymaps = struct {
    scope: *memory_mod.Scope,
    record: *memory_mod.Scope.Record,
    built: BuiltKeymaps,

    /// Makes the built keymaps the ones declared, and releases the arena of those they
    /// replace. Allocates nothing.
    fn install(prepared: PreparedKeymaps) void {
        const installed = prepared.record.of(BuiltKeymaps);
        if (prepared.record.installed) prepared.scope.releaseArena(installed.arena);
        installed.* = prepared.built;
        prepared.record.installed = true;
    }
};

/// Builds the editor's keymaps in a new arena of `editor.keymaps` and reserves the record they
/// are installed in. Inside an init admission, an abort takes back the arena, and the scope and
/// the record if this made them.
fn prepareKeymaps(memory: *memory_mod.Memory, atoms: *Atom.Registry) !PreparedKeymaps {
    try atoms.tryInternAll(&.{ keymaps_scope_name, "editor.keymaps.installed" });
    const scope = try memory.resolvedPrivateScope(Atom.from(keymaps_scope_name));
    const record = try scope.labeledRecord(keymaps_record_label, @sizeOf(BuiltKeymaps));
    const arena = try scope.createArena();
    const allocator = arena.allocator();
    const editor_keymaps = try buildKeymaps(allocator, atoms);
    const stage_keymap = try stage_mod.buildKeymap(allocator, atoms);
    return .{
        .scope = scope,
        .record = record,
        .built = .{ .arena = arena, .editor = editor_keymaps, .stage = stage_keymap },
    };
}

/// The keymaps installed; null before the editor's init installs them.
fn installedKeymaps(memory: *memory_mod.Memory) ?BuiltKeymaps {
    const scope = memory.existingPrivateScope(Atom.from(keymaps_scope_name)) orelse return null;
    const record = scope.existingLabeledRecord(keymaps_record_label) orelse return null;
    if (!record.installed) return null;
    return record.of(BuiltKeymaps).*;
}

/// Whether `default_keymaps` binds a key to the action `name` of the mode `mode`.
fn hasDefaultKey(atoms: *Atom.Registry, mode: Atom, name: []const u8) bool {
    const mode_text = atoms.lookup(mode) orelse return false;
    for (default_keymaps) |keymap| {
        for (keymap.keys) |key| {
            const mode_text_bound, const name_bound = key.action;
            if (std.mem.eql(u8, mode_text_bound, mode_text) and std.mem.eql(u8, name_bound, name)) return true;
        }
    }
    return false;
}

/// Whether the action `name` is a table window's own command, offered while one is focused.
fn isTableAction(name: []const u8) bool {
    for ([_][]const u8{
        "add",             "delete",   "edit",      "save",        "row_add", "row_delete", "schema_toggle",
        "metadata_toggle", "meta_add", "meta_edit", "meta_delete",
    }) |table_name| if (std.mem.eql(u8, name, table_name)) return true;
    return false;
}

/// Which of `editor_actions`' lists an action comes from, as far as its mode goes.
const ActionSource = enum { figure_editor, other };

/// The mode the action `known_name` (see `pushEditorActions`) is offered in. A figure action is
/// the figure editor's, but for the two that open or create a document, which answer whatever
/// has the focus; a form's own are the form's, a table window's are the table's, and the rest
/// are global.
fn actionMode(known_name: []const u8, source: ActionSource) Atom {
    if (source == .figure_editor) {
        const creates_document = std.mem.eql(u8, known_name, "figure_open") or std.mem.eql(u8, known_name, "figure_new");
        return if (creates_document) plugin.action_api.global_mode else modes.figure;
    }
    if (isFormAction(known_name)) return modes.form;
    if (isTableAction(known_name)) return modes.table;
    return plugin.action_api.global_mode;
}

fn isFormAction(name: []const u8) bool {
    return std.mem.eql(u8, name, "form_save") or std.mem.eql(u8, name, "form_cancel") or
        std.mem.eql(u8, name, "meta_save") or std.mem.eql(u8, name, "meta_cancel_edit");
}

fn requiresFocusedView(name: []const u8) bool {
    for ([_][]const u8{
        "add",              "delete",    "edit",        "save",     "row_add",   "row_delete",  "schema_toggle",
        "metadata_toggle",  "form_save", "form_cancel", "meta_add", "meta_edit", "meta_delete", "meta_save",
        "meta_cancel_edit",
    }) |focused_name| if (std.mem.eql(u8, name, focused_name)) return true;
    return false;
}

/// The system that runs the action `def`, whose panels draw again for it: the figure editor's
/// system that claims it, the profiler's, the inspector's or its table windows' (tables,
/// trackers and forms), or the editor's own. `name` is the action's known name (see
/// `pushEditorActions`).
fn actionSystem(def: plugin.action_api.Def, name: []const u8, cancel_owner: CancelOwner) sequencer.System {
    if (std.mem.eql(u8, name, "cancel")) return switch (cancel_owner) {
        .inspector => windows.system(),
        .editor => messagesSystem(),
    };
    if (isFigureAction(name) or definesTag(&figure_workspace.actions, def.tag)) return figure_workspace.actionSystem(Atom.from(def.tag));
    if (definesAction(&profiler.actions, name)) return profiler.system();
    if (definesTag(&text_panel.actions, def.tag)) return text_panel.system();
    if (definesTag(&open.actions, def.tag)) return open.system();
    if (definesTag(&text_tools.actions, def.tag)) return text_tools.system();
    if (definesTag(&vcs_git.actions, def.tag)) return vcs_git.system();
    if (definesTag(&vcs_p4.actions, def.tag)) return vcs_p4.system();
    if (definesAction(&plugins.actions, name)) return plugins.system();
    if (definesTag(&plugin_list.actions, def.tag)) return plugin_list.system();
    if (definesAction(&inspector.actions, name)) return inspector.system();
    if (definesAction(&fixed_panels.actions, name)) return fixed_panels.system();
    if (std.mem.eql(u8, name, "action_palette_toggle")) return messagesSystem();
    return windows.system();
}

/// Who takes `cancel`: the table windows while one of them, or a form, has the keys and no prompt
/// is open over it; else the editor, which hands it to the figure editor.
const CancelOwner = enum { inspector, editor };

fn definesAction(defs: []const plugin.action_api.Def, name: []const u8) bool {
    for (defs) |def| if (std.mem.eql(u8, def.name, name)) return true;
    return false;
}

fn definesTag(defs: []const plugin.action_api.Def, tag: []const u8) bool {
    for (defs) |def| if (std.mem.eql(u8, def.tag, tag)) return true;
    return false;
}

fn isFigureAction(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "figure_") and !std.mem.eql(u8, name, "figure_open") and !std.mem.eql(u8, name, "figure_new");
}

/// Actions about the whole window rather than one panel, which answer wherever the focus is:
/// the action palette and picker, moving between and arranging panels, and opening or closing what the focused panel shows.
fn isWindowAction(name: []const u8) bool {
    const exact = [_][]const u8{
        "action_palette_toggle", "picker_toggle",  "focus_next_view", "maximize_toggle", "window_close",
        "figure_open",           "figure_new",     "text_find_file",  "open",            "text_toggle_keymap",
        "panels_show_hidden",    "vcs_git_status", "vcs_p4_status",   "vcs_status",      "plugins_show",
    };
    for (exact) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    const prefixes = [_][]const u8{ "panel_dock_", "inspector_", "profiler_toggle" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

pub fn pushEditorActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const focus = state.viewFocus(tables, atoms).id.*;
    const app_view_focused = focus != @as(Atom, @enumFromInt(0)) and !fixed_panels.ownsPanel(tables, atoms, focus);
    const editor_view_focused = focus != @as(Atom, @enumFromInt(0)) and !app_view_focused;
    const action_palette_input = action_palette.requestOpen(tables, atoms);
    const form_editing = windows.isFormEditing(tables, atoms);
    const focused_view = windows.focusedHandle(tables, atoms) != null;
    const editor_context = editor_view_focused or action_palette_input or form_editing;
    const cancel_owner: CancelOwner = if (!action_palette_input and (focused_view or form_editing)) .inspector else .editor;
    const app_context = !editor_context;

    for (editor_actions) |def| {
        // A figure, text panel, open, programs or form action's name can be another action's, so
        // the checks below, which are by name, know it by its tag: its known name.
        const figure_def = definesTag(&figure_workspace.actions, def.tag);
        const text_def = definesTag(&text_panel.actions, def.tag) or definesTag(&open.actions, def.tag) or definesTag(&text_tools.actions, def.tag);
        const form_def = isFormAction(def.tag);
        const known_name = if (figure_def or text_def or form_def) def.tag else def.name;
        const source: ActionSource = if (figure_def) .figure_editor else .other;
        const mode = actionMode(known_name, source);
        if (isFormAction(known_name) and !form_editing) continue;
        if (requiresFocusedView(known_name) and !focused_view) continue;
        if (std.mem.eql(u8, known_name, "delete_tracker") and !windows.focusedTracker(tables, atoms)) continue;
        if (isFigureAction(known_name) and (!figure_workspace.stageShown(tables) or !figure_workspace.isFigureView(focus))) continue;
        // A focused text panel lists these itself (`text_panel.panel_actions`).
        if (text_panel.listsActions(tables, atoms) and std.mem.eql(u8, known_name, "text_switch_buffer")) continue;
        if (text_panel.listsActions(tables, atoms) and std.mem.eql(u8, known_name, "text_select_window")) continue;
        if (text_panel.listsActions(tables, atoms) and std.mem.eql(u8, known_name, "text_recent_files")) continue;

        const panel_action = std.mem.startsWith(u8, known_name, "inspector_") or std.mem.startsWith(u8, known_name, "profiler_") or std.mem.eql(u8, known_name, "panels_show_hidden") or std.mem.eql(u8, known_name, "stage_show");
        const creation_action = std.mem.eql(u8, known_name, "figure_open") or std.mem.eql(u8, known_name, "figure_new") or std.mem.eql(u8, known_name, "create_tracker") or std.mem.eql(u8, known_name, "text_find_file") or std.mem.eql(u8, known_name, "open") or std.mem.eql(u8, known_name, "text_toggle_keymap");
        // Action palette completion closes the prompt before invoking the selected
        // action. Actions that show panels must remain available while another plugin's panel
        // has the focus, and so must those a key reaches there.
        if (app_context and !panel_action and !creation_action and !hasDefaultKey(atoms, mode, def.name)) continue;
        var action_def = def;
        // Window actions answer from any panel; the rest only while one of the editor's panels
        // has the focus.
        action_def.scope = if (isWindowAction(known_name)) .global else .local;
        // Closing a text panel is the panel's: a modified file asks first.
        const closes_text_panel = std.mem.eql(u8, known_name, "window_close") and text_panel.isPanel(focus);
        const owner = if (closes_text_panel) text_panel.system() else actionSystem(def, known_name, cancel_owner);
        const inbox = sequencer.inboxOf(owner);
        const palette_toggle = std.mem.eql(u8, known_name, "action_palette_toggle");
        keybinds.pushActionDefinitions(atoms, sink, mode, inbox, &.{.{
            .def = action_def,
            .capture = (action_palette_input and palette_toggle) or (form_editing and isFormAction(known_name)),
        }});
    }
    // The text editor's actions and those of what it edits for: a cell, a form's field, a
    // prompt or a text panel, whichever has the keyboard.
    windows.pushCellEditorActions(tables, atoms, sink);
    windows.pushFormEditorActions(tables, atoms, sink);
    action_palette.pushPromptActions(tables, atoms, sink);
    text_panel.pushActions(tables, atoms, sink);
    vcs_git.pushActions(atoms, sink);
    vcs_p4.pushActions(atoms, sink);
    plugin_list.pushActions(atoms, sink);
}

pub fn init(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const scratch = try memory.frameScratchAllocator();

    _ = atoms.intern("editor");
    const keymaps = try prepareKeymaps(memory, atoms);
    keymaps.install();
    try windows.init(scratch, atoms, tables);
    try action_palette.prepareCompletionArenas(memory, atoms);
    try action_palette.ensure(scratch, atoms, tables);
    try figure_workspace.ensure(memory, atoms, tables);
    // A menu an earlier image showed is that image's constant, gone with it.
    const transient_menu = transient.lostFields(tables);
    transient.loseMenu(transient_menu);

    initializeFocusClicks(tables, atoms);

    requestStartupResources(tables);
}

/// The editor's requests to resources as it starts: the table index, whose answer is the table
/// windows', and the fonts text falls back to. Its own fonts load as they are first drawn.
fn requestStartupResources(tables: *Table.Registry) void {
    const memory = tables.memory;
    const index_reply = windows.replyTo(.table_index);
    resources.request(memory, tables, .{ .refresh_table_index = .{ .reply = index_reply } });
    resources.request(memory, tables, .{ .set_fallback_fonts = .{ .paths = fallback_font_paths } });
}

/// The system's fonts text falls back to for a character the editor's fonts lack: Latin,
/// Greek and Cyrillic beyond the editor's, the CJK ideographs and kana, then the other scripts,
/// symbols and emoji, in that order. Candidates for each platform's usual install; those a
/// machine lacks are passed over. The CJK fonts are TrueType or CFF ones, as stb_truetype
/// reads no CFF2, which Fedora's variable Noto CJK is; Droid Sans Fallback has no Hangul, so
/// Korean needs Nanum or a static Noto Sans KR.
const fallback_font_paths = switch (builtin.os.tag) {
    .windows =>
    \\C:/Windows/Fonts/segoeui.ttf
    \\C:/Windows/Fonts/YuGothR.ttc
    \\C:/Windows/Fonts/msgothic.ttc
    \\C:/Windows/Fonts/msyh.ttc
    \\C:/Windows/Fonts/malgun.ttf
    \\C:/Windows/Fonts/simsun.ttc
    \\C:/Windows/Fonts/Nirmala.ttf
    \\C:/Windows/Fonts/tahoma.ttf
    \\C:/Windows/Fonts/seguisym.ttf
    \\C:/Windows/Fonts/seguiemj.ttf
    ,
    else =>
    \\/usr/share/fonts/google-noto/NotoSans-Regular.ttf
    \\/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf
    \\/usr/share/fonts/noto/NotoSans-Regular.ttf
    \\/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
    \\/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc
    \\/usr/share/fonts/google-droid-sans-fonts/DroidSansFallbackFull.ttf
    \\/usr/share/fonts/naver-nanum/NanumGothic.ttf
    \\/usr/share/fonts/truetype/nanum/NanumGothic.ttf
    \\/usr/share/fonts/google-noto-sans-kr-fonts/NotoSansKR-Regular.otf
    \\/usr/share/fonts/opentype/noto/NotoSansKR-Regular.otf
    \\/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf
    \\/usr/share/fonts/google-noto-vf/NotoSansArabic[wght].ttf
    \\/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf
    \\/usr/share/fonts/google-noto-vf/NotoSansHebrew[wght].ttf
    \\/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf
    \\/usr/share/fonts/google-noto-vf/NotoSansDevanagari[wght].ttf
    \\/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf
    \\/usr/share/fonts/google-noto-vf/NotoSansThai[wght].ttf
    \\/usr/share/fonts/truetype/noto/NotoSansThai-Regular.ttf
    \\/usr/share/fonts/google-noto/NotoSansSymbols2-Regular.ttf
    \\/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf
    \\/usr/share/fonts/google-noto-vf/NotoSansSymbols[wght].ttf
    \\/usr/share/fonts/google-noto-emoji-fonts/NotoEmoji-Regular.ttf
    \\/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
    \\/usr/share/fonts/gdouros-symbola/Symbola.ttf
    \\/usr/share/fonts/truetype/ancient-scripts/Symbola_hint.ttf
    ,
};

/// What the editor's init left for its first update, once its admission committed:
/// the focus clicks it recorded, the registration of its modes, and its requests to resources.
/// An init of the plugin loaded again leaves them again, and registering the modes again
/// changes nothing.
fn sendPendingStartupRequests(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const focus = state.viewFocus(tables, atoms);
    if (focus.startup_requests_pending.* == 0) return;
    focus.startup_requests_pending.* = 0;
    requestFocusClicks(tables, recordedFocusClicks(focus)) catch |err| Log.err("focus_clicks_request_failed", .{ .@"error" = @errorName(err) });
    modes.registerAll(tables);
    requestStartupResources(tables);
}

fn modalActive(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return windows.isTextEditing(tables, atoms) or windows.isFormEditing(tables, atoms) or
        action_palette.requestOpen(tables, atoms) or figure_workspace.contextMenuOpen(context_menu.get(tables));
}

pub const action_selected_tag = plugin.action_api.kActionSelectedTag;

const ActionSelectionData = extern struct { id: plugin.action_api.ActionId };

fn actionListShows(tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8, entries: []const plugin.action_api.ListEntry) bool {
    const shown = action_palette.currentCompletions(tables, atoms) orelse return false;
    if (!std.mem.eql(u8, shown.initial_query, query) or shown.entries.len != entries.len) return false;
    for (shown.entries, entries) |completion, entry| {
        const selected = std.mem.bytesToValue(ActionSelectionData, completion.data[0..@sizeOf(ActionSelectionData)]);
        if (!std.mem.eql(Atom, &selected.id, &entry.id)) return false;
        // The id names the label; the description may change with a reload.
        if (!std.mem.eql(u8, completion.detail, entry.doc)) return false;
    }
    return true;
}

/// The chords the keymaps give actions, as the UI shows a chord of one key
/// (`keybinds.displayChord`), for a list or a row of buttons that shows each action's keys: one
/// `keybinds.ChordLookup` built for them all. Reads the keymaps declared and the modes registered
/// as their writers last left them.
pub const Shortcuts = struct {
    /// Holds the lookup and the text shown: an arena's, such as the frame's scratch.
    allocator: std.mem.Allocator,
    /// Null without the actions system's registry, or when the lookup could not be built.
    lookup: ?keybinds.ChordLookup,

    /// The shortcuts of the keymaps in `tables`, built in `allocator`.
    pub fn of(allocator: std.mem.Allocator, tables: *Table.Registry) Shortcuts {
        const registry = tables.findByName(Atom.from(plugin.action_api.mode_registry_table)) orelse return .{ .allocator = allocator, .lookup = null };
        const keymaps = plugin.Keymaps.of(tables.memory, tables, plugin.action_api.keymaps_table_name);
        const lookup = keybinds.ChordLookup.build(allocator, keymaps, registry) catch null;
        return .{ .allocator = allocator, .lookup = lookup };
    }

    /// The chord `mode`'s keymap, or an ancestor's, gives the action `id`, as the UI shows it;
    /// null when none is bound, or it has several keys. The text is in `shortcuts.allocator`.
    pub fn text(shortcuts: *Shortcuts, mode: Atom, id: plugin.action_api.ActionId) ?[]const u8 {
        const lookup = if (shortcuts.lookup) |*built| built else return null;
        var chord_buffer: [64]u8 = undefined;
        const found = lookup.chordFor(&chord_buffer, mode, id) catch return null;
        const chord = found orelse return null;
        const shown_buffer = shortcuts.allocator.alloc(u8, 32) catch return null;
        return keybinds.displayChord(shown_buffer, chord);
    }
};

/// The action list's completions for `query`, unless it already shows them.
pub fn showActionList(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, query: []const u8, listed: []const plugin.action_api.ListEntry) void {
    // The list is offered every frame the action list is open, and its arena resets only when
    // it closes: a list already shown must not take storage.
    if (actionListShows(tables, atoms, query, listed)) return;
    const allocator = action_palette.completionAllocator(memory, .action_list) catch return;
    // The arena lasts until the palette closes: only the text shown is kept in it, and the keys
    // are looked up in the frame's scratch.
    const scratch = memory.frameScratchAllocator() catch return;
    var shortcuts = Shortcuts.of(scratch.allocator, tables);
    const entries = allocator.alloc(action_palette.Completion, listed.len) catch return;
    for (listed, 0..) |entry, i| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        const selected = ActionSelectionData{ .id = entry.id };
        @memcpy(data[0..@sizeOf(ActionSelectionData)], std.mem.asBytes(&selected));
        // Named by its id, as text writes an action, with what it does beside it. The prompt's
        // modes are active while it is open, so the key is read from the keymap of the
        // action's own mode, active or not.
        const found_shortcut = shortcuts.text(entry.id[0], entry.id) orelse "";
        const shortcut = allocator.dupe(u8, found_shortcut) catch return;
        var id_buffer: [96]u8 = undefined;
        const formatted_id = plugin.action_api.formatId(&id_buffer, atoms, entry.id);
        const id_text = allocator.dupe(u8, formatted_id) catch return;
        entries[i] = .{
            .label = id_text,
            .detail = entry.doc,
            .shortcut = shortcut,
            .data = data,
            // As Emacs's M-x completes to the command's name, which the list is narrowed by.
            .completes_to = entry.label,
        };
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = kActionListOwner,
        .presentation = .prompt,
        .title = action_list_placeholder,
        .initial_query = query,
        .entries = entries,
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
}

/// The action list's events: a completion chosen invokes its action, judged by the modes of the
/// panel the palette was opened from, which it asks for first.
fn handleActionSelected(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) void {
    const event = action_palette.eventOf(received) catch |err| return received.unreadable(err);
    if (event.kind != .completed) return;
    if (event.completion) |completion| {
        const selected = std.mem.bytesToValue(ActionSelectionData, completion.data[0..@sizeOf(ActionSelectionData)]);
        const palette_modes_name = Atom.from(action_palette.prompt_modes_table_name);
        if (tables.findByName(palette_modes_name)) |palette_modes| {
            if (keptModesOf(palette_modes)) |opened_over| plugin.action_api.requestModes(tables, opened_over);
        }
        plugin.action_api.requestInvoke(tables, selected.id);
    }
    // Late, behind an action list opened since: that one owns the arena.
    if (!actionListOpen(tables, atoms)) action_palette.resetCompletionArena(memory, .action_list);
}

// ---- the editor's view focus ----------------------------------------------------------------

/// The editor's view focus, which follows the panels': it reads the focus moves in
/// `events.panels` and moves the editor's keys, its hover and the figure editor's gestures
/// with them. First of the editor's systems, so the others see the focus as it is now.
pub fn focusSystem() sequencer.System {
    return .{
        .name = "editor_focus",
        .root = editor_root,
        .claims = sequencer.claims_nothing,
        .access = focusAccess,
        .kernels = &.{
            .{ .name = "editor_focus.take_focus", .run = takeFocus },
        },
    };
}

const focus_reader = Atom.from(focusSystem().name);

/// Only while the panels told something since its last run: the events, to read past them, and
/// while the focus moved, what following it writes.
fn focusAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    const tables = frame.tables;
    const events = plugin.panels.Events.of(tables, plugin.panels.events_table_name);
    var told: [focus_moves_max]plugin.panels.Event = undefined;
    const unread = events.unread(focus_reader, &told);
    if (unread.len == 0) return result;
    // A size is not followed, but read past, or a run of them would hide a move behind it.
    plugin.panels.Events.declare(&result, tables, plugin.panels.events_table_name);
    const moved = for (unread) |event| {
        if (event != .resized) break true;
    } else false;
    if (!moved) return result;
    result.readAll(&.{ Atom.from(panels_mod.nodes_table_name), Atom.from(panels_mod.state_table_name) });
    result.write(Atom.from(state.view_focus_name));
    result.writeIfPresent(tables, Atom.from(state.app_state_name));
    result.writeIfPresent(tables, Atom.from(state.authoring_ui_name));
    result.writeIfPresent(tables, Atom.from(action_palette.table_name));
    result.writeIfPresent(tables, Atom.from(status_bar.commands_table_name));
    result.writeIfPresent(tables, Atom.from(panels_mod.redraw_table_name));
    // Leaving the figure editor's panels ends its gestures, and entering one gives it the keys.
    for (unread) |event| {
        const id = switch (event) {
            .focused, .unfocused => |panel| panel,
            .resized => continue,
        };
        if (!figure_workspace.isFigureView(id)) continue;
        figure_workspace.table_groups.declareEditing(&result);
        // Focus loss drops a press waiting for its answer.
        figure_workspace.table_groups.declareAsking(&result, tables);
        break;
    }
    return result;
}

/// The most of the panels' events one run reads: all the events table keeps, so a run of sizes
/// (one a panel, each pump a window is resized) never pushes a focus move out unread.
const focus_moves_max = plugin.panels.Events.retained;

fn takeFocus(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const events = plugin.panels.Events.of(frame.tables, plugin.panels.events_table_name);
    var told: [focus_moves_max]plugin.panels.Event = undefined;
    const taken = try events.read(pass, focus_reader, &told);
    for (taken) |event| followFocus(frame.tables, frame.atoms, event);
}

/// Follows one of the panels' events: a focus move; a size is not the focus's to follow.
fn followFocus(tables: *Table.Registry, atoms: *Atom.Registry, move: plugin.panels.Event) void {
    // Moving between the figure editor's own panels keeps its gestures; leaving them ends them.
    switch (move) {
        .unfocused => |id| {
            const leaving_figure = figure_workspace.isFigureView(id) and
                !figure_workspace.isFigureView(panels_mod.focusedTarget(tables, atoms).id);
            if (leaving_figure and figure_workspace.stageShown(tables)) figure_workspace.focusLost(tables, atoms);
            if (!action_palette.requestOpen(tables, atoms) and !windows.isFormEditing(tables, atoms)) {
                state.clearViewFocus(tables, atoms, id);
            }
        },
        .focused => |id| {
            state.setViewFocus(tables, atoms, id);
            figure_workspace.followPanelFocus(tables, id);
            // The figure editor's panels show which of them has the keys.
            requestRootRedraw(tables, atoms, figure_workspace.figure_root);
        },
        .resized => {},
    }
}

/// One of the editor's messages, `received`, as its messages system takes it; tests call it
/// outside a run.
pub fn updateMessage(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) bool {
    const tag = received.tag;
    if (tag == action_selected_tag) {
        handleActionSelected(memory, tables, atoms, received);
        return true;
    }
    // A figure glide stepped; the stage draws the cell it moved.
    if (tag.to(motion.Msg) == .figure_motion_update) return true;
    // The figure editor's systems take their own messages. What reaches it here is the
    // editor's: the generic `cancel` while a figure panel has the keys, the clicks and wheel
    // over its drawing that none of its systems claims, and hover changes over its panels.
    if (figure_workspace.handle(memory, tables, atoms, received)) {
        requestRootRedraw(tables, atoms, figure_workspace.figure_root);
        return true;
    }
    if (tag == action_palette_toggle_tag) {
        if (actionListOpen(tables, atoms)) {
            action_palette.request(memory, tables, .{ .dismiss = .{} });
        } else {
            figure_workspace.finish(tables, atoms);
            queueActionListRequest(memory, tables);
        }
        return true;
    }

    return false;
}

// ---- what the editor subscribes to ----------------------------------------------------------

/// What the editor offers and listens for, last of the editor's systems so it does so for the
/// frame's final state, as its subscriptions were collected after the frame: the regions'
/// pointer input, the app stage's actions, the editor's and the focused table window's, the
/// keymaps of their modes, and, while the action list is open, the actions it lists.
pub fn subscriptionsSystem() sequencer.System {
    return .{
        .name = "editor_subscriptions",
        .root = editor_root,
        .claims = sequencer.claims_nothing,
        .access = subscriptionsAccess,
        .kernels = &.{
            .{ .name = "editor_subscriptions.declare", .run = declareSubscriptions },
            .{ .name = "editor_subscriptions.list_actions", .run = listActions },
        },
    };
}

fn subscriptionsAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    // All three are cleared before every run.
    result.writeIfPresent(frame.tables, editor_sequencer.ActionDeclarer.table);
    result.writeIfPresent(frame.tables, editor_sequencer.KeymapDeclarer.table);
    result.writeIfPresent(frame.tables, editor_sequencer.InputSubscriber.table);
    // The action list's completions are the palette's to show, of the actions available in the
    // modes it found as it opened, by the modes registered.
    result.writeIfPresent(frame.tables, Atom.from(action_palette.requests_table_name));
    readIfPresent(&result, frame.tables, Atom.from(action_palette.prompt_modes_table_name));
    readIfPresent(&result, frame.tables, Atom.from(plugin.action_api.mode_registry_table));
    return result;
}

fn readIfPresent(access: *sequencer.Access, tables: *Table.Registry, name: Atom) void {
    if (tables.findByName(name) != null) access.read(name);
}

fn declareSubscriptions(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    // Without the app's tables, as in a test of the editor alone, nothing of the app's.
    const app_present = tables.findByName(Atom.from(state.app_state_name)) != null;
    if (app_present and pass.writes(editor_sequencer.InputSubscriber.table)) {
        const hits = state.hitRegions(tables, atoms);
        // A modal still takes clicks and the wheel; depth order decides which region gets them.
        // Regions answer the pointer over them wherever the focus is: a press focuses the panel
        // under it, and the wheel and hover follow the pointer. Their routes say whose they
        // are, so their messages go by route.
        const regions: input.Subscription = .{ .on_mouse = .{ .table = hits, .scope = .global, .capture = modalActive(tables, atoms) } };
        const subscriptions = try pass.writeTable(editor_sequencer.InputSubscriber.table);
        try input.appendSubscription(subscriptions, .{ .subscription = regions, .source = .plugin });
    }
    const declares_keymaps = pass.writes(editor_sequencer.KeymapDeclarer.table);
    if (declares_keymaps) {
        if (installedKeymaps(frame.memory)) |built| {
            var keymap_declarer: editor_sequencer.KeymapDeclarer = .{ .pass = pass };
            const keymap_sink = keymap_declarer.sink();
            if (app_present) keymap_sink.declare(built.stage);
            for (built.editor) |keymap| keymap_sink.declare(keymap);
        }
    }
    if (!pass.writes(editor_sequencer.ActionDeclarer.table)) return;
    var declarer: editor_sequencer.ActionDeclarer = .{ .pass = pass };
    const sink = declarer.sink();
    if (app_present) stage_mod.declareActions(atoms, sink);
    windows.declareActions(tables, atoms, sink);
    pushEditorActions(tables, atoms, sink);
}

/// While the action list is open, the actions offered this frame that its query matches and
/// that are available in the modes the palette found as it opened, those of the panel it was
/// opened from, for the palette to show.
fn listActions(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (!actionListOpen(frame.tables, frame.atoms)) return;
    if (!pass.writes(editor_sequencer.ActionDeclarer.table)) return;
    const query = action_palette.promptText(frame.tables, frame.atoms);
    const scratch = try frame.memory.frameScratchAllocator();
    const offered = plugin.Actions.of(frame.memory, frame.tables, plugin.action_api.subscribed_table_name);
    const opened_over = try paletteKeptModes(pass);
    const active = try paletteActiveModes(pass, scratch.allocator, opened_over);
    const entries = try plugin.action_api.listEntries(scratch.allocator, frame.atoms, offered, .{ .only = active }, query);
    showActionList(frame.memory, frame.tables, frame.atoms, query, entries);
}

/// The modes the palette found as its prompt last opened; `global` and none without its table,
/// as in a test that does not make it, or before its first prompt.
fn paletteKeptModes(pass: *sequencer.Pass) !plugin.action_api.Modes {
    const table_atom = Atom.from(action_palette.prompt_modes_table_name);
    if (!pass.declares(table_atom)) return .{};
    const palette_modes = try pass.table(table_atom);
    return keptModesOf(palette_modes) orelse .{};
}

/// The modes the palette's table of its prompt's modes, `palette_modes`, kept as its prompt last
/// opened (`modes.keptModes`); null before its first prompt.
fn keptModesOf(palette_modes: *Table) ?plugin.action_api.Modes {
    var rows = palette_modes.readQuery(modes.PromptModesView);
    const found = rows.next() orelse return null;
    return modes.keptModes(found.view);
}

/// The modes active under `opened_over` by the modes registered (`actions.activeModes`); `global`
/// alone without the actions system's registry, as in a test of the editor alone.
fn paletteActiveModes(pass: *sequencer.Pass, allocator: std.mem.Allocator, opened_over: plugin.action_api.Modes) ![]const Atom {
    const registry_atom = Atom.from(plugin.action_api.mode_registry_table);
    if (!pass.declares(registry_atom)) return allocator.dupe(Atom, &.{plugin.action_api.global_mode});
    const registry = try pass.table(registry_atom);
    return plugin.action_api.activeModes(allocator, registry, opened_over);
}

pub fn isVisible(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return windows.isVisible(tables, atoms) or action_palette.requestOpen(tables, atoms);
}

// ---- the editor's own messages ------------------------------------------------------------

/// What the editor takes itself, first of its systems after table authoring, as its message
/// handling did before any system ran: the action list's replies and choice, the text
/// navigation and toggle actions the palette moves through, hover over any panel's regions,
/// and what a module's own systems leave, as the figure editor's `cancel`; a handler that
/// changes a module's panels asks that module's root to draw. Then, each frame, it sends the
/// editor's startup requests, asks the inspector's panels to draw and keeps the palette's
/// focus clicks in step.
pub fn messagesSystem() sequencer.System {
    return .{
        .name = "editor_messages",
        .root = editor_root,
        .claims = claimsUnclaimed,
        .access = messagesAccess,
        .kernels = &.{
            .{ .name = "editor_messages.take_messages", .run = takeEditorMessages },
            .{ .name = "editor_messages.keep_up", .run = keepUp },
        },
    };
}

/// What no other system under the editor's root claims: they take their own first.
fn claimsUnclaimed(tag: Atom) bool {
    const figure_authoring = figure_workspace.figureAuthoring();
    const frame_root = editor_sequencer.frameRoot(&figure_authoring);
    const own_name = messagesSystem().name;
    for (frame_root.steps) |step| switch (step) {
        .system => |other| {
            const is_this_system = std.mem.eql(u8, other.name, own_name);
            if (is_this_system or other.root != editor_root) continue;
            if (other.claims(tag)) return false;
        },
        .sequencer, .call => {},
    };
    return true;
}

fn messagesAccess(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    // The view's focus and its startup requests, the hover drawn, the palette's prompt, and what
    // these ask of the status bar, the palette, the panels and resources.
    result.write(Atom.from(state.view_focus_name));
    result.writeIfPresent(tables, Atom.from(state.app_state_name));
    result.read(Atom.from(input.hover_table_name));
    const asked = [_][]const u8{ action_palette.requests_table_name, status_bar.commands_table_name, plugin.panels.commands_table_name, resources.commands_table_name, plugin.action_api.commands_table_name };
    for (asked) |name| result.writeIfPresent(tables, Atom.from(name));
    // The modes the palette found as it opened, which an action picked from it is judged by.
    readIfPresent(&result, tables, Atom.from(action_palette.prompt_modes_table_name));
    // The figure editor's `cancel` and hover, while its stage is shown.
    const heard = frame.messages.len != 0;
    if (heard and figure_workspace.stageShown(tables)) {
        figure_workspace.table_groups.declareEditing(&result);
        // Escape's `cancel` drops a press waiting for its answer.
        figure_workspace.table_groups.declareAsking(&result, tables);
    }
    return result;
}

fn takeEditorMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| _ = updateMessage(frame.memory, frame.tables, frame.atoms, received);
}

fn keepUp(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    sendPendingStartupRequests(frame.tables, frame.atoms);
    // Table windows and widgets show tables other systems write every frame, without word of
    // it, so they draw every frame while shown.
    requestRootRedraw(frame.tables, frame.atoms, inspector.inspector_root);
    try redrawOnHoverChange(pass);
    // From the palette as its last run left it, and from form editing as this run left it.
    syncFocusClicks(frame.tables, frame.atoms);
}

/// Every shown panel draws again when input reports the pointer over another element than the
/// one they drew lit: the element lit and the one dimmed may be in any panel.
fn redrawOnHoverChange(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const app_state_table = Atom.from(state.app_state_name);
    if (frame.tables.findByName(app_state_table) == null) return;
    const hover = input.hovered(frame.tables);
    const drawn = try pass.writeSingleton(app_state_table, struct { drawn_hover: *[16]u8 });
    if (std.mem.eql(u8, drawn.drawn_hover, &hover.element)) return;
    drawn.drawn_hover.* = hover.element;
    // Without the panels, as in a headless run, there is nothing to draw.
    if (frame.tables.findByName(Atom.from(panels_mod.nodes_table_name)) == null) return;
    var shown: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
    for (panels_mod.panels(frame.tables, frame.atoms, &shown)) |panel| panels_mod.requestRedraw(frame.tables, frame.atoms, panel.id);
}

/// Asks for every shown panel with `root` to draw again.
fn requestRootRedraw(tables: *Table.Registry, atoms: *Atom.Registry, root: Atom) void {
    var shown: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
    for (panels_mod.panels(tables, atoms, &shown)) |panel| {
        if (panel.root == root) panels_mod.requestRedraw(tables, atoms, panel.id);
    }
}

/// One panel, which the module that shows it draws, header and all; `frame` is its frame in
/// the window and `ctx` begins at its corner. The figure
/// stage holds the figure editor and its context menu; the profiler and widgets each fill
/// their own. A panel that is none of the editor's, another plugin's, is left to its plugin.
pub fn renderPanel(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, id: Atom, frame: plugin.Viewport, ctx: *roop.Context) void {
    if (!fixed_panels.ownsPanel(tables, atoms, id)) return;
    if (id == atoms.intern(fixed_panels.figure_stage)) {
        const trace_zone = Log.zone(Zone.render_canvas);
        defer trace_zone.end();
        var header: panel_frame.Header = undefined;
        if (header.begin(memory, tables, atoms, id)) {
            if (header.open) chrome.renderDecoration(&header.tree, tables);
            header.finish(tables, atoms, frame, ctx);
        }
        const viewport = panel_frame.beginContent(tables, atoms, id, frame, ctx) orelse return;
        defer panel_frame.endContent(ctx);
        ctx.fontFace(style.ui_font);
        const canvas_result = canvas.render(memory, tables, atoms, viewport, ctx);
        chrome.render(memory, tables, atoms, viewport, ctx, canvas_result);
        color_picker.render(memory, tables, atoms, viewport, ctx);
        context_menu.render(memory, tables, atoms, viewport, kModalDepth + 2, ctx);
        return;
    }
    if (id == atoms.intern(figure_workspace.outliner_id) or id == atoms.intern(figure_workspace.inspector_id)) {
        panels.render(memory, tables, atoms, id, frame, ctx, state.hitRegions(tables, atoms), kHitDepth);
        return;
    }
    if (id == atoms.intern(figure_workspace.sequencer_id)) {
        panels.renderTimeline(memory, tables, atoms, frame, ctx);
        return;
    }
    if (id == atoms.intern(profiler.panel_name)) {
        profiler.render(memory, tables, atoms, frame, ctx);
    } else if (id == vcs_git.panel) {
        git_status_view.render(memory, tables, atoms, frame, ctx);
    } else if (id == git_diff.panel) {
        git_diff.render(memory, tables, atoms, frame, ctx);
    } else if (id == vcs_p4.panel) {
        p4_status_view.render(memory, tables, atoms, frame, ctx);
    } else if (id == p4_diff.panel) {
        p4_diff.render(memory, tables, atoms, frame, ctx);
    } else if (id == plugin_list.panel) {
        plugin_list.render(memory, tables, atoms, frame, ctx);
    } else if (text_panel.isPanel(id)) {
        text_panel.render(memory, tables, atoms, id, frame, ctx);
    } else if (inspector.isPanel(tables, atoms, id)) {
        inspector.renderPanel(memory, tables, atoms, id, frame, ctx);
    }
}

/// The action palette, over the whole window and every view in it. `viewport` is the window.
pub fn renderActionPalette(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: *roop.Context) void {
    const scratch = memory.frameScratchAllocator() catch @panic("OOM");
    const hits = state.hitRegions(tables, atoms);
    const offset = mesha.math.Vec2f{ .x = viewport.x, .y = viewport.y };
    const hovered = state.hoveredElementId(tables);
    action_palette.render(scratch, tables, atoms, viewport.width, viewport.height, offset, hovered, ctx, hits, panels_mod.kActionPaletteHitDepth);
}

test "the editor's first update registers each of its modes once, and a second registers none" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try init(&memory, &atoms, &tables);
    try plugin.action_api.Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, plugin.action_api.commands_table_name);
    state.viewFocus(&tables, &atoms).startup_requests_pending.* = 1;

    const requests = plugin.action_api.Requests.of(&memory, &tables, plugin.action_api.commands_table_name);
    var registered: [2 * modes.names.len]Atom = undefined;
    var count: usize = 0;
    for (0..2) |_| {
        sendPendingStartupRequests(&tables, &atoms);
        var commands: [2 * modes.names.len]plugin.action_api.Command = undefined;
        count = 0;
        for (requests.peek(&commands)) |command| switch (command) {
            .register_mode => |registration| {
                registered[count] = registration.mode;
                count += 1;
            },
            .invoke, .set_modes, .enable_minor, .disable_minor => {},
        };
    }
    // Every mode of the editor's but `global`, the first named, which the actions system
    // registers itself.
    try std.testing.expectEqualStrings("global", modes.names[0]);
    try std.testing.expectEqual(modes.names.len - 1, count);
    for (modes.names[1..]) |mode_text| {
        try std.testing.expect(std.mem.indexOfScalar(Atom, registered[0..count], Atom.from(mode_text)) != null);
    }
}

test {
    _ = inspector;
    _ = text_editor;
    _ = tests;
}

pub const EditorInitCheckpoint = enum { atoms, windows, completions, action_palette, session, drawing, weight, pose, filmstrip, prompts, workspace, commands };
pub const EditorInitOptions = struct { reject_after: ?EditorInitCheckpoint = null };

const init_table_names = [_][]const u8{
    "editor_view_focus",               "editor_active_inspector",        "editor_authoring_ui",
    "editor_action_palette",           "editor_status_bar",              "editor_windows_picker_state",
    "editor_windows",                  "editor_figure_session",          "editor_figure_outliner_tab",
    "editor_figure_selection",         "editor_figure_draft",            "editor_figure_draw",
    "editor_figure_clipboard",         "editor_figure_recent_colors",    "editor_figure_weight",
    "editor_figure_weight_bones",      "editor_figure_pose",             "editor_figure_pose_clipboard_bones",
    "editor_figure_pose_clipboard_ik", "editor_figure_pose_drag_chain",  "editor_figure_animation",
    "editor_figure_preview",           "editor_figure_gesture",          "editor_figure_weight_stroke",
    "editor_figure_weight_targets",    "editor_figure_weight_samples",   "editor_figure_weight_shapes",
    "editor_figure_weight_locks",      "editor_figure_motion",           "editor_profiler",
    "sequencer_systems",               "commands.status_bar",            "commands.figure_canvas",
    "commands.action_palette",         "editor_action_palette_delivery", "commands.table_authoring",
    "table_authoring_outcomes",        "editor_text_panels",             "editor_open",
    "editor_text_jumps",               "editor_text_navigation",
};

const InitTableSnapshot = struct {
    handle: Table.Handle,
    table: *Table,
    bytes: []u8,

    fn feed(tab: *const Table, h: anytype) void {
        h.update(std.mem.asBytes(&tab.schema_ref));
        const capacity = tab.rowCapacity();
        h.update(std.mem.asBytes(&capacity));
        h.update(std.mem.asBytes(&tab.name));
        h.update(std.mem.asBytes(&tab.schema_name));
        h.update(std.mem.asBytes(&tab.uses_named_schema));
        h.update(std.mem.asBytes(&tab.revision));
        h.update(std.mem.asBytes(&tab.required_singleton));
        h.update(std.mem.asBytes(&tab.owner));
        h.update(std.mem.asBytes(&tab.lifetime));
        for (0..tab.generationCount()) |row| {
            const generation = tab.rowGeneration(@intCast(row));
            h.update(std.mem.asBytes(&generation));
        }
        for (0..tab.rowCapacity()) |row| {
            const allocated = tab.isAllocated(@intCast(row));
            h.update(std.mem.asBytes(&allocated));
        }
        for (0..tab.rowCapacity()) |row| {
            const mask = tab.rowMask(@intCast(row));
            h.update(std.mem.asBytes(&mask));
        }
        for (0..tab.reusableRows().len) |free_i| {
            const free_row = tab.reusableRows().at(free_i);
            h.update(std.mem.asBytes(&free_row));
        }
        for (tab.getSchema().fields, 0..) |_, field_index| {
            var rows = tab.rows();
            while (rows.next()) |handle| h.update(tab.rowFieldBytes(handle.row, field_index));
        }
    }

    fn hash(tab: *const Table) u64 {
        var h = std.hash.Wyhash.init(0);
        feed(tab, &h);
        return h.final();
    }

    const Sink = struct {
        bytes: ?[]u8 = null,
        offset: usize = 0,
        compare: bool = false,
        matches: bool = true,
        fn update(self: *@This(), bytes: []const u8) void {
            if (self.bytes) |destination| {
                if (self.offset > destination.len or bytes.len > destination.len - self.offset) {
                    self.matches = false;
                } else if (self.compare) {
                    self.matches = self.matches and std.mem.eql(u8, destination[self.offset..][0..bytes.len], bytes);
                } else @memcpy(destination[self.offset..][0..bytes.len], bytes);
            }
            self.offset += bytes.len;
        }
    };

    fn capture(allocator: std.mem.Allocator, tab: *Table, handle: Table.Handle) !InitTableSnapshot {
        var count: Sink = .{};
        feed(tab, &count);
        const bytes = try allocator.alloc(u8, count.offset);
        var sink: Sink = .{ .bytes = bytes };
        feed(tab, &sink);
        return .{ .table = tab, .handle = handle, .bytes = bytes };
    }

    fn unchanged(self: InitTableSnapshot, tab: *Table) bool {
        var sink: Sink = .{ .bytes = self.bytes, .compare = true };
        feed(tab, &sink);
        return sink.matches and sink.offset == self.bytes.len;
    }
};

/// Invocation-local copied plan. Root must validate every packet before resource
/// commits, then freeze all snapshot destinations until this allocation-free tail.
pub const PreparedEditorInit = struct {
    tables: *Table.Registry,
    temporary: std.mem.Allocator,
    snapshots: [init_table_names.len]InitTableSnapshot,
    focus_clicks: *u8,
    startup_requests_pending: *u8,
    /// The transient menu's row, whose menu an earlier image showed is lost as the plan applies.
    transient_menu: transient.Lost,
    focus_clicks_wanted: FocusClicks,
    reject_commands: bool,
    /// The editor's keymaps, built, which `apply` installs.
    keymaps: PreparedKeymaps,
    stage_attempted: bool = false,
    staged: bool = false,
    validated: bool = false,
    applied: bool = false,

    pub fn deinit(self: *PreparedEditorInit) void {
        for (&self.snapshots) |*saved| {
            self.temporary.free(saved.bytes);
            saved.bytes = &.{};
        }
        self.validated = false;
    }

    pub fn validate(self: *PreparedEditorInit) !void {
        self.validated = false;
        if (self.applied or !self.staged) return error.InvalidEditorInitState;
        for (self.snapshots) |saved| {
            const current = self.tables.get(saved.handle) orelse return error.StaleEditorInit;
            if (current != saved.table or !saved.unchanged(current)) return error.StaleEditorInit;
        }
        self.validated = true;
    }

    /// Stages the plan for validation. It sends nothing: what it asks for waits for the
    /// editor's first update, which `apply` marks.
    pub fn stage(self: *PreparedEditorInit) !void {
        if (self.stage_attempted or self.applied) return error.InvalidEditorInitState;
        self.stage_attempted = true;
        if (self.reject_commands) return error.EditorInitInjectedFailure;
        self.staged = true;
    }

    pub fn apply(self: *PreparedEditorInit) void {
        if (!self.validated or self.applied) @panic("editor.init.unvalidated_or_repeated_apply");
        self.applied = true;
        self.focus_clicks.* = @intFromEnum(self.focus_clicks_wanted);
        self.startup_requests_pending.* = 1;
        transient.loseMenu(self.transient_menu);
        self.keymaps.install();
    }
};

fn editorInitCheckpoint(options: EditorInitOptions, checkpoint: EditorInitCheckpoint) !void {
    if (options.reject_after == checkpoint) return error.EditorInitInjectedFailure;
}

pub fn prepareEditorInit(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, options: EditorInitOptions) !PreparedEditorInit {
    if (memory.admission == null or tables.admission == null) return error.EditorAdmissionRequired;
    const old_scope = tables.scope;
    tables.scope = .editor;
    defer tables.scope = old_scope;
    // The text editors' names, so tools inspecting the palette and the inspector can read them.
    const text_editor_names = [_][]const u8{ "prompt_text", "inspector_text" };
    try atoms.tryInternAll(&([_][]const u8{"editor"} ++ text_editor_names ++ modes.names));
    // The keymaps are built here, once, and installed as the plan applies.
    const keymaps = try prepareKeymaps(memory, atoms);
    try editorInitCheckpoint(options, .atoms);
    const scratch = try memory.frameScratchAllocator();
    try windows.prepareInit(scratch, atoms, tables);
    try editorInitCheckpoint(options, .windows);
    try action_palette.prepareCompletionArenas(memory, atoms);
    try editorInitCheckpoint(options, .completions);
    // A distinct compatibility pass, with no old-row reset.
    try action_palette.prepareInit(scratch, atoms, tables);
    try editorInitCheckpoint(options, .action_palette);
    const workspace_checkpoint: ?figure_workspace.InitCheckpoint = if (options.reject_after) |cp| switch (cp) {
        .session => .session,
        .drawing => .drawing,
        .weight => .weight,
        .pose => .pose,
        .filmstrip => .filmstrip,
        .prompts => .prompts,
        else => null,
    } else null;
    try figure_workspace.prepareInit(memory, atoms, tables, workspace_checkpoint);
    try editorInitCheckpoint(options, .workspace);

    const focus = state.viewFocus(tables, atoms);
    var result: PreparedEditorInit = .{
        .tables = tables,
        .temporary = memory.globalAllocator(),
        .snapshots = undefined,
        .focus_clicks = focus.focus_clicks_disabled,
        .startup_requests_pending = focus.startup_requests_pending,
        .transient_menu = transient.lostFields(tables),
        .focus_clicks_wanted = focusClicksWanted(tables, atoms),
        .reject_commands = options.reject_after == .commands,
        .keymaps = keymaps,
    };
    var captured: usize = 0;
    errdefer for (result.snapshots[0..captured]) |saved| memory.globalAllocator().free(saved.bytes);
    inline for (init_table_names, 0..) |name, i| {
        const handle = tables.findHandleByName(atoms.intern(name)).?;
        const tab = tables.get(handle).?;
        result.snapshots[i] = try InitTableSnapshot.capture(memory.globalAllocator(), tab, handle);
        captured += 1;
    }
    return result;
}

test "editor preparation checkpoints preserve warm prompt form capture selection and focus" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try init(&memory, &atoms, &tables);
    const focus = state.viewFocus(&tables, &atoms);
    focus.id.* = atoms.intern("custom_focus");
    focus.focus_clicks_disabled.* = 0;
    state.authoringUi(&tables, &atoms).form_focus.* = 3;
    const prompt = action_palette.prompt(&tables, &atoms);
    prompt.request_open.* = 1;
    prompt.request_presentation.* = @intFromEnum(action_palette.Completions.Presentation.prompt);
    try tables.findByName(Atom.from(action_palette.table_name)).?.assignString(prompt.text, "MMMM");
    prompt.completions_ptr.* = 12345;
    const session = figure_workspace.session.get(&tables);
    session.gesture_active.* = 1;
    session.mode.* = atoms.intern("animate");
    session.prompt_id.* = 42;
    const selected: figure_workspace.session.Selection = .{ .id = 72, .primary = 1 };
    _ = try figure_workspace.session.selections(&tables).insert(selected);
    var before: [init_table_names.len]u64 = undefined;
    inline for (init_table_names, 0..) |name, i| before[i] = InitTableSnapshot.hash(tables.findByName(Atom.from(name)).?);
    const arena = try action_palette.completionAllocator(&memory, .action_list);
    const retained = try arena.dupe(u8, "completion survives");
    inline for (std.meta.fields(EditorInitCheckpoint)) |checkpoint| {
        const mem = try memory.beginInitAdmission();
        const tab = try tables.beginInitAdmission();
        const cp: EditorInitCheckpoint = @enumFromInt(checkpoint.value);
        if (cp == .commands) {
            var plan = try prepareEditorInit(&memory, &atoms, &tables, .{ .reject_after = cp });
            defer plan.deinit();
            try std.testing.expectError(error.EditorInitInjectedFailure, plan.stage());
        } else try std.testing.expectError(error.EditorInitInjectedFailure, prepareEditorInit(&memory, &atoms, &tables, .{ .reject_after = cp }));
        for (init_table_names, 0..) |name, i| {
            const table = tables.findByName(atoms.intern(name)).?;
            try std.testing.expectEqual(before[i], InitTableSnapshot.hash(table));
        }
        try std.testing.expectEqualStrings("completion survives", retained);
        try std.testing.expect(tables.abortInitAdmission(tab));
        try std.testing.expect(memory.abortInitAdmission(mem));
    }
    const mem = try memory.beginInitAdmission();
    const tab = try tables.beginInitAdmission();
    var accepted = try prepareEditorInit(&memory, &atoms, &tables, .{});
    defer accepted.deinit();
    try accepted.stage();
    try accepted.validate();
    try tables.validateInitAdmission(tab);
    try memory.validateInitAdmission(mem);
    try std.testing.expect(tables.commitInitAdmission(tab));
    try std.testing.expect(memory.commitInitAdmission(mem));
    accepted.apply();
    // The prompt open is the minibuffer's.
    try std.testing.expectEqual(@as(u8, 2), focus.focus_clicks_disabled.*);
    // The startup requests wait for the editor's first update, past admission.
    try std.testing.expectEqual(@as(u8, 1), focus.startup_requests_pending.*);
    try std.testing.expectEqual(Atom.from("custom_focus"), focus.id.*);
    try std.testing.expectEqual(@as(usize, 12345), prompt.completions_ptr.*);
    try std.testing.expectEqual(@as(u8, 1), session.gesture_active.*);
    // The first update tells the panels the focus clicks the plan recorded.
    try plugin.panels.Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, plugin.panels.commands_table_name);
    sendPendingStartupRequests(&tables, &atoms);
    var sent: [2]plugin.panels.CmdPayload = undefined;
    const told = plugin.panels.Requests.of(&memory, &tables, plugin.panels.commands_table_name).peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expect(told[0] == .disable_focus_clicks);
}

fn arenaTotal(memory: *const memory_mod.Memory) usize {
    var total: usize = 0;
    for (memory.scopes.items) |scope| total += scope.stats().dynamic_arena_count;
    return total;
}

test "editor preparation provisional cleanup terminal defaults and stale validation" {
    var memory: memory_mod.Memory = undefined;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    memory.init(failing.allocator());
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    inline for (std.meta.fields(EditorInitCheckpoint)) |checkpoint| {
        const mem = try memory.beginInitAdmission();
        const tab = try tables.beginInitAdmission();
        const cp: EditorInitCheckpoint = @enumFromInt(checkpoint.value);
        if (cp == .commands) {
            var plan = try prepareEditorInit(&memory, &atoms, &tables, .{ .reject_after = cp });
            defer plan.deinit();
            try std.testing.expectError(error.EditorInitInjectedFailure, plan.stage());
        } else try std.testing.expectError(error.EditorInitInjectedFailure, prepareEditorInit(&memory, &atoms, &tables, .{ .reject_after = cp }));
        try std.testing.expect(tables.abortInitAdmission(tab));
        try std.testing.expect(memory.abortInitAdmission(mem));
        try std.testing.expect(tables.findByName(Atom.from(state.windows_name)) == null);
        for (memory.scopes.items) |scope| try std.testing.expect(scope.id.atom != Atom.from(action_palette.completions_scope_name));
    }
    const mem = try memory.beginInitAdmission();
    const tab = try tables.beginInitAdmission();
    var plan = try prepareEditorInit(&memory, &atoms, &tables, .{});
    defer plan.deinit();
    try plan.stage();
    const focus = state.viewFocus(&tables, &atoms);
    focus.focus_clicks_disabled.* = 1;
    try std.testing.expectError(error.StaleEditorInit, plan.validate());
    focus.focus_clicks_disabled.* = 0;
    try plan.validate();
    try tables.validateInitAdmission(tab);
    try memory.validateInitAdmission(mem);
    try std.testing.expect(tables.commitInitAdmission(tab));
    try std.testing.expect(memory.commitInitAdmission(mem));
    const owners = arenaTotal(&memory);
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    plan.apply();
    try std.testing.expectEqual(allocations, failing.alloc_index);
    try std.testing.expectEqual(owners, arenaTotal(&memory));
    try std.testing.expectEqual(@as(u8, 0), focus.focus_clicks_disabled.*);
    const default_mode = figure_workspace.session.get(&tables).mode.*;
    try std.testing.expectEqual(Atom.from("design"), default_mode);
    // The editor's packet sends nothing during admission.

    // The editor's first update asks resources for what it starts with, once.
    failing.fail_index = std.math.maxInt(usize);
    try resources.Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, resources.commands_table_name);
    try plugin.panels.Requests.ensure(try memory.tableScratchAllocator(), &atoms, &tables, plugin.panels.commands_table_name);
    try std.testing.expectEqual(@as(u8, 1), focus.startup_requests_pending.*);
    sendPendingStartupRequests(&tables, &atoms);
    var sent: [2]plugin.panels.CmdPayload = undefined;
    const told = plugin.panels.Requests.of(&memory, &tables, plugin.panels.commands_table_name).peek(&sent);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expect(told[0] == .enable_focus_clicks);
    const requested = resources.Requests.of(&memory, &tables, resources.commands_table_name).count();
    // The table index and the fallback fonts.
    try std.testing.expectEqual(@as(u32, 2), requested);
    try std.testing.expectEqual(@as(u8, 0), focus.startup_requests_pending.*);
    sendPendingStartupRequests(&tables, &atoms);
    try std.testing.expectEqual(requested, resources.Requests.of(&memory, &tables, resources.commands_table_name).count());
}

fn editorPreparationAllocationFixture(allocator: std.mem.Allocator) !void {
    var memory: memory_mod.Memory = undefined;
    memory.init(allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    // The host opens this before any plugin stages a request.
    _ = try memory.openScope(resources.kApplicationScope);
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    var plan = try prepareEditorInit(&memory, &atoms, &tables, .{});
    defer plan.deinit();
    try plan.stage();
    try plan.validate();
}

test "editor preparation native allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, editorPreparationAllocationFixture, .{});
}

test "editor preparation atom exhaustion rejects without writes" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    // Exhaustion at the first init preregistration is a recoverable error.
    var tiny_memory: memory_mod.Memory = undefined;
    tiny_memory.init(std.testing.allocator);
    defer tiny_memory.deinit();
    var tiny: Atom.Registry = undefined;
    try tiny.init(&tiny_memory);
    defer tiny.deinit();
    tiny.storage_limit_for_test = 1;
    try std.testing.expectError(error.OutOfMemory, prepareEditorInit(&memory, &tiny, &tables, .{}));
}

test "editor preparation singleton capacity schema mismatch and command copy protect old sentinel" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try init(&memory, &atoms, &tables);
    const session_source = tables.findByName(Atom.from(figure_workspace.session.name)).?;
    const incompatible_handle = try tables.create(session_source.getSchema(), 2, Atom.from("test_incompatible_session"), .durable);
    const incompatible_session = tables.get(incompatible_handle).?;
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    const session = tables.findByName(Atom.from(figure_workspace.session.name)).?;
    const before = InitTableSnapshot.hash(session);
    session.required_singleton = false;
    try std.testing.expectError(error.InvalidEditorSingleton, prepareEditorInit(&memory, &atoms, &tables, .{}));
    try std.testing.expect(!session.required_singleton);
    session.required_singleton = true;
    {
        const original_session = session.*;
        defer session.* = original_session;
        session.* = incompatible_session.*;
        session.name = original_session.name;
        session.required_singleton = true;
        try std.testing.expectError(error.InvalidEditorSingleton, prepareEditorInit(&memory, &atoms, &tables, .{}));
    }
    try std.testing.expectEqual(before, InitTableSnapshot.hash(session));
    try std.testing.expectError(error.SchemaMismatch, figure_workspace.session.prepareSingleton(struct { wrong: u32 = 0 }, &memory, &atoms, &tables, figure_workspace.session.name));
    var plan = try prepareEditorInit(&memory, &atoms, &tables, .{});
    defer plan.deinit();
    try std.testing.expectEqual(before, InitTableSnapshot.hash(session));
}

test "editor preparation atom exhaustion across actual schema vocabulary remains fallible" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try init(&memory, &atoms, &tables);
    // Register the additional preparation vocabulary first, then exhaust one
    // actually used name at a time. No schema panic-intern may bypass preflight.
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    var warm = try prepareEditorInit(&memory, &atoms, &tables, .{});
    defer warm.deinit();
    inline for (init_table_names) |name| {
        const table = tables.findByName(Atom.from(name)).?;
        for (table.schema_ref.schema.fields) |field| {
            const id = Atom.from(field.name);
            const field_name = atoms.removeForTest(id).?;
            atoms.storage_limit_for_test = 0;
            const result = prepareEditorInit(&memory, &atoms, &tables, .{});
            atoms.storage_limit_for_test = null;
            atoms.restoreForTest(id, field_name);
            try std.testing.expectError(error.OutOfMemory, result);
        }
    }
}

test "editor preparation actual registry capacity mismatch preserves accepted windows" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 64);
    defer tables.deinit();
    try init(&memory, &atoms, &tables);
    const identity = tables.findHandleByName(Atom.from(state.windows_name)).?;
    const old = tables.get(identity).?;
    const record = old.schema_ref;
    const replacement = try tables.createSingleton(&record.schema, atoms.intern("undersized_windows_fixture"), .durable);
    tables.destroy(identity);
    tables.get(replacement).?.name = Atom.from(state.windows_name);
    const accepted = tables.get(replacement).?;
    const before = InitTableSnapshot.hash(accepted);
    const mem = try memory.beginInitAdmission();
    defer _ = memory.abortInitAdmission(mem);
    const tab = try tables.beginInitAdmission();
    defer _ = tables.abortInitAdmission(tab);
    try std.testing.expectError(error.SchemaMismatch, prepareEditorInit(&memory, &atoms, &tables, .{}));
    try std.testing.expect(accepted == tables.get(replacement).?);
    try std.testing.expectEqual(before, InitTableSnapshot.hash(accepted));
}
