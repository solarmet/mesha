const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const sequencer = mesha.sequencer;
const Log = mesha.log.scope("action_palette");
const plugin_api = mesha.plugin;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const math = mesha.math;
const input = mesha.input;
const state = @import("state.zig");
const style = @import("ui/style.zig");
const editor_api = plugin_api.editor_api;
const app_commands = plugin_api.app_commands;
const keybinds = mesha.keybinds;
const shared = @import("text_editor.zig");
const modes = @import("modes.zig");
const panels_mod = mesha.panels;
const panel_frame = @import("panel_frame.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const transient = @import("transient.zig");

/// The action palette's root: its keys, clicks and text editor. No panel has it.
pub const action_palette_root = Atom.from("action_palette");

pub const Completion = editor_api.Completion;
pub const Completions = editor_api.Completions;
pub const Msg = editor_api.Msg;
pub const eventOf = editor_api.eventOf;

pub const table_name = "editor_action_palette";

const kRowHeight: f32 = 40;

const kBodyHeight: f32 = 26;

pub const kMaxRows: usize = 10;

pub const kBufSize: usize = editor_api.kBufSize;
pub const kCompletionDataSize: usize = editor_api.kCompletionDataSize;

const kKeyColWidth: f32 = 110;
const kDetailColWidth: f32 = 250;
/// The minibuffer's line, along the window's bottom.
const kMinibufferHeight: f32 = 40;
const kSectionPadding: f32 = 8;
const kSectionGap: f32 = 6;
/// A dialog's button, which does not stretch across the window.
const kButtonWidth: f32 = 140;
/// The most of the window's height the minibuffer and what opens above it cover.
const kMaxWindowShare: f32 = 0.6;

pub const CmdPayload = editor_api.CmdPayload;

const CompletionPayload = extern struct { index: u32 };
const scroll_tag = Atom.from("action_palette_scroll");

/// Above this, a reset returns an arena's pages. Requests rebuild as text is typed, so ordinary
/// ones must reuse pages.
const kCompletionRetainBytes: usize = 1024 * 1024;

pub const State = struct {
    /// The prompt's text, a string cell of the palette's table (`textOf`).
    text: *Table.String,
    /// Where typing goes, in bytes of the text.
    cursor: *u32,

    /// The entry selected: an index into the open prompt's entries. A prompt's is kept on one of
    /// them (`clampSelection`); a dialog's may be past them, none selected.
    selected: *u32,

    request_open: *u8,
    request_owner: *Atom,
    request_presentation: *u8,
    /// The major mode of the open prompt, which its presenter named: what the palette asks the
    /// actions system for while the prompt is open (`modes.followPrompt`).
    request_mode: *Atom,
    completions_ptr: *usize,
    /// Where the open prompt's owner hears its events.
    reply_inbox: *Atom,
    reply_tag: *Atom,
    /// The owner's user data, which comes back with each event: a bytes cell of the
    /// palette's table.
    reply_user_data: *Table.Bytes,

    /// The owner whose cancelled request ended, until it acknowledges hearing so; 0 for none.
    /// No request is presented meanwhile: that owner could not tell the late response to its
    /// cancelled request from one to a new request.
    cancelled_owner: *Atom,
    /// The whole text is selected, as when a field opens: the next edit replaces it.
    text_selected: *u8,
    /// What Tab last made the text from the selected entry, while the text is still that: the
    /// entry stays selected as the owner lists anew for it (`selectCompleted`). Empty once the
    /// text or the selection moves on otherwise.
    tab_text: *Table.String,
    /// The label of the entry Tab completed the text to, which tells it among the entries.
    tab_label: *Table.String,
    /// Tab has made the text `tab_text` and no report of that text has come: a report of an
    /// earlier key, with other text, keeps what Tab made rather than forgetting it.
    tab_typing: *u8,

    /// Counts the requests presented, so the text editor a request names is loaded once each.
    request_serial: *u32,
    /// Whether the open request takes text, which the palette's text editor holds. Kept here
    /// because the request itself may be rebuilt, and its memory reset, before the palette
    /// takes the new one.
    request_takes_text: *u8,
    /// The request the text editor holds the text of; 0 for none.
    editor_loaded_serial: *u32,
    /// A submit awaits the text editor's report of its last text.
    editor_submit_pending: *u8,
    /// The text editor's state the prompt last heard of: its text, caret and selection.
    /// Writing it is what draws the prompt again after a caret move.
    editor_serial: *u32,
    /// How far the text line is scrolled to keep the caret in it, kept by its drawing.
    editor_scroll_x: *f32,

    /// The height of the window's bottom the panels were asked to leave for the minibuffer's
    /// line; 0 while a stage alone has the window.
    reserved: *f32,

    /// The echo area: what the line shows while no prompt is open, the newest line of
    /// `*Messages*`; empty once a prompt has opened over it.
    echo: *Table.String,
    /// The revision of `*Messages*` the echo was last taken at.
    echo_revision: *u32,

    /// What the line tells of the keys of a sequence: those pressed so far while it waits for
    /// more (`C-x 4-`), or the sequence that led to nothing (`C-x 4 q is undefined`). It
    /// shows before the echo.
    key_echo: *Table.String,
    /// The keys the pending sequence leads to, once it has waited long enough: a line each,
    /// the key, a tab and what it does. Empty until then.
    key_hints: *Table.String,
    /// How long the pending sequence has waited without its hints, in seconds.
    key_wait: *f32,
    /// What a requester says of the keys so far that are no sequence's, as a count before a
    /// command (`C-u 4-`): shown before `key_echo` until its requester clears it.
    key_note: *Table.String,
};

/// One arena per kind of requester, each reset when that requester builds anew. A request's
/// arena lives until it is replaced or finished; what crosses to the requester is copied.
pub const CompletionArena = enum {
    action_list,
    picker,
    modal,
    tracker,
    figure,
    widget,
    table_view,
    text_panel,
    open,
    text_tools,
    plugins,
    transient,
    /// The version-control panels' dialogs: each one a panel presents resets it.
    vcs,

    fn label(self: CompletionArena) Atom {
        return switch (self) {
            .action_list => Atom.from("editor.completions.action_list"),
            .picker => Atom.from("editor.completions.picker"),
            .modal => Atom.from("editor.completions.modal"),
            .tracker => Atom.from("editor.completions.tracker"),
            .figure => Atom.from("editor.completions.figure"),
            .widget => Atom.from("editor.completions.widget"),
            .table_view => Atom.from("editor.completions.table_view"),
            .text_panel => Atom.from("editor.completions.text_panel"),
            .open => Atom.from("editor.completions.open"),
            .text_tools => Atom.from("editor.completions.text_tools"),
            .plugins => Atom.from("editor.completions.plugins"),
            .transient => Atom.from("editor.completions.transient"),
            .vcs => Atom.from("editor.completions.vcs"),
        };
    }
};

pub const completions_scope_name = "editor.completions";

fn completionArena(memory: *memory_mod.Memory, which: CompletionArena) !struct { scope: *memory_mod.Scope, arena: *memory_mod.Arena } {
    const scope = try memory.resolvedPrivateScope(Atom.from(completions_scope_name));
    const arena = try scope.labeledArena(which.label());
    return .{ .scope = scope, .arena = arena };
}

/// Through the host's vtable, since a request's arena is used across images.
pub fn completionAllocator(memory: *memory_mod.Memory, which: CompletionArena) !std.mem.Allocator {
    const resolved = try completionArena(memory, which);
    return resolved.arena.allocator();
}

pub fn resetCompletionArena(memory: *memory_mod.Memory, which: CompletionArena) void {
    const resolved = completionArena(memory, which) catch return;
    _ = resolved.arena.reset(.{ .retain_with_limit = kCompletionRetainBytes });
}

/// Backs each arena at init, so the first prompt cannot be refused for want of a record.
pub fn prepareCompletionArenas(memory: *memory_mod.Memory, atoms: *Atom.Registry) !void {
    try atoms.tryInternAll(&.{completions_scope_name});
    for (std.enums.values(CompletionArena)) |which| _ = try completionArena(memory, which);
}

/// A request is held across frames and so across a reload of the editor, whose literals are
/// unmapped with it. Copies every display string into `allocator`, the request's completion
/// arena, which is host memory. Call last when building a request; it replaces `entries`.
pub fn ownRequestText(allocator: std.mem.Allocator, completions: *Completions) error{OutOfMemory}!void {
    completions.prompt = try allocator.dupe(u8, completions.prompt);
    completions.initial_query = try allocator.dupe(u8, completions.initial_query);
    completions.title = try allocator.dupe(u8, completions.title);
    completions.body = try allocator.dupe(u8, completions.body);
    const entries = try allocator.alloc(Completion, completions.entries.len);
    for (entries, completions.entries) |*entry, source| {
        entry.* = source;
        entry.key = try allocator.dupe(u8, source.key);
        entry.label = try allocator.dupe(u8, source.label);
        entry.detail = try allocator.dupe(u8, source.detail);
        if (source.completes_to) |text| entry.completes_to = try allocator.dupe(u8, text);
    }
    completions.entries = entries;
}

const defaults = .{
    .text = Table.String{},
    .cursor = @as(u32, 0),
    .selected = @as(u32, 0),
    .request_open = @as(u8, 0),
    .request_owner = @as(Atom, @enumFromInt(0)),
    .request_presentation = @as(u8, 0),
    .request_mode = @as(Atom, @enumFromInt(0)),
    .completions_ptr = @as(usize, 0),
    .reply_inbox = @as(Atom, @enumFromInt(0)),
    .reply_tag = @as(Atom, @enumFromInt(0)),
    .reply_user_data = Table.Bytes{},
    .cancelled_owner = @as(Atom, @enumFromInt(0)),
    .text_selected = @as(u8, 0),
    .tab_text = Table.String{},
    .tab_label = Table.String{},
    .tab_typing = @as(u8, 0),
    .request_serial = @as(u32, 0),
    .request_takes_text = @as(u8, 0),
    .editor_loaded_serial = @as(u32, 0),
    .editor_submit_pending = @as(u8, 0),
    .editor_serial = @as(u32, 0),
    .editor_scroll_x = @as(f32, 0),
    .reserved = @as(f32, 0),
    .echo = Table.String{},
    .echo_revision = @as(u32, 0),
    .key_echo = Table.String{},
    .key_hints = Table.String{},
    .key_wait = @as(f32, 0),
    .key_note = Table.String{},
};

/// The fields `stateSchema` adds.
const state_field_count = 29;

fn stateSchema(schema: *Table.Schema) !void {
    try schema.addFieldFallible("text", Table.String, .text_field);
    try schema.addFieldFallible("cursor", u32, .int);
    try schema.addFieldFallible("selected", u32, .int);
    try schema.addFieldFallible("request_open", u8, .int);
    try schema.addFieldFallible("request_owner", Atom, .atom);
    try schema.addFieldFallible("request_presentation", u8, .int);
    try schema.addFieldFallible("request_mode", Atom, .atom);
    try schema.addFieldFallible("completions_ptr", usize, .int);
    try schema.addFieldFallible("reply_inbox", Atom, .atom);
    try schema.addFieldFallible("reply_tag", Atom, .atom);
    try schema.addFieldFallible("reply_user_data", Table.Bytes, .bytes);
    try schema.addFieldFallible("cancelled_owner", Atom, .atom);
    try schema.addFieldFallible("text_selected", u8, .int);
    try schema.addFieldFallible("tab_text", Table.String, .text_field);
    try schema.addFieldFallible("tab_label", Table.String, .text_field);
    try schema.addFieldFallible("tab_typing", u8, .int);
    try schema.addFieldFallible("request_serial", u32, .int);
    try schema.addFieldFallible("request_takes_text", u8, .int);
    try schema.addFieldFallible("editor_loaded_serial", u32, .int);
    try schema.addFieldFallible("editor_submit_pending", u8, .int);
    try schema.addFieldFallible("editor_serial", u32, .int);
    try schema.addFieldFallible("editor_scroll_x", f32, .int);
    try schema.addFieldFallible("reserved", f32, .int);
    try schema.addFieldFallible("echo", Table.String, .text_field);
    try schema.addFieldFallible("echo_revision", u32, .int);
    try schema.addFieldFallible("key_echo", Table.String, .text_field);
    try schema.addFieldFallible("key_hints", Table.String, .text_field);
    try schema.addFieldFallible("key_wait", f32, .int);
    try schema.addFieldFallible("key_note", Table.String, .text_field);
}

fn deliverySchema(schema: *Table.Schema) !void {
    try schema.addFieldFallible("held_responses", u32, .int);
}

const delivery_defaults = .{ .held_responses = @as(u32, 0) };

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Requests.ensure(scratch, atoms, tables, requests_table_name);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, state_field_count);
    defer schema.deinit();
    try stateSchema(&schema);
    _ = try tables.ensureSingleton(&schema, atoms.intern(table_name), defaults, .durable);
    try modes.ensurePromptModes(scratch, atoms, tables, prompt_modes_table_name);
    var delivery_schema: Table.Schema = undefined;
    try delivery_schema.init(scratch.allocator, atoms, 1);
    defer delivery_schema.deinit();
    try deliverySchema(&delivery_schema);
    _ = try tables.ensureSingleton(&delivery_schema, atoms.intern(delivery_table_name), delivery_defaults, .durable);
}

pub fn prompt(tables: *Table.Registry, atoms: *Atom.Registry) State {
    const t = tables.findByName(atoms.intern(table_name)) orelse @panic("editor_action_palette singleton missing");
    const handle = Table.RowHandle{ .row = 0, .generation = t.rowGeneration(0) };
    return t.getRow(handle, State) orelse @panic("editor_action_palette singleton row missing");
}

pub fn currentOwner(tables: *Table.Registry, atoms: *Atom.Registry) ?Atom {
    const s = prompt(tables, atoms);
    if (s.request_open.* == 0) return null;
    return s.request_owner.*;
}

pub fn currentCompletions(tables: *Table.Registry, atoms: *Atom.Registry) ?*const Completions {
    return completionsOf(prompt(tables, atoms));
}

fn completionsOf(s: State) ?*const Completions {
    if (s.request_open.* == 0 or s.completions_ptr.* == 0) return null;
    return @ptrFromInt(s.completions_ptr.*);
}

/// Where the open prompt's owner hears its events, its user data in `palette`, the palette's
/// table, until the reply is next set.
fn replyOf(palette: *const Table, s: State) sequencer.ReplyTo {
    const user_data = palette.bytesOf(s.reply_user_data.*);
    return .{ .inbox = s.reply_inbox.*, .tag = s.reply_tag.*, .user_data = .{ .bytes = user_data } };
}

/// Keeps `reply` in the palette's table, `palette`, a copy of its user data among its
/// payloads.
fn setReply(palette: *Table, s: State, reply: sequencer.ReplyTo) error{ OutOfMemory, Overflow }!void {
    const user_data = reply.user_data.bytes;
    s.reply_user_data.* = if (user_data.len == 0) .{} else .{ .payload = try palette.appendPayload(user_data, Table.bytes_alignment) };
    s.reply_inbox.* = reply.inbox;
    s.reply_tag.* = reply.tag;
}

/// Forgets where the owner hears its events.
fn clearReply(s: State) void {
    s.reply_user_data.* = .{};
    s.reply_inbox.* = sequencer.no_inbox;
    s.reply_tag.* = sequencer.no_inbox;
}

/// The table the prompt's row is in, which holds its text.
fn paletteTable(tables: *Table.Registry) *Table {
    return tables.findByName(Atom.from(table_name)) orelse @panic("editor_action_palette singleton missing");
}

/// The prompt's text, in `palette`, its table, until the text next changes.
pub fn textOf(palette: *const Table, s: State) []const u8 {
    return palette.textOf(s.text.*);
}

/// The open prompt's text; valid until the prompt next changes.
pub fn promptText(tables: *Table.Registry, atoms: *Atom.Registry) []const u8 {
    const s = prompt(tables, atoms);
    return textOf(paletteTable(tables), s);
}

/// Takes `text` as the prompt's whole text, the cursor after it. Text that cannot be kept
/// leaves the prompt as it was, and is logged.
fn setText(palette: *Table, s: State, text: []const u8) void {
    palette.assignString(s.text, text) catch |err| {
        Log.err("prompt_text_refused", .{ .bytes = text.len, .@"error" = @errorName(err) });
        return;
    };
    s.cursor.* = @intCast(text.len);
}

/// Puts `typed` in the text at the cursor, which moves past it.
fn insertText(palette: *Table, s: State, typed: []const u8) void {
    const before = textOf(palette, s);
    const at: usize = @min(s.cursor.*, before.len);
    // One payload of the three parts, filled where it lies: the text has no bound.
    const joined = palette.allocatePayload(before.len + typed.len, .@"1") catch |err| {
        Log.err("prompt_text_refused", .{ .bytes = before.len + typed.len, .@"error" = @errorName(err) });
        return;
    };
    const bytes = palette.payloadBytesMut(joined);
    @memcpy(bytes[0..at], before[0..at]);
    @memcpy(bytes[at..][0..typed.len], typed);
    @memcpy(bytes[at + typed.len ..], before[at..]);
    s.text.* = .{ .payload = joined };
    s.cursor.* = @intCast(at + typed.len);
}

// ---- requests from other modules ----------------------------------------------------------
//
// Other modules ask the palette for a prompt by appending rows of `commands.action_palette`,
// which it takes in its run, after every requester has run that frame. A requester learns
// whether its prompt opened from `requestOpen` and `currentOwner` the frame after, or from
// the `completed` a refused or replaced prompt's owner hears.

/// A request to the palette, a row of `commands.action_palette`.
pub const Request = union(enum) {
    /// Opens `completions`, closing a prompt opened in an earlier frame, whose owner hears
    /// `completed` with nothing chosen. Of the prompts presented in one frame the first opens;
    /// the palette logs every other, and their owners hear `completed` with nothing chosen.
    /// `mode` is the prompt's major mode while it is open: `modes.prompt`, or `modes.isearch`
    /// for a text panel's search.
    present: struct { completions: *const Completions, reply: sequencer.ReplyTo, mode: Atom = modes.prompt },
    /// New completions for the open prompt, as when its owner answered a changed query.
    replace: struct { completions: *const Completions },
    /// Closes the open prompt, whoever owns it; its owner hears `completed` with nothing chosen.
    dismiss: struct {},
    /// Closes the open prompt if `owner` owns it; it hears `completed` with the text typed.
    /// Nothing is presented until `owner` acknowledges that.
    cancel: struct { owner: Atom },
    /// `owner` heard a `completed`, which ends the wait a cancel of its prompt began.
    acknowledge: struct { owner: Atom },
    /// What the line says of keys pressed that are no sequence's, as a count before a command
    /// (`C-u 4-`); empty to say nothing again.
    note: struct { text: []const u8 },
};

pub const requests_table_name = "commands.action_palette";
pub const Requests = sequencer.Commands(Request);

/// Asks the palette for `wanted`, in its run this frame.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: Request) void {
    Requests.of(memory, tables, requests_table_name).push(wanted);
}

/// Whether a prompt presented now would open. A requester that presents each frame until its
/// prompt opens checks this first, so a refusal does not end what it waits for.
pub fn canPresent(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    const s = prompt(tables, atoms);
    const held = delivery(tables, atoms).held_responses.*;
    return refusal(s, held) == null;
}

pub fn requestOpen(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return prompt(tables, atoms).request_open.* != 0;
}

const Refusal = enum { awaiting_acknowledgement, response_held };

/// Why a prompt cannot open now: an owner could not tell a late response to a request that
/// ended from one to its next.
fn refusal(s: State, held_responses: u32) ?Refusal {
    if (s.cancelled_owner.* != none_owner) return .awaiting_acknowledgement;
    if (held_responses != 0) return .response_held;
    return null;
}

const none_owner: Atom = @enumFromInt(0);

// ---- delivering events to requesters --------------------------------------------------------
//
// The palette sends its events as `emit` commands, which the editor's command hook delivers
// where the requester's `ReplyTo` names, under its tag with its user data, the event as the
// payload (`editor_api.eventPayload`, read with `eventOf`). A final response that finds no
// queue space is held by the hook and counted in `editor_action_palette_delivery`, which the
// hook owns and the palette reads: no prompt opens while one is held.

pub const delivery_table_name = "editor_action_palette_delivery";

const Delivery = struct {
    /// Final responses waiting in a held command.
    held_responses: *u32,
};

fn delivery(tables: *Table.Registry, atoms: *Atom.Registry) Delivery {
    const t = tables.findByName(atoms.intern(delivery_table_name)) orelse @panic("editor_action_palette_delivery singleton missing");
    const handle = Table.RowHandle{ .row = 0, .generation = t.rowGeneration(0) };
    return t.getRow(handle, Delivery) orelse @panic("editor_action_palette_delivery singleton row missing");
}

/// False only for a refused `completed`, which is the requester's final response: a prompt's
/// owner waits for it and a cancel waits for its acknowledgement, so the caller must keep it.
/// A refused `query_changed` is superseded by the next edit and is dropped.
fn emitEvent(inboxes: sequencer.Inboxes, reply: sequencer.ReplyTo, event: Msg.Event) bool {
    const scratch = inboxes.memory.frameScratchAllocator() catch return refuseEvent(event.kind);
    const payload = editor_api.eventPayload(scratch.allocator, event) catch return refuseEvent(event.kind);
    inboxes.tryAnswerBytes(reply, payload) catch return refuseEvent(event.kind);
    return true;
}

/// A refused `completed` is kept to try again; a refused `query_changed` is superseded by
/// the next edit and is dropped.
fn refuseEvent(kind: Msg.EventKind) bool {
    if (kind == .completed) return false;
    Log.warn("query_changed_dropped", .{});
    return true;
}

/// The editor's command hook for the palette's `command`: an `emit` is delivered, or kept to try
/// again when it is a final response that found no queue space; the other commands are requests
/// for the palette's run.
pub fn processCmd(tables: *Table.Registry, atoms: *Atom.Registry, command: *CmdPayload) sequencer.Applied {
    switch (command.*) {
        .present => |presenting| request(tables.memory, tables, .{ .present = .{ .completions = presenting.completions, .reply = presenting.reply } }),
        .replace => |replacement| request(tables.memory, tables, .{ .replace = .{ .completions = replacement.completions } }),
        .dismiss => request(tables.memory, tables, .{ .dismiss = .{} }),
        .emit => |event| {
            const held = delivery(tables, atoms).held_responses;
            const inboxes: sequencer.Inboxes = .{ .memory = tables.memory, .tables = tables };
            const emitted: Msg.Event = .{ .kind = event.kind, .completion = event.completion, .query = event.query };
            const delivered = emitEvent(inboxes, event.reply, emitted);
            if (delivered) {
                if (event.counted_as_held) held.* -= 1;
                return .done;
            }
            // The held command keeps its own copies of the query and completion.
            var retry = event;
            if (!retry.counted_as_held) held.* += 1;
            retry.counted_as_held = true;
            command.* = .{ .emit = retry };
            return .retry;
        },
    }
    return .done;
}

/// Sends `kind` to `reply` through the command hook. The request's row copies the query and
/// completion, so the prompt may change once this returns.
fn queueEvent(tables: *Table.Registry, reply: sequencer.ReplyTo, kind: Msg.EventKind, completion: ?*const Completion, query: []const u8) void {
    const chosen: ?Completion = if (completion) |entry| entry.* else null;
    const emit: CmdPayload = .{ .emit = .{ .reply = reply, .kind = kind, .completion = chosen, .query = query } };
    app_commands.request(tables.memory, tables, .{ .action_palette = emit });
}

/// Ends the open prompt, its owner hearing `completed` with `completion` and the text typed.
fn completeRequest(tables: *Table.Registry, s: State, completion: ?*const Completion) void {
    const palette = paletteTable(tables);
    queueEvent(tables, replyOf(palette, s), .completed, completion, textOf(palette, s));
    clearRequest(s);
}

fn clearRequest(s: State) void {
    s.request_open.* = 0;
    s.request_owner.* = none_owner;
    s.completions_ptr.* = 0;
    clearReply(s);
    resetPrompt(s);
}

// ---- the palette's system ---------------------------------------------------------------------

/// The palette's keys, clicks and text editor reports: first of the editor's systems, as the
/// editor handled them before any module ran. They were meant for the prompt open then, whose
/// completions a requester may rebuild in place later in the frame, before replacing them.
pub fn inputSystem() sequencer.System {
    return .{
        .name = "action_palette_input",
        .root = action_palette_root,
        .claims = claims,
        .access = inputAccess,
        .kernels = &.{
            .{ .name = "action_palette.take_messages", .run = takeMessages },
            .{ .name = "action_palette.follow_editors", .run = followEditors },
        },
    };
}

/// The prompt's text as its text editor's changes tell it, and the echo as those of
/// `*Messages*` do.
fn followEditors(pass: *sequencer.Pass) !void {
    var events: [shared.events_max]plugin_api.text_editor_api.Event = undefined;
    const taken = try shared.readEvents(pass, Atom.from(inputSystem().name), &events);
    for (taken) |event| {
        const change = switch (event) {
            .changed => |change| change,
            else => continue,
        };
        if (change.buffer == messages_buffer) {
            const s = try pass.writeSingleton(state_table, State);
            // The caret moving in `*Messages*` tells nothing new.
            if (s.echo_revision.* == change.revision) continue;
            s.echo_revision.* = change.revision;
            takeEcho(pass.frame.tables, s);
            continue;
        }
        if (change.buffer != text_editor_name) continue;
        const s = try pass.writeSingleton(state_table, State);
        s.editor_serial.* = change.serial;
        const text = try shared.textOf(pass.frame.tables, text_editor_name);
        onEditorText(s, text, pass.frame.tables);
    }
}

/// The most of a message the echo keeps: more than a line of the window shows.
const kEchoBytes: usize = 512;

/// Takes the newest line of `*Messages*` as the echo, unless a prompt is open: the line is
/// then the prompt's, and what was told meanwhile is read in `*Messages*`.
fn takeEcho(tables: *Table.Registry, s: State) void {
    if (s.request_open.* != 0) return;
    const view = plugin_api.text_editor_api.viewOf(tables, messages_buffer) orelse return;
    // The buffer ends with a line's ending, so its last line is empty.
    var line = view.lineCount();
    while (line > 0) {
        line -= 1;
        const start = view.lineStart(line);
        const end = view.lineEnd(line);
        if (end == start) continue;
        var kept: [kEchoBytes]u8 = undefined;
        const wanted = @min(end - start, kEchoBytes);
        // A line cut short ends on a whole character: not before a continuation byte.
        var kept_len: u32 = @intCast(wanted);
        while (kept_len > 0 and kept_len < end - start and (view.byteAt(start + kept_len) & 0xC0) == 0x80) kept_len -= 1;
        const newest = view.copyRange(start, kept[0..kept_len]);
        paletteTable(tables).assignString(s.echo, newest) catch |err| {
            Log.err("echo_refused", .{ .bytes = newest.len, .@"error" = @errorName(err) });
        };
        return;
    }
    s.echo.* = .{};
}

/// While a prompt is open, its keys and typing, and with none the key that ends an echo, for
/// the input system's inbox. Last of the editor's systems, so a prompt opened this frame hears
/// the next frame's keys.
fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    if (!pass.writes(editor_sequencer.InputSubscriber.table)) return;
    const inputs = editor_sequencer.InputSubscriber.of(pass, inputSystem());
    if (currentCompletions(tables, pass.frame.atoms) == null) {
        // With no prompt, an echo on the line hears the next key, which takes it away. The
        // key still goes wherever it was going.
        const observed = try pass.readSingleton(state_table, State);
        if (observed.echo.payload.len != 0) inputs.push(.{ .key_input = .{ .scope = .global, .tag = echo_key_tag } }, .none);
        return;
    }
    subscribeInput(tables, pass.frame.atoms, inputs);
}

/// The frame's requests, the room the panels leave the minibuffer, then the text editor kept
/// loaded with the open prompt's text: last of the editor's systems, after every module that presents prompts, so the requests of one
/// frame are taken together and the prompt they leave open draws this frame.
pub fn system() sequencer.System {
    return .{
        .name = "action_palette",
        .root = action_palette_root,
        .claims = sequencer.claims_nothing,
        .access = access,
        .kernels = &.{
            .{ .name = "action_palette.take_requests", .run = takeRequests },
            .{ .name = "action_palette.clamp_selection", .run = clampSelection },
            .{ .name = "action_palette.follow_modes", .run = followModes },
            .{ .name = "action_palette.follow_keys", .run = followKeys },
            .{ .name = "action_palette.place", .run = place },
            .{ .name = "action_palette.update_editor", .run = updateEditor },
            .{ .name = "action_palette.subscribe", .run = subscribe },
        },
    };
}

const state_table = Atom.from(table_name);
const requests_table = Atom.from(requests_table_name);
const delivery_table = Atom.from(delivery_table_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);
const messages_buffer = plugin_api.text_editor_api.messages_buffer;
const chords_table = Atom.from(plugin_api.action_api.chord_state_table);
const bindings_table = Atom.from(plugin_api.action_api.bindings_table_name);
const time_subscriptions = Atom.from(mesha.time.subscriptions_table_name);
/// A frame's time while a key sequence waits for its hints.
const key_frame_tag = Atom.from("action_palette_key_frame");
/// A key pressed while the line shows an echo, which goes at the next key as Emacs's does.
const echo_key_tag = Atom.from("action_palette_echo_key");

fn inputAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.write(state_table);
    shared.declareEvents(&result, frame.tables, text_editor_name);
    // The echo is the newest line of `*Messages*`.
    plugin_api.text_editor_api.declareBuffer(&result, frame.tables, messages_buffer);
    // Typing, submitting and loading the prompt ask its text editor.
    result.writeIfPresent(frame.tables, Atom.from(plugin_api.text_editor_api.commands_table_name));
    // Answers to the prompt's owner go through the editor's hook.
    result.writeIfPresent(frame.tables, Atom.from(app_commands.commands_table_name));
    return result;
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    // Every run subscribes again: its run replaces what it subscribed to before.
    result.writeIfPresent(frame.tables, editor_sequencer.InputSubscriber.table);
    // The open prompt's modes, and those it found, which it asks for again as it closes.
    modes.declarePromptModes(&result, frame.tables, prompt_modes_table_name);
    result.read(delivery_table);
    result.write(state_table);
    result.write(requests_table);
    // The line tells of a key sequence's keys, and after a wait of what they lead to.
    const keys_known = frame.tables.findByName(chords_table) != null and frame.tables.findByName(bindings_table) != null;
    if (keys_known) {
        result.readAll(&.{ chords_table, bindings_table });
        result.writeIfPresent(frame.tables, time_subscriptions);
        if (frame.tables.findByName(shared.settings_table) != null) result.read(shared.settings_table);
    }
    // The panels shown make room for the minibuffer's line.
    if (frame.tables.findByName(panel_nodes_table) != null) {
        result.readAll(&.{ panel_nodes_table, panel_state_table });
        result.writeIfPresent(frame.tables, Atom.from(plugin_api.panels.commands_table_name));
    }
    // Typing, submitting and loading the prompt ask its text editor.
    result.writeIfPresent(frame.tables, Atom.from(plugin_api.text_editor_api.commands_table_name));
    // Answers to the prompt's owner go through the editor's hook.
    result.writeIfPresent(frame.tables, Atom.from(app_commands.commands_table_name));
    return result;
}

const prompt_tags = [_]Atom{ Msg.char, Msg.left, Msg.right, Msg.up, Msg.down, Msg.submit, Msg.cancel, Msg.consume, Msg.invoke, scroll_tag };
const prompt_action_tags = plugin_api.action_api.tags(&prompt_actions);
const text_editor_tags = [_]Atom{ shared.command_tag, shared.save_tag, shared.leave_tag };

fn claims(tag: Atom) bool {
    if (tag == echo_key_tag) return true;
    if (std.mem.indexOfScalar(Atom, &prompt_tags, tag) != null) return true;
    if (std.mem.indexOfScalar(Atom, &prompt_action_tags, tag) != null) return true;
    return std.mem.indexOfScalar(Atom, &text_editor_tags, tag) != null;
}

/// The frame's keys, clicks and text editor reports, at the prompt that was open.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const s = try pass.writeSingleton(state_table, State);
    for (frame.messages) |received| {
        if (received.tag == echo_key_tag) {
            // What a key's own command tells is taken after it, from `*Messages*`.
            s.echo.* = .{};
            continue;
        }
        const is_key = std.mem.indexOfScalar(Atom, &prompt_tags, received.tag) != null;
        if (is_key) {
            takeKey(frame.tables, s, received) catch |err| received.unreadable(err);
        } else {
            takeAction(frame.tables, s, received) catch |err| received.unreadable(err);
        }
    }
}

const Taking = struct {
    s: State,
    memory: *memory_mod.Memory,
    tables: *Table.Registry,
    held_responses: u32,
    /// The prompt that opened this frame; any other presented this frame lost to it.
    opened: ?Presented = null,

    const Presented = struct { completions: *const Completions, reply: sequencer.ReplyTo };

    fn apply(taking: *Taking, wanted: *const Request) !void {
        const s = taking.s;
        switch (wanted.*) {
            .present => |presenting| try taking.present(presenting.completions, presenting.reply, presenting.mode),
            .replace => |replacement| {
                if (s.request_open.* == 0) return;
                s.request_owner.* = replacement.completions.owner;
                s.request_presentation.* = @intFromEnum(replacement.completions.presentation);
                s.completions_ptr.* = @intFromPtr(replacement.completions);
                s.request_takes_text.* = @intFromBool(replacement.completions.presentation.takesText());
                // Listed anew for the text Tab made: the entry it was made from stays selected.
                const palette = paletteTable(taking.tables);
                if (followsTab(palette, s)) selectCompleted(palette, s, replacement.completions);
            },
            .dismiss => {
                if (s.request_open.* == 0) return;
                // A dismissed prompt's owner hears nothing typed, as a replaced one's does.
                queueEvent(taking.tables, replyOf(paletteTable(taking.tables), s), .completed, null, "");
                clearRequest(s);
            },
            .cancel => |cancelling| {
                if (s.request_open.* == 0 or s.request_owner.* != cancelling.owner) return;
                completeRequest(taking.tables, s, null);
                s.cancelled_owner.* = cancelling.owner;
            },
            .acknowledge => |acknowledging| {
                if (s.cancelled_owner.* == acknowledging.owner) s.cancelled_owner.* = none_owner;
            },
            .note => |noting| try paletteTable(taking.tables).assignString(s.key_note, noting.text),
        }
    }

    fn present(taking: *Taking, completions: *const Completions, reply: sequencer.ReplyTo, mode: Atom) !void {
        const s = taking.s;
        const palette = paletteTable(taking.tables);
        if (taking.opened) |opened| {
            logConflict(opened, completions, reply);
            refuse(taking.tables, reply);
            return;
        }
        if (refusal(s, taking.held_responses)) |reason| {
            Log.warn("present_refused", .{
                .reason = @tagName(reason),
                .owner = completions.owner,
                .presentation = @tagName(completions.presentation),
                .title = completions.title,
                .prompt = completions.prompt,
                .reply_tag = reply.tag,
                .cancelled_owner = s.cancelled_owner.*,
                .held_responses = taking.held_responses,
            });
            refuse(taking.tables, reply);
            return;
        }
        taking.opened = .{ .completions = completions, .reply = reply };
        Log.trace("present", .{ .reply_tag = reply.tag });
        const same_request = s.request_open.* != 0 and s.completions_ptr.* == @intFromPtr(completions) and
            replyOf(palette, s).eql(reply);
        if (same_request) return;
        if (s.request_open.* != 0) {
            // The replaced prompt's owner hears nothing typed: the text was for its prompt.
            queueEvent(taking.tables, replyOf(palette, s), .completed, null, "");
        }
        s.request_open.* = 1;
        s.request_owner.* = completions.owner;
        s.request_presentation.* = @intFromEnum(completions.presentation);
        s.request_mode.* = mode;
        s.completions_ptr.* = @intFromPtr(completions);
        try setReply(palette, s, reply);
        resetPrompt(s);
        // The line is the prompt's now, as Emacs's minibuffer takes the echo area.
        s.echo.* = .{};
        // A new request: the text editor it names loads its text afresh.
        s.request_serial.* +%= 1;
        s.editor_submit_pending.* = 0;
        s.request_takes_text.* = @intFromBool(completions.presentation.takesText());
        if (completions.presentation == .dialog) s.selected.* = completions.default_entry orelse std.math.maxInt(u32);
        setText(paletteTable(taking.tables), s, completions.initial_query);
        const replaces_seed = completions.initial_query_edit == .replace;
        s.text_selected.* = @intFromBool(completions.presentation.takesText() and s.text.payload.len != 0 and replaces_seed);
    }

    /// A refused prompt's owner hears `completed` with nothing chosen, as for a cancel.
    fn refuse(tables: *Table.Registry, reply: sequencer.ReplyTo) void {
        queueEvent(tables, reply, .completed, null, "");
    }

    /// Both prompts in full, so that whoever reads the log can tell which modules presented
    /// at once, and why.
    fn logConflict(opened: Presented, refused: *const Completions, refused_reply: sequencer.ReplyTo) void {
        Log.warn("present_conflict", .{
            .opened_owner = opened.completions.owner,
            .opened_presentation = @tagName(opened.completions.presentation),
            .opened_title = opened.completions.title,
            .opened_prompt = opened.completions.prompt,
            .opened_entries = opened.completions.entries.len,
            .opened_reply_tag = opened.reply.tag,
            .refused_owner = refused.owner,
            .refused_presentation = @tagName(refused.presentation),
            .refused_title = refused.title,
            .refused_prompt = refused.prompt,
            .refused_entries = refused.entries.len,
            .refused_reply_tag = refused_reply.tag,
        });
    }
};

/// The palette's modes, `<owner>_prompt_modes`: see `modes.followPrompt`.
pub const prompt_modes_table_name = "action_palette_prompt_modes";

/// The palette opens every prompt, whoever presents it, so it asks for the open prompt's modes,
/// and as the prompt closes for those it found, after the frame's requests opened or closed it
/// and after its keys did.
fn followModes(pass: *sequencer.Pass) !void {
    const s = try pass.readSingleton(state_table, State);
    const major = if (s.request_open.* != 0) s.request_mode.* else plugin_api.action_api.no_mode;
    try modes.followPrompt(pass, prompt_modes_table_name, major);
}

/// The frame's requests, in the order appended.
fn takeRequests(pass: *sequencer.Pass) !void {
    const requests = Requests.of(pass.frame.memory, pass.frame.tables, requests_table_name);
    if (requests.count() == 0) return;
    const held = try pass.readSingleton(delivery_table, Delivery);
    var taking: Taking = .{
        .s = try pass.writeSingleton(state_table, State),
        .memory = pass.frame.memory,
        .tables = pass.frame.tables,
        .held_responses = held.held_responses.*,
    };
    try requests.take(pass, &taking, Taking.apply);
}

// ---- the minibuffer --------------------------------------------------------------------------
//
// The palette draws as Emacs's minibuffer does: a line along the window's bottom, always there,
// which the panels leave room for and a prompt's text is typed in. What a prompt offers, its
// completions or a dialog's buttons, opens above the line, over the panels, which keep their
// sizes. A stage alone in the window keeps all of it: the line shows only while a prompt is
// open, over the stage.

/// The room the panels leave the minibuffer's line: none for a stage alone in the window, or
/// without the panels, as in a headless run.
fn lineRoom(tables: *Table.Registry, atoms: *Atom.Registry) f32 {
    if (tables.findByName(panel_nodes_table) == null) return 0;
    var shown_buffer: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
    const shown = panels_mod.panels(tables, atoms, &shown_buffer);
    const lone_stage = shown.len == 1 and !panel_frame.wearsHeader(tables, atoms, shown[0].id);
    return if (lone_stage) 0 else kMinibufferHeight;
}

/// Each frame: asks the panels for the line's room, when the panels shown change it.
fn place(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const observed = try pass.readSingleton(state_table, State);
    const wanted = lineRoom(tables, pass.frame.atoms);
    if (observed.reserved.* == wanted) return;
    const s = try pass.writeSingleton(state_table, State);
    s.reserved.* = wanted;
    plugin_api.panels.request(tables.memory, tables, .{ .reserve_bottom = .{ .height = wanted } });
}

fn resetPrompt(s: State) void {
    s.text.* = .{};
    s.cursor.* = 0;
    s.selected.* = 0;
    forgetTab(s);
}

/// After the frame's requests: keeps a prompt's selection on one of its entries, which its
/// owner may have listed fewer of, so the minibuffer draws it as it is (`shownSelection`).
fn clampSelection(pass: *sequencer.Pass) !void {
    const observed = try pass.readSingleton(state_table, State);
    const completions = completionsOf(observed) orelse return;
    const wanted = shownSelection(observed.selected.*, completions);
    if (wanted == observed.selected.*) return;
    const s = try pass.writeSingleton(state_table, State);
    s.selected.* = wanted;
}

/// The entry `selected` stands for among `completions`' entries: a dialog's as it is, which
/// may be none; a prompt's at most its last, and 0 when it lists none.
fn shownSelection(selected: u32, completions: *const Completions) u32 {
    if (completions.presentation == .dialog) return selected;
    if (completions.entries.len == 0) return 0;
    const last: u32 = @intCast(completions.entries.len - 1);
    return @min(selected, last);
}

fn deleteSelectedText(s: State) void {
    if (s.text_selected.* == 0) return;
    s.text_selected.* = 0;
    s.text.* = .{};
    s.cursor.* = 0;
}

/// Tells whether an edit changed the text, without copying text of any length to compare.
const TextFingerprint = struct { len: u32, hash: u64 };

fn textFingerprint(palette: *const Table, s: State) TextFingerprint {
    const text = textOf(palette, s);
    return .{ .len = @intCast(text.len), .hash = std.hash.Wyhash.hash(0, text) };
}

/// After an edit of the text: tells the owner if it changed. A changed text selects the first
/// entry, or, when Tab made it, the entry Tab made it from.
fn finishEdit(palette: *const Table, s: State, before: TextFingerprint, tables: *Table.Registry) void {
    const after = textFingerprint(palette, s);
    if (std.meta.eql(before, after)) return;
    s.selected.* = 0;
    const completions = completionsOf(s);
    if (followsTab(palette, s)) {
        s.tab_typing.* = 0;
        if (completions) |listed| selectCompleted(palette, s, listed);
    } else if (s.tab_typing.* == 0) {
        forgetTab(s);
    }
    queueEvent(tables, replyOf(palette, s), .query_changed, null, textOf(palette, s));
}

/// A key or click at the open prompt. The inbox holds what arrived since the last run, all of
/// it for the prompt open then: a key for no open prompt is dropped.
fn takeKey(tables: *Table.Registry, s: State, received: sequencer.Message) !void {
    const tag = received.tag;
    const completions = completionsOf(s) orelse return;
    if (tag == scroll_tag) {
        if (!completions.presentation.takesText()) return;
        const event = try received.payloadAs(input.MouseScrollMsg);
        s.selected.* = @import("figure/list_navigation.zig").wheel(s.selected.*, event.y, completions.entries.len -| 1);
        forgetTab(s);
        return;
    }
    if (tag == Msg.cancel) return completeRequest(tables, s, null);
    if (tag == Msg.consume) return;
    if (tag == Msg.invoke) {
        const payload = try received.userDataAs(CompletionPayload);
        if (payload.index < completions.entries.len) completeRequest(tables, s, &completions.entries[payload.index]);
        return;
    }
    if (completions.presentation == .dialog) {
        if (completions.entries.len == 0) return;
        const last: u32 = @intCast(completions.entries.len - 1);
        if (tag == Msg.up or tag == Msg.left) s.selected.* = if (s.selected.* > last) last else s.selected.* -| 1;
        if (tag == Msg.down or tag == Msg.right) s.selected.* = if (s.selected.* > last) 0 else @min(last, s.selected.* +| 1);
        if (tag == Msg.submit and s.selected.* <= last) completeRequest(tables, s, &completions.entries[s.selected.*]);
        return;
    }
    if (!completions.presentation.takesText()) return;

    if (tag == Msg.char) {
        const m = try received.payloadAs(input.TextInputMsg);
        if (m.codepoint < 32 or m.codepoint == 127) return;
        if (holdingEditor(s, completions)) |editor| {
            var bytes: [4]u8 = undefined;
            const utf8 = input.typedText(m, &bytes) orelse return;
            plugin_api.text_editor_api.request(tables.memory, tables, .{ .insert = .{ .buffer = editor, .utf8 = utf8 } });
            return;
        }
        // Typed before the editor holds the request, as when the run that opened it faulted
        // before loading it: kept here, and loaded into it with the rest.
        var bytes: [4]u8 = undefined;
        const utf8 = input.typedText(m, &bytes) orelse return;
        const palette = paletteTable(tables);
        const before = textFingerprint(palette, s);
        deleteSelectedText(s);
        insertText(palette, s, utf8);
        finishEdit(palette, s, before, tables);
        return;
    }
    if (tag == Msg.submit) requestSubmit(tables, s, completions);
}

/// Completes with the selected entry, as a submit does.
fn submitSelected(s: State, completions: *const Completions, tables: *Table.Registry) void {
    if (completions.entries.len == 0) {
        if (!completions.accepts_text) return;
        const typed: Completion = .{ .label = "" };
        return completeRequest(tables, s, &typed);
    }
    const index = @min(s.selected.*, @as(u32, @intCast(completions.entries.len - 1)));
    completeRequest(tables, s, &completions.entries[index]);
}

/// Submits now, or, while a text editor holds the text, once its report of its last text has
/// come in, so the completion carries everything typed.
fn requestSubmit(tables: *Table.Registry, s: State, completions: *const Completions) void {
    const editor = holdingEditor(s, completions) orelse return submitSelected(s, completions, tables);
    s.editor_submit_pending.* = 1;
    plugin_api.text_editor_api.request(tables.memory, tables, .{ .mark_saved = editor });
}

// ---- a request's text editor ---------------------------------------------------------------
//
// A request that takes text is edited in the palette's one text editor, which every prompt
// shares: the figure editor's fields, Alt+X, the table picker. When the request
// opens, the editor is loaded with its text, the seed selected so typing replaces it. Its
// reports bring the text back here, where the owner hears of it as before. While it has the
// keyboard its keys are the text editor's actions and the prompt's own, bound in
// `prompt_keys`, which win over the text editor's for the same chord: `prompt` inherits `text`.

/// The prompt's own actions while its text editor has the keyboard, of the mode `modes.prompt`.
pub const prompt_actions = [_]plugin_api.action_api.Def{
    .{ .name = "submit", .tag = "prompt_submit", .doc = "Accept the prompt's selected completion", .scope = .global },
    .{ .name = "cancel", .tag = "prompt_cancel", .doc = "Close the prompt without accepting", .scope = .global },
    .{ .name = "next", .tag = "prompt_next", .doc = "Select the next completion", .scope = .global },
    .{ .name = "complete", .tag = "prompt_complete", .doc = "Complete the text to the selected one", .scope = .global },
    .{ .name = "previous", .tag = "prompt_previous", .doc = "Select the previous completion", .scope = .global },
    .{ .name = "page_down", .tag = "prompt_page_down", .doc = "Select a page of completions further", .scope = .global },
    .{ .name = "page_up", .tag = "prompt_page_up", .doc = "Select a page of completions back", .scope = .global },
};

/// The keys of `prompt_actions`, the keymap of `prompt`. Moving the selection and completing
/// repeat while held; submitting and cancelling do not.
pub const prompt_keys = [_]keybinds.KeyDef{
    .{ .chord = "enter", .action = .{ "prompt", "submit" } },
    .{ .chord = "kp_enter", .action = .{ "prompt", "submit" } },
    .{ .chord = "escape", .action = .{ "prompt", "cancel" } },
    .{ .chord = "down", .action = .{ "prompt", "next" }, .trigger = .repeat },
    .{ .chord = "up", .action = .{ "prompt", "previous" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "prompt", "next" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "prompt", "previous" }, .trigger = .repeat },
    .{ .chord = "tab", .action = .{ "prompt", "complete" }, .trigger = .repeat },
    .{ .chord = "S-tab", .action = .{ "prompt", "previous" }, .trigger = .repeat },
    .{ .chord = "page_down", .action = .{ "prompt", "page_down" }, .trigger = .repeat },
    .{ .chord = "page_up", .action = .{ "prompt", "page_up" }, .trigger = .repeat },
};

/// The palette's one text editor, which holds the text of whichever request is open: the
/// figure editor's fields, Alt+X, the table picker, all of them.
pub const text_editor_name = Atom.from("prompt_text");

/// The text editor, while the open request takes text, from the palette's own record.
fn requestEditor(s: State) ?Atom {
    if (s.request_open.* == 0 or s.request_takes_text.* == 0) return null;
    return text_editor_name;
}

/// The text editor, while it holds this request's text.
fn holdingEditor(s: State, completions: *const Completions) ?Atom {
    if (!completions.presentation.takesText()) return null;
    if (s.editor_loaded_serial.* != s.request_serial.*) return null;
    return text_editor_name;
}

/// Whether a request's text editor wants the keyboard.
fn editorTakesKeys(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return requestEditor(prompt(tables, atoms)) != null;
}

/// Each frame: loads the open request's text editor, or lets the last one go. Writes the
/// palette's row only when it loads or lets go.
fn updateEditor(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const observed = try pass.readSingleton(state_table, State);
    const wanted = requestEditor(observed) orelse {
        if (observed.editor_loaded_serial.* != 0) {
            const s = try pass.writeSingleton(state_table, State);
            s.editor_loaded_serial.* = 0;
        }
        return;
    };
    if (observed.editor_loaded_serial.* != observed.request_serial.*) {
        const s = try pass.writeSingleton(state_table, State);
        // What was typed before the editor held the request is in the text here.
        plugin_api.text_editor_api.request(tables.memory, tables, .{ .set_text = .{ .buffer = wanted, .text = textOf(paletteTable(tables), s) } });
        const placement: editor_api_text.EditCommand = if (s.text_selected.* != 0) .select_all else .document_end;
        plugin_api.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = wanted, .command = placement } });
        s.text_selected.* = 0;
        s.editor_scroll_x.* = 0;
        s.editor_loaded_serial.* = s.request_serial.*;
    }
}

const editor_api_text = plugin_api.text_editor_api;

/// The request's text editor's drawing, while it holds the request's text.
pub fn editorDrawable(tables: *Table.Registry, atoms: *Atom.Registry) ?shared.FieldDrawable {
    const s = prompt(tables, atoms);
    const editor = requestEditor(s) orelse return null;
    if (s.editor_loaded_serial.* != s.request_serial.*) return null;
    const look: shared.FieldLook = .{ .text = style.col.text, .caret = style.col.accent_bright };
    return shared.fieldDrawable(tables, editor, look, s.editor_scroll_x);
}

/// Lists, while a request's text editor has the keyboard, the prompt's actions and the text
/// editor's, both capturing their keys.
pub fn pushPromptActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin_api.ActionSink) void {
    if (!editorTakesKeys(tables, atoms)) return;
    const inbox = sequencer.inboxOf(inputSystem());
    for (prompt_actions) |def| {
        keybinds.pushActionDefinitions(atoms, sink, modes.prompt, inbox, &.{.{ .def = def, .capture = true }});
    }
    shared.pushActions(atoms, sink, .captured, inputSystem());
}

/// The text editor reported its text: take it as the request's, telling the owner if it
/// changed, and finish a submit that waited for it.
fn onEditorText(s: State, text: []const u8, tables: *Table.Registry) void {
    const completions = completionsOf(s) orelse return;
    _ = holdingEditor(s, completions) orelse return;
    const palette = paletteTable(tables);
    if (!std.mem.eql(u8, text, textOf(palette, s))) {
        const before = textFingerprint(palette, s);
        setText(palette, s, text);
        finishEdit(palette, s, before, tables);
    }
    if (s.editor_submit_pending.* != 0) {
        s.editor_submit_pending.* = 0;
        submitSelected(s, completions, tables);
    }
}

/// Makes the text the selected entry's completion (`selectedEntry`, `tabTarget`); nothing when
/// the text is that already. The selection does not move: once the text is the entry's
/// completion, that entry stays selected (`selectCompleted`). The owner hears of the new text
/// as of any edit.
fn completeText(tables: *Table.Registry, s: State, completions: *const Completions) void {
    const palette = paletteTable(tables);
    const text = textOf(palette, s);
    const entry = selectedEntry(s, completions) orelse return;
    const target = tabTarget(entry);
    if (std.mem.eql(u8, text, target)) return;
    // The text's slice is the table's, which remembering may move: it is not read again.
    rememberTab(palette, s, target, entry.label);
    // The text editor holds the text: it types the completion over all of it, an edit undo
    // takes back, and its report brings the text here. Reports of earlier keys may come first.
    if (holdingEditor(s, completions)) |editor| {
        plugin_api.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = editor, .command = .select_all } });
        plugin_api.text_editor_api.request(tables.memory, tables, .{ .insert = .{ .buffer = editor, .utf8 = target } });
        return;
    }
    const before = textFingerprint(palette, s);
    setText(palette, s, target);
    finishEdit(palette, s, before, tables);
}

/// The entry Tab completes the text to: the one selected, in a prompt whose Tab completes the
/// selection; none in a dialog, or with none selected.
fn selectedEntry(s: State, completions: *const Completions) ?*const Completion {
    if (completions.tab == .nothing) return null;
    if (completions.presentation == .dialog) return null;
    if (s.selected.* >= completions.entries.len) return null;
    return &completions.entries[s.selected.*];
}

/// What Tab makes the text when `entry` is selected.
fn tabTarget(entry: *const Completion) []const u8 {
    return entry.completes_to orelse entry.label;
}

/// Keeps what Tab made the text, `text`, from the entry labelled `label`, in `palette`, the
/// palette's table. Text that cannot be kept is logged, and the selection then goes to the
/// first entry as after any edit.
fn rememberTab(palette: *Table, s: State, text: []const u8, label: []const u8) void {
    palette.assignString(s.tab_text, text) catch |err| return refuseTab(s, text.len, err);
    palette.assignString(s.tab_label, label) catch |err| return refuseTab(s, label.len, err);
    s.tab_typing.* = 1;
}

/// Logs that `bytes` of what Tab made the text could not be kept, and forgets it.
fn refuseTab(s: State, bytes: usize, err: anyerror) void {
    Log.err("tab_text_refused", .{ .bytes = bytes, .@"error" = @errorName(err) });
    forgetTab(s);
}

/// Forgets what Tab made the text: the text or the selection has moved on.
fn forgetTab(s: State) void {
    s.tab_text.* = .{};
    s.tab_label.* = .{};
    s.tab_typing.* = 0;
}

/// Whether the text is what Tab last made it, in `palette`, the palette's table.
fn followsTab(palette: *const Table, s: State) bool {
    const made = palette.textOf(s.tab_text.*);
    if (made.len == 0) return false;
    return std.mem.eql(u8, made, textOf(palette, s));
}

/// Selects the entry of `completions` Tab made the text from: the one with its label whose
/// completion the text is; the first entry when none is.
fn selectCompleted(palette: *const Table, s: State, completions: *const Completions) void {
    const text = textOf(palette, s);
    const label = palette.textOf(s.tab_label.*);
    s.selected.* = 0;
    for (completions.entries, 0..) |*entry, index| {
        if (!std.mem.eql(u8, entry.label, label)) continue;
        if (!std.mem.eql(u8, tabTarget(entry), text)) continue;
        s.selected.* = @intCast(index);
        return;
    }
}

/// Moves the completion selection by `step` entries, clamped to the list.
fn stepSelection(s: State, completions: *const Completions, step: i32) void {
    if (completions.entries.len == 0) return;
    const last: i64 = @intCast(completions.entries.len - 1);
    const current: i64 = if (s.selected.* > last) (if (step > 0) -1 else last + 1) else s.selected.*;
    s.selected.* = @intCast(std.math.clamp(current + step, 0, last));
    forgetTab(s);
}

/// The prompt's actions and the text editor's, which reach the palette while a request's
/// editor has the keyboard. An error is an edit command whose command it cannot read.
fn takeAction(tables: *Table.Registry, s: State, received: sequencer.Message) !void {
    const tag = received.tag;
    _ = requestEditor(s) orelse return;
    const completions = completionsOf(s) orelse return;
    if (tag == shared.command_tag) {
        // Until the editor holds the request, it holds something else: the key is dropped.
        const editor = holdingEditor(s, completions) orelse return;
        const command = try shared.commandOf(received);
        plugin_api.text_editor_api.request(tables.memory, tables, .{ .run = .{ .buffer = editor, .command = command } });
    } else if (tag == shared.save_tag) {
        // A prompt saves nothing.
    } else if (tag == Atom.from("prompt_submit")) {
        requestSubmit(tables, s, completions);
    } else if (tag == Atom.from("prompt_cancel") or tag == shared.leave_tag) {
        completeRequest(tables, s, null);
    } else if (tag == Atom.from("prompt_next")) {
        stepSelection(s, completions, 1);
    } else if (tag == Atom.from("prompt_complete")) {
        completeText(tables, s, completions);
    } else if (tag == Atom.from("prompt_previous")) {
        stepSelection(s, completions, -1);
    } else if (tag == Atom.from("prompt_page_down")) {
        stepSelection(s, completions, kMaxRows);
    } else if (tag == Atom.from("prompt_page_up")) {
        stepSelection(s, completions, -@as(i32, kMaxRows));
    }
}

/// The open prompt's keys and typing, for the input system's inbox.
fn subscribeInput(tables: *Table.Registry, atoms: *Atom.Registry, inputs: editor_sequencer.InputSubscriber) void {
    const completions = currentCompletions(tables, atoms) orelse return;
    if (completions.presentation.takesText()) {
        // Every other key is an action's: the text editor's and the prompt's own, listed by
        // `pushPromptActions`.
        // The palette opens over any panel, so it takes the keyboard wherever the focus is.
        inputs.push(.{ .text_input = .{
            .scope = .global,
            .capture = true,
            .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
            .tag = Msg.char,
        } }, .none);
        return;
    }
    if (completions.presentation == .dialog) {
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .up, .tag = Msg.up } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .down, .tag = Msg.down } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .left, .tag = Msg.left } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .right, .tag = Msg.right } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .tab, .modifiers = .{ .shift = .forbidden, .control = .forbidden, .alt = .forbidden, .super = .forbidden }, .tag = Msg.down } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .tab, .modifiers = .{ .shift = .required, .control = .forbidden, .alt = .forbidden, .super = .forbidden }, .tag = Msg.up } }, .none);
        inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .enter, .tag = Msg.submit } }, .none);
    }
    inputs.push(.{ .key_down = .{ .scope = .global, .capture = true, .key = .escape, .tag = Msg.cancel } }, .none);
}

/// Under an open prompt, the whole window: a click away from a prompt closes it, and from a
/// field its requester draws commits it.
// ---- the keys of a sequence -------------------------------------------------------------------
//
// A sequence of keys, as `C-x 4 f`, is the actions system's: `actions_chords` has the keys
// pressed so far. The line shows them as Emacs's echo area does, and once they have waited
// `which_key_delay_ms` for the next, the keys they lead to are listed above the line.

/// The most the line tells of a sequence: four keys with every modifier, and what follows.
const kKeyEchoBytes: usize = 128;
/// The most keys a pending sequence's hints list.
const kMaxKeyHints: usize = 96;
/// The most text the hints hold: a key and an action's name a line.
const kKeyHintBytes: usize = kMaxKeyHints * (24 + plugin_api.action_api.kMaxActionNameLen);

const KeyToken = plugin_api.action_api.KeyToken;
const Chord = plugin_api.action_api.Chord;

/// Writes `keys` as Emacs writes a sequence, a space between its keys.
fn writeKeys(writer: *std.Io.Writer, keys: []const KeyToken) std.Io.Writer.Error!void {
    for (keys, 0..) |key, index| {
        if (index != 0) try writer.writeByte(' ');
        var key_buffer: [24]u8 = undefined;
        const key_text = plugin_api.action_api.formatToken(&key_buffer, key);
        try writer.writeAll(key_text);
    }
}

/// What the line tells of the keys: the pending ones and a dash, or the sequence that led to
/// nothing; empty with neither. Cut short where `buffer` ends.
fn keyEcho(buffer: []u8, pending: ?Chord, undefined_chord: ?Chord) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (pending) |prefix| {
        writeKeys(&writer, prefix.slice()) catch return writer.buffered();
        writer.writeByte('-') catch return writer.buffered();
    } else if (undefined_chord) |sequence| {
        writeKeys(&writer, sequence.slice()) catch return writer.buffered();
        writer.writeAll(" is undefined") catch return writer.buffered();
    }
    return writer.buffered();
}

/// A key a pending sequence leads to, and what it does.
const KeyHint = struct {
    key: KeyToken,
    /// The action the key runs; null for a key that leads to more keys.
    action: ?plugin_api.action_api.ActionId,

    fn lessThan(_: void, a: KeyHint, b: KeyHint) bool {
        var a_buffer: [24]u8 = undefined;
        var b_buffer: [24]u8 = undefined;
        const a_text = plugin_api.action_api.formatToken(&a_buffer, a.key);
        const b_text = plugin_api.action_api.formatToken(&b_buffer, b.key);
        return std.mem.lessThan(u8, a_text, b_text);
    }
};

/// What a key that leads to more keys is listed as, as which-key lists one.
const kPrefixHint = "+prefix";

/// The keys `prefix` leads to among the chords bound now, each once, in `hints`: a key that ends
/// a sequence with its action, one that goes on with none. The chords are those of `bindings`,
/// the table `actions_bindings`, which the active keymaps leave.
fn gatherKeyHints(hints: []KeyHint, bindings: *Table, prefix: Chord) []KeyHint {
    var count: usize = 0;
    var rows = bindings.readQuery(plugin_api.action_api.BoundView);
    while (rows.next()) |row| {
        const chord = row.view.keys.toChord(row.view.len.*) orelse continue;
        const id: plugin_api.action_api.ActionId = .{ row.view.mode.*, row.view.name.* };
        count = addKeyHint(hints, count, prefix, chord, id);
    }
    std.mem.sort(KeyHint, hints[0..count], {}, KeyHint.lessThan);
    return hints[0..count];
}

/// Adds to the first `count` of `hints` the key `chord`, bound to `id`, leads to after `prefix`,
/// unless it is there or `hints` is full; returns how many count after.
fn addKeyHint(hints: []KeyHint, count: usize, prefix: Chord, chord: Chord, id: plugin_api.action_api.ActionId) usize {
    if (chord.len <= prefix.len) return count;
    const chord_start = Chord.of(chord.tokens[0..prefix.len]);
    if (!chord_start.eql(prefix)) return count;
    const key = chord.tokens[prefix.len];
    const ends = chord.len == prefix.len + 1;
    const ends_with: ?plugin_api.action_api.ActionId = if (ends) id else null;
    var known = false;
    for (hints[0..count]) |*hint| {
        if (!hint.key.eql(key)) continue;
        known = true;
        // A key bound both ways is listed as the action the gate runs.
        if (ends) hint.action = ends_with;
    }
    if (known or count == hints.len) return count;
    hints[count] = .{ .key = key, .action = ends_with };
    return count + 1;
}

/// Writes `hints` a line each: the key, a tab, and what it does, an action as `mode.name`.
fn writeKeyHints(buffer: []u8, atoms: *Atom.Registry, hints: []const KeyHint) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (hints) |hint| {
        var key_buffer: [24]u8 = undefined;
        const key_text = plugin_api.action_api.formatToken(&key_buffer, hint.key);
        var id_buffer: [96]u8 = undefined;
        const label = if (hint.action) |id| plugin_api.action_api.formatId(&id_buffer, atoms, id) else kPrefixHint;
        writer.print("{s}\t{s}\n", .{ key_text, label }) catch break;
    }
    return writer.buffered();
}

/// Keeps the line telling of the keys of a sequence, and lists what a pending one leads to
/// once it has waited. While it waits, the time system's frames are heard to count the wait.
fn followKeys(pass: *sequencer.Pass) !void {
    if (!pass.declares(chords_table)) return;
    const frame = pass.frame;
    const chords = try pass.readSingleton(chords_table, plugin_api.action_api.ChordStateView);
    const pending = plugin_api.action_api.pendingOf(chords);
    const undefined_chord = plugin_api.action_api.undefinedOf(chords);
    var echo_buffer: [kKeyEchoBytes]u8 = undefined;
    const wanted = keyEcho(&echo_buffer, pending, undefined_chord);

    const observed = try pass.readSingleton(state_table, State);
    const observed_cells = try pass.table(state_table);
    const shown = observed_cells.textOf(observed.key_echo.*);
    const echo_changed = !std.mem.eql(u8, shown, wanted);
    const awaits_hints = pending != null and observed.key_hints.payload.len == 0;
    if (!echo_changed and !awaits_hints) return;

    const s = try pass.writeSingleton(state_table, State);
    const palette = try pass.writeTable(state_table);
    if (echo_changed) {
        try palette.assignString(s.key_echo, wanted);
        s.key_hints.* = .{};
        s.key_wait.* = 0;
    } else {
        for (frame.messages) |received| {
            if (received.tag != key_frame_tag) continue;
            const frame_time = received.payloadAs(mesha.time.FrameMsg) catch continue;
            s.key_wait.* += frame_time.raw_dt;
        }
    }
    const prefix = pending orelse return;

    var settings: shared.Settings = .{};
    if (pass.declares(shared.settings_table)) {
        const settings_cells = try pass.table(shared.settings_table);
        const settings_row = pass.readSingleton(shared.settings_table, shared.SettingsRow) catch null;
        if (settings_row) |row| settings = shared.Settings.of(settings_cells, row);
    }
    const delay_seconds = @as(f32, @floatFromInt(settings.which_key_delay_ms)) / 1000.0;
    if (s.key_wait.* < delay_seconds) {
        if (pass.writes(time_subscriptions)) {
            _ = try pass.append(time_subscriptions, .{ .kind = mesha.time.SubscriptionKind.frame, .inbox = sequencer.inboxOf(system()), .tag = key_frame_tag });
        }
        return;
    }
    const scratch = try frame.memory.frameScratchAllocator();
    const hints_storage = try scratch.allocator.alloc(KeyHint, kMaxKeyHints);
    const bindings = try pass.table(bindings_table);
    const hints = gatherKeyHints(hints_storage, bindings, prefix);
    const text_storage = try scratch.allocator.alloc(u8, kKeyHintBytes);
    const text = writeKeyHints(text_storage, frame.atoms, hints);
    // A prefix whose keys no action offers any more still stops waiting.
    try palette.assignString(s.key_hints, if (text.len == 0) "\t\n" else text);
}

fn renderBackdrop(scratch: memory_mod.Scratch, atoms: *Atom.Registry, completions: *const Completions, screen_w: f32, screen_h: f32, offset: math.Vec2f, hovered: ?ui.ElementId, ctx: anytype, hits: *Table, depth: u32) void {
    var backdrop = ui.Tree.init(scratch, atoms, 8) catch @panic("OOM");
    const inline_field = completions.presentation == .inline_field;
    if (backdrop.beginRect("editor.action_palette.backdrop", .{ .size = .{ .w = .fill, .h = .fill } })) {
        defer backdrop.endRect();
        backdrop.onClick(editor_sequencer.to(&backdrop, inputSystem(), if (inline_field) Msg.submit else Msg.cancel, {}), .left);
    }
    backdrop.commit(.{ .root_size = .{ .x = screen_w, .y = screen_h }, .offset = offset, .hovered = hovered, .depth = depth }, ctx, hits);
}

/// The width of a column of key hints: a key and an action's name.
const kHintColumnWidth: f32 = 450;
const kHintRowHeight: f32 = 24;
const kHintKeyWidth: f32 = 120;
/// The most rows of hints: the keys past them are not listed.
const kMaxHintRows: usize = 8;

/// The keys a pending sequence leads to, down each column in turn. `hints` is a line a key:
/// the key, a tab, what it does.
fn renderKeyHints(tree: *ui.Tree, hints: []const u8, rows: usize, columns: usize) void {
    var lines = std.mem.splitScalar(u8, hints, '\n');
    if (!tree.beginRect("editor.action_palette.hints", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = @as(f32, @floatFromInt(rows)) * kHintRowHeight } }, .clip_content = true })) return;
    defer tree.endRect();
    for (0..columns) |column| {
        if (!tree.beginRect(.{ "editor.action_palette.hints.column", column }, .{ .axis = .vertical, .size = .{ .w = .{ .fixed = kHintColumnWidth }, .h = .fill } })) continue;
        defer tree.endRect();
        for (0..rows) |row| {
            const line = lines.next() orelse break;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const key_text = line[0..tab];
            const label = line[tab + 1 ..];
            if (key_text.len == 0) continue;
            const cell = column * kMaxHintRows + row;
            if (!tree.beginRect(.{ "editor.action_palette.hint", cell }, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = kHintRowHeight } }, .gap = 8 })) continue;
            defer tree.endRect();
            tree.text(.{ "editor.action_palette.hint.key", cell }, key_text, .{ .font = style.ui_font, .color = style.col.accent_bright, .size_hint = .{ .w = .{ .fixed = kHintKeyWidth }, .h = .fill } });
            const is_prefix = std.mem.eql(u8, label, kPrefixHint);
            tree.text(.{ "editor.action_palette.hint.label", cell }, label, .{ .font = style.ui_font, .color = if (is_prefix) style.col.text_dim else style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
        }
    }
}

/// The transient menu shown, while the line shows no prompt or the prompt reading a value for
/// the menu, `presented`.
fn shownMenu(tables: *Table.Registry, presented: ?*const Completions) ?transient.Shown {
    if (presented) |completions| {
        if (completions.owner != transient.value_prompt_owner) return null;
    }
    return transient.shown(tables);
}

/// The minibuffer's line, and above it what `presented`, the prompt it shows, offers, or a
/// transient menu shown; with neither the line is the echo area, and above it are the keys a
/// pending sequence leads to.
fn renderMinibuffer(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, presented: ?*const Completions, screen_w: f32, screen_h: f32, offset: math.Vec2f, hovered: ?ui.ElementId, ctx: anytype, hits: *Table, depth: u32) void {
    const s = prompt(tables, atoms);
    const dialog = if (presented) |completions| completions.presentation == .dialog else false;
    const entries: []const Completion = if (presented) |completions| completions.entries else &.{};
    const body: []const u8 = if (presented) |completions| completions.body else "";
    const body_height: f32 = if (body.len > 0) kBodyHeight else 0;

    // A prompt lists the completions that fit above the line; a dialog's buttons share a row.
    var row_capacity: usize = kMaxRows;
    if (!dialog) {
        const body_section: f32 = if (body_height > 0) body_height + kSectionGap else 0;
        const list_room = screen_h * kMaxWindowShare - kMinibufferHeight - 2 * kSectionPadding - body_section;
        const rows_fitting = @floor(@max(list_room, 0) / kRowHeight);
        row_capacity = @intFromFloat(@min(rows_fitting, @as(f32, @floatFromInt(kMaxRows))));
    }
    const shown_len: usize = @min(entries.len, row_capacity);
    // The palette's run keeps the selection on an entry (`clampSelection`); drawing only reads it.
    const selected: u32 = if (presented) |completions| shownSelection(s.selected.*, completions) else 0;
    const start: usize = if (!dialog and row_capacity > 0 and selected >= row_capacity) @as(usize, selected) - (row_capacity - 1) else 0;
    // A transient menu shown takes the place of what a prompt offers, over the line while no
    // prompt is open or while the prompt reads a value for the menu.
    const menu_shown = shownMenu(tables, presented);
    var menu_height: f32 = 0;
    if (menu_shown) |menu| {
        // A line of the menu's font is as tall as the font's pixel height, whatever its text.
        const line_height = ctx.measureText(transient.menu_style.font, " ").h;
        menu_height = ui.transient.height(menu.menu, line_height);
    }
    // With no prompt open, a key sequence that has waited lists what its keys lead to, in
    // columns as which-key does.
    const hints_text: []const u8 = if (presented == null and menu_shown == null) paletteTable(tables).textOf(s.key_hints.*) else "";
    const hint_count = std.mem.count(u8, hints_text, "\n");
    const hint_columns: usize = @max(1, @as(usize, @intFromFloat(@max(screen_w - 2 * kSectionPadding, 0) / kHintColumnWidth)));
    const hint_rows: usize = @min(kMaxHintRows, (hint_count + hint_columns - 1) / hint_columns);
    const hints_height: f32 = @as(f32, @floatFromInt(hint_rows)) * kHintRowHeight;

    const offered_height: f32 = if (dialog) kRowHeight else @as(f32, @floatFromInt(shown_len)) * kRowHeight;
    const parts_gap: f32 = if (body_height > 0 and offered_height > 0) kSectionGap else 0;
    const content_height = body_height + parts_gap + offered_height + hints_height + menu_height;
    const section_height: f32 = if (content_height > 0) content_height + 2 * kSectionPadding else 0;
    const height = @min(section_height + kMinibufferHeight, screen_h);
    if (screen_w <= 0 or height <= 0) return;

    const menu_elements: usize = if (menu_shown) |menu| ui.transient.elementCount(menu.menu) else 0;
    const max_cmds: usize = 64 + (shown_len + 4) * 8 + hint_rows * hint_columns * 8 + menu_elements;
    var tree = ui.Tree.init(scratch, atoms, max_cmds) catch @panic("OOM");
    if (tree.beginRect("editor.action_palette.root", .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .fill },
        .bg = style.col.sidebar,
        .border = style.col.border,
        .border_size = 1,
        .clip_content = true,
    })) {
        defer tree.endRect();
        tree.onClick(editor_sequencer.to(&tree, inputSystem(), Msg.consume, {}), .left);
        tree.onScroll(editor_sequencer.to(&tree, inputSystem(), scroll_tag, {}));
        if (section_height > 0 and tree.beginRect("editor.action_palette.offered", .{
            .axis = .vertical,
            .size = .{ .w = .fill, .h = .{ .fixed = section_height } },
            .padding = kSectionPadding,
            .gap = kSectionGap,
            .clip_content = true,
        })) {
            defer tree.endRect();
            if (body_height > 0)
                tree.text("editor.action_palette.body", body, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .fill, .h = .{ .fixed = body_height } } });
            if (dialog) {
                if (tree.beginRect("editor.action_palette.actions", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = kRowHeight } }, .gap = 8 })) {
                    defer tree.endRect();
                    for (entries[0..shown_len], 0..) |entry, i| {
                        const salt = std.hash.Wyhash.hash(@intCast(i), entry.label);
                        const id = tree.toElementId(.{ "editor.action_palette.action", salt });
                        if (tree.beginRect(id, .{
                            .axis = .horizontal,
                            .cross_align = .center,
                            .main_align = .center,
                            .size = .{ .w = .{ .fixed = kButtonWidth }, .h = .fill },
                            .bg = if (i == selected) style.col.accent_deep else style.col.button,
                            .bg_hover = if (i == selected) style.col.accent_deep else style.col.button_hover,
                            .padding = 4,
                            .corner_radius = style.metric.button_radius,
                            .clip_content = true,
                        })) {
                            defer tree.endRect();
                            tree.onClick(editor_sequencer.to(&tree, inputSystem(), Msg.invoke, CompletionPayload{ .index = @intCast(i) }), .left);
                            tree.trackHover("");
                            tree.text(.{ "editor.action_palette.action.text", salt }, entry.label, .{ .font = style.ui_font, .color = style.col.text });
                        }
                    }
                }
            } else if (menu_shown) |menu| {
                ui.transient.record(&tree, menu.menu, menu.state, transient.menu_style);
            } else if (hint_rows > 0) {
                renderKeyHints(&tree, hints_text, hint_rows, hint_columns);
            } else if (shown_len > 0 and tree.beginRect("editor.action_palette.list", .{ .size = .{ .w = .fill, .h = .{ .fixed = offered_height } }, .clip_content = true })) {
                defer tree.endRect();
                for (entries[start..][0..shown_len], 0..) |entry, i| {
                    const index = start + i;
                    const is_selected = index == selected;
                    const salt = std.hash.Wyhash.hash(@intCast(index), entry.label);
                    const id = tree.toElementId(.{ "editor.action_palette.entry", salt });
                    if (tree.beginRect(id, .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = kRowHeight } }, .bg = if (is_selected) style.col.accent_deep else null, .bg_hover = style.col.card_hover, .corner_radius = 4, .padding = 8, .gap = 8, .clip_content = true })) {
                        defer tree.endRect();
                        tree.onClick(editor_sequencer.to(&tree, inputSystem(), Msg.invoke, CompletionPayload{ .index = @intCast(index) }), .left);
                        tree.trackHover("");
                        tree.text(.{ "editor.action_palette.entry.label", salt }, entry.label, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
                        if (entry.detail.len > 0)
                            tree.text(.{ "editor.action_palette.entry.detail", salt }, entry.detail, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .{ .fixed = kDetailColWidth }, .h = .fill } });
                        if (entry.key.len > 0)
                            tree.text(.{ "editor.action_palette.entry.key", salt }, entry.key, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .{ .fixed = kKeyColWidth }, .h = .fill } });
                    }
                }
            }
        }
        // The line is flat, as Emacs's is: the caret says where typing goes.
        const line_frame: ui.RectParams = .{
            .axis = .horizontal,
            .cross_align = .center,
            .size = .{ .w = .fill, .h = .{ .fixed = kMinibufferHeight } },
            .padding = 8,
            .gap = 4,
            .clip_content = true,
        };
        if (tree.beginRect("editor.action_palette.line", line_frame)) {
            defer tree.endRect();
            if (presented) |completions| {
                if (dialog) {
                    tree.text("editor.action_palette.line.title", if (completions.title.len > 0) completions.title else " ", .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
                } else {
                    if (completions.prompt.len > 0)
                        tree.text("editor.action_palette.line.label", completions.prompt, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .h = .fill } });
                    const empty = s.text.payload.len == 0;
                    const placeholder = empty and completions.title.len > 0;
                    if (editorDrawable(tables, atoms)) |editor| {
                        // The request's text editor draws the text, caret and selection.
                        const drawable = scratch.allocator.create(shared.FieldDrawable) catch @panic("OOM");
                        drawable.* = editor;
                        tree.custom("editor.action_palette.line.editor", drawable, .{ .size = .{ .w = .fill, .h = .fill } });
                    } else if (s.text_selected.* != 0) {
                        if (tree.beginRect("editor.action_palette.line.selection", .{ .axis = .horizontal, .cross_align = .center, .bg = style.col.accent_deep })) {
                            defer tree.endRect();
                            tree.text("editor.action_palette.line.text", textOf(paletteTable(tables), s), .{ .font = style.ui_font, .color = style.col.text });
                        }
                    } else {
                        tree.text("editor.action_palette.line.text", if (!empty) textOf(paletteTable(tables), s) else if (placeholder) completions.title else " ", .{
                            .font = style.ui_font,
                            .color = if (placeholder) style.col.text_dim else style.col.text,
                            .size_hint = .{ .w = .fill, .h = .fill },
                        });
                        tree.cursor("editor.action_palette.line.cursor", if (placeholder) 0 else s.cursor.*, .{ .bg = style.col.accent_bright });
                    }
                }
            } else if (s.key_echo.payload.len != 0 or s.key_note.payload.len != 0) {
                // A count's note and the sequence that follows it read as one line of keys.
                const palette = paletteTable(tables);
                const key_note = palette.textOf(s.key_note.*);
                const key_echo = palette.textOf(s.key_echo.*);
                const separator: []const u8 = if (key_note.len != 0 and key_echo.len != 0) " " else "";
                const keys = std.fmt.allocPrint(scratch.allocator, "{s}{s}{s}", .{ key_note, separator, key_echo }) catch key_echo;
                tree.text("editor.action_palette.line.keys", keys, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
            } else if (s.echo.payload.len != 0) {
                const echo = paletteTable(tables).textOf(s.echo.*);
                tree.text("editor.action_palette.line.echo", echo, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .fill } });
            }
        }
    }
    tree.commit(.{ .root_size = .{ .x = screen_w, .y = height }, .origin = .{ .x = 0, .y = screen_h - height }, .offset = offset, .hovered = hovered, .depth = depth + 1 }, ctx, hits);
}

/// Drawn in the action palette's own layer, over the whole window: `screen_w` and `screen_h` are
/// the window's, and `offset` places hit regions in it. The minibuffer's line draws wherever
/// the panels left it room, and over a stage alone only while a prompt or a transient menu is
/// open.
pub fn render(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, screen_w: f32, screen_h: f32, offset: math.Vec2f, hovered: ?ui.ElementId, ctx: anytype, hits: *Table, depth: u32) void {
    const open = currentCompletions(tables, atoms);
    if (open) |completions| renderBackdrop(scratch, atoms, completions, screen_w, screen_h, offset, hovered, ctx, hits, depth);
    // A field its requester draws shows nothing in the minibuffer.
    var presented = open;
    if (open) |completions| {
        if (completions.presentation == .inline_field) presented = null;
    }
    const line_has_room = prompt(tables, atoms).reserved.* > 0;
    const menu_shown = transient.shown(tables) != null;
    if (presented == null and !line_has_room and !menu_shown) return;
    renderMinibuffer(scratch, tables, atoms, presented, screen_w, screen_h, offset, hovered, ctx, hits, depth);
}

pub fn prepareInit(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Requests.ensure(scratch, atoms, tables, requests_table_name);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, state_field_count);
    defer schema.deinit();
    try stateSchema(&schema);
    _ = try state.prepareSingletonSchema(tables, &schema, atoms.intern(table_name), defaults, .durable);
    try modes.ensurePromptModes(scratch, atoms, tables, prompt_modes_table_name);
    var delivery_schema: Table.Schema = undefined;
    try delivery_schema.init(scratch.allocator, atoms, 1);
    defer delivery_schema.deinit();
    try deliverySchema(&delivery_schema);
    _ = try state.prepareSingletonSchema(tables, &delivery_schema, atoms.intern(delivery_table_name), delivery_defaults, .durable);
}
