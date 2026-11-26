//! The list of plugins: a panel showing a page, `editor/assets/documents/plugins.org`, of every
//! plugin the host has a row for (`plugin.plugins`), with whether it is loaded, how its newest
//! build went, when its library last loaded and how many times it has: what tells a person a
//! reload happened. Nothing builds a plugin until asked: `g` asks the host to build every
//! plugin again (`plugin.plugins.Build`), and each library a build installs reloads as it lands.
//!
//! - `global.plugins_show` (`C-x P`) shows the panel at the window's right and gives
//!   it the focus.
//! - In the panel (mode `plugin_list`) the keys move through the page as vcs-git's do, `tab`
//!   folds, `g` builds every plugin, `RET` shows the buffer the build of the plugin at the
//!   cursor tells its lines to (`*plugins build*`, `*plugin <name>*`), and `q` closes it.
//! - What it publishes (`document/sources.zig`): the source `plugins.loaded`, a row a plugin
//!   (`ListRow`), in the order of the host's rows, and the value `plugins.build`, which says which
//!   builds run. Both are written again only when what they would hold changed, read from the
//!   host's tables `plugins`, `watch` and `watch_plugins` each run while the panel is shown.

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
const ui = mesha.ui;
const keybinds = mesha.keybinds;
const watch_api = mesha.watch;
const plugins_api = plugin.plugins;
const text_editor = plugin.text_editor_api;
const vcs_page = @import("vcs/page.zig");
const modes = @import("modes.zig");
const fixed_panels = @import("fixed_panels.zig");
const text_panel = @import("text_panel.zig");
const panel_frame = @import("panel_frame.zig");
const editor_state = @import("state.zig");
const style = @import("ui/style.zig");
const table_view = @import("table_view.zig");
const document = @import("document/document.zig");
const document_view = @import("document/view.zig");
const document_sources = @import("document/sources.zig");
const editor_sequencer = @import("editor_sequencer.zig");

const Log = mesha.log.scope("plugin_list");

// ---- the panel -----------------------------------------------------------------------------

/// The panel's id.
pub const panel_name = "plugin_list";
/// The panel's id, as an atom.
pub const panel = Atom.from(panel_name);
/// The root of the panel's system: its panel draws again when the system changes a table.
pub const plugin_list_root = Atom.from("plugin_list");

/// The panel, a fixed panel `fixed_panels` declares while it is shown: along the right
/// edge of the window.
pub const fixed_panel: plugin.panels.Open = .{ .id = panel, .title = "Plugins", .root = plugin_list_root, .side = .right, .share = 0.45 };

// ---- the messages, the actions and their keys ----------------------------------------------

/// What the panel's system takes: its actions, the host's answer to a build and what its
/// drawing sends.
pub const Msg = enum(u64) {
    /// Shows the panel.
    plugins_show = Atom.from("plugins_show").value(),
    plugin_list_next = Atom.from("plugin_list_next").value(),
    plugin_list_previous = Atom.from("plugin_list_previous").value(),
    plugin_list_first = Atom.from("plugin_list_first").value(),
    plugin_list_last = Atom.from("plugin_list_last").value(),
    plugin_list_page_down = Atom.from("plugin_list_page_down").value(),
    plugin_list_page_up = Atom.from("plugin_list_page_up").value(),
    plugin_list_toggle = Atom.from("plugin_list_toggle").value(),
    plugin_list_toggle_all = Atom.from("plugin_list_toggle_all").value(),
    plugin_list_visit = Atom.from("plugin_list_visit").value(),
    plugin_list_build = Atom.from("plugin_list_build").value(),
    plugin_list_quit = Atom.from("plugin_list_quit").value(),
    /// The host's answer to a build, a `plugins.Answer`.
    plugin_list_built = Atom.from("plugin_list_built").value(),
    /// A click on a heading or a line of the page, a `document.Click`.
    plugin_list_click = Atom.from("plugin_list_click").value(),
    /// A click on a heading's fold mark, a `document.Click`.
    plugin_list_fold = Atom.from("plugin_list_fold").value(),
    /// The wheel over the page, an `input.MouseScrollMsg`.
    plugin_list_wheel = Atom.from("plugin_list_wheel").value(),
    _,
};

/// The panel's action of `global`, offered from anywhere.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "plugins_show", .tag = @tagName(Msg.plugins_show), .doc = "Show the plugins loaded, how each last built and when each last loaded" },
};

/// The keys of `actions`, of `global`: `C-x S-p`, Emacs's `C-x P`, beside the project prefix.
pub const global_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-x S-p", .action = .{ "global", "plugins_show" } },
};

/// The actions of mode `plugin_list`.
pub const list_actions = [_]plugin.action_api.Def{
    .{ .name = "next", .tag = @tagName(Msg.plugin_list_next), .doc = "Move to the next line or row" },
    .{ .name = "previous", .tag = @tagName(Msg.plugin_list_previous), .doc = "Move to the line or row before" },
    .{ .name = "first", .tag = @tagName(Msg.plugin_list_first), .doc = "Move to the first line" },
    .{ .name = "last", .tag = @tagName(Msg.plugin_list_last), .doc = "Move to the last line" },
    .{ .name = "page_down", .tag = @tagName(Msg.plugin_list_page_down), .doc = "Move a page down" },
    .{ .name = "page_up", .tag = @tagName(Msg.plugin_list_page_up), .doc = "Move a page up" },
    .{ .name = "toggle", .tag = @tagName(Msg.plugin_list_toggle), .doc = "Fold or open the heading the cursor is under" },
    .{ .name = "toggle_all", .tag = @tagName(Msg.plugin_list_toggle_all), .doc = "Fold every heading, or open them all" },
    .{ .name = "visit", .tag = @tagName(Msg.plugin_list_visit), .doc = "Show what the build of the plugin at the cursor said" },
    .{ .name = "build", .tag = @tagName(Msg.plugin_list_build), .doc = "Build every plugin again; each reloads as its library lands" },
    .{ .name = "quit", .tag = @tagName(Msg.plugin_list_quit), .doc = "Close the list of plugins" },
};

/// The keys of mode `plugin_list`, vcs-git's for the same ideas (`n` `p` `tab` `RET` `q`), and
/// `g` building, where vcs-git asks git again.
pub const list_keys = [_]keybinds.KeyDef{
    .{ .chord = "n", .action = .{ "plugin_list", "next" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "plugin_list", "next" }, .trigger = .repeat },
    .{ .chord = "p", .action = .{ "plugin_list", "previous" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "plugin_list", "previous" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "plugin_list", "first" } },
    .{ .chord = "M-S-period", .action = .{ "plugin_list", "last" } },
    .{ .chord = "C-v", .action = .{ "plugin_list", "page_down" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "plugin_list", "page_up" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "plugin_list", "toggle" } },
    .{ .chord = "S-tab", .action = .{ "plugin_list", "toggle_all" } },
    .{ .chord = "RET", .action = .{ "plugin_list", "visit" } },
    .{ .chord = "g", .action = .{ "plugin_list", "build" } },
    .{ .chord = "q", .action = .{ "plugin_list", "quit" } },
};

/// Offers the actions of mode `plugin_list`, this system taking them, every frame: the mode
/// decides when they are live.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    const inbox = sequencer.inboxOf(system());
    for (list_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.plugin_list, inbox, &.{.{ .def = def }});
}

// ---- the tables and the page ---------------------------------------------------------------

/// `editor_plugin_list`: a row a plugin, in the order of the host's rows (`ListRow`): the source
/// `plugins.loaded`.
pub const list_table_name = "editor_plugin_list";
/// `editor_plugin_list_view`: the page's cursor, scroll and view (`document.StateRow`) and its
/// `cursor_moved_under`; one row.
pub const view_table_name = "editor_plugin_list_view";
/// `editor_plugin_list_folds`: the page's folds.
pub const folds_table_name = "editor_plugin_list_folds";
/// The panel's major mode, kept as the panel takes the focus.
pub const panel_modes_table_name = "editor_plugin_list_panel_modes";

const list_table = Atom.from(list_table_name);
const view_table = Atom.from(view_table_name);
const folds_table = Atom.from(folds_table_name);

/// The name the list is published as.
pub const source_name = "plugins.loaded";
/// The value that says which builds run.
pub const build_value = "plugins.build";

/// A row of `editor_plugin_list`, each cell text for showing but `buffer`.
pub const ListRow = struct {
    /// The plugin's name.
    name: []const u8,
    /// `loaded`, `waiting` or `refused`: the host's `plugins.State`.
    state: []const u8,
    /// How its newest build went: `building`, `built`, `failed`; empty for a plugin with no
    /// build.
    build: []const u8,
    /// When its library last loaded, local time, `YYYY-MM-DD HH:MM:SS`; empty while it never
    /// has.
    loaded: []const u8,
    /// How many times its library has loaded in this run.
    loads: []const u8,
    /// Its directory.
    directory: []const u8,
    /// The buffer its build tells its lines to; empty for a plugin with no build.
    buffer: []const u8,
};

const list_fields = [_][]const u8{ "name", "state", "build", "loaded", "loads", "directory", "buffer" };
const list_shown = [_][]const u8{ "name", "state", "build", "loaded", "loads", "directory" };

/// The most plugins the list holds.
const max_plugins = 64;

/// The page, `editor/assets/documents/plugins.org`, compiled in.
pub const list_document = @embedFile("plugins_document");

/// The page: its state in `editor_plugin_list_view`, its folds in `editor_plugin_list_folds`.
pub const page: vcs_page.Page = .{
    .document = vcs_page.parsePage(list_document, "plugins.org"),
    .name = "plugin_list_document",
    .state_table = view_table,
    .folds_table = folds_table,
    .tags = .{
        .click = Atom.from(Msg.plugin_list_click),
        .toggle = Atom.from(Msg.plugin_list_fold),
        .wheel = Atom.from(Msg.plugin_list_wheel),
    },
    .resize_reader_name = "plugin_list_resizes",
    .moved_under_sentence = "The plugins changed under the cursor",
};

/// Makes the panel's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ list_table_name, view_table_name, folds_table_name, panel_name });

    var list: Table.Schema = undefined;
    try list.init(scratch.allocator, atoms, list_fields.len);
    defer list.deinit();
    for (list_fields) |field| try list.addFieldFallible(field, Table.String, .text_field);
    _ = try tables.ensure(&list, max_plugins, list_table, .durable);

    var view: Table.Schema = undefined;
    try view.init(scratch.allocator, atoms, 1 + std.meta.fields(document.StateRow).len);
    defer view.deinit();
    try view.addFieldFallible("cursor_moved_under", u8, .int);
    try document.addStateFields(&view);
    const defaults = .{
        .cursor_moved_under = @as(u8, 0),
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
    _ = try tables.ensureSingleton(&view, view_table, defaults, .durable);

    var folds: Table.Schema = undefined;
    try folds.init(scratch.allocator, atoms, 1);
    defer folds.deinit();
    try document.addFoldFields(&folds);
    const max_folds = 16;
    _ = try tables.ensure(&folds, max_folds, folds_table, .durable);

    try document_sources.ensure(scratch, atoms, tables);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
}

// ---- the system ----------------------------------------------------------------------------

/// The panel's system: its kernels take the panel's messages, keep the list as the host's
/// tables say while the panel is shown, keep the page fit to the panel and ask for its mode.
pub fn system() sequencer.System {
    return .{
        .name = "plugin_list",
        .names = comptime &(sequencer.enumNames(Msg) ++ sequencer.enumNames(ui.grid.Msg) ++ [_][]const u8{panel_modes_table_name} ++ page.names() ++ document_view.element_names),
        .root = plugin_list_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "plugin_list.take_messages", .run = takeMessages },
            .{ .name = "plugin_list.follow_plugins", .run = followPlugins },
            .{ .name = "plugin_list.follow_layout", .run = followLayout },
            .{ .name = "plugin_list.follow_modes", .run = followModes },
        },
    };
}

fn claims(tag: Atom) bool {
    // The grid of the page's table sends its clicks to the system: a click on a row is the
    // page's.
    switch (tag.to(ui.grid.Msg)) {
        _ => {},
        else => return true,
    }
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

const host_plugins_table = Atom.from(plugins_api.table_name);
const watch_table = Atom.from(watch_api.state_table_name);
const watch_plugins_table = Atom.from(watch_api.plugins_table_name);
const plugin_requests_table = Atom.from(plugins_api.commands_table_name);
const text_editor_requests = Atom.from(text_editor.commands_table_name);
const document_sources_table = Atom.from(document_sources.sources_table_name);
const document_values_table = Atom.from(document_sources.values_table_name);
const shown_panels_table = Atom.from(fixed_panels.shown_panels_table_name);
const panel_requests_table = Atom.from(plugin.panels.commands_table_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const show_requests_table = Atom.from(text_panel.show_requests_table_name);
const font_metrics_table = Atom.from(resources.font_metrics_table_name);

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.write(list_table);
    page.declareAccess(&result, tables);
    result.writeIfPresent(tables, document_sources_table);
    result.writeIfPresent(tables, document_values_table);
    // Without the host's tables, as in a test, the list is empty.
    for ([_]Atom{ host_plugins_table, watch_table, watch_plugins_table, panel_nodes_table, panel_state_table, font_metrics_table }) |name| {
        if (tables.findByName(name) != null) result.read(name);
    }
    result.writeIfPresent(tables, plugin_requests_table);
    result.writeIfPresent(tables, text_editor_requests);
    result.writeIfPresent(tables, shown_panels_table);
    result.writeIfPresent(tables, panel_requests_table);
    result.writeIfPresent(tables, show_requests_table);
    plugin.panels.Events.declare(&result, tables, plugin.panels.events_table_name);
    modes.declarePanelModes(&result, tables, panel_modes_table_name);
    return result;
}

/// Each message the system claimed this frame, in order; then the page's cursor settled
/// against the page as it is now.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    for (frame.messages) |received| {
        take(pass, received) catch |err| received.unreadable(err);
    }
    try vcs_page.settle(pass, page, .keep);
    const moved_under = try vcs_page.movedUnder(pass, page);
    if (moved_under.* != 0) moved_under.* = 0;
}

fn take(pass: *sequencer.Pass, received: sequencer.Message) !void {
    if (try takeOnPage(pass, received)) return;
    const memory = pass.frame.memory;
    const tables = pass.frame.tables;
    const way: document.Step = switch (received.tag.to(Msg)) {
        .plugins_show => return show(pass),
        .plugin_list_next => .next,
        .plugin_list_previous => .previous,
        .plugin_list_first => .first,
        .plugin_list_last => .last,
        .plugin_list_page_down => .page_down,
        .plugin_list_page_up => .page_up,
        .plugin_list_toggle => return vcs_page.fold(pass, page, .at_cursor),
        .plugin_list_toggle_all => return vcs_page.fold(pass, page, .every),
        .plugin_list_visit => {
            if (try vcs_page.changedUnderCursor(pass, page)) return;
            return visitAt(pass, try vcs_page.atCursor(pass, page));
        },
        .plugin_list_build => {
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.plugin_list_built));
            plugins_api.request(memory, tables, .{ .build = .{ .reply = reply } });
            return;
        },
        .plugin_list_built => {
            const answer = try received.payloadAs(plugins_api.Answer);
            const sentence = switch (answer.result) {
                .building => "Building every plugin; each reloads as its library is built.",
                .builds_off => "Builds are off (MESHA_NO_BUILD): no plugin was built.",
                else => "No plugin was built.",
            };
            text_editor.message(memory, tables, sentence);
            return;
        },
        .plugin_list_quit => return fixed_panels.hidePanel(tables, panel),
        .plugin_list_click, .plugin_list_fold, .plugin_list_wheel, _ => return,
    };
    const laid_out = try vcs_page.laidOut(pass, page);
    document.step(laid_out, try vcs_page.stateOf(pass, page), way);
}

/// A message of the page (a click, a fold mark, the wheel), or a click on a row of its table,
/// through `document.take`: whether it was the page's. A click on what the cursor is already
/// on is chosen, as RET chooses it.
fn takeOnPage(pass: *sequencer.Pass, received: sequencer.Message) !bool {
    const tags = page.tags;
    const own = received.tag == tags.click or received.tag == tags.toggle or received.tag == tags.wheel;
    const grid_click = received.tag == Atom.from(ui.grid.Msg.cell_click);
    if (!own and !grid_click) return false;
    const laid_out = try vcs_page.laidOut(pass, page);
    const state = try vcs_page.stateOf(pass, page);
    const folds = try vcs_page.foldRows(pass, page);
    switch (try document.take(received, laid_out, state, folds, page.input())) {
        .ignored => return own,
        .moved, .scrolled, .toggled => return true,
        .chosen => |chosen| {
            if (!try vcs_page.changedUnderCursor(pass, page)) try visitAt(pass, chosen);
            return true;
        },
    }
}

/// `global.plugins_show`: shows the panel and gives it the focus, the
/// list published at once.
fn show(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    fixed_panels.showPanel(tables, atoms, panel, .arranged, .take);
    try publish(pass);
}

/// RET on a plugin's row: the buffer its build tells its lines to, in the other window. A
/// plugin with no build says so.
fn visitAt(pass: *sequencer.Pass, at: document.At) !void {
    const tables = pass.frame.tables;
    const row = switch (at) {
        .row => |on_row| on_row,
        else => return,
    };
    if (!std.mem.eql(u8, row.source, source_name)) return;
    const listed = row.table.readRow(row.row, ListRow) orelse return;
    if (listed.buffer.len == 0) {
        text_editor.message(pass.frame.memory, tables, "That plugin has no build: its library is loaded as it is.");
        return;
    }
    text_panel.showBuffer(tables, Atom.from(listed.buffer), .other_window);
}

/// While the panel is shown, the list and the build's value as the host's tables say.
fn followPlugins(pass: *sequencer.Pass) !void {
    if (!isShown(pass)) return;
    try publish(pass);
}

/// Keeps the page fit to its panel as it is resized.
fn followLayout(pass: *sequencer.Pass) !void {
    try vcs_page.followSize(pass, page, panel);
}

/// The panel's major mode, `plugin_list`.
fn followModes(pass: *sequencer.Pass) !void {
    const wanted = [_]modes.PanelMajor{.{ .panel = panel, .major = modes.plugin_list }};
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

/// Whether the panel is shown: declared, open or about to open.
pub fn isShown(pass: *const sequencer.Pass) bool {
    if (!pass.declares(shown_panels_table)) return false;
    return fixed_panels.panelShown(pass.frame.tables, panel);
}

// ---- what is published -------------------------------------------------------------------------

/// Publishes the list and the build's value, writing the list's rows only when what they hold
/// differs from what the host's tables say now.
fn publish(pass: *sequencer.Pass) !void {
    const publishing = try document_sources.Publishing.of(pass) orelse return;
    const allocator = (try pass.frame.memory.frameScratchAllocator()).allocator;
    const listed = try listedNow(pass, allocator);
    publishing.publishSource(plugin_list_root, .{ .name = source_name, .table = list_table, .shown = &list_shown });
    publishing.publishValue(plugin_list_root, build_value, try buildNote(pass, allocator));
    const list = try pass.table(list_table);
    if (sameList(list, listed)) return;
    const rows = try pass.writeTable(list_table);
    const count: u32 = @intCast(listed.len);
    const handles = try table_view.rowsInOrder(rows, count, allocator);
    for (listed, handles) |wanted, handle| {
        inline for (list_fields) |field| try rows.setString(handle, field, @field(wanted, field));
    }
}

/// A row of the list as it is to read: its texts, in the frame's scratch.
const Listed = struct {
    name: []const u8,
    state: []const u8,
    build: []const u8,
    loaded: []const u8,
    loads: []const u8,
    directory: []const u8,
    buffer: []const u8,
};

/// The host's rows of `plugins` as the list shows them, in the table's order, at most
/// `max_plugins`, in `allocator`.
fn listedNow(pass: *sequencer.Pass, allocator: std.mem.Allocator) ![]const Listed {
    var listed: std.ArrayList(Listed) = .empty;
    if (!pass.declares(host_plugins_table)) return listed.items;
    const hosted = try pass.table(host_plugins_table);
    var rows = hosted.readQuery(plugins_api.Row);
    while (rows.next()) |found| {
        if (listed.items.len == max_plugins) break;
        const row = found.view;
        const name_atom = row.name.*;
        const name = pass.frame.atoms.lookup(name_atom) orelse "";
        const state: plugins_api.State = std.enums.fromInt(plugins_api.State, row.state.*) orelse .waiting;
        const built = try buildOf(pass, name_atom);
        const loaded = if (row.loaded_at.* == 0) "" else try localTime(allocator, row.loaded_at.*, row.loaded_utc_offset.*);
        const loads = try std.fmt.allocPrint(allocator, "{d}", .{row.loads.*});
        try listed.append(allocator, .{
            .name = try ui.displayText(allocator, name),
            .state = @tagName(state),
            .build = built.word,
            .loaded = loaded,
            .loads = loads,
            .directory = try ui.displayText(allocator, row.directory),
            .buffer = built.buffer,
        });
    }
    return listed.items;
}

/// What the list says of a plugin's build: the word for its newest pass and the buffer its
/// build tells its lines to, both empty for a plugin with no build.
const Built = struct { word: []const u8, buffer: []const u8 };

fn buildOf(pass: *sequencer.Pass, plugin_name: Atom) !Built {
    const none: Built = .{ .word = "", .buffer = "" };
    if (!pass.declares(watch_plugins_table) or !pass.declares(watch_table)) return none;
    const watched = try pass.table(watch_plugins_table);
    var rows = watched.readQuery(watch_api.PluginRow);
    const found = while (rows.next()) |row| {
        if (row.view.plugin.* == plugin_name) break row.view;
    } else return none;
    const pass_now: watch_api.Pass = std.enums.fromInt(watch_api.Pass, found.pass.*) orelse .building;
    const word = switch (pass_now) {
        .building => "building",
        .succeeded => "built",
        .failed => "failed",
    };
    const builds = try pass.table(watch_table);
    var build_rows = builds.readQuery(watch_api.StateRow);
    const buffer = while (build_rows.next()) |row| {
        if (row.view.build.* == found.build.*) break row.view.buffer;
    } else "";
    return .{ .word = word, .buffer = buffer };
}

/// What the line `Build ::` says: the builds that run, or how to start them.
fn buildNote(pass: *sequencer.Pass, allocator: std.mem.Allocator) ![]const u8 {
    const idle = "g builds every plugin; each reloads as its library is built";
    if (!pass.declares(watch_table)) return "builds are off";
    const builds = try pass.table(watch_table);
    var running: std.ArrayList(u8) = .empty;
    var rows = builds.readQuery(watch_api.StateRow);
    while (rows.next()) |row| {
        const state: watch_api.State = std.enums.fromInt(watch_api.State, row.view.state.*) orelse .idle;
        const busy = state == .starting or state == .running;
        if (!busy) continue;
        const name = pass.frame.atoms.lookup(row.view.build.*) orelse continue;
        if (running.items.len != 0) try running.appendSlice(allocator, ", ");
        try running.appendSlice(allocator, name);
    }
    if (running.items.len == 0) return idle;
    return std.fmt.allocPrint(allocator, "building {s}", .{running.items});
}

/// Whether `list` holds `listed`, row for row in its own order.
fn sameList(list: *Table, listed: []const Listed) bool {
    var rows = list.readQuery(ListRow);
    var index: usize = 0;
    while (rows.next()) |found| : (index += 1) {
        if (index == listed.len) return false;
        const wanted = listed[index];
        inline for (list_fields) |field| {
            if (!std.mem.eql(u8, @field(found.view, field), @field(wanted, field))) return false;
        }
    }
    return index == listed.len;
}

/// `milliseconds` since 1970 in UTC, `utc_offset` seconds east of it, as
/// `YYYY-MM-DD HH:MM:SS`, in `allocator`.
pub fn localTime(allocator: std.mem.Allocator, milliseconds: i64, utc_offset: i32) ![]const u8 {
    const local_seconds = @divFloor(milliseconds, std.time.ms_per_s) + utc_offset;
    if (local_seconds < 0) return "";
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(local_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

// ---- drawing -------------------------------------------------------------------------------

/// How many elements the panel's tree has room for besides the page's.
const own_elements = 4;

/// Draws the panel: its header, then the page, scrolled as its kernels left it. `frame` is the
/// panel's frame in the window and `ctx` begins at its corner. Writes no table.
pub fn render(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
    panel_frame.drawPlainHeader(memory, tables, atoms, panel, frame, ctx);
    const viewport = panel_frame.beginContent(tables, atoms, panel, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const scratch = memory.frameScratchAllocator() catch return;
    const laid_out = vcs_page.laidOutIn(scratch.allocator, tables, atoms, page) catch return;
    const elements = document_view.elementCount(viewport.height, .{ .line_height = laid_out.line_height }) + own_elements;
    var tree = ui.Tree.init(scratch, atoms, elements) catch return;
    if (tree.beginRect("plugin_list", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .bg = style.col.canvas, .clip_content = true })) {
        defer tree.endRect();
        vcs_page.record(&tree, tables, page, laid_out, sequencer.inboxOf(system()), scratch, viewport, ctx);
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = panels_mod.kPanelHitDepth,
    }, ctx, editor_state.hitRegions(tables, atoms), editor_sequencer.redrawInbox());
}

test "plugin list: a load time is shown in local time" {
    const allocator = std.testing.allocator;
    // 2026-11-25 22:03:07 UTC is 14:03:07 in Vancouver, eight hours west.
    const at: i64 = 1795644187 * std.time.ms_per_s + 250;
    const vancouver = try localTime(allocator, at, -8 * 60 * 60);
    defer allocator.free(vancouver);
    try std.testing.expectEqualStrings("2026-11-25 14:03:07", vancouver);
    // Across midnight eastward.
    const tokyo = try localTime(allocator, at, 9 * 60 * 60);
    defer allocator.free(tokyo);
    try std.testing.expectEqualStrings("2026-11-26 07:03:07", tokyo);
}
