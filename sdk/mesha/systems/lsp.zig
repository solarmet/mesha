//! The language server system: what a file's language server says about it, for the buffers
//! of the text editor that hold source files. It draws nothing.
//!
//! - `lsp.mappings` says which server a file's extension takes: the command that starts it,
//!   the language it is told the file is in, and the files that mark a project's root. It
//!   is made with the defaults; edits apply to servers started after. A program the build
//!   the plugins' build wrote to the vendor folder (`os.PlacesView.vendor_directory`:
//!   `vendor/clice/bin/clice`, `vendor/zls/zls`) is taken before one on `PATH`.
//! - `lsp` is the system's own state, one row; `lsp_servers` the servers started, a row
//!   each; `lsp_documents` the buffers on a server, a row each, with the address of what
//!   the server last said of the buffer: its colours and its diagnostics.
//! - `commands.lsp` asks a buffer's server where a name is defined, what it is, what could be
//!   typed at a place and what the buffer defines (`CmdPayload`); the answers go to the asker's
//!   inbox.
//! - `events.lsp` tells that what is known of a buffer, or a server's state, changed.
//!
//! Servers are programs of the process system: this system spawns them, writes to them and
//! reads their output through `commands.process` and `events.process`. It follows the text
//! editor's buffers through `events.text_editor`: a buffer that opens with a file a mapping
//! takes is opened on the server for its program and root; its text is sent again whole
//! once it has been quiet for `quiet_ms`, and its colours asked for again.
//!
//! What a document's row addresses (`DocumentView`) is this system's and changes only while
//! it applies commands: between two applications it is stable, as a text view is. Positions
//! in it are lines and byte columns of the buffer's text.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");

/// What a piece of text is, as far as its colour goes.
pub const TokenKind = enum(u8) {
    /// Text of no other kind.
    plain,
    /// A word of the language.
    keyword,
    /// A string or character literal.
    string,
    /// A numeric literal.
    number,
    /// A comment.
    comment,
    /// A type's name.
    type,
    /// A function's name.
    function,
};

/// A coloured piece of a line. In a `DocumentView`, `start` and `length` are bytes of the buffer's
/// line; as a server sends them they are in the server's units, which the runtime converts.
pub const Token = extern struct {
    /// The line it is on, counted from 0.
    line: u32,
    /// Where on the line it begins.
    start: u32,
    /// How long it is.
    length: u32,
    /// What it is coloured as.
    kind: TokenKind,
};

/// The most rows `lsp.mappings` holds.
pub const max_mappings = 32;
/// The most servers running or kept in `lsp_servers` at once.
pub const max_servers = 16;
/// The most buffers on servers at once: the rows of `lsp_documents`.
pub const max_documents = 64;

/// A question for a buffer's language server, a row of `commands.lsp`. The host applies the rows
/// after each dispatch and the answer comes in a later frame, as a message to `reply` whose payload
/// is the answer's struct followed by the bytes it says it carries. A buffer on no running server
/// is answered `no_server`; a question whose server errs or ends before answering, `failed`.
pub const CmdPayload = union(enum) {
    /// Asks where the name at byte `offset` of `buffer` is defined; answers `reply` with a
    /// `DefinitionMsg` carrying the path.
    definition: struct { buffer: Atom, offset: u64, reply: sequencer.ReplyTo },
    /// Asks what the name at byte `offset` of `buffer` is; answers `reply` with a `HoverMsg`
    /// carrying the server's description as plain text.
    hover: struct { buffer: Atom, offset: u64, reply: sequencer.ReplyTo },
    /// Asks what could be typed at byte `offset` of `buffer`; answers `reply` with an
    /// `ItemsMsg` carrying a line for each completion: what it is called, what it puts in
    /// the text, and what the server says of it, `item_separator` between them.
    completion: struct { buffer: Atom, offset: u64, reply: sequencer.ReplyTo },
    /// Asks what `buffer` defines; answers `reply` with an `ItemsMsg` carrying a line for
    /// each symbol: its name, its line, its byte column on it, and what kind of thing it is,
    /// `item_separator` between them.
    symbols: struct { buffer: Atom, reply: sequencer.ReplyTo },
};

/// How a question to a server ended.
pub const QueryResult = enum(u8) {
    /// The server answered, and the message carries what it found.
    found,
    /// The server knows nothing there.
    nothing,
    /// The buffer is on no running server.
    no_server,
    /// The server answered with an error, or ended before answering.
    failed,
};

/// The answer to `definition`. When `result` is `found`, `line` and `column` are the line and byte
/// column, both from 0, in the file whose path follows the struct in the payload; otherwise they
/// are 0 and no path follows.
pub const DefinitionMsg = struct { result: QueryResult, line: u32, column: u32 };

/// The answer to `hover`. The server's description follows the struct in the payload as plain text,
/// empty unless `result` is `found`.
pub const HoverMsg = struct { result: QueryResult };

/// The answer to `completion` and `symbols`, carrying `count` lines after it, each an item's
/// fields with `item_separator` between them. Read them with `Items`.
pub const ItemsMsg = extern struct {
    /// How many item lines follow.
    count: u32,
    /// How the question ended; no lines follow unless it is `found`.
    result: QueryResult,
    /// Zero, so the payload's bytes are all the sender's.
    padding: [3]u8 = @splat(0),
};

/// Between the fields of an item's line.
pub const item_separator = '\x1f';
/// The most items an answer carries: the first the server gives.
pub const max_items = 200;
/// The most of an item's field an answer carries.
pub const max_item_field_bytes = 96;

/// Reads the lines that follow an `ItemsMsg`.
pub const Items = struct {
    /// The item lines not yet read.
    lines: std.mem.SplitIterator(u8, .scalar),

    /// A reader over `trailing`, the bytes that follow an `ItemsMsg` in its payload. It borrows
    /// them: the items it gives are slices of the inbox's memory, to copy before the inbox is
    /// cleared.
    pub fn of(trailing: []const u8) Items {
        return .{ .lines = std.mem.splitScalar(u8, trailing, '\n') };
    }

    /// The next item's fields, in the order its request says; a field it lacks is empty.
    pub fn next(items: *Items, fields: [][]const u8) ?[]const []const u8 {
        const line = items.lines.next() orelse return null;
        if (line.len == 0) return null;
        var parts = std.mem.splitScalar(u8, line, item_separator);
        for (fields) |*part| part.* = parts.next() orelse "";
        return fields;
    }
};

/// The table questions for the language servers are pushed to.
pub const commands_table_name = "commands.lsp";
/// `commands.lsp` as a typed command table of `CmdPayload` rows.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the language server system for `wanted`, a row of `commands.lsp`, which the host makes at
/// start. A journaled system that asks declares the table written, so a fault takes its request
/// back.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(wanted);
}

/// The table of what happened in the language servers; see `Event`.
pub const events_table_name = "events.lsp";
/// `events.lsp` as typed numbered rows, which any system reads with a cursor of its own
/// (`sequencer.Events`).
pub const Events = sequencer.Events(Event);

/// What happened that is not state: a row of `events.lsp`.
pub const Event = union(enum) {
    /// What `buffer`'s row addresses changed, its colours or diagnostics; `serial` is the row's
    /// `serial` after the change.
    document_changed: struct { buffer: Atom, serial: u32 },
    /// The state of the server with id `server` changed; read it in `lsp_servers`.
    server_changed: struct { server: u32 },
};

/// The table that says which server a file's extension takes, a `MappingRow` each. Made with the
/// defaults (zls for `.zig` and `.zon`, clice for C and C++); text is read as written, and a
/// mapping is matched by its extension, dot and all. Edits apply to servers started after.
pub const mappings_table_name = "lsp.mappings";
/// A row of `lsp.mappings`.
pub const MappingRow = struct {
    /// As `.zig`.
    extension: []const u8,
    /// The language the server is told the file is in, as `zig`.
    language: []const u8,
    /// The program and its arguments, separated by spaces.
    command: []const u8,
    /// Names of files, separated by spaces, whose folder is a project's root.
    root_markers: []const u8,
};

const default_mappings = [_]struct { extension: []const u8, language: []const u8, command: []const u8, root_markers: []const u8 }{
    .{ .extension = ".zig", .language = "zig", .command = "zls", .root_markers = "build.zig" },
    .{ .extension = ".zon", .language = "zig", .command = "zls", .root_markers = "build.zig" },
    .{ .extension = ".c", .language = "c", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".h", .language = "c", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".cpp", .language = "cpp", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".cc", .language = "cpp", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".cxx", .language = "cpp", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".hpp", .language = "cpp", .command = clice_command, .root_markers = clice_root_markers },
    .{ .extension = ".hh", .language = "cpp", .command = clice_command, .root_markers = clice_root_markers },
};
const clice_command = "clice serve";
/// clice reads its commands from a `compile_commands.json` at the root or one folder below,
/// or from the rules of a `clice.toml`; a checkout with neither is still one project.
const clice_root_markers = "clice.toml compile_commands.json .git";

/// The system's own state, one row; see `StateRow`.
pub const state_table_name = "lsp";
/// The one row of `lsp`.
pub const StateRow = struct {
    /// How many servers the system keeps, whatever their state.
    servers: *u32,
    /// How many buffers are on servers.
    documents: *u32,
    /// How long a buffer is quiet before its text is sent again, in milliseconds.
    quiet_ms: *u32,
};

/// Where a server is in its life, as `ServerRow.state` holds it.
pub const ServerState = enum(u8) {
    /// Its program was spawned and has not yet answered the opening handshake.
    starting,
    /// It answers questions.
    running,
    /// Its program ended.
    exited,
    /// Its program could not be started.
    failed,

    /// The state's name as text, for showing: static memory.
    pub fn name(state: ServerState) []const u8 {
        return @tagName(state);
    }
};

/// The servers started, a `ServerRow` each.
pub const servers_table_name = "lsp_servers";
/// A row of `lsp_servers`.
pub const ServerRow = struct {
    /// The server's id, which `DocumentRow.server` and `Event.server_changed` name. Ids start at 1
    /// and are not used again.
    server: *u32,
    /// The program, as the mapping's command starts. A server takes the files of every
    /// mapping that names its program: clice has C and C++ both.
    program: []const u8,
    /// The project folder it was started in: the nearest folder, from the file's own upward, that
    /// holds one of the mapping's root markers, or the file's folder when none does.
    root: []const u8,
    /// A `ServerState`.
    state: *u8,
    /// Its program's id in the process system; 0 until the program is spawned.
    process: *u32,
};

/// The buffers on a server, a `DocumentRow` each.
pub const documents_table_name = "lsp_documents";
/// A row of `lsp_documents`.
pub const DocumentRow = struct {
    /// The text editor's buffer.
    buffer: *Atom,
    /// The id of the server it is on.
    server: *u32,
    /// Counts the changes to what `view_address` shows.
    serial: *u32,
    /// How many tokens the view holds.
    tokens: *u32,
    /// How many diagnostics the view holds.
    diagnostics: *u32,
    /// A `*const DocumentView`; see the file comment for how long it may be read.
    view_address: *u64,
};

/// How grave a diagnostic is, numbered as the language server protocol numbers them: `error` 1,
/// `warning` 2, `information` 3, `hint` 4. A server may send a number outside these.
pub const Severity = enum(u8) { @"error" = 1, warning = 2, information = 3, hint = 4, _ };

/// A server's diagnostic, from its start to its end, in lines and byte columns of the buffer's
/// text, both from 0.
pub const Diagnostic = extern struct {
    /// The line it starts on.
    start_line: u32,
    /// The byte column it starts at.
    start_column: u32,
    /// The line it ends on.
    end_line: u32,
    /// The byte column it ends before.
    end_column: u32,
    /// How grave it is.
    severity: Severity,
    /// Where its message begins in `DocumentView.messages`; read it with `DocumentView.message`.
    message_start: u32,
    /// Its message's length in bytes.
    message_length: u32,
};

/// What the server last said of a buffer: its tokens, sorted by line and then start, and its
/// diagnostics as the server gave them. The slices are the host's and stable between two
/// applications of the system's commands; see the file comment.
pub const DocumentView = struct {
    /// The buffer's coloured pieces, sorted by line and then start.
    tokens: []const Token = &.{},
    /// The buffer's diagnostics, in the server's order.
    diagnostics: []const Diagnostic = &.{},
    /// The diagnostics' messages, one after another; each diagnostic names its part.
    messages: []const u8 = "",

    /// The text of `diagnostic`'s message: a slice of `messages`, valid as long as the view.
    /// `diagnostic` must be one of this view's.
    pub fn message(view: *const DocumentView, diagnostic: Diagnostic) []const u8 {
        return view.messages[diagnostic.message_start..][0..diagnostic.message_length];
    }

    /// The first token on `line`, or the number of tokens when there is none at or past it.
    pub fn firstTokenOn(view: *const DocumentView, line: u32) usize {
        var low: usize = 0;
        var high: usize = view.tokens.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (view.tokens[middle].line < line) low = middle + 1 else high = middle;
        }
        return low;
    }
};

/// Makes the system's tables, unless they are there: `events.lsp`, `lsp`, `lsp.mappings` (filled
/// with the defaults when it has no rows), `lsp_servers` and `lsp_documents`. The host calls it at
/// start. `scratch` holds the schemas while they are registered.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Events.ensure(scratch, atoms, tables, events_table_name);
    try atoms.tryInternAll(&.{ state_table_name, mappings_table_name, servers_table_name, documents_table_name });

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 3);
    defer state.deinit();
    try state.addFieldFallible("servers", u32, .int);
    try state.addFieldFallible("documents", u32, .int);
    try state.addFieldFallible("quiet_ms", u32, .int);
    _ = try tables.ensureSingleton(&state, Atom.from(state_table_name), .{ .servers = @as(u32, 0), .documents = @as(u32, 0), .quiet_ms = @as(u32, 150) }, .durable);

    var mappings: Table.Schema = undefined;
    try mappings.init(scratch.allocator, atoms, 4);
    defer mappings.deinit();
    try mappings.addFieldFallible("extension", Table.String, .text_field);
    try mappings.addFieldFallible("language", Table.String, .text_field);
    try mappings.addFieldFallible("command", Table.String, .text_field);
    try mappings.addFieldFallible("root_markers", Table.String, .text_field);
    const ensured = try tables.ensure(&mappings, max_mappings, Atom.from(mappings_table_name), .durable);
    if (ensured.table.count() == 0) {
        for (default_mappings) |mapping| _ = try ensured.table.tryInsert(mapping);
    }

    var servers: Table.Schema = undefined;
    try servers.init(scratch.allocator, atoms, 5);
    defer servers.deinit();
    try servers.addFieldFallible("server", u32, .int);
    try servers.addFieldFallible("program", Table.String, .text_field);
    try servers.addFieldFallible("root", Table.String, .text_field);
    try servers.addFieldFallible("state", u8, .int);
    try servers.addFieldFallible("process", u32, .int);
    _ = try tables.ensure(&servers, max_servers, Atom.from(servers_table_name), .durable);

    var documents: Table.Schema = undefined;
    try documents.init(scratch.allocator, atoms, 6);
    defer documents.deinit();
    try documents.addFieldFallible("buffer", Atom, .atom);
    try documents.addFieldFallible("server", u32, .int);
    try documents.addFieldFallible("serial", u32, .int);
    try documents.addFieldFallible("tokens", u32, .int);
    try documents.addFieldFallible("diagnostics", u32, .int);
    try documents.addFieldFallible("view_address", u64, .int);
    _ = try tables.ensure(&documents, max_documents, Atom.from(documents_table_name), .durable);
}

/// The row of `buffer` in `lsp_documents`; null for a buffer on no server.
pub fn documentOf(tables: *Table.Registry, buffer: Atom) ?Table.ReadView(DocumentRow) {
    const documents = tables.findByName(Atom.from(documents_table_name)) orelse return null;
    var rows = documents.readQuery(DocumentRow);
    while (rows.next()) |row| {
        if (row.view.buffer.* == buffer) return row.view;
    }
    return null;
}

/// What the server last said of `buffer`, to read until the system next applies commands; null for
/// a buffer on no server or one the server has said nothing of.
pub fn viewOf(tables: *Table.Registry, buffer: Atom) ?*const DocumentView {
    const row = documentOf(tables, buffer) orelse return null;
    if (row.view_address.* == 0) return null;
    return @ptrFromInt(row.view_address.*);
}

/// The row of server `server` in `lsp_servers`; null when there is none.
pub fn serverOf(tables: *Table.Registry, server: u32) ?Table.ReadView(ServerRow) {
    const servers = tables.findByName(Atom.from(servers_table_name)) orelse return null;
    var rows = servers.readQuery(ServerRow);
    while (rows.next()) |row| {
        if (row.view.server.* == server) return row.view;
    }
    return null;
}

/// What a reader of buffers' documents and their servers declares: reads of `lsp_documents` and
/// `lsp_servers`, each only once it exists.
pub fn declareReading(access: *sequencer.Access, tables: *Table.Registry) void {
    for ([_]Atom{ Atom.from(documents_table_name), Atom.from(servers_table_name) }) |name| {
        if (tables.findByName(name) != null) access.read(name);
    }
}

/// The system's one row, `lsp`, to read and write; null before `ensureTables`.
pub fn stateRow(tables: *Table.Registry) ?StateRow {
    const found = tables.findByName(Atom.from(state_table_name)) orelse return null;
    return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, StateRow);
}
