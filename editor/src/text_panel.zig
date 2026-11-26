//! The text panels: a panel for each open file, showing a buffer of the text editor system.
//!
//! The system holds the text and knows nothing of how it looks. A panel reads its buffer's
//! view and draws the lines that fit, in a monospace font, with the selection, the current
//! line and the caret; it turns typing and the text editor's actions into commands for the
//! buffer, and keeps the caret in sight as the buffer's changes come back as events.
//!
//! A panel is a row of `editor_text_panels`: which buffer it shows and how far it is
//! scrolled. Its id is one of a fixed set of names, taken while it is open, so opening files
//! through a session interns nothing.

const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const roop = mesha.roop;
const plugin = mesha.plugin;
const input = mesha.input;
const os = mesha.os;
const resources = mesha.resources;
const memory_mod = mesha.memory;
const panels_mod = mesha.panels;
const panel_frame = @import("panel_frame.zig");
const sequencer = mesha.sequencer;
const action_palette = @import("action_palette.zig");
const shared = @import("text_editor.zig");
const style = @import("ui/style.zig");
const fixed_panels = @import("fixed_panels.zig");
const figure_workspace = @import("figure/workspace.zig");
const buffer_list = @import("buffer_list.zig");
const open_mod = @import("open.zig");
const modes = @import("modes.zig");
const state_mod = @import("state.zig");
const Log = mesha.log.scope("text_panel");

const text_editor = plugin.text_editor_api;
const lsp = plugin.lsp_api;

const Zone = enum { text_panel_render };

/// The panels' root: a panel draws again when the system changes a table.
pub const text_panel_root = Atom.from("text_panel");

/// How many windows can show at once. A window shows one buffer; a buffer may show in
/// several, each keeping its own place in it (see the windows' points below).
pub const max_panels = 16;

comptime {
    // A window keeps its point as its buffer's marker of the window's own number.
    std.debug.assert(max_panels <= text_editor.marker_count);
}

const panel_names: [max_panels][]const u8 = blk: {
    var names: [max_panels][]const u8 = undefined;
    for (&names, 0..) |*name, slot| name.* = std.fmt.comptimePrint("text_panel_{d:0>2}", .{slot});
    break :blk names;
};

const panel_ids: [max_panels]Atom = blk: {
    var ids: [max_panels]Atom = undefined;
    for (&ids, panel_names) |*id, name| id.* = Atom.from(name);
    break :blk ids;
};

/// A size the text draws at: the font for ASCII, and the one that has the characters past
/// ASCII it lacks. Each loads the first time a panel draws at its size; ctrl+wheel steps a
/// panel through them.
pub const TextSize = struct {
    pixel_height: f32,
    font: resources.Font,
    extra_font: resources.Font,
};

const mono_file = "fonts/RobotoMonoNerdFontMono-Regular.ttf";

fn textSize(comptime pixel_height: comptime_int) TextSize {
    return .{
        .pixel_height = pixel_height,
        .font = .init(.{ .plugin = "editor", .path = mono_file, .pixel_height = pixel_height }),
        .extra_font = .init(.{ .plugin = "editor", .path = mono_file, .pixel_height = pixel_height, .glyph_codepoints = &extra_codepoints }),
    };
}

/// The sizes a panel zooms through, smallest first.
pub const text_sizes = [_]TextSize{ textSize(10), textSize(12), textSize(14), textSize(16), textSize(18), textSize(20), textSize(24), textSize(28) };
/// The index in `text_sizes` a panel opens at: 18 pixels.
const default_text_size: u8 = 6;

/// The characters `extra_font` holds: Latin-1 punctuation and letters, and the typographic
/// marks prose most often has. Any other character draws as a box.
pub const extra_codepoints: [106]u32 = blk: {
    var codepoints: [106]u32 = undefined;
    var count: usize = 0;
    var latin: u32 = 0xA1;
    while (latin <= 0xFF) : (latin += 1) {
        codepoints[count] = latin;
        count += 1;
    }
    for ([_]u32{ 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x2190, 0x2192, 0x20AC }) |mark| {
        codepoints[count] = mark;
        count += 1;
    }
    break :blk codepoints;
};

const padding: f32 = 8;
const line_spacing: f32 = 4;
const caret_width: f32 = 2;
const tab_width: u8 = 4;

const no_atom: Atom = @enumFromInt(0);

/// The buffer a compile's output is kept in (`text_tools.zig`): emptied for each compile,
/// and shown in another window as it is made.
pub const compilation_name = "*compilation*";
pub const compilation_buffer = Atom.from(compilation_name);

// ---- the panels' table ----------------------------------------------------------------------

pub const table_name = "editor_text_panels";
const panels_table = Atom.from(table_name);

const PanelRow = struct {
    /// The panel's id: one of `panel_ids`.
    panel: *Atom,
    buffer: *Atom,
    /// Whether the panels system has shown the panel since the row was made. A row whose
    /// panel was shown and is gone was closed or replaced, and goes.
    shown: *u8,
    /// How far the text is scrolled, in pixels.
    scroll_x: *f32,
    scroll_y: *f32,
    /// The height of a line and the width of a cell at the row's text size, which
    /// `followMetrics` keeps from the font's metrics; zero until the font is loaded.
    line_height: *f32,
    cell_width: *f32,
    /// The buffer's state the panel last heard of. Writing it is what draws the panel again.
    serial: *u32,
    /// The page length the buffer was last told, in lines.
    page_lines: *u32,
    /// Where the window opens, which the panels system reads as it first shows it: beside
    /// this panel (none: along the window's edge), on this `plugin.panels.Side`, taking the
    /// focus or not (a `plugin.panels.FocusOnOpen`).
    open_beside: *Atom,
    open_side: *u8,
    open_focus: *u8,
    /// A press in the text is held: moving the pointer extends the selection.
    dragging: *u8,
    /// The buffer is to close once its save succeeds.
    closing: *u8,
    /// A `Notice`: what last went wrong, said in the header until the buffer next changes.
    notice: *u8,
    /// An `Awaiting`: what the next character typed is for.
    awaiting: *u8,
    /// What the language server last said of the buffer, as `events.lsp` told it. Writing
    /// it draws the panel again with the server's colours and diagnostics.
    lsp_serial: *u32,
    /// What the server said a name is, shown in the header until the buffer next changes.
    info: []const u8,
    /// Typing was subscribed for this panel at the system's last run: it had the keyboard.
    typing: *u8,
    /// The size the text draws at, an index in `text_sizes`: ctrl+wheel changes it.
    text_size: *u8,
    /// A `Recenter`: where the next `recenter` in a row puts the caret's line.
    recenter: *u8,
    /// An `Argument`: how far the count before the next command has been typed.
    argument_state: *u8,
    /// The count, while `argument_state` says there is one.
    argument: *u32,
    /// A `Search`: whether the panel is searching as its text is typed, and which way.
    search: *u8,
    /// Where the caret was when the search began: where it starts from and a cancel returns.
    search_origin: *u32,
    /// The search's text is not found from where it looks.
    search_failing: *u8,
    /// A `Replace`: how far a search and replace has got.
    replace: *u8,
    /// The stretch of the text the replace covers: the selection it began with, or from the
    /// caret to the text's end. The end moves with each replacement made before it.
    replace_start: *u32,
    replace_end: *u32,
    /// The replacements made so far.
    replace_count: *u32,
    /// Counts the changes to what the replace's prompt holds: writing it draws the panel
    /// again with the matches and what would replace them.
    replace_preview: *u32,
    /// Of the windows showing its buffer, this is the one whose point is the buffer's caret.
    current: *u8,
    /// The window's point is kept as its buffer's marker, to take back when it is the
    /// current window again.
    has_point: *u8,
    /// The buffer's history is shown as a tree along the window's bottom, and the keys walk it.
    history_shown: *u8,
    /// The state the text was in when the tree was shown: where giving the walk up returns.
    history_origin: *u32,
    /// A `Jump`: the kind of place a jump by letters is choosing among, or none.
    jump: *u8,
    /// How many characters of what the jump looks for are typed, and those characters'
    /// bytes, the first lowest: a jump has two at most, of four bytes each.
    jump_typed: *u8,
    jump_needle: *u64,
    /// The first letter typed of a place's two-letter name; 0 before it.
    jump_letter: *u8,
    /// A `Completing`: whether completions were asked for, or are listed at the caret.
    completing: *u8,
    /// Where what is being completed begins: the completions are those that begin as the
    /// text from here to the caret does.
    completion_start: *u32,
    /// Which of the completions listed is chosen, counted among those listed.
    completion_selected: *u32,
};

/// How far a completion at the caret has got.
const Completing = enum(u8) {
    none,
    /// Asked of the language server, by the key that only completes.
    asked,
    /// Asked by the key that indents when there is nothing to complete.
    asked_or_indent,
    /// The completions are listed at the caret.
    listed,
};

/// How far a search and replace has got, as Emacs's `query-replace`: asking what to
/// replace, asking what with, then asking at each match.
const Replace = enum(u8) { none, from, to, asking };

/// A search as its text is typed, as Emacs's `isearch`: none, or the way it looks.
const Search = enum(u8) { none, forward, backward };

/// How far a count before a command has been typed, as Emacs's `C-u` and `M-5` begin one.
const Argument = enum(u8) {
    none,
    /// `C-u` alone, which counts four, and four times over for each `C-u` after it.
    universal,
    /// Digits were typed: more digits go on with the count.
    digits,
    /// A `C-u` after the digits ended the count: a digit typed now is text, typed that often.
    sealed,
};

/// The most a count is typed up to: more digits leave it there.
const max_argument = 99_999;

/// Where `recenter` puts the caret's line: the middle, and when asked again at once the top,
/// then the bottom, as Emacs's `recenter-top-bottom`.
const Recenter = enum(u8) {
    middle,
    top,
    bottom,

    fn next(place: Recenter) Recenter {
        return switch (place) {
            .middle => .top,
            .top => .bottom,
            .bottom => .middle,
        };
    }
};

/// What the next character typed in a panel is for, when it is not text.
const Awaiting = enum(u8) {
    none,
    /// The character to zap up to.
    zap,
    /// The character to zap through.
    zap_through,
    /// The name of the register the selection's text is copied to.
    register_copy,
    /// The name of the register whose text is inserted.
    register_insert,
    /// The name of the register the caret's place is kept in.
    register_point,
    /// The name of the register whose place is gone to.
    register_jump,
};

/// What a panel's header says went wrong.
const Notice = enum(u8) {
    none,
    save_failed,
    cannot_encode,

    fn text(notice: Notice) []const u8 {
        return switch (notice) {
            .none => "",
            .save_failed => "Could not write the file",
            .cannot_encode => "The text has characters its encoding cannot hold",
        };
    }
};

/// The places a jump to a definition left, the latest last: where `text_go_back` returns.
pub const jumps_table_name = "editor_text_jumps";
const jumps_table = Atom.from(jumps_table_name);
const max_jumps = 32;

const JumpRow = struct {
    /// Counts up: the latest jump has the highest.
    order: *u32,
    path: []const u8,
    line: *u32,
    /// In bytes from the line's start.
    column: *u32,
};

/// A place to put the caret once the file asked for has opened: a definition, or a jump back.
pub const navigation_table_name = "editor_text_navigation";
const navigation_table = Atom.from(navigation_table_name);

const NavigationRow = struct {
    pending: *u8,
    line: *u32,
    /// In bytes from the line's start.
    column: *u32,
    /// The buffer next shown goes in a window other than the focused one, as Emacs's
    /// `C-x 4` commands show theirs. Any key in a panel that shows nothing drops it.
    other_window: *u8,
};

/// `editor_text_buffer_modes`: the buffers whose windows have a major mode of their own in
/// place of `buffer`, a row each (`BufferModeRow`), set by `setBufferMode` and dropped as the
/// buffer closes. Its mode's parent is `buffer`, so every key of a text window still works.
pub const buffer_modes_table_name = "editor_text_buffer_modes";
const buffer_modes_table = Atom.from(buffer_modes_table_name);

const BufferModeRow = struct { buffer: *Atom, mode: *Atom };

/// `editor_text_show_requests`: the buffers `showBuffer` was asked to show, a row each
/// (`ShowRequestRow`). A row is asked until the panels' run shows its buffer, once it is open,
/// and is dropped when the buffer has not opened after `max_show_waits` runs; shown, it keeps
/// the window it went in and what that window showed before, until the buffer closes (the window
/// shows that again, or closes when it was made for it) or the person puts another buffer in it.
pub const show_requests_table_name = "editor_text_show_requests";
const show_requests_table = Atom.from(show_requests_table_name);
/// The most buffers asked to show, or shown and remembered, at once.
const max_show_requests = 8;
/// How many of the panels' runs a buffer asked to show may take to open before the request,
/// and the buffer's own mode, are dropped: its making was refused. A maker that gives up on the
/// buffer itself waits no longer than this, so the buffer is never opened unshown.
pub const max_show_waits = 10;

const ShowRequestRow = struct {
    buffer: *Atom,
    /// A `Place`.
    place: *u8,
    /// 1 once the buffer is shown; 0 while it is asked.
    shown: *u8,
    /// While asked, the panels' runs it has waited for the buffer to open.
    waits: *u8,
    /// Once shown, the window it went in.
    panel: *Atom,
    /// What that window showed before it; none when the window was made for it.
    previous: *Atom,
};

/// Which window `showBuffer` shows a buffer in.
pub const Place = enum(u8) {
    /// A window that already shows it, which takes the focus; else the focused text window, in
    /// place of what it showed; else a new window beside the focused panel.
    this_window,
    /// A window that already shows it, else a text window other than the focused panel (the
    /// first in the panels' table, when there are several), which shows it in place of what it
    /// showed, else a new one beside the focused panel: the window takes the focus. With a panel
    /// that is no text window focused (vcs-git), that is a text window, never the panel.
    other_window,
};

/// Asks the panels' run to show `buffer` at `place`, as `C-x b` shows one, in place of what was
/// asked before and not yet taken. A buffer not open yet is shown once it opens, so a caller may
/// ask the text editor to make it and show it in the same run; one that has not opened after a
/// few runs is forgotten. When the buffer closes, its window shows again what it showed before
/// it and gives the focus back to the panel that had it before, or closes when it was made for
/// it, which gives the focus back too. A journaled system that calls this declares
/// `editor_text_show_requests` written.
pub fn showBuffer(tables: *Table.Registry, buffer: Atom, place: Place) void {
    const requests = tables.findByName(show_requests_table) orelse return;
    forgetAsked(requests, null);
    // Full of shown buffers, the oldest remembered is forgotten.
    if (requests.count() >= requests.rowCapacity()) {
        var rows = requests.readQuery(ShowRequestRow);
        if (rows.next()) |oldest| requests.free(oldest.handle);
    }
    _ = requests.tryInsert(.{
        .buffer = buffer,
        .place = @as(u8, @intFromEnum(place)),
        .shown = @as(u8, 0),
        .waits = @as(u8, 0),
        .panel = no_atom,
        .previous = no_atom,
    }) catch |err| {
        Log.err("text_panel_show_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// Forgets that `buffer` was asked to show and is not shown yet, as when its maker gives it up:
/// nothing is shown when it opens. A journaled system that calls this declares
/// `editor_text_show_requests` written.
pub fn forgetShowRequest(tables: *Table.Registry, buffer: Atom) void {
    const requests = tables.findByName(show_requests_table) orelse return;
    forgetAsked(requests, buffer);
}

/// Frees the rows of `requests` still asked, of `buffer`, or of any buffer when null.
fn forgetAsked(requests: *Table, buffer: ?Atom) void {
    var asked: [max_show_requests]Table.RowHandle = undefined;
    var asked_count: usize = 0;
    var rows = requests.readQuery(ShowRequestRow);
    while (rows.next()) |found| {
        if (found.view.shown.* != 0 or asked_count == asked.len) continue;
        if (buffer) |only| {
            if (found.view.buffer.* != only) continue;
        }
        asked[asked_count] = found.handle;
        asked_count += 1;
    }
    for (asked[0..asked_count]) |asked_row| requests.free(asked_row);
}

/// Gives every window on `buffer` the major mode `mode`, whose parent is `buffer`, in place of
/// `buffer`, until the buffer closes; `buffer` itself as `mode` takes the buffer's own mode
/// away. A journaled system that calls this declares `editor_text_buffer_modes` written.
pub fn setBufferMode(tables: *Table.Registry, buffer: Atom, mode: Atom) void {
    const buffer_modes = tables.findByName(buffer_modes_table) orelse return;
    var rows = buffer_modes.query(BufferModeRow);
    while (rows.next()) |found| {
        if (found.view.buffer.* != buffer) continue;
        if (mode == modes.buffer) {
            buffer_modes.free(found.handle);
        } else {
            found.view.mode.* = mode;
        }
        return;
    }
    if (mode == modes.buffer) return;
    _ = buffer_modes.tryInsert(.{ .buffer = buffer, .mode = mode }) catch |err| {
        Log.err("text_panel_mode_unrecorded", .{ .@"error" = @errorName(err) });
    };
}

/// The major mode of a window on `buffer`: its own (`setBufferMode`), else `buffer`.
fn bufferMode(buffer_modes: *Table, buffer: Atom) Atom {
    var rows = buffer_modes.readQuery(BufferModeRow);
    while (rows.next()) |found| {
        if (found.view.buffer.* == buffer) return found.view.mode.*;
    }
    return modes.buffer;
}

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&panel_names);
    for (text_sizes) |size| try atoms.tryInternAll(&.{ size.font.label, size.extra_font.label });
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 44);
    defer schema.deinit();
    try schema.addFieldFallible("panel", Atom, .atom);
    try schema.addFieldFallible("buffer", Atom, .atom);
    try schema.addFieldFallible("shown", u8, .int);
    try schema.addFieldFallible("scroll_x", f32, .int);
    try schema.addFieldFallible("scroll_y", f32, .int);
    try schema.addFieldFallible("line_height", f32, .int);
    try schema.addFieldFallible("cell_width", f32, .int);
    try schema.addFieldFallible("serial", u32, .int);
    try schema.addFieldFallible("page_lines", u32, .int);
    try schema.addFieldFallible("open_beside", Atom, .atom);
    try schema.addFieldFallible("open_side", u8, .int);
    try schema.addFieldFallible("open_focus", u8, .int);
    try schema.addFieldFallible("dragging", u8, .int);
    try schema.addFieldFallible("closing", u8, .int);
    try schema.addFieldFallible("notice", u8, .int);
    try schema.addFieldFallible("awaiting", u8, .int);
    try schema.addFieldFallible("lsp_serial", u32, .int);
    try schema.addFieldFallible("info", Table.String, .text_field);
    try schema.addFieldFallible("typing", u8, .int);
    try schema.addFieldFallible("text_size", u8, .int);
    try schema.addFieldFallible("recenter", u8, .int);
    try schema.addFieldFallible("argument_state", u8, .int);
    try schema.addFieldFallible("argument", u32, .int);
    try schema.addFieldFallible("search", u8, .int);
    try schema.addFieldFallible("search_origin", u32, .int);
    try schema.addFieldFallible("search_failing", u8, .int);
    try schema.addFieldFallible("replace", u8, .int);
    try schema.addFieldFallible("replace_start", u32, .int);
    try schema.addFieldFallible("replace_end", u32, .int);
    try schema.addFieldFallible("replace_count", u32, .int);
    try schema.addFieldFallible("replace_preview", u32, .int);
    try schema.addFieldFallible("current", u8, .int);
    try schema.addFieldFallible("has_point", u8, .int);
    try schema.addFieldFallible("history_shown", u8, .int);
    try schema.addFieldFallible("history_origin", u32, .int);
    try schema.addFieldFallible("jump", u8, .int);
    try schema.addFieldFallible("jump_typed", u8, .int);
    try schema.addFieldFallible("jump_needle", u64, .int);
    try schema.addFieldFallible("jump_letter", u8, .int);
    try schema.addFieldFallible("completing", u8, .int);
    try schema.addFieldFallible("completion_start", u32, .int);
    try schema.addFieldFallible("completion_selected", u32, .int);
    _ = try tables.ensure(&schema, max_panels, panels_table, .durable);

    try atoms.tryInternAll(&.{ jumps_table_name, navigation_table_name });
    var jumps: Table.Schema = undefined;
    try jumps.init(scratch.allocator, atoms, 4);
    defer jumps.deinit();
    try jumps.addFieldFallible("order", u32, .int);
    try jumps.addFieldFallible("path", Table.String, .text_field);
    try jumps.addFieldFallible("line", u32, .int);
    try jumps.addFieldFallible("column", u32, .int);
    _ = try tables.ensure(&jumps, max_jumps, jumps_table, .durable);

    var navigation: Table.Schema = undefined;
    try navigation.init(scratch.allocator, atoms, 4);
    defer navigation.deinit();
    try navigation.addFieldFallible("pending", u8, .int);
    try navigation.addFieldFallible("line", u32, .int);
    try navigation.addFieldFallible("column", u32, .int);
    try navigation.addFieldFallible("other_window", u8, .int);
    _ = try tables.ensureSingleton(&navigation, navigation_table, .{ .pending = @as(u8, 0), .line = @as(u32, 0), .column = @as(u32, 0), .other_window = @as(u8, 0) }, .durable);
    try shared.ensureSettings(tables);

    try atoms.tryInternAll(&.{ buffer_modes_table_name, show_requests_table_name });
    var buffer_modes: Table.Schema = undefined;
    try buffer_modes.init(scratch.allocator, atoms, 2);
    defer buffer_modes.deinit();
    try buffer_modes.addFieldFallible("buffer", Atom, .atom);
    try buffer_modes.addFieldFallible("mode", Atom, .atom);
    _ = try tables.ensure(&buffer_modes, text_editor.max_buffers, buffer_modes_table, .durable);

    var show_requests: Table.Schema = undefined;
    try show_requests.init(scratch.allocator, atoms, 6);
    defer show_requests.deinit();
    try show_requests.addFieldFallible("buffer", Atom, .atom);
    try show_requests.addFieldFallible("place", u8, .int);
    try show_requests.addFieldFallible("shown", u8, .int);
    try show_requests.addFieldFallible("waits", u8, .int);
    try show_requests.addFieldFallible("panel", Atom, .atom);
    try show_requests.addFieldFallible("previous", Atom, .atom);
    _ = try tables.ensure(&show_requests, max_show_requests, show_requests_table, .durable);

    try atoms.tryInternAll(&.{ registers_table_name, macro_table_name, macro_state_table_name });
    var registers: Table.Schema = undefined;
    try registers.init(scratch.allocator, atoms, 5);
    defer registers.deinit();
    try registers.addFieldFallible("name", u32, .int);
    try registers.addFieldFallible("kind", u8, .int);
    try registers.addFieldFallible("text", Table.String, .text_field);
    try registers.addFieldFallible("buffer", Atom, .atom);
    try registers.addFieldFallible("offset", u32, .int);
    _ = try tables.ensure(&registers, max_registers, registers_table, .durable);

    var macro: Table.Schema = undefined;
    try macro.init(scratch.allocator, atoms, 4);
    defer macro.deinit();
    try macro.addFieldFallible("kind", u8, .int);
    try macro.addFieldFallible("command", u8, .int);
    try macro.addFieldFallible("count", u32, .int);
    try macro.addFieldFallible("text", Table.String, .text_field);
    _ = try tables.ensure(&macro, max_macro_steps, macro_table, .durable);

    var macro_state: Table.Schema = undefined;
    try macro_state.init(scratch.allocator, atoms, 1);
    defer macro_state.deinit();
    try macro_state.addFieldFallible("recording", u8, .int);
    _ = try tables.ensureSingleton(&macro_state, macro_state_table, .{ .recording = @as(u8, 0) }, .durable);

    try atoms.tryInternAll(&.{ completions_table_name, symbols_table_name });
    var completions: Table.Schema = undefined;
    try completions.init(scratch.allocator, atoms, 3);
    defer completions.deinit();
    try completions.addFieldFallible("label", Table.String, .text_field);
    try completions.addFieldFallible("inserted", Table.String, .text_field);
    try completions.addFieldFallible("detail", Table.String, .text_field);
    _ = try tables.ensure(&completions, lsp.max_items, completions_table, .durable);

    var symbols: Table.Schema = undefined;
    try symbols.init(scratch.allocator, atoms, 4);
    defer symbols.deinit();
    try symbols.addFieldFallible("name", Table.String, .text_field);
    try symbols.addFieldFallible("kind", Table.String, .text_field);
    try symbols.addFieldFallible("line", u32, .int);
    try symbols.addFieldFallible("column", u32, .int);
    _ = try tables.ensure(&symbols, lsp.max_items, symbols_table, .durable);

    try atoms.tryInternAll(&.{searches_table_name});
    var searches: Table.Schema = undefined;
    try searches.init(scratch.allocator, atoms, 3);
    defer searches.deinit();
    try searches.addFieldFallible("last", Table.String, .text_field);
    try searches.addFieldFallible("replace_from", Table.String, .text_field);
    try searches.addFieldFallible("replace_to", Table.String, .text_field);
    _ = try tables.ensureSingleton(&searches, searches_table, .{ .last = Table.String{}, .replace_from = Table.String{}, .replace_to = Table.String{} }, .durable);

    try atoms.tryInternAll(&.{encodings_table_name});
    var encodings: Table.Schema = undefined;
    try encodings.init(scratch.allocator, atoms, 3);
    defer encodings.deinit();
    try encodings.addFieldFallible("name", Table.String, .text_field);
    try encodings.addFieldFallible("supported", u8, .int);
    try encodings.addFieldFallible("typed", u8, .int);
    _ = try tables.ensure(&encodings, max_encoding_answers, encodings_table, .durable);

    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
}

/// The registers, a row each: a text copied there or a place kept there, by the character
/// that names it, as Emacs's `C-x r` commands keep them.
pub const registers_table_name = "editor_text_registers";
const registers_table = Atom.from(registers_table_name);
const max_registers = 64;
/// The most text a register keeps.
const max_register_bytes = 1024 * 1024;
const RegisterKind = enum(u8) { text, place };
const RegisterRow = struct {
    /// The character that names it.
    name: *u32,
    /// A `RegisterKind`.
    kind: *u8,
    text: []const u8,
    /// For a place: the buffer it is in, and where.
    buffer: *Atom,
    offset: *u32,
};

/// The keyboard macro last defined, a row for each of its steps in order: an edit command
/// run so many times, or text typed so many times.
pub const macro_table_name = "editor_text_macro";
const macro_table = Atom.from(macro_table_name);
/// The most steps a macro keeps: what is done past them while it is defined is not in it.
const max_macro_steps = 1024;
const MacroStepKind = enum(u8) { command, text, zap_up_to, zap_through };
const MacroStep = struct {
    /// A `MacroStepKind`.
    kind: *u8,
    /// For a command: the `EditCommand`.
    command: *u8,
    count: *u32,
    /// For text and a zap: the characters.
    text: []const u8,
};

/// Whether a keyboard macro is being defined, one row.
pub const macro_state_table_name = "editor_text_macro_state";
const macro_state_table = Atom.from(macro_state_table_name);
const MacroState = struct { recording: *u8 };

/// What the language server last said could be typed at the caret, a row each, in its order:
/// the completion listed there.
pub const completions_table_name = "editor_text_completions";
const completions_table = Atom.from(completions_table_name);
const CompletionRow = struct {
    /// What it is called: what is matched against the text typed.
    label: []const u8,
    /// What it puts in the text.
    inserted: []const u8,
    /// What the server says of it: its type, mostly.
    detail: []const u8,
};

/// What the language server last said a buffer defines, a row each: what `text_goto_symbol`
/// chooses among.
pub const symbols_table_name = "editor_text_symbols";
const symbols_table = Atom.from(symbols_table_name);
const SymbolRow = struct {
    name: []const u8,
    kind: []const u8,
    line: *u32,
    /// In bytes from the line's start.
    column: *u32,
};

/// What the panels remember of searching, one row: the text last searched for, which a
/// search asked for again with nothing typed takes up, and what the replace under way
/// replaces and puts in its place.
pub const searches_table_name = "editor_text_searches";
const searches_table = Atom.from(searches_table_name);
const SearchesRow = struct { last: *Table.String, replace_from: *Table.String, replace_to: *Table.String };

/// What the host said of the encodings it was asked about, a row each: each of
/// `text_editor.known_encodings`, in their order, once its answer to the ask the first
/// encodings' prompt makes is in, and then the names typed in an encodings' prompt. A name with no row has no
/// answer yet, and is not offered.
pub const encodings_table_name = "editor_text_encodings";
const encodings_table = Atom.from(encodings_table_name);
/// The most names typed the table keeps: past them it forgets them all and starts again.
const max_typed_encodings = 32;
const max_encoding_answers = text_editor.known_encodings.len + max_typed_encodings;
const EncodingRow = struct {
    name: []const u8,
    supported: *u8,
    /// Typed in a prompt, not one of the known names.
    typed: *u8,
};

/// A text the panels remember, as `SearchesRow` names it; empty until it is set. The slice
/// is the table's until it is next written.
fn rememberedText(tables: *Table.Registry, comptime field: []const u8) []const u8 {
    const searches = tables.findByName(searches_table) orelse return "";
    var rows = searches.readQuery(SearchesRow);
    const row = rows.next() orelse return "";
    return searches.textOf(@field(row.view, field).*);
}

fn rememberText(tables: *Table.Registry, comptime field: []const u8, text: []const u8) void {
    const searches = tables.findByName(searches_table) orelse return;
    const row: Table.RowHandle = .{ .row = 0, .generation = searches.rowGeneration(0) };
    searches.setString(row, field, text) catch |err| Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
}

fn panelsTable(tables: *Table.Registry) ?*Table {
    return tables.findByName(panels_table);
}

fn rowOfPanel(table: *Table, panel: Atom) ?struct { handle: Table.RowHandle, row: PanelRow } {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.panel.* == panel) return .{ .handle = found.handle, .row = found.view };
    }
    return null;
}

/// A panel's row as code that only reads sees it: drawing, and the helpers it shares with
/// the kernels.
const ReadRow = Table.ReadView(PanelRow);

fn readRow(row: PanelRow) ReadRow {
    return Table.readViewOf(PanelRow, row);
}

/// The row of `panel`, to read: what drawing takes, which writes no table.
fn readRowOfPanel(table: *Table, panel: Atom) ?ReadRow {
    var rows = table.readQuery(PanelRow);
    while (rows.next()) |found| {
        if (found.view.panel.* == panel) return found.view;
    }
    return null;
}

/// A line's height and a cell's width at a text size.
const Cell = struct { line_height: f32, cell_width: f32 };

const font_metrics_table = Atom.from(resources.font_metrics_table_name);
const declared_panels_table = Atom.from(plugin.panels.declared_table_name);

/// The cell of the size `text_size` names, from the metrics of its font; null until the font
/// is loaded.
fn cellOf(metrics: *Table, text_size: u8) ?Cell {
    const size_index = @min(text_size, text_sizes.len - 1);
    const font = text_sizes[size_index].font;
    const measured = resources.fontMetrics(metrics, resources.kApplicationScope, font.name) orelse return null;
    if (measured.pixel_height <= 0 or measured.mono_advance <= 0) return null;
    return .{ .line_height = measured.pixel_height + line_spacing, .cell_width = measured.mono_advance };
}

/// Whether `row` scrolls by another cell than its text size's font has: after a zoom, or
/// once the font has loaded.
fn cellChanged(metrics: *Table, row: ReadRow) bool {
    const cell = cellOf(metrics, row.text_size.*) orelse return false;
    return cell.line_height != row.line_height.* or cell.cell_width != row.cell_width.*;
}

/// The window showing `buffer` whose point is the buffer's caret, or failing that any
/// window showing it.
fn rowOfBuffer(table: *Table, buffer: Atom) ?PanelRow {
    var any: ?PanelRow = null;
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.buffer.* != buffer) continue;
        if (found.view.current.* != 0) return found.view;
        if (any == null) any = found.view;
    }
    return any;
}

// ---- the windows' points ----------------------------------------------------------------------
//
// A buffer has one caret, and may show in several windows. One of them is the buffer's
// current window: its point is the caret. Each other keeps its point as one of the buffer's
// markers, the one of the window's own number, which the buffer moves with its text. The
// focused window is always its buffer's current one; a window that stops being current
// leaves its point in its marker, and takes it back from there when it is current again.

/// The panel whose buffer's history is shown as a tree, if one is.
fn historyRow(table: *Table) ?PanelRow {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.history_shown.* != 0) return found.view;
    }
    return null;
}

/// The number of a window, which is also the marker it keeps its point in.
fn slotOf(panel: Atom) u8 {
    const slot = std.mem.indexOfScalar(Atom, &panel_ids, panel) orelse 0;
    return @intCast(slot);
}

fn currentRowOf(table: *Table, buffer: Atom) ?PanelRow {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.buffer.* == buffer and found.view.current.* != 0) return found.view;
    }
    return null;
}

/// `row`'s window stops being its buffer's current one: its point stays in its marker.
fn leavePoint(tables: *Table.Registry, row: PanelRow) void {
    row.current.* = 0;
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const caret: u32 = @intCast(state.caret.*);
    text_editor.request(tables.memory, tables, .{ .set_marker = .{ .buffer = row.buffer.*, .marker = slotOf(row.panel.*), .offset = caret } });
    row.has_point.* = 1;
}

/// `row`'s window becomes its buffer's current one. `restore` puts the caret back at the
/// point the window kept; a click that is about to place the caret itself keeps it.
fn takePoint(tables: *Table.Registry, table: *Table, row: PanelRow, point: enum { restore, keep }) void {
    if (row.current.* != 0) return;
    if (currentRowOf(table, row.buffer.*)) |previous| leavePoint(tables, previous);
    row.current.* = 1;
    if (point == .keep or row.has_point.* == 0) return;
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return;
    const offset = view.markers[slotOf(row.panel.*)];
    text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = offset, .caret = offset } });
}

/// Makes the focused window its buffer's current one, and gives every buffer whose current
/// window went, closed or showing another buffer now, one of the windows it still has.
fn settleWindows(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table) void {
    const focused = panels_mod.focusedTarget(tables, atoms).id;
    if (rowOfPanel(table, focused)) |found| takePoint(tables, table, found.row, .restore);
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (currentRowOf(table, found.view.buffer.*) != null) continue;
        takePoint(tables, table, found.view, .restore);
    }
}

/// Sets what the header says a name is, cut to its first line.
fn setInfo(table: *Table, panel: Atom, text: []const u8) void {
    const found = rowOfPanel(table, panel) orelse return;
    const first_line = std.mem.sliceTo(std.mem.trim(u8, text, " \n"), '\n');
    const shown = utf8Prefix(first_line, max_info_bytes);
    table.setString(found.handle, "info", shown) catch |err| Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
}

/// The most of a header message shown.
const max_info_bytes = 120;

/// The longest start of `text` no longer than `limit` bytes that ends between characters.
fn utf8Prefix(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

/// Whether `id` is a text panel's, open or not.
pub fn isPanel(id: Atom) bool {
    return std.mem.indexOfScalar(Atom, &panel_ids, id) != null;
}

/// The part of a text window's row `windowFile` reads: the window and the buffer it shows.
pub const WindowBufferRow = struct { panel: *Atom, buffer: *Atom };

/// The file of the buffer the text window `panel` shows, by its absolute path, from `windows`,
/// the rows of `table_name`, and `buffers`, those of `text_editor.buffers_table_name`. Empty
/// when `panel` is not a text window or its buffer holds no file. The slice is the buffers
/// table's, good for the reader's run.
pub fn windowFile(windows: Table.ReadQuery(WindowBufferRow), buffers: Table.ReadQuery(text_editor.BufferEntry), panel: Atom) []const u8 {
    var window_rows = windows;
    const buffer = while (window_rows.next()) |window| {
        if (window.view.panel.* == panel) break window.view.buffer.*;
    } else return "";
    var buffer_rows = buffers;
    while (buffer_rows.next()) |entry| {
        if (entry.view.buffer.* == buffer) return entry.view.path;
    }
    return "";
}

/// The text panel with the keyboard: the focused panel, while no prompt is over it.
fn focusedPanel(tables: *Table.Registry, atoms: *Atom.Registry) ?Atom {
    if (action_palette.requestOpen(tables, atoms)) return null;
    const focused = panels_mod.focusedTarget(tables, atoms).id;
    return if (isPanel(focused)) focused else null;
}

// ---- the system -----------------------------------------------------------------------------

const Msg = enum(u64) {
    /// The answer to the dialog that says why a file did not open.
    text_panel_open_failure_seen = Atom.from("text_panel_open_failure_seen").value(),
    /// The text editor's answers to an open and a save.
    text_panel_opened = Atom.from("text_panel_opened").value(),
    text_panel_saved = Atom.from("text_panel_saved").value(),
    /// A character typed while a text panel has the keyboard.
    text_panel_char = Atom.from("text_panel_char").value(),
    /// The pointer over the panels: a press puts the caret, a held move selects, the wheel scrolls.
    text_panel_press = Atom.from("text_panel_press").value(),
    text_panel_release = Atom.from("text_panel_release").value(),
    text_panel_move = Atom.from("text_panel_move").value(),
    text_panel_scroll = Atom.from("text_panel_scroll").value(),
    /// Asks where to save the focused panel's file, in the platform's picker.
    text_save_as = Atom.from("text_save_as").value(),
    /// The picker's answer: the path chosen, the buffer its user data.
    text_panel_save_path = Atom.from("text_panel_save_path").value(),
    /// Asks, in the palette, for the encoding or the line endings the focused panel's file
    /// is written with; and the palette's answers, the buffer their user data.
    text_set_encoding = Atom.from("text_set_encoding").value(),
    text_panel_encoding = Atom.from("text_panel_encoding").value(),
    /// Asks for the encoding to read the focused panel's file again in, and its answer.
    text_revert_with_encoding = Atom.from("text_revert_with_encoding").value(),
    text_panel_revert_encoding = Atom.from("text_panel_revert_encoding").value(),
    /// The text editor's answer to which encodings the host converts: an `EncodingAsk` its
    /// user data when it is about a name typed, none when about the known names.
    text_panel_encodings = Atom.from("text_panel_encodings").value(),
    text_set_line_ending = Atom.from("text_set_line_ending").value(),
    text_panel_line_ending = Atom.from("text_panel_line_ending").value(),
    /// What to do with a modified file whose panel is closing, the buffer its user data.
    text_panel_close_choice = Atom.from("text_panel_close_choice").value(),
    /// Asks for a line to go to, and the palette's answer.
    text_goto_line = Atom.from("text_goto_line").value(),
    text_panel_goto = Atom.from("text_panel_goto").value(),
    /// Asks for text to find, listing the lines that have it; and the palette's events.
    text_search_lines = Atom.from("text_search_lines").value(),
    text_panel_search = Atom.from("text_panel_search").value(),
    /// Asks which buffer the focused panel is to show, and the palette's answer, a
    /// `BufferScope` its user data.
    text_switch_buffer = Atom.from("text_switch_buffer").value(),
    text_panel_switch = Atom.from("text_panel_switch").value(),
    /// Asks which buffer to kill, the one shown first, and the palette's answer.
    text_kill_buffer = Atom.from("text_kill_buffer").value(),
    text_panel_kill = Atom.from("text_panel_kill").value(),
    /// Asks which of the buffers whose file lies under the working directory to show.
    text_project_switch_buffer = Atom.from("text_project_switch_buffer").value(),
    /// Kills the focused panel's buffer; the panel then shows another, or closes.
    text_close = Atom.from("text_close").value(),
    /// Kills up to the next character typed, or through it.
    text_zap_up_to = Atom.from("text_zap_up_to").value(),
    text_zap_to_char = Atom.from("text_zap_to_char").value(),
    /// Switches the text editors' keys between Emacs's and the common ones.
    text_toggle_keymap = Atom.from("text_toggle_keymap").value(),
    /// Searching as the text is typed, the way asked; again, on to the next match.
    text_isearch_forward = Atom.from("text_isearch_forward").value(),
    text_isearch_backward = Atom.from("text_isearch_backward").value(),
    /// Takes the word after the match into the search's text.
    text_isearch_yank_word = Atom.from("text_isearch_yank_word").value(),
    /// The search prompt's events.
    text_panel_isearch = Atom.from("text_panel_isearch").value(),
    /// Replaces a text with another, asking at each place it is.
    text_query_replace = Atom.from("text_query_replace").value(),
    /// The events of the replace's prompts, whichever is open.
    text_panel_replace = Atom.from("text_panel_replace").value(),
    /// A second window on the buffer, below the window or to its right.
    text_split_below = Atom.from("text_split_below").value(),
    text_split_right = Atom.from("text_split_right").value(),
    /// As switching buffers and finding a file, showing what is chosen in another window.
    text_switch_buffer_other_window = Atom.from("text_switch_buffer_other_window").value(),
    text_find_file_other_window = Atom.from("text_find_file_other_window").value(),
    /// Goes to a window chosen by its letter.
    text_select_window = Atom.from("text_select_window").value(),
    text_panel_window = Atom.from("text_panel_window").value(),
    /// Puts a text typed in place of the selection's rectangle, on each of its lines.
    text_string_rectangle = Atom.from("text_string_rectangle").value(),
    text_panel_rectangle = Atom.from("text_panel_rectangle").value(),
    /// The registers: the next character typed names the one meant.
    text_copy_to_register = Atom.from("text_copy_to_register").value(),
    text_insert_register = Atom.from("text_insert_register").value(),
    text_point_to_register = Atom.from("text_point_to_register").value(),
    text_jump_to_register = Atom.from("text_jump_to_register").value(),
    /// A keyboard macro: defining one, ending it, and doing it again.
    text_macro_start = Atom.from("text_macro_start").value(),
    text_macro_end = Atom.from("text_macro_end").value(),
    text_macro_end_or_call = Atom.from("text_macro_end_or_call").value(),
    text_macro_call = Atom.from("text_macro_call").value(),
    /// Completes what is typed at the caret from what the language server offers; or, by the
    /// key that also indents, indents when nothing is typed there.
    text_complete = Atom.from("text_complete").value(),
    text_complete_or_indent = Atom.from("text_complete_or_indent").value(),
    /// The language server's completions.
    text_panel_completions = Atom.from("text_panel_completions").value(),
    /// Goes to one of the things the buffer defines, chosen by its name.
    text_goto_symbol = Atom.from("text_goto_symbol").value(),
    text_panel_symbols = Atom.from("text_panel_symbols").value(),
    text_panel_symbol = Atom.from("text_panel_symbol").value(),
    /// Jumps to a place in sight chosen by the letters shown on it: a character typed, two
    /// characters, a word beginning with a character, or a line.
    text_jump_char = Atom.from("text_jump_char").value(),
    text_jump_char_2 = Atom.from("text_jump_char_2").value(),
    text_jump_word = Atom.from("text_jump_word").value(),
    text_jump_line = Atom.from("text_jump_line").value(),
    /// Opens one of the files opened lately, chosen by its path.
    text_recent_files = Atom.from("text_recent_files").value(),
    text_panel_recent = Atom.from("text_panel_recent").value(),
    /// Shows the buffer's history as a tree, to walk with the keys; and those keys.
    text_undo_tree = Atom.from("text_undo_tree").value(),
    text_panel_history_back = Atom.from("text_panel_history_back").value(),
    text_panel_history_forward = Atom.from("text_panel_history_forward").value(),
    text_panel_history_next = Atom.from("text_panel_history_next").value(),
    text_panel_history_previous = Atom.from("text_panel_history_previous").value(),
    text_panel_history_keep = Atom.from("text_panel_history_keep").value(),
    text_panel_history_quit = Atom.from("text_panel_history_quit").value(),
    text_toggle_read_only = Atom.from("text_toggle_read_only").value(),
    text_toggle_subword = Atom.from("text_toggle_subword").value(),
    /// A count before the next command: `C-u`, and a digit, which its user data holds.
    text_universal_argument = Atom.from("text_universal_argument").value(),
    text_digit_argument = Atom.from("text_digit_argument").value(),
    /// Asks the language server where the name at the caret is defined, and its answer.
    text_goto_definition = Atom.from("text_goto_definition").value(),
    text_panel_definition = Atom.from("text_panel_definition").value(),
    /// Returns to where the last jump to a definition left.
    text_go_back = Atom.from("text_go_back").value(),
    /// Asks the language server what the name at the caret is, and its answer.
    text_describe = Atom.from("text_describe").value(),
    text_panel_description = Atom.from("text_panel_description").value(),
    /// Moves the caret to the next or the previous diagnostic.
    text_next_diagnostic = Atom.from("text_next_diagnostic").value(),
    text_previous_diagnostic = Atom.from("text_previous_diagnostic").value(),
    _,
};

/// Closing the focused panel is the editor's action, which comes here while the focused
/// panel is a text panel: the window goes and its buffer stays open.
const window_close_tag = Atom.from("window_close");

const toggle_keymap_action: plugin.action_api.Def = .{ .name = "toggle_keymap", .tag = @tagName(Msg.text_toggle_keymap), .doc = "Switch text editing between Emacs keys and common (Ctrl+C, Ctrl+V) keys" };

/// Shows a buffer: in the focused text panel, or with none focused in a new one.
const switch_buffer_action: plugin.action_api.Def = .{ .name = "switch_buffer", .tag = @tagName(Msg.text_switch_buffer), .doc = "Switch to another buffer: an open file, *scratch*, *Messages* or a figure" };

/// Kills a buffer chosen from all of them, the one shown offered first: a text buffer, or a
/// figure, which closes.
const kill_buffer_action: plugin.action_api.Def = .{ .name = "kill_buffer", .tag = @tagName(Msg.text_kill_buffer), .doc = "Kill a buffer: an open file, *scratch* or a figure" };

/// Shows one of the project's buffers, as `switch_buffer` shows any; its key, `C-x p b`, is
/// `text_tools.global_keys`, with the other project commands'.
const project_switch_buffer_action: plugin.action_api.Def = .{ .name = "project_switch_buffer", .tag = @tagName(Msg.text_project_switch_buffer), .doc = "Switch to another buffer whose file lies in the project" };

/// What the editor offers from anywhere: the keymap is a setting, not the panel's, and any
/// buffer can be shown from anywhere. A focused text panel lists `switch_buffer`,
/// `select_window` and `recent_files` itself, in place of the editor (`panelActionMode`).
pub const actions = [_]plugin.action_api.Def{ toggle_keymap_action, switch_buffer_action, kill_buffer_action, select_window_action, recent_files_action, project_switch_buffer_action };

/// The keys of `actions`, of the mode `global`.
pub const global_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "C-x o", .action = .{ "global", "select_window" } },
    .{ .chord = "C-x b", .action = .{ "global", "switch_buffer" } },
    .{ .chord = "C-x C-b", .action = .{ "global", "switch_buffer" } },
    .{ .chord = "C-x k", .action = .{ "global", "kill_buffer" } },
};

/// Opens a file opened lately, from anywhere: the list outlasts the session.
const recent_files_action: plugin.action_api.Def = .{ .name = "recent_files", .tag = @tagName(Msg.text_recent_files), .doc = "Open one of the files opened lately" };

/// Goes to a window by its letter, as ace-window does: any panel, from anywhere.
const select_window_action: plugin.action_api.Def = .{ .name = "select_window", .tag = @tagName(Msg.text_select_window), .doc = "Go to a window chosen by its letter; with two windows, to the other" };

/// What a text panel offers while it has the focus, of the mode `buffer` but for the three of
/// `actions` among them (`panelActionMode`). Their keys are `buffer_keys`, and `cua_keys` while
/// the common keys are in use.
pub const panel_actions = [_]plugin.action_api.Def{
    .{ .name = "save_as", .tag = @tagName(Msg.text_save_as), .doc = "Save the text panel's file under another name" },
    .{ .name = "close", .tag = @tagName(Msg.text_close), .doc = "Kill the text panel's buffer" },
    switch_buffer_action,
    .{ .name = "goto_line", .tag = @tagName(Msg.text_goto_line), .doc = "Go to a line by its number" },
    .{ .name = "search_lines", .tag = @tagName(Msg.text_search_lines), .doc = "Search the file's lines" },
    .{ .name = "zap_up_to", .tag = @tagName(Msg.text_zap_up_to), .doc = "Kill up to the next character typed" },
    .{ .name = "zap_to_char", .tag = @tagName(Msg.text_zap_to_char), .doc = "Kill through the next character typed" },
    .{ .name = "set_encoding", .tag = @tagName(Msg.text_set_encoding), .doc = "Choose the encoding the text panel's file is saved in" },
    .{ .name = "revert_with_encoding", .tag = @tagName(Msg.text_revert_with_encoding), .doc = "Read the text panel's file again as text in an encoding chosen" },
    .{ .name = "set_line_ending", .tag = @tagName(Msg.text_set_line_ending), .doc = "Convert the line endings of the text panel's file" },
    .{ .name = "goto_definition", .tag = @tagName(Msg.text_goto_definition), .doc = "Go to where the name at the caret is defined" },
    .{ .name = "go_back", .tag = @tagName(Msg.text_go_back), .doc = "Go back to where the last jump to a definition left" },
    .{ .name = "describe", .tag = @tagName(Msg.text_describe), .doc = "Say what the name at the caret is" },
    .{ .name = "next_diagnostic", .tag = @tagName(Msg.text_next_diagnostic), .doc = "Go to the language server's next diagnostic" },
    .{ .name = "previous_diagnostic", .tag = @tagName(Msg.text_previous_diagnostic), .doc = "Go to the language server's previous diagnostic" },
    isearch_forward_action,
    isearch_backward_action,
    .{ .name = "query_replace", .tag = @tagName(Msg.text_query_replace), .doc = "Replace a text with another, asking at each place it is: in the selection, or from the caret on" },
    .{ .name = "split_below", .tag = @tagName(Msg.text_split_below), .doc = "Show the buffer in a second window below this one" },
    .{ .name = "split_right", .tag = @tagName(Msg.text_split_right), .doc = "Show the buffer in a second window to the right of this one" },
    .{ .name = "switch_buffer_other_window", .tag = @tagName(Msg.text_switch_buffer_other_window), .doc = "Switch to another buffer in another window" },
    .{ .name = "find_file_other_window", .tag = @tagName(Msg.text_find_file_other_window), .doc = "Open a file by typing its path, in another window" },
    select_window_action,
    recent_files_action,
    .{ .name = "string_rectangle", .tag = @tagName(Msg.text_string_rectangle), .doc = "Put a text typed in place of the rectangle between the selection's ends, on each line" },
    .{ .name = "copy_to_register", .tag = @tagName(Msg.text_copy_to_register), .doc = "Copy the selection to the register named by the next character typed" },
    .{ .name = "insert_register", .tag = @tagName(Msg.text_insert_register), .doc = "Insert the text of the register named by the next character typed" },
    .{ .name = "point_to_register", .tag = @tagName(Msg.text_point_to_register), .doc = "Keep the caret's place in the register named by the next character typed" },
    .{ .name = "jump_to_register", .tag = @tagName(Msg.text_jump_to_register), .doc = "Go to the place kept in the register named by the next character typed" },
    .{ .name = "macro_start", .tag = @tagName(Msg.text_macro_start), .doc = "Begin defining a keyboard macro: the edit commands and text typed from here" },
    .{ .name = "macro_end", .tag = @tagName(Msg.text_macro_end), .doc = "End the keyboard macro being defined" },
    .{ .name = "macro_end_or_call", .tag = @tagName(Msg.text_macro_end_or_call), .doc = "End the keyboard macro being defined, or do the one defined again" },
    .{ .name = "macro_call", .tag = @tagName(Msg.text_macro_call), .doc = "Do the keyboard macro last defined again" },
    .{ .name = "complete", .tag = @tagName(Msg.text_complete), .doc = "Complete what is typed at the caret from what the language server offers" },
    .{ .name = "complete_or_indent", .tag = @tagName(Msg.text_complete_or_indent), .doc = "Complete what is typed at the caret, or indent when nothing is typed there" },
    .{ .name = "goto_symbol", .tag = @tagName(Msg.text_goto_symbol), .doc = "Go to one of the things the buffer defines, chosen by its name" },
    .{ .name = "jump_char", .tag = @tagName(Msg.text_jump_char), .doc = "Jump to a character in sight: type it, then the letters shown on the one meant" },
    .{ .name = "jump_char_2", .tag = @tagName(Msg.text_jump_char_2), .doc = "Jump to two characters in sight: type them, then the letters shown on the pair meant" },
    .{ .name = "jump_word", .tag = @tagName(Msg.text_jump_word), .doc = "Jump to a word in sight: type its first character, then the letters shown on it" },
    .{ .name = "jump_line", .tag = @tagName(Msg.text_jump_line), .doc = "Jump to a line in sight by the letters shown on it" },
    .{ .name = "undo_tree", .tag = @tagName(Msg.text_undo_tree), .doc = "Show the buffer's undo history as a tree and walk it: f and b along a branch, n and p between branches, RET to stay, C-g to return" },
    .{ .name = "toggle_read_only", .tag = @tagName(Msg.text_toggle_read_only), .doc = "Switch the buffer between being edited and being only read" },
    .{ .name = "toggle_subword", .tag = @tagName(Msg.text_toggle_subword), .doc = "Switch whether a word also ends where its capitals part it, as in GtkWindow" },
    .{ .name = "universal_argument", .tag = @tagName(Msg.text_universal_argument), .doc = "Begin a count before the next command: four, and four times that when asked again" },
} ++ digit_argument_actions;

const panel_action_tags = plugin.action_api.tags(&panel_actions);

/// Emacs's keys for a text panel's actions, the keymap of `buffer`, over those of `text`. Each
/// invokes on the press alone, as the panel's actions always have.
pub const buffer_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "M-z", .action = .{ "buffer", "zap_to_char" } },
    .{ .chord = "M-g g", .action = .{ "buffer", "goto_line" } },
    .{ .chord = "M-g M-g", .action = .{ "buffer", "goto_line" } },
    .{ .chord = "C-x C-w", .action = .{ "buffer", "save_as" } },
    .{ .chord = "M-period", .action = .{ "buffer", "goto_definition" } },
    .{ .chord = "M-comma", .action = .{ "buffer", "go_back" } },
    .{ .chord = "C-h period", .action = .{ "buffer", "describe" } },
    .{ .chord = "C-x RET f", .action = .{ "buffer", "set_encoding" } },
    .{ .chord = "C-x RET r", .action = .{ "buffer", "revert_with_encoding" } },
    .{ .chord = "C-u", .action = .{ "buffer", "universal_argument" } },
    .{ .chord = "M-0", .action = .{ "buffer", "digit_argument_0" } },
    .{ .chord = "M-1", .action = .{ "buffer", "digit_argument_1" } },
    .{ .chord = "M-2", .action = .{ "buffer", "digit_argument_2" } },
    .{ .chord = "M-3", .action = .{ "buffer", "digit_argument_3" } },
    .{ .chord = "M-4", .action = .{ "buffer", "digit_argument_4" } },
    .{ .chord = "M-5", .action = .{ "buffer", "digit_argument_5" } },
    .{ .chord = "M-6", .action = .{ "buffer", "digit_argument_6" } },
    .{ .chord = "M-7", .action = .{ "buffer", "digit_argument_7" } },
    .{ .chord = "M-8", .action = .{ "buffer", "digit_argument_8" } },
    .{ .chord = "M-9", .action = .{ "buffer", "digit_argument_9" } },
    .{ .chord = "C-x C-q", .action = .{ "buffer", "toggle_read_only" } },
    .{ .chord = "C-s", .action = .{ "buffer", "isearch_forward" } },
    .{ .chord = "C-r", .action = .{ "buffer", "isearch_backward" } },
    .{ .chord = "M-s l", .action = .{ "buffer", "search_lines" } },
    .{ .chord = "M-S-5", .action = .{ "buffer", "query_replace" } },
    .{ .chord = "C-x 2", .action = .{ "buffer", "split_below" } },
    .{ .chord = "C-x 3", .action = .{ "buffer", "split_right" } },
    .{ .chord = "C-x 4 b", .action = .{ "buffer", "switch_buffer_other_window" } },
    .{ .chord = "C-x 4 f", .action = .{ "buffer", "find_file_other_window" } },
    .{ .chord = "C-x 4 C-f", .action = .{ "buffer", "find_file_other_window" } },
    .{ .chord = "tab", .action = .{ "buffer", "complete_or_indent" } },
    .{ .chord = "C-M-i", .action = .{ "buffer", "complete" } },
    .{ .chord = "M-g i", .action = .{ "buffer", "goto_symbol" } },
    .{ .chord = "C-x r t", .action = .{ "buffer", "string_rectangle" } },
    .{ .chord = "C-x r s", .action = .{ "buffer", "copy_to_register" } },
    .{ .chord = "C-x r i", .action = .{ "buffer", "insert_register" } },
    .{ .chord = "C-x r SPC", .action = .{ "buffer", "point_to_register" } },
    .{ .chord = "C-x r j", .action = .{ "buffer", "jump_to_register" } },
    .{ .chord = "f3", .action = .{ "buffer", "macro_start" } },
    .{ .chord = "f4", .action = .{ "buffer", "macro_end_or_call" } },
    .{ .chord = "C-x S-9", .action = .{ "buffer", "macro_start" } },
    .{ .chord = "C-x S-0", .action = .{ "buffer", "macro_end" } },
    .{ .chord = "C-x e", .action = .{ "buffer", "macro_call" } },
};

const isearch_forward_action: plugin.action_api.Def = .{ .name = "isearch_forward", .tag = @tagName(Msg.text_isearch_forward), .doc = "Search forward as the text is typed; again, go on to the next match" };
const isearch_backward_action: plugin.action_api.Def = .{ .name = "isearch_backward", .tag = @tagName(Msg.text_isearch_backward), .doc = "Search backward as the text is typed; again, go on to the match before" };

/// What a panel offers while it searches, `isearch.<name>`, bound by `isearch_keys`: the prompt
/// has the keyboard then, and these capture their keys as it does. The first two are the
/// search's own repeats of `buffer`'s actions that begin one, under the same tags.
pub const isearch_actions = [_]plugin.action_api.Def{
    .{ .name = "forward", .tag = isearch_forward_action.tag, .doc = isearch_forward_action.doc },
    .{ .name = "backward", .tag = isearch_backward_action.tag, .doc = isearch_backward_action.doc },
    .{ .name = "yank_word", .tag = @tagName(Msg.text_isearch_yank_word), .doc = "Take the word after the match into the search's text" },
};

/// The keys of `isearch_actions`, the keymap of `isearch`, as Emacs's `isearch-mode-map`, over
/// the prompt's and the text editor's.
pub const isearch_keys = [_]mesha.keybinds.KeyDef{
    .{ .chord = "C-s", .action = .{ "isearch", "forward" } },
    .{ .chord = "C-r", .action = .{ "isearch", "backward" } },
    .{ .chord = "C-w", .action = .{ "isearch", "yank_word" } },
};

/// The mode `def`, one of `panel_actions`, is offered in: the three that `actions` offers from
/// anywhere are among these, so that taking one drops a count (`panel_action_tags`), and while a
/// text panel has the focus it lists them, under their own mode, in place of the editor.
fn panelActionMode(def: plugin.action_api.Def) Atom {
    for (actions) |global_def| {
        if (std.mem.eql(u8, global_def.tag, def.tag)) return plugin.action_api.global_mode;
    }
    return modes.buffer;
}

/// Whether an action goes on with the count or reads it itself; any other drops it.
fn keepsArgument(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        .text_universal_argument, .text_digit_argument, .text_goto_line => true,
        // A macro is done again as many times as the count says.
        .text_macro_end_or_call, .text_macro_call => true,
        else => false,
    };
}

// ---- the count before a command ---------------------------------------------------------------
//
// `C-u` and `M-digit` begin a count, and digits typed after go on with it, as Emacs's prefix
// argument. The next command takes it: an edit command runs that many times, a character is
// typed that many times, go-to-line goes to that line, and `C-SPC` returns to the mark.

/// Takes the count typed before the command now running: null when none was.
fn takeArgument(row: PanelRow) ?u32 {
    const state: Argument = std.enums.fromInt(Argument, row.argument_state.*) orelse .none;
    row.argument_state.* = @intFromEnum(Argument.none);
    return if (state == .none) null else row.argument.*;
}

/// What the minibuffer's line says of a count: `C-u` and its digits, and a dash.
fn argumentNote(buffer: []u8, row: PanelRow) []const u8 {
    const state: Argument = std.enums.fromInt(Argument, row.argument_state.*) orelse .none;
    var writer = std.Io.Writer.fixed(buffer);
    switch (state) {
        .none => {},
        .universal => {
            // `C-u C-u` is sixteen: a `C-u` for each four.
            var remaining = row.argument.*;
            while (remaining >= 4) : (remaining /= 4) writer.writeAll(if (remaining == row.argument.*) "C-u" else " C-u") catch break;
            writer.writeByte('-') catch {};
        },
        .digits => writer.print("C-u {d}-", .{row.argument.*}) catch {},
        .sealed => writer.print("C-u {d} C-u-", .{row.argument.*}) catch {},
    }
    return writer.buffered();
}

/// Tells the minibuffer's line what the count is now, or nothing once it is taken.
fn noteArgument(tables: *Table.Registry, row: PanelRow) void {
    var note_buffer: [48]u8 = undefined;
    const note = argumentNote(&note_buffer, row);
    action_palette.request(tables.memory, tables, .{ .note = .{ .text = note } });
}

/// `C-u`: begins a count of four, multiplies one begun so, and ends one of digits.
fn universalArgument(row: PanelRow) void {
    const state: Argument = std.enums.fromInt(Argument, row.argument_state.*) orelse .none;
    switch (state) {
        .none => {
            row.argument_state.* = @intFromEnum(Argument.universal);
            row.argument.* = 4;
        },
        .universal => row.argument.* = @min(row.argument.* *| 4, max_argument),
        .digits => row.argument_state.* = @intFromEnum(Argument.sealed),
        .sealed => {},
    }
}

/// A digit of the count: the first replaces what `C-u` alone counted.
fn digitArgument(row: PanelRow, digit: u32) void {
    const state: Argument = std.enums.fromInt(Argument, row.argument_state.*) orelse .none;
    const so_far: u32 = if (state == .digits) row.argument.* else 0;
    row.argument_state.* = @intFromEnum(Argument.digits);
    row.argument.* = @min(so_far *| 10 +| digit, max_argument);
}

/// Whether a digit typed now goes on with the count instead of being text.
fn argumentTakesDigits(row: PanelRow) bool {
    const state: Argument = std.enums.fromInt(Argument, row.argument_state.*) orelse .none;
    return state == .universal or state == .digits;
}

/// A digit of the count before a command, `M-0` to `M-9`: the digit is the action's user data.
const digit_argument_actions: [10]plugin.action_api.Def = blk: {
    var defs: [10]plugin.action_api.Def = undefined;
    for (&defs, 0..) |*def, digit| {
        const params = [_]u8{digit};
        def.* = .{
            .name = std.fmt.comptimePrint("digit_argument_{d}", .{digit}),
            .tag = @tagName(Msg.text_digit_argument),
            .params = &params,
            .doc = std.fmt.comptimePrint("Begin or go on with a count before the next command: {d}", .{digit}),
        };
    }
    break :blk defs;
};

pub fn system() sequencer.System {
    return .{
        .name = "text_panel",
        .names = comptime &sequencer.enumNames(Msg),
        .root = text_panel_root,
        .claims = claims,
        .idle = idle,
        .access = access,
        .kernels = &.{
            .{ .name = "text_panel.take_messages", .run = takeMessages },
            .{ .name = "text_panel.follow_metrics", .run = followMetrics },
            .{ .name = "text_panel.follow_buffers", .run = followBuffers },
            .{ .name = "text_panel.declare_windows", .run = declareWindows },
            .{ .name = "text_panel.subscribe", .run = subscribe },
        },
    };
}

/// The text panels' modes: `buffer` each, with `cua` while the text editors answer the common
/// keys, asked for as a text panel takes the focus and as the focused one's modes change. A
/// system of its own beside the panels', which idle while the focus moves elsewhere or the
/// setting changes.
pub fn modesSystem() sequencer.System {
    return .{
        .name = "text_panel_modes",
        .root = text_panel_root,
        .claims = sequencer.claims_nothing,
        .access = modesAccess,
        .kernels = &.{.{ .name = "text_panel_modes.sync", .run = syncModes }},
    };
}

/// The text panels' modes, a `modes.PanelModesRow` each.
pub const panel_modes_table_name = "text_panel_panel_modes";

fn modesAccess(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    if (panelsTable(frame.tables) != null) result.readAll(&.{ panels_table, buffer_modes_table });
    modes.declarePanelModes(&result, frame.tables, panel_modes_table_name);
    return result;
}

/// Every text panel's row is `buffer`'s, or its buffer's own mode's (`setBufferMode`): a
/// search's modes are the palette's, which opens it.
fn syncModes(pass: *sequencer.Pass) !void {
    if (!pass.declares(panels_table)) return;
    const table = try pass.table(panels_table);
    const buffer_modes = try pass.table(buffer_modes_table);
    var wanted: [max_panels]modes.PanelMajor = undefined;
    var count: usize = 0;
    var rows = table.readQuery(struct { panel: *Atom, buffer: *Atom });
    while (rows.next()) |found| {
        if (count == wanted.len) break;
        const major = bufferMode(buffer_modes, found.view.buffer.*);
        wanted[count] = .{ .panel = found.view.panel.*, .major = major };
        count += 1;
    }
    try modes.syncPanelModes(pass, panel_modes_table_name, wanted[0..count]);
}

const text_editor_tags = [_]Atom{ shared.command_tag, shared.save_tag, shared.leave_tag };
/// The palette's prompts are one owner's: only one shows at a time.
const prompt_owner = Atom.from("text_panel_prompt");

fn claims(tag: Atom) bool {
    if (std.mem.indexOfScalar(Atom, &text_editor_tags, tag) != null) return true;
    if (tag == window_close_tag) return true;
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Whether the panels have nothing to do this frame: no messages (which always run the
/// system), no events from their buffers or language servers, and no panel opened, closed,
/// resized, being dragged in, taking or losing the keyboard, or whose font has another cell
/// than it scrolls by. Idle, the system keeps its subscriptions, so the panels still hear the pointer and typing.
fn idle(frame: *const sequencer.Frame) bool {
    const tables = frame.tables;
    const atoms = frame.atoms;
    const reader = Atom.from(system().name);
    var text_events: [1]text_editor.Event = undefined;
    if (text_editor.Events.of(tables, text_editor.events_table_name).unread(reader, &text_events).len != 0) return false;
    var server_events: [1]lsp.Event = undefined;
    if (lsp.Events.of(tables, lsp.events_table_name).unread(reader, &server_events).len != 0) return false;
    if (showAsked(tables)) return false;

    const table = panelsTable(tables) orelse return true;
    const keyboard = focusedPanel(tables, atoms);
    const metrics = tables.findByName(font_metrics_table);
    var rows = table.readQuery(PanelRow);
    while (rows.next()) |found| {
        const row = found.view;
        if (row.dragging.* != 0) return false;
        if (metrics) |measured| {
            if (cellChanged(measured, row)) return false;
        }
        const open = panels_mod.isOpen(tables, atoms, row.panel.*);
        // Shown for the first time, or replaced, and its row to go.
        if (open != (row.shown.* != 0)) return false;
        if (!open) continue;
        const has_keyboard = keyboard != null and keyboard.? == row.panel.*;
        if (has_keyboard != (row.typing.* != 0)) return false;
        if (pageLines(tables, atoms, row)) |page_lines| {
            if (page_lines != row.page_lines.*) return false;
        }
    }
    return true;
}

/// The lines a page move travels in `row`'s panel, as it is laid out now; null while it has
/// no place, or its lines have not been measured.
fn pageLines(tables: *Table.Registry, atoms: *Atom.Registry, row: anytype) ?u32 {
    // Hidden behind a maximized panel: nothing to lay out.
    const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse return null;
    if (row.line_height.* <= 0) return null;
    const visible_lines: u32 = @intFromFloat(@max(@floor((content.h - 2 * padding) / row.line_height.*), 1));
    return @max(visible_lines, 2) - 1;
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.writeAll(&.{ panels_table, buffer_modes_table, show_requests_table });
    result.writeAll(&.{ jumps_table, navigation_table, completions_table, symbols_table, registers_table, macro_table, macro_state_table, encodings_table });
    result.writeIfPresent(tables, shared.settings_table);
    // The settings are loaded, made and saved by resources.
    result.writeIfPresent(tables, Atom.from(resources.commands_table_name));
    // Which panel has the keyboard, and where each panel's content is.
    result.readAll(&.{ Atom.from(panels_mod.nodes_table_name), Atom.from(panels_mod.state_table_name) });
    result.read(Atom.from(action_palette.table_name));
    result.write(Atom.from(action_palette.requests_table_name));
    result.writeIfPresent(tables, Atom.from(text_editor.commands_table_name));
    result.writeIfPresent(tables, Atom.from(plugin.panels.commands_table_name));
    // Each window is a panel the system declares open.
    result.writeIfPresent(tables, declared_panels_table);
    result.writeIfPresent(tables, Atom.from(input.subscriptions_table_name));
    result.writeIfPresent(tables, Atom.from(os.commands_table_name));
    // Finding a file for another window asks for the open system's action.
    result.writeIfPresent(tables, Atom.from(plugin.action_api.commands_table_name));
    // Each panel follows its buffer's events and reads its buffer's table.
    text_editor.Events.declare(&result, tables, text_editor.events_table_name);
    // Each panel's cell is its font's, which resources measures as it loads.
    if (tables.findByName(font_metrics_table) != null) result.read(font_metrics_table);
    // The buffers a panel may switch to.
    result.read(Atom.from(text_editor.buffers_table_name));
    // The files opened lately, to open one again.
    if (tables.findByName(Atom.from(text_editor.recent_table_name)) != null) result.read(Atom.from(text_editor.recent_table_name));
    // The working directory, which the lists of files name theirs from.
    result.read(Atom.from(os.places_table_name));
    // Which view had the focus before a prompt took the keyboard: the window a buffer
    // chosen there shows in.
    result.read(Atom.from(state_mod.view_focus_name));
    // And what its buffer's language server says of it.
    lsp.Events.declare(&result, tables, lsp.events_table_name);
    lsp.declareReading(&result, tables);
    result.writeIfPresent(tables, Atom.from(lsp.commands_table_name));
    // A buffer shown from the focused figure stage takes its place, closing it.
    result.writeIfPresent(tables, Atom.from(fixed_panels.shown_panels_table_name));
    result.writeIfPresent(tables, Atom.from(figure_workspace.commands_table_name));
    // The buffers listed to switch to or kill, figures among them, the focused window's
    // buffer the latest visited, and the figure the stage shows.
    buffer_list.declareVisits(&result, tables);
    buffer_list.declareListing(&result, tables);
    if (tables.findByName(Atom.from(figure_workspace.session.name)) != null) result.read(Atom.from(figure_workspace.session.name));
    const table = panelsTable(tables) orelse return result;
    var rows = table.readQuery(PanelRow);
    while (rows.next()) |found| text_editor.declareBuffer(&result, tables, found.view.buffer.*);
    return result;
}

/// Keeps each panel's line height and cell width as its text size's font has them, after
/// the frame's messages, one of which may have zoomed: the scroll, in pixels of the cell
/// before, keeps its line and cell at the panel's corner. Only a row whose cell changed is
/// written.
fn followMetrics(pass: *sequencer.Pass) !void {
    if (!pass.declares(font_metrics_table)) return;
    const metrics = try pass.table(font_metrics_table);
    const observed = try pass.table(panels_table);
    var changed: [max_panels]Table.RowHandle = undefined;
    var changed_count: usize = 0;
    var rows = observed.readQuery(PanelRow);
    while (rows.next()) |found| {
        if (changed_count == changed.len) break;
        if (!cellChanged(metrics, found.view)) continue;
        changed[changed_count] = found.handle;
        changed_count += 1;
    }
    if (changed_count == 0) return;
    const table = try pass.writeTable(panels_table);
    for (changed[0..changed_count]) |row_handle| {
        const row = table.getRow(row_handle, PanelRow) orelse continue;
        const cell = cellOf(metrics, row.text_size.*) orelse continue;
        if (row.line_height.* > 0) row.scroll_y.* = @round(row.scroll_y.* / row.line_height.* * cell.line_height);
        if (row.cell_width.* > 0) row.scroll_x.* = @round(row.scroll_x.* / row.cell_width.* * cell.cell_width);
        row.line_height.* = cell.line_height;
        row.cell_width.* = cell.cell_width;
    }
}

fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const table = try pass.writeTable(panels_table);
    const working_directory = open_mod.places(pass).working_directory;
    for (frame.messages) |received| {
        handle(frame, table, working_directory, received) catch |err| received.unreadable(err);
    }
}

/// `working_directory` is the one `open_mod.places` reads, which the lists of files name
/// theirs from.
fn handle(frame: *const sequencer.Frame, table: *Table, working_directory: []const u8, received: sequencer.Message) !void {
    const tables = frame.tables;
    const atoms = frame.atoms;
    const tag = received.tag;
    if (std.mem.indexOfScalar(Atom, &text_editor_tags, tag) != null) {
        const panel = focusedPanel(tables, atoms) orelse return;
        const found = rowOfPanel(table, panel) orelse return;
        return handleEditorAction(tables, atoms, found.row, received);
    }
    if (tag == window_close_tag) {
        const panel = focusedPanel(tables, atoms) orelse return;
        const found = rowOfPanel(table, panel) orelse return;
        // The row gone, the window is no longer declared, and the panels system closes it.
        table.free(found.handle);
        return;
    }
    // A count is for the next command: one that does not read it drops it.
    const is_panel_action = std.mem.indexOfScalar(Atom, &panel_action_tags, tag) != null;
    // So is a wish to show what is next opened in another window, when the prompt it was
    // for was given up: any action but those that make the wish drops it.
    const makes_wish = tag.to(Msg) == .text_switch_buffer_other_window or tag.to(Msg) == .text_find_file_other_window;
    if (is_panel_action and !makes_wish) {
        if (navigationRow(tables)) |navigation| navigation.other_window.* = 0;
    }
    if (is_panel_action and !keepsArgument(tag)) {
        if (focusedPanel(tables, atoms)) |panel| {
            if (rowOfPanel(table, panel)) |found| {
                if (takeArgument(found.row) != null) noteArgument(tables, found.row);
            }
        }
    }
    switch (tag.to(Msg)) {
        .text_panel_open_failure_seen => {
            const event = try action_palette.eventOf(received);
            if (event.kind != .completed) return;
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
        },
        .text_panel_opened => {
            const opened = try received.payloadAs(text_editor.OpenedMsg);
            switch (opened.result) {
                .opened, .already_open => {
                    // The place gone from is the mark, and where `text_go_back` returns.
                    const placed = received.user_data.len == @sizeOf(OpenPlace);
                    if (placed) {
                        if (focusedPanel(tables, atoms)) |panel| {
                            if (rowOfPanel(table, panel)) |found| pushJump(tables, found.row.buffer.*);
                        }
                    }
                    showAsWished(tables, atoms, table, opened.buffer);
                    finishNavigation(tables, opened.buffer);
                    if (placed) {
                        const place = (try received.userDataAs(OpenPlace)).*;
                        placeCaret(tables, opened.buffer, place.line, place.column);
                    }
                },
                else => {
                    if (navigationRow(tables)) |navigation| navigation.pending.* = 0;
                    presentOpenFailure(tables, opened.result);
                },
            }
        },
        .text_panel_saved => {
            const saved = try received.payloadAs(text_editor.SavedMsg);
            const row = rowOfBuffer(table, saved.buffer) orelse return;
            onSaved(tables, row, saved.result);
        },
        .text_panel_press, .text_panel_release, .text_panel_move, .text_panel_scroll => try handlePointer(tables, atoms, table, received),
        .text_save_as => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            askSavePath(tables, found.row.buffer.*);
        },
        .text_panel_save_path => {
            const buffer = (try received.userDataAs(Atom)).*;
            // No path is the picker cancelled: a close that waited for the save is off.
            if (received.payload.len == 0) {
                if (rowOfBuffer(table, buffer)) |row| row.closing.* = 0;
                return;
            }
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_saved));
            text_editor.request(frame.memory, tables, .{ .save = .{ .buffer = buffer, .path = received.payload, .reply = reply } });
        },
        .text_set_encoding => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            presentEncodings(tables, found.row.buffer.*, .save, "", .open);
        },
        .text_panel_encoding => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            if (event.kind == .query_changed) return presentEncodings(tables, buffer, .save, event.query, .narrow);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            chooseEncoding(tables, buffer, .save, chosenEncoding(chosen, event.query));
        },
        .text_revert_with_encoding => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const buffer = found.row.buffer.*;
            const state = text_editor.rowOf(tables, buffer) orelse return;
            // Reading the file again forgets the text here: changes are saved or undone first.
            if (state.path.len == 0) return text_editor.message(frame.memory, tables, "The buffer holds no file to read again");
            if (state.modified.* != 0) return text_editor.message(frame.memory, tables, "The buffer has changes: save or undo them before reading its file again");
            presentEncodings(tables, buffer, .revert, "", .open);
        },
        .text_panel_revert_encoding => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            if (event.kind == .query_changed) return presentEncodings(tables, buffer, .revert, event.query, .narrow);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            chooseEncoding(tables, buffer, .revert, chosenEncoding(chosen, event.query));
        },
        .text_panel_encodings => {
            const head = try headOf(text_editor.EncodingsMsg, received);
            const kept = tables.findByName(encodings_table) orelse return;
            if (received.user_data.len == 0) {
                keepKnownEncodings(kept, head.trailing);
                return refreshEncodingPrompt(tables, atoms);
            }
            const ask = (try received.userDataAs(EncodingAsk)).*;
            var answers: text_editor.EncodingAnswers = .{ .remaining = head.trailing };
            const answer = answers.next() orelse return error.MessageShape;
            const use = std.enums.fromInt(EncodingUse, ask.use) orelse return error.MessageShape;
            const kept_answer = keepTypedEncoding(kept, answer);
            switch (use) {
                // Offered once the answer is kept, or it would be asked again.
                .offer => if (kept_answer) refreshEncodingPrompt(tables, atoms),
                .save, .revert => {
                    const purpose: EncodingPurpose = if (use == .save) .save else .revert;
                    const coding: CodingSystem = .{ .encoding = answer.name, .line_ending = lineEndingOf(ask.line_ending) };
                    if (answer.supported) {
                        useEncoding(tables, ask.buffer, purpose, coding);
                    } else {
                        refuseEncoding(tables, purpose, answer.name);
                    }
                },
            }
        },
        .text_set_line_ending => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            presentLineEndings(tables, found.row.buffer.*);
        },
        .text_panel_line_ending => {
            const event = try action_palette.eventOf(received);
            if (event.kind != .completed) return;
            const buffer = (try received.userDataAs(Atom)).*;
            if (event.completion) |chosen| {
                const ending = std.enums.fromInt(text_editor.LineEnding, chosen.data[0]) orelse return;
                text_editor.request(frame.memory, tables, .{ .set_line_ending = .{ .buffer = buffer, .ending = ending, .existing = .convert } });
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
        },
        .text_panel_close_choice => {
            const event = try action_palette.eventOf(received);
            if (event.kind != .completed) return;
            const buffer = (try received.userDataAs(Atom)).*;
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            const choice = std.enums.fromInt(CloseChoice, chosen.data[0]) orelse return;
            const row = rowOfBuffer(table, buffer) orelse return;
            switch (choice) {
                .save => {
                    row.closing.* = 1;
                    requestSave(tables, buffer);
                },
                .discard => text_editor.request(frame.memory, tables, .{ .close = buffer }),
                .cancel => {},
            }
        },
        .text_panel_char => {
            const typed = try received.payloadAs(input.TextInputMsg);
            if (typed.codepoint < 32 or typed.codepoint == 127) return;
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const row = found.row;
            var bytes: [4]u8 = undefined;
            const utf8 = input.typedText(typed, &bytes) orelse return;
            const awaiting: Awaiting = std.enums.fromInt(Awaiting, row.awaiting.*) orelse .none;
            // A jump under way takes what is typed: what it looks for, then a place's letters.
            if (row.jump.* != @intFromEnum(Jump.none)) return jumpTyped(tables, atoms, row, utf8);
            // A digit typed after `C-u` goes on with the count.
            const is_digit = typed.codepoint >= '0' and typed.codepoint <= '9';
            if (awaiting == .none and is_digit and argumentTakesDigits(row)) {
                digitArgument(row, typed.codepoint - '0');
                return noteArgument(tables, row);
            }
            const argument = takeArgument(row);
            if (argument != null) noteArgument(tables, row);
            // More of a name narrows the completions listed; anything else ends them.
            if (!isWordByte(utf8[0])) row.completing.* = @intFromEnum(Completing.none);
            row.awaiting.* = @intFromEnum(Awaiting.none);
            row.recenter.* = @intFromEnum(Recenter.middle);
            switch (awaiting) {
                .none => {
                    recordMacroStep(tables, .text, .cancel, argument orelse 1, utf8);
                    text_editor.request(frame.memory, tables, .{ .insert = .{ .buffer = row.buffer.*, .utf8 = utf8, .count = argument orelse 1 } });
                },
                .zap => {
                    recordMacroStep(tables, .zap_up_to, .cancel, 1, utf8);
                    text_editor.request(frame.memory, tables, .{ .zap = .{ .buffer = row.buffer.*, .utf8 = utf8, .reach = .up_to } });
                },
                .zap_through => {
                    recordMacroStep(tables, .zap_through, .cancel, 1, utf8);
                    text_editor.request(frame.memory, tables, .{ .zap = .{ .buffer = row.buffer.*, .utf8 = utf8, .reach = .through } });
                },
                .register_copy, .register_insert, .register_point, .register_jump => useRegister(tables, atoms, table, row, awaiting, typed.codepoint),
            }
        },
        .text_goto_definition, .text_describe => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const buffer = found.row.buffer.*;
            const state = text_editor.rowOf(tables, buffer) orelse return;
            const definition = tag.to(Msg) == .text_goto_definition;
            const answer: Msg = if (definition) .text_panel_definition else .text_panel_description;
            const reply = sequencer.ReplyTo.of(system(), .from(answer)).with(.of(&buffer));
            const wanted: lsp.CmdPayload = if (definition)
                .{ .definition = .{ .buffer = buffer, .offset = state.caret.*, .reply = reply } }
            else
                .{ .hover = .{ .buffer = buffer, .offset = state.caret.*, .reply = reply } };
            lsp.request(frame.memory, tables, wanted);
        },
        .text_panel_definition => {
            const buffer = (try received.userDataAs(Atom)).*;
            const head = try headOf(lsp.DefinitionMsg, received);
            const row = rowOfBuffer(table, buffer) orelse return;
            switch (head.value.result) {
                .found => {
                    pushJump(tables, buffer);
                    navigate(tables, head.trailing, head.value.line, head.value.column);
                },
                .nothing => setInfo(table, row.panel.*, "No definition found"),
                .no_server => setInfo(table, row.panel.*, "No language server for this file"),
                .failed => setInfo(table, row.panel.*, "The language server could not answer"),
            }
        },
        .text_panel_description => {
            const buffer = (try received.userDataAs(Atom)).*;
            const head = try headOf(lsp.HoverMsg, received);
            const row = rowOfBuffer(table, buffer) orelse return;
            const text = switch (head.value.result) {
                .found => head.trailing,
                .nothing => "Nothing known here",
                .no_server => "No language server for this file",
                .failed => "The language server could not answer",
            };
            setInfo(table, row.panel.*, text);
        },
        .text_go_back => popJump(tables),
        .text_next_diagnostic, .text_previous_diagnostic => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const direction: Direction = if (tag.to(Msg) == .text_next_diagnostic) .next else .previous;
            moveToDiagnostic(tables, found.row.buffer.*, direction);
        },
        .text_close => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            killBuffer(tables, found.row.buffer.*);
        },
        .text_string_rectangle => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            present(tables, .{ .presentation = .prompt, .prompt = "String rectangle:", .accepts_text = true, .entries = &.{} }, &.{}, .text_panel_rectangle, found.row.buffer.*);
        },
        .text_panel_rectangle => {
            const event = try action_palette.eventOf(received);
            if (event.kind != .completed) return;
            const buffer = (try received.userDataAs(Atom)).*;
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            if (event.completion == null) return;
            text_editor.request(frame.memory, tables, .{ .string_rectangle = .{ .buffer = buffer, .utf8 = event.query } });
        },
        .text_copy_to_register, .text_insert_register, .text_point_to_register, .text_jump_to_register => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const awaiting: Awaiting = switch (tag.to(Msg)) {
                .text_copy_to_register => .register_copy,
                .text_insert_register => .register_insert,
                .text_point_to_register => .register_point,
                else => .register_jump,
            };
            found.row.awaiting.* = @intFromEnum(awaiting);
        },
        .text_macro_start => {
            const state = macroState(tables) orelse return;
            if (tables.findByName(macro_table)) |steps| steps.clear();
            state.recording.* = 1;
            text_editor.message(frame.memory, tables, "Defining a keyboard macro");
        },
        .text_macro_end, .text_macro_end_or_call, .text_macro_call => {
            const state = macroState(tables) orelse return;
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const argument = takeArgument(found.row);
            if (argument != null) noteArgument(tables, found.row);
            if (state.recording.* != 0) {
                state.recording.* = 0;
                // The key that ends a macro only ends it.
                if (tag.to(Msg) != .text_macro_call) return text_editor.message(frame.memory, tables, "Keyboard macro defined");
            } else if (tag.to(Msg) == .text_macro_end) {
                return;
            }
            callMacro(tables, found.row.buffer.*, argument orelse 1);
        },
        .text_complete, .text_complete_or_indent => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const how: Completing = if (tag.to(Msg) == .text_complete) .asked else .asked_or_indent;
            // Asked again while they are listed, the key takes the one chosen.
            if (found.row.completing.* == @intFromEnum(Completing.listed)) return acceptCompletion(tables, found.row);
            askCompletions(tables, found.row, how);
        },
        .text_panel_completions => {
            const buffer = (try received.userDataAs(Atom)).*;
            const head = try headOf(lsp.ItemsMsg, received);
            const row = rowOfBuffer(table, buffer) orelse return;
            takeCompletions(tables, table, row, head.value.result, head.trailing);
        },
        .text_goto_symbol => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const buffer = found.row.buffer.*;
            const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_symbols)).with(.of(&buffer));
            lsp.request(frame.memory, tables, .{ .symbols = .{ .buffer = buffer, .reply = reply } });
        },
        .text_panel_symbols => {
            const buffer = (try received.userDataAs(Atom)).*;
            const head = try headOf(lsp.ItemsMsg, received);
            const row = rowOfBuffer(table, buffer) orelse return;
            switch (head.value.result) {
                .found => {},
                .nothing => return setInfo(table, row.panel.*, "The server names nothing here"),
                .no_server => return setInfo(table, row.panel.*, "No language server for this file"),
                .failed => return setInfo(table, row.panel.*, "The language server did not answer"),
            }
            keepSymbols(tables, head.trailing);
            presentSymbols(tables, buffer, "", .open);
        },
        .text_panel_symbol => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            if (event.kind == .query_changed) return presentSymbols(tables, buffer, event.query, .narrow);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            const line = std.mem.readInt(u32, chosen.data[0..4], .little);
            const column = std.mem.readInt(u32, chosen.data[4..8], .little);
            // The place left is the mark, to go back to (C-x C-x).
            text_editor.request(frame.memory, tables, .{ .run = .{ .buffer = buffer, .command = .push_mark } });
            placeCaret(tables, buffer, line, column);
        },
        .text_jump_char, .text_jump_char_2, .text_jump_word, .text_jump_line => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const kind: Jump = switch (tag.to(Msg)) {
                .text_jump_char => .char,
                .text_jump_char_2 => .char_2,
                .text_jump_word => .word,
                else => .line,
            };
            found.row.jump.* = @intFromEnum(kind);
            found.row.jump_typed.* = 0;
            found.row.jump_needle.* = 0;
            found.row.jump_letter.* = 0;
        },
        .text_zap_up_to, .text_zap_to_char => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const awaiting: Awaiting = if (tag.to(Msg) == .text_zap_up_to) .zap else .zap_through;
            found.row.awaiting.* = @intFromEnum(awaiting);
        },
        .text_toggle_keymap => toggleKeymap(tables),
        .text_isearch_forward, .text_isearch_backward => {
            const direction: Search = if (tag.to(Msg) == .text_isearch_forward) .forward else .backward;
            if (searchingRow(table)) |row| return repeatSearch(tables, atoms, row, direction);
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            beginSearch(tables, found.row, direction);
        },
        .text_isearch_yank_word => {
            const row = searchingRow(table) orelse return;
            yankWordIntoSearch(tables, row);
        },
        .text_panel_isearch => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            const row = rowOfBuffer(table, buffer) orelse return;
            if (event.kind == .query_changed) return searchFromOrigin(tables, row, event.query);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            endSearch(tables, row, event.query, if (event.completion != null) .stay else .return_to_origin);
        },
        .text_query_replace => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            beginReplace(tables, found.row);
        },
        .text_panel_replace => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            const row = rowOfBuffer(table, buffer) orelse return;
            replaceEvent(tables, atoms, row, event);
        },
        .text_toggle_read_only, .text_toggle_subword => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const buffer = found.row.buffer.*;
            const wanted: text_editor.CmdPayload = if (tag.to(Msg) == .text_toggle_read_only) .{ .toggle_read_only = buffer } else .{ .toggle_subword = buffer };
            text_editor.request(frame.memory, tables, wanted);
        },
        .text_universal_argument => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            universalArgument(found.row);
            noteArgument(tables, found.row);
        },
        .text_digit_argument => {
            const digit = (try received.userDataAs(u8)).*;
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            digitArgument(found.row, digit);
            noteArgument(tables, found.row);
        },
        .text_goto_line => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            // With a count, that is the line: nothing is asked.
            if (takeArgument(found.row)) |line| {
                noteArgument(tables, found.row);
                return gotoLine(tables, found.row.buffer.*, line);
            }
            const choices = [_]Choice{.{ .label = "Go to the line typed" }};
            present(tables, .{ .presentation = .prompt, .title = "Go to line", .tab = .nothing, .entries = &.{} }, &choices, .text_panel_goto, found.row.buffer.*);
        },
        .text_panel_goto => {
            const event = try action_palette.eventOf(received);
            if (event.kind != .completed) return;
            const buffer = (try received.userDataAs(Atom)).*;
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            if (event.completion == null) return;
            const typed = std.mem.trim(u8, event.query, " ");
            const line = std.fmt.parseInt(u32, typed, 10) catch return;
            gotoLine(tables, buffer, line);
        },
        .text_search_lines => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            present(tables, .{ .presentation = .prompt, .title = "Search lines", .tab = .nothing, .entries = &.{} }, &.{}, .text_panel_search, found.row.buffer.*);
        },
        .text_panel_search => {
            const event = try action_palette.eventOf(received);
            const buffer = (try received.userDataAs(Atom)).*;
            if (event.kind == .query_changed) return presentMatchingLines(tables, buffer, event.query);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            const place = std.mem.bytesToValue(MatchPlace, chosen.data[0..@sizeOf(MatchPlace)]);
            text_editor.request(frame.memory, tables, .{ .run = .{ .buffer = buffer, .command = .push_mark } });
            text_editor.request(frame.memory, tables, .{ .set_caret = .{ .buffer = buffer, .line = place.line, .column = place.column, .select = .motion } });
        },
        .text_switch_buffer => presentBuffers(tables, atoms, working_directory, "", .open, .all, .switch_to),
        .text_project_switch_buffer => presentBuffers(tables, atoms, working_directory, "", .open, .project, .switch_to),
        .text_kill_buffer => presentBuffers(tables, atoms, working_directory, "", .open, .all, .kill),
        .text_switch_buffer_other_window => {
            if (navigationRow(tables)) |navigation| navigation.other_window.* = 1;
            presentBuffers(tables, atoms, working_directory, "", .open, .all, .switch_to);
        },
        .text_find_file_other_window => {
            if (navigationRow(tables)) |navigation| navigation.other_window.* = 1;
            const find_file_id: plugin.action_api.ActionId = .{ plugin.action_api.global_mode, Atom.from(open_mod.find_file_action.name) };
            plugin.action_api.requestInvoke(tables, find_file_id);
        },
        .text_split_below, .text_split_right => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const side: plugin.panels.Side = if (tag.to(Msg) == .text_split_below) .bottom else .right;
            splitWindow(tables, table, found.row, side);
        },
        .text_select_window => presentWindows(tables, atoms, table),
        .text_recent_files => presentRecentFiles(tables, working_directory, "", .open),
        .text_panel_recent => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) return presentRecentFiles(tables, working_directory, event.query, .narrow);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            openPath(tables, chosen.key);
        },
        .text_undo_tree => {
            const panel = focusedPanel(tables, atoms) orelse return;
            const found = rowOfPanel(table, panel) orelse return;
            const view = text_editor.viewOf(tables, found.row.buffer.*) orelse return;
            found.row.history_shown.* = 1;
            found.row.history_origin.* = view.history_current;
        },
        .text_panel_history_back, .text_panel_history_forward, .text_panel_history_next, .text_panel_history_previous => {
            const row = historyRow(table) orelse return;
            const command: text_editor.EditCommand = switch (tag.to(Msg)) {
                .text_panel_history_back => .undo,
                .text_panel_history_forward => .redo,
                .text_panel_history_next => .undo_branch_next,
                else => .undo_branch_previous,
            };
            text_editor.request(frame.memory, tables, .{ .run = .{ .buffer = row.buffer.*, .command = command } });
        },
        .text_panel_history_keep, .text_panel_history_quit => {
            const row = historyRow(table) orelse return;
            row.history_shown.* = 0;
            // Given up, the text goes back to the state the walk began in.
            if (tag.to(Msg) == .text_panel_history_quit) {
                text_editor.request(frame.memory, tables, .{ .history_goto = .{ .buffer = row.buffer.*, .node = row.history_origin.* } });
            }
        },
        .text_panel_window => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) {
                // A window's letter typed goes there at once.
                const panel = windowLettered(tables, atoms, event.query) orelse return;
                plugin.panels.request(frame.memory, tables, .{ .focus = .{ .id = panel } });
                action_palette.request(frame.memory, tables, .{ .cancel = .{ .owner = prompt_owner } });
                return;
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const chosen = event.completion orelse return;
            const panel = windowLettered(tables, atoms, chosen.key) orelse return;
            plugin.panels.request(frame.memory, tables, .{ .focus = .{ .id = panel } });
        },
        .text_panel_switch => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) {
                const scope_byte = (try received.userDataAs(u8)).*;
                const scope = std.enums.fromInt(BufferScope, scope_byte) orelse .all;
                return presentBuffers(tables, atoms, working_directory, event.query, .narrow, scope, .switch_to);
            }
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            // Given up, what was to show in another window shows nowhere.
            if (event.completion == null) {
                if (navigationRow(tables)) |navigation| navigation.other_window.* = 0;
            }
            const completion = event.completion orelse return;
            const chosen = buffer_list.Chosen.decode(&completion.data);
            switch (chosen.kind) {
                .text => showAsWished(tables, atoms, table, chosen.id),
                .figure, .sketch => {
                    // The figure stage shows it in the focused window's place, as a buffer
                    // shows in the focused text window: never in another.
                    if (navigationRow(tables)) |navigation| navigation.other_window.* = 0;
                    const wanted: figure_workspace.Request = if (chosen.kind == .figure) .{ .show_document = chosen.id } else .{ .show_sketch = chosen.id };
                    figure_workspace.request(frame.memory, tables, wanted);
                },
            }
        },
        .text_panel_kill => {
            const event = try action_palette.eventOf(received);
            if (event.kind == .query_changed) return presentBuffers(tables, atoms, working_directory, event.query, .narrow, .all, .kill);
            action_palette.request(frame.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
            const completion = event.completion orelse return;
            const chosen = buffer_list.Chosen.decode(&completion.data);
            switch (chosen.kind) {
                .text => killBuffer(tables, chosen.id),
                .figure => figure_workspace.request(frame.memory, tables, .{ .close_document = chosen.id }),
                // Not offered: a sketch closes with its figures.
                .sketch => {},
            }
        },
        _ => {},
    }
}

/// One of the text editor's actions, for the panel with the keyboard.
fn handleEditorAction(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, received: sequencer.Message) !void {
    const memory = tables.memory;
    const buffer = row.buffer.*;
    const tag = received.tag;
    if (tag == shared.save_tag) return requestSave(tables, buffer);
    // Any key ends the wait for a character, and a jump that was choosing its place.
    row.awaiting.* = @intFromEnum(Awaiting.none);
    row.jump.* = @intFromEnum(Jump.none);
    // And a wish to show something in another window that showed nothing: its prompt was
    // given up.
    if (navigationRow(tables)) |navigation| navigation.other_window.* = 0;
    // The count typed before this command is its own, and leaving drops it.
    const argument = takeArgument(row);
    if (argument != null) noteArgument(tables, row);
    if (tag == shared.leave_tag) {
        text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = .cancel } });
        return;
    }
    const command = try shared.commandOf(received);
    // While completions are listed, the keys that move through a list and take from it are
    // the list's; a character deleted narrows it less; any other command ends it.
    if (row.completing.* == @intFromEnum(Completing.listed)) {
        switch (command) {
            .line_down => return stepCompletion(tables, row, .next),
            .line_up => return stepCompletion(tables, row, .previous),
            .new_line, .indent => return acceptCompletion(tables, row),
            .cancel => {
                row.completing.* = @intFromEnum(Completing.none);
                return;
            },
            .delete_back => {},
            else => row.completing.* = @intFromEnum(Completing.none),
        }
    } else if (command != .delete_back) {
        // An answer still on its way is for a place the caret may have left.
        row.completing.* = @intFromEnum(Completing.none);
    }
    const count = argument orelse 1;
    const lines: f32 = @floatFromInt(count);
    // Only a `recenter` right after a `recenter` goes on to the next place.
    if (command != .recenter) row.recenter.* = @intFromEnum(Recenter.middle);
    switch (command) {
        // The buffer has no window: scrolling is the panel's.
        .scroll_up => row.scroll_y.* = @max(row.scroll_y.* - lines * row.line_height.*, 0),
        .scroll_down => row.scroll_y.* += lines * row.line_height.*,
        .scroll_page_up => scrollPage(tables, atoms, row, .previous),
        .scroll_page_down => scrollPage(tables, atoms, row, .next),
        .recenter => recenter(tables, atoms, row),
        // With a count, `C-SPC` goes back to the mark instead of setting it.
        .set_mark => {
            const marking: text_editor.EditCommand = if (argument != null) .pop_mark else .set_mark;
            recordMacroStep(tables, .command, marking, 1, "");
            text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = marking } });
        },
        else => {
            recordMacroStep(tables, .command, command, count, "");
            text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = command, .count = count } });
        },
    }
}

// ---- registers ---------------------------------------------------------------------------------
//
// As Emacs's `C-x r` commands: `C-x r s` copies the selection to a register and `C-x r i`
// inserts one; `C-x r SPC` keeps the caret's place in one and `C-x r j` goes there. The
// character typed next names the register, which holds one thing: the last put there.

fn registerNamed(registers: *Table, name: u32) ?struct { handle: Table.RowHandle, row: RegisterRow } {
    var rows = registers.query(RegisterRow);
    while (rows.next()) |found| {
        if (found.view.name.* == name) return .{ .handle = found.handle, .row = found.view };
    }
    return null;
}

/// Does what was waiting for a register's name with the register `name`.
fn useRegister(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table, row: PanelRow, use: Awaiting, name: u32) void {
    const memory = tables.memory;
    const registers = tables.findByName(registers_table) orelse return;
    const buffer = row.buffer.*;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    switch (use) {
        .register_copy, .register_point => {
            const caret: u32 = @intCast(state.caret.*);
            const anchor: u32 = @intCast(state.anchor.*);
            var text: []const u8 = "";
            if (use == .register_copy) {
                const view = text_editor.viewOf(tables, buffer) orelse return;
                const start = @min(caret, anchor);
                const length = @max(caret, anchor) - start;
                if (length == 0) return;
                if (length > max_register_bytes) return text_editor.message(memory, tables, "The selection is more than a register keeps");
                const scratch = memory.frameScratchAllocator() catch return;
                const copied = scratch.allocator.alloc(u8, length) catch return;
                text = view.copyRange(start, copied);
            }
            // A register holds one thing: what it held goes.
            if (registerNamed(registers, name)) |held| registers.free(held.handle);
            const kind: RegisterKind = if (use == .register_copy) .text else .place;
            _ = registers.tryInsert(.{ .name = name, .kind = @as(u8, @intFromEnum(kind)), .text = text, .buffer = buffer, .offset = caret }) catch |err| {
                Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
                return;
            };
            // The selection copied is let go, as a copy lets go of it.
            if (use == .register_copy) text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = .cancel } });
        },
        .register_insert => {
            const held = registerNamed(registers, name) orelse return text_editor.message(memory, tables, "The register holds nothing");
            if (held.row.kind.* != @intFromEnum(RegisterKind.text)) return text_editor.message(memory, tables, "The register holds a place, not text");
            text_editor.request(memory, tables, .{ .paste = .{ .buffer = buffer, .utf8 = held.row.text } });
        },
        .register_jump => {
            const held = registerNamed(registers, name) orelse return text_editor.message(memory, tables, "The register holds nothing");
            if (held.row.kind.* != @intFromEnum(RegisterKind.place)) return text_editor.message(memory, tables, "The register holds text, not a place");
            const target = held.row.buffer.*;
            const offset = held.row.offset.*;
            if (text_editor.rowOf(tables, target) == null) return text_editor.message(memory, tables, "The register's buffer is gone");
            // The place left is the mark, to go back to.
            text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = .push_mark } });
            showAsWished(tables, atoms, table, target);
            text_editor.request(memory, tables, .{ .select_range = .{ .buffer = target, .anchor = offset, .caret = offset } });
        },
        .none, .zap, .zap_through => {},
    }
}

// ---- keyboard macros ---------------------------------------------------------------------------
//
// F3 begins a macro and F4 ends it; F4 again does it again, as many times as a count says.
// A macro is the edit commands run and the text typed in the text panels while it was
// defined, in order. What a prompt was asked, as a search's text, is not in it.

fn macroState(tables: *Table.Registry) ?MacroState {
    const found = tables.findByName(macro_state_table) orelse return null;
    return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, MacroState);
}

/// Keeps a step of the macro being defined, when one is.
fn recordMacroStep(tables: *Table.Registry, kind: MacroStepKind, command: text_editor.EditCommand, count: u32, text: []const u8) void {
    const state = macroState(tables) orelse return;
    if (state.recording.* == 0) return;
    const steps = tables.findByName(macro_table) orelse return;
    if (steps.count() >= max_macro_steps) return;
    _ = steps.tryInsert(.{ .kind = @as(u8, @intFromEnum(kind)), .command = @as(u8, @intFromEnum(command)), .count = count, .text = text }) catch |err| {
        Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
    };
}

/// The most times one key does a macro again: a count past it does this many.
const max_macro_calls = 1000;

/// Does the macro last defined in `buffer`, `times` over.
fn callMacro(tables: *Table.Registry, buffer: Atom, times: u32) void {
    const memory = tables.memory;
    const steps = tables.findByName(macro_table) orelse return;
    if (steps.count() == 0) return text_editor.message(memory, tables, "No keyboard macro is defined");
    for (0..@min(times, max_macro_calls)) |_| {
        var rows = steps.readQuery(MacroStep);
        while (rows.next()) |found| {
            const step = found.view;
            const kind: MacroStepKind = std.enums.fromInt(MacroStepKind, step.kind.*) orelse continue;
            switch (kind) {
                .command => {
                    const command = std.enums.fromInt(text_editor.EditCommand, step.command.*) orelse continue;
                    text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = command, .count = step.count.* } });
                },
                .text => text_editor.request(memory, tables, .{ .insert = .{ .buffer = buffer, .utf8 = step.text, .count = step.count.* } }),
                .zap_up_to => text_editor.request(memory, tables, .{ .zap = .{ .buffer = buffer, .utf8 = step.text, .reach = .up_to } }),
                .zap_through => text_editor.request(memory, tables, .{ .zap = .{ .buffer = buffer, .utf8 = step.text, .reach = .through } }),
            }
        }
    }
}

// ---- completing at the caret -------------------------------------------------------------------
//
// As corfu with completion on a key: TAB completes what is typed before the caret, or
// indents when nothing is; C-M-i only completes. The language server says what could be
// typed there; the completions that begin as the text does are listed under the caret, and
// narrow as more is typed. C-n and C-p move through them, RET or TAB takes the one chosen,
// C-g closes the list. A lone completion is taken at once.

/// The rows of completions listed at once.
const completion_rows = 14;
/// The list is this many cells wide at least and at most.
const completion_min_cells = 20;
const completion_max_cells = 80;

/// Where the name the caret is in or after begins.
fn nameStartBefore(view: *const text_editor.View, offset: u32) u32 {
    var start = offset;
    while (start > 0 and isWordByte(view.byteAt(start - 1))) start -= 1;
    return start;
}

/// Asks the language server what could be typed at the caret. The key that also indents
/// indents instead when nothing is typed before the caret.
fn askCompletions(tables: *Table.Registry, row: PanelRow, how: Completing) void {
    const memory = tables.memory;
    const buffer = row.buffer.*;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const view = text_editor.viewOf(tables, buffer) orelse return;
    const caret: u32 = @intCast(state.caret.*);
    const start = nameStartBefore(view, caret);
    const after_member = caret > 0 and view.byteAt(caret - 1) == '.';
    const has_selection = state.caret.* != state.anchor.*;
    if (how == .asked_or_indent and (has_selection or (start == caret and !after_member))) {
        text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = .indent } });
        return;
    }
    row.completing.* = @intFromEnum(how);
    row.completion_start.* = start;
    row.completion_selected.* = 0;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_completions)).with(.of(&buffer));
    lsp.request(memory, tables, .{ .completion = .{ .buffer = buffer, .offset = caret, .reply = reply } });
}

/// What is typed of the name being completed: the text from where it begins to the caret.
fn completionPrefix(tables: *Table.Registry, row: ReadRow, buffer: *[lsp.max_item_field_bytes]u8) ?[]const u8 {
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return null;
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return null;
    const caret: u32 = @intCast(state.caret.*);
    const start = row.completion_start.*;
    if (caret < start or caret - start > buffer.len) return null;
    return view.copyRange(start, buffer[0 .. caret - start]);
}

fn completionBegins(label: []const u8, prefix: []const u8) bool {
    return label.len >= prefix.len and std.ascii.eqlIgnoreCase(label[0..prefix.len], prefix);
}

/// How many of the completions kept begin as `prefix` does.
fn countCompletions(tables: *Table.Registry, prefix: []const u8) u32 {
    const kept = tables.findByName(completions_table) orelse return 0;
    var count: u32 = 0;
    var rows = kept.readQuery(CompletionRow);
    while (rows.next()) |found| {
        if (completionBegins(found.view.label, prefix)) count += 1;
    }
    return count;
}

/// The language server's answer: its completions are kept, and listed when more than one
/// begins as the text does; a lone one is taken; with none the key that also indents does.
fn takeCompletions(tables: *Table.Registry, table: *Table, row: PanelRow, result: lsp.QueryResult, trailing: []const u8) void {
    const how: Completing = std.enums.fromInt(Completing, row.completing.*) orelse .none;
    // The caret moved on since it asked: the answer is for nothing now.
    if (how != .asked and how != .asked_or_indent) return;
    row.completing.* = @intFromEnum(Completing.none);
    const kept = tables.findByName(completions_table) orelse return;
    kept.clear();
    if (result == .found) {
        var items = lsp.Items.of(trailing);
        var fields: [3][]const u8 = undefined;
        while (items.next(&fields)) |item| {
            _ = kept.tryInsert(.{ .label = item[0], .inserted = item[1], .detail = item[2] }) catch break;
        }
    }
    var prefix_buffer: [lsp.max_item_field_bytes]u8 = undefined;
    const prefix = completionPrefix(tables, readRow(row), &prefix_buffer) orelse return;
    const matching = countCompletions(tables, prefix);
    if (matching == 0) {
        if (how == .asked_or_indent) {
            text_editor.request(tables.memory, tables, .{ .run = .{ .buffer = row.buffer.*, .command = .indent } });
            return;
        }
        const told: []const u8 = if (result == .no_server) "No language server for this file" else "No completions";
        return setInfo(table, row.panel.*, told);
    }
    row.completing.* = @intFromEnum(Completing.listed);
    row.completion_selected.* = 0;
    if (matching == 1) acceptCompletion(tables, row);
}

/// Puts the chosen completion in the text, in place of what was typed of it.
fn acceptCompletion(tables: *Table.Registry, row: PanelRow) void {
    row.completing.* = @intFromEnum(Completing.none);
    var prefix_buffer: [lsp.max_item_field_bytes]u8 = undefined;
    const prefix = completionPrefix(tables, readRow(row), &prefix_buffer) orelse return;
    const kept = tables.findByName(completions_table) orelse return;
    var index: u32 = 0;
    var rows = kept.readQuery(CompletionRow);
    while (rows.next()) |found| {
        if (!completionBegins(found.view.label, prefix)) continue;
        if (index != row.completion_selected.*) {
            index += 1;
            continue;
        }
        const prefix_len: u32 = @intCast(prefix.len);
        text_editor.request(tables.memory, tables, .{ .replace_range = .{ .buffer = row.buffer.*, .start = row.completion_start.*, .len = prefix_len, .utf8 = found.view.inserted, .step = .new } });
        return;
    }
}

/// Chooses the completion after the one chosen, or before it, among those listed.
fn stepCompletion(tables: *Table.Registry, row: PanelRow, direction: Direction) void {
    var prefix_buffer: [lsp.max_item_field_bytes]u8 = undefined;
    const prefix = completionPrefix(tables, readRow(row), &prefix_buffer) orelse return;
    const listed = countCompletions(tables, prefix);
    if (listed == 0) return;
    const selected = row.completion_selected.*;
    row.completion_selected.* = if (direction == .next) @min(selected + 1, listed - 1) else selected -| 1;
}

/// The text changed under a list of completions: it closes when the caret has left what it
/// completes or nothing listed begins as the text now does, and its choice stays in it.
fn settleCompletion(tables: *Table.Registry, row: PanelRow) void {
    if (row.completing.* != @intFromEnum(Completing.listed)) return;
    var prefix_buffer: [lsp.max_item_field_bytes]u8 = undefined;
    const prefix = completionPrefix(tables, readRow(row), &prefix_buffer);
    const listed = if (prefix) |typed| countCompletions(tables, typed) else 0;
    if (listed == 0) {
        row.completing.* = @intFromEnum(Completing.none);
        return;
    }
    if (row.completion_selected.* >= listed) row.completion_selected.* = listed - 1;
}

// ---- going to a symbol -------------------------------------------------------------------------

/// Keeps what the language server says the buffer defines, a row each.
fn keepSymbols(tables: *Table.Registry, trailing: []const u8) void {
    const kept = tables.findByName(symbols_table) orelse return;
    kept.clear();
    var items = lsp.Items.of(trailing);
    var fields: [4][]const u8 = undefined;
    while (items.next(&fields)) |item| {
        const line = std.fmt.parseInt(u32, item[1], 10) catch continue;
        const column = std.fmt.parseInt(u32, item[2], 10) catch continue;
        _ = kept.tryInsert(.{ .name = item[0], .kind = item[3], .line = line, .column = column }) catch break;
    }
}

/// Asks, in the palette, which of the things the buffer defines to go to: those whose name
/// holds `query`, in either case, in the order they are defined.
fn presentSymbols(tables: *Table.Registry, buffer: Atom, query: []const u8, prompt: EncodingPrompt) void {
    const memory = tables.memory;
    const kept = tables.findByName(symbols_table) orelse return;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (prompt == .open) action_palette.resetCompletionArena(memory, .text_panel);
    const listed = allocator.alloc(action_palette.Completion, lsp.max_items) catch return;
    var count: usize = 0;
    var rows = kept.readQuery(SymbolRow);
    while (rows.next()) |found| {
        if (count == listed.len) break;
        if (std.ascii.indexOfIgnoreCase(found.view.name, query) == null) continue;
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        std.mem.writeInt(u32, data[0..4], found.view.line.*, .little);
        std.mem.writeInt(u32, data[4..8], found.view.column.*, .little);
        listed[count] = .{ .label = found.view.name, .detail = found.view.kind, .data = data };
        count += 1;
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .title = "Go to symbol",
        .initial_query = query,
        .entries = listed[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    if (prompt == .narrow) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
        return;
    }
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_symbol)).with(.of(&buffer));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

// ---- jumping to a place in sight ---------------------------------------------------------------
//
// As avy: a jump names every place in sight of one kind, a character typed, a pair of them,
// a word that begins with one, or a line's start, with letters of the settings' `hint_keys`
// drawn over it, and typing a place's letters goes there, the mark left behind. With more
// places than letters each has two. Any other key gives the jump up.

/// The kind of place a jump chooses among.
const Jump = enum(u8) {
    none,
    char,
    char_2,
    word,
    line,

    /// How many characters are typed to say what the jump looks for.
    fn characters(kind: Jump) u8 {
        return switch (kind) {
            .none, .line => 0,
            .char, .word => 1,
            .char_2 => 2,
        };
    }
};

/// The most places a jump names: as many as two letters of the longest hint keys tell apart.
const max_jump_targets = 256;

/// The stretch of a buffer's text a panel shows, from the start of its first line in sight
/// to the end of its last.
fn sightOf(view: *const text_editor.View, scroll_y: f32, line_height: f32, height: f32) struct { start: u32, end: u32 } {
    const line_count = view.lineCount();
    const first_line: u32 = @intFromFloat(@floor(scroll_y / line_height));
    const lines_in_sight: u32 = @intFromFloat(@ceil(height / line_height) + 1);
    return .{
        .start = view.lineStart(@min(first_line, line_count - 1)),
        .end = view.lineEnd(@min(first_line + lines_in_sight, line_count - 1)),
    };
}

/// What a jump looks for, from the row's cells: the bytes typed so far.
fn jumpNeedle(row: ReadRow, buffer: *[8]u8) []const u8 {
    std.mem.writeInt(u64, buffer, row.jump_needle.*, .little);
    const length = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..length];
}

/// The places a jump of `kind` names between `start` and `end`, in order, in `storage`.
fn jumpTargets(storage: []u32, view: *const text_editor.View, kind: Jump, needle: []const u8, start: u32, end: u32) []const u32 {
    var count: usize = 0;
    if (kind == .line) {
        var line = view.lineOf(start);
        const last_line = view.lineOf(end);
        while (line <= last_line and count < storage.len) : (line += 1) {
            storage[count] = view.lineStart(line);
            count += 1;
        }
        return storage[0..count];
    }
    if (needle.len == 0) return storage[0..0];
    var from = start;
    while (count < storage.len) {
        const found = view.find(needle, from) orelse break;
        if (found >= end) break;
        from = found + 1;
        // A word's jump names only the places a word begins.
        const begins_word = found == 0 or !isWordByte(view.byteAt(found - 1));
        if (kind == .word and !begins_word) continue;
        storage[count] = found;
        count += 1;
    }
    return storage[0..count];
}

/// The letters that name place `index` of `count`: one of `keys` while there are no more
/// places than keys, else two.
fn jumpLabel(keys: []const u8, index: usize, count: usize) [2]u8 {
    if (count <= keys.len) return .{ keys[index], 0 };
    const first = index / keys.len;
    if (first >= keys.len) return .{ 0, 0 };
    return .{ keys[first], keys[index % keys.len] };
}

/// A character typed while a jump is under way: one of what it looks for, until that is
/// whole, then a letter of the place meant.
fn jumpTyped(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, utf8: []const u8) void {
    const kind: Jump = std.enums.fromInt(Jump, row.jump.*) orelse .none;
    if (row.jump_typed.* < kind.characters()) {
        var needle_buffer: [8]u8 = undefined;
        const so_far = jumpNeedle(readRow(row), &needle_buffer).len;
        if (so_far + utf8.len > needle_buffer.len) {
            row.jump.* = @intFromEnum(Jump.none);
            return;
        }
        @memset(needle_buffer[so_far..], 0);
        @memcpy(needle_buffer[so_far..][0..utf8.len], utf8);
        row.jump_needle.* = std.mem.readInt(u64, &needle_buffer, .little);
        row.jump_typed.* += 1;
        return;
    }
    // A letter of a place: it ends the jump, or is the first of two.
    const letter = utf8[0];
    const first_letter = row.jump_letter.*;
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return;
    const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse return;
    if (row.line_height.* <= 0) return;
    const sight = sightOf(view, row.scroll_y.*, row.line_height.*, content.h);
    var needle_buffer: [8]u8 = undefined;
    const needle = jumpNeedle(readRow(row), &needle_buffer);
    var storage: [max_jump_targets]u32 = undefined;
    const targets = jumpTargets(&storage, view, kind, needle, sight.start, sight.end);
    const keys = shared.settingsOf(tables).hint_keys;
    var chosen: ?u32 = null;
    var begins_a_name = false;
    for (targets, 0..) |target, index| {
        const label = jumpLabel(keys, index, targets.len);
        if (first_letter == 0) {
            if (label[0] != letter) continue;
            if (label[1] == 0) chosen = target else begins_a_name = true;
        } else if (label[0] == first_letter and label[1] == letter) {
            chosen = target;
        }
        if (chosen != null) break;
    }
    if (chosen) |target| {
        row.jump.* = @intFromEnum(Jump.none);
        // The place left is the mark, to go back to (C-x C-x, C-u C-SPC).
        text_editor.request(tables.memory, tables, .{ .run = .{ .buffer = row.buffer.*, .command = .push_mark } });
        text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = target, .caret = target } });
        return;
    }
    if (begins_a_name and first_letter == 0) {
        row.jump_letter.* = letter;
        return;
    }
    // No place has those letters: the jump is given up.
    row.jump.* = @intFromEnum(Jump.none);
}

// ---- going to a window by its letter ----------------------------------------------------------
//
// As ace-window: with more than two windows, each is listed with a letter of the settings'
// `hint_keys`, and typing the letter goes there. With two, it goes to the other at once.

/// The window `letter` names: the panels in the order the window has them, lettered from the
/// settings' hint keys.
fn windowLettered(tables: *Table.Registry, atoms: *Atom.Registry, letter: []const u8) ?Atom {
    if (letter.len != 1) return null;
    const settings = shared.settingsOf(tables);
    const index = std.mem.indexOfScalar(u8, settings.hint_keys, letter[0]) orelse return null;
    var shown_buffer: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
    const shown = panels_mod.panels(tables, atoms, &shown_buffer);
    return if (index < shown.len) shown[index].id else null;
}

/// Lists the windows with their letters, or with two windows goes to the other.
fn presentWindows(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table) void {
    const memory = tables.memory;
    var shown_buffer: [panels_mod.kMaxPanels]panels_mod.Panel = undefined;
    const shown = panels_mod.panels(tables, atoms, &shown_buffer);
    if (shown.len <= 2) return plugin.panels.request(memory, tables, .{ .focus_next = {} });
    const settings = shared.settingsOf(tables);
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    action_palette.resetCompletionArena(memory, .text_panel);
    const lettered = @min(shown.len, settings.hint_keys.len);
    const entries = allocator.alloc(action_palette.Completion, lettered) catch return;
    // By pointer: a label is a slice of the panel's title, read after the loop.
    for (shown[0..lettered], entries, 0..) |*panel, *entry, index| {
        // A text window has no title of its own: it is told by what it shows.
        var label = panel.title.slice();
        if (rowOfPanel(table, panel.id)) |found| {
            if (text_editor.rowOf(tables, found.row.buffer.*)) |state| label = bufferTitle(state);
        }
        entry.* = .{ .key = settings.hint_keys[index .. index + 1], .label = label };
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    // A letter typed goes to its window: a title typed by Tab would go nowhere.
    completions.* = .{ .owner = prompt_owner, .presentation = .prompt, .prompt = "Window:", .tab = .nothing, .entries = entries };
    action_palette.ownRequestText(allocator, completions) catch return;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_window));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

// ---- searching as the text is typed -----------------------------------------------------------
//
// `C-s` and `C-r` search as Emacs's isearch does. The minibuffer's line takes the text; each
// change of it looks again from where the search began, and what is found is selected. `C-s`
// and `C-r` again go on to the next match and the one before, round the text's ends. RET
// stays, leaving the mark where the search began; C-g returns there. Every match in sight is
// tinted (`searchHighlights`).

/// The panel that is searching, if one is.
fn searchingRow(table: *Table) ?PanelRow {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.search.* != @intFromEnum(Search.none)) return found.view;
    }
    return null;
}

fn searchLabel(direction: Search, failing: bool) []const u8 {
    if (direction == .backward) return if (failing) "Failing I-search backward:" else "I-search backward:";
    return if (failing) "Failing I-search:" else "I-search:";
}

/// Shows the search's prompt, or the same prompt saying anew whether the text is found.
fn presentSearch(tables: *Table.Registry, row: PanelRow, how: enum { open, relabel }) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    if (how == .open) action_palette.resetCompletionArena(memory, .text_panel);
    const direction: Search = std.enums.fromInt(Search, row.search.*) orelse .forward;
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .prompt = searchLabel(direction, row.search_failing.* != 0),
        .accepts_text = true,
        .entries = &.{},
    };
    if (how == .relabel) return action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
    const buffer = row.buffer.*;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_isearch)).with(.of(&buffer));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply, .mode = modes.isearch } });
}

fn beginSearch(tables: *Table.Registry, row: PanelRow, direction: Search) void {
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    row.search.* = @intFromEnum(direction);
    row.search_origin.* = @intCast(state.caret.*);
    row.search_failing.* = 0;
    presentSearch(tables, row, .open);
}

/// Selects the match at `start`, the caret at the end the search is heading to, or says
/// the text is not found.
fn showMatch(tables: *Table.Registry, row: PanelRow, match: ?u32, needle_len: u32) void {
    const was_failing = row.search_failing.* != 0;
    const direction: Search = std.enums.fromInt(Search, row.search.*) orelse .forward;
    if (match) |start| {
        const end = start + needle_len;
        const anchor = if (direction == .forward) start else end;
        const caret = if (direction == .forward) end else start;
        text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = anchor, .caret = caret } });
    }
    row.search_failing.* = @intFromBool(match == null);
    if (was_failing != (match == null)) presentSearch(tables, row, .relabel);
}

/// The search's text changed: looks for it from where the search began.
fn searchFromOrigin(tables: *Table.Registry, row: PanelRow, needle: []const u8) void {
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return;
    const origin = row.search_origin.*;
    const direction: Search = std.enums.fromInt(Search, row.search.*) orelse return;
    if (direction == .none) return;
    if (needle.len == 0) {
        text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = origin, .caret = origin } });
        return showMatch(tables, row, origin, 0);
    }
    const match = if (direction == .forward) view.find(needle, origin) else view.findBackward(needle, origin);
    showMatch(tables, row, match, @intCast(needle.len));
}

/// `C-s` or `C-r` while searching: on to the next match that way, round the text's ends. With
/// nothing typed yet, the text last searched for is taken up.
fn repeatSearch(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, direction: Search) void {
    row.search.* = @intFromEnum(direction);
    const needle = action_palette.promptText(tables, atoms);
    if (needle.len == 0) {
        const text = rememberedText(tables, "last");
        if (text.len != 0) text_editor.request(tables.memory, tables, .{ .insert = .{ .buffer = action_palette.text_editor_name, .utf8 = text } });
        return presentSearch(tables, row, .relabel);
    }
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return;
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const needle_len: u32 = @intCast(needle.len);
    const selection_start: u32 = @intCast(@min(state.caret.*, state.anchor.*));
    const selection_end: u32 = @intCast(@max(state.caret.*, state.anchor.*));
    // From a match, the next one begins after its start; from none, where the caret is.
    const on_match = selection_end - selection_start == needle_len and row.search_failing.* == 0;
    var match: ?u32 = null;
    if (direction == .forward) {
        const from = if (on_match) selection_start + 1 else selection_end;
        match = view.find(needle, from) orelse view.find(needle, 0);
    } else {
        const end_limit = if (on_match) selection_end - 1 else selection_start;
        match = view.findBackward(needle, end_limit) orelse view.findBackward(needle, view.byteCount());
    }
    showMatch(tables, row, match, needle_len);
    // The label tells the way the search now looks.
    presentSearch(tables, row, .relabel);
}

/// The most of a word `C-w` takes into the search's text at once.
const max_yanked_word = 128;

/// Adds the word after the match, or the rest of the one it ends in, to the search's text.
fn yankWordIntoSearch(tables: *Table.Registry, row: PanelRow) void {
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return;
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const text_len = view.byteCount();
    const start: u32 = @intCast(@max(state.caret.*, state.anchor.*));
    var end = start;
    // Over what is no word, then over the word, as `forward-word` moves.
    while (end < text_len and end - start < max_yanked_word and !isWordByte(view.byteAt(end)) and view.byteAt(end) != '\n') end += 1;
    while (end < text_len and end - start < max_yanked_word and isWordByte(view.byteAt(end))) end += 1;
    if (end == start) return;
    var word_buffer: [max_yanked_word]u8 = undefined;
    const word = view.copyRange(start, word_buffer[0 .. end - start]);
    text_editor.request(tables.memory, tables, .{ .insert = .{ .buffer = action_palette.text_editor_name, .utf8 = word } });
}

fn isWordByte(byte: u8) bool {
    return byte >= 0x80 or byte == '_' or std.ascii.isAlphanumeric(byte);
}

/// Ends the search: the caret stays at the match with the mark left where the search began,
/// or goes back there. The text searched for is remembered.
fn endSearch(tables: *Table.Registry, row: PanelRow, needle: []const u8, ending: enum { stay, return_to_origin }) void {
    const memory = tables.memory;
    const buffer = row.buffer.*;
    const origin = row.search_origin.*;
    row.search.* = @intFromEnum(Search.none);
    row.search_failing.* = 0;
    if (ending == .return_to_origin) {
        text_editor.request(memory, tables, .{ .select_range = .{ .buffer = buffer, .anchor = origin, .caret = origin } });
        return;
    }
    if (needle.len != 0) rememberText(tables, "last", needle);
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const caret: u32 = @intCast(state.caret.*);
    // The place the search began is the mark, to go back to (C-x C-x, C-u C-SPC).
    text_editor.request(memory, tables, .{ .select_range = .{ .buffer = buffer, .anchor = origin, .caret = origin } });
    text_editor.request(memory, tables, .{ .run = .{ .buffer = buffer, .command = .push_mark } });
    text_editor.request(memory, tables, .{ .select_range = .{ .buffer = buffer, .anchor = caret, .caret = caret } });
}

// ---- search and replace -----------------------------------------------------------------------
//
// `M-%` replaces as Emacs's `query-replace` does, with what visual-replace shows: one prompt
// asks what to replace, the next what with, and while either is typed the matches are tinted
// and what would replace each is drawn beside it. Then each match is asked about: `y` or a
// space replaces it, `n` leaves it, `!` replaces it and all the rest, and anything else
// stops. The replacements are one undo step. With a selection only what it holds is covered;
// with none, from the caret to the text's end.

fn replacePhase(row: ReadRow) Replace {
    return std.enums.fromInt(Replace, row.replace.*) orelse .none;
}

/// Shows the prompt of the phase the replace is in.
fn presentReplace(tables: *Table.Registry, row: PanelRow) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    action_palette.resetCompletionArena(memory, .text_panel);
    const label: []const u8 = switch (replacePhase(readRow(row))) {
        .none => return,
        .from => "Replace:",
        .to => std.fmt.allocPrint(allocator, "Replace {s} with:", .{rememberedText(tables, "replace_from")}) catch return,
        .asking => "Replace? (y, n, ! for the rest, q to stop)",
    };
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .prompt = label,
        .accepts_text = true,
        .entries = &.{},
    };
    const buffer = row.buffer.*;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_replace)).with(.of(&buffer));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

fn beginReplace(tables: *Table.Registry, row: PanelRow) void {
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const caret: u32 = @intCast(state.caret.*);
    const anchor: u32 = @intCast(state.anchor.*);
    const has_selection = caret != anchor;
    const start = @min(caret, anchor);
    row.replace.* = @intFromEnum(Replace.from);
    row.replace_start.* = start;
    row.replace_end.* = if (has_selection) @max(caret, anchor) else @intCast(state.bytes.*);
    row.replace_count.* = 0;
    // The selection said where; the matches are what is shown from here on.
    if (has_selection) text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = start, .caret = start } });
    presentReplace(tables, row);
}

/// An event of whichever of the replace's prompts is open.
fn replaceEvent(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, event: action_palette.Msg.Event) void {
    const phase = replacePhase(readRow(row));
    if (event.kind == .query_changed) {
        switch (phase) {
            .none => {},
            // What is typed is shown against the text as it is typed.
            .from, .to => row.replace_preview.* +%= 1,
            .asking => answerReplace(tables, atoms, row, event.query),
        }
        return;
    }
    action_palette.request(tables.memory, tables, .{ .acknowledge = .{ .owner = prompt_owner } });
    const accepted = event.completion != null;
    switch (phase) {
        // The prompt this panel closed itself, once it had its answer.
        .none => {},
        .from => {
            if (!accepted or event.query.len == 0) return endReplace(tables, row, .quiet);
            rememberText(tables, "replace_from", event.query);
            row.replace.* = @intFromEnum(Replace.to);
            presentReplace(tables, row);
        },
        .to => {
            if (!accepted) return endReplace(tables, row, .quiet);
            rememberText(tables, "replace_to", event.query);
            askFirstReplace(tables, row);
        },
        .asking => endReplace(tables, row, .told),
    }
}

/// Selects the first match the replace covers and asks about it, or tells there is none.
fn askFirstReplace(tables: *Table.Registry, row: PanelRow) void {
    const view = text_editor.viewOf(tables, row.buffer.*) orelse return endReplace(tables, row, .quiet);
    const needle = rememberedText(tables, "replace_from");
    const needle_len: u32 = @intCast(needle.len);
    const match = view.find(needle, row.replace_start.*);
    const covered = if (match) |start| start + needle_len <= row.replace_end.* else false;
    if (!covered) return endReplace(tables, row, .told);
    const start = match.?;
    text_editor.request(tables.memory, tables, .{ .select_range = .{ .buffer = row.buffer.*, .anchor = start, .caret = start + needle_len } });
    row.replace.* = @intFromEnum(Replace.asking);
    presentReplace(tables, row);
}

/// How many times `needle` is from `start` on, wholly before `end`, one after another.
fn countMatches(view: *const text_editor.View, needle: []const u8, start: u32, end: u32) u32 {
    const needle_len: u32 = @intCast(needle.len);
    var count: u32 = 0;
    var from = start;
    while (view.find(needle, from)) |match| {
        if (match + needle_len > end) break;
        count += 1;
        from = match + needle_len;
    }
    return count;
}

/// A key typed at the question about the selected match.
fn answerReplace(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, typed: []const u8) void {
    if (typed.len == 0) return;
    const memory = tables.memory;
    const buffer = row.buffer.*;
    // The line is for the next answer.
    text_editor.request(memory, tables, .{ .set_text = .{ .buffer = action_palette.text_editor_name, .text = "" } });
    const view = text_editor.viewOf(tables, buffer) orelse return;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const needle = rememberedText(tables, "replace_from");
    const replacement = rememberedText(tables, "replace_to");
    const needle_len: u32 = @intCast(needle.len);
    const replacement_len: u32 = @intCast(replacement.len);
    const match_start: u32 = @intCast(@min(state.caret.*, state.anchor.*));
    const match_end: u32 = @intCast(@max(state.caret.*, state.anchor.*));
    if (match_end - match_start != needle_len) return closeReplace(tables, atoms, row);
    // The text as it is now, before what is asked for here is applied.
    const end_now = row.replace_end.*;
    const step: text_editor.UndoStep = if (row.replace_count.* == 0) .new else .joined;
    var replaced_here = false;
    switch (typed[0]) {
        'y', ' ' => {
            text_editor.request(memory, tables, .{ .replace_range = .{ .buffer = buffer, .start = match_start, .len = needle_len, .utf8 = replacement, .step = step } });
            row.replace_count.* += 1;
            row.replace_end.* = end_now - needle_len + replacement_len;
            replaced_here = true;
        },
        'n' => {},
        '!' => {
            row.replace_count.* += countMatches(view, needle, match_start, end_now);
            text_editor.request(memory, tables, .{ .replace_all = .{ .buffer = buffer, .needle = needle, .utf8 = replacement, .start = match_start, .end = end_now, .step = step } });
            return closeReplace(tables, atoms, row);
        },
        else => return closeReplace(tables, atoms, row),
    }
    const next = view.find(needle, match_end);
    const covered = if (next) |start| start + needle_len <= end_now else false;
    if (!covered) return closeReplace(tables, atoms, row);
    // Once the replacement asked for above is made, what follows it has moved.
    var next_start = next.?;
    if (replaced_here) next_start = next_start - needle_len + replacement_len;
    text_editor.request(memory, tables, .{ .select_range = .{ .buffer = buffer, .anchor = next_start, .caret = next_start + needle_len } });
}

/// Ends the replace from its own question: the prompt is closed, which this panel hears of
/// with the replace already over.
fn closeReplace(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow) void {
    endReplace(tables, row, .told);
    if (action_palette.requestOpen(tables, atoms)) action_palette.request(tables.memory, tables, .{ .cancel = .{ .owner = prompt_owner } });
}

/// The replace is over: nothing is selected, and how many were replaced is told unless it
/// never got as far as asking.
fn endReplace(tables: *Table.Registry, row: PanelRow, telling: enum { told, quiet }) void {
    const count = row.replace_count.*;
    row.replace.* = @intFromEnum(Replace.none);
    row.replace_count.* = 0;
    row.replace_preview.* +%= 1;
    text_editor.request(tables.memory, tables, .{ .run = .{ .buffer = row.buffer.*, .command = .cancel } });
    if (telling == .quiet) return;
    var message_buffer: [64]u8 = undefined;
    const noun: []const u8 = if (count == 1) "occurrence" else "occurrences";
    const message = std.fmt.bufPrint(&message_buffer, "Replaced {d} {s}", .{ count, noun }) catch return;
    text_editor.message(tables.memory, tables, message);
}

/// Goes to a line by its number, counted from one. The place left is the mark, to go back
/// to (C-x C-x).
fn gotoLine(tables: *Table.Registry, buffer: Atom, line: u32) void {
    text_editor.request(tables.memory, tables, .{ .run = .{ .buffer = buffer, .command = .push_mark } });
    text_editor.request(tables.memory, tables, .{ .set_caret = .{ .buffer = buffer, .line = line -| 1, .column = 0, .select = .motion } });
}

/// Scrolls the caret's line to the middle of the panel, and when asked again at once to the
/// top, then the bottom.
fn recenter(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow) void {
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse return;
    const place: Recenter = std.enums.fromInt(Recenter, row.recenter.*) orelse .middle;
    row.recenter.* = @intFromEnum(place.next());
    const caret_top = @as(f32, @floatFromInt(state.caret_line.*)) * row.line_height.*;
    const text_height = content.h - 2 * padding;
    const room = text_height - row.line_height.*;
    const scroll = switch (place) {
        .middle => caret_top - room / 2,
        .top => caret_top,
        .bottom => caret_top - room,
    };
    row.scroll_y.* = @max(@round(scroll), 0);
}

/// The lines of the page before that stay in sight after a page's scroll, as Emacs keeps.
const page_context_lines = 2;

/// Scrolls the panel a page, as Emacs's C-v and M-v: the text moves, and the caret only when
/// it would be left out of sight, to the nearest line still in it.
fn scrollPage(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow, direction: Direction) void {
    const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse return;
    const line_height = row.line_height.*;
    if (line_height <= 0) return;
    const text_height = content.h - 2 * padding;
    const visible_lines = @max(@floor(text_height / line_height), 1);
    const page = @max(visible_lines - page_context_lines, 1) * line_height;
    // The last line can be brought to the top, no further.
    const last_line: f32 = @floatFromInt(state.lines.* - 1);
    const furthest = last_line * line_height;
    const wanted = if (direction == .next) row.scroll_y.* + page else row.scroll_y.* - page;
    const scroll = std.math.clamp(wanted, 0, furthest);
    row.scroll_y.* = scroll;

    // The lines wholly in sight.
    const first_shown = @ceil(scroll / line_height);
    const last_shown = @max(@floor((scroll + text_height) / line_height) - 1, first_shown);
    const caret_line: f32 = @floatFromInt(state.caret_line.*);
    if (caret_line >= first_shown and caret_line <= last_shown) return;
    const target = if (caret_line < first_shown) first_shown else @min(last_shown, last_line);
    text_editor.request(tables.memory, tables, .{ .set_caret = .{ .buffer = row.buffer.*, .line = @intFromFloat(target), .column = 0, .select = .motion } });
}

/// Sets the settings' keymap, in the singleton's one row.
fn writeKeymap(settings: *Table, keymap: shared.Keymap) !void {
    if (!settings.isSingleton() or !settings.isAllocated(0)) return error.NoSettingsRow;
    const row: Table.RowHandle = .{ .row = 0, .generation = settings.rowGeneration(0) };
    try settings.writeFieldSingle(Atom, row, "text_keymap", shared.keymapAtom(keymap));
}

/// Switches the keymap for this session: what a person wants at every start, their plugin
/// sets (`shared.settings_table`).
fn toggleKeymap(tables: *Table.Registry) void {
    const found = tables.findByName(shared.settings_table) orelse {
        Log.warn("editor_settings_unavailable", .{});
        return;
    };
    const next: shared.Keymap = if (shared.keymapInUse(tables) == .emacs) .cua else .emacs;
    writeKeymap(found, next) catch |err| {
        Log.err("editor_settings_row_failed", .{ .@"error" = @errorName(err) });
    };
}

/// Where a line search's entry leads.
const MatchPlace = extern struct { line: u32, column: u32 };

/// The most lines a search lists.
const max_matching_lines = 64;
/// The most of a line a search's entry shows.
const max_match_label_bytes = 160;

/// Lists, in the open prompt, the lines of `buffer` that have `needle`, each leading to
/// where it has it.
fn presentMatchingLines(tables: *Table.Registry, buffer: Atom, needle: []const u8) void {
    const memory = tables.memory;
    const view = text_editor.viewOf(tables, buffer) orelse return;
    // The arena is not reset: the prompt may still read the entries it shows.
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    const entries = allocator.alloc(action_palette.Completion, max_matching_lines) catch return;
    var count: usize = 0;
    var position: u32 = 0;
    while (count < max_matching_lines) {
        const found = view.find(needle, position) orelse break;
        const line = view.lineOf(found);
        const line_start = view.lineStart(line);
        const line_end = view.lineEnd(line);
        const shown_len = @min(line_end - line_start, max_match_label_bytes);
        const label = allocator.alloc(u8, shown_len) catch return;
        const shown = view.copyRange(line_start, label);
        const number = std.fmt.allocPrint(allocator, "{d}", .{line + 1}) catch return;
        const place: MatchPlace = .{ .line = line, .column = view.columnOf(found, tab_width) };
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        @memcpy(data[0..@sizeOf(MatchPlace)], std.mem.asBytes(&place));
        entries[count] = .{ .key = number, .label = std.mem.trimStart(u8, shown, " \t"), .data = data };
        count += 1;
        // One entry a line: the search goes on from the next.
        position = line_end + 1;
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .title = "Search lines",
        .initial_query = needle,
        // The text is what the lines are searched for, not a line.
        .tab = .nothing,
        .entries = entries[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
}

/// The buffers a person switches to, a row each of the text editor's list: a file's, and
/// one with a name. A field's buffer has neither.
const BufferEntry = text_editor.BufferEntry;

/// What a buffer is called where it is chosen: its file's path, else its name. Empty for a
/// buffer nobody switches to.
fn bufferLabel(entry: Table.ReadView(BufferEntry)) []const u8 {
    return if (entry.path.len != 0) entry.path else entry.name;
}

/// Which buffers the switch-buffer prompt offers: every one a person switches to, or those
/// whose file lies under the working directory, the project's.
const BufferScope = enum(u8) { all, project };

/// What the list of buffers is asked for.
const BufferPurpose = enum {
    /// To show one: the buffer shown now is offered last, so the one before it comes first.
    switch_to,
    /// To kill one: the buffer shown now is offered first. Sketches, which close with their
    /// figures, are not offered.
    kill,
};

/// The buffer the focused view shows: a text window's buffer, or the figure the figure stage
/// shows while one of the figure editor's panels has the focus; null for any other view.
fn currentBuffer(tables: *Table.Registry, atoms: *Atom.Registry) ?buffer_list.Chosen {
    const focused = state_mod.viewFocus(tables, atoms).id.*;
    if (isPanel(focused)) {
        const table = panelsTable(tables) orelse return null;
        const found = rowOfPanel(table, focused) orelse return null;
        return .{ .kind = .text, .id = found.row.buffer.* };
    }
    const figure_shown = figure_workspace.isFigureView(focused) and figure_workspace.stageShown(tables);
    if (!figure_shown) return null;
    const doc = figure_workspace.session.get(tables).doc.*;
    if (doc == no_atom) return null;
    return .{ .kind = .figure, .id = doc };
}

/// Asks, in the palette, which buffer to show or kill (`purpose`): every buffer of `scope`
/// whose label holds `query`, in either case, the latest visited first (`buffer_list`). A
/// text buffer's file is labelled by `open_mod.shown`, a figure or a sketch by its name and
/// its kind beside it. `prompt` says whether the prompt opens or is open and has new text to
/// narrow by. The entry chosen carries a `buffer_list.Chosen` in its data.
fn presentBuffers(tables: *Table.Registry, atoms: *Atom.Registry, working_directory: []const u8, query: []const u8, prompt: EncodingPrompt, scope: BufferScope, purpose: BufferPurpose) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (prompt == .open) action_palette.resetCompletionArena(memory, .text_panel);
    const entries = buffer_list.collect(allocator, tables, atoms) catch return;
    const current = currentBuffer(tables, atoms);
    const listed = allocator.alloc(action_palette.Completion, entries.len) catch return;
    var count: usize = 0;
    var shown_now: ?action_palette.Completion = null;
    for (entries) |entry| {
        if (purpose == .kill and entry.kind == .sketch) continue;
        const in_scope = switch (scope) {
            .all => true,
            .project => entry.path.len != 0 and open_mod.partUnder(entry.path, working_directory) != null,
        };
        if (!in_scope) continue;
        const text_file = entry.kind == .text and entry.path.len != 0;
        const label = if (text_file) open_mod.shown(entry.path, working_directory) else entry.name;
        if (std.ascii.indexOfIgnoreCase(label, query) == null) continue;
        const detail: []const u8 = switch (entry.kind) {
            .text => "",
            .figure => if (entry.modified) "Figure, modified" else "Figure",
            .sketch => if (entry.modified) "Sketch, modified" else "Sketch",
        };
        const chosen: buffer_list.Chosen = .{ .kind = entry.kind, .id = entry.id };
        const completion: action_palette.Completion = .{ .label = label, .detail = detail, .data = chosen.encode() };
        const is_current = if (current) |shown| shown.kind == chosen.kind and shown.id == chosen.id else false;
        if (is_current and purpose == .switch_to) {
            shown_now = completion;
            continue;
        }
        listed[count] = completion;
        count += 1;
    }
    if (shown_now) |completion| {
        listed[count] = completion;
        count += 1;
    }
    const title = switch (purpose) {
        .kill => "Kill buffer",
        .switch_to => if (scope == .project) "Switch to the project's buffer" else "Switch to buffer",
    };
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .title = title,
        .initial_query = query,
        .entries = listed[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    if (prompt == .narrow) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
        return;
    }
    const answer: Msg = if (purpose == .kill) .text_panel_kill else .text_panel_switch;
    const scope_byte: u8 = @intFromEnum(scope);
    const reply = sequencer.ReplyTo.of(system(), .from(answer)).with(.of(&scope_byte));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// Asks, in the palette, which of the files opened lately to open: those whose path holds
/// `query`, in either case, the latest first, each labelled by `open_mod.shown` and its path
/// the entry's key.
fn presentRecentFiles(tables: *Table.Registry, working_directory: []const u8, query: []const u8, prompt: EncodingPrompt) void {
    const memory = tables.memory;
    const recent = tables.findByName(Atom.from(text_editor.recent_table_name)) orelse return;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (prompt == .open) action_palette.resetCompletionArena(memory, .text_panel);
    const listed = allocator.alloc(action_palette.Completion, text_editor.max_recent_files) catch return;
    var count: usize = 0;
    var rows = recent.readQuery(text_editor.RecentRow);
    while (rows.next()) |found| {
        if (count == listed.len) break;
        const path = found.view.path;
        if (std.ascii.indexOfIgnoreCase(path, query) == null) continue;
        listed[count] = .{ .key = path, .label = open_mod.shown(path, working_directory) };
        count += 1;
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .title = "Open a recent file",
        .initial_query = query,
        .entries = listed[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    if (prompt == .narrow) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
        return;
    }
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_recent));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

/// A buffer to show in a window whose own has closed: one a person switches to that no
/// window shows, a file's or `*scratch*` before `*Messages*`.
fn hiddenBuffer(tables: *Table.Registry, table: *Table) ?Atom {
    const entries = tables.findByName(Atom.from(text_editor.buffers_table_name)) orelse return null;
    var messages_hidden = false;
    var rows = entries.readQuery(BufferEntry);
    while (rows.next()) |found| {
        if (bufferLabel(found.view).len == 0) continue;
        const buffer = found.view.buffer.*;
        if (rowOfBuffer(table, buffer) != null) continue;
        if (buffer != text_editor.messages_buffer) return buffer;
        messages_hidden = true;
    }
    return if (messages_hidden) text_editor.messages_buffer else null;
}

/// A message's payload that leads with a `T` and carries bytes after it.
pub fn headOf(comptime T: type, received: sequencer.Message) !struct { value: *const T, trailing: []const u8 } {
    if (received.payload.len < @sizeOf(T)) return error.MessageShape;
    const head: sequencer.Message = .{ .tag = received.tag, .payload = received.payload[0..@sizeOf(T)] };
    return .{ .value = try head.payloadAs(T), .trailing = received.payload[@sizeOf(T)..] };
}

fn navigationRow(tables: *Table.Registry) ?NavigationRow {
    const found = tables.findByName(navigation_table) orelse return null;
    return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, NavigationRow);
}

/// Opens `path` and puts the caret at `line` and byte `column` once it has.
fn navigate(tables: *Table.Registry, path: []const u8, line: u32, column: u32) void {
    const navigation = navigationRow(tables) orelse return;
    navigation.pending.* = 1;
    navigation.line.* = line;
    navigation.column.* = column;
    openPath(tables, path);
}

/// Puts the caret of the buffer just opened where the navigation waiting for it says.
fn finishNavigation(tables: *Table.Registry, buffer: Atom) void {
    const navigation = navigationRow(tables) orelse return;
    if (navigation.pending.* == 0) return;
    navigation.pending.* = 0;
    placeCaret(tables, buffer, navigation.line.*, navigation.column.*);
}

/// Puts `buffer`'s caret at `line` and byte `column`, or as near as the text has.
fn placeCaret(tables: *Table.Registry, buffer: Atom, line: u32, column: u32) void {
    const view = text_editor.viewOf(tables, buffer) orelse return;
    const last_line = view.lineCount() - 1;
    const target_line = @min(line, last_line);
    const start = view.lineStart(target_line);
    const offset = start + @min(column, view.lineEnd(target_line) - start);
    const cell = view.columnOf(offset, tab_width);
    text_editor.request(tables.memory, tables, .{ .set_caret = .{ .buffer = buffer, .line = target_line, .column = cell, .select = .move } });
}

/// Keeps where `buffer`'s caret is, for `text_go_back`. The oldest goes when the list is full.
fn pushJump(tables: *Table.Registry, buffer: Atom) void {
    const jumps = tables.findByName(jumps_table) orelse return;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const view = text_editor.viewOf(tables, buffer) orelse return;
    if (state.path.len == 0) return;
    var latest: u32 = 0;
    var oldest: ?struct { handle: Table.RowHandle, order: u32 } = null;
    var rows = jumps.query(JumpRow);
    while (rows.next()) |found| {
        const order = found.view.order.*;
        latest = @max(latest, order);
        if (oldest == null or order < oldest.?.order) oldest = .{ .handle = found.handle, .order = order };
    }
    if (jumps.count() == max_jumps) jumps.free(oldest.?.handle);
    const line = state.caret_line.*;
    const column: u32 = @intCast(state.caret.* - view.lineStart(line));
    _ = jumps.tryInsert(.{ .order = latest + 1, .path = state.path, .line = line, .column = column }) catch |err| {
        Log.err("text_panel_jump_failed", .{ .@"error" = @errorName(err) });
    };
}

/// Returns to the latest place kept, and forgets it.
fn popJump(tables: *Table.Registry) void {
    const jumps = tables.findByName(jumps_table) orelse return;
    var latest: ?struct { handle: Table.RowHandle, row: JumpRow } = null;
    var rows = jumps.query(JumpRow);
    while (rows.next()) |found| {
        if (latest == null or found.view.order.* > latest.?.row.order.*) latest = .{ .handle = found.handle, .row = found.view };
    }
    const place = latest orelse return;
    // The path is the table's: open it before the row goes.
    navigate(tables, place.row.path, place.row.line.*, place.row.column.*);
    jumps.free(place.handle);
}

const Direction = enum { next, previous };

/// Moves `buffer`'s caret to the start of the diagnostic after it, or before it, wrapping
/// around the file.
fn moveToDiagnostic(tables: *Table.Registry, buffer: Atom, direction: Direction) void {
    const server_view = lsp.viewOf(tables, buffer) orelse return;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const view = text_editor.viewOf(tables, buffer) orelse return;
    if (server_view.diagnostics.len == 0) return;
    const line = state.caret_line.*;
    const caret_key = placeKey(line, @intCast(state.caret.* - view.lineStart(line)));
    var nearest: ?lsp.Diagnostic = null;
    var wrapped: lsp.Diagnostic = server_view.diagnostics[0];
    for (server_view.diagnostics) |diagnostic| {
        const key = placeKey(diagnostic.start_line, diagnostic.start_column);
        const wrapped_key = placeKey(wrapped.start_line, wrapped.start_column);
        switch (direction) {
            .next => {
                if (key < wrapped_key) wrapped = diagnostic;
                const beyond = key > caret_key;
                if (beyond and (nearest == null or key < placeKey(nearest.?.start_line, nearest.?.start_column))) nearest = diagnostic;
            },
            .previous => {
                if (key > wrapped_key) wrapped = diagnostic;
                const before = key < caret_key;
                if (before and (nearest == null or key > placeKey(nearest.?.start_line, nearest.?.start_column))) nearest = diagnostic;
            },
        }
    }
    const chosen = nearest orelse wrapped;
    placeCaret(tables, buffer, chosen.start_line, chosen.start_column);
}

fn placeKey(line: u32, column: u32) u64 {
    return (@as(u64, line) << 32) | column;
}

/// Opens the file at `path` in a text panel, or shows the panel that already holds it.
pub fn openPath(tables: *Table.Registry, path: []const u8) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_opened));
    text_editor.request(tables.memory, tables, .{ .open = .{ .path = path, .reply = reply } });
}

/// Where the caret goes in a file opened by `openAt`: a line, and a byte on it.
const OpenPlace = extern struct { line: u32, column: u32 };

/// Opens the file at `path` and puts the caret on `line`, `column` bytes along it, both
/// counted from zero: where a search's match or a compile's error is. Callable from any
/// system that may ask the text editor.
pub fn openAt(tables: *Table.Registry, path: []const u8, line: u32, column: u32) void {
    const place: OpenPlace = .{ .line = line, .column = column };
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_opened)).with(.of(&place));
    text_editor.request(tables.memory, tables, .{ .open = .{ .path = path, .reply = reply } });
}

fn requestSave(tables: *Table.Registry, buffer: Atom) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_saved));
    text_editor.request(tables.memory, tables, .{ .save = .{ .buffer = buffer, .path = "", .reply = reply } });
}

/// Asks the platform's picker where to save `buffer`, starting at the file it holds.
fn askSavePath(tables: *Table.Registry, buffer: Atom) void {
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_save_path)).with(.of(&buffer));
    os.request(tables.memory, tables, .{ .save_file_dialog = .{ .reply = reply, .suggested = state.path } });
}

/// A save's answer: a buffer with no file asks where to save, a failure is said in the
/// header, and a panel that waited for the save to close closes.
fn onSaved(tables: *Table.Registry, row: PanelRow, result: text_editor.SaveResult) void {
    switch (result) {
        .saved => {
            row.notice.* = @intFromEnum(Notice.none);
            if (row.closing.* != 0) text_editor.request(tables.memory, tables, .{ .close = row.buffer.* });
        },
        .no_path => askSavePath(tables, row.buffer.*),
        .convert_failed => {
            row.notice.* = @intFromEnum(Notice.cannot_encode);
            row.closing.* = 0;
        },
        .write_failed, .out_of_memory, .not_open => {
            row.notice.* = @intFromEnum(Notice.save_failed);
            row.closing.* = 0;
        },
    }
}

const CloseChoice = enum(u8) { save, discard, cancel };

/// Closes `buffer`; a modified file's asks first. A panel that showed it then shows another
/// buffer, or closes when no other is hidden (`followBuffers`).
fn killBuffer(tables: *Table.Registry, buffer: Atom) void {
    const state = text_editor.rowOf(tables, buffer) orelse return;
    // Only a file's changes are asked about: a buffer that holds none, as `*scratch*`, goes
    // as it is, as Emacs kills one.
    if (state.modified.* == 0 or state.path.len == 0) {
        text_editor.request(tables.memory, tables, .{ .close = buffer });
        return;
    }
    const name = bufferTitle(state);
    const choices = [_]Choice{
        .{ .label = "Save", .data = @intFromEnum(CloseChoice.save) },
        .{ .label = "Close without saving", .data = @intFromEnum(CloseChoice.discard) },
        .{ .label = "Cancel", .data = @intFromEnum(CloseChoice.cancel) },
    };
    present(tables, .{ .presentation = .dialog, .title = "Save changes?", .body = name, .default_entry = 0, .entries = &.{} }, &choices, .text_panel_close_choice, buffer);
}

/// A completion the panels offer: what it says and the byte that tells which it is.
const Choice = struct { label: []const u8, data: u8 = 0 };

/// Presents `completions` with `choices` as its entries; the answer comes back under
/// `answer` with `buffer` as its user data.
fn present(tables: *Table.Registry, completions: action_palette.Completions, choices: []const Choice, answer: Msg, buffer: Atom) void {
    const memory = tables.memory;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    action_palette.resetCompletionArena(memory, .text_panel);
    const kept = allocator.create(action_palette.Completions) catch return;
    const entries = allocator.alloc(action_palette.Completion, choices.len) catch return;
    for (choices, entries) |choice, *entry| {
        var data = std.mem.zeroes([action_palette.kCompletionDataSize]u8);
        data[0] = choice.data;
        entry.* = .{ .label = choice.label, .data = data };
    }
    kept.* = completions;
    kept.owner = prompt_owner;
    kept.entries = entries;
    action_palette.ownRequestText(allocator, kept) catch return;
    const reply = sequencer.ReplyTo.of(system(), .from(answer)).with(.of(&buffer));
    action_palette.request(memory, tables, .{ .present = .{ .completions = kept, .reply = reply } });
}

/// Says, in a dialog, why a file did not open.
fn presentOpenFailure(tables: *Table.Registry, result: text_editor.OpenResult) void {
    const reason = switch (result) {
        .opened, .already_open => return,
        .not_found => "There is no file at that path.",
        .too_large => "The file is too large to open.",
        .binary => "The file is not text.",
        .read_failed => "The file could not be read.",
        .convert_failed => "The file is not text in an encoding this platform reads.",
        .too_many_buffers => "Too many files are open.",
        .out_of_memory => "There is not enough memory to open the file.",
    };
    const choices = [_]Choice{.{ .label = "OK" }};
    present(tables, .{ .presentation = .dialog, .title = "Could not open the file", .body = reason, .entries = &.{} }, &choices, .text_panel_open_failure_seen, no_atom);
}

/// What an encoding is chosen for: the one the buffer is saved in from now on, as Emacs's
/// `set-buffer-file-coding-system`, or the one its file is read again in, as
/// `revert-buffer-with-coding-system`.
const EncodingPurpose = enum { save, revert };

/// Whether the encodings' prompt opens, or is open and has new text to narrow by.
const EncodingPrompt = enum { open, narrow };

/// The titles of the encodings' prompts, by which an answer that comes while one is open
/// finds it.
const save_encoding_title = "Save in encoding";
const revert_encoding_title = "Read the file again in encoding";

/// An encoding as Emacs names a coding system: the encoding, and the line endings a
/// `-unix`, `-dos` or `-mac` after it asks for.
const CodingSystem = struct { encoding: []const u8, line_ending: ?text_editor.LineEnding = null };

/// What the host has said of an encoding.
const EncodingSupport = enum { unknown, supported, unsupported };

/// What the answers kept say of the encoding `name`. UTF-8 is a buffer's own, never asked; a
/// name no encoding can have (`encoding.isEncodingName`) is not converted, never asked either.
fn encodingSupport(kept: *Table, name: []const u8) EncodingSupport {
    if (text_editor.encoding.isUtf8(name)) return .supported;
    if (!text_editor.encoding.isEncodingName(name)) return .unsupported;
    var rows = kept.readQuery(EncodingRow);
    while (rows.next()) |found| {
        if (!std.ascii.eqlIgnoreCase(found.view.name, name)) continue;
        return if (found.view.supported.* != 0) .supported else .unsupported;
    }
    return .unknown;
}

/// Keeps the host's answer about the known encodings, in their order, in place of any before.
fn keepKnownEncodings(kept: *Table, trailing: []const u8) void {
    kept.clear();
    var answers: text_editor.EncodingAnswers = .{ .remaining = trailing };
    while (answers.next()) |answer| {
        const supported: u8 = @intFromBool(answer.supported);
        _ = kept.tryInsert(.{ .name = answer.name, .supported = supported, .typed = @as(u8, 0) }) catch |err| {
            Log.err("text_panel_encodings_unkept", .{ .@"error" = @errorName(err) });
            return;
        };
    }
}

/// Keeps the host's answer about a name typed; false when it could not be kept.
fn keepTypedEncoding(kept: *Table, answer: text_editor.EncodingAnswer) bool {
    const supported: u8 = @intFromBool(answer.supported);
    var rows = kept.query(EncodingRow);
    while (rows.next()) |found| {
        if (!std.ascii.eqlIgnoreCase(found.view.name, answer.name)) continue;
        found.view.supported.* = supported;
        return true;
    }
    if (kept.count() >= max_encoding_answers) {
        // Freed once the walk is done: a row is not freed under the query reading it.
        var typed_rows: [max_typed_encodings]Table.RowHandle = undefined;
        var typed_count: usize = 0;
        var all_rows = kept.readQuery(EncodingRow);
        while (all_rows.next()) |found| {
            if (found.view.typed.* == 0 or typed_count == typed_rows.len) continue;
            typed_rows[typed_count] = found.handle;
            typed_count += 1;
        }
        for (typed_rows[0..typed_count]) |typed_row| kept.free(typed_row);
    }
    _ = kept.tryInsert(.{ .name = answer.name, .supported = supported, .typed = @as(u8, 1) }) catch |err| {
        Log.err("text_panel_encodings_unkept", .{ .@"error" = @errorName(err) });
        return false;
    };
    return true;
}

/// Why a name typed was asked about, the ask's user data: to offer it in the open prompt, or
/// to save or read the file again in it once the host says it converts it.
const EncodingUse = enum(u8) { offer, save, revert };
const EncodingAsk = extern struct {
    buffer: Atom,
    /// An `EncodingUse`.
    use: u8,
    /// One more than the `LineEnding` a coding system's suffix asked for; 0 for none.
    line_ending: u8 = 0,
    /// Zero, so the user data's bytes are all the sender's.
    padding: [6]u8 = @splat(0),
};

fn lineEndingOf(stored: u8) ?text_editor.LineEnding {
    if (stored == 0) return null;
    return std.enums.fromInt(text_editor.LineEnding, stored - 1);
}

/// Asks the host whether it converts the encoding `name`, answered under
/// `text_panel_encodings` next frame.
fn askEncoding(tables: *Table.Registry, name: []const u8, ask: EncodingAsk) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_encodings)).with(.of(&ask));
    text_editor.request(tables.memory, tables, .{ .supported_encodings = .{ .name = name, .reply = reply } });
}

/// Asks the host which of the known encodings it converts, answered under
/// `text_panel_encodings`: when an encodings' prompt opens with no answer kept, so a session
/// that never opens one asks nothing. Until the answer is in, the prompts offer UTF-8 alone.
fn askEncodings(tables: *Table.Registry) void {
    const reply = sequencer.ReplyTo.of(system(), .from(Msg.text_panel_encodings));
    text_editor.request(tables.memory, tables, .{ .supported_encodings = .{ .name = "", .reply = reply } });
}

/// `name` as a coding system. A name the host converts whole is an encoding's, whatever it
/// ends in.
fn codingSystemOf(kept: *Table, name: []const u8) CodingSystem {
    if (encodingSupport(kept, name) == .supported) return .{ .encoding = name };
    const endings = [_]struct { suffix: []const u8, ending: text_editor.LineEnding }{
        .{ .suffix = "-unix", .ending = .lf },
        .{ .suffix = "-dos", .ending = .crlf },
        .{ .suffix = "-mac", .ending = .cr },
    };
    for (endings) |candidate| {
        if (!std.ascii.endsWithIgnoreCase(name, candidate.suffix)) continue;
        return .{ .encoding = name[0 .. name.len - candidate.suffix.len], .line_ending = candidate.ending };
    }
    return .{ .encoding = name };
}

/// What a prompt's answer chose: an entry's label, or with none offered the text typed.
fn chosenEncoding(chosen: action_palette.Completion, query: []const u8) []const u8 {
    if (chosen.label.len != 0) return chosen.label;
    return std.mem.trim(u8, query, " ");
}

/// Saves `buffer` in the encoding `name` from now on, or reads its file again in it: at once
/// when the host is known to convert it, after it is asked when not yet known.
fn chooseEncoding(tables: *Table.Registry, buffer: Atom, purpose: EncodingPurpose, name: []const u8) void {
    if (name.len == 0) return;
    const kept = tables.findByName(encodings_table) orelse return;
    const coding: CodingSystem = if (purpose == .save) codingSystemOf(kept, name) else .{ .encoding = name };
    switch (encodingSupport(kept, coding.encoding)) {
        .supported => useEncoding(tables, buffer, purpose, coding),
        .unsupported => refuseEncoding(tables, purpose, coding.encoding),
        .unknown => {
            const use: EncodingUse = if (purpose == .save) .save else .revert;
            const line_ending: u8 = if (coding.line_ending) |ending| @intFromEnum(ending) + 1 else 0;
            askEncoding(tables, coding.encoding, .{ .buffer = buffer, .use = @intFromEnum(use), .line_ending = line_ending });
        },
    }
}

/// Asks the text editor for the encoding chosen, which the host converts.
fn useEncoding(tables: *Table.Registry, buffer: Atom, purpose: EncodingPurpose, coding: CodingSystem) void {
    const memory = tables.memory;
    if (purpose == .revert) {
        text_editor.request(memory, tables, .{ .revert = .{ .buffer = buffer, .encoding = coding.encoding } });
        return;
    }
    text_editor.request(memory, tables, .{ .set_encoding = .{ .buffer = buffer, .encoding = coding.encoding } });
    // As Emacs's `utf-8-dos` does: the line endings the name asks for, on every line.
    if (coding.line_ending) |ending| {
        text_editor.request(memory, tables, .{ .set_line_ending = .{ .buffer = buffer, .ending = ending, .existing = .convert } });
    }
}

/// Tells the person the host does not convert the encoding `name`, or that no encoding has
/// such a name.
fn refuseEncoding(tables: *Table.Registry, purpose: EncodingPurpose, name: []const u8) void {
    if (!text_editor.encoding.isEncodingName(name)) {
        const sentence = std.fmt.comptimePrint("Not an encoding's name: one has at most {d} bytes and no control characters", .{text_editor.max_encoding_name});
        return text_editor.message(tables.memory, tables, sentence);
    }
    var told_buffer: [160]u8 = undefined;
    const told = switch (purpose) {
        .save => std.fmt.bufPrint(&told_buffer, "The file's encoding is not changed to {s}: this platform does not convert it", .{name}),
        .revert => std.fmt.bufPrint(&told_buffer, "Not read again as {s}: this platform does not convert it", .{name}),
    } catch "This platform does not convert that encoding";
    text_editor.message(tables.memory, tables, told);
}

/// Offers the encodings again in the open prompt, when it is one of the encodings' prompts,
/// now that an answer is kept: with the text typed in it.
fn refreshEncodingPrompt(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const shown = action_palette.currentCompletions(tables, atoms) orelse return;
    if (shown.owner != prompt_owner) return;
    const purpose: EncodingPurpose = if (std.mem.eql(u8, shown.title, save_encoding_title))
        .save
    else if (std.mem.eql(u8, shown.title, revert_encoding_title))
        .revert
    else
        return;
    const query = action_palette.promptText(tables, atoms);
    presentEncodings(tables, no_atom, purpose, query, .narrow);
}

/// Offers the encodings the host converts whose names hold `query`, for `buffer`; UTF-8
/// alone until the host has said which. A name typed that is none of them is offered as
/// typed when the host converts it, and asked about when it has not said: iconv knows
/// encodings by many names. For saving, such a name may end as Emacs's coding systems do.
/// With nothing offered the prompt still takes the text typed (`chooseEncoding`).
fn presentEncodings(tables: *Table.Registry, buffer: Atom, purpose: EncodingPurpose, query: []const u8, prompt: EncodingPrompt) void {
    const memory = tables.memory;
    const kept = tables.findByName(encodings_table) orelse return;
    const allocator = action_palette.completionAllocator(memory, .text_panel) catch return;
    // While narrowing the arena is not reset: the prompt may still read the entries it shows.
    if (prompt == .open) action_palette.resetCompletionArena(memory, .text_panel);
    const typed = std.mem.trim(u8, query, " ");
    const entries = allocator.alloc(action_palette.Completion, text_editor.known_encodings.len + 1) catch return;
    var count: usize = 0;
    var known_answered = false;
    var rows = kept.readQuery(EncodingRow);
    while (rows.next()) |found| {
        if (found.view.typed.* != 0) continue;
        known_answered = true;
        if (found.view.supported.* == 0) continue;
        if (std.ascii.indexOfIgnoreCase(found.view.name, typed) == null) continue;
        entries[count] = .{ .label = found.view.name };
        count += 1;
    }
    if (!known_answered and prompt == .open) askEncodings(tables);
    const utf8_name = text_editor.encoding.utf8_name;
    if (!known_answered and std.ascii.indexOfIgnoreCase(utf8_name, typed) != null) {
        entries[0] = .{ .label = utf8_name };
        count = 1;
    }
    if (count == 0 and typed.len != 0) {
        const named = if (purpose == .save) codingSystemOf(kept, typed).encoding else typed;
        switch (encodingSupport(kept, named)) {
            .supported => {
                entries[0] = .{ .label = typed };
                count = 1;
            },
            .unsupported => {},
            .unknown => askEncoding(tables, named, .{ .buffer = buffer, .use = @intFromEnum(EncodingUse.offer) }),
        }
    }
    const completions = allocator.create(action_palette.Completions) catch return;
    completions.* = .{
        .owner = prompt_owner,
        .presentation = .prompt,
        .title = if (purpose == .save) save_encoding_title else revert_encoding_title,
        .initial_query = query,
        .accepts_text = true,
        .entries = entries[0..count],
    };
    action_palette.ownRequestText(allocator, completions) catch return;
    if (prompt == .narrow) {
        action_palette.request(memory, tables, .{ .replace = .{ .completions = completions } });
        return;
    }
    const answer: Msg = if (purpose == .save) .text_panel_encoding else .text_panel_revert_encoding;
    const reply = sequencer.ReplyTo.of(system(), .from(answer)).with(.of(&buffer));
    action_palette.request(memory, tables, .{ .present = .{ .completions = completions, .reply = reply } });
}

fn presentLineEndings(tables: *Table.Registry, buffer: Atom) void {
    const choices = [_]Choice{
        .{ .label = "LF (Unix)", .data = @intFromEnum(text_editor.LineEnding.lf) },
        .{ .label = "CRLF (Windows)", .data = @intFromEnum(text_editor.LineEnding.crlf) },
        .{ .label = "CR (classic Mac)", .data = @intFromEnum(text_editor.LineEnding.cr) },
    };
    present(tables, .{ .presentation = .prompt, .title = "Convert line endings to", .tab = .nothing, .entries = &.{} }, &choices, .text_panel_line_ending, buffer);
}

// ---- the pointer ----------------------------------------------------------------------------

/// The line and cell of the text under a point in the window, in `row`'s panel.
fn cellAt(row: PanelRow, content: panels_mod.Rect, x: f32, y: f32) struct { line: u32, column: u32 } {
    const text_x = x - content.x - padding + row.scroll_x.*;
    const text_y = y - content.y - padding + row.scroll_y.*;
    const line = @floor(@max(text_y, 0) / row.line_height.*);
    // The caret goes between cells: to the nearer side of the one under the pointer.
    const column = @round(@max(text_x, 0) / row.cell_width.*);
    return .{ .line = @intFromFloat(line), .column = @intFromFloat(column) };
}

/// The open panel whose content holds the point.
fn panelAt(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table, x: f32, y: f32) ?struct { row: PanelRow, content: panels_mod.Rect } {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        const content = panel_frame.contentRect(tables, atoms, found.view.panel.*) orelse continue;
        if (content.contains(x, y)) return .{ .row = found.view, .content = content };
    }
    return null;
}

fn handlePointer(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table, received: sequencer.Message) !void {
    const memory = tables.memory;
    switch (received.tag.to(Msg)) {
        .text_panel_press => {
            if (action_palette.requestOpen(tables, atoms)) return;
            const pressed = try received.payloadAs(input.MouseButtonMsg);
            const hit = panelAt(tables, atoms, table, pressed.x, pressed.y) orelse return;
            const row = hit.row;
            if (row.line_height.* <= 0 or row.cell_width.* <= 0) return;
            const cell = cellAt(row, hit.content, pressed.x, pressed.y);
            const buffer = row.buffer.*;
            // The click places the caret itself: the window's kept point is not taken back.
            takePoint(tables, table, row, .keep);
            if (pressed.clicks >= 3) {
                text_editor.request(memory, tables, .{ .select_unit = .{ .buffer = buffer, .line = cell.line, .column = cell.column, .unit = .line } });
            } else if (pressed.clicks == 2) {
                text_editor.request(memory, tables, .{ .select_unit = .{ .buffer = buffer, .line = cell.line, .column = cell.column, .unit = .word } });
            } else {
                const select: text_editor.Select = if (pressed.modifiers.shift) .extend else .move;
                text_editor.request(memory, tables, .{ .set_caret = .{ .buffer = buffer, .line = cell.line, .column = cell.column, .select = select } });
                row.dragging.* = 1;
            }
        },
        .text_panel_move => {
            const moved = try received.payloadAs(input.MouseMoveMsg);
            var rows = table.query(PanelRow);
            while (rows.next()) |found| {
                const row = found.view;
                if (row.dragging.* == 0) continue;
                const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse continue;
                const cell = cellAt(row, content, moved.x, moved.y);
                text_editor.request(memory, tables, .{ .set_caret = .{ .buffer = row.buffer.*, .line = cell.line, .column = cell.column, .select = .extend } });
            }
        },
        .text_panel_release => {
            var rows = table.query(PanelRow);
            while (rows.next()) |found| found.view.dragging.* = 0;
        },
        .text_panel_scroll => {
            const scrolled = try received.payloadAs(input.MouseScrollMsg);
            const hit = panelAt(tables, atoms, table, scrolled.pointer_x, scrolled.pointer_y) orelse return;
            const row = hit.row;
            // Ctrl+wheel zooms: a step of size for each notch, up larger and down smaller.
            // `followMetrics` then takes the new size's cell and keeps the same line at the top.
            if (scrolled.modifiers.control) {
                const largest: u8 = text_sizes.len - 1;
                if (scrolled.y > 0 and row.text_size.* < largest) row.text_size.* += 1;
                if (scrolled.y < 0 and row.text_size.* > 0) row.text_size.* -= 1;
                return;
            }
            const state = text_editor.rowOf(tables, row.buffer.*) orelse return;
            // The last line can be brought to the top, no further.
            const last_line: f32 = @floatFromInt(state.lines.* - 1);
            const furthest = last_line * row.line_height.*;
            const wheel_lines: f32 = 3;
            const down = row.scroll_y.* - scrolled.y * wheel_lines * row.line_height.*;
            const right = row.scroll_x.* - scrolled.x * wheel_lines * row.cell_width.*;
            row.scroll_y.* = std.math.clamp(down, 0, furthest);
            row.scroll_x.* = @max(right, 0);
        },
        else => {},
    }
}

/// What a buffer is called in a header and a prompt: its file's name, else its own.
fn bufferTitle(state: Table.ReadView(text_editor.BufferRow)) []const u8 {
    if (state.path.len != 0) return std.fs.path.basename(state.path);
    return if (state.name.len != 0) state.name else "untitled";
}

/// Has `found`'s window show `buffer` in place of the one it showed, which stays open. What
/// the window knew of its buffer starts over: its scroll, what its header said, and the page
/// length the buffer was told.
fn retarget(table: *Table, found: anytype, buffer: Atom) void {
    const row = found.row;
    row.buffer.* = buffer;
    row.scroll_x.* = 0;
    row.scroll_y.* = 0;
    row.serial.* = 0;
    row.page_lines.* = 0;
    row.dragging.* = 0;
    row.closing.* = 0;
    row.notice.* = @intFromEnum(Notice.none);
    row.awaiting.* = @intFromEnum(Awaiting.none);
    row.lsp_serial.* = 0;
    // Its point was in the buffer it showed, and so was whatever was under way there.
    row.current.* = 0;
    row.has_point.* = 0;
    row.argument_state.* = @intFromEnum(Argument.none);
    row.search.* = @intFromEnum(Search.none);
    row.search_failing.* = 0;
    row.replace.* = @intFromEnum(Replace.none);
    row.history_shown.* = 0;
    row.jump.* = @intFromEnum(Jump.none);
    row.completing.* = @intFromEnum(Completing.none);
    if (row.info.len != 0) table.setString(found.handle, "info", "") catch |err| Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
}

/// A window's row as it is made: showing `buffer` from its start, with nothing under way.
fn insertRow(table: *Table, panel: Atom, buffer: Atom) !void {
    _ = try table.tryInsert(.{
        .panel = panel,
        .buffer = buffer,
        .shown = @as(u8, 0),
        .scroll_x = @as(f32, 0),
        .scroll_y = @as(f32, 0),
        .line_height = @as(f32, 0),
        .cell_width = @as(f32, 0),
        .serial = @as(u32, 0),
        .page_lines = @as(u32, 0),
        .open_beside = no_atom,
        .open_side = @intFromEnum(plugin.panels.Side.right),
        .open_focus = @intFromEnum(plugin.panels.FocusOnOpen.take),
        .dragging = @as(u8, 0),
        .closing = @as(u8, 0),
        .notice = @as(u8, 0),
        .awaiting = @as(u8, 0),
        .lsp_serial = @as(u32, 0),
        .info = @as([]const u8, ""),
        .typing = @as(u8, 0),
        .text_size = default_text_size,
        .recenter = @as(u8, 0),
        .argument_state = @intFromEnum(Argument.none),
        .argument = @as(u32, 0),
        .search = @intFromEnum(Search.none),
        .search_origin = @as(u32, 0),
        .search_failing = @as(u8, 0),
        .replace = @intFromEnum(Replace.none),
        .replace_start = @as(u32, 0),
        .replace_end = @as(u32, 0),
        .replace_count = @as(u32, 0),
        .replace_preview = @as(u32, 0),
        .current = @as(u8, 0),
        .has_point = @as(u8, 0),
        .history_shown = @as(u8, 0),
        .history_origin = @as(u32, 0),
        .jump = @intFromEnum(Jump.none),
        .jump_typed = @as(u8, 0),
        .jump_needle = @as(u64, 0),
        .jump_letter = @as(u8, 0),
        .completing = @intFromEnum(Completing.none),
        .completion_start = @as(u32, 0),
        .completion_selected = @as(u32, 0),
    });
}

/// A window no row has, or null when every one shows.
fn freePanel(table: *Table) ?Atom {
    for (panel_ids) |candidate| {
        if (rowOfPanel(table, candidate) == null) return candidate;
    }
    // The buffer stays open, to be switched to.
    Log.warn("text_panel_none_free", .{});
    return null;
}

/// A text window other than `focused`, for what is to show beside it.
fn otherWindow(table: *Table, focused: Atom) ?Atom {
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        if (found.view.panel.* != focused) return found.view.panel.*;
    }
    return null;
}

/// Shows `buffer` where the person asked: in the other window when the last `C-x 4` command
/// wished so (`NavigationRow.other_window`), which this takes, else in this one (`placeBuffer`).
fn showAsWished(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table, buffer: Atom) void {
    var place: Place = .this_window;
    if (navigationRow(tables)) |navigation| {
        if (navigation.other_window.* != 0) place = .other_window;
        navigation.other_window.* = 0;
    }
    _ = placeBuffer(tables, atoms, table, buffer, place);
}

/// Where `placeBuffer` put a buffer: the window, and what it showed before.
const Placed = struct {
    panel: Atom,
    /// What the window showed before; none for a window made for the buffer.
    previous: Atom,
    /// Whether the buffer was shown there already, the window only taking the focus.
    already: bool = false,
};

/// Shows `buffer`: in a window that already shows it, which takes the focus; else in the
/// focused window, in place of what it showed; else, with no text window focused, in a new
/// one beside the focused panel. In the `other_window`, it shows in a text window that is not
/// the focused one, which takes the focus, a new one when there is none. Returns where; null
/// when no window could be had.
fn placeBuffer(tables: *Table.Registry, atoms: *Atom.Registry, table: *Table, buffer: Atom, place: Place) ?Placed {
    const in_other_window = place == .other_window;
    if (rowOfBuffer(table, buffer)) |existing| {
        const panel = existing.panel.*;
        plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = panel } });
        return .{ .panel = panel, .previous = no_atom, .already = true };
    }
    // The editor's own record of the focused view, which the prompt that asked did not take.
    const focused = state_mod.viewFocus(tables, atoms).id.*;
    const target = if (in_other_window) otherWindow(table, focused) else if (isPanel(focused)) focused else null;
    if (target) |panel| {
        if (rowOfPanel(table, panel)) |found| {
            const previous = found.row.buffer.*;
            retarget(table, found, buffer);
            if (in_other_window) plugin.panels.request(tables.memory, tables, .{ .focus = .{ .id = panel } });
            return .{ .panel = panel, .previous = previous };
        }
    }
    const panel = freePanel(table) orelse return null;
    insertRow(table, panel, buffer) catch |err| {
        Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
        return null;
    };
    const made = rowOfPanel(table, panel) orelse return null;
    // The figure stage is a document's window as a text window is: the buffer takes its place.
    const stage = Atom.from(fixed_panels.figure_stage);
    if (focused == stage and !in_other_window) {
        fixed_panels.hidePanel(tables, stage);
        plugin.panels.request(tables.memory, tables, .{ .replace = .{ .id = stage, .by = panel } });
        return .{ .panel = panel, .previous = no_atom };
    }
    // Beside the focused panel, which asked for it, taking the focus as it opens.
    made.row.open_beside.* = fixed_panels.requester(tables, atoms);
    return .{ .panel = panel, .previous = no_atom };
}

/// Shows the buffer of `source`'s window in a second window to `side` of it, at the same
/// place, as Emacs's `C-x 2` and `C-x 3`. The focus stays where it was.
fn splitWindow(tables: *Table.Registry, table: *Table, source: PanelRow, side: plugin.panels.Side) void {
    const buffer = source.buffer.*;
    const state = text_editor.rowOf(tables, buffer) orelse return;
    const scroll_x = source.scroll_x.*;
    const scroll_y = source.scroll_y.*;
    const text_size = source.text_size.*;
    const source_panel = source.panel.*;
    const panel = freePanel(table) orelse return;
    insertRow(table, panel, buffer) catch |err| {
        Log.err("text_panel_row_failed", .{ .@"error" = @errorName(err) });
        return;
    };
    // The new window begins where this one is: its point the caret's place, kept as a marker.
    const made = rowOfPanel(table, panel) orelse return;
    made.row.scroll_x.* = scroll_x;
    made.row.scroll_y.* = scroll_y;
    made.row.text_size.* = text_size;
    made.row.has_point.* = 1;
    const caret: u32 = @intCast(state.caret.*);
    text_editor.request(tables.memory, tables, .{ .set_marker = .{ .buffer = buffer, .marker = slotOf(panel), .offset = caret } });
    made.row.open_beside.* = source_panel;
    made.row.open_side.* = @intFromEnum(side);
    made.row.open_focus.* = @intFromEnum(plugin.panels.FocusOnOpen.keep);
}

/// Whether a buffer is asked to show and not shown yet: the panels' run shows it once it is
/// open, or forgets it after `max_show_waits` runs.
fn showAsked(tables: *Table.Registry) bool {
    const requests = tables.findByName(show_requests_table) orelse return false;
    var rows = requests.readQuery(ShowRequestRow);
    while (rows.next()) |found| {
        if (found.view.shown.* == 0) return true;
    }
    return false;
}

/// Shows each buffer asked for that is open now, remembering where and what its window showed
/// before; forgets one that has waited `max_show_waits` runs, and its own mode, as its making
/// was refused; and forgets a buffer shown whose window shows another now, put there by the
/// person, or is gone.
fn takeShowRequests(pass: *sequencer.Pass, table: *Table) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const requests = try pass.writeTable(show_requests_table);
    var gone: [max_show_requests]Table.RowHandle = undefined;
    var gone_count: usize = 0;
    var rows = requests.query(ShowRequestRow);
    while (rows.next()) |found| {
        if (gone_count == gone.len) break;
        const request = found.view;
        const buffer = request.buffer.*;
        if (request.shown.* != 0) {
            const window = rowOfPanel(table, request.panel.*);
            const still = if (window) |kept| kept.row.buffer.* == buffer else false;
            if (still) continue;
            gone[gone_count] = found.handle;
            gone_count += 1;
            continue;
        }
        if (text_editor.tableOf(tables, buffer) == null) {
            request.waits.* +|= 1;
            if (request.waits.* < max_show_waits) continue;
            setBufferMode(tables, buffer, modes.buffer);
            gone[gone_count] = found.handle;
            gone_count += 1;
            continue;
        }
        const place = std.enums.fromInt(Place, request.place.*) orelse .this_window;
        const placed = placeBuffer(tables, frame.atoms, table, buffer, place);
        const kept = placed orelse Placed{ .panel = no_atom, .previous = no_atom, .already = true };
        if (kept.already) {
            gone[gone_count] = found.handle;
            gone_count += 1;
            continue;
        }
        request.shown.* = 1;
        request.panel.* = kept.panel;
        request.previous.* = kept.previous;
    }
    for (gone[0..gone_count]) |gone_row| requests.free(gone_row);
}

/// `closed`, a buffer `showBuffer` put in a window that still shows it, closed: the window shows
/// what it showed before while that is open, and gives the focus back to the panel that had it
/// before (`focus_previous`, from the window: nothing moves when the focus has left it), as the
/// system that showed the buffer is done with it; or the
/// window closes when it was made for the buffer, its closing giving the focus back of itself.
/// Every row of the buffer is let go; of those shown, the one whose window still shows it is
/// acted on. The others that showed it are left to `followBuffers`.
fn restoreShownWindow(pass: *sequencer.Pass, table: *Table, closed: Atom) !void {
    const tables = pass.frame.tables;
    const requests = try pass.writeTable(show_requests_table);
    var showing: ?Placed = null;
    var rows = requests.readQuery(ShowRequestRow);
    while (rows.next()) |found| {
        if (found.view.shown.* == 0 or found.view.buffer.* != closed) continue;
        const window = rowOfPanel(table, found.view.panel.*) orelse continue;
        if (window.row.buffer.* != closed) continue;
        showing = .{ .panel = found.view.panel.*, .previous = found.view.previous.*, .already = false };
    }
    forgetRequestsOf(requests, closed);
    const shown = showing orelse return;
    const window = rowOfPanel(table, shown.panel) orelse return;
    if (shown.previous == no_atom) {
        table.free(window.handle);
        return;
    }
    if (text_editor.tableOf(tables, shown.previous) == null) return;
    retarget(table, window, shown.previous);
    plugin.panels.request(pass.frame.memory, tables, .{ .focus_previous = .{ .from = shown.panel } });
}

/// Frees every row of `requests` of `buffer`, asked or shown.
fn forgetRequestsOf(requests: *Table, buffer: Atom) void {
    var gone: [max_show_requests]Table.RowHandle = undefined;
    var gone_count: usize = 0;
    var rows = requests.readQuery(ShowRequestRow);
    while (rows.next()) |found| {
        if (found.view.buffer.* != buffer or gone_count == gone.len) continue;
        gone[gone_count] = found.handle;
        gone_count += 1;
    }
    for (gone[0..gone_count]) |gone_row| requests.free(gone_row);
}

/// A buffer closed while no text window is open, whose `closed` event `followBuffers` reads and
/// passes by: its rows of `editor_text_show_requests` go with it, or a later request of a
/// buffer of the same name would find the stale one.
fn forgetClosedRequests(pass: *sequencer.Pass, taken: []const text_editor.Event) !void {
    for (taken) |event| {
        const closed = switch (event) {
            .closed => |closed| closed.buffer,
            else => continue,
        };
        const requests = try pass.writeTable(show_requests_table);
        forgetRequestsOf(requests, closed);
    }
}

/// A buffer closed takes its own mode with it (`setBufferMode`).
fn forgetClosedBufferModes(pass: *sequencer.Pass, taken: []const text_editor.Event) !void {
    for (taken) |event| {
        const closed = switch (event) {
            .closed => |closed| closed.buffer,
            else => continue,
        };
        const buffer_modes = try pass.writeTable(buffer_modes_table);
        var rows = buffer_modes.query(BufferModeRow);
        // A buffer has one row at most.
        while (rows.next()) |found| {
            if (found.view.buffer.* != closed) continue;
            buffer_modes.free(found.handle);
            break;
        }
    }
}

/// Each frame: hears of the buffers' changes, keeps each panel's caret in sight, tells each
/// buffer how long its panel's page is, shows the buffers `showBuffer` asked for, and has a
/// panel whose buffer closed show what it showed before that buffer, or another.
fn followBuffers(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const tables = frame.tables;
    const atoms = frame.atoms;
    var events: [shared.events_max]text_editor.Event = undefined;
    const taken = try shared.readEvents(pass, Atom.from(system().name), &events);
    try forgetClosedBufferModes(pass, taken);
    const observed = panelsTable(tables) orelse return;
    const asked = showAsked(tables);
    if (observed.count() == 0 and !asked) return forgetClosedRequests(pass, taken);

    const table = try pass.writeTable(panels_table);
    for (taken) |event| switch (event) {
        .changed => |change| {
            var showing = table.query(PanelRow);
            while (showing.next()) |found| {
                const row = found.view;
                if (row.buffer.* != change.buffer) continue;
                // A change to the text answers what the header said went wrong.
                if (row.serial.* != change.serial and change.modified) row.notice.* = @intFromEnum(Notice.none);
                // So does any change to what the header says a name is.
                if (row.serial.* != change.serial and row.info.len != 0) setInfo(table, row.panel.*, "");
                row.serial.* = change.serial;
                // The caret is the current window's: the others keep their own places.
                if (row.current.* != 0) keepCaretInSight(tables, atoms, row);
                if (row.current.* != 0) settleCompletion(tables, row);
            }
        },
        .closed => |closed| {
            try restoreShownWindow(pass, table, closed.buffer);
            // Each window that showed it stays, on a buffer no window shows, while there is one.
            while (rowOfBuffer(table, closed.buffer)) |row| {
                const found = rowOfPanel(table, row.panel.*) orelse break;
                if (hiddenBuffer(tables, table)) |next| {
                    retarget(table, found, next);
                    continue;
                }
                table.free(found.handle);
            }
        },
        // What a compile says shows in another window as soon as there is a buffer for it.
        .opened => |opened| {
            if (opened.buffer != compilation_buffer) continue;
            const focused_before = panels_mod.focusedTarget(tables, atoms).id;
            _ = placeBuffer(tables, atoms, table, opened.buffer, .other_window);
            // The window the compile was asked from keeps the keyboard.
            if (isPanel(focused_before)) plugin.panels.request(frame.memory, tables, .{ .focus = .{ .id = focused_before } });
        },
        .copied, .paste_wanted => {},
    };

    var lsp_events: [shared.events_max]lsp.Event = undefined;
    const told = try lsp.Events.of(tables, lsp.events_table_name).read(pass, Atom.from(system().name), &lsp_events);
    for (told) |event| switch (event) {
        .document_changed => |changed| {
            var showing = table.query(PanelRow);
            while (showing.next()) |found| {
                if (found.view.buffer.* == changed.buffer) found.view.lsp_serial.* = changed.serial;
            }
        },
        // The header tells the server's state: every panel on it draws again.
        .server_changed => |changed| {
            var on_server = table.query(PanelRow);
            while (on_server.next()) |found| {
                const document = lsp.documentOf(tables, found.view.buffer.*) orelse continue;
                if (document.server.* == changed.server) found.view.lsp_serial.* +%= 1;
            }
        },
    };

    try takeShowRequests(pass, table);
    settleWindows(tables, atoms, table);

    // A window shown that is no longer open was replaced, as the figure stage takes a
    // window's place: its row goes, so it is not declared and opened again.
    var dropped: [panel_ids.len]Table.RowHandle = undefined;
    var dropped_count: usize = 0;
    var rows = table.query(PanelRow);
    while (rows.next()) |found| {
        const row = found.view;
        if (!panels_mod.isOpen(tables, atoms, row.panel.*)) {
            const replaced = row.shown.* != 0;
            if (replaced and dropped_count < dropped.len) {
                dropped[dropped_count] = found.handle;
                dropped_count += 1;
            }
            continue;
        }
        if (row.shown.* == 0) row.shown.* = 1;
        const page_lines = pageLines(tables, atoms, row) orelse continue;
        if (row.page_lines.* == page_lines) continue;
        row.page_lines.* = page_lines;
        // A window that has just come to show the buffer, or changed size, shows its caret.
        if (row.current.* != 0) keepCaretInSight(tables, atoms, row);
        text_editor.request(frame.memory, tables, .{ .set_layout = .{ .buffer = row.buffer.*, .page_lines = page_lines, .tab_width = tab_width } });
    }
    for (dropped[0..dropped_count]) |dropped_handle| table.free(dropped_handle);
    // The buffer of the window with the keyboard is the latest visited.
    if (focusedPanel(tables, atoms)) |panel| {
        if (rowOfPanel(table, panel)) |found| buffer_list.visit(tables, .text, found.row.buffer.*);
    }
}

/// Declares every window open, a panel each, as the panels system follows them: a window
/// made this frame opens where its row says, and one whose row went closes.
fn declareWindows(pass: *sequencer.Pass) !void {
    if (!pass.writes(declared_panels_table)) return;
    const frame = pass.frame;
    const table = try pass.table(panels_table);
    var rows = table.readQuery(PanelRow);
    while (rows.next()) |found| {
        const row = found.view;
        plugin.panels.declare(frame.memory, frame.tables, .{
            .id = row.panel.*,
            .root = text_panel_root,
            .beside = row.open_beside.*,
            .side = std.enums.fromInt(plugin.panels.Side, row.open_side.*) orelse .right,
            .share = 0.5,
            .focus = std.enums.fromInt(plugin.panels.FocusOnOpen, row.open_focus.*) orelse .keep,
        });
    }
}

/// Scrolls `row`'s panel by the least that puts the buffer's caret in it.
fn keepCaretInSight(tables: *Table.Registry, atoms: *Atom.Registry, row: PanelRow) void {
    const buffer = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const content = panel_frame.contentRect(tables, atoms, row.panel.*) orelse return;
    const line_height = row.line_height.*;
    const cell_width = row.cell_width.*;
    if (line_height <= 0 or cell_width <= 0) return;

    const text_height = content.h - 2 * padding;
    const caret_top = @as(f32, @floatFromInt(buffer.caret_line.*)) * line_height;
    const caret_bottom = caret_top + line_height;
    if (caret_top < row.scroll_y.*) row.scroll_y.* = caret_top;
    if (caret_bottom > row.scroll_y.* + text_height) row.scroll_y.* = caret_bottom - text_height;

    const text_width = content.w - 2 * padding;
    const caret_left = @as(f32, @floatFromInt(buffer.caret_column.*)) * cell_width;
    const caret_right = caret_left + cell_width;
    if (caret_left < row.scroll_x.*) row.scroll_x.* = caret_left;
    if (caret_right > row.scroll_x.* + text_width) row.scroll_x.* = caret_right - text_width;
    row.scroll_x.* = @max(row.scroll_x.*, 0);
    row.scroll_y.* = @max(row.scroll_y.*, 0);
}

/// Typing goes to the text panel with the keyboard. Its other keys are actions': the text
/// editor's and its own; see `pushActions`.
fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const table = panelsTable(tables) orelse return;
    if (table.count() == 0) return;
    // The pointer is heard wherever it is, and tested against the panels' content here.
    try appendInput(pass, .{ .mouse_button_down = .{ .button = .left, .scope = .global } }, .text_panel_press);
    try appendInput(pass, .{ .mouse_button_up = .{ .button = .left } }, .text_panel_release);
    try appendInput(pass, .{ .mouse_scroll = .{ .scope = .global } }, .text_panel_scroll);
    const keyboard = focusedPanel(tables, atoms);
    var dragging = false;
    const written = try pass.writeTable(panels_table);
    var rows = written.query(PanelRow);
    while (rows.next()) |found| {
        dragging = dragging or found.view.dragging.* != 0;
        // What `idle` compares, to run again when the keyboard moves.
        const has_keyboard = keyboard != null and keyboard.? == found.view.panel.*;
        const typing: u8 = @intFromBool(has_keyboard);
        if (found.view.typing.* != typing) found.view.typing.* = typing;
    }
    // Moves are wanted only while a press is held, so a pointer crossing a panel draws nothing.
    if (dragging) try appendInput(pass, .{ .mouse_move = .{ .scope = .global } }, .text_panel_move);

    // While a history's tree is shown, the keyboard walks it and does nothing else, as
    // vundo's keys: along a branch, between branches, and out.
    if (historyRow(written) != null) {
        const none: input.ModifierFilter = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden };
        const control: input.ModifierFilter = .{ .control = .required, .alt = .forbidden, .super = .forbidden };
        const walking = [_]struct { key: input.Key, modifiers: input.ModifierFilter, message: Msg }{
            .{ .key = .b, .modifiers = none, .message = .text_panel_history_back },
            .{ .key = .left, .modifiers = none, .message = .text_panel_history_back },
            .{ .key = .f, .modifiers = none, .message = .text_panel_history_forward },
            .{ .key = .right, .modifiers = none, .message = .text_panel_history_forward },
            .{ .key = .n, .modifiers = none, .message = .text_panel_history_next },
            .{ .key = .down, .modifiers = none, .message = .text_panel_history_next },
            .{ .key = .p, .modifiers = none, .message = .text_panel_history_previous },
            .{ .key = .up, .modifiers = none, .message = .text_panel_history_previous },
            .{ .key = .enter, .modifiers = none, .message = .text_panel_history_keep },
            .{ .key = .q, .modifiers = none, .message = .text_panel_history_keep },
            .{ .key = .escape, .modifiers = none, .message = .text_panel_history_quit },
            .{ .key = .g, .modifiers = control, .message = .text_panel_history_quit },
        };
        for (walking) |walk| {
            try appendInput(pass, .{ .key_down = .{ .key = walk.key, .modifiers = walk.modifiers, .capture = true } }, walk.message);
        }
        return;
    }

    if (keyboard == null) return;
    // Not a capture, which would keep the pointer from every panel, this one included.
    const typing: input.Subscription = .{ .text_input = .{
        .modifiers = .{ .control = .forbidden, .alt = .forbidden, .super = .forbidden },
    } };
    try appendInput(pass, typing, .text_panel_char);
}

fn appendInput(pass: *sequencer.Pass, subscription: input.Subscription, message: Msg) !void {
    const tag = Atom.from(message);
    const subscriptions = try pass.writeTable(Atom.from(input.subscriptions_table_name));
    try input.appendSubscription(subscriptions, input.subscriptionRow(subscription, tag, .plugin, sequencer.inboxOf(system())));
}

/// Whether the focused panel is a text panel, which then lists its own actions, a prompt
/// over it or not.
pub fn listsActions(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    // The editor's own record of the focused view, which a prompt does not take.
    const focused = state_mod.viewFocus(tables, atoms).id.*;
    return isPanel(focused);
}

/// Whether a text panel has the keyboard.
pub fn hasKeyboard(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return focusedPanel(tables, atoms) != null;
}

/// Lists the text panel's actions while one has the focus, and the text editor's while it has
/// the keyboard. They do not capture their keys, which would keep the pointer and every other
/// key from the rest of the window. Their keys are the keymaps of `buffer`, `text` and `cua`.
pub fn pushActions(tables: *Table.Registry, atoms: *Atom.Registry, sink: plugin.ActionSink) void {
    if (!listsActions(tables, atoms)) return;
    const keybinds = mesha.keybinds;
    const inbox = sequencer.inboxOf(system());
    // A panel that searches takes the search's keys from under its prompt, which captures
    // the keyboard.
    const searching = if (panelsTable(tables)) |table| searchingRow(table) != null else false;
    if (searching) {
        for (isearch_actions) |def| {
            keybinds.pushActionDefinitions(atoms, sink, modes.isearch, inbox, &.{.{ .def = def, .capture = true }});
        }
        return;
    }
    // Under a prompt the panel's own actions stay listed, for the palette to offer, without
    // keys; the text editor's are then the prompt's.
    if (hasKeyboard(tables, atoms)) shared.pushActions(atoms, sink, .shared, system());
    for (panel_actions) |def| {
        const mode = panelActionMode(def);
        keybinds.pushActionDefinitions(atoms, sink, mode, inbox, &.{.{ .def = def }});
    }
}

// ---- drawing --------------------------------------------------------------------------------

/// What a panel's header adds after its title: whether the file is modified, its name, how
/// it is written, what last went wrong, and where the caret is. A panel without the
/// keyboard says it all dimly.
fn renderDecoration(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom) void {
    const table = panelsTable(tables) orelse return;
    const row = readRowOfPanel(table, panel) orelse return;
    const buffer = text_editor.rowOf(tables, row.buffer.*) orelse return;
    const scratch = tree.frame_allocator.allocator;
    const slot = std.mem.indexOfScalar(Atom, &panel_ids, panel) orelse return;
    const salt: u64 = slot;

    const focused = panels_mod.hasFocus(tables, atoms, panel);
    const dim = style.col.text_disabled;
    const modified = buffer.modified.* != 0;
    const chip = scratch.create(StatusChip) catch return;
    const read_only = buffer.access.* == @intFromEnum(text_editor.Access.read_only);
    chip.* = .{
        .label = if (read_only) "RO" else if (modified) "**" else "RW",
        .color = if (!focused) dim else if (modified) style.col.canvas else style.col.text_dim,
        .fill = if (focused and modified) style.col.warning else style.col.button,
    };
    tree.custom(.{ "text_panel.decoration.status", salt }, chip, .{ .size = .{ .w = .{ .fixed = StatusChip.width }, .h = .{ .fixed = StatusChip.height } } });
    const name = bufferTitle(buffer);
    tree.text(.{ "text_panel.decoration.name", salt }, name, .{ .font = style.ui_font, .color = if (focused) style.col.text else dim });

    const endings: text_editor.LineEndings = @enumFromInt(buffer.line_endings.*);
    const ending_name = switch (endings) {
        .lf => "LF",
        .crlf => "CRLF",
        .cr => "CR",
        .mixed => "Mixed endings",
    };
    const format = std.fmt.allocPrint(scratch, "{s} {s}", .{ buffer.encoding, ending_name }) catch return;
    tree.text(.{ "text_panel.decoration.format", salt }, format, .{ .font = style.ui_font, .color = style.col.text_disabled });
    const notice: Notice = std.enums.fromInt(Notice, row.notice.*) orelse .none;
    if (notice != .none) tree.text(.{ "text_panel.decoration.notice", salt }, notice.text(), .{ .font = style.ui_font, .color = style.col.danger });
    const awaiting: Awaiting = std.enums.fromInt(Awaiting, row.awaiting.*) orelse .none;
    const awaited = switch (awaiting) {
        .none => "",
        .zap => "Zap up to character:",
        .zap_through => "Zap to character:",
        .register_copy => "Copy to register:",
        .register_insert => "Insert register:",
        .register_point => "Point to register:",
        .register_jump => "Jump to register:",
    };
    if (awaited.len != 0) tree.text(.{ "text_panel.decoration.awaiting", salt }, awaited, .{ .font = style.ui_font, .color = style.col.accent_bright });
    // A jump says what it waits for: what to look for, then a place's letters.
    const jump: Jump = std.enums.fromInt(Jump, row.jump.*) orelse .none;
    if (jump != .none) {
        const waits_for_text = row.jump_typed.* < jump.characters();
        const wanted: []const u8 = if (!waits_for_text) "Jump to:" else if (jump == .word) "Jump to word beginning:" else "Jump to character:";
        tree.text(.{ "text_panel.decoration.jump", salt }, wanted, .{ .font = style.ui_font, .color = style.col.accent_bright });
    }
    // As Emacs's mode line says `Def` while a keyboard macro is defined.
    if (macroState(tables)) |macro| {
        if (macro.recording.* != 0 and focused) tree.text(.{ "text_panel.decoration.macro", salt }, "Def", .{ .font = style.ui_font, .color = style.col.warning });
    }
    // What the server says: of the name asked about, else of the caret's place.
    if (notice == .none) {
        if (row.info.len != 0) {
            tree.text(.{ "text_panel.decoration.info", salt }, row.info, .{ .font = style.ui_font, .color = if (focused) style.col.text_dim else dim });
        } else if (diagnosticAtCaret(tables, row.buffer.*, buffer)) |at_caret| {
            const shown = utf8Prefix(std.mem.sliceTo(at_caret.message, '\n'), max_info_bytes);
            tree.text(.{ "text_panel.decoration.diagnostic", salt }, shown, .{ .font = style.ui_font, .color = if (focused) severityColour(at_caret.severity) else dim });
        }
    }
    tree.rect(.{ "text_panel.decoration.fill", salt }, .{ .size = .{ .w = .fill, .h = .fill } });
    if (serverStatus(scratch, tables, row.buffer.*)) |status| {
        tree.text(.{ "text_panel.decoration.server", salt }, status.text, .{ .font = style.ui_font, .color = if (!focused) dim else if (status.trouble) style.col.danger else style.col.text_disabled });
    }
    const place = std.fmt.allocPrint(scratch, "{d}:{d}", .{ buffer.caret_line.* + 1, buffer.caret_column.* }) catch return;
    tree.text(.{ "text_panel.decoration.place", salt }, place, .{ .font = style.ui_font, .color = if (focused) style.col.text_dim else dim });
    // As much room before the header's buttons as between the header's other parts.
    tree.rect(.{ "text_panel.decoration.trail", salt }, .{ .size = .{ .w = .{ .fixed = 6 }, .h = .fill } });
}

const AtCaret = struct { message: []const u8, severity: lsp.Severity };

/// The most severe diagnostic covering the caret, as the server last told it.
fn diagnosticAtCaret(tables: *Table.Registry, buffer: Atom, state: Table.ReadView(text_editor.BufferRow)) ?AtCaret {
    const server_view = lsp.viewOf(tables, buffer) orelse return null;
    const view = text_editor.viewOf(tables, buffer) orelse return null;
    const line = state.caret_line.*;
    const caret: u32 = @intCast(state.caret.*);
    const column = caret - view.lineStart(line);
    var best: ?lsp.Diagnostic = null;
    for (server_view.diagnostics) |diagnostic| {
        const after_start = line > diagnostic.start_line or (line == diagnostic.start_line and column >= diagnostic.start_column);
        const before_end = line < diagnostic.end_line or (line == diagnostic.end_line and column <= diagnostic.end_column);
        if (!after_start or !before_end) continue;
        const more_severe = if (best) |chosen| @intFromEnum(diagnostic.severity) < @intFromEnum(chosen.severity) else true;
        if (more_severe) best = diagnostic;
    }
    const chosen = best orelse return null;
    return .{ .message = server_view.message(chosen), .severity = chosen.severity };
}

/// The buffer's server and its state, as the header says them: `zls`, `zls starting`,
/// `zls exited`. Null for a buffer on no server.
fn serverStatus(scratch: std.mem.Allocator, tables: *Table.Registry, buffer: Atom) ?struct { text: []const u8, trouble: bool } {
    const document = lsp.documentOf(tables, buffer) orelse return null;
    const server = lsp.serverOf(tables, document.server.*) orelse return null;
    const state = std.enums.fromInt(lsp.ServerState, server.state.*) orelse return null;
    const text = switch (state) {
        .running => server.program,
        .starting => std.fmt.allocPrint(scratch, "{s} starting", .{server.program}) catch return null,
        .exited => std.fmt.allocPrint(scratch, "{s} exited", .{server.program}) catch return null,
        .failed => std.fmt.allocPrint(scratch, "{s} not started", .{server.program}) catch return null,
    };
    return .{ .text = text, .trouble = state == .exited or state == .failed };
}

/// Whether the file is modified, as Emacs's mode line says it: `RW`, or `**` once edited.
/// A badge, its label centered by its ink: asterisks sit at the top of a line of text, and
/// set as text they would float above the rest of the header.
const StatusChip = struct {
    const width: f32 = 26;
    const height: f32 = 16;
    const radius: f32 = 3;

    label: []const u8,
    color: ui.Color,
    fill: ui.Color,

    pub fn draw(chip: *const StatusChip, size: mesha.math.Vec2f, ctx: *roop.Context) void {
        const label_font = style.ui_font;
        ctx.beginPath();
        ctx.roundedRect(0, 0, size.x, size.y, radius);
        ctx.fillColor(chip.fill);
        ctx.fill();
        const ink = ctx.textInk(label_font, chip.label);
        const label_width = ctx.measureText(label_font, chip.label).w;
        const baseline = @round(size.y / 2 - (ink.top + ink.bottom) / 2);
        ctx.fontFace(label_font);
        ctx.fillColor(chip.color);
        _ = ctx.text(@round((size.x - label_width) / 2), baseline, chip.label);
    }
};

/// Draws the panel: its header, then its text under it. `frame` is the panel's frame in the
/// window and `ctx` begins at its corner.
pub fn render(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom, frame: plugin.Viewport, ctx: *roop.Context) void {
    const zone = Log.zone(Zone.text_panel_render);
    defer zone.end();
    var header: panel_frame.Header = undefined;
    if (header.begin(memory, tables, atoms, panel)) {
        if (header.open) renderDecoration(&header.tree, tables, atoms, panel);
        header.finish(tables, atoms, frame, ctx);
    }
    const viewport = panel_frame.beginContent(tables, atoms, panel, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const table = panelsTable(tables) orelse return;
    const row = readRowOfPanel(table, panel) orelse return;

    ctx.beginPath();
    ctx.rect(0, 0, viewport.width, viewport.height);
    ctx.fillColor(style.col.canvas);
    ctx.fill();

    const buffer = text_editor.rowOf(tables, row.buffer.*) orelse return;
    if (buffer.view_address.* == 0) return;
    const view: *const text_editor.View = @ptrFromInt(buffer.view_address.*);

    const size_index = @min(row.text_size.*, text_sizes.len - 1);
    const size = text_sizes[size_index];
    // The cell `followMetrics` keeps, which the kernels scroll by: zero until the font is in.
    // Nothing else draws in the font before then, so asking here is what loads it; its metrics
    // arriving change the cell, which draws the panel again.
    const line_height = row.line_height.*;
    const cell_width = row.cell_width.*;
    if (line_height <= 0 or cell_width <= 0) {
        _ = ctx.fontView(size.font);
        return;
    }

    // What is tinted behind the text in sight: a search's matches.
    const line_count = view.lineCount();
    const first_line: u32 = @intFromFloat(@floor(row.scroll_y.* / line_height));
    const sight = sightOf(view, row.scroll_y.*, line_height, viewport.height);
    const sight_start = sight.start;
    const sight_end = sight.end;

    // A jump that has what it looks for names each place in sight with letters.
    var hint_storage: [max_jump_targets]Hint = undefined;
    var hints: []const Hint = &.{};
    const jump: Jump = std.enums.fromInt(Jump, row.jump.*) orelse .none;
    if (jump != .none and row.jump_typed.* >= jump.characters()) {
        var needle_buffer: [8]u8 = undefined;
        const needle = jumpNeedle(row, &needle_buffer);
        var target_storage: [max_jump_targets]u32 = undefined;
        const targets = jumpTargets(&target_storage, view, jump, needle, sight_start, sight_end);
        const keys = shared.settingsOf(tables).hint_keys;
        var hint_count: usize = 0;
        for (targets, 0..) |target, index| {
            const label = jumpLabel(keys, index, targets.len);
            // Once a name's first letter is typed, only the places it begins are still named.
            const still_named = row.jump_letter.* == 0 or label[0] == row.jump_letter.*;
            if (label[0] == 0 or !still_named) continue;
            hint_storage[hint_count] = .{ .offset = target, .label = label };
            hint_count += 1;
        }
        hints = hint_storage[0..hint_count];
    }
    var highlight_storage: [max_highlights]Highlight = undefined;
    var highlights: []const Highlight = &.{};
    if (row.search.* != @intFromEnum(Search.none)) {
        const needle = action_palette.promptText(tables, atoms);
        highlights = searchHighlights(&highlight_storage, view, needle, "", sight_start, sight_end);
    }
    const replace_phase = replacePhase(row);
    if (replace_phase != .none) {
        // What is being typed shows as it is typed; what was typed before is remembered.
        const typed = action_palette.promptText(tables, atoms);
        const needle = if (replace_phase == .from) typed else rememberedText(tables, "replace_from");
        const replacement: []const u8 = switch (replace_phase) {
            .none, .from => "",
            .to => typed,
            .asking => rememberedText(tables, "replace_to"),
        };
        const covered_start = @max(sight_start, row.replace_start.*);
        const covered_end = @min(sight_end, row.replace_end.*);
        // Asked about one at a time, the matches before the one selected are behind it.
        const selection_start: u32 = @intCast(@min(buffer.caret.*, buffer.anchor.*));
        const from = if (replace_phase == .asking) @max(covered_start, selection_start) else covered_start;
        highlights = searchHighlights(&highlight_storage, view, needle, replacement, from, covered_end);
        if (replace_phase != .from) {
            for (highlight_storage[0..highlights.len]) |*highlight| highlight.colour = style.col.danger_wash;
        }
    }

    // The caret and the selection are the current window's; another's point is its marker.
    const is_current = row.current.* != 0;
    const point = view.markers[slotOf(panel)];
    const drawing: Drawing = .{
        .ctx = ctx,
        .view = view,
        .highlights = highlights,
        .hints = hints,
        .caret = if (is_current) @intCast(buffer.caret.*) else point,
        .anchor = if (is_current) @intCast(buffer.anchor.*) else point,
        .focused = panels_mod.hasFocus(tables, atoms, panel),
        .font = size.font,
        .extra_font = size.extra_font,
        .line_height = line_height,
        .cell_width = cell_width,
        .baseline = ctx.fontBaseline(size.font, line_height),
        .scroll_x = row.scroll_x.*,
        .text_width = viewport.width - 2 * padding,
        .server_view = lsp.viewOf(tables, row.buffer.*),
    };

    ctx.save();
    defer ctx.restore();
    ctx.intersectScissor(padding, 0, viewport.width - 2 * padding, viewport.height, 0);
    var line = first_line;
    while (line < line_count) : (line += 1) {
        const top = padding + @as(f32, @floatFromInt(line)) * line_height - row.scroll_y.*;
        if (top >= viewport.height) break;
        drawing.drawLine(line, top);
    }
    if (row.history_shown.* != 0) drawHistory(tables, ctx, view, viewport, line_height);
    if (is_current and row.completing.* == @intFromEnum(Completing.listed)) {
        var prefix_buffer: [lsp.max_item_field_bytes]u8 = undefined;
        if (completionPrefix(tables, row, &prefix_buffer)) |prefix| drawCompletions(tables, &drawing, row, prefix, viewport);
    }
}

/// Draws the completions that begin as `prefix` does in a list under the caret's line, or
/// over it where there is no room under: each with what the server says of it, the chosen
/// one marked, and those around the chosen one when there are more than fit.
fn drawCompletions(tables: *Table.Registry, drawing: *const Drawing, row: ReadRow, prefix: []const u8, viewport: plugin.Viewport) void {
    const kept = tables.findByName(completions_table) orelse return;
    const ctx = drawing.ctx;
    const view = drawing.view;
    const selected = row.completion_selected.*;
    const first_shown = if (selected >= completion_rows) selected - (completion_rows - 1) else 0;

    // How wide the widest listed is, and how many there are.
    var listed: u32 = 0;
    var widest: usize = completion_min_cells;
    var rows = kept.readQuery(CompletionRow);
    while (rows.next()) |found| {
        if (!completionBegins(found.view.label, prefix)) continue;
        const shown = listed >= first_shown and listed < first_shown + completion_rows;
        if (shown) widest = @max(widest, found.view.label.len + 2 + found.view.detail.len);
        listed += 1;
    }
    const shown_count = @min(listed - @min(first_shown, listed), completion_rows);
    if (shown_count == 0) return;
    const cells = @min(widest, completion_max_cells);

    const caret_line = view.lineOf(drawing.caret);
    const start_column = view.columnOf(row.completion_start.*, tab_width);
    const width = @as(f32, @floatFromInt(cells)) * drawing.cell_width + 2 * padding;
    const height = @as(f32, @floatFromInt(shown_count)) * drawing.line_height;
    const line_top = padding + @as(f32, @floatFromInt(caret_line)) * drawing.line_height - row.scroll_y.*;
    const below = line_top + drawing.line_height;
    const top = if (below + height <= viewport.height) below else @max(line_top - height, 0);
    const left = @max(@min(drawing.xOf(start_column) - padding, viewport.width - width), 0);

    drawing.fill(left, top, width, height, style.col.card);
    var index: u32 = 0;
    var listing = kept.readQuery(CompletionRow);
    while (listing.next()) |found| {
        if (!completionBegins(found.view.label, prefix)) continue;
        defer index += 1;
        if (index < first_shown or index >= first_shown + shown_count) continue;
        const row_top = top + @as(f32, @floatFromInt(index - first_shown)) * drawing.line_height;
        if (index == selected) drawing.fill(left, row_top, width, drawing.line_height, style.col.accent_deep);
        const label = found.view.label[0..@min(found.view.label.len, cells)];
        ctx.fontFace(drawing.font);
        ctx.fillColor(style.col.text);
        _ = ctx.text(left + padding, row_top + drawing.baseline, label);
        // What the server says of it, as far as the row has room after its name.
        const room = cells - label.len;
        if (room < 3 or found.view.detail.len == 0) continue;
        const detail = found.view.detail[0..@min(found.view.detail.len, room - 2)];
        const detail_x = left + padding + @as(f32, @floatFromInt(label.len + 2)) * drawing.cell_width;
        ctx.fillColor(style.col.text_disabled);
        _ = ctx.text(detail_x, row_top + drawing.baseline, detail);
    }
}

/// The most rows of a history's tree shown at once, as vundo's window has.
const max_history_rows = 8;
/// How far apart the states of a branch are drawn, and how large each is.
const history_step: f32 = 18;
const history_dot: f32 = 3;

/// Draws the history of `view`'s text as a tree along the panel's bottom: time runs to the
/// right, a state's first child on its own row and each branch made later on a row below.
/// The state the text is in is marked, and kept in sight.
fn drawHistory(tables: *Table.Registry, ctx: *roop.Context, view: *const text_editor.View, viewport: plugin.Viewport, line_height: f32) void {
    const nodes = view.history;
    if (nodes.len == 0) return;
    const scratch = tables.memory.frameScratchAllocator() catch return;
    const columns = scratch.allocator.alloc(u32, nodes.len) catch return;
    const rows = scratch.allocator.alloc(u32, nodes.len) catch return;
    const stack = scratch.allocator.alloc(u32, nodes.len) catch return;

    // Each state in the order a walk down the tree meets it, a branch's states before the
    // branches made after it: a first child keeps its parent's row, any other takes the
    // next row no state has.
    const none = text_editor.HistoryNode.none;
    var row_count: u32 = 1;
    var stacked: usize = 1;
    stack[0] = 0;
    columns[0] = 0;
    rows[0] = 0;
    while (stacked > 0) {
        stacked -= 1;
        const node = stack[stacked];
        const parent = nodes[node].parent;
        if (parent != none) {
            columns[node] = columns[parent] + 1;
            const is_first = nodes[parent].first_child == node;
            rows[node] = if (is_first) rows[parent] else row_count;
            if (!is_first) row_count += 1;
        }
        // Its children go on the stack last to first, so the first comes off first.
        const pushed_from = stacked;
        var child = nodes[node].first_child;
        while (child != none) : (child = nodes[child].next_sibling) {
            stack[stacked] = child;
            stacked += 1;
        }
        std.mem.reverse(u32, stack[pushed_from..stacked]);
    }

    const shown_rows = @min(row_count, max_history_rows);
    const height = @as(f32, @floatFromInt(shown_rows)) * line_height + 2 * padding;
    const top = viewport.height - height;
    ctx.beginPath();
    ctx.rect(0, top, viewport.width, height);
    ctx.fillColor(style.col.sidebar);
    ctx.fill();
    ctx.beginPath();
    ctx.rect(0, top, viewport.width, 1);
    ctx.fillColor(style.col.region_border);
    ctx.fill();

    // The rows and columns in sight are those around the state the text is in.
    const current = view.history_current;
    const first_row = @min(rows[current] -| (max_history_rows / 2), row_count - shown_rows);
    const shown_columns: u32 = @intFromFloat(@max((viewport.width - 2 * padding) / history_step, 1));
    const first_column = (columns[current] + 2) -| shown_columns;
    const left = padding + history_step / 2;
    const first_y = top + padding + line_height / 2;

    ctx.save();
    defer ctx.restore();
    ctx.intersectScissor(0, top, viewport.width, height, 0);
    for (nodes, 0..) |node, index| {
        if (columns[index] < first_column or columns[index] > first_column + shown_columns) continue;
        const x = left + @as(f32, @floatFromInt(columns[index] - first_column)) * history_step;
        const y = first_y + (@as(f32, @floatFromInt(rows[index])) - @as(f32, @floatFromInt(first_row))) * line_height;
        if (node.parent != none) {
            // From its parent: along the row, or for a later branch down from the parent first.
            const parent_y = first_y + (@as(f32, @floatFromInt(rows[node.parent])) - @as(f32, @floatFromInt(first_row))) * line_height;
            ctx.beginPath();
            ctx.moveTo(x - history_step, parent_y);
            ctx.lineTo(x - history_step, y);
            ctx.lineTo(x, y);
            ctx.strokeWidth(1);
            ctx.strokeColor(style.col.text_disabled);
            ctx.stroke();
        }
        const is_current = index == current;
        ctx.beginPath();
        ctx.circle(x, y, if (is_current) history_dot + 1.5 else history_dot);
        ctx.fillColor(if (is_current) style.col.accent_bright else style.col.text_dim);
        ctx.fill();
    }
}

/// The letters that name a place a jump can go to, drawn over the text there.
const Hint = struct { offset: u32, label: [2]u8 };

/// A stretch of the text tinted behind its characters, from `start` to `end`. With a
/// `replacement`, that text is drawn after the stretch, in cells of its own: what would be
/// put in its place.
const Highlight = struct { start: u32, end: u32, colour: roop.Color, replacement: []const u8 = "" };

/// The most stretches tinted in one drawing: more matches than that in sight go untinted.
const max_highlights = 256;

/// The places `needle` is wholly between `sight_start` and `sight_end`, in `storage`, in
/// order, each with `replacement` to show beside it.
fn searchHighlights(storage: []Highlight, view: *const text_editor.View, needle: []const u8, replacement: []const u8, sight_start: u32, sight_end: u32) []const Highlight {
    if (needle.len == 0) return storage[0..0];
    const needle_len: u32 = @intCast(needle.len);
    var count: usize = 0;
    var from = sight_start;
    while (count < storage.len) {
        const start = view.find(needle, from) orelse break;
        if (start + needle_len > sight_end) break;
        storage[count] = .{ .start = start, .end = start + needle_len, .colour = style.col.match_wash, .replacement = replacement };
        count += 1;
        from = start + needle_len;
    }
    return storage[0..count];
}

/// One drawing of a panel's text: what every line needs.
const Drawing = struct {
    ctx: *roop.Context,
    view: *const text_editor.View,
    /// What is tinted behind the text, in order of where each starts.
    highlights: []const Highlight = &.{},
    /// The names of the places a jump can go to, in order of where each is.
    hints: []const Hint = &.{},
    caret: u32,
    anchor: u32,
    focused: bool,
    /// The fonts of the panel's size: see `TextSize`.
    font: resources.Font,
    extra_font: resources.Font,
    line_height: f32,
    cell_width: f32,
    /// From a line's top: the capitals sit in the middle of the line.
    baseline: f32,
    scroll_x: f32,
    text_width: f32,
    /// What the buffer's language server last said of it; null for a buffer on none.
    server_view: ?*const lsp.DocumentView,

    /// Where cell `column` begins, in the panel.
    fn xOf(drawing: *const Drawing, column: u32) f32 {
        return padding + @as(f32, @floatFromInt(column)) * drawing.cell_width - drawing.scroll_x;
    }

    fn fill(drawing: *const Drawing, x: f32, y: f32, width: f32, height: f32, color: roop.Color) void {
        const ctx = drawing.ctx;
        ctx.beginPath();
        ctx.rect(x, y, width, height);
        ctx.fillColor(color);
        ctx.fill();
    }

    /// Draws line `line` with its top at `top`: the current line's band, the selection, the
    /// text, and the caret. One walk over the line's bytes finds the cells of all of them.
    fn drawLine(drawing: *const Drawing, line: u32, top: f32) void {
        const view = drawing.view;
        const start = view.lineStart(line);
        const end = view.lineEnd(line);
        const selection_start = @min(drawing.caret, drawing.anchor);
        const selection_end = @max(drawing.caret, drawing.anchor);
        const has_caret = drawing.caret >= start and drawing.caret <= end;
        if (has_caret and drawing.focused) drawing.fill(0, top, drawing.text_width + 2 * padding, drawing.line_height, style.col.sidebar);

        // The cells the selection covers on this line; a selection that runs past the line's
        // end takes one more cell, for the line break.
        const selected = selection_start != selection_end and selection_start <= end and selection_end > start;
        var selection_first: u32 = 0;
        var selection_last: u32 = 0;
        var caret_column: u32 = 0;

        const baseline = top + drawing.baseline;
        const last_visible_x = drawing.text_width + 2 * padding;
        var colours: Colours = .init(drawing.server_view, line, start);
        var column: u32 = 0;
        var position = start;
        var run_start = start;
        var run_column: u32 = 0;
        // The first highlight that reaches this line, and the cell its tint begins at here.
        var highlight_index: usize = 0;
        while (highlight_index < drawing.highlights.len and drawing.highlights[highlight_index].end <= start) highlight_index += 1;
        var tint_first: u32 = 0;
        // Whether the walk is inside that highlight: one begun on a line before is, from here.
        var tint_begun = highlight_index < drawing.highlights.len and drawing.highlights[highlight_index].start < start;
        while (true) {
            if (position == selection_start) selection_first = column;
            if (position == selection_end) selection_last = column;
            if (position == drawing.caret) caret_column = column;
            // A highlight's tint runs under its cells, and what would replace it is drawn
            // after it, in cells of its own that push the rest of the line along.
            while (highlight_index < drawing.highlights.len) {
                const highlight = drawing.highlights[highlight_index];
                if (highlight.start == position) {
                    tint_first = column;
                    tint_begun = true;
                }
                if (highlight.end != position) break;
                drawing.tint(highlight, tint_first, column, top);
                tint_begun = false;
                if (highlight.replacement.len != 0) {
                    drawing.drawRun(run_start, position, run_column, baseline, colours.colour);
                    column += drawing.drawReplacement(highlight.replacement, column, top, baseline);
                    run_start = position;
                    run_column = column;
                }
                highlight_index += 1;
            }
            if (position >= end) break;

            // Where the colour changes, the run of text before it ends.
            if (position == colours.boundary) {
                drawing.drawRun(run_start, position, run_column, baseline, colours.colour);
                colours.advance(position);
                run_start = position;
                run_column = column;
            }
            const byte = view.byteAt(position);
            const plain = byte >= 0x20 and byte < 0x7F;
            if (plain) {
                position += 1;
                column += 1;
                continue;
            }
            // A tab or a character past ASCII ends the run of plain text before it.
            drawing.drawRun(run_start, position, run_column, baseline, colours.colour);
            if (byte == '\t') {
                column += tab_width - column % tab_width;
                position += 1;
            } else {
                const length = @min(codepointLength(byte), end - position);
                const cells = drawing.drawWide(position, length, column, top, baseline, colours.colour);
                column += cells;
                position += length;
            }
            run_start = position;
            run_column = column;
            // A wide character may step over a boundary.
            while (position > colours.boundary) colours.advance(colours.boundary);
            // Nothing past the panel's edge shows; the selection and caret are before it or not seen.
            if (drawing.xOf(column) > last_visible_x and position < selection_start and position < drawing.caret) break;
        }
        if (selection_start < start) selection_first = 0;
        if (selection_end > end) selection_last = column + 1;
        // A highlight that runs on past the line is tinted as far as the line goes.
        // One the walk never reached, past the panel's edge, is out of sight.
        if (tint_begun) drawing.tint(drawing.highlights[highlight_index], tint_first, column, top);

        if (selected) {
            const x = drawing.xOf(selection_first);
            const width = @as(f32, @floatFromInt(selection_last - selection_first)) * drawing.cell_width;
            drawing.fill(x, top, width, drawing.line_height, style.col.accent_wash);
        }
        drawing.drawRun(run_start, position, run_column, baseline, colours.colour);
        drawing.drawHints(start, end, top, baseline);
        drawing.underlineDiagnostics(line, top);
        if (has_caret and drawing.focused) {
            drawing.fill(drawing.xOf(caret_column), top, caret_width, drawing.line_height, style.col.accent_bright);
        }
    }

    /// Draws, over the text of the line from `start` to `end`, the names of the places on it
    /// a jump can go to.
    fn drawHints(drawing: *const Drawing, start: u32, end: u32, top: f32, baseline: f32) void {
        const ctx = drawing.ctx;
        for (drawing.hints) |hint| {
            if (hint.offset > end) break;
            if (hint.offset < start) continue;
            const letters: []const u8 = if (hint.label[1] == 0) hint.label[0..1] else hint.label[0..2];
            const column = drawing.view.columnOf(hint.offset, tab_width);
            const x = drawing.xOf(column);
            const width = @as(f32, @floatFromInt(letters.len)) * drawing.cell_width;
            drawing.fill(x, top, width, drawing.line_height, style.col.accent_deep);
            ctx.fontFace(drawing.font);
            ctx.fillColor(style.col.text);
            _ = ctx.text(x, baseline, letters);
        }
    }

    /// Tints the cells from `first` to `last` of the line at `top` in the highlight's colour.
    fn tint(drawing: *const Drawing, highlight: Highlight, first: u32, last: u32, top: f32) void {
        // The match a search is at is the selection, which has its own colour.
        const selection_start = @min(drawing.caret, drawing.anchor);
        const selection_end = @max(drawing.caret, drawing.anchor);
        if (highlight.start == selection_start and highlight.end == selection_end and highlight.replacement.len == 0) return;
        const width = @as(f32, @floatFromInt(last - first)) * drawing.cell_width;
        drawing.fill(drawing.xOf(first), top, width, drawing.line_height, highlight.colour);
    }

    /// Draws `text`, what would replace a highlight, from cell `column`, and says how many
    /// cells it took.
    fn drawReplacement(drawing: *const Drawing, text: []const u8, column: u32, top: f32, baseline: f32) u32 {
        var cells: u32 = 0;
        for (text) |byte| {
            if ((byte & 0xC0) != 0x80) cells += 1;
        }
        const ctx = drawing.ctx;
        const x = drawing.xOf(column);
        drawing.fill(x, top, @as(f32, @floatFromInt(cells)) * drawing.cell_width, drawing.line_height, style.col.success_wash);
        ctx.fontFace(drawing.font);
        ctx.fillColor(style.col.success);
        _ = ctx.text(x, baseline, text);
        return cells;
    }

    fn underlineDiagnostics(drawing: *const Drawing, line: u32, top: f32) void {
        underlineDiagnosticsOf(drawing, line, top);
    }

    /// A wavy line from `left` to `right` at `y`, as editors mark a diagnostic.
    fn wave(drawing: *const Drawing, left: f32, right: f32, y: f32, colour: roop.Color) void {
        const ctx = drawing.ctx;
        const step: f32 = 2;
        ctx.beginPath();
        ctx.moveTo(left, y);
        var x = left;
        var up = true;
        while (x < right) : (up = !up) {
            x = @min(x + step, right);
            ctx.lineTo(x, if (up) y - 1.5 else y);
        }
        ctx.strokeWidth(1);
        ctx.strokeColor(colour);
        ctx.stroke();
    }

    /// Draws the plain ASCII bytes from `start` to `end`, a cell each, from cell `column`.
    fn drawRun(drawing: *const Drawing, start: u32, end: u32, column: u32, baseline: f32, colour: roop.Color) void {
        if (start == end) return;
        const ctx = drawing.ctx;
        ctx.fontFace(drawing.font);
        ctx.fillColor(colour);
        const pieces = drawing.view.range(start, end);
        var cell = column;
        for (pieces) |piece| {
            if (piece.len == 0) continue;
            _ = ctx.text(drawing.xOf(cell), baseline, piece);
            cell += @intCast(piece.len);
        }
    }

    /// Draws one character past ASCII in its cells, and returns how many it takes
    /// (`text_editor.buffer_mod.cellsOf`): from the extra font or the fallback fonts behind it
    /// when one has the character, centred in its cells, as a box when none has.
    fn drawWide(drawing: *const Drawing, start: u32, length: u32, column: u32, top: f32, baseline: f32, colour: roop.Color) u32 {
        const ctx = drawing.ctx;
        var bytes: [4]u8 = undefined;
        const character = drawing.view.copyRange(start, bytes[0..length]);
        const codepoint = std.unicode.utf8Decode(character) catch std.unicode.replacement_character;
        const cells = text_editor.buffer_mod.cellsOf(codepoint);
        const x = drawing.xOf(column);
        const cells_width = @as(f32, @floatFromInt(cells)) * drawing.cell_width;
        const advance = ctx.measureText(drawing.extra_font, character).w;
        if (advance > 0) {
            ctx.fontFace(drawing.extra_font);
            ctx.fillColor(colour);
            // A fallback glyph is drawn at the font's em and may be wider or narrower than its
            // cells: a narrower one is centred in them, a wider one squeezed into them, so it
            // never covers its neighbours. A glyph of the font's own fills them already.
            if (advance <= cells_width) {
                const centred = x + (cells_width - advance) / 2;
                _ = ctx.text(centred, baseline, character);
                return cells;
            }
            // Composed in the panel's coordinates: squeeze about the glyph's origin, then place
            // it, then the panel's own transform.
            ctx.save();
            defer ctx.restore();
            const transform = roop.transform;
            const squeeze = transform.scaling(cells_width / advance, 1);
            const placed = transform.multiply(transform.translation(x, baseline), squeeze);
            const panel = ctx.currentTransform();
            ctx.setTransform(transform.multiply(panel, placed));
            _ = ctx.text(0, 0, character);
            return cells;
        }
        const inset: f32 = 2;
        ctx.beginPath();
        ctx.rect(x + inset, top + inset, cells_width - 2 * inset, drawing.line_height - 2 * inset);
        ctx.strokeWidth(1);
        ctx.strokeColor(style.col.text_disabled);
        ctx.stroke();
        return cells;
    }
};

/// Underlines what the server's diagnostics cover of `line`, wavy, in their severity's colour.
fn underlineDiagnosticsOf(drawing: *const Drawing, line: u32, top: f32) void {
    const server_view = drawing.server_view orelse return;
    const view = drawing.view;
    const start = view.lineStart(line);
    const end = view.lineEnd(line);
    const line_bytes = end - start;
    for (server_view.diagnostics) |diagnostic| {
        if (diagnostic.start_line > line or diagnostic.end_line < line) continue;
        const first_byte = if (diagnostic.start_line == line) @min(diagnostic.start_column, line_bytes) else 0;
        const last_byte = if (diagnostic.end_line == line) @min(diagnostic.end_column, line_bytes) else line_bytes;
        const first_cell = view.columnOf(start + first_byte, tab_width);
        // An empty range, as at a line's end, still marks a cell.
        const last_cell = @max(view.columnOf(start + last_byte, tab_width), first_cell + 1);
        drawing.wave(drawing.xOf(first_cell), drawing.xOf(last_cell), top + drawing.line_height - 2, severityColour(diagnostic.severity));
    }
}

fn severityColour(severity: lsp.Severity) roop.Color {
    return switch (severity) {
        .@"error" => style.col.danger,
        .warning => style.col.warning,
        else => style.col.text_disabled,
    };
}

/// The colours of a line's text, from the server's tokens: where the next change of colour
/// is, and the colour until then.
const Colours = struct {
    tokens: []const lsp.Token,
    next: usize,
    line_start: u32,
    /// The byte where the colour next changes; past any line when it does not.
    boundary: u32,
    colour: roop.Color,

    fn init(server_view: ?*const lsp.DocumentView, line: u32, line_start: u32) Colours {
        const tokens: []const lsp.Token = if (server_view) |known| known.tokens else &.{};
        const first = if (server_view) |known| known.firstTokenOn(line) else 0;
        var colours: Colours = .{ .tokens = tokens, .next = first, .line_start = line_start, .boundary = 0, .colour = style.col.text };
        // Tokens of other lines are not this one's.
        var last = first;
        while (last < tokens.len and tokens[last].line == line) last += 1;
        colours.tokens = tokens[0..last];
        colours.advance(line_start);
        return colours;
    }

    /// Moves to the colour at byte `position`, which is the boundary or the line's start.
    fn advance(colours: *Colours, position: u32) void {
        while (colours.next < colours.tokens.len) {
            const token = colours.tokens[colours.next];
            const token_start = colours.line_start + token.start;
            const token_end = token_start + token.length;
            if (position >= token_end) {
                colours.next += 1;
                continue;
            }
            if (position < token_start) {
                colours.colour = style.col.text;
                colours.boundary = token_start;
            } else {
                colours.colour = tokenColour(token.kind);
                colours.boundary = token_end;
            }
            return;
        }
        colours.colour = style.col.text;
        colours.boundary = std.math.maxInt(u32);
    }
};

/// The nano theme's faces, by what a piece of code is. There is no bold face loaded, so
/// types take a colour of their own where nano would set them strong.
fn tokenColour(kind: lsp.TokenKind) roop.Color {
    return switch (kind) {
        .keyword => code_colours.salient,
        .string, .number => code_colours.popout,
        .comment => code_colours.faded,
        .type => code_colours.strong,
        .plain, .function => style.col.text,
    };
}

const code_colours = struct {
    const salient = ui.rgb(129, 161, 193);
    const popout = ui.rgb(208, 135, 112);
    const faded = ui.rgb(118, 132, 158);
    const strong = ui.rgb(136, 192, 208);
};

fn codepointLength(first_byte: u8) u32 {
    if (first_byte >= 0xF0) return 4;
    if (first_byte >= 0xE0) return 3;
    if (first_byte >= 0xC0) return 2;
    return 1;
}
