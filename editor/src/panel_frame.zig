//! What the editor's panels share in drawing their frames: the usual header along the top
//! (`ui.panel_header`), and the content under it. A panel's whole frame is its module's to
//! draw, so each module's `render` opens a `Header`, adds what its panel says there, and draws
//! its content between `beginContent` and `endContent`. A kernel that needs the content's
//! place before it is drawn asks `contentRect`, which the drawing follows too, so the two
//! cannot disagree.
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const panels_mod = mesha.panels;
const plugin = mesha.plugin;
const roop = mesha.roop;
const state = @import("state.zig");
const fixed_panels = @import("fixed_panels.zig");
const editor_sequencer = @import("editor_sequencer.zig");

/// The most elements a panel adds to its header.
const added_commands = 64;

/// Whether the panel `id` wears a header where it is. A maximized panel wears none, and the
/// figure canvas none while it is the only panel the window shows; every other panel of the
/// editor's wears one.
pub fn wearsHeader(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) bool {
    if (panels_mod.isMaximized(tables, atoms, id)) return false;
    const stage = id == Atom.from(fixed_panels.figure_stage);
    if (!stage) return true;
    return panels_mod.load(tables, atoms).visibleCount() > 1;
}

/// Where the panel `id` shows its content, in window pixels: its frame under its header, or
/// its whole frame where it wears none. Null while the panel is closed, hidden behind a
/// maximized one, or too short for any content.
pub fn contentRect(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) ?panels_mod.Rect {
    const shown = panels_mod.panelFor(tables, atoms, id) orelse return null;
    if (shown.frame.empty()) return null;
    if (!wearsHeader(tables, atoms, id)) return shown.frame;
    const content = ui.panel_header.contentRect(shown.frame);
    if (content.empty()) return null;
    return content;
}

/// The size of what a panel shows under its header, in window pixels.
pub const ContentSize = struct {
    /// The content's width.
    width: f32,
    /// The content's height; zero for a frame no taller than the header.
    height: f32,
};

/// The size of the content the panel `resized.panel` shows in a frame of the size the panels
/// system told (`events.panels`, which tells frames): the frame less its header, or the whole
/// frame where the panel wears none, as `contentRect` places it.
pub fn contentSize(tables: *Table.Registry, atoms: *Atom.Registry, resized: plugin.panels.Resized) ContentSize {
    const frame: panels_mod.Rect = .{ .w = resized.frame_width, .h = resized.frame_height };
    const wears_header = wearsHeader(tables, atoms, resized.panel);
    const content = if (wears_header) ui.panel_header.contentRect(frame) else frame;
    return .{ .width = content.w, .height = content.h };
}

/// A panel's header while it is drawn. `begin` it in place, add the panel's own elements to
/// `tree` while `open`, then `finish` it.
pub const Header = struct {
    /// The header's elements, in the frame's scratch memory.
    tree: ui.Tree,
    /// What the header says of the panel.
    options: ui.panel_header.Options,
    /// Whether the header took its row, and the panel may add to it.
    open: bool,

    /// Opens the header of the panel `panel`. False, and nothing to finish, where the panel
    /// wears none or the frame has no memory for its tree.
    pub fn begin(header: *Header, memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom) bool {
        if (!wearsHeader(tables, atoms, panel)) return false;
        const shown = panels_mod.panelFor(tables, atoms, panel) orelse return false;
        const scratch = memory.frameScratchAllocator() catch return false;
        header.tree = ui.Tree.init(scratch, atoms, ui.panel_header.commands + added_commands) catch return false;
        header.tree.hovered = state.hoveredElementId(tables);
        // The tree copies no text: the title lasts the frame in its scratch memory.
        const title = scratch.allocator.dupe(u8, shown.title.slice()) catch return false;
        header.options = .{
            .panel = panel,
            .title = title,
            .focused = panels_mod.hasFocus(tables, atoms, panel),
            .maximized = panels_mod.isMaximized(tables, atoms, panel),
        };
        header.open = ui.panel_header.begin(&header.tree, header.options);
        return true;
    }

    /// Closes the header and draws it along the top of `frame`, the panel's frame in the
    /// window, into `ctx`, which begins at the frame's corner.
    pub fn finish(header: *Header, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
        if (header.open) ui.panel_header.end(&header.tree, header.options);
        const height = @min(ui.panel_header.height, frame.height);
        ctx.save();
        defer ctx.restore();
        ctx.intersectScissor(0, 0, frame.width, height, 0);
        header.tree.commit(.{
            .root_size = .{ .x = frame.width, .y = height },
            .offset = .{ .x = frame.x, .y = frame.y },
            .hovered = state.hoveredElementId(tables),
            .depth = panels_mod.kChromeHitDepth,
        }, ctx, state.hitRegions(tables, atoms), editor_sequencer.redrawInbox());
        ui.panel_header.drawFootLine(ctx, frame.width, if (header.options.focused) .focused else .unfocused);
    }
};

/// Moves `ctx`, which begins at the corner of `frame`, to the corner of the content of the
/// panel `id` and clips it there. Returns the content's place in the window, or null, with
/// `ctx` untouched, where the panel has none; otherwise `endContent` must follow.
pub fn beginContent(tables: *Table.Registry, atoms: *Atom.Registry, id: Atom, frame: plugin.Viewport, ctx: *roop.Context) ?plugin.Viewport {
    const content = contentRect(tables, atoms, id) orelse return null;
    ctx.save();
    ctx.translate(content.x - frame.x, content.y - frame.y);
    ctx.intersectScissor(0, 0, content.w, content.h, 0);
    return .{ .x = content.x, .y = content.y, .width = content.w, .height = content.h };
}

/// Puts `ctx` back as `beginContent` found it.
pub fn endContent(ctx: *roop.Context) void {
    ctx.restore();
}

/// Draws the header of a panel that adds nothing to it: its title and the buttons.
pub fn drawPlainHeader(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, panel: Atom, frame: plugin.Viewport, ctx: *roop.Context) void {
    var header: Header = undefined;
    if (!header.begin(memory, tables, atoms, panel)) return;
    header.finish(tables, atoms, frame, ctx);
}
