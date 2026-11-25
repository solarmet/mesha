//! Loading, creating and unloading plugins from the editor. `load_plugin` asks the platform's
//! folder picker for a plugin directory and asks the host to load it; `create_plugin` asks the
//! picker for the folder to write a new stage plugin in, then the palette for its name, and
//! asks the host to write it there and load it; `unload_plugin` lists the plugins that may be
//! unloaded (all but the editor and the user's) in the palette and asks the host to unload the
//! one chosen. The host's answer is told in the echo area, a sentence naming the plugin or the
//! directory.
//!
//! A system (`system`, `editor_plugins`) whose kernel takes the actions, the picker's answers,
//! the prompts' events and the host's answers. It keeps no state: the unload prompt lists the
//! rows of `plugins` as they are when it opens, or its text changes, and the name prompt's
//! reply carries the folder chosen.

const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const os = mesha.os;
const sequencer = mesha.sequencer;
const action_palette = @import("action_palette.zig");
const editor_mod = @import("editor.zig");
const text_editor = plugin.text_editor_api;
const plugins_api = plugin.plugins;

const Log = mesha.log.scope("editor_plugins");

/// The tags of the messages its inbox takes.
const Msg = enum(u64) {
    load_plugin = Atom.from("load_plugin").value(),
    unload_plugin = Atom.from("unload_plugin").value(),
    /// The folder picker's answer: the directory chosen, none for a cancel.
    plugin_folder_chosen = Atom.from("plugin_folder_chosen").value(),
    /// The unload prompt's events: its text as typed, and the plugin chosen.
    unload_plugin_prompt = Atom.from("unload_plugin_prompt").value(),
    /// The host's answer, a `plugins.Answer`; its user data the directory a load asked for.
    plugin_answered = Atom.from("plugin_answered").value(),
    create_plugin = Atom.from("create_plugin").value(),
    /// The folder picker's answer to `create_plugin`: the parent chosen, none for a cancel.
    create_plugin_folder_chosen = Atom.from("create_plugin_folder_chosen").value(),
    /// The name prompt's events; its user data the parent chosen.
    create_plugin_prompt = Atom.from("create_plugin_prompt").value(),
    /// The host's answer to a create, a `plugins.Answer`; its user data what was asked
    /// (`CreateAsked`).
    plugin_created = Atom.from("plugin_created").value(),
    _,
};

pub const actions = [_]plugin.action_api.Def{
    .{ .name = "load_plugin", .tag = @tagName(Msg.load_plugin), .doc = "Load a plugin from its directory" },
    .{ .name = "unload_plugin", .tag = @tagName(Msg.unload_plugin), .doc = "Unload a loaded plugin" },
    .{ .name = "create_plugin", .tag = @tagName(Msg.create_plugin), .doc = "Write a new stage plugin and load it" },
};

pub fn system() sequencer.System {
    return .{
        .name = "editor_plugins",
        .names = comptime &sequencer.enumNames(Msg),
        .root = editor_mod.editor_root,
        .claims = claims,
        .access = access,
        .kernels = &.{.{ .name = "editor_plugins.take_messages", .run = takeMessages }},
    };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

const plugins_table = Atom.from(plugins_api.table_name);

/// The rows of `plugins` are read for the unload prompt; the picker, the palette, the host's
/// plugins and the echo area are asked.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    // Without the host's plugins, as in a test, there are none to list.
    if (tables.findByName(plugins_table) != null) result.read(plugins_table);
    result.read(Atom.from(action_palette.table_name));
    result.write(Atom.from(action_palette.requests_table_name));
    result.writeIfPresent(tables, Atom.from(os.commands_table_name));
    result.writeIfPresent(tables, Atom.from(plugins_api.commands_table_name));
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    return result;
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| handle(frame, received);
}

const prompt_owner = Atom.from(Msg.unload_plugin_prompt);
const name_prompt_owner = Atom.from(Msg.create_plugin_prompt);

/// What a message asks for.
fn handle(frame: *const sequencer.Frame, received: sequencer.Message) void {
    const memory = frame.memory;
    const tables = frame.tables;
    switch (received.tag.to(Msg)) {
        .load_plugin => {
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.plugin_folder_chosen));
            os.request(memory, tables, .{ .open_folder_dialog = .{ .reply = reply } });
        },
        .plugin_folder_chosen => {
            // The path is the payload; none is a cancel.
            const directory = received.payload;
            if (directory.len == 0) return;
            // The directory comes back with the answer, which names it.
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.plugin_answered)).with(.{ .bytes = directory });
            plugins_api.request(memory, tables, .{ .load = .{ .directory = directory, .reply = reply } });
        },
        .unload_plugin => presentUnloadable(frame, "", .open),
        .unload_plugin_prompt => {
            const event = action_palette.eventOf(received) catch |err| return received.unreadable(err);
            if (event.kind == .query_changed) return presentUnloadable(frame, event.query, .relist);
            action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            // The entry's data holds the plugin's name, an atom of a row.
            const name = std.mem.bytesToValue(Atom, chosen.data[0..@sizeOf(Atom)]);
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.plugin_answered));
            plugins_api.request(memory, tables, .{ .unload = .{ .name = name, .reply = reply } });
        },
        .plugin_answered => {
            const answer = received.payloadAs(plugins_api.Answer) catch |err| return received.unreadable(err);
            tellAnswer(frame, answer.*, received.user_data);
        },
        .create_plugin => {
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.create_plugin_folder_chosen));
            os.request(memory, tables, .{ .open_folder_dialog = .{ .reply = reply } });
        },
        .create_plugin_folder_chosen => {
            // The path is the payload; none is a cancel.
            const parent = received.payload;
            if (parent.len == 0) return;
            presentNamePrompt(frame, parent);
        },
        .create_plugin_prompt => {
            const event = action_palette.eventOf(received) catch |err| return received.unreadable(err);
            if (event.kind == .query_changed) return;
            action_palette.request(memory, tables, .{ .acknowledge = .{ .owner = name_prompt_owner } });
            // A cancel chose nothing; a name submitted chose an empty completion.
            if (event.completion == null) return;
            requestCreate(frame, received.user_data, event.query);
        },
        .plugin_created => {
            const answer = received.payloadAs(plugins_api.Answer) catch |err| return received.unreadable(err);
            tellCreated(frame, answer.*, received.user_data);
        },
        _ => {},
    }
}

// ---- the unload prompt --------------------------------------------------------------------

/// The most plugins the prompt lists.
const max_listed = 64;

const PluginRows = sequencer.Rows(plugins_api.Row);

/// The plugins that may be unloaded (all but the editor and the user's) whose names hold
/// `query`, into `entries`: each labeled with its name, its directory the detail, and its
/// name's atom the data. `atoms` names them.
fn unloadable(plugins: PluginRows, atoms: *const Atom.Registry, query: []const u8, entries: []action_palette.Completion) []action_palette.Completion {
    var count: usize = 0;
    var rows = plugins.read();
    while (rows.next()) |row| {
        if (count == entries.len) break;
        // A cell anyone may write: a value that names no origin is a plugin a person loaded.
        const origin = std.enums.fromInt(plugins_api.Origin, row.view.origin.*) orelse .loaded;
        if (origin == .editor or origin == .user) continue;
        const name = row.view.name.*;
        const label = atoms.lookup(name) orelse continue;
        if (std.ascii.indexOfIgnoreCase(label, query) == null) continue;
        var entry: action_palette.Completion = .{ .label = label, .detail = row.view.directory };
        @memcpy(entry.data[0..@sizeOf(Atom)], std.mem.asBytes(&name));
        entries[count] = entry;
        count += 1;
    }
    return entries[0..count];
}

/// Lists the plugins that may be unloaded whose names hold `query`, as the prompt opens or
/// its text changes.
fn presentUnloadable(frame: *const sequencer.Frame, query: []const u8, how: enum { open, relist }) void {
    const memory = frame.memory;
    const tables = frame.tables;
    action_palette.resetCompletionArena(memory, .plugins);
    const allocator = action_palette.completionAllocator(memory, .plugins) catch return;
    const room = allocator.alloc(action_palette.Completion, max_listed) catch return;
    // Without the host's plugins, as in a test, there are none to list.
    var entries: []action_palette.Completion = room[0..0];
    if (tables.findByName(plugins_table)) |table| {
        const plugin_rows: PluginRows = .of(table);
        entries = unloadable(plugin_rows, frame.atoms, query, room);
    }
    const kept = allocator.create(action_palette.Completions) catch return;
    kept.* = .{ .owner = prompt_owner, .prompt = "Unload plugin:", .title = "Unload a loaded plugin", .initial_query = query, .entries = entries };
    action_palette.ownRequestText(allocator, kept) catch return;
    if (how == .relist) return action_palette.request(memory, tables, .{ .replace = .{ .completions = kept } });
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.unload_plugin_prompt));
    action_palette.request(memory, tables, .{ .present = .{ .completions = kept, .reply = reply } });
}

// ---- the name prompt ----------------------------------------------------------------------

/// Asks for the new plugin's name in the palette. `parent`, the folder chosen, rides in the
/// prompt's reply and comes back with the name.
fn presentNamePrompt(frame: *const sequencer.Frame, parent: []const u8) void {
    const memory = frame.memory;
    const tables = frame.tables;
    action_palette.resetCompletionArena(memory, .plugins);
    const allocator = action_palette.completionAllocator(memory, .plugins) catch return;
    const kept = allocator.create(action_palette.Completions) catch return;
    kept.* = .{
        .owner = name_prompt_owner,
        .prompt = "Plugin name:",
        .title = "Write a new stage plugin and load it",
        .accepts_text = true,
        .entries = &.{},
    };
    action_palette.ownRequestText(allocator, kept) catch return;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.create_plugin_prompt)).with(.{ .bytes = parent });
    action_palette.request(memory, tables, .{ .present = .{ .completions = kept, .reply = reply } });
}

/// What a create asked for, which its answer comes back with as the reply's user data: the
/// name's length in two bytes (little-endian), the name as typed, then the parent.
const CreateAsked = struct {
    name: []const u8,
    parent: []const u8,

    const length_bytes = 2;

    fn pack(asked: CreateAsked, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        if (asked.name.len > std.math.maxInt(u16)) return error.NoSpaceLeft;
        const total = length_bytes + asked.name.len + asked.parent.len;
        if (total > buffer.len) return error.NoSpaceLeft;
        const name_length: u16 = @intCast(asked.name.len);
        std.mem.writeInt(u16, buffer[0..length_bytes], name_length, .little);
        const name_end = length_bytes + asked.name.len;
        @memcpy(buffer[length_bytes..name_end], asked.name);
        @memcpy(buffer[name_end..total], asked.parent);
        return buffer[0..total];
    }

    /// Null for bytes no `pack` made.
    fn unpack(bytes: []const u8) ?CreateAsked {
        if (bytes.len < length_bytes) return null;
        const name_length = std.mem.readInt(u16, bytes[0..length_bytes], .little);
        const name_end = length_bytes + @as(usize, name_length);
        if (name_end > bytes.len) return null;
        return .{ .name = bytes[length_bytes..name_end], .parent = bytes[name_end..] };
    }
};

/// Asks the host to write the plugin `name` in `parent` and load it. The answer comes back
/// with what was asked, which its sentence names. An empty name is refused here.
fn requestCreate(frame: *const sequencer.Frame, parent: []const u8, name: []const u8) void {
    if (name.len == 0) {
        text_editor.message(frame.memory, frame.tables, "No plugin was written: it needs a name.");
        return;
    }
    var asked_buffer: [std.fs.max_path_bytes + 2 * plugins_api.max_name_bytes]u8 = undefined;
    const asked: CreateAsked = .{ .name = name, .parent = parent };
    const packed_asked = asked.pack(&asked_buffer) catch {
        text_editor.message(frame.memory, frame.tables, "No plugin was written: the folder's path and the name are too long together.");
        return;
    };
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.plugin_created)).with(.{ .bytes = packed_asked });
    const create: plugins_api.Create = .{ .parent = parent, .name = name, .reply = reply };
    plugins_api.request(frame.memory, frame.tables, .{ .create = create });
}

// ---- the host's answer --------------------------------------------------------------------

/// Tells the person what became of a load or unload: one sentence, naming the plugin, and
/// for a load the directory asked for, `asked`.
fn tellAnswer(frame: *const sequencer.Frame, answer: plugins_api.Answer, asked: []const u8) void {
    const name = frame.atoms.lookup(answer.name) orelse std.fs.path.basename(asked);
    var sentence_buffer: [2 * std.fs.max_path_bytes]u8 = undefined;
    const sentence = switch (answer.result) {
        .loaded => std.fmt.bufPrint(&sentence_buffer, "Loaded the plugin {s} from {s}.", .{ name, asked }),
        .already_loaded => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} is already loaded from {s}.", .{ name, asked }),
        .not_found => std.fmt.bufPrint(&sentence_buffer, "The directory at {s} could not be found or opened, so no plugin was loaded from it.", .{asked}),
        .not_a_directory => std.fmt.bufPrint(&sentence_buffer, "{s} is not a directory, so no plugin was loaded from it.", .{asked}),
        .invalid_name => std.fmt.bufPrint(&sentence_buffer, "No plugin was loaded from {s}: a plugin's directory is named with lowercase letters, digits and underscores, beginning with a letter, at most {d} bytes.", .{ asked, plugins_api.max_name_bytes }),
        .name_taken => std.fmt.bufPrint(&sentence_buffer, "No plugin was loaded from {s}: a plugin named {s} is already loaded from another directory.", .{ asked, name }),
        .unloaded => std.fmt.bufPrint(&sentence_buffer, "Unloaded the plugin {s}.", .{name}),
        .not_loaded => std.fmt.bufPrint(&sentence_buffer, "No plugin named {s} is loaded.", .{name}),
        .fixed => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} stays loaded: the editor and your own plugin cannot be unloaded.", .{name}),
        .unsaved_tables => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} has tables with unsaved edits: save them, then unload it.", .{name}),
        // A create's own answers, which come to `tellCreated`.
        .no_zig => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} was not loaded: zig 0.16.0 is not on PATH, so it could not be built.", .{name}),
        .exists, .no_sdk, .builds_off, .write_failed => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} was not loaded.", .{name}),
    } catch |err| {
        Log.err("plugin_answer_untold", .{ .result = @tagName(answer.result), .@"error" = @errorName(err) });
        return;
    };
    text_editor.message(frame.memory, frame.tables, sentence);
}

/// The longest package name Zig takes in a `build.zig.zon`, which a new plugin's name is: the
/// host refuses a longer one (`skeleton.max_package_name_bytes`).
const max_package_name_bytes = 32;

/// Tells the person what became of a create, `asked`: one sentence, naming the name typed
/// and the plugin's directory.
fn tellCreated(frame: *const sequencer.Frame, answer: plugins_api.Answer, asked_bytes: []const u8) void {
    const asked = CreateAsked.unpack(asked_bytes) orelse {
        Log.err("plugin_answer_untold", .{ .result = @tagName(answer.result), .@"error" = "UnreadableUserData" });
        return;
    };
    const name = asked.name;
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = std.fmt.bufPrint(&directory_buffer, "{s}/{s}", .{ asked.parent, name }) catch asked.parent;
    var sentence_buffer: [3 * std.fs.max_path_bytes]u8 = undefined;
    const sentence = switch (answer.result) {
        // Its row is added; whether its build started, and when it loads, the answer does
        // not say.
        .loaded => std.fmt.bufPrint(&sentence_buffer, "Wrote the plugin {s} in {s} and added it: it loads once its library is built.", .{ name, directory }),
        .exists => std.fmt.bufPrint(&sentence_buffer, "No plugin was written: {s} is already there and holds files.", .{directory}),
        .no_sdk => std.fmt.bufPrint(&sentence_buffer, "No plugin was written: there is no SDK (mesha) for {s} to build on.", .{name}),
        .builds_off => std.fmt.bufPrint(&sentence_buffer, "No plugin was written: builds are off (MESHA_NO_BUILD), so {s} would never be built.", .{name}),
        .no_zig => std.fmt.bufPrint(&sentence_buffer, "No plugin was written: zig 0.16.0 is not on PATH, so {s} could not be built.", .{name}),
        .write_failed => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} could not be written in {s}; what was written stays, and *Messages* says why.", .{ name, directory }),
        .invalid_name => if (plugins_api.validName(name))
            std.fmt.bufPrint(&sentence_buffer, "No plugin was written: \"{s}\" cannot name a new plugin: a new plugin's name is its Zig package's, which must be at most {d} bytes and not a Zig keyword.", .{ name, max_package_name_bytes })
        else
            std.fmt.bufPrint(&sentence_buffer, "No plugin was written: \"{s}\" is not a plugin name, which is lowercase letters, digits and underscores, beginning with a letter, at most {d} bytes.", .{ name, plugins_api.max_name_bytes }),
        .name_taken => std.fmt.bufPrint(&sentence_buffer, "No plugin was written: a plugin named {s} is already loaded.", .{name}),
        .already_loaded => std.fmt.bufPrint(&sentence_buffer, "Wrote the plugin {s} in {s}, which was already loaded.", .{ name, directory }),
        .not_found, .not_a_directory => std.fmt.bufPrint(&sentence_buffer, "Wrote the plugin {s} in {s}, but its directory could not be opened to load it.", .{ name, directory }),
        // A load's and an unload's own answers.
        .unloaded, .not_loaded, .fixed, .unsaved_tables => std.fmt.bufPrint(&sentence_buffer, "The plugin {s} was not written.", .{name}),
    } catch |err| {
        Log.err("plugin_answer_untold", .{ .result = @tagName(answer.result), .@"error" = @errorName(err) });
        return;
    };
    text_editor.message(frame.memory, frame.tables, sentence);
}

/// A test's registries, with the tables the system asks of.
const Fixture = struct {
    memory: mesha.memory.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    /// The system the fixture's frames are for, kept here so a frame may point at it.
    frame_system: sequencer.System = undefined,

    fn init(fixture: *Fixture) !void {
        fixture.frame_system = system();
        fixture.memory.init(std.testing.allocator);
        try fixture.atoms.init(&fixture.memory);
        try fixture.tables.init(&fixture.memory, 16);
        const scratch = try fixture.memory.tableScratchAllocator();
        try os.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, os.commands_table_name);
        try plugins_api.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, plugins_api.commands_table_name);
        try action_palette.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, action_palette.requests_table_name);
        try text_editor.Requests.ensure(scratch, &fixture.atoms, &fixture.tables, text_editor.commands_table_name);
        try action_palette.prepareCompletionArenas(&fixture.memory, &fixture.atoms);
    }

    /// The system's frame, as its kernel sees it.
    fn frame(fixture: *Fixture) sequencer.Frame {
        return .{ .memory = &fixture.memory, .atoms = &fixture.atoms, .tables = &fixture.tables, .messages = &.{}, .context = fixture, .system = &fixture.frame_system };
    }

    fn deinit(fixture: *Fixture) void {
        fixture.tables.deinit();
        fixture.atoms.deinit();
        fixture.memory.deinit();
    }

    /// The one request in `commands.plugins`, which this takes.
    fn takePluginRequest(fixture: *Fixture) !plugins_api.CmdPayload {
        const requests = plugins_api.Requests.of(&fixture.memory, &fixture.tables, plugins_api.commands_table_name);
        var rows: [2]plugins_api.CmdPayload = undefined;
        const asked = requests.peek(&rows);
        if (asked.len != 1) return error.ExpectedOneRequest;
        return asked[0];
    }

    /// The messages the person was told.
    fn told(fixture: *Fixture, into: []text_editor.CmdPayload) []text_editor.CmdPayload {
        return text_editor.Requests.of(&fixture.memory, &fixture.tables, text_editor.commands_table_name).peek(into);
    }
};

test "load_plugin asks for a folder and loads the one chosen" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const frame = fixture.frame();

    try std.testing.expect(claims(.from(Msg.load_plugin)));
    handle(&frame, .{ .tag = .from(Msg.load_plugin) });
    var asked: [2]os.CmdPayload = undefined;
    const dialogs = os.Requests.of(&fixture.memory, &fixture.tables, os.commands_table_name).peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), dialogs.len);
    // The picker's answer comes back to this system.
    const reply = dialogs[0].open_folder_dialog.reply;
    try std.testing.expectEqual(sequencer.inboxOf(system()), reply.inbox);
    try std.testing.expectEqual(Atom.from(Msg.plugin_folder_chosen), reply.tag);

    var path = "/home/someone/plugins/fight".*;
    handle(&frame, .{ .tag = .from(Msg.plugin_folder_chosen), .payload = &path });
    const load = (try fixture.takePluginRequest()).load;
    try std.testing.expectEqualStrings("/home/someone/plugins/fight", load.directory);
    try std.testing.expectEqual(sequencer.inboxOf(system()), load.reply.inbox);
    try std.testing.expectEqual(Atom.from(Msg.plugin_answered), load.reply.tag);
    // The answer names the directory asked for, which comes back as the reply's user data.
    try std.testing.expectEqualStrings("/home/someone/plugins/fight", load.reply.user_data.bytes);

    // A cancel loads nothing.
    plugins_api.Requests.of(&fixture.memory, &fixture.tables, plugins_api.commands_table_name).reset();
    handle(&frame, .{ .tag = .from(Msg.plugin_folder_chosen) });
    try std.testing.expectError(error.ExpectedOneRequest, fixture.takePluginRequest());

    // The host's answer is told as a sentence naming the plugin and its directory.
    _ = fixture.atoms.intern("fight");
    const answer: plugins_api.Answer = .{ .result = .loaded, .name = Atom.from("fight") };
    const answered = load.reply.answered(std.mem.asBytes(&answer));
    handle(&frame, answered);
    var messages: [2]text_editor.CmdPayload = undefined;
    const told = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("Loaded the plugin fight from /home/someone/plugins/fight.", told[0].message);
}

test "create_plugin asks for a folder, then a name, then pushes create" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const frame = fixture.frame();

    try std.testing.expect(claims(.from(Msg.create_plugin)));
    handle(&frame, .{ .tag = .from(Msg.create_plugin) });
    var asked: [2]os.CmdPayload = undefined;
    const dialogs = os.Requests.of(&fixture.memory, &fixture.tables, os.commands_table_name).peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), dialogs.len);
    const folder_reply = dialogs[0].open_folder_dialog.reply;
    try std.testing.expectEqual(sequencer.inboxOf(system()), folder_reply.inbox);
    try std.testing.expectEqual(Atom.from(Msg.create_plugin_folder_chosen), folder_reply.tag);

    // A cancel asks for no name.
    handle(&frame, .{ .tag = .from(Msg.create_plugin_folder_chosen) });
    var prompts_buffer: [2]action_palette.Request = undefined;
    const palette_requests = action_palette.Requests.of(&fixture.memory, &fixture.tables, action_palette.requests_table_name);
    try std.testing.expectEqual(@as(usize, 0), palette_requests.peek(&prompts_buffer).len);

    // The folder chosen, the palette asks for the name, and the folder comes back with it.
    var parent = "/home/someone/plugins".*;
    handle(&frame, .{ .tag = .from(Msg.create_plugin_folder_chosen), .payload = &parent });
    const prompts = palette_requests.peek(&prompts_buffer);
    try std.testing.expectEqual(@as(usize, 1), prompts.len);
    const present = prompts[0].present;
    try std.testing.expect(present.completions.accepts_text);
    try std.testing.expectEqual(@as(usize, 0), present.completions.entries.len);
    try std.testing.expectEqual(sequencer.inboxOf(system()), present.reply.inbox);
    try std.testing.expectEqual(Atom.from(Msg.create_plugin_prompt), present.reply.tag);
    try std.testing.expectEqualStrings("/home/someone/plugins", present.reply.user_data.bytes);

    // The prompt cancelled: nothing is created.
    const cancelled: action_palette.Msg.Event = .{ .kind = .completed, .completion = null, .query = "meadow" };
    const cancelled_payload = try plugin.editor_api.eventPayload(std.testing.allocator, cancelled);
    defer std.testing.allocator.free(cancelled_payload);
    handle(&frame, present.reply.answered(cancelled_payload));
    try std.testing.expectError(error.ExpectedOneRequest, fixture.takePluginRequest());

    // The name submitted: the host is asked to create the plugin there.
    const submitted: action_palette.Msg.Event = .{ .kind = .completed, .completion = .{ .label = "" }, .query = "meadow" };
    const payload = try plugin.editor_api.eventPayload(std.testing.allocator, submitted);
    defer std.testing.allocator.free(payload);
    handle(&frame, present.reply.answered(payload));
    const create = (try fixture.takePluginRequest()).create;
    try std.testing.expectEqualStrings("/home/someone/plugins", create.parent);
    try std.testing.expectEqualStrings("meadow", create.name);
    try std.testing.expectEqual(sequencer.inboxOf(system()), create.reply.inbox);
    try std.testing.expectEqual(Atom.from(Msg.plugin_created), create.reply.tag);

    // The host's answer is told as a sentence naming the plugin's directory.
    _ = fixture.atoms.intern("meadow");
    const answer: plugins_api.Answer = .{ .result = .exists, .name = Atom.from("meadow") };
    handle(&frame, create.reply.answered(std.mem.asBytes(&answer)));
    var messages: [2]text_editor.CmdPayload = undefined;
    const told = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("No plugin was written: /home/someone/plugins/meadow is already there and holds files.", told[0].message);
}

test "create_plugin names the name typed, and refuses an empty one itself" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const frame = fixture.frame();
    const text_requests = text_editor.Requests.of(&fixture.memory, &fixture.tables, text_editor.commands_table_name);
    var parent = "/home/someone/plugins".*;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.create_plugin_prompt)).with(.{ .bytes = &parent });

    // An empty submit asks the host for nothing, and says why.
    const empty: action_palette.Msg.Event = .{ .kind = .completed, .completion = .{ .label = "" }, .query = "" };
    const empty_payload = try plugin.editor_api.eventPayload(std.testing.allocator, empty);
    defer std.testing.allocator.free(empty_payload);
    handle(&frame, reply.answered(empty_payload));
    try std.testing.expectError(error.ExpectedOneRequest, fixture.takePluginRequest());
    var messages: [2]text_editor.CmdPayload = undefined;
    const told_empty = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told_empty.len);
    try std.testing.expectEqualStrings("No plugin was written: it needs a name.", told_empty[0].message);
    text_requests.reset();

    // A name with a slash is refused by the host, and the sentence names it as typed.
    const slashed: action_palette.Msg.Event = .{ .kind = .completed, .completion = .{ .label = "" }, .query = "my/game" };
    const slashed_payload = try plugin.editor_api.eventPayload(std.testing.allocator, slashed);
    defer std.testing.allocator.free(slashed_payload);
    handle(&frame, reply.answered(slashed_payload));
    const create = (try fixture.takePluginRequest()).create;
    try std.testing.expectEqualStrings("my/game", create.name);
    const answer: plugins_api.Answer = .{ .result = .invalid_name, .name = @enumFromInt(0) };
    handle(&frame, create.reply.answered(std.mem.asBytes(&answer)));
    const told = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("No plugin was written: \"my/game\" is not a plugin name, which is lowercase letters, digits and underscores, beginning with a letter, at most 63 bytes.", told[0].message);
    text_requests.reset();
    plugins_api.Requests.of(&fixture.memory, &fixture.tables, plugins_api.commands_table_name).reset();

    // A plugin name Zig will not take as a package's is refused for that.
    const keyword: action_palette.Msg.Event = .{ .kind = .completed, .completion = .{ .label = "" }, .query = "test" };
    const keyword_payload = try plugin.editor_api.eventPayload(std.testing.allocator, keyword);
    defer std.testing.allocator.free(keyword_payload);
    handle(&frame, reply.answered(keyword_payload));
    const keyword_create = (try fixture.takePluginRequest()).create;
    handle(&frame, keyword_create.reply.answered(std.mem.asBytes(&answer)));
    const told_keyword = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told_keyword.len);
    try std.testing.expectEqualStrings("No plugin was written: \"test\" cannot name a new plugin: a new plugin's name is its Zig package's, which must be at most 32 bytes and not a Zig keyword.", told_keyword[0].message);
}

test "unload_plugin offers the loaded plugins but the editor and the user's" {
    var fixture: Fixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const frame = fixture.frame();
    const table = try plugins_api.ensureTable(std.testing.allocator, &fixture.atoms, &fixture.tables);
    const rows = [_]struct { name: []const u8, origin: plugins_api.Origin }{
        .{ .name = "editor", .origin = .editor },
        .{ .name = "user", .origin = .user },
        .{ .name = "demo", .origin = .launch },
        .{ .name = "fight", .origin = .loaded },
    };
    for (rows) |row| {
        const name = fixture.atoms.intern(row.name);
        _ = try plugins_api.add(table, .{ .name = name, .directory = "", .library = "", .origin = row.origin });
    }

    try std.testing.expect(claims(.from(Msg.unload_plugin)));
    handle(&frame, .{ .tag = .from(Msg.unload_plugin) });
    var asked: [2]action_palette.Request = undefined;
    const prompts = action_palette.Requests.of(&fixture.memory, &fixture.tables, action_palette.requests_table_name).peek(&asked);
    try std.testing.expectEqual(@as(usize, 1), prompts.len);
    const present = prompts[0].present;
    try std.testing.expectEqual(sequencer.inboxOf(system()), present.reply.inbox);
    const entries = present.completions.entries;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("demo", entries[0].label);
    try std.testing.expectEqualStrings("fight", entries[1].label);

    // Choosing one asks the host to unload it.
    const event: action_palette.Msg.Event = .{ .kind = .completed, .completion = entries[1], .query = "" };
    const payload = try plugin.editor_api.eventPayload(std.testing.allocator, event);
    defer std.testing.allocator.free(payload);
    handle(&frame, present.reply.answered(payload));
    const unload = (try fixture.takePluginRequest()).unload;
    try std.testing.expectEqual(Atom.from("fight"), unload.name);
    try std.testing.expectEqual(Atom.from(Msg.plugin_answered), unload.reply.tag);

    // A refusal is told, naming the plugin.
    const answer: plugins_api.Answer = .{ .result = .unsaved_tables, .name = Atom.from("fight") };
    handle(&frame, unload.reply.answered(std.mem.asBytes(&answer)));
    var messages: [2]text_editor.CmdPayload = undefined;
    const told = fixture.told(&messages);
    try std.testing.expectEqual(@as(usize, 1), told.len);
    try std.testing.expectEqualStrings("The plugin fight has tables with unsaved edits: save them, then unload it.", told[0].message);
}
