//! Your configuration, as a plugin: mesha builds this file as `libuser.so`, loads it at
//! start, and loads it again each time it is rebuilt, which it is whenever you save it.
//!
//! It is written as the editor is: systems and kernels over tables, run by a sequencer. Add a
//! system to `frameRoot`'s steps and it runs every frame, after the open project's game and before
//! the editor, so what it subscribes to it takes first. Its state belongs in tables, which a
//! reload keeps.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const sequencer = mesha.sequencer;
const journal = mesha.journal;
const roop = mesha.roop;
const plugin = mesha.plugin;
const keybinds = mesha.keybinds;
const text_editor = mesha.text_editor;

const name = Atom.from("user");

// Your keys: each binds a chord, in the keymap of a mode, to an action named by its mode and
// its name, as the editor's M-x lists them (`buffer.goto_line`). A chord is written as Emacs
// writes one: `C-x C-s`, `M-j`, `C-S-z`; a key with no action unbinds its chord. A mode's
// keymap starts as its parent's: `text`, what every text editor does, is under `global`, and
// `buffer`, a text panel, is under `text`. Your keys go over the editor's: a chord the editor
// binds in the same mode is yours, and to change one of `text`'s keys in a text panel alone,
// bind or unbind it in `buffer`.

/// Your keys in every text editor: a text panel, a table cell, a form's field, a prompt.
const text_keys = [_]keybinds.KeyDef{
    // .{ .chord = "M-g d", .action = .{ "text", "duplicate_line" } }, // the common keys keep `M-g d` too
};

/// Your keys in a text panel, over `text_keys` and the editor's `text` keys.
const buffer_keys = [_]keybinds.KeyDef{
    // .{ .chord = "C-t" }, // no transposing in a text panel; a cell still has it
    //
    // What configurations of Emacs often bind, which the editor leaves to you:
    // .{ .chord = "C-S-z", .action = .{ "buffer", "undo_tree" } }, // vundo
    // .{ .chord = "M-g c", .action = .{ "buffer", "jump_char" } }, // avy-goto-char
    // .{ .chord = "M-g w", .action = .{ "buffer", "jump_word" } }, // avy-goto-word-1
    // .{ .chord = "M-g l", .action = .{ "buffer", "jump_line" } }, // avy-goto-line
    // .{ .chord = "C-c t s", .action = .{ "buffer", "toggle_subword" } }, // subword-mode
};

/// Your keys everywhere.
const global_keys = [_]keybinds.KeyDef{
    // .{ .chord = "C-c r", .action = .{ "global", "recent_files" } }, // consult-recent-file
};

/// Your keymaps, of the rank `custom` (`KeymapDef`'s default), which goes over the editor's.
const keymaps = [_]keybinds.KeymapDef{
    .{ .mode = Atom.from("text"), .keys = &text_keys },
    .{ .mode = Atom.from("buffer"), .keys = &buffer_keys },
    .{ .mode = plugin.action_api.global_mode, .keys = &global_keys },
};

/// How many keys `keymaps` has in all.
const key_count = count: {
    var total: usize = 0;
    for (keymaps) |keymap| total += keymap.keys.len;
    break :count total;
};

/// `keymaps` as rows of `subscribed.keymaps`, their chords read and their actions' names
/// interned by `ensure`, once, and declared every frame. They live in this image, with the
/// bindings in `binding_storage`: a rebuild loads a new image, whose `ensure` builds them again.
var built_keymaps: [keymaps.len]plugin.action_api.Keymap = undefined;
/// Room for every binding of `built_keymaps`.
var binding_storage: [key_count]plugin.action_api.Binding = undefined;

/// The table your keymaps are rows of; the actions system reads it every frame.
const keymaps_table = Atom.from(plugin.action_api.keymaps_table_name);

/// Declares `built_keymaps` every frame: a reload, or a key changed, is in force at once.
fn keysSystem() sequencer.System {
    return .{
        .name = "user_keys",
        .root = name,
        .claims = sequencer.claims_nothing,
        .access = keysAccess,
        .kernels = &.{.{ .name = "user_keys.declare", .run = declareKeys }},
    };
}

fn keysAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.writeIfPresent(frame.tables, keymaps_table);
    return result;
}

fn declareKeys(pass: *sequencer.Pass) !void {
    if (!pass.writes(keymaps_table)) return;
    const frame = pass.frame;
    var rows: plugin.KeymapRows = .{ .keymaps = plugin.Keymaps.of(frame.memory, frame.tables, plugin.action_api.keymaps_table_name) };
    const sink = rows.sink();
    for (built_keymaps) |keymap| sink.declare(keymap);
}

// Your settings. Mesha keeps none in files and reads no configuration directory: what you
// want at every start is written here, and set when this plugin loads, and again each time
// it is rebuilt.

/// The editor's settings; null leaves a setting as the editor has it.
const EditorSettings = struct {
    /// Which keys the text editors answer: `keybinds.text_keymap_emacs` or
    /// `keybinds.text_keymap_cua`, the common keys (C-c, C-v, C-z).
    text_keymap: ?[]const u8 = null,
    /// How long a key sequence waits, in milliseconds, before the keys it leads to are listed.
    which_key_delay_ms: ?u32 = null,
    /// The letters windows and places to jump to are named by, the first for the nearest:
    /// your keyboard's home row.
    hint_keys: ?[]const u8 = null,
    /// How many seconds pass between vcs-git's refreshes of its status while it is shown and
    /// mesha's window has the focus; 0 turns them off.
    vcs_refresh_seconds: ?u32 = null,
    /// How many seconds pass between vcs-p4's refreshes of its changelists while it is shown and
    /// mesha's window has the focus; 0, the default, turns them off (each asks a server).
    vcs_p4_refresh_seconds: ?u32 = null,
};

const editor_settings: EditorSettings = .{
    // .text_keymap = keybinds.text_keymap_cua,
    // .which_key_delay_ms = 400,
    // .hint_keys = "asdfjkl;",
    // .vcs_refresh_seconds = 10,
    // .vcs_p4_refresh_seconds = 60,
};

/// Whether the text editor keeps, in this plugin's directory, what outlasts a session: the
/// files opened lately, in `recent_files`, and each file as it was before a session first
/// wrote over it, in `backups/`. False keeps neither.
const keeps_files = true;

/// The editor's settings table, which the editor makes when it loads.
const editor_settings_table = Atom.from(keybinds.editor_settings_name);
const editor_settings_keymap: ?Atom = if (editor_settings.text_keymap) |keymap| Atom.from(keymap) else null;
const plugins_table = Atom.from(plugin.plugins.table_name);
const text_editor_commands = Atom.from(text_editor.commands_table_name);

/// Whether this image has set its settings: a rebuild loads a new image, which sets them again.
var settings_applied = false;

/// Sets the settings above once, when the tables they are written to are there.
fn settingsSystem() sequencer.System {
    return .{
        .name = "user_settings",
        .root = name,
        .claims = sequencer.claims_nothing,
        .idle = settingsApplied,
        .access = settingsAccess,
        .kernels = &.{.{ .name = "user_settings.apply", .run = applySettings }},
    };
}

fn settingsApplied(frame: *const sequencer.Frame) bool {
    _ = frame;
    return settings_applied;
}

fn settingsAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.writeIfPresent(frame.tables, editor_settings_table);
    result.writeIfPresent(frame.tables, text_editor_commands);
    result.read(plugins_table);
    return result;
}

fn applySettings(pass: *sequencer.Pass) !void {
    // The editor may load after this plugin: its settings wait for its table.
    if (!pass.writes(editor_settings_table) or !pass.writes(text_editor_commands)) return;
    const settings = try pass.writeTable(editor_settings_table);
    var settings_rows = settings.rows();
    const settings_row = settings_rows.next() orelse return;
    if (editor_settings_keymap) |keymap| try settings.writeFieldSingle(Atom, settings_row, keybinds.text_keymap_field, keymap);
    if (editor_settings.which_key_delay_ms) |delay| try settings.writeFieldSingle(u32, settings_row, keybinds.which_key_delay_field, delay);
    if (editor_settings.hint_keys) |hint_keys| try settings.setString(settings_row, keybinds.hint_keys_field, hint_keys);
    if (editor_settings.vcs_refresh_seconds) |seconds| try settings.writeFieldSingle(u32, settings_row, keybinds.vcs_refresh_field, seconds);
    if (editor_settings.vcs_p4_refresh_seconds) |seconds| try settings.writeFieldSingle(u32, settings_row, keybinds.vcs_p4_refresh_field, seconds);

    if (keeps_files) {
        // This plugin's own row says where its directory is.
        const plugin_rows = try pass.rows(plugins_table, plugin.plugins.Row);
        var loaded = plugin_rows.read();
        while (loaded.next()) |found| {
            if (found.view.name.* != name) continue;
            text_editor.request(pass.frame.memory, pass.frame.tables, .{ .keep_in = found.view.directory });
        }
    }
    settings_applied = true;
}

/// The systems that run once a frame, in this order: built where it is used, at init for its
/// names and each frame for its run. Add `.{ .system = yourSystem() }` to the steps, and make
/// the count in `Built` the number of steps.
fn frameRoot() sequencer.Built(2) {
    return .{ .name = "user_frame", .steps = .{
        .{ .system = keysSystem() },
        .{ .system = settingsSystem() },
    } };
}

pub export fn plugin_bind_log(shared: ?*mesha.log.SharedState) callconv(.c) void {
    mesha.log.bindSharedState(shared);
}

/// The layout this image was built with, which the loader compares with its own.
pub export fn plugin_abi() callconv(.c) u64 {
    return plugin.abi_fingerprint;
}

pub export fn plugin_tag(atoms: *Atom.Registry) callconv(.c) Atom {
    _ = atoms;
    return name;
}

/// Runs at start and after every rebuild, on the tables as they are: make what is missing
/// and leave what is there.
pub export fn plugin_init(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) callconv(.c) bool {
    ensure(memory, atoms, tables) catch return false;
    return true;
}

fn ensure(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const scratch = try memory.tableScratchAllocator();
    try sequencer.ensure(scratch, atoms, tables);
    // The systems' names, and the names your keys bind, are interned once, here, so the
    // kernels never intern.
    const frame_root = frameRoot();
    try sequencer.internNames(atoms, &frame_root.sequencer());
    var storage = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&binding_storage));
    for (keymaps, &built_keymaps) |def, *keymap| keymap.* = try keybinds.buildKeymap(storage.allocator(), atoms, def);
    if (editor_settings.text_keymap) |keymap| _ = atoms.intern(keymap);
    // A system's name names its inbox: one shared with another system would lose messages.
    try sequencer.checkNamesFree(tables, &frame_root.sequencer());
    try sequencer.ensureInboxes(scratch, atoms, tables, &frame_root.sequencer());
}

/// `layer` is the journal layer of the host's run: this plugin's run is its child.
pub export fn plugin_update(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry, layer: *journal.Layer) callconv(.c) void {
    var context: Context = .{};
    const env: sequencer.Env = .{
        .memory = memory,
        .atoms = atoms,
        .tables = tables,
        .hooks = .{ .context = &context, .enter = Context.around, .leave = Context.around, .finished = Context.finished },
    };
    const frame_root = frameRoot();
    _ = sequencer.run(&frame_root.sequencer(), &env, layer);
}

/// The systems need nothing around their runs.
const Context = struct {
    fn around(context: *anyopaque, system: *const sequencer.System) void {
        _ = context;
        _ = system;
    }

    fn finished(context: *anyopaque, system: *const sequencer.System, changed: bool) void {
        _ = context;
        _ = system;
        _ = changed;
    }
};

/// The host asks every plugin for every panel, `viewport` being the panel's frame: a plugin
/// draws the panels its systems declared (`plugin.panels.declare`) and nothing in the rest.
pub export fn plugin_render_panel(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom, viewport: plugin.Viewport, ctx: *roop.Context) callconv(.c) void {
    _ = memory;
    _ = tables;
    _ = atoms;
    _ = panel;
    _ = viewport;
    _ = ctx;
}
