//! What every text editor shares, whichever view owns it (a table cell, a
//! form field or a prompt):
//!
//! - Keys: an action for each of the text editor system's edit commands, and two for the
//!   editor's owner (save, and leave the text), of the mode `text`, bound by Emacs's keys in
//!   `text_keys`, and by the common keys in `cua_keys`, the keymap of the minor mode `cua`. The
//!   editor binds no keys itself, so these are the only keys it answers besides typed
//!   characters. The actions exist only while a text editor has the keyboard; the owner of that
//!   editor takes their messages and runs them on it.
//! - The clipboard, which is the OS's: what an editor copies is put on it, and a paste an
//!   editor asks for is read from it and handed back to that editor.
//! - Drawing a single-line field's text, selection and caret inside a `ui.Tree`, read from
//!   its buffer's view. The text editor system lays nothing out: what a field looks like is
//!   decided here.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const roop = mesha.roop;
const plugin = mesha.plugin;
const os = mesha.os;
const keybinds = mesha.keybinds;
const math = mesha.math;
const sequencer = mesha.sequencer;
const style = @import("ui/style.zig");
const editor_mod = @import("editor.zig");
const modes = @import("modes.zig");

const text_editor = plugin.text_editor_api;
const EditCommand = text_editor.EditCommand;

/// Which keys the text editors answer: Emacs's, the keymaps of `text` and `buffer`, or the
/// common ones (Ctrl+C, Ctrl+V, ...), which the minor mode `cua` puts over them (`cua_keys`). The
/// setting says which; the panels' owners put `cua` in the modes they ask for while it says `cua`
/// (`modes.modesFor`). The figure editor follows it too, its common keys `figure_cua`'s.
pub const Keymap = enum(u8) {
    emacs,
    cua,
};

/// The editor's settings (`keybinds.editor_settings_name`): a singleton the editor makes at
/// its init with every cell at its default (`ensureSettings`). Nothing reads it from a file or
/// saves it: a person sets what they want in their own plugin's code, which writes its cells.
pub const settings_table = Atom.from(keybinds.editor_settings_name);

/// Makes the settings table, its keymap Emacs's and its other cells absent, which read as
/// their defaults (`Settings`); one that is there, as after a reload, is left as it is. The
/// host registers its schema before any plugin loads (`keybinds.init`); where none did, as in
/// a test, there is no table and the defaults hold.
pub fn ensureSettings(tables: *Table.Registry) !void {
    const schema = tables.getSchema(settings_table) orelse return;
    _ = try tables.ensureSingleton(schema, settings_table, .{ .text_keymap = keymapAtom(.emacs) }, .durable);
}
pub const SettingsRow = struct {
    text_keymap: *Atom,
    which_key_delay_ms: *u32,
    hint_keys: *Table.String,
};

/// The settings as code reads them: a cell left empty has its default.
pub const Settings = struct {
    /// How long a key sequence waits before the keys it leads to are listed.
    which_key_delay_ms: u32 = 250,
    /// The letters windows and places to jump to are named by: the home row of the
    /// keyboard the configuration is typed on. The table's until it is next written.
    hint_keys: []const u8 = "aoeuhtns",

    pub fn of(table: *const Table, row: SettingsRow) Settings {
        var settings: Settings = .{};
        if (row.which_key_delay_ms.* != 0) settings.which_key_delay_ms = row.which_key_delay_ms.*;
        const hint_keys = table.textOf(row.hint_keys.*);
        if (hint_keys.len != 0) settings.hint_keys = hint_keys;
        return settings;
    }
};

/// The settings as they are now: the defaults where the table is not there.
pub fn settingsOf(tables: *Table.Registry) Settings {
    const found = tables.findByName(settings_table) orelse return .{};
    var rows = found.readQuery(SettingsRow);
    const row = rows.next() orelse return .{};
    return Settings.of(found, .{ .text_keymap = @constCast(row.view.text_keymap), .which_key_delay_ms = @constCast(row.view.which_key_delay_ms), .hint_keys = @constCast(row.view.hint_keys) });
}

pub fn keymapAtom(keymap: Keymap) Atom {
    return switch (keymap) {
        .emacs => Atom.from(keybinds.text_keymap_emacs),
        .cua => Atom.from(keybinds.text_keymap_cua),
    };
}

/// The keys the text editors answer now: Emacs's unless the settings say the common ones. Reads
/// the one cell, which a row may have without the others.
pub fn keymapInUse(tables: *Table.Registry) Keymap {
    const found = tables.findByName(settings_table) orelse return .emacs;
    var rows = found.readQuery(struct { text_keymap: *Atom });
    const row = rows.next() orelse return .emacs;
    return if (row.view.text_keymap.* == keymapAtom(.cua)) .cua else .emacs;
}

/// Every edit command's action arrives under this tag, its command the user data's one byte.
pub const command_tag = Atom.from("text_editor_command");
/// Asks the editor's owner to save what it edits.
pub const save_tag = Atom.from("text_editor_save");
/// Gives the keyboard up: the editor stops taking keys.
pub const leave_tag = Atom.from("text_editor_leave");

const edit_commands = std.enums.values(EditCommand);

/// The text editor's actions, `text.<name>`.
pub const actions: [edit_commands.len + 2]plugin.action_api.Def = blk: {
    var defs: [edit_commands.len + 2]plugin.action_api.Def = undefined;
    for (edit_commands, 0..) |command, index| {
        const params = [_]u8{@intFromEnum(command)};
        defs[index] = .{
            .name = @tagName(command),
            .tag = "text_editor_command",
            .params = &params,
            .doc = command.doc(),
        };
    }
    defs[edit_commands.len] = .{ .name = "save", .tag = "text_editor_save", .doc = "Save what the text editor edits" };
    defs[edit_commands.len + 1] = .{ .name = "leave", .tag = "text_editor_leave", .doc = "Leave the text editor" };
    break :blk defs;
};

/// Emacs's keys for the text editor's actions, the keymap of `text`, which every mode that edits
/// text inherits. A command a held key repeats (`repeats`) repeats here too.
pub const text_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-f", .action = .{ "text", "char_right" }, .trigger = .repeat },
    .{ .chord = "right", .action = .{ "text", "char_right" }, .trigger = .repeat },
    .{ .chord = "S-right", .action = .{ "text", "char_right_extend" }, .trigger = .repeat },
    .{ .chord = "C-b", .action = .{ "text", "char_left" }, .trigger = .repeat },
    .{ .chord = "left", .action = .{ "text", "char_left" }, .trigger = .repeat },
    .{ .chord = "S-left", .action = .{ "text", "char_left_extend" }, .trigger = .repeat },
    .{ .chord = "M-f", .action = .{ "text", "forward_word" }, .trigger = .repeat },
    .{ .chord = "C-right", .action = .{ "text", "forward_word" }, .trigger = .repeat },
    .{ .chord = "C-S-right", .action = .{ "text", "forward_word_extend" }, .trigger = .repeat },
    .{ .chord = "M-b", .action = .{ "text", "backward_word" }, .trigger = .repeat },
    .{ .chord = "C-left", .action = .{ "text", "backward_word" }, .trigger = .repeat },
    .{ .chord = "C-S-left", .action = .{ "text", "backward_word_extend" }, .trigger = .repeat },
    .{ .chord = "C-n", .action = .{ "text", "line_down" }, .trigger = .repeat },
    .{ .chord = "down", .action = .{ "text", "line_down" }, .trigger = .repeat },
    .{ .chord = "S-down", .action = .{ "text", "line_down_extend" }, .trigger = .repeat },
    .{ .chord = "C-p", .action = .{ "text", "line_up" }, .trigger = .repeat },
    .{ .chord = "up", .action = .{ "text", "line_up" }, .trigger = .repeat },
    .{ .chord = "S-up", .action = .{ "text", "line_up_extend" }, .trigger = .repeat },
    .{ .chord = "C-a", .action = .{ "text", "line_begin" }, .trigger = .repeat },
    .{ .chord = "home", .action = .{ "text", "line_begin" }, .trigger = .repeat },
    .{ .chord = "S-home", .action = .{ "text", "line_begin_extend" }, .trigger = .repeat },
    .{ .chord = "C-e", .action = .{ "text", "line_end" }, .trigger = .repeat },
    .{ .chord = "end", .action = .{ "text", "line_end" }, .trigger = .repeat },
    .{ .chord = "S-end", .action = .{ "text", "line_end_extend" }, .trigger = .repeat },
    .{ .chord = "C-v", .action = .{ "text", "scroll_page_down" }, .trigger = .repeat },
    .{ .chord = "page_down", .action = .{ "text", "scroll_page_down" }, .trigger = .repeat },
    .{ .chord = "S-page_down", .action = .{ "text", "page_down_extend" }, .trigger = .repeat },
    .{ .chord = "M-v", .action = .{ "text", "scroll_page_up" }, .trigger = .repeat },
    .{ .chord = "page_up", .action = .{ "text", "scroll_page_up" }, .trigger = .repeat },
    .{ .chord = "S-page_up", .action = .{ "text", "page_up_extend" }, .trigger = .repeat },
    .{ .chord = "M-S-comma", .action = .{ "text", "document_start" }, .trigger = .repeat },
    .{ .chord = "C-home", .action = .{ "text", "document_start" }, .trigger = .repeat },
    .{ .chord = "C-S-home", .action = .{ "text", "document_start_extend" }, .trigger = .repeat },
    .{ .chord = "M-S-period", .action = .{ "text", "document_end" }, .trigger = .repeat },
    .{ .chord = "C-end", .action = .{ "text", "document_end" }, .trigger = .repeat },
    .{ .chord = "C-S-end", .action = .{ "text", "document_end_extend" }, .trigger = .repeat },
    .{ .chord = "C-l", .action = .{ "text", "recenter" } },
    .{ .chord = "C-up", .action = .{ "text", "paragraph_back" }, .trigger = .repeat },
    .{ .chord = "C-down", .action = .{ "text", "paragraph_forward" }, .trigger = .repeat },
    .{ .chord = "backspace", .action = .{ "text", "delete_back" }, .trigger = .repeat },
    .{ .chord = "S-backspace", .action = .{ "text", "delete_back" }, .trigger = .repeat },
    .{ .chord = "C-d", .action = .{ "text", "delete_forward" }, .trigger = .repeat },
    .{ .chord = "delete", .action = .{ "text", "delete_forward" }, .trigger = .repeat },
    .{ .chord = "M-d", .action = .{ "text", "kill_word_forward" }, .trigger = .repeat },
    .{ .chord = "C-delete", .action = .{ "text", "kill_word_forward" }, .trigger = .repeat },
    .{ .chord = "M-backspace", .action = .{ "text", "kill_word_back" }, .trigger = .repeat },
    .{ .chord = "C-backspace", .action = .{ "text", "kill_word_back" }, .trigger = .repeat },
    .{ .chord = "C-k", .action = .{ "text", "kill_line" }, .trigger = .repeat },
    .{ .chord = "C-S-backspace", .action = .{ "text", "kill_whole_line" }, .trigger = .repeat },
    .{ .chord = "C-SPC", .action = .{ "text", "set_mark" } },
    .{ .chord = "C-x C-x", .action = .{ "text", "exchange_point_and_mark" } },
    .{ .chord = "C-x h", .action = .{ "text", "select_all" } },
    .{ .chord = "C-w", .action = .{ "text", "kill_region" } },
    .{ .chord = "M-w", .action = .{ "text", "copy_region" } },
    .{ .chord = "C-y", .action = .{ "text", "yank" } },
    .{ .chord = "M-y", .action = .{ "text", "yank_pop" } },
    .{ .chord = "C-/", .action = .{ "text", "undo" }, .trigger = .repeat },
    .{ .chord = "C-z", .action = .{ "text", "undo" }, .trigger = .repeat },
    .{ .chord = "C-x u", .action = .{ "text", "undo" }, .trigger = .repeat },
    .{ .chord = "C-S-z", .action = .{ "text", "redo" }, .trigger = .repeat },
    .{ .chord = "enter", .action = .{ "text", "new_line" }, .trigger = .repeat },
    .{ .chord = "kp_enter", .action = .{ "text", "new_line" }, .trigger = .repeat },
    .{ .chord = "C-j", .action = .{ "text", "new_line" }, .trigger = .repeat },
    .{ .chord = "S-tab", .action = .{ "text", "unindent" }, .trigger = .repeat },
    .{ .chord = "M-j", .action = .{ "text", "new_line" }, .trigger = .repeat },
    .{ .chord = "M-up", .action = .{ "text", "move_lines_up" }, .trigger = .repeat },
    .{ .chord = "M-down", .action = .{ "text", "move_lines_down" }, .trigger = .repeat },
    .{ .chord = "insert", .action = .{ "text", "toggle_overtype" } },
    .{ .chord = "C-x C-s", .action = .{ "text", "save" } },
    .{ .chord = "C-g", .action = .{ "text", "leave" } },
    .{ .chord = "escape", .action = .{ "text", "leave" } },
    .{ .chord = "M-S-f", .action = .{ "text", "forward_word_extend" }, .trigger = .repeat },
    .{ .chord = "M-S-b", .action = .{ "text", "backward_word_extend" }, .trigger = .repeat },
    .{ .chord = "M-m", .action = .{ "text", "back_to_indentation" } },
    .{ .chord = "M-S-left_bracket", .action = .{ "text", "paragraph_back" }, .trigger = .repeat },
    .{ .chord = "M-S-right_bracket", .action = .{ "text", "paragraph_forward" }, .trigger = .repeat },
    .{ .chord = "C-o", .action = .{ "text", "open_line" }, .trigger = .repeat },
    .{ .chord = "C-t", .action = .{ "text", "transpose_chars" }, .trigger = .repeat },
    .{ .chord = "M-u", .action = .{ "text", "upcase_word" }, .trigger = .repeat },
    .{ .chord = "M-l", .action = .{ "text", "downcase_word" }, .trigger = .repeat },
    .{ .chord = "M-c", .action = .{ "text", "capitalize_word" }, .trigger = .repeat },
    .{ .chord = "M-backslash", .action = .{ "text", "delete_horizontal_space" } },
    .{ .chord = "M-SPC", .action = .{ "text", "just_one_space" } },
    .{ .chord = "M-S-6", .action = .{ "text", "join_previous_line" }, .trigger = .repeat },
    .{ .chord = "C-S-minus", .action = .{ "text", "undo" }, .trigger = .repeat },
    .{ .chord = "C-S-/", .action = .{ "text", "redo" }, .trigger = .repeat },
    .{ .chord = "C-M-S-minus", .action = .{ "text", "redo" }, .trigger = .repeat },
    .{ .chord = "M-semicolon", .action = .{ "text", "comment_dwim" }, .trigger = .repeat },
    .{ .chord = "C-x C-semicolon", .action = .{ "text", "comment_line" }, .trigger = .repeat },
    .{ .chord = "M-q", .action = .{ "text", "fill_paragraph" }, .trigger = .repeat },
    .{ .chord = "C-x C-o", .action = .{ "text", "delete_blank_lines" }, .trigger = .repeat },
    .{ .chord = "M-t", .action = .{ "text", "transpose_words" }, .trigger = .repeat },
    .{ .chord = "C-x C-t", .action = .{ "text", "transpose_lines" }, .trigger = .repeat },
    .{ .chord = "C-M-f", .action = .{ "text", "forward_sexp" }, .trigger = .repeat },
    .{ .chord = "C-M-b", .action = .{ "text", "backward_sexp" }, .trigger = .repeat },
    .{ .chord = "C-M-k", .action = .{ "text", "kill_sexp" }, .trigger = .repeat },
    .{ .chord = "C-M-SPC", .action = .{ "text", "mark_sexp" }, .trigger = .repeat },
    .{ .chord = "C-x r k", .action = .{ "text", "kill_rectangle" }, .trigger = .repeat },
    .{ .chord = "C-x r d", .action = .{ "text", "delete_rectangle" }, .trigger = .repeat },
    .{ .chord = "C-x r y", .action = .{ "text", "yank_rectangle" }, .trigger = .repeat },
    .{ .chord = "C-x r o", .action = .{ "text", "open_rectangle" }, .trigger = .repeat },
};

/// The common keys, as other editors have them: the keymap of the minor mode `cua`, which is over
/// the keymaps of `global`, `text` and `buffer` in a panel whose major mode edits text while the
/// setting chooses them. It binds each common key that `buffer`'s keymap, with what it inherits,
/// does not already bind to the same action, and unbinds each other chord of `text_keys` and
/// `buffer_keys` but those it replaces by prefix (`C-x` hides every `C-x …`, `C-k C-i` hides
/// `C-k`).
///
/// It leaves alone the chords the field modes (`prompt`, `table_cell`, `form`) bind for
/// themselves, which a minor mode's keymap would take from them: `tab` and the page keys, which do
/// as they do with Emacs's keys, and `C-n` and `C-p`, which keep their Emacs actions in a text
/// panel. `C-x`, cut, hides `global`'s `C-x` chords in a text panel; `C-tab`, `C-S-w` and `f11`
/// still reach other panels. `C-r` and `C-w` are unbound, as `cua` is never over a search's
/// modes, and in a prompt, a cell or a form, where `buffer` is not active, a binding to a `buffer`
/// action drops out and the chord is `text`'s.
pub const cua_keys = [_]keybinds.KeyDef{
    .{ .chord = "C-left", .action = .{ "text", "word_left" }, .trigger = .repeat },
    .{ .chord = "C-S-left", .action = .{ "text", "word_left_extend" }, .trigger = .repeat },
    .{ .chord = "C-right", .action = .{ "text", "word_right" }, .trigger = .repeat },
    .{ .chord = "C-S-right", .action = .{ "text", "word_right_extend" }, .trigger = .repeat },
    .{ .chord = "home", .action = .{ "text", "line_start" }, .trigger = .repeat },
    .{ .chord = "S-home", .action = .{ "text", "line_start_extend" }, .trigger = .repeat },
    .{ .chord = "C-up", .action = .{ "text", "scroll_up" }, .trigger = .repeat },
    .{ .chord = "C-down", .action = .{ "text", "scroll_down" }, .trigger = .repeat },
    .{ .chord = "C-backspace", .action = .{ "text", "delete_word_back" }, .trigger = .repeat },
    .{ .chord = "C-delete", .action = .{ "text", "delete_word_forward" }, .trigger = .repeat },
    .{ .chord = "C-S-backspace", .action = .{ "text", "delete_line_back" }, .trigger = .repeat },
    .{ .chord = "C-S-delete", .action = .{ "text", "delete_line_forward" }, .trigger = .repeat },
    .{ .chord = "C-S-k", .action = .{ "text", "delete_line" }, .trigger = .repeat },
    .{ .chord = "C-d", .action = .{ "text", "duplicate_line" }, .trigger = .repeat },
    .{ .chord = "C-y", .action = .{ "text", "redo" }, .trigger = .repeat },
    .{ .chord = "C-x", .action = .{ "text", "cut" } },
    .{ .chord = "S-delete", .action = .{ "text", "cut" } },
    .{ .chord = "C-c", .action = .{ "text", "copy" } },
    .{ .chord = "C-insert", .action = .{ "text", "copy" } },
    .{ .chord = "C-v", .action = .{ "text", "paste" } },
    .{ .chord = "S-insert", .action = .{ "text", "paste" } },
    .{ .chord = "C-a", .action = .{ "text", "select_all" } },
    .{ .chord = "C-s", .action = .{ "text", "save" } },
    .{ .chord = "C-g", .action = .{ "buffer", "goto_line" } },
    .{ .chord = "C-f", .action = .{ "buffer", "search_lines" } },
    .{ .chord = "C-S-s", .action = .{ "buffer", "save_as" } },
    .{ .chord = "f12", .action = .{ "buffer", "goto_definition" } },
    .{ .chord = "M-left", .action = .{ "buffer", "go_back" } },
    .{ .chord = "C-k C-i", .action = .{ "buffer", "describe" } },
    .{ .chord = "f8", .action = .{ "buffer", "next_diagnostic" } },
    .{ .chord = "S-f8", .action = .{ "buffer", "previous_diagnostic" } },
    // Emacs's keys of `text_keys` that the common keys do not have.
    .{ .chord = "C-b" },
    .{ .chord = "M-f" },
    .{ .chord = "M-b" },
    .{ .chord = "C-e" },
    .{ .chord = "M-v" },
    .{ .chord = "M-S-comma" },
    .{ .chord = "M-S-period" },
    .{ .chord = "C-l" },
    .{ .chord = "M-d" },
    .{ .chord = "M-backspace" },
    .{ .chord = "C-SPC" },
    .{ .chord = "C-w" },
    .{ .chord = "M-w" },
    .{ .chord = "M-y" },
    .{ .chord = "C-/" },
    .{ .chord = "C-j" },
    .{ .chord = "M-j" },
    .{ .chord = "M-S-f" },
    .{ .chord = "M-S-b" },
    .{ .chord = "M-m" },
    .{ .chord = "M-S-left_bracket" },
    .{ .chord = "M-S-right_bracket" },
    .{ .chord = "C-o" },
    .{ .chord = "C-t" },
    .{ .chord = "M-u" },
    .{ .chord = "M-l" },
    .{ .chord = "M-c" },
    .{ .chord = "M-backslash" },
    .{ .chord = "M-SPC" },
    .{ .chord = "M-S-6" },
    .{ .chord = "C-S-minus" },
    .{ .chord = "C-S-/" },
    .{ .chord = "C-M-S-minus" },
    .{ .chord = "M-semicolon" },
    .{ .chord = "M-q" },
    .{ .chord = "M-t" },
    .{ .chord = "C-M-f" },
    .{ .chord = "C-M-b" },
    .{ .chord = "C-M-k" },
    .{ .chord = "C-M-SPC" },
    // Emacs's keys of `buffer_keys` that the common keys do not have.
    .{ .chord = "M-z" },
    .{ .chord = "M-g g" },
    .{ .chord = "M-g M-g" },
    .{ .chord = "M-period" },
    .{ .chord = "M-comma" },
    .{ .chord = "C-h period" },
    .{ .chord = "C-u" },
    .{ .chord = "M-0" },
    .{ .chord = "M-1" },
    .{ .chord = "M-2" },
    .{ .chord = "M-3" },
    .{ .chord = "M-4" },
    .{ .chord = "M-5" },
    .{ .chord = "M-6" },
    .{ .chord = "M-7" },
    .{ .chord = "M-8" },
    .{ .chord = "M-9" },
    .{ .chord = "C-r" },
    .{ .chord = "M-s l" },
    .{ .chord = "M-S-5" },
    .{ .chord = "C-M-i" },
    .{ .chord = "M-g i" },
    .{ .chord = "f3" },
    .{ .chord = "f4" },
};

/// Commands a held key repeats.
fn repeats(command: EditCommand) bool {
    return switch (command) {
        .cut, .copy, .paste, .select_all, .cancel, .toggle_overtype => false,
        .set_mark, .exchange_point_and_mark, .kill_region, .copy_region, .yank, .yank_pop, .recenter => false,
        .push_mark, .delete_horizontal_space, .just_one_space, .back_to_indentation => false,
        else => true,
    };
}

/// The command an edit command action's message carries in its user data.
pub fn commandOf(received: sequencer.Message) error{ MessageShape, UnknownCommand }!EditCommand {
    const value = try received.userDataAs(u8);
    return std.enums.fromInt(EditCommand, value.*) orelse error.UnknownCommand;
}

/// Whether an editor's keys capture input: a captured key reaches nothing else, as an inspector
/// cell's edit wants.
pub const Capture = enum { shared, captured };

/// Lists the actions, for `owner`, the system of the editor that has the keyboard, which takes
/// them. Called only while a text editor has the keyboard. The actions carry no keys: the keymaps
/// of `text` and `cua` bind them, and those of the owner's modes.
pub fn pushActions(atoms: *Atom.Registry, sink: plugin.ActionSink, capture: Capture, owner: sequencer.System) void {
    const inbox = sequencer.inboxOf(owner);
    for (actions) |def| {
        keybinds.pushActionDefinitions(atoms, sink, modes.text, inbox, &.{.{ .def = def, .capture = capture == .captured }});
    }
}

// ---- the clipboard ----------------------------------------------------------------------

const clipboard_tag = Atom.from("text_editor_clipboard");

/// The most a paste reads from the clipboard.
const max_paste_bytes = 1024 * 1024;

/// What the editors' events say of a text changing: which editor, its revision and whether it
/// is saved.
pub const Change = @FieldType(text_editor.Event, "changed");

/// The most events one run of a reader takes; the rest wait for its next.
pub const events_max = 16;

/// What a reader of `buffer`'s events declares: the events, its cursor, and the buffer's
/// table, which says where the buffer's text is.
pub fn declareEvents(result: *sequencer.Access, tables: *Table.Registry, buffer: Atom) void {
    text_editor.Events.declare(result, tables, text_editor.events_table_name);
    text_editor.declareBuffer(result, tables, buffer);
}

/// `buffer`'s whole text, for a field that takes it as its value: empty for a buffer not
/// open. It is the buffer's, or the frame's scratch when the buffer holds it in two pieces;
/// either way it lasts the run that asked.
pub fn textOf(tables: *Table.Registry, buffer: Atom) error{OutOfMemory}![]const u8 {
    const view = text_editor.viewOf(tables, buffer) orelse return "";
    const text_len = view.byteCount();
    const pieces = view.range(0, text_len);
    if (pieces[1].len == 0) return pieces[0];
    const scratch = tables.memory.frameScratchAllocator() catch return error.OutOfMemory;
    const joined = try scratch.allocator.alloc(u8, text_len);
    return view.copyRange(0, joined);
}

/// The editors' events since `reader` last read them, oldest first.
pub fn readEvents(pass: *sequencer.Pass, reader: Atom, into: *[events_max]text_editor.Event) ![]text_editor.Event {
    const events = text_editor.Events.of(pass.frame.tables, text_editor.events_table_name);
    return events.read(pass, reader, into);
}

/// Every editor's copies and pastes, through the window's clipboard: it reads an editor copy or
/// want a paste in the editors' events, and takes the clipboard's answer to a paste.
pub fn clipboardSystem() sequencer.System {
    return .{
        .name = "editor_clipboard",
        .root = editor_mod.editor_root,
        .claims = claimsClipboard,
        .access = clipboardAccess,
        .kernels = &.{
            .{ .name = "editor_clipboard.follow_editors", .run = followEditors },
            .{ .name = "editor_clipboard.take_messages", .run = takeClipboardMessages },
        },
    };
}

/// The window's clipboard answers, under their tag.
fn claimsClipboard(tag: Atom) bool {
    return tag == clipboard_tag;
}

fn clipboardAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    text_editor.Events.declare(&result, frame.tables, text_editor.events_table_name);
    // The copied text's address is in the text editor's own row.
    const state_table = Atom.from(text_editor.state_table_name);
    if (frame.tables.findByName(state_table) != null) result.read(state_table);
    result.writeIfPresent(frame.tables, Atom.from(os.commands_table_name));
    result.writeIfPresent(frame.tables, Atom.from(text_editor.commands_table_name));
    return result;
}

/// Puts what an editor copied on the window's clipboard, and asks it for what an editor
/// wants pasted.
fn followEditors(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    var events: [events_max]text_editor.Event = undefined;
    const taken = try readEvents(pass, Atom.from(clipboardSystem().name), &events);
    for (taken) |event| switch (event) {
        .copied => {
            // The command copies the text.
            const text = text_editor.copiedText(frame.tables);
            os.request(frame.memory, frame.tables, .{ .set_clipboard = .{ .text = text } });
        },
        .paste_wanted => |wanted| {
            // The reply comes back naming the buffer that asked.
            const reply = sequencer.ReplyTo.of(clipboardSystem(), clipboard_tag).with(.of(&wanted.buffer));
            os.request(frame.memory, frame.tables, .{ .get_clipboard = .{ .max_bytes = max_paste_bytes, .reply = reply } });
        },
        .changed, .opened, .closed => {},
    };
}

fn takeClipboardMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    for (frame.messages) |received| {
        const editor = (received.userDataAs(Atom) catch |err| {
            received.unreadable(err);
            continue;
        }).*;
        // The clipboard's text is the payload while it waits in the inbox; the command copies it.
        const text = received.payload;
        if (text.len > 0) plugin.text_editor_api.request(frame.memory, frame.tables, .{ .paste = .{ .buffer = editor, .utf8 = text } });
    }
}

// ---- typing and drawing --------------------------------------------------------------------

/// How a field's text looks.
pub const FieldLook = struct {
    font: roop.Font = style.ui_font,
    text: ui.Color,
    caret: ui.Color,
    selection: ui.Color = style.col.accent_wash,
};

const caret_width: f32 = 2;

/// Draws a buffer as one line of text with its selection and caret, where `ui` lays it out.
/// It holds the buffer's view, so it is built and drawn within one drawing of its panel.
pub const FieldDrawable = struct {
    view: *const text_editor.View,
    caret: u32,
    anchor: u32,
    look: FieldLook,
    /// How far the text is scrolled left, which the field's owner keeps between drawings:
    /// the text moves only when the caret would otherwise leave the field.
    scroll_x: *f32,

    pub fn draw(drawable: *const FieldDrawable, size: math.Vec2f, ctx: *roop.Context) void {
        const view = drawable.view;
        const font = drawable.look.font;
        const text_len = view.byteCount();
        const caret = @min(drawable.caret, text_len);
        const anchor = @min(drawable.anchor, text_len);
        const caret_x = widthTo(ctx, font, view, caret);

        var scroll = drawable.scroll_x.*;
        const visible_width = size.x - caret_width;
        if (caret_x - scroll > visible_width) scroll = caret_x - visible_width;
        if (caret_x < scroll) scroll = caret_x;
        scroll = @max(scroll, 0);
        drawable.scroll_x.* = scroll;

        ctx.save();
        defer ctx.restore();
        ctx.intersectScissor(0, 0, size.x, size.y, 0);
        const line_height = ctx.measureText(font, "").h;
        const top = @round((size.y - line_height) / 2);
        // As `ui` sets text: its capitals in the middle of the line, and the caret beside them.
        const baseline = top + ctx.fontBaseline(font, line_height);

        if (caret != anchor) {
            const start_x = widthTo(ctx, font, view, @min(caret, anchor));
            const end_x = widthTo(ctx, font, view, @max(caret, anchor));
            ctx.beginPath();
            ctx.rect(start_x - scroll, top, end_x - start_x, line_height);
            ctx.fillColor(drawable.look.selection);
            ctx.fill();
        }

        ctx.fontFace(font);
        ctx.fillColor(drawable.look.text);
        const pieces = view.range(0, text_len);
        var pen_x = -scroll;
        for (pieces) |piece| {
            _ = ctx.text(pen_x, baseline, piece);
            pen_x += ctx.measureText(font, piece).w;
        }

        ctx.beginPath();
        ctx.rect(caret_x - scroll, top, caret_width, line_height);
        ctx.fillColor(drawable.look.caret);
        ctx.fill();
    }
};

/// The width of the text before `offset`, in `font`.
fn widthTo(ctx: *const roop.Context, font: roop.Font, view: *const text_editor.View, offset: u32) f32 {
    const pieces = view.range(0, offset);
    const first = ctx.measureText(font, pieces[0]).w;
    const second = ctx.measureText(font, pieces[1]).w;
    return first + second;
}

/// What draws `buffer` as a field; null for a buffer not open.
pub fn fieldDrawable(tables: *Table.Registry, buffer: Atom, look: FieldLook, scroll_x: *f32) ?FieldDrawable {
    const row = text_editor.rowOf(tables, buffer) orelse return null;
    if (row.view_address.* == 0) return null;
    return .{
        .view = @ptrFromInt(row.view_address.*),
        .caret = @intCast(row.caret.*),
        .anchor = @intCast(row.anchor.*),
        .look = look,
        .scroll_x = scroll_x,
    };
}

test "every edit command has an action routing it by its value" {
    for (edit_commands, 0..) |command, index| {
        try std.testing.expectEqualStrings("text_editor_command", actions[index].tag);
        try std.testing.expectEqual(@intFromEnum(command), actions[index].params[0]);
        try std.testing.expectEqualStrings(@tagName(command), actions[index].name);
    }
}

/// Expects `key`, a key of a text action, to trigger as its action does: `repeat` for a command
/// a held key repeats (`repeats`), `once` for any other.
fn expectTextTrigger(key: keybinds.KeyDef) !void {
    const name = key.action[1];
    const defined = for (actions) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) break true;
    } else false;
    try std.testing.expect(defined);
    const command = std.meta.stringToEnum(EditCommand, name);
    const repeating = if (command) |found| repeats(found) else false;
    const expected: plugin.action_api.Trigger = if (repeating) .repeat else .once;
    try std.testing.expectEqual(expected, key.trigger);
}

test "each of text_keys names a text action and repeats only for a command a held key repeats" {
    for (text_keys) |key| {
        try std.testing.expectEqualStrings("text", key.action[0]);
        try expectTextTrigger(key);
    }
}

test "each of cua_keys repeats as text_keys do, a text panel's once, and an unbinding binds nothing" {
    for (cua_keys) |key| {
        const mode_text = key.action[0];
        if (mode_text.len == 0) {
            try std.testing.expectEqualStrings("", key.action[1]);
            try std.testing.expectEqual(plugin.action_api.Trigger.once, key.trigger);
        } else if (std.mem.eql(u8, mode_text, "text")) {
            try expectTextTrigger(key);
        } else {
            try std.testing.expectEqualStrings("buffer", mode_text);
            try std.testing.expectEqual(plugin.action_api.Trigger.once, key.trigger);
        }
    }
}

test "keymapInUse reads a settings row that holds only text_keymap" {
    var memory: mesha.memory.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: mesha.Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 16);
    defer tables.deinit();
    try keybinds.init(&atoms, &tables);
    try std.testing.expectEqual(Keymap.emacs, keymapInUse(&tables));

    // As the toggle writes it: the other cells are absent.
    const schema = tables.getSchema(settings_table).?;
    _ = try tables.ensureSingleton(schema, settings_table, .{ .text_keymap = keymapAtom(.cua) }, .durable);
    try std.testing.expectEqual(Keymap.cua, keymapInUse(&tables));
}
