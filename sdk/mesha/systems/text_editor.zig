//! The text editor system's contract: buffers of UTF-8 text, named by atom, driven by commands. The
//! system draws nothing and measures nothing. Its user lays the text out, draws it, and turns keys
//! and clicks into commands; what a command did is read back from tables. The runtime is
//! `runtime/text_editor.zig`; the editor's text panels and one-line fields are its users.
//!
//! - `commands.text_editor` takes the requests (`CmdPayload`, `request`), which the host applies in
//!   order right after each dispatch.
//! - `text_editor` is the system's own state, one row (`StateRow`).
//! - `text_editor_buffers` lists the open buffers and the table each keeps its state in
//!   (`BufferEntry`).
//! - Each open buffer has a table of its own, one row (`BufferRow`): where its caret is, whether it
//!   is modified, how long it is, and the address of its `View`.
//! - `text_editor_recent` lists the files opened lately (`RecentRow`).
//! - `text_editor_projects` lists the projects, directories a person opened, remembered (`ProjectRow`).
//! - `events.text_editor` tells what happened (`Event`): a buffer changed, was copied from, wants a
//!   paste, opened or closed.
//!
//! A buffer's text is never copied into a table. Its user reads it through the buffer's `View`
//! (`viewOf`), which the system rewrites only while it applies commands. Between two applications,
//! which is the whole of any other system's run and of drawing, a view and the slices it gives are
//! stable. The address is read from the buffer's table each time and never kept: a closed buffer's
//! table is gone, and its view with it.
//!
//! Each buffer lives in a memory scope of its own, closed with it: its text, line index and history
//! on the scope's pages, its table placed in the scope.
//!
//! A buffer may hold a file. The host reads and writes the file on the frame's thread, as the
//! command asks: a large file is a hitch, once, when it opens. Its text is UTF-8 in the buffer
//! whatever the file's encoding, which is remembered with its byte order mark and written back on a
//! save.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");
/// The text as its readers see it, and the enums commands name (`text_editor/buffer.zig`).
pub const buffer_mod = @import("text_editor/buffer.zig");
/// Encodings' names, byte order marks and line endings (`text_editor/encoding.zig`).
pub const encoding = @import("text_editor/encoding.zig");

const Allocator = std.mem.Allocator;

/// What a buffer can be told to do by `run`; see `buffer_mod.EditCommand`.
pub const EditCommand = buffer_mod.EditCommand;
/// A buffer's text as its readers see it; see `buffer_mod.View`.
pub const View = buffer_mod.View;
/// Whether a buffer holds one line or many; see `buffer_mod.LineMode`.
pub const LineMode = buffer_mod.LineMode;
/// What a caret move does to the selection; see `buffer_mod.Select`.
pub const Select = buffer_mod.Select;
/// A unit a click can select; see `buffer_mod.Unit`.
pub const Unit = buffer_mod.Unit;
/// How far a zap kills; see `buffer_mod.Zap`.
pub const Zap = buffer_mod.Zap;
/// Whether an edit is an undo step of its own; see `buffer_mod.UndoStep`.
pub const UndoStep = buffer_mod.UndoStep;
/// How many markers a buffer keeps; see `buffer_mod.marker_count`.
pub const marker_count = buffer_mod.marker_count;
/// A node of a buffer's undo history; see `buffer_mod.HistoryNode`.
pub const HistoryNode = buffer_mod.HistoryNode;
/// The ending a new line gets; see `buffer_mod.LineEnding`.
pub const LineEnding = buffer_mod.LineEnding;
/// How a text's lines end; see `encoding.LineEndings`.
pub const LineEndings = encoding.LineEndings;
/// A file's byte order mark; see `encoding.Bom`.
pub const Bom = encoding.Bom;

/// How many buffers can be open at once: the fields that edit text and the files.
pub const max_buffers = 64;

/// A request to the text editor, a row of `commands.text_editor`. Offsets are bytes of the buffer's
/// text, and lines and cells count from 0. A request naming a buffer that is not open does nothing,
/// unless its own comment says otherwise. Slices are copied into the command table, so they need
/// last only until `request` returns.
pub const CmdPayload = union(enum) {
    /// Opens the file at `path` in a buffer of its own, or finds the buffer that already
    /// holds it, and answers `reply` with an `OpenedMsg`.
    open: struct { path: []const u8, reply: sequencer.ReplyTo },
    /// Writes the buffer to `path`, or to the file it holds when `path` is empty, and
    /// answers `reply` with a `SavedMsg`. A buffer saved to a path holds that file after.
    save: struct { buffer: Atom, path: []const u8, reply: sequencer.ReplyTo },
    /// The encoding the buffer is saved in from now on, by its iconv name. The text in the
    /// buffer does not change; one this platform cannot convert to is refused and logged.
    set_encoding: struct { buffer: Atom, encoding: []const u8 },
    /// Reads the buffer's file again as text in `encoding`, by its iconv name, whatever its
    /// bytes suggest: the text is replaced, saved, and its history forgotten, and the buffer
    /// is saved in that encoding after. A file that is not text in it, or a buffer with no
    /// file, leaves the buffer as it was; the person is told why in `*Messages*`.
    revert: struct { buffer: Atom, encoding: []const u8 },
    /// The ending new lines get from now on; `convert` also rewrites every ending the text
    /// has, which forgets its history.
    set_line_ending: struct { buffer: Atom, ending: LineEnding, existing: ExistingEndings },
    /// Opens an empty buffer. One already open is left as it is. A buffer with a `name` is
    /// one a person switches to, as `*scratch*`; a field's has none.
    create: struct { buffer: Atom, lines: LineMode, name: []const u8 = "", access: Access = .edit },
    /// Closes the buffer and frees its text. Its table goes with it.
    close: Atom,
    /// Replaces the text, clears its history, and marks it saved. A buffer not yet open
    /// opens as a single-line one.
    set_text: struct { buffer: Atom, text: []const u8 },
    /// Adds text after the buffer's last byte, whatever its `Access`: the text stays saved,
    /// its history is forgotten, and a caret at the end follows it.
    append: struct { buffer: Atom, utf8: []const u8 },
    /// Tells the person something: a line added to `*Messages*`, which is opened if it is
    /// not open.
    message: []const u8,
    /// Adds a line to a buffer that is a log of its own, as `*Messages*` is: one only read,
    /// called `name`, opened if it is not open, which forgets its oldest lines.
    tell: struct { buffer: Atom, name: []const u8, line: []const u8 },
    /// Typed characters, over the selection if there is one: `count` times over, as a
    /// count before a key types its character again and again.
    insert: struct { buffer: Atom, utf8: []const u8, count: u32 = 1 },
    /// Pastes `utf8` over the selection, as one undo step: the answer to a `paste_wanted`.
    paste: struct { buffer: Atom, utf8: []const u8 },
    /// Runs `command` as the buffer's keys would, `count` times.
    run: struct { buffer: Atom, command: EditCommand, count: u32 = 1 },
    /// Kills from the caret to the next `utf8` after it: up to it, or through it.
    zap: struct { buffer: Atom, utf8: []const u8, reach: Zap },
    /// Puts the caret at a line and cell, as a click there does; `extend` leaves the
    /// selection's other end where it was.
    set_caret: struct { buffer: Atom, line: u32, column: u32, select: Select },
    /// Puts `utf8` on each line in place of the selection's rectangle, the cells between its
    /// ends' columns: Emacs's `string-rectangle`.
    string_rectangle: struct { buffer: Atom, utf8: []const u8 },
    /// Puts `utf8` where the `len` bytes at `start` were, the caret after it: one replacement
    /// of a search and replace, an undo step of its own or part of the one before.
    replace_range: struct { buffer: Atom, start: u32, len: u32, utf8: []const u8, step: UndoStep },
    /// Puts `utf8` in place of each `needle` wholly between `start` and `end`, as one undo
    /// step or part of the one before.
    replace_all: struct { buffer: Atom, needle: []const u8, utf8: []const u8, start: u32, end: u32, step: UndoStep },
    /// Puts the text in the state `node` of its history names (`View.history`), by the undos
    /// and redos that lead there: where a walk through the history is given up.
    history_goto: struct { buffer: Atom, node: u32 },
    /// Puts one of the buffer's `marker_count` markers at a byte offset, where it stays in
    /// its text through the edits after: a window keeps its point so while the caret is
    /// another's. Read back from the `View`.
    set_marker: struct { buffer: Atom, marker: u8, offset: u32 },
    /// Selects from `anchor` to `caret`, byte offsets in the text, as a search selects what
    /// it found; equal, they only place the caret. No mark is set.
    select_range: struct { buffer: Atom, anchor: u32, caret: u32 },
    /// Selects the word or the line at a line and cell, as a double or triple click does.
    select_unit: struct { buffer: Atom, line: u32, column: u32, unit: Unit },
    /// What the buffer cannot know of how it is shown: the lines a page move travels and
    /// the cells a tab runs to.
    set_layout: struct { buffer: Atom, page_lines: u32, tab_width: u8 },
    /// Marks the text as it is now as saved. A `changed` event follows whether or not
    /// anything changed, so a user waiting for the buffer's last text hears of it.
    mark_saved: Atom,
    /// Switches the buffer between being edited and being only read, as Emacs's `C-x C-q`,
    /// and tells which it is now.
    toggle_read_only: Atom,
    /// Switches whether a word in the buffer also ends where its capitals part it
    /// (`GtkWindow`), as Emacs's subword mode, and tells which it is now.
    toggle_subword: Atom,
    /// Lists the directory at `path`, relative to the working directory or absolute, the
    /// working directory when it is empty, and answers `reply` with a `ListedMsg`, which names
    /// the directory by its real, absolute path: what a user typing a path to open can choose
    /// from.
    list_directory: struct { path: []const u8, reply: sequencer.ReplyTo },
    /// Keeps what outlasts a session in the directory at this path from now on, relative to
    /// the working directory or absolute, and made absolute when the command is applied, so
    /// the working directory changing later does not move it: the list of files opened
    /// lately, in `recent_files` there, and the projects remembered, in `projects` there, each
    /// read now and put after this session's, and each file as it was before the session
    /// first writes over it, in `backups/` there. The directory
    /// is made when something is first kept. Until a plugin asks, as the person's own does,
    /// nothing is kept, and the host looks nowhere of its own; an empty path keeps nothing
    /// again. The slice is copied.
    keep_in: []const u8,
    /// Puts the directory at this path first in the projects remembered (`text_editor_projects`),
    /// made absolute when the command is applied and without a trailing `/` but a root's, so one
    /// directory has one spelling; an empty path names none and does nothing. A directory already
    /// listed moves first; the list holds at most
    /// `max_projects`, the oldest dropped. Kept, a path a line, in `projects` in the directory
    /// `keep_in` names, if one was asked. The directory is not looked at, so one that is gone
    /// stays listed until it is forgotten. The slice is copied.
    remember_project: []const u8,
    /// Drops the directory at this path, spelled as `remember_project` spells it, from the
    /// projects remembered. A directory that is not listed, or an empty path, changes nothing.
    /// The slice is copied.
    forget_project: []const u8,
    /// Asks whether the host converts the encoding `name` and UTF-8, both ways, or with an
    /// empty `name` each of `known_encodings`; answers `reply` with an `EncodingsMsg`. What a
    /// user offering encodings asks once at its start, and again for a name typed.
    supported_encodings: struct { name: []const u8, reply: sequencer.ReplyTo },
};

/// What `set_line_ending` does to the endings the text already has: `keep` them, or `convert` each
/// to the ending asked for.
pub const ExistingEndings = enum(u8) { keep, convert };

/// What typing and editing commands may do to a buffer's text.
pub const Access = enum(u8) {
    /// Typing and every command apply.
    edit,
    /// The text changes only by `set_text` and `append`: typing and edits are dropped.
    read_only,
};

/// Where the person is told things: warnings and errors from the log, and what the editor
/// says (`message`). It is only read, and forgets its oldest lines.
pub const messages_name = "*Messages*";
/// The `*Messages*` buffer's id.
pub const messages_buffer = Atom.from(messages_name);
/// The buffer mesha starts with: text that is no file's.
pub const scratch_name = "*scratch*";
/// The `*scratch*` buffer's id.
pub const scratch_buffer = Atom.from(scratch_name);

/// Tells the person `text`, a line of `*Messages*`.
pub fn message(memory: *memory_mod.Memory, tables: *Table.Registry, text: []const u8) void {
    request(memory, tables, .{ .message = text });
}

/// Asks for the buffers mesha starts with: `*Messages*` and `*scratch*`.
pub fn requestStartingBuffers(memory: *memory_mod.Memory, tables: *Table.Registry) void {
    request(memory, tables, .{ .create = .{ .buffer = messages_buffer, .lines = .multi, .name = messages_name, .access = .read_only } });
    request(memory, tables, .{ .create = .{ .buffer = scratch_buffer, .lines = .multi, .name = scratch_name } });
}

/// The encodings iconv names, the commonest first; `supported_encodings` asks which of them
/// the host converts.
pub const known_encodings = encoding.known_names;
/// The longest name an encoding may have.
pub const max_encoding_name = encoding.max_encoding_name;

/// How an `open` ended.
pub const OpenResult = enum(u8) {
    /// The file was read into a buffer of its own.
    opened,
    /// A buffer already held the file; it is left as it is.
    already_open,
    /// There is no file at the path.
    not_found,
    /// Larger than `max_file_bytes`.
    too_large,
    /// Not text: it holds NUL bytes and no mark says it is UTF-16 or UTF-32.
    binary,
    /// The file could not be read.
    read_failed,
    /// Its bytes are not text in the encoding its mark names, or in any fallback.
    convert_failed,
    /// `max_buffers` buffers are open.
    too_many_buffers,
    /// There was no memory for the buffer.
    out_of_memory,
};

/// The answer to `open`. `buffer` names the buffer when `result` is `opened` or
/// `already_open`.
pub const OpenedMsg = struct { buffer: Atom, result: OpenResult };

/// How a `save` ended.
pub const SaveResult = enum(u8) {
    /// The file was written and the buffer is marked saved.
    saved,
    /// No buffer of that id is open.
    not_open,
    /// The buffer holds no file and the request named none.
    no_path,
    /// The file could not be written.
    write_failed,
    /// The text has a character its encoding cannot hold. The file was not touched.
    convert_failed,
    /// There was no memory to convert or write the text.
    out_of_memory,
};

/// The answer to `save`.
pub const SavedMsg = struct { buffer: Atom, result: SaveResult };

/// How a `list_directory` ended.
pub const ListResult = enum(u8) {
    /// The directory's path and entries follow the message.
    listed,
    /// There is nothing at the path.
    not_found,
    /// The path leads to something other than a directory.
    not_a_directory,
    /// The directory could not be read.
    read_failed,
    /// There was no memory for the listing.
    out_of_memory,
};

/// What a listed entry is: a `file` or a `directory`.
pub const ListedKind = enum(u8) { file, directory };

/// The answer to `list_directory`. The directory's real path follows it, `directory_len`
/// bytes with `/` separators, and then its `entry_count` entries, sorted by name, each its
/// `ListedKind` as a byte, its name and a 0. `ListedEntries` reads them. A link is listed
/// as what it leads to.
pub const ListedMsg = extern struct {
    /// The length in bytes of the directory's path, which follows the struct.
    directory_len: u32,
    /// How many entries follow the path.
    entry_count: u32,
    /// How the listing ended; nothing follows unless it is `listed`.
    result: ListResult,
    /// Zero, so the payload's bytes are all the sender's.
    padding: [3]u8 = @splat(0),
};

/// One entry of a listed directory: what it is and its name, without the directory. `name` is a
/// slice of the message's payload.
pub const ListedEntry = struct { kind: ListedKind, name: []const u8 };

/// Reads the entries that follow a `ListedMsg` and its directory.
pub const ListedEntries = struct {
    /// The entries not yet read: the payload's bytes after the `ListedMsg` and its directory's
    /// path.
    remaining: []const u8,

    /// The next entry, or null after the last or at bytes that are not an entry.
    pub fn next(entries: *ListedEntries) ?ListedEntry {
        if (entries.remaining.len < 2) return null;
        const kind = std.enums.fromInt(ListedKind, entries.remaining[0]) orelse return null;
        const name_end = std.mem.indexOfScalarPos(u8, entries.remaining, 1, 0) orelse return null;
        const name = entries.remaining[1..name_end];
        entries.remaining = entries.remaining[name_end + 1 ..];
        return .{ .kind = kind, .name = name };
    }
};

/// The answer to `supported_encodings`. Its `count` answers follow it, one for each name
/// asked, in the order asked: a byte, 1 when the host converts the encoding and 0 when not,
/// the name, and a 0. `EncodingAnswers` reads them. A name no encoding can have
/// (`encoding.isEncodingName`: longer than `max_encoding_name`, or with a byte below a space)
/// is answered as not converted under an empty name, so no answer names an encoding other
/// than the one asked about.
pub const EncodingsMsg = extern struct { count: u32 };

/// One answer of an `EncodingsMsg`: an encoding's name and whether the host converts it. `name` is
/// a slice of the message's payload.
pub const EncodingAnswer = struct { name: []const u8, supported: bool };

/// Reads the answers that follow an `EncodingsMsg`.
pub const EncodingAnswers = struct {
    /// The answers not yet read: the payload's bytes after the `EncodingsMsg`.
    remaining: []const u8,

    /// The next answer, or null after the last or at bytes that are not an answer.
    pub fn next(answers: *EncodingAnswers) ?EncodingAnswer {
        if (answers.remaining.len < 2) return null;
        const supported = answers.remaining[0] != 0;
        const name_end = std.mem.indexOfScalarPos(u8, answers.remaining, 1, 0) orelse return null;
        const name = answers.remaining[1..name_end];
        answers.remaining = answers.remaining[name_end + 1 ..];
        return .{ .name = name, .supported = supported };
    }
};

/// Requests to the buffers, a row each, applied in order right after each dispatch. Text they
/// carry is copied into the table's arena until then.
pub const commands_table_name = "commands.text_editor";
/// `commands.text_editor` as a typed command table of `CmdPayload` rows.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the text editor for `wanted`, a row of `commands.text_editor`, which the host makes at
/// start. A journaled system that asks declares the table written, so a fault takes its request
/// back.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(wanted);
}

/// What happened in the buffers, a row each, which any system reads with a cursor of its own
/// (`sequencer.Events`). What an event is about is in the buffer's table.
pub const events_table_name = "events.text_editor";
/// `events.text_editor` as typed numbered rows (`sequencer.Events`).
pub const Events = sequencer.Events(Event);

/// What happened in a buffer that is not state: a row of `events.text_editor`.
pub const Event = union(enum) {
    /// The buffer opened.
    opened: struct { buffer: Atom },
    /// The buffer closed: its table is gone, and its view with it.
    closed: struct { buffer: Atom },
    /// The buffer's text, caret or selection changed, or it was marked saved.
    changed: struct {
        /// The buffer that changed.
        buffer: Atom,
        /// Counts the changes to the text alone.
        revision: u32,
        /// Counts everything a view of the buffer shows: text, caret and selection.
        serial: u32,
        /// Whether the text differs from what was last marked saved.
        modified: bool,
        /// Whether this change is the buffer's text written to its file by a `save`: what a
        /// system that shows the state of the files on disk (a version-control panel) reads to
        /// look again. False for a buffer only marked saved (`mark_saved`), which wrote nothing.
        saved: bool = false,
    },
    /// Text was copied or cut in the buffer: `copiedText` has it, for the clipboard. The
    /// buffers keep no clipboard of their own.
    copied: struct { buffer: Atom },
    /// A paste was asked for in the buffer; the answer is `paste`.
    paste_wanted: struct { buffer: Atom },
};

/// The system's own state, one row.
pub const state_table_name = "text_editor";
/// The one row of `text_editor`.
pub const StateRow = struct {
    /// How many buffers are open.
    open_buffers: *u32,
    /// A file larger than this is refused.
    max_file_bytes: *u64,
    /// A buffer's history forgets its oldest edits once their bytes pass this.
    undo_limit_bytes: *u64,
    /// The text last copied in any buffer: valid until the next commands are applied.
    copied_address: *u64,
    /// The length of the text at `copied_address`; read both with `copiedText`.
    copied_bytes: *u64,
};

/// The open buffers, a row each.
pub const buffers_table_name = "text_editor_buffers";
/// A row of `text_editor_buffers`.
pub const BufferEntry = struct {
    /// The buffer's id.
    buffer: *Atom,
    /// The name of the table the buffer keeps its state in.
    table: *Atom,
    /// The file the buffer holds, by its absolute path with `/` separators: its real path when
    /// the file was there when opened or saved. Empty for a buffer that holds none.
    path: []const u8,
    /// What a buffer that holds no file is called, as `*scratch*`. Empty for a file's buffer
    /// and for a field's, which nobody switches to.
    name: []const u8,
};

/// The files opened lately, the latest first, a row each: what a person picks one to open
/// again from. Kept between sessions only where a plugin asked (`CmdPayload.keep_in`).
pub const recent_table_name = "text_editor_recent";
/// A row of `text_editor_recent`.
pub const RecentRow = struct {
    /// The file's whole path.
    path: []const u8,
};
/// How many files the list remembers.
pub const max_recent_files = 100;

/// The projects remembered, the latest first, a row each: the directories a person opened, which
/// a person picks one of to open again. Kept between sessions only where a plugin asked
/// (`CmdPayload.keep_in`).
pub const projects_table_name = "text_editor_projects";
/// A row of `text_editor_projects`.
pub const ProjectRow = struct {
    /// The project's directory: absolute, `/`-separated, with no trailing `/` unless it is a root
    /// (`/`, `C:/`, `//server/`).
    path: []const u8,
};
/// How many projects the list remembers.
pub const max_projects = 50;

/// The one row of a buffer's own table.
pub const BufferRow = struct {
    /// The buffer's id.
    buffer: *Atom,
    /// Counts everything a view of the buffer shows; see `Event.changed`.
    serial: *u32,
    /// Counts the changes to the text alone.
    revision: *u32,
    /// 1 when the text differs from what was last marked saved, else 0.
    modified: *u8,
    /// The text's length in bytes.
    bytes: *u64,
    /// How many lines the text has.
    lines: *u32,
    /// The caret and the selection's other end, as byte offsets; equal with no selection.
    caret: *u64,
    /// The selection's other end; see `caret`.
    anchor: *u64,
    /// The line the caret is on, from 0.
    caret_line: *u32,
    /// The caret's cell on its line, tabs run out to their stops.
    caret_column: *u32,
    /// A `*const View`; see the file comment for how long it may be read.
    view_address: *u64,
    /// The file the buffer holds, by its absolute path, as in `BufferEntry`; empty for none.
    path: []const u8,
    /// The encoding a save writes, by its iconv name.
    encoding: []const u8,
    /// A `Bom`: the byte order mark a save writes first.
    bom: *u8,
    /// A `LineEndings`: how the file's lines ended when it was read, or were last set.
    line_endings: *u8,
    /// As `BufferEntry.name`.
    name: []const u8,
    /// An `Access`.
    access: *u8,
};

/// The named schema every buffer's own table has: the columns of `BufferRow`.
pub const buffer_schema_name = "text_editor_buffer";

/// The names buffers' tables take, `text_editor_buffer_00` to `text_editor_buffer_63`: an open
/// buffer has one of them, by its slot.
pub const buffer_table_names: [max_buffers][]const u8 = blk: {
    var names: [max_buffers][]const u8 = undefined;
    for (&names, 0..) |*name, slot| name.* = std.fmt.comptimePrint("text_editor_buffer_{d:0>2}", .{slot});
    break :blk names;
};

/// A buffer's table and its memory scope share a name: one of these, by its slot.
pub const buffer_table_atoms: [max_buffers]Atom = blk: {
    var atoms: [max_buffers]Atom = undefined;
    for (&atoms, buffer_table_names) |*atom, name| atom.* = Atom.from(name);
    break :blk atoms;
};

/// Makes the system's tables, unless they are there: `events.text_editor`, `text_editor` with its
/// defaults (files up to 2 GiB, 64 MiB of undo history a buffer), `text_editor_buffers` and
/// `text_editor_recent`, `text_editor_projects`, and registers the schema of the buffers' own tables. The host calls it at
/// start. `scratch` holds the schemas while they are registered.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Events.ensure(scratch, atoms, tables, events_table_name);
    try atoms.tryInternAll(&.{ state_table_name, buffers_table_name, buffer_schema_name, messages_name, scratch_name, recent_table_name, projects_table_name });

    var recent: Table.Schema = undefined;
    try recent.init(scratch.allocator, atoms, 1);
    defer recent.deinit();
    try recent.addFieldFallible("path", Table.String, .text_field);
    _ = try tables.ensure(&recent, max_recent_files, Atom.from(recent_table_name), .durable);

    var projects: Table.Schema = undefined;
    try projects.init(scratch.allocator, atoms, 1);
    defer projects.deinit();
    try projects.addFieldFallible("path", Table.String, .text_field);
    _ = try tables.ensure(&projects, max_projects, Atom.from(projects_table_name), .durable);
    try atoms.tryInternAll(&buffer_table_names);

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 5);
    defer state.deinit();
    try state.addFieldFallible("open_buffers", u32, .int);
    try state.addFieldFallible("max_file_bytes", u64, .int);
    try state.addFieldFallible("undo_limit_bytes", u64, .int);
    try state.addFieldFallible("copied_address", u64, .int);
    try state.addFieldFallible("copied_bytes", u64, .int);
    const defaults = .{
        .open_buffers = @as(u32, 0),
        .max_file_bytes = @as(u64, 2 * 1024 * 1024 * 1024),
        .undo_limit_bytes = @as(u64, 64 * 1024 * 1024),
        .copied_address = @as(u64, 0),
        .copied_bytes = @as(u64, 0),
    };
    _ = try tables.ensureSingleton(&state, Atom.from(state_table_name), defaults, .durable);

    var entries: Table.Schema = undefined;
    try entries.init(scratch.allocator, atoms, 4);
    defer entries.deinit();
    try entries.addFieldFallible("buffer", Atom, .atom);
    try entries.addFieldFallible("table", Atom, .atom);
    try entries.addFieldFallible("path", Table.String, .text_field);
    try entries.addFieldFallible("name", Table.String, .text_field);
    _ = try tables.ensure(&entries, max_buffers, Atom.from(buffers_table_name), .durable);

    if (tables.schemas.get(Atom.from(buffer_schema_name)) != null) return;
    var buffer: Table.Schema = undefined;
    try buffer.init(scratch.allocator, atoms, 17);
    defer buffer.deinit();
    try buffer.addFieldFallible("buffer", Atom, .atom);
    try buffer.addFieldFallible("serial", u32, .int);
    try buffer.addFieldFallible("revision", u32, .int);
    try buffer.addFieldFallible("modified", u8, .int);
    try buffer.addFieldFallible("bytes", u64, .int);
    try buffer.addFieldFallible("lines", u32, .int);
    try buffer.addFieldFallible("caret", u64, .int);
    try buffer.addFieldFallible("anchor", u64, .int);
    try buffer.addFieldFallible("caret_line", u32, .int);
    try buffer.addFieldFallible("caret_column", u32, .int);
    try buffer.addFieldFallible("view_address", u64, .int);
    try buffer.addFieldFallible("path", Table.String, .text_field);
    try buffer.addFieldFallible("encoding", Table.String, .text_field);
    try buffer.addFieldFallible("bom", u8, .int);
    try buffer.addFieldFallible("line_endings", u8, .int);
    try buffer.addFieldFallible("name", Table.String, .text_field);
    try buffer.addFieldFallible("access", u8, .int);
    try tables.registerSchema(Atom.from(buffer_schema_name), &buffer);
}

/// The system's one row, `text_editor`, to read and write; null before `ensureTables`.
pub fn stateRow(tables: *Table.Registry) ?StateRow {
    const found = tables.findByName(Atom.from(state_table_name)) orelse return null;
    return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, StateRow);
}

/// The table `buffer` keeps its state in; null for a buffer not open.
pub fn tableOf(tables: *Table.Registry, buffer: Atom) ?*Table {
    const entries = tables.findByName(Atom.from(buffers_table_name)) orelse return null;
    var rows = entries.readQuery(BufferEntry);
    while (rows.next()) |row| {
        if (row.view.buffer.* == buffer) return tables.findByName(row.view.table.*);
    }
    return null;
}

/// The row of `buffer`'s own table; null for a buffer not open.
pub fn rowOf(tables: *Table.Registry, buffer: Atom) ?Table.ReadView(BufferRow) {
    const found = tableOf(tables, buffer) orelse return null;
    var rows = found.readQuery(BufferRow);
    const row = rows.next() orelse return null;
    return row.view;
}

/// `buffer`'s text, to read until the next commands are applied; null for a buffer not open.
pub fn viewOf(tables: *Table.Registry, buffer: Atom) ?*const View {
    const row = rowOf(tables, buffer) orelse return null;
    if (row.view_address.* == 0) return null;
    return @ptrFromInt(row.view_address.*);
}

/// What a reader of `buffer` declares: the list of buffers and the buffer's own table.
pub fn declareBuffer(access: *sequencer.Access, tables: *Table.Registry, buffer: Atom) void {
    const entries_name = Atom.from(buffers_table_name);
    const entries = tables.findByName(entries_name) orelse return;
    access.read(entries_name);
    var rows = entries.readQuery(BufferEntry);
    while (rows.next()) |row| {
        if (row.view.buffer.* == buffer) access.read(row.view.table.*);
    }
}

/// The text last copied or cut in any buffer, to read until the next commands are applied.
pub fn copiedText(tables: *Table.Registry) []const u8 {
    const state = stateRow(tables) orelse return "";
    if (state.copied_address.* == 0) return "";
    const bytes: [*]const u8 = @ptrFromInt(state.copied_address.*);
    return bytes[0..state.copied_bytes.*];
}

/// The buffer holding the file at `path`, which is given as `BufferEntry.path` has it; null when no
/// open buffer holds it.
pub fn bufferOfPath(tables: *Table.Registry, path: []const u8) ?Atom {
    const entries = tables.findByName(Atom.from(buffers_table_name)) orelse return null;
    var rows = entries.readQuery(BufferEntry);
    while (rows.next()) |row| {
        if (row.view.path.len != 0 and std.mem.eql(u8, row.view.path, path)) return row.view.buffer.*;
    }
    return null;
}
