//! The programs a person runs from the text editor, as consult and Emacs's compile run them:
//!
//! - `text_grep` (M-s r) searches the project with ripgrep as its text is typed, and goes to
//!   the match chosen.
//! - `text_find_project_file` (M-s f, C-x p f) lists the project's files, which fd names, and
//!   opens the one chosen where its kind goes, as `open` does: a figure or a
//!   sketch in the figure editor, a log in the profiler, anything else as text.
//! - `text_compile` (C-x p c) runs a command in the system's shell (`sh -c`, or `cmd /D /S /C`
//!   on Windows) and keeps what it says in `*compilation*`; `text_next_error` (M-g n) and
//!   `text_previous_error` (M-g p) go through the places its lines name, as `file:line:column`.
//!
//! ripgrep and fd are those in `vendor/` (`os.PlacesView.vendor_directory`, `vendoredProgram`).
//! The programs run through the process system, in the working directory, the project in
//! Emacs's sense, which `project_switch` (C-x p p) changes. A frame never waits on one: what a
//! program says is read as it arrives. The paths a program names are read against the
//! directory it ran in, kept with it, so a match or an error listed before the project changed
//! still opens the file it named.
//!
//! `global_keys` holds the project's keys, `C-x p`, Emacs's project.el's: those of the
//! actions here and those of `open`'s and `text_panel`'s project actions.

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const memory_mod = mesha.memory;
const process = mesha.process;
const resources = mesha.resources;
const sequencer = mesha.sequencer;
const action_palette = @import("action_palette.zig");
const editor_mod = @import("editor.zig");
const modes = @import("modes.zig");
const text_editor = plugin.text_editor_api;
const text_panel = @import("text_panel.zig");
const open = @import("open.zig");

const Log = mesha.log.scope("text_tools");

const Msg = enum(u64) {
    text_grep = Atom.from("text_grep").value(),
    text_find_project_file = Atom.from("text_find_project_file").value(),
    text_compile = Atom.from("text_compile").value(),
    text_next_error = Atom.from("text_next_error").value(),
    text_previous_error = Atom.from("text_previous_error").value(),
    /// The events of the prompt of whichever tool is asking.
    text_tools_prompt = Atom.from("text_tools_prompt").value(),
    /// The process system's answer to a search's program, its serial the user data.
    text_tools_spawned = Atom.from("text_tools_spawned").value(),
    /// The process system's answer to the compile's program.
    text_tools_compiling = Atom.from("text_tools_compiling").value(),
    _,
};

/// Offered from anywhere, by the editor.
pub const actions = [_]plugin.action_api.Def{
    .{ .name = "grep", .tag = @tagName(Msg.text_grep), .doc = "Search the project's files with ripgrep as the text is typed" },
    .{ .name = "find_project_file", .tag = @tagName(Msg.text_find_project_file), .doc = "Open one of the project's files, chosen by its name" },
    .{ .name = "compile", .tag = @tagName(Msg.text_compile), .doc = "Run a command and keep what it says in *compilation*" },
    .{ .name = "next_error", .tag = @tagName(Msg.text_next_error), .doc = "Go to the next place the compilation names, or the next diagnostic" },
    .{ .name = "previous_error", .tag = @tagName(Msg.text_previous_error), .doc = "Go to the place the compilation names before this one, or the diagnostic before" },
};

/// The keys of `actions`, and of the other project actions, of the mode `global`, as Emacs's.
pub const global_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "M-s r", .action = .{ "global", "grep" } },
    .{ .chord = "M-s f", .action = .{ "global", "find_project_file" } },
    .{ .chord = "C-x p p", .action = .{ "global", "project_switch" } },
    .{ .chord = "C-x p f", .action = .{ "global", "find_project_file" } },
    .{ .chord = "C-x p g", .action = .{ "global", "grep" } },
    .{ .chord = "C-x p d", .action = .{ "global", "project_find_directory" } },
    .{ .chord = "C-x p b", .action = .{ "global", "project_switch_buffer" } },
    .{ .chord = "C-x p c", .action = .{ "global", "compile" } },
    .{ .chord = "C-x p S-d", .action = .{ "global", "project_forget" } },
    .{ .chord = "M-g n", .action = .{ "global", "next_error" } },
    .{ .chord = "M-g p", .action = .{ "global", "previous_error" } },
    .{ .chord = "M-g M-n", .action = .{ "global", "next_error" } },
    .{ .chord = "M-g M-p", .action = .{ "global", "previous_error" } },
};

pub fn system() sequencer.System {
    return .{
        .name = "text_tools",
        .names = comptime &sequencer.enumNames(Msg),
        .root = editor_mod.editor_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "text_tools.take_messages", .run = takeMessages },
            .{ .name = "text_tools.follow_programs", .run = followPrograms },
        },
    };
}

/// Which tool's prompt is open.
const Tool = enum(u8) { none, grep, files, compile };

pub const table_name = "editor_text_tools";
const state_table = Atom.from(table_name);

const StateRow = struct {
    /// A `Tool`: whose prompt is open.
    tool: *u8,
    /// The program of the open prompt's search, a `process.Process`; none while there is none.
    program: *u32,
    /// Counts the searches started: an answer for an earlier one is for a program no longer
    /// wanted.
    serial: *u32,
    /// How many lines of the program's output the prompt last listed.
    listed: *u32,
    /// The compile's program, which outlasts its prompt, and how much of what it said is
    /// already in `*compilation*`.
    compiling: *u32,
    compile_read: *u64,
    /// The command last compiled with: what the next compile offers.
    compile_command: *Table.String,
    /// The line of `*compilation*` the last error gone to is on; the next is looked for after.
    error_line: *u32,
    /// Whether an error has been gone to since the compile began.
    error_visited: *u8,
    /// The working directory the open prompt's searches run in, and the compile's: what the
    /// paths they name are read against. Absolute, or empty when the host did not say.
    search_directory: *Table.String,
    compile_directory: *Table.String,
};

/// What a compile offers the first time.
const default_compile_command = "zig build";

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ table_name, prompt_owner_name, text_panel.compilation_name });
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 11);
    defer schema.deinit();
    try schema.addFieldFallible("tool", u8, .int);
    try schema.addFieldFallible("program", u32, .int);
    try schema.addFieldFallible("serial", u32, .int);
    try schema.addFieldFallible("listed", u32, .int);
    try schema.addFieldFallible("compiling", u32, .int);
    try schema.addFieldFallible("compile_read", u64, .int);
    try schema.addFieldFallible("compile_command", Table.String, .text_field);
    try schema.addFieldFallible("error_line", u32, .int);
    try schema.addFieldFallible("error_visited", u8, .int);
    try schema.addFieldFallible("search_directory", Table.String, .text_field);
    try schema.addFieldFallible("compile_directory", Table.String, .text_field);
    const defaults = .{
        .tool = @as(u8, @intFromEnum(Tool.none)),
        .program = @as(u32, 0),
        .serial = @as(u32, 0),
        .listed = @as(u32, 0),
        .compiling = @as(u32, 0),
        .compile_read = @as(u64, 0),
        .compile_command = Table.String{},
        .error_line = @as(u32, 0),
        .error_visited = @as(u8, 0),
        .search_directory = Table.String{},
        .compile_directory = Table.String{},
    };
    _ = try tables.ensureSingleton(&schema, state_table, defaults, .durable);
}

const prompt_owner_name = "text_tools_prompt";
const prompt_owner = Atom.from(prompt_owner_name);

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.write(state_table);
    result.read(Atom.from(action_palette.table_name));
    result.write(Atom.from(action_palette.requests_table_name));
    result.writeIfPresent(tables, Atom.from(process.commands_table_name));
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    // With no compilation to go through, the next error is the next diagnostic's action.
    result.writeIfPresent(tables, Atom.from(plugin.action_api.commands_table_name));
    // A file found opens where its kind goes, as `open` sends it.
    open.declareOpenAccess(&result, tables);
    // The working directory, where the programs run.
    result.read(Atom.from(mesha.os.places_table_name));
    process.Events.declare(&result, tables, process.events_table_name);
    // What the programs said is read from their own tables, and the compilation's lines
    // from its buffer.
    const found = tables.findByName(state_table) orelse return result;
    var rows = found.readQuery(StateRow);
    const state = rows.next() orelse return result;
    process.declareProcess(&result, tables, @enumFromInt(state.view.program.*));
    process.declareProcess(&result, tables, @enumFromInt(state.view.compiling.*));
    text_editor.declareBuffer(&result, tables, text_panel.compilation_buffer);
    return result;
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const state = try pass.writeSingleton(state_table, StateRow);
    const cells = try pass.writeTable(state_table);
    for (frame.messages) |received| {
        handle(pass, cells, state, received) catch |err| received.unreadable(err);
    }
}

fn handle(pass: *sequencer.Pass, cells: *Table, state: StateRow, received: sequencer.Message) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const memory = frame.memory;
    switch (received.tag.to(Msg)) {
        .text_grep => {
            endSearch(tables, state);
            state.tool.* = @intFromEnum(Tool.grep);
            const working_directory = open.places(pass).working_directory;
            try cells.assignString(state.search_directory, working_directory);
            presentTool(tables, .{ .prompt = "Ripgrep:", .title = "Search the project's files", .tab = .nothing, .entries = &.{} }, .open);
        },
        .text_find_project_file => {
            endSearch(tables, state);
            state.tool.* = @intFromEnum(Tool.files);
            const places = open.places(pass);
            try cells.assignString(state.search_directory, places.working_directory);
            const directory = cells.textOf(state.search_directory.*);
            const scratch = try memory.frameScratchAllocator();
            const fd = try vendoredProgram(scratch.allocator, places.vendor_directory, .fd);
            // The files ripgrep would search: those no ignore file names, hidden ones left out.
            startSearch(tables, state, directory, &.{ fd, "--type", "file", "--strip-cwd-prefix", "--color", "never" });
            presentTool(tables, .{ .prompt = "Find file:", .title = "Open one of the project's files", .entries = &.{} }, .open);
        },
        .text_compile => {
            endSearch(tables, state);
            state.tool.* = @intFromEnum(Tool.compile);
            const last = cells.textOf(state.compile_command.*);
            const offered = if (last.len != 0) last else default_compile_command;
            presentTool(tables, .{ .prompt = "Compile command:", .initial_query = offered, .accepts_text = true, .entries = &.{} }, .open);
        },
        .text_next_error, .text_previous_error => {
            const direction: Direction = if (received.tag.to(Msg) == .text_next_error) .next else .previous;
            const compile_directory = cells.textOf(state.compile_directory.*);
            gotoError(tables, state, compile_directory, direction);
        },
        .text_tools_prompt => {
            const event = try action_palette.eventOf(received);
            const tool: Tool = std.enums.fromInt(Tool, state.tool.*) orelse .none;
            const search_directory = cells.textOf(state.search_directory.*);
            if (event.kind == .query_changed) {
                switch (tool) {
                    .none, .compile => {},
                    .grep => {
                        const scratch = try memory.frameScratchAllocator();
                        const vendor_directory = open.places(pass).vendor_directory;
                        const rg = try vendoredProgram(scratch.allocator, vendor_directory, .rg);
                        searchFor(tables, state, rg, search_directory, event.query);
                    },
                    .files => listFiles(tables, state, event.query),
                }
                return;
            }
            action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            state.tool.* = @intFromEnum(Tool.none);
            endSearch(tables, state);
            const chosen = event.completion orelse return;
            switch (tool) {
                .none => {},
                .grep => openMatch(tables, search_directory, chosen.label),
                .files => {
                    const scratch = try memory.frameScratchAllocator();
                    const file = pathIn(scratch.allocator, search_directory, chosen.label, builtin.os.tag);
                    try open.openPath(pass, file, .present);
                },
                .compile => {
                    const command = std.mem.trim(u8, event.query, " ");
                    if (command.len == 0) return;
                    try cells.assignString(state.compile_command, command);
                    const working_directory = open.places(pass).working_directory;
                    try cells.assignString(state.compile_directory, working_directory);
                    const compile_directory = cells.textOf(state.compile_directory.*);
                    startCompile(tables, state, compile_directory, command);
                },
            }
        },
        .text_tools_spawned => {
            const spawned = try received.payloadAs(process.SpawnedMsg);
            const serial = (try received.userDataAs(u32)).*;
            // A search given up or begun again since: its program is not wanted.
            const wanted = serial == state.serial.* and state.tool.* != @intFromEnum(Tool.none);
            if (spawned.result != .spawned) {
                const program = if (state.tool.* == @intFromEnum(Tool.files)) "fd" else "ripgrep (rg)";
                if (wanted) tellNotStarted(tables, program, spawned.result);
                return;
            }
            if (!wanted) return process.request(memory, tables, .{ .release = spawned.process });
            state.program.* = @intFromEnum(spawned.process);
            state.listed.* = 0;
        },
        .text_tools_compiling => {
            const spawned = try received.payloadAs(process.SpawnedMsg);
            if (spawned.result != .spawned) return tellNotStarted(tables, "The compile's shell", spawned.result);
            // A compile asked for before this one answered is let go: the last asked for is kept.
            if (state.compiling.* != 0) process.request(memory, tables, .{ .release = @enumFromInt(state.compiling.*) });
            state.compiling.* = @intFromEnum(spawned.process);
            state.compile_read.* = 0;
        },
        _ => {},
    }
}

fn tellNotStarted(tables: *Table.Registry, program: []const u8, result: process.SpawnResult) void {
    var message_buffer: [128]u8 = undefined;
    const reason: []const u8 = if (result == .not_found) "was not found" else "could not be run";
    const message = std.fmt.bufPrint(&message_buffer, "{s} {s}", .{ program, reason }) catch return;
    text_editor.message(tables.memory, tables, message);
}

// ---- the prompt --------------------------------------------------------------------------------

/// The most entries a search lists: the first it finds.
const max_listed = 200;
/// The most of a line of a program's output an entry shows.
const max_entry_bytes = 240;

/// Shows `completions` as the tools' prompt, or in place of what the open prompt lists.
fn presentTool(tables: *Table.Registry, completions: action_palette.Completions, how: enum { open, relist }) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .text_tools) catch return;
    const kept = allocator.create(action_palette.Completions) catch return;
    kept.* = completions;
    kept.owner = prompt_owner;
    action_palette.ownRequestText(allocator, kept) catch return;
    if (how == .relist) return action_palette.request(memory, tables, .{ .replace = .{ .completions = kept } });
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_tools_prompt));
    action_palette.request(memory, tables, .{ .present = .{ .completions = kept, .reply = reply } });
}

/// The programs the plugins' build writes to `vendor/`, each named for its file.
const Vendored = enum { fd, rg };

/// `program` in `vendor_directory`: `vendor/fd/fd` and `vendor/ripgrep/rg`. Its name alone,
/// found on `PATH`, when the host names no vendor folder. Allocated in `allocator` unless it is
/// the name alone.
fn vendoredProgram(allocator: std.mem.Allocator, vendor_directory: []const u8, program: Vendored) ![]const u8 {
    const name = @tagName(program);
    if (vendor_directory.len == 0) return name;
    const folder = switch (program) {
        .fd => "fd",
        .rg => "ripgrep",
    };
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}{s}", .{ vendor_directory, folder, name, suffix });
}

/// Runs `arguments` as the open prompt's search, in `directory`, the working directory when
/// it is empty. Its answer names it by the search's serial.
fn startSearch(tables: *Table.Registry, state: StateRow, directory: []const u8, arguments: []const []const u8) void {
    var argv_buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&argv_buffer);
    for (arguments, 0..) |argument, index| {
        if (index != 0) writer.writeByte(process.argument_separator) catch return;
        writer.writeAll(argument) catch return;
    }
    state.serial.* +%= 1;
    const serial = state.serial.*;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_tools_spawned)).with(.of(&serial));
    process.request(tables.memory, tables, .{ .spawn = .{
        .argv = writer.buffered(),
        .cwd = directory,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .reply = reply,
    } });
}

/// Ends the open prompt's search: its program is let go, and one still starting is not
/// wanted when it answers.
fn endSearch(tables: *Table.Registry, state: StateRow) void {
    state.serial.* +%= 1;
    state.listed.* = 0;
    if (state.program.* == 0) return;
    process.request(tables.memory, tables, .{ .release = @enumFromInt(state.program.*) });
    state.program.* = 0;
}

/// The fewest characters ripgrep is run for, as consult waits for three.
const min_grep_characters = 3;

/// The search's text changed: ripgrep, `rg`, runs again for it in `directory`, and the prompt
/// lists nothing until it answers.
fn searchFor(tables: *Table.Registry, state: StateRow, rg: []const u8, directory: []const u8, query: []const u8) void {
    endSearch(tables, state);
    action_palette.resetCompletionArena(tables.memory, .text_tools);
    presentTool(tables, .{ .prompt = "Ripgrep:", .title = "Search the project's files", .tab = .nothing, .initial_query = query, .entries = &.{} }, .relist);
    if (query.len < min_grep_characters) return;
    startSearch(tables, state, directory, &.{ rg, "--line-number", "--column", "--no-heading", "--color=never", "--smart-case", "--max-columns=200", "--regexp", query, "." });
}

/// The lines the search's program has said so far, a whole line each.
fn outputLines(tables: *Table.Registry, state: StateRow) std.mem.SplitIterator(u8, .scalar) {
    const output = process.outputOf(tables, @enumFromInt(state.program.*));
    const said: []const u8 = if (output) |found| found.after(.stdout, 0) else "";
    // What follows the last line's ending is a line still arriving.
    const whole = if (std.mem.lastIndexOfScalar(u8, said, '\n')) |last| said[0 .. last + 1] else "";
    return std.mem.splitScalar(u8, whole, '\n');
}

/// Lists ripgrep's matches so far in the prompt, when more have arrived than it lists.
fn listMatches(tables: *Table.Registry, atoms: *Atom.Registry, state: StateRow) void {
    const allocator = action_palette.completionAllocator(tables.memory, .text_tools) catch return;
    var lines = outputLines(tables, state);
    var counted: u32 = 0;
    while (lines.next()) |line| {
        if (line.len != 0 and counted < max_listed) counted += 1;
    }
    if (counted == state.listed.*) return;
    state.listed.* = counted;
    const entries = allocator.alloc(action_palette.Completion, counted) catch return;
    lines.reset();
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or count == entries.len) continue;
        // A match's line begins `./`, as the directory searched was named.
        const shown = if (std.mem.startsWith(u8, line, "./")) line[2..] else line;
        entries[count] = .{ .label = shown[0..@min(shown.len, max_entry_bytes)] };
        count += 1;
    }
    const query = action_palette.promptText(tables, atoms);
    presentTool(tables, .{ .prompt = "Ripgrep:", .title = "Search the project's files", .tab = .nothing, .initial_query = query, .entries = entries[0..count] }, .relist);
}

/// Whether `name` holds every word of `query`, in either case: the words in any order.
fn holdsEveryWord(name: []const u8, query: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        if (std.ascii.indexOfIgnoreCase(name, word) == null) return false;
    }
    return true;
}

/// Lists the project's files whose names hold every word of `query`, the first found.
fn listFiles(tables: *Table.Registry, state: StateRow, query: []const u8) void {
    const allocator = action_palette.completionAllocator(tables.memory, .text_tools) catch return;
    action_palette.resetCompletionArena(tables.memory, .text_tools);
    const entries = allocator.alloc(action_palette.Completion, max_listed) catch return;
    var lines = outputLines(tables, state);
    var count: usize = 0;
    var known: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        known += 1;
        if (count == entries.len or !holdsEveryWord(line, query)) continue;
        entries[count] = .{ .label = line[0..@min(line.len, max_entry_bytes)] };
        count += 1;
    }
    state.listed.* = known;
    presentTool(tables, .{ .prompt = "Find file:", .title = "Open one of the project's files", .initial_query = query, .entries = entries[0..count] }, .relist);
}

/// A place a line names as `file:line:column`, as ripgrep and compilers do; the column is 1
/// when the line names none.
const Place = struct { path: []const u8, line: u32, column: u32 };

fn placeIn(text: []const u8) ?Place {
    const path_end = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const path = text[0..path_end];
    if (path.len == 0 or std.mem.indexOfAny(u8, path, " \t") != null) return null;
    var rest = text[path_end + 1 ..];
    const line_end = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const line = std.fmt.parseInt(u32, rest[0..line_end], 10) catch return null;
    rest = rest[line_end + 1 ..];
    const column_end = std.mem.indexOfScalar(u8, rest, ':') orelse 0;
    const column = std.fmt.parseInt(u32, rest[0..column_end], 10) catch 1;
    return .{ .path = path, .line = line, .column = column };
}

/// Opens the file a match's entry names, read against `directory`, the search's, the caret at
/// the match.
fn openMatch(tables: *Table.Registry, directory: []const u8, label: []const u8) void {
    const place = placeIn(label) orelse return;
    const scratch = tables.memory.frameScratchAllocator() catch return;
    const file = pathIn(scratch.allocator, directory, place.path, builtin.os.tag);
    text_panel.openAt(tables, file, place.line -| 1, place.column -| 1);
}

/// `path`, as a program run in `directory` named it, made absolute against `directory` when
/// it is relative and `directory` is known, in `allocator`; else `path` itself. Built for
/// Windows (`os_tag`), where a program may name it with `\`, its separators are made `/`
/// first, so `C:\x` is absolute too; elsewhere a `\` is a name's.
fn pathIn(allocator: std.mem.Allocator, directory: []const u8, path: []const u8, os_tag: std.Target.Os.Tag) []const u8 {
    const separated = switch (os_tag) {
        .windows => std.mem.replaceOwned(u8, allocator, path, "\\", "/") catch path,
        else => path,
    };
    if (directory.len == 0 or resources.isAbsolutePath(separated)) return separated;
    return open.joinedPath(allocator, directory, separated) catch separated;
}

// ---- compiling ---------------------------------------------------------------------------------

/// Runs `command` in a shell in `directory`, the working directory when it is empty, what it
/// says to be kept in `*compilation*`, which holds only this compile's.
fn startCompile(tables: *Table.Registry, state: StateRow, directory: []const u8, command: []const u8) void {
    const memory = tables.memory;
    if (state.compiling.* != 0) process.request(memory, tables, .{ .release = @enumFromInt(state.compiling.*) });
    state.compiling.* = 0;
    state.compile_read.* = 0;
    state.error_line.* = 0;
    state.error_visited.* = 0;
    // Made the first time, which shows it in another window; after that only emptied, so a
    // window that shows it goes on showing it.
    if (text_editor.rowOf(tables, text_panel.compilation_buffer) == null) {
        text_editor.request(memory, tables, .{ .create = .{ .buffer = text_panel.compilation_buffer, .lines = .multi, .name = text_panel.compilation_name, .access = .read_only } });
    } else {
        text_editor.request(memory, tables, .{ .set_text = .{ .buffer = text_panel.compilation_buffer, .text = "" } });
    }
    var said_buffer: [512]u8 = undefined;
    const said = std.fmt.bufPrint(&said_buffer, "$ {s}", .{command}) catch command;
    tellCompilation(tables, said);

    var argv_buffer: [2048]u8 = undefined;
    const argv = shellArgv(&argv_buffer, builtin.os.tag, command) orelse return;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_tools_compiling));
    process.request(memory, tables, .{ .spawn = .{ .argv = argv, .cwd = directory, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore, .reply = reply } });
}

/// The argv, joined by `process.argument_separator` in `buffer`, that runs `command` in the
/// shell of `os_tag`, its errors with its output in the order it says them: `sh -c` and, on
/// Windows, `cmd /D /S /C`, whose `/S` takes the command whole however it is quoted. Null
/// when it does not fit `buffer`.
fn shellArgv(buffer: []u8, os_tag: std.Target.Os.Tag, command: []const u8) ?[]const u8 {
    const separator = [_]u8{process.argument_separator};
    return switch (os_tag) {
        .windows => std.fmt.bufPrint(buffer, "cmd{s}/D{s}/S{s}/C{s}{s} 2>&1", .{ separator, separator, separator, separator, command }) catch null,
        else => std.fmt.bufPrint(buffer, "sh{s}-c{s}{s} 2>&1", .{ separator, separator, command }) catch null,
    };
}

fn tellCompilation(tables: *Table.Registry, line: []const u8) void {
    text_editor.request(tables.memory, tables, .{ .tell = .{ .buffer = text_panel.compilation_buffer, .name = text_panel.compilation_name, .line = line } });
}

/// Moves what the compile has said since the last look into `*compilation*`, a whole line
/// at a time.
fn readCompile(tables: *Table.Registry, state: StateRow) void {
    const compiling: process.Process = @enumFromInt(state.compiling.*);
    const output = process.outputOf(tables, compiling) orelse return;
    const said = output.after(.stdout, state.compile_read.*);
    const whole_len = if (std.mem.lastIndexOfScalar(u8, said, '\n')) |last| last + 1 else return;
    var lines = std.mem.splitScalar(u8, said[0 .. whole_len - 1], '\n');
    while (lines.next()) |line| tellCompilation(tables, std.mem.trimEnd(u8, line, "\r"));
    state.compile_read.* += whole_len;
    process.request(tables.memory, tables, .{ .consume = .{ .process = compiling, .stream = .stdout, .through = state.compile_read.* } });
}

/// The compile ended: what it said last, with no line's ending after it, and how it ended.
fn finishCompile(tables: *Table.Registry, state: StateRow, code: i32) void {
    const memory = tables.memory;
    const compiling: process.Process = @enumFromInt(state.compiling.*);
    readCompile(tables, state);
    if (process.outputOf(tables, compiling)) |output| {
        const rest = output.after(.stdout, state.compile_read.*);
        if (rest.len != 0) tellCompilation(tables, rest);
    }
    var ended_buffer: [96]u8 = undefined;
    const ended = if (code == 0)
        "Compilation finished"
    else
        std.fmt.bufPrint(&ended_buffer, "Compilation exited abnormally with code {d}", .{code}) catch "Compilation exited abnormally";
    tellCompilation(tables, ended);
    text_editor.message(memory, tables, ended);
    process.request(memory, tables, .{ .release = compiling });
    state.compiling.* = 0;
}

/// Each frame: what the programs said and how they ended.
fn followPrograms(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    var events: [32]process.Event = undefined;
    const told = try process.Events.of(tables, process.events_table_name).read(pass, Atom.from(system().name), &events);
    if (told.len == 0) return;
    const state = try pass.writeSingleton(state_table, StateRow);
    for (told) |event| {
        const about: process.Process = switch (event) {
            .output => |output| output.process,
            .exited => |exited| exited.process,
        };
        const number = @intFromEnum(about);
        if (number == 0) continue;
        if (number == state.compiling.*) {
            switch (event) {
                .output => readCompile(tables, state),
                .exited => |exited| finishCompile(tables, state, exited.code),
            }
            continue;
        }
        if (number != state.program.*) continue;
        const tool: Tool = std.enums.fromInt(Tool, state.tool.*) orelse .none;
        switch (tool) {
            .grep => listMatches(tables, pass.frame.atoms, state),
            .files => {
                const query = action_palette.promptText(tables, pass.frame.atoms);
                listFiles(tables, state, query);
            },
            .none, .compile => {},
        }
    }
}

// ---- going through the compilation's errors -----------------------------------------------------

const Direction = enum { next, previous };

/// Goes to the next place a line of `*compilation*` names, read against `directory`, the
/// compile's, or the one before, and puts that buffer's caret on the line. With no
/// compilation, the language server's diagnostics are gone through instead, as Emacs's
/// `next-error` goes through whichever list is there.
fn gotoError(tables: *Table.Registry, state: StateRow, directory: []const u8, direction: Direction) void {
    const memory = tables.memory;
    const view = text_editor.viewOf(tables, text_panel.compilation_buffer) orelse {
        const diagnostic: []const u8 = if (direction == .next) "next_diagnostic" else "previous_diagnostic";
        const diagnostic_id: plugin.action_api.ActionId = .{ modes.buffer, Atom.from(diagnostic) };
        return plugin.action_api.requestInvoke(tables, diagnostic_id);
    };
    const line_count = view.lineCount();
    var line_buffer: [512]u8 = undefined;
    // From the line last gone to; the first time, from before the first or after the last.
    var line: i64 = state.error_line.*;
    if (state.error_visited.* == 0) line = if (direction == .next) -1 else line_count;
    while (true) {
        line += if (direction == .next) 1 else -1;
        if (line < 0 or line >= line_count) return text_editor.message(memory, tables, "No more errors");
        const index: u32 = @intCast(line);
        const start = view.lineStart(index);
        const length = @min(view.lineEnd(index) - start, line_buffer.len);
        const text = view.copyRange(start, line_buffer[0..length]);
        const place = placeIn(text) orelse continue;
        state.error_line.* = index;
        state.error_visited.* = 1;
        text_editor.request(memory, tables, .{ .set_caret = .{ .buffer = text_panel.compilation_buffer, .line = index, .column = 0, .select = .move } });
        const scratch = memory.frameScratchAllocator() catch return;
        const file = pathIn(scratch.allocator, directory, place.path, builtin.os.tag);
        return text_panel.openAt(tables, file, place.line -| 1, place.column -| 1);
    }
}

test "a place is read from the lines ripgrep and compilers write" {
    const match = placeIn("editor/src/open.zig:12:5:const std = @import(\"std\");").?;
    try std.testing.expectEqualStrings("editor/src/open.zig", match.path);
    try std.testing.expectEqual(@as(u32, 12), match.line);
    try std.testing.expectEqual(@as(u32, 5), match.column);
    // A line with no column names its first.
    const lined = placeIn("Makefile:7: recipe failed").?;
    try std.testing.expectEqual(@as(u32, 7), lined.line);
    try std.testing.expectEqual(@as(u32, 1), lined.column);
    try std.testing.expect(placeIn("$ zig build") == null);
    try std.testing.expect(placeIn("error: something failed") == null);
    try std.testing.expect(placeIn("note: see main.zig:3:1") == null);

    try std.testing.expect(holdsEveryWord("editor/src/text_panel.zig", "panel TEXT"));
    try std.testing.expect(!holdsEveryWord("editor/src/text_panel.zig", "panel figure"));
    try std.testing.expect(holdsEveryWord("anything", ""));
}

test "a compile runs in sh off Windows and in cmd on it, its command one argument" {
    var buffer: [128]u8 = undefined;
    const separator = [_]u8{process.argument_separator};
    const posix = shellArgv(&buffer, .linux, "zig build").?;
    try std.testing.expectEqualStrings("sh" ++ separator ++ "-c" ++ separator ++ "zig build 2>&1", posix);
    const windows = shellArgv(&buffer, .windows, "zig build").?;
    try std.testing.expectEqualStrings("cmd" ++ separator ++ "/D" ++ separator ++ "/S" ++ separator ++ "/C" ++ separator ++ "zig build 2>&1", windows);
}

test "a tool's result path is read against the directory it ran in, its `\\` a separator on Windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("C:/proj/src/a.zig", pathIn(allocator, "C:/proj", "src\\a.zig", .windows));
    try std.testing.expectEqualStrings("C:/x/a.zig", pathIn(allocator, "C:/proj", "C:\\x\\a.zig", .windows));
    try std.testing.expectEqualStrings("/proj/src/a.zig", pathIn(allocator, "/proj", "src/a.zig", .linux));
    try std.testing.expectEqualStrings("/proj/a\\b.zig", pathIn(allocator, "/proj", "a\\b.zig", .linux));
    try std.testing.expectEqualStrings("/x/a.zig", pathIn(allocator, "/proj", "/x/a.zig", .linux));
}
