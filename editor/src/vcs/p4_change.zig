//! vcs-p4's description buffer: where a changelist's description is written before it is
//! submitted (`s`), edited (`e`) or made (`N`). A part of vcs-p4's system (`p4_status.zig`): the
//! changelist being described is this file's table, while the jobs, how their ends refresh and
//! what is told are the system's (`p4_status.Work`).
//!
//! - The buffer `*vcs-p4: description*` shows in the other text window, which takes the focus,
//!   holding the changelist's description as the panel lists it (empty for the default
//!   changelist and a new one); its windows have the major mode `vcs_p4_message` under `buffer`:
//!   `C-c C-c` sends it, `C-c C-k` or `C-x k` give it up. It stays until `p4` accepts what it
//!   sends: a command that fails keeps it and its text for another `C-c C-c`.
//! - The description never goes in an argument: it is written into the changelist's form
//!   (`p4.writeChangeForm`), which goes on the job's input. Each step runs only once the one
//!   before succeeded:
//!   - `N`: `change -o` (a new changelist's form), the description written in it with its
//!     `Files:` left out (`FormFiles.drop`), so the new changelist is made empty and the default
//!     changelist keeps its files; then `change -i`. Two programs.
//!   - `e`: `change -o N`, the description written in it, its `Files:` kept; then `change -i`.
//!     Two programs.
//!   - `s` keeps what it shows: the changelist's files (sorted depot path, action and resolve
//!     state, `p4_status.submitFingerprint`), told as the buffer opens. `C-c C-c` first refreshes
//!     the changelists (`verifying`; a refresh already running ends and the NEXT one is used),
//!     and goes on only when that refresh read the lists, no other command of the panel's waits
//!     or runs, the changelist is still listed and its files are exactly those kept; else it is
//!     told and nothing runs. Then, on a numbered changelist: `submit -c N`, after `change -o N`
//!     (its `Files:` checked against those kept) and `change -i` when the description changed.
//!     On the default changelist: `change -o` (`Change: new`, its `Files:` the default
//!     changelist's, checked against those kept, and kept, so the whole changelist is
//!     submitted), the description written in it, then `submit -i` with the form on its input
//!     (`p4.Submit.default`).
//!   - A default changelist's submit that fails, or is given up while it runs, may or may not
//!     have left a numbered changelist: the panel lists the changelists again, `C-c C-c` refuses
//!     the same form, and `s` begins anew: on the changelist holding exactly that submit's
//!     files (the numbered one the server left, `submit -c N`, or the default one again) the
//!     buffer holds what was typed; on the default changelist holding other files it holds it
//!     too, said to be typed for other files; any other changelist begins from its own
//!     description, what was typed said to be dropped.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const keybinds = mesha.keybinds;
const text_editor = plugin.text_editor_api;
const p4 = @import("p4.zig");
const status = @import("p4_status.zig");
const text_panel = @import("../text_panel.zig");
const shared = @import("../text_editor.zig");
const modes = @import("../modes.zig");

// ---- the messages, the actions and their keys ----------------------------------------------------

/// What the system takes for the description buffer.
pub const Msg = enum(u64) {
    /// `C-c C-c`: sends the description.
    vcs_p4_message_finish = Atom.from("vcs_p4_message_finish").value(),
    /// `C-c C-k`: gives it up.
    vcs_p4_message_cancel = Atom.from("vcs_p4_message_cancel").value(),
    _,
};

/// Whether `tag` is one of `Msg`'s.
pub fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// The actions of mode `vcs_p4_message`.
pub const message_actions = [_]plugin.action_api.Def{
    .{ .name = "finish", .tag = @tagName(Msg.vcs_p4_message_finish), .doc = "Send this description: submit, save or make the changelist" },
    .{ .name = "cancel", .tag = @tagName(Msg.vcs_p4_message_cancel), .doc = "Give up the description" },
};

/// The keys of mode `vcs_p4_message`, over `buffer`'s.
pub const message_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-c C-c", .action = .{ "vcs_p4_message", "finish" } },
    .{ .chord = "C-c C-k", .action = .{ "vcs_p4_message", "cancel" } },
    // Killing the buffer would lose the text: it gives the description up.
    .{ .chord = "C-x k", .action = .{ "vcs_p4_message", "cancel" } },
};

/// Offers the actions of mode `vcs_p4_message`, `inbox` taking them.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, inbox: Atom) void {
    for (message_actions) |def| keybinds.pushActionDefinitions(atoms, sink, modes.vcs_p4_message, inbox, &.{.{ .def = def }});
}

// ---- the table -----------------------------------------------------------------------------------

/// `editor_vcs_p4_change`: the changelist being described, one row (`ChangeRow`).
pub const change_table_name = "editor_vcs_p4_change";

/// The buffer a description is written in.
pub const message_name = "*vcs-p4: description*";
/// The buffer's id.
pub const message_buffer = Atom.from(message_name);

/// What the description is for.
pub const Purpose = enum(u8) {
    /// `s`: the changelist submitted.
    submit,
    /// `e`: the changelist's description saved.
    describe,
    /// `N`: a new changelist made.
    new_change,
};

/// How far the description has got.
pub const Phase = enum(u8) {
    /// None is being written.
    none,
    /// The buffer is shown for it to be written.
    editing,
    /// Sent for a submit: the changelists are read again first, so what is submitted is
    /// checked against what the panel showed as `s` was pressed (`refreshEnded`).
    verifying,
    /// `change -o` runs, for the form the description is written into.
    form_asked,
    /// `change -i` runs.
    saving,
    /// `submit` runs.
    submitting,

    fn runs(phase: Phase) bool {
        return phase == .verifying or phase == .form_asked or phase == .saving or phase == .submitting;
    }
};

/// The row of `editor_vcs_p4_change`.
pub const ChangeRow = struct {
    /// A `Phase`.
    phase: *u8,
    /// A `Purpose`.
    purpose: *u8,
    /// The changelist, as the tables write it: `default` or its number; empty for a new one.
    change: *Table.String,
    /// Its description as the panel listed it when the buffer opened.
    original: *Table.String,
    /// The description sent, while its commands run and after they failed.
    message: *Table.String,
    /// The panel's generation as the last command was queued: a give-up moves it on.
    generation: *u32,
    /// 1 once the buffer was seen open: its closing after that gives the description up.
    buffer_seen: *u8,
    /// The runs the buffer, asked for, has not been open.
    open_waits: *u8,
    /// 1 once a submit of the default changelist did not go through, or was given up while it
    /// ran: the server may have numbered it, submitted it, or done neither; `C-c C-c` refuses,
    /// and `s` starts anew (`start` says what becomes of what was typed, which it decides by
    /// comparing the changelist's files with `file_paths`, that submit's files until then).
    renumbered: *u8,
    /// The workspace the description was begun in: another one gives it up.
    client: *Table.String,
    /// For a submit, the changelist's files as `s` saw them: their number, a fingerprint of
    /// their files (`p4_status.submitFingerprint`) and the paths, a line each, which the
    /// default changelist's form is checked against.
    file_count: *u32,
    file_fingerprint: *u64,
    file_paths: *Table.Bytes,
};

/// `ChangeRow` read, its text as slices of the table's.
const ChangeRead = struct {
    phase: *u8,
    purpose: *u8,
    change: []const u8,
    original: []const u8,
    message: []const u8,
    generation: *u32,
    buffer_seen: *u8,
    open_waits: *u8,
    renumbered: *u8,
    client: []const u8,
    file_count: *u32,
    file_fingerprint: *u64,
    file_paths: []const u8,
};

const change_table = Atom.from(change_table_name);
const buffer_modes_table = Atom.from(text_panel.buffer_modes_table_name);
const show_requests_table = Atom.from(text_panel.show_requests_table_name);

/// Makes the table unless it is there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ change_table_name, message_name });
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 13);
    defer schema.deinit();
    try schema.addFieldFallible("phase", u8, .int);
    try schema.addFieldFallible("purpose", u8, .int);
    try schema.addFieldFallible("change", Table.String, .text_field);
    try schema.addFieldFallible("original", Table.String, .text_field);
    try schema.addFieldFallible("message", Table.String, .text_field);
    try schema.addFieldFallible("generation", u32, .int);
    try schema.addFieldFallible("buffer_seen", u8, .int);
    try schema.addFieldFallible("open_waits", u8, .int);
    try schema.addFieldFallible("renumbered", u8, .int);
    try schema.addFieldFallible("client", Table.String, .text_field);
    try schema.addFieldFallible("file_count", u32, .int);
    try schema.addFieldFallible("file_fingerprint", u64, .hex);
    try schema.addFieldFallible("file_paths", Table.Bytes, .bytes);
    const defaults = .{
        .phase = @as(u8, @intFromEnum(Phase.none)),
        .purpose = @as(u8, @intFromEnum(Purpose.submit)),
        .change = Table.String{},
        .original = Table.String{},
        .message = Table.String{},
        .generation = @as(u32, 0),
        .buffer_seen = @as(u8, 0),
        .open_waits = @as(u8, 0),
        .renumbered = @as(u8, 0),
        .client = Table.String{},
        .file_count = @as(u32, 0),
        .file_fingerprint = @as(u64, 0),
        .file_paths = Table.Bytes{},
    };
    _ = try tables.ensureSingleton(&schema, change_table, defaults, .durable);
}

/// What the description buffer reads and writes, for the system's access.
pub fn declareAccess(result: *sequencer.Access, tables: *Table.Registry) void {
    result.write(change_table);
    text_editor.declareBuffer(result, tables, message_buffer);
    result.writeIfPresent(tables, buffer_modes_table);
    result.writeIfPresent(tables, show_requests_table);
}

// ---- writing it ----------------------------------------------------------------------------------

/// One of `Msg`'s.
pub fn take(work: status.Work, received: sequencer.Message) !void {
    switch (received.tag.to(Msg)) {
        .vcs_p4_message_finish => try finish(work),
        .vcs_p4_message_cancel => try cancel(work),
        _ => {},
    }
}

/// Opens the description buffer for `purpose` of `change` (ignored for a new changelist),
/// holding `description`; for a submit, `files` are the changelist's files as the panel lists
/// them, kept as what is to be submitted and told. One being sent is not interrupted. One being
/// written for the same purpose and changelist is shown again, the files it submits taken
/// again; one for another is given up, which is told (`The description being written for <X>
/// was given up`), and this one begun. After a default changelist's submit
/// that did not go through or was given up, a submit of a changelist that holds exactly the
/// files that submit kept (the default changelist still, or the numbered one the server left)
/// begins holding what was typed. A submit of the default changelist holding other files holds
/// it too, as that changelist has no description of its own, and the files sentence says it was
/// typed for other files. Any other begins from its own description, and what was typed is said
/// to be dropped, so it is never lost or attached to other files unsaid.
pub fn start(work: status.Work, purpose: Purpose, change: p4.Changelist, description: []const u8, files: []const status.FileRow) !void {
    if (work.refusedWithoutWorkspace()) return;
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    const phase = std.enums.fromInt(Phase, row.phase.*) orelse .none;
    const tables = work.tables();
    if (phase.runs()) return work.tell("The changelist's command is still running");
    const allocator = try work.scratch();
    const change_text = if (purpose == .new_change) "" else try status.changeText(allocator, change);
    const read = try work.pass.readSingleton(change_table, ChangeRead);
    const same = read.purpose.* == @intFromEnum(purpose) and std.mem.eql(u8, read.change, change_text) and read.renumbered.* == 0;
    const open = text_editor.tableOf(tables, message_buffer) != null;
    if (phase == .editing and open and same) {
        try keepFiles(work, files);
        text_panel.setBufferMode(tables, message_buffer, modes.vcs_p4_message);
        text_panel.showBuffer(tables, message_buffer, .other_window);
        if (purpose == .submit) return tellFiles(work, "", change, files, .none);
        return work.tell("A description is being written: C-c C-c sends it, C-c C-k gives it up");
    }
    // After a default changelist's submit that did not go through or was given up: what was
    // typed for it goes on unremarked with the same files only (the default changelist still,
    // or the changelist the server left holding exactly the files kept). The default changelist
    // holding other files has no description to begin from, so it holds the typed text, said
    // to be typed for other files; anywhere else the text is said to be dropped. The files that
    // submit kept are read here, before `keepFiles` below replaces them.
    var text = description;
    var typed_fate: TypedFate = .none;
    // A description being written for something else, nothing having failed, is replaced: said.
    var given_up: []const u8 = "";
    if (phase == .editing and open and read.renumbered.* == 0) {
        const read_purpose = std.enums.fromInt(Purpose, read.purpose.*) orelse .submit;
        const was_for = if (read_purpose == .new_change)
            "a new changelist"
        else
            try status.changelistName(allocator, status.changelistOf(read.change) orelse .default);
        given_up = try std.fmt.allocPrint(allocator, "The description being written for {s} was given up", .{was_for});
    }
    if (read.renumbered.* != 0) {
        const typed = if (open) try shared.textOf(tables, message_buffer) else read.message;
        const has_typed = std.mem.trim(u8, typed, " \t\r\n").len != 0;
        const differs = !std.mem.eql(u8, trimmedEnd(typed), trimmedEnd(description));
        const same_files = sameFiles(files, read.file_paths);
        const submits_typed = has_typed and purpose == .submit;
        if (submits_typed and same_files) {
            text = typed;
            const saved_first = change != .default and differs;
            typed_fate = if (saved_first) .kept_to_save else .kept;
        } else if (submits_typed and change == .default) {
            text = typed;
            typed_fate = .kept_for_other_files;
        } else if (has_typed and differs) {
            typed_fate = .dropped;
        }
    }
    const kept = try allocator.dupe(u8, text);
    const original = try allocator.dupe(u8, description);
    const client = try allocator.dupe(u8, work.client());
    const cells = try work.writeCells(change_table);
    row.purpose.* = @intFromEnum(purpose);
    try cells.assignString(row.change, change_text);
    try cells.assignString(row.original, original);
    try cells.assignString(row.message, "");
    try cells.assignString(row.client, client);
    try keepFiles(work, files);
    row.generation.* = work.state.generation.*;
    row.buffer_seen.* = 0;
    row.open_waits.* = 0;
    row.renumbered.* = 0;
    const memory = work.memory();
    if (!open) {
        text_editor.request(memory, tables, .{ .create = .{ .buffer = message_buffer, .lines = .multi, .name = message_name } });
    }
    text_editor.request(memory, tables, .{ .set_text = .{ .buffer = message_buffer, .text = kept } });
    text_panel.setBufferMode(tables, message_buffer, modes.vcs_p4_message);
    text_panel.showBuffer(tables, message_buffer, .other_window);
    row.phase.* = @intFromEnum(Phase.editing);
    if (purpose == .submit) return tellFiles(work, given_up, change, files, typed_fate);
    if (given_up.len != 0) return work.tell(given_up);
    if (typed_fate != .dropped) return;
    if (purpose == .new_change) return work.tell("What you typed for the default changelist was dropped: a new changelist begins empty");
    const named = try status.changelistName(allocator, change);
    const sentence = try std.fmt.allocPrint(allocator, "What you typed for the default changelist was dropped: this is {s}'s own description", .{named});
    work.tell(sentence);
}

/// What became of the text typed for a default changelist's submit that did not go through.
const TypedFate = enum {
    /// There was none, or no such submit.
    none,
    /// The buffer holds it, for the files it was typed for, and it is the description the
    /// changelist has or, for the default changelist, the one its form is written with.
    kept,
    /// The buffer holds it, for the files it was typed for, in a numbered changelist described
    /// otherwise: it is saved there before the submit.
    kept_to_save,
    /// The buffer holds it, though the default changelist now holds other files than those it
    /// was typed for.
    kept_for_other_files,
    /// The buffer holds the changelist's own description instead.
    dropped,
};

/// Whether `files`' depot paths are exactly `paths`, a line each as `keepFiles` kept them, in
/// any order.
fn sameFiles(files: []const status.FileRow, paths: []const u8) bool {
    const kept: usize = std.mem.count(u8, paths, "\n");
    if (kept != files.len) return false;
    for (files) |file| {
        if (!holdsLine(paths, file.depot_path)) return false;
    }
    return true;
}

/// Keeps `files`, what a submit is to submit, as `s` saw them.
fn keepFiles(work: status.Work, files: []const status.FileRow) !void {
    const allocator = try work.scratch();
    var paths: std.Io.Writer.Allocating = .init(allocator);
    for (files) |file| {
        try paths.writer.writeAll(file.depot_path);
        try paths.writer.writeByte('\n');
    }
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    const cells = try work.writeCells(change_table);
    row.file_count.* = @intCast(files.len);
    row.file_fingerprint.* = try status.submitFingerprint(allocator, files);
    row.file_paths.* = .{ .payload = try cells.appendPayload(paths.written(), .@"1") };
}

/// Tells what a submit of `change` submits: its files, by number and the first few names, so
/// the person sees them without their being part of the description, and in the same sentence
/// what became of the text typed for a default changelist's submit that did not go through;
/// after `given_up`, a description given up for this one, when it is not empty.
fn tellFiles(work: status.Work, given_up: []const u8, change: p4.Changelist, files: []const status.FileRow, typed_fate: TypedFate) !void {
    const allocator = try work.scratch();
    const named = try status.changelistName(allocator, change);
    var told: std.Io.Writer.Allocating = .init(allocator);
    if (given_up.len != 0) try told.writer.print("{s}. ", .{given_up});
    const noun = if (files.len == 1) "file" else "files";
    try told.writer.print("Submitting {s}: {d} {s} (", .{ named, files.len, noun });
    const shown = @min(files.len, 5);
    for (files[0..shown], 0..) |file, index| {
        if (index != 0) try told.writer.writeAll(", ");
        try told.writer.writeAll(file.path);
    }
    if (files.len > shown) try told.writer.writeAll(", ...");
    switch (typed_fate) {
        .none => try told.writer.writeAll("); C-c C-c submits them, C-c C-k gives it up"),
        .kept => switch (change) {
            .default => try told.writer.writeAll("); the buffer holds what you typed: C-c C-c submits them"),
            .numbered => try told.writer.writeAll("); the buffer holds what you typed: C-c C-c submits"),
        },
        .kept_to_save => try told.writer.writeAll("); the buffer holds what you typed: C-c C-c saves it to the changelist and submits"),
        .kept_for_other_files => try told.writer.writeAll("); the buffer holds what you typed for other files: change it, or C-c C-c submits these under it"),
        .dropped => try told.writer.print("); what you typed for the default changelist was dropped: this is {s}'s own description", .{named}),
    }
    work.tell(told.written());
}

/// `C-c C-c`: the description sent, the first of its commands queued; refused when it is empty,
/// when a command of its runs, and after a default changelist's submit failed.
fn finish(work: status.Work) !void {
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    const phase = std.enums.fromInt(Phase, row.phase.*) orelse .none;
    switch (phase) {
        .none => return work.tell("No description is being written"),
        .verifying, .form_asked, .saving, .submitting => return work.tell("The changelist's command is still running"),
        .editing => {},
    }
    const begun_in = try work.pass.readSingleton(change_table, ChangeRead);
    if (!std.mem.eql(u8, begun_in.client, work.client())) {
        try end(work);
        return work.tell("The workspace changed; the description was given up");
    }
    if (row.renumbered.* != 0) return work.tell("The default changelist's submit did not go through, or was given up while it ran: s on the changelist its files are in now (a numbered one, or the default again); what you typed is kept");
    const tables = work.tables();
    const text = try shared.textOf(tables, message_buffer);
    const blank = std.mem.trim(u8, text, " \t\r\n").len == 0;
    if (blank) return work.tell("The description is empty");
    if (std.mem.indexOfScalar(u8, text, 0) != null) return work.tell("p4 cannot be given that description: it holds a NUL");
    const cells = try work.writeCells(change_table);
    try cells.assignString(row.message, text);
    const read = try work.pass.readSingleton(change_table, ChangeRead);
    const purpose = std.enums.fromInt(Purpose, read.purpose.*) orelse .submit;
    const change = status.changelistOf(read.change) orelse .default;
    switch (purpose) {
        .new_change => try runStep(work, .form_asked, .{ .change_form = .default }, ""),
        .describe => try runStep(work, .form_asked, .{ .change_form = change }, ""),
        .submit => {
            // The panel reads its lists only when asked: they are read again before anything is
            // submitted, and what they then list is checked against what `s` saw
            // (`refreshEnded`).
            row.phase.* = @intFromEnum(Phase.verifying);
            row.generation.* = work.state.generation.*;
            try work.refresh();
        },
    }
}

/// A refresh ended, `read` saying whether it read the lists: a submit waiting on it
/// (`verifying`) goes on only when the changelist still holds exactly the files `s` saw;
/// otherwise it is told, nothing runs and the description is kept.
pub fn refreshEnded(work: status.Work, read_lists: status.ListsRead) !void {
    const read = try work.pass.readSingleton(change_table, ChangeRead);
    if (read.phase.* != @intFromEnum(Phase.verifying)) return;
    if (read_lists == .unread) {
        _ = try keepEditing(work, "The lists could not be read (see the note), so nothing was submitted; the description is kept: C-c C-c tries again");
        return;
    }
    const change = status.changelistOf(read.change) orelse .default;
    const allocator = try work.scratch();
    const named = try status.changelistName(allocator, change);
    switch (change) {
        .default => {},
        .numbered => |number| if (try work.changelistRow(number) == null) {
            const sentence = try std.fmt.allocPrint(allocator, "{s} is no longer pending, so nothing was submitted; the description is kept", .{named});
            _ = try keepEditing(work, sentence);
            return;
        },
    }
    if (work.state.commands_running.* != 0) {
        _ = try keepEditing(work, "Another command of the panel's runs, so nothing was submitted; the description is kept: C-c C-c once it ended");
        return;
    }
    // `submit -c` submits every file of the changelist, listed or not.
    const unlisted = work.unlistedFiles();
    if (unlisted != 0) {
        const sentence = try std.fmt.allocPrint(allocator, "Not every opened file is listed ({d} are not), so nothing was submitted: do this from a terminal; the description is kept", .{unlisted});
        _ = try keepEditing(work, sentence);
        return;
    }
    const files = try work.filesOf(change);
    const fingerprint = try status.submitFingerprint(allocator, files);
    if (fingerprint != read.file_fingerprint.*) {
        const had_noun = if (read.file_count.* == 1) "file" else "files";
        const sentence = try std.fmt.allocPrint(allocator, "{s} changed since s (it had {d} {s}, it has {d}), so nothing was submitted: s asks again; the description is kept", .{ named, read.file_count.*, had_noun, files.len });
        _ = try keepEditing(work, sentence);
        return;
    }
    const message = try allocator.dupe(u8, read.message);
    switch (change) {
        .numbered => |number| {
            const unchanged = std.mem.eql(u8, trimmedEnd(read.original), trimmedEnd(message));
            if (unchanged) return runStep(work, .submitting, .{ .submit = .{ .numbered = number } }, "");
            try runStep(work, .form_asked, .{ .change_form = change }, "");
        },
        .default => try runStep(work, .form_asked, .{ .change_form = .default }, ""),
    }
}

/// Queues `command`, `input_bytes` on its input, the description's next step, now `phase`.
fn runStep(work: status.Work, phase: Phase, command: p4.Command, input_bytes: []const u8) !void {
    const running_before = work.state.commands_running.*;
    try work.runCommand(command, input_bytes);
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    // Not queued (a name `p4` cannot be given, told): the description is being written still.
    if (work.state.commands_running.* == running_before) {
        row.phase.* = @intFromEnum(Phase.editing);
        return;
    }
    row.phase.* = @intFromEnum(phase);
    row.generation.* = work.state.generation.*;
}

/// `C-c C-k` and `C-x k`: the description given up, the buffer closed.
fn cancel(work: status.Work) !void {
    const row = try work.pass.readSingleton(change_table, ChangeRead);
    const phase = std.enums.fromInt(Phase, row.phase.*) orelse .none;
    switch (phase) {
        .none => return work.tell("No description is being written"),
        .verifying, .form_asked, .saving, .submitting => return work.tell("The changelist's command is still running"),
        .editing => {},
    }
    try end(work);
    work.tell("Description given up");
}

/// Nothing is being written any more: the buffer closes, and its window shows again what it
/// showed or closes.
fn end(work: status.Work) !void {
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    row.phase.* = @intFromEnum(Phase.none);
    row.buffer_seen.* = 0;
    row.open_waits.* = 0;
    row.renumbered.* = 0;
    const cells = try work.writeCells(change_table);
    try cells.assignString(row.message, "");
    const tables = work.tables();
    if (text_editor.tableOf(tables, message_buffer) != null) text_editor.request(work.memory(), tables, .{ .close = message_buffer });
}

/// A command of the panel's ended, `said` what it said, null for one that failed: when it is the
/// description's step, the next is queued, or the description ends, or a failure is told and
/// the buffer kept. Returns whether it was the description's, whose failure it told.
pub fn commandEnded(work: status.Work, name: status.CommandName, said: ?[]const u8) !bool {
    const read = try work.pass.readSingleton(change_table, ChangeRead);
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    const purpose = std.enums.fromInt(Purpose, read.purpose.*) orelse .submit;
    const change = status.changelistOf(read.change) orelse .default;
    const allocator = try work.scratch();
    const message = try allocator.dupe(u8, read.message);
    switch (phase) {
        .none, .editing, .verifying => return false,
        .form_asked => {
            if (name != .change_form) return false;
            const form = said orelse return keepEditing(work, "p4 change -o failed; $ shows why. The description is kept: C-c C-c tries again");
            const files: p4.FormFiles = if (purpose == .new_change) .drop else .keep;
            var written: std.Io.Writer.Allocating = .init(allocator);
            p4.writeChangeForm(&written.writer, form, message, files) catch |err| switch (err) {
                error.UnpassableArgument => return keepEditing(work, "p4 cannot be given that form: its description is empty, or its form is not a new changelist's"),
                error.WriteFailed => return error.OutOfMemory,
            };
            const submits_default = purpose == .submit and change == .default;
            // A submit's form lists what is submitted, or what the changelist holds: it must
            // list exactly the files `s` saw.
            if (purpose == .submit and !formListsExactly(form, read.file_paths)) {
                const named = try status.changelistName(allocator, change);
                const sentence = try std.fmt.allocPrint(allocator, "{s} changed since s (p4 change -o lists other files than those it had), so nothing was submitted: s asks again; the description is kept", .{named});
                return keepEditing(work, sentence);
            }
            if (submits_default) {
                try runStep(work, .submitting, .{ .submit = .default }, written.written());
            } else {
                try runStep(work, .saving, .save_change, written.written());
            }
            return true;
        },
        .saving => {
            if (name != .save_change) return false;
            const sentence = said orelse return keepEditing(work, "p4 change -i failed; $ shows why. The description is kept: C-c C-c tries again");
            const saved = p4.parseChangeSaved(sentence);
            switch (purpose) {
                .new_change => {
                    try end(work);
                    const told = if (saved) |number| try std.fmt.allocPrint(allocator, "Change {d} made", .{number}) else "A new changelist was made";
                    work.tell(told);
                },
                .describe => {
                    try end(work);
                    const told = try std.fmt.allocPrint(allocator, "Saved the description of {s}", .{try status.changelistName(allocator, change)});
                    work.tell(told);
                },
                .submit => {
                    const number = switch (change) {
                        .numbered => |number| number,
                        .default => return keepEditing(work, "The default changelist is submitted from its form, not saved"),
                    };
                    try runStep(work, .submitting, .{ .submit = .{ .numbered = number } }, "");
                },
            }
            return true;
        },
        .submitting => {
            if (name != .submit) return false;
            if (said != null) {
                try end(work);
                const told = try std.fmt.allocPrint(allocator, "Submitted {s}: {s}", .{ try status.changelistName(allocator, change), summaryOf(message) });
                work.tell(told);
                return true;
            }
            switch (change) {
                .numbered => return keepEditing(work, "p4 submit failed; $ shows why. The description is kept: C-c C-c tries again"),
                .default => {
                    _ = try keepEditing(work, "The submit did not go through ($ shows why). If Perforce numbered the changelist it is listed now: put the cursor on it and press s; otherwise s on the default changelist again. What you typed is kept.");
                    const row = try work.pass.writeSingleton(change_table, ChangeRow);
                    row.renumbered.* = 1;
                    return true;
                },
            }
        },
    }
}

/// Whether `form`'s `Files:` lists exactly the depot paths of `paths`, a line each, as
/// `keepFiles` kept them, in any order. A form's file line is a tab, the depot path, then a tab
/// and `# action` (`p4_change.html`'s form), which is cut at its first tab or ` #`.
fn formListsExactly(form: []const u8, paths: []const u8) bool {
    var listed: u32 = 0;
    var in_files = false;
    var lines = std.mem.splitScalar(u8, form, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const indented = line[0] == '\t' or line[0] == ' ';
        if (!indented) {
            in_files = std.mem.startsWith(u8, line, "Files:");
            continue;
        }
        if (!in_files) continue;
        const text = std.mem.trim(u8, line, " \t");
        const path_end = std.mem.indexOfAny(u8, text, "\t#") orelse text.len;
        const depot = std.mem.trimEnd(u8, text[0..path_end], " ");
        if (depot.len == 0) continue;
        if (!holdsLine(paths, depot)) return false;
        listed += 1;
    }
    const kept: u32 = @intCast(std.mem.count(u8, paths, "\n"));
    return listed == kept;
}

/// Whether `lines`, a line each, holds `wanted` as a line.
fn holdsLine(lines: []const u8, wanted: []const u8) bool {
    var each = std.mem.tokenizeScalar(u8, lines, '\n');
    while (each.next()) |line| {
        if (std.mem.eql(u8, line, wanted)) return true;
    }
    return false;
}

/// A step failed: told, and the description is being written again, its buffer kept.
fn keepEditing(work: status.Work, sentence: []const u8) !bool {
    const row = try work.pass.writeSingleton(change_table, ChangeRow);
    row.phase.* = @intFromEnum(Phase.editing);
    work.tell(sentence);
    return true;
}

/// `text` without the blank lines and spaces at its end.
fn trimmedEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t\r\n");
}

/// The first line of `message` that is not blank, its ends trimmed.
fn summaryOf(message: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, message, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len != 0) return trimmed;
    }
    return "";
}

/// A kernel of the system: a description whose command a give-up left without an answer is
/// being written again (the command may have run: the refresh shows); one whose buffer, once
/// seen, is gone is given up; one whose buffer has not opened within the text panels' wait is
/// given up.
pub fn followChange(pass: *sequencer.Pass) !void {
    const read = try pass.readSingleton(change_table, ChangeRead);
    const phase = std.enums.fromInt(Phase, read.phase.*) orelse .none;
    if (phase == .none) return;
    const panel_state = try pass.readSingleton(Atom.from(status.state_table_name), struct { generation: *u32, client: []const u8 });
    const tables = pass.frame.tables;
    const open = text_editor.tableOf(tables, message_buffer) != null;
    const seen = read.buffer_seen.* != 0;
    const moved_on = phase.runs() and read.generation.* != panel_state.generation.*;
    const closed = phase == .editing and seen and !open;
    const unopened = phase == .editing and !seen and !open and read.open_waits.* + 1 >= text_panel.max_show_waits;
    const newly_seen = !seen and open;
    const waiting = phase == .editing and !seen and !open;
    const other_workspace = !std.mem.eql(u8, read.client, panel_state.client);
    if (!moved_on and !closed and !unopened and !newly_seen and !waiting and !other_workspace) return;
    const work = try status.Work.of(pass);
    if (other_workspace) {
        try end(work);
        return work.tell("The workspace changed; the description was given up");
    }
    // A give-up while the default changelist's `submit -i` ran: whether it was submitted is not
    // known, so the same form is never sent again; the changelists are read, then `s`.
    const default_submit = phase == .submitting and std.mem.eql(u8, read.change, "default");
    if (moved_on and default_submit) {
        _ = try keepEditing(work, "Gave up waiting for p4 submit: whether the default changelist was submitted is not known: g reads the changelists, then s on the changelist its files are in");
        const row = try pass.writeSingleton(change_table, ChangeRow);
        row.renumbered.* = 1;
        return;
    }
    if (moved_on) {
        _ = try keepEditing(work, "Gave up waiting for p4: g shows what it did; C-c C-c sends the description again");
        return;
    }
    if (closed or unopened) {
        try end(work);
        if (unopened) text_panel.forgetShowRequest(tables, message_buffer);
        work.tell("Description given up");
        return;
    }
    const row = try pass.writeSingleton(change_table, ChangeRow);
    if (newly_seen) row.buffer_seen.* = 1;
    if (waiting) row.open_waits.* += 1;
}
