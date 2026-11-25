//! vcs-git's log: a query and its table. The log view is the second page vcs-git owns
//! (`page.Page`), `editor/assets/documents/vcs-git-log.org`: a line that reads `git log`
//! and the query, a note when there is something to say, and one table of the commits git
//! answered, over the source `vcs-git.log`. A part of the panel's system (`git_status.zig`): the
//! commits and the query are this file's tables, while the jobs, their ends, the views and what
//! is told are the panel's (`git_status.Work`), which these functions are handed.
//!
//! - The query is the text after `git log ` (`-n 256 HEAD`), what a person reads and edits, kept
//!   in `editor_vcs_git_log_view` and published as `vcs-git.log-query`: the one source of truth of
//!   what runs. It is split into arguments as a shell splits a command line, nothing expanded
//!   (`query.write`); vcs-git's own options, the format it reads among them, go before it
//!   (`git.Command.log`). A query with an unterminated quote, or an argument git cannot be
//!   given, is told and nothing runs. Each run is one `log`, and a run asked while one runs
//!   replaces it: the answer of an earlier one is dropped (`serial`).
//! - `e`, or RET on the query's line, opens a prompt holding the query; its answer replaces it
//!   and runs it (an empty answer runs `default_query`). `g` runs it again as it is. `l` shows
//!   the log menu, whose options narrow (`=n` the limit, 256 unless set; `=a` the author, `=g`
//!   words of the messages, `=S` words of the changes, `=s` and `=u` the dates, `=p` a path,
//!   written after `--`; `-m` no merges, `-i` case ignored) and whose commands say which commits
//!   (`l` those of `HEAD`, `o` another revision read in a prompt of the branches, one
//!   `for-each-ref` each time (`git_branch.askListing`), `a` every reference, `b` every branch): choosing one writes the
//!   query from what the menu is set to and runs it. The menu keeps what it was set to for the
//!   session; a query edited by hand is not read back into its switches.
//! - The commits are rows of `editor_vcs_git_log` (`LogRow`), replaced by each answer, at most
//!   `max_commits`; what git said that is no commit (`git.parseLog`'s `unread`) leaves the
//!   table with what did read, the source marked `unread` (the page draws it in the error
//!   colour), `vcs-git.log-note` saying so and one line told in `*Messages*`; the next answer
//!   that reads clears it. A query git refuses is told as any failed command, and the table
//!   keeps what it showed. The note (`noteOf`) also says a query runs, was given up, matched
//!   nothing, or listed more commits than the table holds.
//! - In the log view (mode `vcs_log`, under `vcs_git`) the keys of mode `vcs` move through the
//!   page, RET on a row shows its commit in the diff panel (`git_diff.show`), `c f` makes a
//!   fixup of it, and `q` goes back to the status. After an answer the cursor is on the commit it
//!   was on, by its full hash, while it is listed, else on the first row. The page keeps its
//!   cursor and its scroll as the person leaves the view and comes back.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const keybinds = mesha.keybinds;
const git = @import("git.zig");
const vcs_query = @import("query.zig");
const status = @import("git_status.zig");
const vcs_page = @import("page.zig");
const git_diff = @import("git_diff.zig");
const git_branch = @import("git_branch.zig");
const table_view = @import("../table_view.zig");
const transient = @import("../transient.zig");
const action_palette = @import("../action_palette.zig");
const modes = @import("../modes.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");

// ---- the messages, the actions and their keys --------------------------------------------------

/// What the panel's system takes for the log: the actions below, the menu's answer, the
/// prompts' events and its page's clicks.
pub const Msg = enum(u64) {
    /// `l`: shows the log menu, set as it was last.
    vcs_git_log_menu = Atom.from("vcs_git_log_menu").value(),
    /// The log menu's answer, a `transient.Chosen`.
    vcs_git_log_chosen = Atom.from("vcs_git_log_chosen").value(),
    /// `e` in the log: the prompt holding the query.
    vcs_git_log_edit = Atom.from("vcs_git_log_edit").value(),
    /// The events of the query's prompt, palette events.
    vcs_git_log_query = Atom.from("vcs_git_log_query").value(),
    /// A click on a line of the log's page, a `document.Click`.
    vcs_git_log_click = Atom.from("vcs_git_log_click").value(),
    /// A click on a heading's fold mark of the log's page, a `document.Click`.
    vcs_git_log_toggle = Atom.from("vcs_git_log_toggle").value(),
    /// The wheel over the log's page, an `input.MouseScrollMsg`.
    vcs_git_log_wheel = Atom.from("vcs_git_log_wheel").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The action of mode `vcs_git` that shows the log menu; its key is `l`.
pub const log_action: plugin.action_api.Def = .{ .name = "log", .tag = @tagName(Msg.vcs_git_log_menu), .doc = "Show the menu of logs" };

/// The log view's own action, of mode `vcs_log`.
pub const edit_action: plugin.action_api.Def = .{ .name = "edit_query", .tag = @tagName(Msg.vcs_git_log_edit), .doc = "Edit the log's query in a prompt, and run it" };

/// Offers the actions of mode `vcs_log`, `inbox`'s.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    keybinds.pushActionDefinitions(atoms, sink, modes.vcs_log, inbox, &.{.{ .def = edit_action }});
}

/// The keys of mode `vcs_log`, over `vcs_git`'s and `vcs`'s: `e` edits the query.
pub const log_keys = [_]keybinds.KeyDef{
    .{ .chord = "e", .action = .{ "vcs_log", "edit_query" } },
};

// ---- the menu ------------------------------------------------------------------------------------

/// The log menu's items, by their ids.
pub const MenuItem = enum(u32) {
    current = 1,
    other,
    all,
    branches,
    limit,
    author,
    grep,
    changes,
    since,
    until,
    path,
    no_merges,
    ignore_case,
};

/// The log menu: what narrows the commits listed, then which commits. The limit is written
/// `-n`, and the path's option shows `--` before it, where it goes in the query: neither is
/// written as the option it shows.
pub const menu: ui.transient.Menu = .{
    .title = "Log",
    .groups = &.{
        .{ .title = "Arguments", .items = &.{
            ui.transient.Item.option("=n", "Limit", "--max-count=", @intFromEnum(MenuItem.limit)),
            ui.transient.Item.option("=a", "Author", "--author=", @intFromEnum(MenuItem.author)),
            ui.transient.Item.option("=g", "Search messages", "--grep=", @intFromEnum(MenuItem.grep)),
            ui.transient.Item.option("=S", "Search changes", "-S", @intFromEnum(MenuItem.changes)),
            ui.transient.Item.option("=s", "Since", "--since=", @intFromEnum(MenuItem.since)),
            ui.transient.Item.option("=u", "Until", "--until=", @intFromEnum(MenuItem.until)),
            ui.transient.Item.option("=p", "Limit to path", "-- ", @intFromEnum(MenuItem.path)),
            ui.transient.Item.toggle("-m", "No merges", "--no-merges", @intFromEnum(MenuItem.no_merges)),
            ui.transient.Item.toggle("-i", "Ignore case", "--regexp-ignore-case", @intFromEnum(MenuItem.ignore_case)),
        } },
        .{ .title = "Log", .items = &.{
            ui.transient.Item.command("l", "current branch", @intFromEnum(MenuItem.current)),
            ui.transient.Item.command("o", "other", @intFromEnum(MenuItem.other)),
            ui.transient.Item.command("a", "all references", @intFromEnum(MenuItem.all)),
            ui.transient.Item.command("b", "all branches", @intFromEnum(MenuItem.branches)),
        } },
    },
};

/// How many commits the menu's query lists unless `=n` says.
pub const default_limit = 256;
/// What `g` and an empty answer to the query's prompt run while no query was written.
pub const default_query = std.fmt.comptimePrint("-n {d} HEAD", .{default_limit});
/// The most commits the log's table holds: past them a log says how many git listed.
pub const max_commits = git.max_log_commits;

// ---- the tables and the page ---------------------------------------------------------------------

/// `editor_vcs_git_log`: the commits the last answer listed, newest first, a row each
/// (`LogRow`): the source `vcs-git.log`.
pub const log_table_name = "editor_vcs_git_log";
/// `editor_vcs_git_log_view`: the query, what came of it and the menu's state, and the page's
/// cursor, scroll and view (`document.StateRow`); one row (`AskedRow`).
pub const view_table_name = "editor_vcs_git_log_view";
/// `editor_vcs_git_log_folds`: the log page's folds (`document.FoldRow`).
pub const folds_table_name = "editor_vcs_git_log_folds";
/// The owner the query's prompt is presented as.
pub const query_prompt_name = "vcs_git_log_query_prompt";

const log_table = Atom.from(log_table_name);
const view_table = Atom.from(view_table_name);
const folds_table = Atom.from(folds_table_name);
const query_prompt = Atom.from(query_prompt_name);

/// The log's page, `editor/assets/documents/vcs-git-log.org`, compiled in.
pub const log_document = @embedFile("vcs_git_log_document");

/// The log's page: its state in `editor_vcs_git_log_view`, its folds in
/// `editor_vcs_git_log_folds`.
pub const page: vcs_page.Page = .{
    .document = vcs_page.parsePage(log_document, "vcs-git-log.org"),
    .name = "vcs_git_log_document",
    .state_table = view_table,
    .folds_table = folds_table,
    .tags = .{
        .click = Atom.from(Msg.vcs_git_log_click),
        .toggle = Atom.from(Msg.vcs_git_log_toggle),
        .wheel = Atom.from(Msg.vcs_git_log_wheel),
    },
    .resize_reader_name = "vcs_git_log_resizes",
    .moved_under_sentence = "The log changed under the cursor",
};

/// The names the log adds to the system's `names`.
pub const names = [_][]const u8{query_prompt_name} ++ page.names();

/// The name the log's table is published as.
pub const source_name = "vcs-git.log";
/// The name of the value that holds the query, as the page's text names it.
const query_value = "vcs-git.log-query";
/// The line of the page's text that shows the query, the one whose text names `query_value`:
/// RET on it edits the query. Found as the editor is compiled, so a page whose text no longer
/// shows the query does not compile.
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
    @compileError("vcs-git-log.org has no line that shows {{{" ++ query_value ++ "}}}");
}

/// A row of `editor_vcs_git_log`, its text made displayable (`ui.displayText`): the shown
/// columns, in the page's order, then the full hash, data only.
pub const LogRow = struct {
    /// The hash as short as git keeps it unambiguous.
    hash: []const u8,
    /// The refs that point at it, as git decorates them.
    refs: []const u8,
    /// The message's first paragraph.
    subject: []const u8,
    /// The author's name.
    author: []const u8,
    /// As git wrote it: `YYYY-MM-DD` unless the query asks another `--date`.
    date: []const u8,
    /// The full hash, which a show and a fixup are given.
    full_hash: []const u8,
};

/// The fields of `editor_vcs_git_log`, in order; all but the last are shown.
const log_fields = [_][]const u8{ "hash", "refs", "subject", "author", "date", "full_hash" };
const log_shown = log_fields[0..5];

/// Where the last query is: asked, answered, or failed.
pub const Phase = enum(u8) {
    /// None was asked since the panel's data was last forgotten.
    none,
    /// One runs.
    loading,
    /// Its answer fills the table.
    answered,
    /// It failed: the table holds what the query before listed.
    failed,
    /// It was given up (`C-g`) before it answered: the table holds what the query before listed.
    stopped,
};

/// The row of `editor_vcs_git_log_view`, but the page's fields (`document.StateRow`).
pub const AskedRow = struct {
    /// What the menu was set to as it last closed.
    menu: *ui.transient.State,
    /// The query, the text after `git log `: what runs, and what the page shows.
    query: *Table.String,
    /// A `Phase`.
    phase: *u8,
    /// Counts the queries asked: an answer of an earlier one is dropped.
    serial: *u32,
    /// How many commits the last answer listed, kept or not.
    listed: *u32,
    /// How many records of the last answer were no commit (`git.Parsed.unread`).
    unread: *u32,
    /// The page's `page.MovedUnder`: 1 from an answer that took the commit under the
    /// page's cursor away to the end of that run.
    cursor_moved_under: *u8,
};

/// `AskedRow` read, its text as slices of the table's.
pub const AskedRead = struct {
    menu: *ui.transient.State,
    query: []const u8,
    phase: *u8,
    serial: *u32,
    listed: *u32,
    unread: *u32,
    cursor_moved_under: *u8,
};

/// Makes the log's tables unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ log_table_name, view_table_name, folds_table_name, query_prompt_name });
    var rows: Table.Schema = undefined;
    try rows.init(scratch.allocator, atoms, log_fields.len);
    defer rows.deinit();
    for (log_fields) |field| try rows.addFieldFallible(field, Table.String, .text_field);
    _ = try tables.ensure(&rows, max_commits, log_table, .durable);

    var asked: Table.Schema = undefined;
    try asked.init(scratch.allocator, atoms, 7 + std.meta.fields(document.StateRow).len);
    defer asked.deinit();
    try asked.addFieldFallible("menu", ui.transient.State, .hex);
    try asked.addFieldFallible("query", Table.String, .text_field);
    try asked.addFieldFallible("phase", u8, .int);
    try asked.addFieldFallible("serial", u32, .int);
    try asked.addFieldFallible("listed", u32, .int);
    try asked.addFieldFallible("unread", u32, .int);
    try asked.addFieldFallible("cursor_moved_under", u8, .int);
    try document.addStateFields(&asked);
    const defaults = .{
        .menu = ui.transient.State{},
        .query = Table.String{},
        .phase = @as(u8, @intFromEnum(Phase.none)),
        .serial = @as(u32, 0),
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
    _ = try tables.ensureSingleton(&asked, view_table, defaults, .durable);

    var folds: Table.Schema = undefined;
    try folds.init(scratch.allocator, atoms, 1);
    defer folds.deinit();
    try document.addFoldFields(&folds);
    _ = try tables.ensure(&folds, max_folds, folds_table, .durable);
}

/// The most headings the log's page keeps folded: its text has none now.
const max_folds = 16;

/// What the log reads and writes, for the panel's system's access: its commits, and its page's
/// state, folds and what its text reads.
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.write(log_table);
    page.declareAccess(result, tables);
}

// ---- taking the messages -------------------------------------------------------------------------

/// One of `Msg`'s, which `claims` took. The page's clicks and wheel are taken in the log view
/// before this (`git_status.Work.takeOnPage`); come in another view, they do nothing.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_git_log_menu => return presentMenu(work),
        .vcs_git_log_chosen => {
            const chosen = try received.payloadAs(transient.Chosen);
            // What the menu was set to is kept however it closed.
            const asked = try work.pass.writeSingleton(view_table, AskedRow);
            asked.menu.* = chosen.state;
            if (chosen.cancelled != 0) return;
            const item = std.enums.fromInt(MenuItem, chosen.id) orelse return;
            return choose(work, item);
        },
        .vcs_git_log_edit => return presentQuery(work, null),
        .vcs_git_log_query => return takeQuery(work, received),
        .vcs_git_log_click, .vcs_git_log_toggle, .vcs_git_log_wheel, _ => {},
    }
}

/// Shows the log menu, set as it last closed; its answer comes as `vcs_git_log_chosen`.
pub fn presentMenu(work: status.Work) !void {
    const asked = try work.pass.readSingleton(view_table, AskedRead);
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_log_chosen));
    transient.present(work.pass.frame.memory, work.pass.frame.tables, .{ .menu = &menu, .state = asked.menu.*, .reply = reply });
}

/// What the command chosen in the menu does, with what the menu, kept, sets: a query written
/// and run, or for `o` the prompt for its revision first.
fn choose(work: status.Work, item: MenuItem) !void {
    switch (item) {
        .current => try runMenu(work, .{ .revision = "HEAD" }),
        .all => try runMenu(work, .{ .everything = "--all" }),
        .branches => try runMenu(work, .{ .everything = "--branches" }),
        .other => try git_branch.askListing(work, .log_revision, "", .refs),
        .limit, .author, .grep, .changes, .since, .until, .path, .no_merges, .ignore_case => {},
    }
}

/// Which commits the menu's query lists: those of a revision, or of every reference or branch,
/// as the argument that says so.
const Which = union(enum) {
    revision: []const u8,
    everything: []const u8,
};

/// The query the menu set as `state` writes for the commits `which` names, in `allocator`: `-n`
/// and the limit, the options, the revision, then `--` and the path, each argument quoted as
/// the query's text needs (`query.writeArgument`); or what is told in its place when the
/// limit is no number.
pub fn queryOf(allocator: std.mem.Allocator, state: ui.transient.State, which: Which) !union(enum) { query: []const u8, tell: []const u8 } {
    const limit_id = @intFromEnum(MenuItem.limit);
    const path_id = @intFromEnum(MenuItem.path);
    const limit_text = std.mem.trim(u8, ui.transient.valueOf(&menu, &state, limit_id), " ");
    const limit: u32 = if (limit_text.len == 0)
        default_limit
    else
        std.fmt.parseInt(u32, limit_text, 10) catch return .{ .tell = "The limit is a number of commits: l =n sets it" };
    if (limit == 0) return .{ .tell = "The limit is a number of commits: l =n sets it" };
    // A value holding the separator would split as the arguments are read back below.
    for (menu.groups) |group| {
        for (group.items) |item| {
            if (item.kind != .option) continue;
            const value = ui.transient.valueOf(&menu, &state, item.id);
            if (!git.isPassable(value)) return .{ .tell = "git cannot be given that value: it holds a control character" };
        }
    }
    switch (which) {
        // A revision is no option: one beginning with `-` would be read as one.
        .revision => |revision| if (!git.isPassable(revision) or revision.len == 0 or revision[0] == '-') return .{ .tell = "git cannot be given that revision" },
        .everything => {},
    }
    const path = ui.transient.valueOf(&menu, &state, path_id);
    // The limit and the path are written apart, not as the options they show.
    var options = state;
    _ = ui.transient.setValue(&menu, &options, limit_id, "");
    _ = ui.transient.setValue(&menu, &options, path_id, "");
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    try ui.transient.writeArguments(&menu, &options, process.argument_separator, &arguments.writer);
    var query: std.Io.Writer.Allocating = .init(allocator);
    try query.writer.print("-n {d}", .{limit});
    var each = std.mem.tokenizeScalar(u8, arguments.written(), process.argument_separator);
    while (each.next()) |argument| {
        try query.writer.writeByte(' ');
        try vcs_query.writeArgument(&query.writer, argument);
    }
    try query.writer.writeByte(' ');
    switch (which) {
        .revision => |revision| try vcs_query.writeArgument(&query.writer, revision),
        .everything => |argument| try query.writer.writeAll(argument),
    }
    if (path.len != 0) {
        try query.writer.writeAll(" -- ");
        try vcs_query.writeArgument(&query.writer, path);
    }
    return .{ .query = query.written() };
}

/// Writes the query the menu's kept state and `which` say, and runs it.
fn runMenu(work: status.Work, which: Which) !void {
    const allocator = try work.scratch();
    const read = try work.pass.readSingleton(view_table, AskedRead);
    const planned = try queryOf(allocator, read.menu.*, which);
    switch (planned) {
        .tell => |sentence| work.tell(sentence),
        .query => |query| _ = try runQuery(work, query, .show),
    }
}

/// Whether running a query shows the log view, or leaves the view shown as it is.
const Showing = enum { show, stay };

/// Whether a query ran, was refused and told (the query wants putting right), or could not run
/// while the repository's root is not known, also told (the query itself is fine).
const Ran = enum { ran, refused, no_root };

/// Runs `query`, the text after `git log `: one `log`, the query kept as the one the page shows
/// and `g` runs, the log view shown as `showing` says. A query that cannot be split, that
/// splits into more arguments than one command takes, or that asks git to write a file
/// (`git.writesFile`) is told and refused, and nothing runs or changes; so is any query while
/// the repository's root is not known (`no_root`).
fn runQuery(work: status.Work, query: []const u8, showing: Showing) !Ran {
    if (work.rootUnknown()) return .no_root;
    const count = vcs_query.count(query) catch |err| {
        work.tell(switch (err) {
            error.UnterminatedQuote => "The query has an unterminated quote",
            error.UnpassableArgument => "The query has an argument git cannot be given: an empty one, or one with a control character",
        });
        return .refused;
    };
    const allocator = try work.scratch();
    if (count > git.max_query_arguments) {
        const sentence = try std.fmt.allocPrint(allocator, "The query has {d} arguments; one log takes at most {d}", .{ count, git.max_query_arguments });
        work.tell(sentence);
        return .refused;
    }
    var arguments: std.Io.Writer.Allocating = .init(allocator);
    _ = try vcs_query.write(&arguments.writer, query);
    if (git.writesFile(arguments.written())) {
        work.tell("--output is not passed to git log here");
        return .refused;
    }
    var argv: std.Io.Writer.Allocating = .init(allocator);
    git.writeArgv(&argv.writer, .{ .log = query }) catch |err| switch (err) {
        error.UnpassableArgument => {
            work.tell("git cannot be given that query");
            return .refused;
        },
        error.WriteFailed => return error.OutOfMemory,
    };
    // Copied first: the query may be the table's text, which the assignment moves.
    const kept = try allocator.dupe(u8, query);
    const asked = try work.pass.writeSingleton(view_table, AskedRow);
    const cells = try work.writeCells(view_table);
    try cells.assignString(asked.query, kept);
    asked.serial.* +%= 1;
    asked.phase.* = @intFromEnum(Phase.loading);
    work.queueQuery(.log, argv.written(), asked.serial.*);
    if (showing == .show) work.enterView(.log);
    try publish(work);
    return .ran;
}

/// `g` in the log view: the query run again as it is, or `default_query` while there is none.
pub fn refresh(work: status.Work) !void {
    const read = try work.pass.readSingleton(view_table, AskedRead);
    const query = if (read.query.len != 0) read.query else default_query;
    _ = try runQuery(work, query, .show);
}

/// A commit of the panel's own made: while the log is a view to come back to, its query is run
/// again, so it lists the commit; the view shown stays.
pub fn followCommit(work: status.Work) !void {
    if (!work.logOnStack()) return;
    const read = try work.pass.readSingleton(view_table, AskedRead);
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    if (phase == .none or read.query.len == 0) return;
    _ = try runQuery(work, read.query, .stay);
}

/// A give-up (`C-g`) or a change of project moved the panel's generation on: a query asked and
/// not answered will never answer, and the note says it was given up.
pub fn abandon(work: status.Work) !void {
    const asked = try work.pass.writeSingleton(view_table, AskedRow);
    if (asked.phase.* != @intFromEnum(Phase.loading)) return;
    asked.phase.* = @intFromEnum(Phase.stopped);
    try publish(work);
}

/// A query's answer, `said`, null for one that failed: its commits in place of those the table
/// held, the cursor kept on its commit (`keepCursor`); what could not be read as commits marks
/// the source unread and is told once. An answer of an earlier query is dropped; a failure is
/// told, and the table keeps what it held.
pub fn takeLog(work: status.Work, epoch: u32, said: ?[]const u8) !void {
    const asked = try work.pass.writeSingleton(view_table, AskedRow);
    if (epoch != asked.serial.*) return;
    const bytes = said orelse {
        asked.phase.* = @intFromEnum(Phase.failed);
        work.tell("git log failed; $ shows why");
        return publish(work);
    };
    const allocator = try work.scratch();
    const commits = try allocator.alloc(git.LogEntry, max_commits);
    const parsed = git.parseLog(bytes, commits);
    const kept = try keptCursor(work);
    // Written row by row in the table's own order, which the page shows.
    const rows = try work.writeCells(log_table);
    const handles = try table_view.rowsInOrder(rows, parsed.commits.kept, allocator);
    for (commits[0..parsed.commits.kept], handles) |commit, handle| {
        try rows.setString(handle, "hash", try ui.displayText(allocator, commit.short_hash));
        try rows.setString(handle, "refs", try ui.displayText(allocator, commit.refs));
        try rows.setString(handle, "subject", try ui.displayText(allocator, commit.subject));
        try rows.setString(handle, "author", try ui.displayText(allocator, commit.author));
        try rows.setString(handle, "date", try ui.displayText(allocator, commit.date));
        try rows.setString(handle, "full_hash", commit.hash);
    }
    asked.listed.* = parsed.commits.seen;
    asked.unread.* = parsed.unread;
    asked.phase.* = @intFromEnum(Phase.answered);
    if (parsed.unread != 0) {
        const read = try work.pass.readSingleton(view_table, AskedRead);
        const query = try oneLine(allocator, read.query);
        const sample = try oneLine(allocator, parsed.first_unread);
        const sentence = try std.fmt.allocPrint(allocator, "git log {s}: the output could not be read as commits ({s})", .{ query, sample });
        work.tell(sentence);
    }
    try publish(work);
    try keepCursor(work, kept);
}

/// Publishes what the log's page shows: the table as `vcs-git.log`, marked `unread` while it
/// holds an answer of which some could not be read, the query and the note.
pub fn publish(work: status.Work) !void {
    const publishing = try document_sources.Publishing.of(work.pass) orelse return;
    const publisher = status.vcs_git_root;
    const allocator = try work.scratch();
    const read = try work.pass.readSingleton(view_table, AskedRead);
    publishing.publishSource(publisher, .{ .name = source_name, .table = log_table, .shown = log_shown });
    if (read.unread.* != 0) publishing.setSourceState(publisher, source_name, .unread);
    publishing.publishValue(publisher, query_value, read.query);
    publishing.publishValue(publisher, "vcs-git.log-note", try noteOf(allocator, read));
}

/// What the note under the query says of the last query, in `allocator`; empty when there is
/// nothing to say, so its line is left out.
pub fn noteOf(allocator: std.mem.Allocator, read: AskedRead) ![]const u8 {
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    return switch (phase) {
        .none => "",
        .loading => "Loading...",
        .failed => "git log failed; $ shows why",
        .stopped => "Gave up; g asks again",
        .answered => if (read.unread.* != 0)
            "The log's output could not be read as commits"
        else if (read.listed.* == 0)
            "No commits match"
        else if (read.listed.* == max_commits + 1)
            // vcs-git's own `--max-count` asked one past the table: git listed that one, and there
            // may be more.
            std.fmt.comptimePrint("More than {d} commits match; the panel lists the first {d}", .{ max_commits, max_commits })
        else if (read.listed.* > max_commits)
            try std.fmt.allocPrint(allocator, "The table holds the first {d} of the {d} commits git listed; -n says how many", .{ max_commits, read.listed.* })
        else
            "",
    };
}

/// Forgets the log, as the panel's data of another repository is: its commits, what came of its
/// query, and the page's cursor. The query and the menu's state stay, the person's.
pub fn forgetLog(work: status.Work) !void {
    const rows = try work.pass.writeTable(log_table);
    rows.clear();
    const asked = try work.pass.writeSingleton(view_table, AskedRow);
    asked.phase.* = @intFromEnum(Phase.none);
    asked.serial.* +%= 1;
    asked.listed.* = 0;
    asked.unread.* = 0;
    document.setCursor(try vcs_page.stateOf(work.pass, page), .{});
    try publish(work);
}

// ---- the cursor ----------------------------------------------------------------------------------

/// The full hash of the commit the page's cursor is on, in the frame's memory; null off a row.
fn cursorHash(work: status.Work) !?[]const u8 {
    const row = switch (try vcs_page.atCursor(work.pass, page)) {
        .row => |row| row,
        .heading, .group, .text, .none => return null,
    };
    const commit = row.table.getRow(row.row, LogRow) orelse return null;
    const allocator = try work.scratch();
    return try allocator.dupe(u8, commit.full_hash);
}

/// Where the page's cursor was as an answer came, to keep it there (`keepCursor`).
const KeptCursor = union(enum) {
    /// On a commit's row: its full hash, in the frame's memory.
    row: []const u8,
    /// On a line of text (the query's, the note) while the table showed rows: it stays there.
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
            const commit = row.table.getRow(row.row, LogRow) orelse return .start;
            const allocator = try work.scratch();
            return .{ .row = try allocator.dupe(u8, commit.full_hash) };
        },
        .text, .heading, .group => return if (tableBlock(laid_out) != null) .line else .start,
        .none => return .start,
    }
}

/// After an answer: the cursor on the commit it was on while that is listed, else on the first
/// row; on a line of text it stays. A commit under the cursor gone, another in its place, marks
/// the page's own `cursor_moved_under`, so a key of the log's later in the run acts on nothing.
fn keepCursor(work: status.Work, kept: KeptCursor) !void {
    const hash: ?[]const u8 = switch (kept) {
        .line => return,
        .start => null,
        .row => |named| named,
    };
    const laid_out = try vcs_page.laidOut(work.pass, page);
    const block = tableBlock(laid_out) orelse return;
    const table = block.table.?.table;
    const found: ?Table.RowHandle = if (hash) |named| rowNaming(table, named) else null;
    if (hash != null and found == null) {
        const moved_under = try vcs_page.movedUnder(work.pass, page);
        moved_under.* = 1;
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
        if (std.mem.eql(u8, table.source, source_name)) return block;
    }
    return null;
}

/// The row of `table`, the log's, whose full hash is `hash`.
fn rowNaming(table: *Table, hash: []const u8) ?Table.RowHandle {
    var rows = table.readQuery(LogRow);
    while (rows.next()) |row| {
        if (std.mem.eql(u8, row.view.full_hash, hash)) return row.handle;
    }
    return null;
}

/// RET in the log view: what the cursor is on (`chooseAt`), unless an answer earlier in the
/// run took its commit away.
pub fn visit(work: status.Work) !void {
    if (try vcs_page.changedUnderCursor(work.pass, page)) return;
    try chooseAt(work, try vcs_page.atCursor(work.pass, page));
}

/// RET on `at`, or a click on what the cursor is on: the query's line opens its prompt, a
/// commit's row shows it in the diff panel.
pub fn chooseAt(work: status.Work, at: document.At) !void {
    switch (at) {
        .text => |line| {
            const laid_out = try vcs_page.laidOut(work.pass, page);
            const on_query = for (laid_out.blocks) |block| {
                if (block.key == line.key) break block.line == query_line;
            } else false;
            if (on_query) try presentQuery(work, null);
        },
        .row => |row| {
            if (try vcs_page.changedUnderCursor(work.pass, page)) return;
            const commit = row.table.getRow(row.row, LogRow) orelse return;
            const allocator = try work.scratch();
            const hash = try allocator.dupe(u8, commit.full_hash);
            try git_diff.show(work, .{ .commit = .{ .hash = hash } });
        },
        .heading, .group, .none => {},
    }
}

/// The full hash of the commit on the page's cursor row, in the frame's memory; null off a row:
/// what `c f` fixes up in the log view, through `git_status.Work.commitAtCursor`, which guards
/// it.
pub fn commitAtCursor(work: status.Work) !?[]const u8 {
    return cursorHash(work);
}

// ---- the query's prompt --------------------------------------------------------------------------

/// `e`, or RET on the query's line: a prompt holding `holding`, or with null the query, or
/// `default_query` while there is none; its answer comes as `vcs_git_log_query`.
fn presentQuery(work: status.Work, holding: ?[]const u8) !void {
    const memory = work.pass.frame.memory;
    const read = try work.pass.readSingleton(view_table, AskedRead);
    const allocator = try action_palette.completionAllocator(memory, .vcs);
    action_palette.resetCompletionArena(memory, .vcs);
    const shown = holding orelse if (read.query.len != 0) read.query else default_query;
    const completions = try allocator.create(action_palette.Completions);
    completions.* = .{
        .owner = query_prompt,
        .presentation = .prompt,
        .title = "git log",
        .initial_query = try allocator.dupe(u8, shown),
        .initial_query_edit = .append,
        .accepts_text = true,
        .entries = &.{},
    };
    try action_palette.ownRequestText(allocator, completions);
    const reply = sequencer.ReplyTo.of(status.system(), .from(Msg.vcs_git_log_query));
    action_palette.request(memory, work.pass.frame.tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// The query's prompt's events: on Enter its text replaces the query and runs, an empty one
/// running `default_query`; a query refused (`runQuery`) is told and the prompt opens again
/// holding what was typed, to be put right, but not when the repository's root is not known,
/// which no edit of the query puts right; closed with nothing, nothing changes.
fn takeQuery(work: status.Work, received: sequencer.Message) !void {
    const event = try action_palette.eventOf(received);
    if (event.kind == .query_changed) return;
    action_palette.request(work.pass.frame.memory, work.pass.frame.tables, .{ .acknowledge = .{ .owner = query_prompt } });
    _ = event.completion orelse return;
    const typed = std.mem.trim(u8, event.query, " \t\r\n");
    const allocator = try work.scratch();
    const query = if (typed.len == 0) default_query else try allocator.dupe(u8, typed);
    const ran = try runQuery(work, query, .show);
    if (ran == .refused) try presentQuery(work, query);
}

// ---- the revision ----------------------------------------------------------------------------------

/// The revision `o` read in a prompt of the branches (`git_branch.askListing`): the menu's
/// query, as it closed, written for it and run.
pub fn runRevision(work: status.Work, revision: []const u8) !void {
    try runMenu(work, .{ .revision = revision });
}

// ---- helpers -------------------------------------------------------------------------------------

/// `text` made displayable (`ui.displayText`) as one line of `*Messages*`, in `allocator`: each
/// control character (a line break, a tab, git's field separator) is a space, as a record git
/// wrote may hold them (a `--stat`'s lines).
fn oneLine(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const shown = try ui.displayText(allocator, text);
    const line = try allocator.dupe(u8, shown);
    for (line) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    return line;
}
