//! vcs-p4's history: a query a person writes after `p4 changes` and the changelists it lists, a
//! second page of the panel (`editor/assets/documents/vcs-p4-history.org`, the view `history`),
//! as vcs-git's log is a query and its table. A part of vcs-p4's system (`p4_status.zig`).
//!
//! - `l` shows it; the first time it runs `-s submitted -m 100 //<workspace>/...`, the
//!   workspace's submitted changes, newest first.
//! - The query is the text after `p4 changes `, the one source of truth of what runs, split into
//!   arguments as vcs-git's log query is (`query.zig`: a shell's rules, nothing expanded), and run
//!   as `p4 -ztag changes -l <arguments>` (`p4.Command.changes_query`): vcs-p4's own `-ztag` is a
//!   global option, before the command, and `-l` (whole descriptions) goes before the person's
//!   arguments. `changes` only reads, so nothing a person types can write; refused before
//!   anything runs, told, and the prompt opened again holding what was typed: a quote not closed,
//!   more arguments than a command line takes here, and an argument beginning `-z`, `-G` or `-M`:
//!   those are `p4`'s global options, which choose the output form; after `changes` `p4` takes
//!   them as options of `changes`, which has none of these (`p4_changes.html`), and the page's
//!   reader needs `-ztag`'s form, which no argument after the command can change.
//! - In mode `vcs_p4_history` (under `vcs_p4`) the page's keys move as the changelists'; `e`, or
//!   RET on the query's line, opens a prompt holding the query; RET on a row shows that change
//!   in the diff panel; `g` runs the query again; what acts on a changelist tells it is not
//!   there. An answer `p4` printed in another shape marks the source `unread` and says so.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const keybinds = mesha.keybinds;
const p4 = @import("p4.zig");
const status = @import("p4_status.zig");
const vcs_page = @import("page.zig");
const vcs_query = @import("query.zig");
const p4_diff = @import("p4_diff.zig");
const modes = @import("../modes.zig");
const action_palette = @import("../action_palette.zig");
const table_view = @import("../table_view.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");

/// The history's page, `editor/assets/documents/vcs-p4-history.org`, compiled in.
pub const history_document = @embedFile("vcs_p4_history_document");

/// What the system takes for the history.
pub const Msg = enum(u64) {
    /// `l`: shows the history.
    vcs_p4_history = Atom.from("vcs_p4_history").value(),
    /// `e`: opens the query's prompt.
    vcs_p4_history_edit = Atom.from("vcs_p4_history_edit").value(),
    /// The query's prompt's answer, a palette event.
    vcs_p4_history_query = Atom.from("vcs_p4_history_query").value(),
    /// A click on a heading or a line of the page, a `document.Click`.
    vcs_p4_history_click = Atom.from("vcs_p4_history_click").value(),
    /// A click on a fold mark.
    vcs_p4_history_toggle = Atom.from("vcs_p4_history_toggle").value(),
    /// The wheel over the page.
    vcs_p4_history_wheel = Atom.from("vcs_p4_history_wheel").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The action of mode `vcs_p4` that shows the history; its key is `l`.
pub const history_action: plugin.action_api.Def = .{ .name = "history", .tag = @tagName(Msg.vcs_p4_history), .doc = "Show the history: a query of p4 changes and what it lists" };

/// The actions of mode `vcs_p4_history`.
pub const history_actions = [_]plugin.action_api.Def{
    .{ .name = "edit_query", .tag = @tagName(Msg.vcs_p4_history_edit), .doc = "Edit the query of p4 changes, and run it" },
};

/// The keys of mode `vcs_p4_history`, over `vcs_p4`'s.
pub const history_keys = [_]keybinds.KeyDef{
    .{ .chord = "e", .action = .{ "vcs_p4_history", "edit_query" } },
};

/// Offers the actions of mode `vcs_p4_history`, `inbox` taking them.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    for (history_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_p4_history, inbox, &.{.{ .def = def }});
}

// ---- the tables ----------------------------------------------------------------------------------

/// `editor_vcs_p4_history`: the changelists the query listed (`HistoryRow`), the source
/// `vcs-p4.history`.
pub const history_table_name = "editor_vcs_p4_history";
/// `editor_vcs_p4_history_view`: the page's state (`ViewRow`).
pub const view_table_name = "editor_vcs_p4_history_view";
/// `editor_vcs_p4_history_folds`: the page's folds.
pub const folds_table_name = "editor_vcs_p4_history_folds";

/// The most changelists the table holds.
pub const max_history = 1000;
/// What the history runs the first time.
pub const default_query_format = "-s submitted -m 100 //{s}/...";

/// Where the query is.
pub const Phase = enum(u8) { none, loading, answered, failed, gave_up };

/// A row of `editor_vcs_p4_history`.
pub const HistoryRow = struct {
    change: []const u8,
    user: []const u8,
    date: []const u8,
    description: []const u8,
};

const history_fields = [_][]const u8{ "change", "user", "date", "description" };

/// The row of `editor_vcs_p4_history_view`, beside its `document.StateRow` fields.
pub const ViewRow = struct {
    /// The query, the text after `p4 changes `.
    query: *Table.String,
    /// Counts the queries run: an answer of an earlier one is dropped.
    serial: *u32,
    /// A `Phase`.
    phase: *u8,
    /// How many changelists `p4` listed, kept or not.
    listed: *u32,
    /// The records of its answer that could not be read.
    unread: *u32,
    /// The page's `page.MovedUnder`.
    cursor_moved_under: *u8,
};

const ViewRead = struct {
    query: []const u8,
    serial: *u32,
    phase: *u8,
    listed: *u32,
    unread: *u32,
};

const history_table = Atom.from(history_table_name);
const view_table = Atom.from(view_table_name);
const folds_table = Atom.from(folds_table_name);
const query_prompt_name = "vcs_p4_history_prompt";
const query_prompt = Atom.from(query_prompt_name);

/// The names the history adds to the system's.
pub const names = [_][]const u8{query_prompt_name};

/// The name of the value that holds the query, as the page's text names it.
const query_value = "vcs-p4.history-query";
/// The line of the page's text that shows the query: RET on it edits the query. Found as the
/// editor is compiled, so a page whose text no longer shows the query does not compile.
const query_line: u32 = queryLineOf(page.document);

fn queryLineOf(comptime parsed: document.Document) u32 {
    @setEvalBranchQuota(100_000);
    for (parsed.blocks) |block| {
        const spans = switch (block.content) {
            .term => |term| term.text.of(parsed.spans),
            .paragraph => |text| text.of(parsed.spans),
            .heading => |heading| heading.text.of(parsed.spans),
            .title, .refresh, .table, .group, .text => continue,
        };
        for (spans) |span| switch (span) {
            .macro => |macro| if (std.mem.eql(u8, macro.name, query_value)) return block.line,
            .text, .line_end => {},
        };
    }
    @compileError("vcs-p4-history.org has no line that shows {{{" ++ query_value ++ "}}}");
}

/// The history's page.
pub const page: vcs_page.Page = .{
    .document = vcs_page.parsePage(history_document, "vcs-p4-history.org"),
    .name = "vcs_p4_history_document",
    .state_table = view_table,
    .folds_table = folds_table,
    .tags = .{
        .click = Atom.from(Msg.vcs_p4_history_click),
        .toggle = Atom.from(Msg.vcs_p4_history_toggle),
        .wheel = Atom.from(Msg.vcs_p4_history_wheel),
    },
    .resize_reader_name = "vcs_p4_history_resizes",
    .moved_under_sentence = "The history changed under the cursor",
};

/// Makes the history's tables unless they are there.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ history_table_name, view_table_name, folds_table_name, query_prompt_name });
    var rows: Table.Schema = undefined;
    try rows.init(scratch.allocator, atoms, history_fields.len);
    defer rows.deinit();
    for (history_fields) |field| try rows.addFieldFallible(field, Table.String, .text_field);
    _ = try tables.ensure(&rows, max_history, history_table, .durable);

    var view: Table.Schema = undefined;
    try view.init(scratch.allocator, atoms, 6 + std.meta.fields(document.StateRow).len);
    defer view.deinit();
    try view.addFieldFallible("query", Table.String, .text_field);
    try view.addFieldFallible("serial", u32, .int);
    try view.addFieldFallible("phase", u8, .int);
    try view.addFieldFallible("listed", u32, .int);
    try view.addFieldFallible("unread", u32, .int);
    try view.addFieldFallible("cursor_moved_under", u8, .int);
    try document.addStateFields(&view);
    const defaults = .{
        .query = Table.String{},
        .serial = @as(u32, 0),
        .phase = @as(u8, @intFromEnum(Phase.none)),
        .listed = @as(u32, 0),
        .unread = @as(u32, 0),
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
    _ = try tables.ensure(&folds, 16, folds_table, .durable);
}

/// What the history reads and writes, for the system's access.
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.write(history_table);
    page.declareAccess(result, tables);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s that `takeOnPage` did not take.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_p4_history => try showHistory(work),
        .vcs_p4_history_edit => try presentQuery(work, null),
        .vcs_p4_history_query => try takeQuery(work, received),
        // A page's own messages, come late, after the view left it.
        .vcs_p4_history_click, .vcs_p4_history_toggle, .vcs_p4_history_wheel => {},
        _ => {},
    }
}

/// The panel's keys while the history is shown: its moves move the page's cursor, `RET` edits
/// the query on its line and shows the change on a row, `g` runs the query again; what acts on
/// a changelist is told it is not there. Returns false for a message the views share.
pub fn takeInHistory(work: status.Work, message: status.Msg) !bool {
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
        .vcs_p4_toggle, .vcs_p4_toggle_all => return true,
        .vcs_p4_visit => {
            if (try vcs_page.changedUnderCursor(work.pass, page)) return true;
            const at = try vcs_page.atCursor(work.pass, page);
            try chooseAt(work, at);
            return true;
        },
        .vcs_p4_refresh => {
            try rerun(work);
            return true;
        },
        .vcs_p4_submit, .vcs_p4_describe, .vcs_p4_new_change, .vcs_p4_move, .vcs_p4_revert, .vcs_p4_revert_unchanged, .vcs_p4_delete_change, .vcs_p4_shelve_menu, .vcs_p4_resolve, .vcs_p4_reconcile, .vcs_p4_open_menu => {
            work.tell("Not in the history: q goes back to the changelists");
            return true;
        },
        .vcs_p4_document_click, .vcs_p4_document_toggle, .vcs_p4_document_wheel, .vcs_p4_click, .vcs_p4_chevron, .vcs_p4_wheel => return true,
        else => return false,
    };
    const laid_out = try vcs_page.laidOut(work.pass, page);
    const state = try vcs_page.stateOf(work.pass, page);
    document.step(laid_out, state, way);
    return true;
}

/// `RET` or a click on what the cursor is on: a row's change shown in the diff panel; a line of
/// text, the query's, edited.
pub fn chooseAt(work: status.Work, at: document.At) !void {
    switch (at) {
        .row => |row| {
            const change = row.table.getRow(row.row, HistoryRow) orelse return;
            const number = std.fmt.parseInt(u32, change.change, 10) catch return;
            try p4_diff.show(work, .{ .change = number });
        },
        .text => |line| {
            const laid_out = try vcs_page.laidOut(work.pass, page);
            const on_query = for (laid_out.blocks) |block| {
                if (block.key == line.key) break block.line == query_line;
            } else false;
            if (on_query) try presentQuery(work, null);
        },
        .heading, .group, .none => {},
    }
}

/// `l`: the history shown, its query run the first time.
pub fn showHistory(work: status.Work) !void {
    if (work.refusedWithoutWorkspace()) return;
    work.enterView(.history);
    const view = try work.pass.readSingleton(view_table, ViewRead);
    if (view.query.len != 0) return publish(work);
    const allocator = try work.scratch();
    const query = try std.fmt.allocPrint(allocator, default_query_format, .{work.client()});
    _ = try runQuery(work, query);
}

/// `g`: the query run again.
fn rerun(work: status.Work) !void {
    const view = try work.pass.readSingleton(view_table, ViewRead);
    const allocator = try work.scratch();
    const query = try allocator.dupe(u8, view.query);
    _ = try runQuery(work, query);
}

/// Whether a query ran, or was refused and told.
pub const Ran = enum { ran, refused };

/// Runs `query`, the text after `p4 changes `, in place of the one before, unless it is refused
/// (the module's doc says what is), told.
pub fn runQuery(work: status.Work, query: []const u8) !Ran {
    if (work.refusedWithoutWorkspace()) return .refused;
    const allocator = try work.scratch();
    _ = vcs_query.count(query) catch |err| {
        work.tell(switch (err) {
            error.UnterminatedQuote => "The query has a quote not closed: nothing was run",
            error.UnpassableArgument => "The query holds an empty argument or a control character: nothing was run",
        });
        return .refused;
    };
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    _ = try vcs_query.write(&arguments.writer, query);
    if (choosesOutputForm(arguments.written())) {
        work.tell("p4 changes has no -z, -G or -M option (they are p4's global options, which choose the output form, and the page reads -ztag's): nothing was run");
        return .refused;
    }
    const command: p4.Command = .{ .changes_query = arguments.written() };
    if (!p4.passes(work.context(), command)) {
        work.tell("p4 cannot be given that query: too many arguments, or a line break in one");
        return .refused;
    }
    const view = try work.pass.writeSingleton(view_table, ViewRow);
    const cells = try work.writeCells(view_table);
    const kept_query = try allocator.dupe(u8, query);
    try cells.assignString(view.query, kept_query);
    view.serial.* +%= 1;
    view.phase.* = @intFromEnum(Phase.loading);
    try work.queueRead(.history, command, "", view.serial.*);
    try publish(work);
    return .ran;
}

/// Whether `arguments`, as the splitter wrote them, hold one beginning `-z`, `-G` or `-M`:
/// global options of `p4`'s that choose its output form, no options of `changes`.
fn choosesOutputForm(arguments: []const u8) bool {
    var each = std.mem.tokenizeScalar(u8, arguments, mesha.process.argument_separator);
    while (each.next()) |argument| {
        const prefixes = [_][]const u8{ "-z", "-G", "-M" };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, argument, prefix)) return true;
        }
    }
    return false;
}

/// The query's answer, `said` null for one that failed: the changelists written in place of
/// those listed, the cursor kept on the same change; a failure told, the rows kept. An answer of
/// an earlier query is dropped.
pub fn takeHistory(work: status.Work, serial: u32, said: ?[]const u8) !void {
    const view = try work.pass.writeSingleton(view_table, ViewRow);
    if (serial != view.serial.*) return;
    const bytes = said orelse {
        view.phase.* = @intFromEnum(Phase.failed);
        work.tell("p4 changes failed; $ shows why");
        return publish(work);
    };
    const allocator = try work.scratch();
    const room = try allocator.alloc(p4.Change, max_history);
    const parsed = p4.parseChanges(bytes, room);
    const table = try work.writeCells(history_table);
    const kept = try keptCursor(work);
    const changes = room[0..parsed.records.kept];
    const handles = try table_view.rowsInOrder(table, @intCast(changes.len), allocator);
    for (changes, handles) |change, handle| {
        const number = try std.fmt.allocPrint(allocator, "{d}", .{change.number});
        try table.setString(handle, "change", number);
        const shown_user = try ui.displayText(allocator, change.user);
        try table.setString(handle, "user", shown_user);
        const date = try status.dateOf(allocator, change.time);
        try table.setString(handle, "date", date);
        const shown_description = try ui.displayText(allocator, change.summary);
        try table.setString(handle, "description", shown_description);
    }
    view.phase.* = @intFromEnum(Phase.answered);
    view.listed.* = parsed.records.seen;
    view.unread.* = parsed.unread;
    try publish(work);
    if (parsed.unread != 0) work.tell("p4 changes: some of its output could not be read as changelists ($ shows it)");
    try keepCursor(work, kept);
}

/// Where the page's cursor was as an answer came, to keep it there (`keepCursor`).
const KeptCursor = union(enum) {
    /// On a change's row: its number's text, in the frame's memory.
    row: []const u8,
    /// On a line of text while the table showed rows: it stays there.
    line,
    /// Where it starts, the table showing no rows: it goes to the first row.
    start,
};

/// Where the page's cursor is, before an answer rewrites the table.
fn keptCursor(work: status.Work) !KeptCursor {
    const laid_out = try vcs_page.laidOut(work.pass, page);
    const state = try vcs_page.stateOf(work.pass, page);
    switch (document.at(laid_out, document.cursorOf(state))) {
        .row => |row| {
            const change = row.table.getRow(row.row, HistoryRow) orelse return .start;
            const allocator = try work.scratch();
            return .{ .row = try allocator.dupe(u8, change.change) };
        },
        .text, .heading, .group => return if (tableBlock(laid_out) != null) .line else .start,
        .none => return .start,
    }
}

/// After an answer: the cursor on the change it was on while that is listed, else on the first
/// row (the page's `MovedUnder` set, so a key later in the run acts on nothing); on a line of
/// text it stays.
fn keepCursor(work: status.Work, kept: KeptCursor) !void {
    const number: ?[]const u8 = switch (kept) {
        .line => return,
        .start => null,
        .row => |named| named,
    };
    const laid_out = try vcs_page.laidOut(work.pass, page);
    const block = tableBlock(laid_out) orelse return;
    const table = block.table.?.table;
    var found: ?Table.RowHandle = null;
    if (number) |wanted| {
        var rows = table.readQuery(HistoryRow);
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.view.change, wanted)) found = row.handle;
        }
        if (found == null) {
            const moved_under = try vcs_page.movedUnder(work.pass, page);
            moved_under.* = 1;
        }
    }
    const first = document.rowAt(table, 0);
    const handle = found orelse first orelse return;
    try vcs_page.putCursorOnRow(work.pass, page, block.key, handle);
}

/// The page's table block, while it shows.
fn tableBlock(laid_out: document.Layout) ?document.Block {
    for (laid_out.shown) |index| {
        const block = laid_out.blocks[index];
        const table = block.table orelse continue;
        if (std.mem.eql(u8, table.source, "vcs-p4.history")) return block;
    }
    return null;
}

/// The query's prompt, holding `holding`, or the query; its answer comes as
/// `vcs_p4_history_query`.
fn presentQuery(work: status.Work, holding: ?[]const u8) !void {
    const memory = work.memory();
    const view = try work.pass.readSingleton(view_table, ViewRead);
    const allocator = try action_palette.completionAllocator(memory, .vcs);
    action_palette.resetCompletionArena(memory, .vcs);
    const shown = holding orelse view.query;
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = query_prompt,
        .presentation = .prompt,
        .title = "p4 changes",
        .initial_query = try allocator.dupe(u8, shown),
        .initial_query_edit = .append,
        .accepts_text = true,
        .entries = &.{},
    };
    try action_palette.ownRequestText(allocator, completions);
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_p4_history_query));
    action_palette.request(memory, work.tables(), .{ .present = .{ .completions = completions, .reply = reply } });
}

/// The query's prompt's events: on Enter its text replaces the query and runs, an empty one
/// the default; a refused one is told and the prompt opens again holding it; closed with
/// nothing, nothing changes.
fn takeQuery(work: status.Work, received: sequencer.Message) !void {
    const event = try action_palette.eventOf(received);
    if (event.kind == .query_changed) return;
    action_palette.request(work.memory(), work.tables(), .{ .acknowledge = .{ .owner = query_prompt } });
    _ = event.completion orelse return;
    const typed = std.mem.trim(u8, event.query, " \t\r\n");
    const allocator = try work.scratch();
    const query = if (typed.len == 0) try std.fmt.allocPrint(allocator, default_query_format, .{work.client()}) else try allocator.dupe(u8, typed);
    const ran = try runQuery(work, query);
    if (ran == .refused) try presentQuery(work, query);
}

/// The history's values: its query and its note.
pub fn publish(work: status.Work) !void {
    const publishing = try document_sources.Publishing.of(work.pass) orelse return;
    const view = try work.pass.readSingleton(view_table, ViewRead);
    const allocator = try work.scratch();
    publishing.publishSource(status.publisher, .{ .name = "vcs-p4.history", .table = history_table, .shown = &history_fields });
    // Publishing marks the source read: its mark is set again from what the last answer said.
    const source_state: document_sources.SourceState = if (view.unread.* != 0) .unread else .ok;
    publishing.setSourceState(status.publisher, "vcs-p4.history", source_state);
    const shown_query = try ui.displayText(allocator, view.query);
    publishing.publishValue(status.publisher, "vcs-p4.history-query", shown_query);
    const phase = std.enums.fromInt(Phase, view.phase.*) orelse .none;
    const note: []const u8 = switch (phase) {
        .none => "",
        // The ui font has ASCII only: three dots, not an ellipsis.
        .loading => "Loading...",
        .failed => "p4 changes failed; $ shows why",
        .gave_up => "Gave up; g asks again",
        .answered => if (view.unread.* != 0)
            "Some of p4's output could not be read as changelists"
        else if (view.listed.* == 0)
            "No changes match"
        else if (view.listed.* > max_history)
            try std.fmt.allocPrint(allocator, "p4 listed {d} changes; the table holds the first {d}: -m says how many", .{ view.listed.*, max_history })
        else
            "",
    };
    publishing.publishValue(status.publisher, "vcs-p4.history-note", note);
}

/// A give-up: a query asked and not answered never will be.
pub fn abandon(work: status.Work) !void {
    const view = try work.pass.writeSingleton(view_table, ViewRow);
    if (view.phase.* != @intFromEnum(Phase.loading)) return;
    view.phase.* = @intFromEnum(Phase.gave_up);
    try publish(work);
}

/// Another project: the history forgotten.
pub fn forget(work: status.Work) !void {
    const view = try work.pass.writeSingleton(view_table, ViewRow);
    const cells = try work.writeCells(view_table);
    try cells.assignString(view.query, "");
    view.phase.* = @intFromEnum(Phase.none);
    view.serial.* +%= 1;
    const table = try work.pass.writeTable(history_table);
    table.clear();
    document.setCursor(try vcs_page.stateOf(work.pass, page), .{});
    try publish(work);
}
