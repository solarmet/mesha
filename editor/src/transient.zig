//! The editor's transient menus (`mesha.ui.transient`: keys, switches and values shown at the
//! bottom of the frame): any editor system presents a menu (`present`), which shows above the
//! minibuffer's line, where the keys of a pending sequence are listed, and takes every key while it
//! is shown. One menu is shown at a time.
//!
//! Each typed character goes to `ui.transient.press`. A switch flips and the menu draws again; an
//! option reads its value in a palette prompt with the option's label, its current value the
//! text, the menu staying shown under it and taking the keys back once it closes; a command, or
//! an item that leads to another menu, closes the menu and answers the presenter with a `Chosen`
//! (the item's id and what the menu was set to), and the presenter presents the next menu itself.
//! `C-g` and Escape close the menu and answer `cancelled`, and so does `q` unless a key of the
//! menu begins with `q`. A key that reaches no item, or any key that types nothing but those
//! (one with Control, Alt or Super held, RET, an arrow), is told on the message line as the
//! minibuffer's line writes a sequence of keys (`- x is not bound in Log`) and the menu stays.
//! A palette prompt another system opens over the menu closes it, `cancelled`.
//!
//! While a menu is shown the editor's modes are `transient`'s, kept and restored as a prompt's
//! are (`modes.followPrompt`); the keys are this system's own capturing subscriptions, so
//! nothing reaches the panel under the menu. The menu and its state are kept in the singleton
//! `editor_transient`, which the action palette's drawing reads (`shown`).
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const sequencer = mesha.sequencer;
const input = mesha.input;
const plugin = mesha.plugin;
const transient_menu = ui.transient;
const action_palette = @import("action_palette.zig");
const editor_sequencer = @import("editor_sequencer.zig");
const modes = @import("modes.zig");
const shared = @import("text_editor.zig");
const style = @import("ui/style.zig");
const Log = mesha.log.scope("editor_transient");

const Msg = enum(u64) {
    /// A key pressed while the menu is shown, a `KeyInputMsg`.
    transient_key = Atom.from("transient_key").value(),
    /// A character typed while the menu is shown, a `TextInputMsg`.
    transient_char = Atom.from("transient_char").value(),
    /// The events of the palette's prompt that reads an option's value.
    transient_value = Atom.from("transient_value").value(),
    _,
};

/// What a presenter hears as its menu closes: the item chosen, or that the menu was cancelled
/// (closed with `C-g`, Escape or `q`, replaced by another menu, refused, or lost to a reload of
/// the editor). It travels between the editor's own systems, which one image builds, so it is no
/// part of what the host and a plugin share (`plugin.boundary_roots`).
pub const Chosen = extern struct {
    /// The id of the command or menu item chosen; 0 when cancelled.
    id: u32,
    /// 1 when the menu closed with nothing chosen, else 0.
    cancelled: u8,
    /// Zero, so the answer's bytes are all set.
    reserved: [3]u8 = @splat(0),
    /// What the menu's switches and options were set to as it closed, no key pending: the
    /// presenter reads it with `ui.transient.isOn`, `valueOf` and `writeArguments` against the
    /// menu it presented.
    state: transient_menu.State,
};

/// A request to show a menu: a row of `commands.editor_transient`.
pub const Request = union(enum) {
    /// Shows `menu`, set as `state` says, and answers `reply` with a `Chosen` as it closes.
    present: Presenting,
};

/// A menu to show, what it starts set to and where the answer goes.
pub const Presenting = struct {
    /// The presenter's constant: it must outlive the menu's showing. Its address is kept in a
    /// table while the menu is shown, and an image of the editor loaded again finds it gone: as
    /// the editor initialises, a menu shown is closed unread and its presenter hears `cancelled`.
    menu: *const transient_menu.Menu,
    /// What the menu's switches and options start set to; `.{}` for nothing.
    state: transient_menu.State = .{},
    /// Where the `Chosen` goes, under its tag with its user data, which is copied.
    reply: sequencer.ReplyTo,
};

/// The system's requests, `Request`s, which it takes in its run.
pub const requests_table_name = "commands.editor_transient";
/// The typed handle on `commands.editor_transient`.
pub const Requests = sequencer.Commands(Request);

/// Asks for `presenting.menu` to be shown, in this system's run this frame, after every editor
/// system that presents. A menu shown already is replaced, its presenter hearing `cancelled`.
/// While a palette prompt is open the menu is refused, and its presenter hears `cancelled` at
/// once; a prompt another system opens over a menu shown closes the menu, `cancelled` too. The
/// menu's address is kept across frames, so an image of the editor loaded again would find it
/// gone: as the editor initialises, a menu shown is closed unread and its presenter hears
/// `cancelled`. The caller's system declares `commands.editor_transient` written.
pub fn present(memory: *memory_mod.Memory, tables: *Table.Registry, presenting: Presenting) void {
    Requests.of(memory, tables, requests_table_name).push(.{ .present = presenting });
}

/// The menu's colours and font, the editor's theme's.
pub const menu_style: transient_menu.Style = .{
    .font = style.ui_font,
    .key = style.col.accent_bright,
    .label = style.col.text,
    .on = style.col.warning,
    .heading = style.col.text_dim,
    .background = style.col.sidebar,
};

// ---- the shown menu ---------------------------------------------------------------------------

/// The menu shown, a singleton (`Row`): the system writes it, and the palette's drawing reads it.
pub const table_name = "editor_transient";

/// Where the menu is in its showing.
const Phase = enum(u8) {
    /// No menu is shown.
    closed,
    /// The menu is shown and takes the keys.
    shown,
    /// The menu is shown under the palette's prompt that reads the value of the option
    /// `Row.reading`, which has the keys.
    reading_value,
    /// The menu was shown by an image of the editor that is gone, its address with it: the
    /// system's next run answers its presenter `cancelled`.
    lost,
};

/// The row of `editor_transient`.
const Row = struct {
    /// A `Phase`.
    phase: *u8,
    /// The address of the menu shown, a `*const transient_menu.Menu`; 0 when none is.
    menu: *usize,
    /// What the menu is set to and the keys typed so far.
    state: *transient_menu.State,
    /// The id of the option whose value the palette's prompt reads.
    reading: *u32,
    /// Where the presenter hears the answer.
    reply_inbox: *Atom,
    reply_tag: *Atom,
    /// The presenter's user data, a copy among the table's payloads.
    reply_user_data: *Table.Bytes,
};

const defaults = .{
    .phase = @as(u8, @intFromEnum(Phase.closed)),
    .menu = @as(usize, 0),
    .state = transient_menu.State{},
    .reading = @as(u32, 0),
    .reply_inbox = sequencer.no_inbox,
    .reply_tag = sequencer.no_inbox,
    .reply_user_data = Table.Bytes{},
};

/// The modes the menu asks for while shown and those it found: see `modes.followPrompt`.
pub const prompt_modes_table_name = "editor_transient_prompt_modes";

/// Makes the system's tables, unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{table_name});
    try Requests.ensure(scratch, atoms, tables, requests_table_name);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 7);
    defer schema.deinit();
    try schema.addFieldFallible("phase", u8, .int);
    try schema.addFieldFallible("menu", usize, .hex);
    try schema.addFieldFallible("state", transient_menu.State, .hex);
    try schema.addFieldFallible("reading", u32, .int);
    try schema.addFieldFallible("reply_inbox", Atom, .atom);
    try schema.addFieldFallible("reply_tag", Atom, .atom);
    try schema.addFieldFallible("reply_user_data", Table.Bytes, .bytes);
    _ = try tables.ensureSingleton(&schema, state_table, defaults, .durable);
    try modes.ensurePromptModes(scratch, atoms, tables, prompt_modes_table_name);
}

/// The fields a reload of the editor changes (`loseMenu`), which an init that may not change a
/// table before it commits takes from `ensure`'s table first.
pub const Lost = struct {
    /// The row's `Phase`.
    phase: *u8,
    /// The address of the menu shown.
    menu: *usize,
};

/// The row's fields `loseMenu` writes, from `tables`, which `ensure` made the table in.
pub fn lostFields(tables: *Table.Registry) Lost {
    const found = tables.findByName(state_table) orelse @panic("editor_transient singleton missing");
    const handle: Table.RowHandle = .{ .row = 0, .generation = found.rowGeneration(0) };
    const row = found.getRow(handle, Lost) orelse @panic("editor_transient singleton row missing");
    return row;
}

/// As the editor initialises: a menu shown or reading a value was presented by an image that is
/// gone, whose constants moved with it, so its address is forgotten unread and the system's next
/// run answers its presenter `cancelled` (`answerLost`).
pub fn loseMenu(fields: Lost) void {
    const phase = std.enums.fromInt(Phase, fields.phase.*) orelse .closed;
    switch (phase) {
        .shown, .reading_value => {
            fields.phase.* = @intFromEnum(Phase.lost);
            fields.menu.* = 0;
        },
        .closed, .lost => {},
    }
}

/// The menu shown and what it is set to, for the palette to draw.
pub const Shown = struct {
    /// The presenter's menu.
    menu: *const transient_menu.Menu,
    /// What it is set to, the table's: valid until the table next changes.
    state: *const transient_menu.State,
};

const ShownView = struct { phase: *u8, menu: *usize, state: *transient_menu.State };

/// The menu shown, or null while none is: read, not written, by whatever draws it.
pub fn shown(tables: *Table.Registry) ?Shown {
    const found = tables.findByName(state_table) orelse return null;
    var rows = found.readQuery(ShownView);
    const row = rows.next() orelse return null;
    return shownOf(row.view.phase.*, row.view.menu.*, row.view.state);
}

/// The menu a row's `phase` and `menu` give: only a menu shown or reading a value, whose address
/// this image's presenter gave.
fn shownOf(phase_value: u8, menu: usize, state: *const transient_menu.State) ?Shown {
    const phase = std.enums.fromInt(Phase, phase_value) orelse return null;
    switch (phase) {
        .shown, .reading_value => {},
        .closed, .lost => return null,
    }
    if (menu == 0) return null;
    return .{ .menu = @ptrFromInt(menu), .state = state };
}

/// The owner the palette's value prompt is presented as, which tells its drawing that the menu
/// stays shown above it.
pub const value_prompt_owner = Atom.from("editor_transient");

// ---- the system -----------------------------------------------------------------------------

const state_table = Atom.from(table_name);
const requests_table = Atom.from(requests_table_name);
const palette_table = Atom.from(action_palette.table_name);
const palette_requests_table = Atom.from(action_palette.requests_table_name);

/// Takes the frame's requests and keys, and while a menu is shown its keys and modes: after
/// every editor system that presents a menu, before the palette, which opens the prompt an
/// option's value is read in the same frame.
pub fn system() sequencer.System {
    return .{
        .name = "editor_transient",
        .names = comptime &sequencer.enumNames(Msg),
        .root = Atom.from("editor_transient"),
        .claims = claims,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "editor_transient.answer_lost", .run = answerLost },
            .{ .name = "editor_transient.take_requests", .run = takeRequests },
            .{ .name = "editor_transient.yield_to_prompt", .run = yieldToPrompt },
            .{ .name = "editor_transient.take_messages", .run = takeMessages },
            .{ .name = "editor_transient.follow_modes", .run = followModes },
            .{ .name = "editor_transient.subscribe", .run = subscribe },
        },
    };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Nothing to do while no menu is shown and none is asked for: the system is off, its key
/// subscriptions with it. The run that closes a menu restores the modes it kept.
fn active(frame: *const sequencer.Frame) bool {
    const requests = Requests.of(frame.memory, frame.tables, requests_table_name);
    if (requests.count() != 0) return true;
    const found = frame.tables.findByName(state_table) orelse return false;
    var rows = found.readQuery(struct { phase: *u8 });
    const row = rows.next() orelse return false;
    return row.view.phase.* != @intFromEnum(Phase.closed);
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.write(state_table);
    result.write(requests_table);
    // A menu is refused while a palette prompt is open, and an option's value is read in one.
    result.read(palette_table);
    result.write(palette_requests_table);
    // Every run subscribes again: its run replaces what it subscribed to before.
    result.writeIfPresent(tables, editor_sequencer.InputSubscriber.table);
    modes.declarePromptModes(&result, tables, prompt_modes_table_name);
    // The answers go through the editor's hook; what is not bound is told on the message line.
    result.writeIfPresent(tables, Atom.from(plugin.app_commands.commands_table_name));
    result.writeIfPresent(tables, Atom.from(plugin.text_editor_api.commands_table_name));
    return result;
}

/// Where the presenter hears the answer, its user data in `owned`, the system's table.
fn replyOf(owned: *const Table, row: Row) sequencer.ReplyTo {
    const user_data = owned.bytesOf(row.reply_user_data.*);
    return .{ .inbox = row.reply_inbox.*, .tag = row.reply_tag.*, .user_data = .{ .bytes = user_data } };
}

/// Keeps `reply` in `owned`, the system's table, a copy of its user data among its payloads.
fn setReply(owned: *Table, row: Row, reply: sequencer.ReplyTo) !void {
    const user_data = reply.user_data.bytes;
    row.reply_user_data.* = if (user_data.len == 0) .{} else .{ .payload = try owned.appendPayload(user_data, Table.bytes_alignment) };
    row.reply_inbox.* = reply.inbox;
    row.reply_tag.* = reply.tag;
}

/// Answers `reply` with `chosen`, through the editor's hook, which copies it. Answers to one
/// presenter arrive in the order given: the hook keeps an answer its inbox cannot take, and every
/// later one to that inbox in the same application finds it as full and is kept behind it, in
/// order (`Commands.drain` keeps the rows it retries in their order).
fn answer(tables: *Table.Registry, reply: sequencer.ReplyTo, chosen: Chosen) void {
    const bytes = std.mem.asBytes(&chosen);
    plugin.app_commands.request(tables.memory, tables, .{ .answer = .{ .reply = reply, .payload = bytes } });
}

fn cancelledWith(state: transient_menu.State) Chosen {
    return .{ .id = 0, .cancelled = 1, .state = state };
}

/// Closes the menu, answering its presenter with `chosen`.
fn close(tables: *Table.Registry, owned: *Table, row: Row, chosen: Chosen) void {
    answer(tables, replyOf(owned, row), chosen);
    row.phase.* = @intFromEnum(Phase.closed);
    row.menu.* = 0;
    row.state.* = .{};
    row.reading.* = 0;
    row.reply_inbox.* = sequencer.no_inbox;
    row.reply_tag.* = sequencer.no_inbox;
    row.reply_user_data.* = .{};
}

/// A menu lost to a reload: its presenter hears `cancelled`, with the state as it was.
fn answerLost(pass: *sequencer.Pass) !void {
    const observed = try pass.readSingleton(state_table, Row);
    if (observed.phase.* != @intFromEnum(Phase.lost)) return;
    const row = try pass.writeSingleton(state_table, Row);
    const owned = try pass.writeTable(state_table);
    transient_menu.clearPending(row.state);
    close(pass.frame.tables, owned, row, cancelledWith(row.state.*));
    // The prompt that read a value for the lost menu has no one to answer: cancelled if it is
    // still the one open when the palette runs, and not a prompt another system presented this
    // frame in its place. The acknowledgement follows at once, where an owner would wait to hear
    // `completed`: no answer of a value prompt is read once the menu is closed (`takeValue`), so
    // a late one cannot be taken for a later prompt's.
    const memory = pass.frame.memory;
    const tables = pass.frame.tables;
    action_palette.request(memory, tables, .{ .cancel = .{ .owner = value_prompt_owner } });
    action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = value_prompt_owner } });
}

/// What the system reads of the palette's row: whether a prompt is open, and whose.
const PaletteView = struct { request_open: *u8, request_owner: *Atom };

/// A palette prompt another system opened over the menu, which hides it: the menu closes,
/// answering `cancelled`, before it takes the frame's keys, which were the prompt's. Its modes
/// are asked for as the menu closes, ahead of the palette's run, which keeps them in place of
/// the menu's it found as the prompt opened (`modes.followPrompt`), and so asks for them again
/// as the prompt closes.
fn yieldToPrompt(pass: *sequencer.Pass) !void {
    const observed = try pass.readSingleton(state_table, Row);
    if (shownOf(observed.phase.*, observed.menu.*, observed.state) == null) return;
    const palette = try pass.readSingleton(palette_table, PaletteView);
    if (palette.request_open.* == 0 or palette.request_owner.* == value_prompt_owner) return;
    const row = try pass.writeSingleton(state_table, Row);
    const owned = try pass.writeTable(state_table);
    transient_menu.clearPending(row.state);
    close(pass.frame.tables, owned, row, cancelledWith(row.state.*));
}

const Taking = struct {
    pass: *sequencer.Pass,
    palette_open: bool,

    fn apply(taking: *Taking, wanted: *const Request) !void {
        switch (wanted.*) {
            .present => |presenting| try taking.present(presenting),
        }
    }

    fn present(taking: *Taking, presenting: Presenting) !void {
        const pass = taking.pass;
        const tables = pass.frame.tables;
        if (taking.palette_open) {
            Log.warn("present_refused", .{ .title = presenting.menu.title, .reply_tag = presenting.reply.tag });
            answer(tables, presenting.reply, cancelledWith(presenting.state));
            return;
        }
        const row = try pass.writeSingleton(state_table, Row);
        const owned = try pass.writeTable(state_table);
        const replaced = row.phase.* == @intFromEnum(Phase.shown);
        if (replaced) {
            transient_menu.clearPending(row.state);
            answer(tables, replyOf(owned, row), cancelledWith(row.state.*));
        }
        row.phase.* = @intFromEnum(Phase.shown);
        row.menu.* = @intFromPtr(presenting.menu);
        row.state.* = presenting.state;
        transient_menu.clearPending(row.state);
        row.reading.* = 0;
        try setReply(owned, row, presenting.reply);
    }
};

/// The frame's requests, in the order appended.
fn takeRequests(pass: *sequencer.Pass) !void {
    const requests = Requests.of(pass.frame.memory, pass.frame.tables, requests_table_name);
    if (requests.count() == 0) return;
    const palette = try pass.readSingleton(palette_table, PaletteView);
    var taking: Taking = .{ .pass = pass, .palette_open = palette.request_open.* != 0 };
    try requests.take(pass, &taking, Taking.apply);
}

/// The keys typed at the menu, and the answer of the prompt that read an option's value. What
/// arrives for a menu no longer shown, or while the prompt has the keys, is dropped.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const row = try pass.writeSingleton(state_table, Row);
    const owned = try pass.writeTable(state_table);
    for (frame.messages) |received| {
        const showing = shownOf(row.phase.*, row.menu.*, row.state) orelse continue;
        const at: Showing = .{ .tables = frame.tables, .owned = owned, .row = row, .menu = showing.menu };
        const taken: anyerror!void = switch (received.tag.to(Msg)) {
            .transient_key => at.takeKey(received),
            .transient_char => at.takeChar(received),
            .transient_value => at.takeValue(received),
            _ => {},
        };
        taken catch |err| received.unreadable(err);
    }
}

/// The menu shown, as a message to it finds it.
const Showing = struct {
    tables: *Table.Registry,
    owned: *Table,
    row: Row,
    menu: *const transient_menu.Menu,

    fn phase(at: Showing) Phase {
        return std.enums.fromInt(Phase, at.row.phase.*) orelse .closed;
    }

    /// A key: `C-g` and Escape cancel. One that types a character is taken as that character
    /// (`takeChar`); any other is not bound, but a lock's.
    fn takeKey(at: Showing, received: sequencer.Message) !void {
        if (at.phase() != .shown) return;
        const pressed = try received.payloadAs(input.KeyInputMsg);
        const modifiers = pressed.modifiers;
        const quits = pressed.key == .escape or (pressed.key == .g and modifiers.control and !modifiers.alt);
        if (quits) return at.cancel();
        const plain = !modifiers.control and !modifiers.alt and !modifiers.super;
        if (plain and typesCharacter(pressed.key)) return;
        if (isLock(pressed.key)) return;
        const token: plugin.action_api.KeyToken = .{ .key = pressed.key, .control = modifiers.control, .alt = modifiers.alt, .shift = modifiers.shift, .super_key = modifiers.super };
        var key_buffer: [24]u8 = undefined;
        const key_text = plugin.action_api.formatToken(&key_buffer, token);
        const state = at.row.state;
        try at.tellUnbound(state.pending[0..state.pending_len], key_text);
        transient_menu.clearPending(state);
    }

    /// A character typed, to `ui.transient.press`, or `q`, which cancels when nothing is pending
    /// and no key of the menu begins with it.
    fn takeChar(at: Showing, received: sequencer.Message) !void {
        if (at.phase() != .shown) return;
        const typed_msg = try received.payloadAs(input.TextInputMsg);
        var bytes: [4]u8 = undefined;
        const typed = input.typedText(typed_msg, &bytes) orelse return;
        const state = at.row.state;
        const quits = state.pending_len == 0 and std.mem.eql(u8, typed, "q") and !bindsKeyStartingWith(at.menu, typed);
        if (quits) return at.cancel();
        // What was typed before, which `press` forgets when the keys reach nothing.
        var pending_buffer: [transient_menu.max_key]u8 = undefined;
        const pending_len = state.pending_len;
        @memcpy(pending_buffer[0..pending_len], state.pending[0..pending_len]);
        switch (transient_menu.press(at.menu, state, typed)) {
            .pending, .toggled => {},
            .wants_value => |id| try at.readValue(id),
            .chosen, .menu => |id| close(at.tables, at.owned, at.row, .{ .id = id, .cancelled = 0, .state = state.* }),
            .unbound => {
                var key_buffer: [24]u8 = undefined;
                const key_text = characterKey(typed, &key_buffer);
                try at.tellUnbound(pending_buffer[0..pending_len], key_text);
            },
        }
    }

    /// The prompt's answer: its text, empty to clear, becomes the option's value; a cancelled
    /// prompt changes nothing. Either way the menu takes the keys back.
    fn takeValue(at: Showing, received: sequencer.Message) !void {
        if (at.phase() != .reading_value) return;
        // A late answer of a prompt that read another option's value.
        const option = try received.userDataAs(u32);
        if (option.* != at.row.reading.*) return;
        const event = try action_palette.eventOf(received);
        if (event.kind != .completed) return;
        at.row.phase.* = @intFromEnum(Phase.shown);
        if (event.completion == null) return;
        if (transient_menu.setValue(at.menu, at.row.state, at.row.reading.*, event.query)) return;
        const allocator = (try at.tables.memory.frameScratchAllocator()).allocator;
        const sentence = try std.fmt.allocPrint(allocator, "No more than {d} options can be set at once", .{transient_menu.max_values});
        plugin.text_editor_api.message(at.tables.memory, at.tables, sentence);
    }

    fn cancel(at: Showing) void {
        transient_menu.clearPending(at.row.state);
        close(at.tables, at.owned, at.row, cancelledWith(at.row.state.*));
    }

    /// Opens the palette's prompt for the value of the option `id`, labelled with its label, its
    /// value the text.
    fn readValue(at: Showing, id: u32) !void {
        const memory = at.tables.memory;
        const label = labelOf(at.menu, id) orelse return;
        action_palette.resetCompletionArena(memory, .transient);
        const allocator = try action_palette.completionAllocator(memory, .transient);
        const completions = try allocator.create(action_palette.Completions);
        completions.* = .{
            .owner = value_prompt_owner,
            .identity = id,
            .presentation = .prompt,
            .prompt = label,
            .initial_query = transient_menu.valueOf(at.menu, at.row.state, id),
            .tab = .nothing,
            .accepts_text = true,
            .entries = &.{},
        };
        try action_palette.ownRequestText(allocator, completions);
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.transient_value)).with(.{ .bytes = std.mem.asBytes(&id) });
        action_palette.request(memory, at.tables, .{ .present = .{ .completions = completions, .reply = reply } });
        at.row.phase.* = @intFromEnum(Phase.reading_value);
        at.row.reading.* = id;
    }

    /// Tells that the characters `pending`, typed before, and then `key` are bound to nothing in
    /// the menu, written as the minibuffer's line writes a sequence of keys: a space between
    /// them, each character a key of its own.
    fn tellUnbound(at: Showing, pending: []const u8, key: []const u8) !void {
        const allocator = (try at.tables.memory.frameScratchAllocator()).allocator;
        var sentence: std.Io.Writer.Allocating = .init(allocator);
        const writer = &sentence.writer;
        const pending_view = try std.unicode.Utf8View.init(pending);
        var characters = pending_view.iterator();
        while (characters.nextCodepointSlice()) |character| {
            var key_buffer: [24]u8 = undefined;
            const character_key = characterKey(character, &key_buffer);
            try writer.print("{s} ", .{character_key});
        }
        try writer.print("{s} is not bound in {s}", .{ key, at.menu.title });
        plugin.text_editor_api.message(at.tables.memory, at.tables, sentence.written());
    }
};

/// A typed character as a key's name: itself, but a space, which is named as its key is.
fn characterKey(character: []const u8, buffer: *[24]u8) []const u8 {
    if (!std.mem.eql(u8, character, " ")) return character;
    return plugin.action_api.formatToken(buffer, .{ .key = .space });
}

/// Whether `key`, with no modifier but Shift held, types a character, which arrives as text.
fn typesCharacter(key: input.Key) bool {
    const ordinal = @intFromEnum(key);
    if (ordinal <= @intFromEnum(input.Key.world_2)) return true;
    const keypad = ordinal >= @intFromEnum(input.Key.kp_0) and ordinal <= @intFromEnum(input.Key.kp_equal);
    return keypad and key != .kp_enter;
}

/// Whether `key` is a lock, which a person presses for what it locks and not for the menu.
fn isLock(key: input.Key) bool {
    return switch (key) {
        .caps_lock, .scroll_lock, .num_lock => true,
        else => false,
    };
}

/// Whether a key of `menu` begins with `typed`.
fn bindsKeyStartingWith(menu: *const transient_menu.Menu, typed: []const u8) bool {
    for (menu.groups) |group| {
        for (group.items) |item| {
            if (std.mem.startsWith(u8, item.key, typed)) return true;
        }
    }
    return false;
}

/// The label of `menu`'s item `id`; null when no item has it.
fn labelOf(menu: *const transient_menu.Menu, id: u32) ?[]const u8 {
    for (menu.groups) |group| {
        for (group.items) |item| {
            if (item.id == id) return item.label;
        }
    }
    return null;
}

/// Asks for `transient`'s modes while a menu is shown, as a prompt's are, and for those it found
/// as it closes: after the frame's requests and keys opened or closed it.
fn followModes(pass: *sequencer.Pass) !void {
    const observed = try pass.readSingleton(state_table, Row);
    const showing = shownOf(observed.phase.*, observed.menu.*, observed.state) != null;
    const major = if (showing) modes.transient else plugin.action_api.no_mode;
    try modes.followPrompt(pass, prompt_modes_table_name, major);
}

/// While the menu has the keys, every key and every character typed, wherever the focus is,
/// captured so that nothing reaches the panel under it. None while the palette's prompt reads a
/// value: the prompt has the keys.
fn subscribe(pass: *sequencer.Pass) !void {
    if (!pass.writes(editor_sequencer.InputSubscriber.table)) return;
    const observed = try pass.readSingleton(state_table, Row);
    if (observed.phase.* != @intFromEnum(Phase.shown)) return;
    const inputs = editor_sequencer.InputSubscriber.of(pass, system());
    inputs.push(.{ .key_input = .{ .scope = .global, .capture = true, .tag = .from(Msg.transient_key) } }, .none);
    inputs.push(.{ .text_input = .{
        .scope = .global,
        .capture = true,
        .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
        .tag = .from(Msg.transient_char),
    } }, .none);
}
