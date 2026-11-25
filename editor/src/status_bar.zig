//! The band at the bottom of the figure editor: what the pointer is over, or else a context hint.
//!
//! A system of one kernel (`system`): requests to show or clear the hover text are rows of
//! `commands.status_bar`, which it takes in its run. In the same run it notes what the element
//! under the pointer says, its hit region's tooltip: the regions are all there then, while the
//! bar is drawn before some of its own panel's are. Under an open action palette nothing
//! behind it is hovered, so the band shows no hover text while the palette is open.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const plugin_api = mesha.plugin;
const state = @import("state.zig");
const style = @import("ui/style.zig");
const action_palette = @import("action_palette.zig");
const panels_mod = mesha.panels;
const sequencer = mesha.sequencer;
const input = mesha.input;
const figure_workspace = @import("figure/workspace.zig");

pub const table_name = "editor_status_bar";
const kTextSize: usize = 256;

pub const CmdPayload = plugin_api.editor_api.StatusBarCmd;

pub const commands_table_name = "commands.status_bar";
pub const Requests = sequencer.Commands(CmdPayload);

/// Appends a request for the bar's next run, as the editor's command hook does for a `Cmd`.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, payload: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(payload);
}

/// The bar is drawn in the figure editor's stage, so its changes draw that module's panels.
pub fn system() sequencer.System {
    return .{
        .name = "status_bar",
        .root = figure_workspace.figure_root,
        .claims = sequencer.claims_nothing,
        .access = access,
        .kernels = &.{.{ .name = "status_bar.apply", .run = apply }},
    };
}

const state_table = Atom.from(table_name);
const commands_table = Atom.from(commands_table_name);
const palette_table = Atom.from(action_palette.table_name);
const hover_table = Atom.from(input.hover_table_name);
const regions_table = Atom.from(state.hit_regions_name);

fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.read(palette_table);
    // A headless run has no pointer and no regions.
    if (hoverObservable(frame)) {
        result.read(hover_table);
        result.read(regions_table);
    }
    result.write(commands_table);
    result.write(state_table);
    return result;
}

const Applying = struct {
    table: *Table,
    view: View,
    palette_open: bool,

    fn applyRequest(applying: *Applying, payload: *const CmdPayload) !void {
        switch (payload.*) {
            .set_hover => |text| {
                // Nothing behind an open palette is hovered, so a late hover stays silent.
                if (applying.palette_open) return;
                var len = @min(text.len, kTextSize);
                while (len > 0 and !std.unicode.utf8ValidateSlice(text[0..len])) : (len -= 1) {}
                try applying.table.assignString(applying.view.hover_text, text[0..len]);
            },
            .clear_hover => applying.view.hover_text.* = .{},
        }
    }
};

fn hoverObservable(frame: *const sequencer.Frame) bool {
    return frame.tables.findByName(hover_table) != null and frame.tables.findByName(regions_table) != null;
}

/// A hit region's part in what the bar says.
const RegionView = struct {
    id: *[16]u8,
    hover: *u8,
    tooltip: []const u8,
};

/// What the region of `element` says, the regions' own bytes: of several regions with one
/// element, the later row's, as the later row answers the pointer. Empty when it says nothing.
fn tooltipOf(regions: *Table, element: [16]u8) []const u8 {
    var tooltip: []const u8 = "";
    var rows = regions.readQuery(RegionView);
    while (rows.next()) |region| {
        if (region.view.hover.* == 0) continue;
        if (!std.mem.eql(u8, region.view.id, &element)) continue;
        tooltip = region.view.tooltip;
    }
    return tooltip;
}

/// Applies the frame's requests in order and notes the hovered element's tooltip, then clears
/// both under an open palette.
fn apply(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    const palette_open = action_palette.requestOpen(frame.tables, frame.atoms);
    const observed = try pass.readSingleton(state_table, View);
    var tooltip: []const u8 = "";
    if (!palette_open and hoverObservable(frame)) {
        const hover = try pass.readSingleton(hover_table, struct { element: *[16]u8 });
        const over_element = !std.mem.allEqual(u8, hover.element, 0);
        if (over_element) tooltip = tooltipOf(try pass.table(regions_table), hover.element.*);
    }
    const state_cells = try pass.table(state_table);
    const shown_tooltip = state_cells.textOf(observed.tooltip.*);
    const tooltip_changed = !std.mem.eql(u8, shown_tooltip, tooltip);
    const requests = Requests.of(frame.memory, frame.tables, commands_table_name);
    const hover_text_stale = palette_open and observed.hover_text.payload.len != 0;
    if (requests.count() == 0 and !hover_text_stale and !tooltip_changed) return;
    var applying: Applying = .{ .table = state_cells, .view = try pass.writeSingleton(state_table, View), .palette_open = palette_open };
    try requests.take(pass, &applying, Applying.applyRequest);
    if (palette_open) applying.view.hover_text.* = .{};
    if (tooltip.len == 0) {
        applying.view.tooltip.* = .{};
    } else {
        try state_cells.assignString(applying.view.tooltip, tooltip);
    }
}

const View = struct {
    hover_text: *Table.String,
    /// What the element under the pointer says, as of the bar's last run.
    tooltip: *Table.String,
};

const defaults = .{
    .hover_text = Table.String{},
    .tooltip = Table.String{},
};

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Requests.ensure(scratch, atoms, tables, commands_table_name);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    schema.addField("hover_text", Table.String, .text_field);
    schema.addField("tooltip", Table.String, .text_field);
    _ = try tables.ensureSingleton(&schema, atoms.intern(table_name), defaults, .durable);
}

pub fn prepareInit(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Requests.ensure(scratch, atoms, tables, commands_table_name);
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 2);
    defer schema.deinit();
    try schema.addFieldFallible("hover_text", Table.String, .text_field);
    try schema.addFieldFallible("tooltip", Table.String, .text_field);
    _ = try state.prepareSingletonSchema(tables, &schema, atoms.intern(table_name), defaults, .durable);
}

/// What the band says of what the pointer is over: the tooltip of the element input reports,
/// unless the action palette is asking for the screen, else the text its owners set.
pub fn hoverText(tables: *Table.Registry, atoms: *Atom.Registry) []const u8 {
    const t = tables.findByName(atoms.intern(table_name)) orelse @panic("editor_status_bar singleton missing");
    const row = t.readRow(.{ .row = 0, .generation = t.rowGeneration(0) }, struct { hover_text: []const u8, tooltip: []const u8 }) orelse @panic("editor_status_bar singleton row missing");
    const palette_open = action_palette.requestOpen(tables, atoms);
    if (row.tooltip.len != 0 and !palette_open) return row.tooltip;
    return row.hover_text;
}

/// How the band reads for the hint in it. Hovered descriptions keep the plain text color.
pub const Look = struct { fill: ui.Color, hint: ui.Color };

pub fn render(scratch: memory_mod.Scratch, tables: *Table.Registry, atoms: *Atom.Registry, rect: panels_mod.Rect, hint: []const u8, look: Look, ctx: anytype, hits: *Table, depth: u32) void {
    const hover_text = hoverText(tables, atoms);
    var tree = ui.Tree.init(scratch, atoms, 8) catch @panic("OOM");
    if (tree.beginRect("editor.status_bar", .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .{ .fixed = rect.w }, .h = .{ .fixed = rect.h } },
        .bg = look.fill,
        .padding = 6,
        .clip_content = true,
    })) {
        defer tree.endRect();
        const hovering = hover_text.len != 0;
        const text_color = if (hovering) style.col.text_dim else look.hint;
        tree.text("editor.status_bar.text", if (hovering) hover_text else hint, .{ .font = style.ui_font, .color = text_color, .size_hint = .{ .w = .fill } });
    }
    tree.commit(.{ .root_size = .{ .x = rect.w, .y = rect.h }, .origin = .{ .x = rect.x, .y = rect.y }, .depth = depth }, ctx, hits);
}
