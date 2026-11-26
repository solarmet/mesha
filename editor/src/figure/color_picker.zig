//! Captured color targets and their cancellable edits. Rendering only observes this owner.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const modes = @import("../modes.zig");
const workspace = @import("workspace.zig");
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;
const plugin = mesha.plugin;
const figure = mesha.figure;
const panels_mod = mesha.panels;
const fixed_panels = @import("../fixed_panels.zig");
const roop = mesha.roop;
const session = @import("session.zig");
const sequencer = mesha.sequencer;
const drawing = @import("drawing.zig");
const selection = @import("selection.zig");
const gesture = @import("gesture.zig");
const asks = @import("asks.zig");
const filmstrip = @import("filmstrip.zig");
const geometry = @import("geometry.zig");
const prompts = @import("prompts.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");
const button = @import("../ui/button.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const api = figure;
const chrome = @import("chrome.zig");
const editor_mod = @import("../editor.zig");

pub const name = "editor_figure_color";
pub const targets_name = "editor_figure_color_targets";
const Scope = enum(u8) { defaults, selection, property };
const Part = enum(u8) { none, saturation_value, hue, alpha };
pub const Config = struct {
    open: u8 = 0,
    scope: u8 = @intFromEnum(Scope.defaults),
    channel: u8 = @intFromEnum(api.PaintChannel.fill),
    doc: Atom = session.none,
    mode: Atom = session.none,
    table_index: u32 = 0,
    table_generation: u32 = 0,
    row: u32 = 0,
    generation: u32 = 0,
    shape: u32 = 0,
    /// The shape colored, by name, while the popover colors one shape.
    label: Atom = session.none,
    anchor_y: f32 = 0,
    current: session.Color = .{ 0, 0, 0, 255 },
    original: session.Color = .{ 0, 0, 0, 255 },
    before: session.Color = .{ 0, 0, 0, 255 },
    hue: f32 = 0,
    saturation: f32 = 0,
    value: f32 = 0,
    alpha: f32 = 1,
    drag_part: u8 = 0,
    drag_x: f32 = 0,
    drag_y: f32 = 0,
    drag_w: f32 = 0,
    drag_h: f32 = 0,
    sampling: u8 = 0,
    fallback: u8 = 0,
};
const Target = struct { doc: Atom = session.none, shape: u32 = 0 };
/// The tags of the color popover's actions and swatches, and of the pointer dragging its
/// controls.
pub const Msg = enum(u64) {
    figure_color_fill = Atom.from("figure_color_fill").value(),
    figure_color_stroke = Atom.from("figure_color_stroke").value(),
    figure_color_target_toggle = Atom.from("figure_color_target_toggle").value(),
    figure_color_hex = Atom.from("figure_color_hex").value(),
    figure_color_opacity = Atom.from("figure_color_opacity").value(),
    figure_color_sample = Atom.from("figure_color_sample").value(),
    figure_color_done = Atom.from("figure_color_done").value(),
    figure_color_swatch = Atom.from("figure_color_swatch").value(),
    figure_color_down = Atom.from("figure_color_down").value(),
    figure_color_move = Atom.from("figure_color_move").value(),
    figure_color_up = Atom.from("figure_color_up").value(),
    figure_color_cancel = Atom.from("figure_color_cancel").value(),
    _,
};

pub const actions = blk: {
    const defs = .{
        .{ Msg.figure_color_fill, "Open captured fill color popover" },
        .{ Msg.figure_color_stroke, "Open captured stroke color popover" },
        .{ Msg.figure_color_target_toggle, "Switch the fill/stroke color target (x)" },
        .{ Msg.figure_color_hex, "Enter captured fill/stroke color as hex RGBA" },
        .{ Msg.figure_color_opacity, "Set color alpha as a percentage" },
        .{ Msg.figure_color_sample, "Pick an artwork color for the captured target" },
        .{ Msg.figure_color_done, "Close the color popover" },
    };
    var result: [defs.len]plugin.action_api.Def = undefined;
    for (defs, 0..) |entry, i| result[i] = .{ .name = modes.shortName("figure", @tagName(entry[0])), .tag = @tagName(entry[0]), .doc = entry[1] };
    break :blk result;
};

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try session.prepareSingleton(Config, mem, atoms, tables, name);
    try session.prepareTable(Target, mem, atoms, tables, targets_name, 4096);
}

pub const ConfigView = session.Row(Config);
pub fn config(tables: *Table.Registry) ConfigView {
    const owner = tables.findByName(Atom.from(name)).?;
    return owner.getRow(.{ .row = 0, .generation = owner.rowGeneration(0) }, session.Row(Config)).?;
}

/// The shapes the popover colors at once, a row each.
pub const TargetRows = sequencer.Rows(session.Row(Target));
pub fn colorTargets(tables: *Table.Registry) TargetRows {
    return .of(tables.findByName(Atom.from(targets_name)).?);
}

pub fn isOpen(tables: *Table.Registry) bool {
    if (tables.findByName(Atom.from(name)) == null) return false;
    return config(tables).open.* != 0;
}

pub fn samplingChannel(tables: *Table.Registry) ?api.PaintChannel {
    if (!isOpen(tables)) return null;
    const settings = config(tables);
    if (settings.sampling.* == 0) return null;
    return targetChannel(settings);
}

fn targetChannel(settings: session.Row(Config)) api.PaintChannel {
    return @enumFromInt(settings.channel.*);
}

fn defaultColor(settings: drawing.ConfigView, channel: api.PaintChannel) *session.Color {
    return if (channel == .stroke) settings.stroke_color else settings.fill_color;
}

fn validate(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const settings = config(tables);
    const context = session.figureContext(tables, atoms);
    const handle = api.DefinitionHandle{ .table_index = settings.table_index.*, .table_generation = settings.table_generation.*, .row = settings.row.*, .generation = settings.generation.* };
    const doc = figure.resolveDefinition(context, handle) catch return error.ColorTargetChanged;
    const editor = session.get(tables);
    if (doc != settings.doc.* or doc != editor.doc.*) return error.ColorTargetChanged;
    const info = try figure.definitionInfo(context, doc);
    if (!info.editor_open) return error.ColorTargetChanged;
}

/// A property edits its own fallback color; bulk commands explicitly replace paints.
pub fn open(tables: *Table.Registry, atoms: *Atom.Registry, channel: api.PaintChannel, property: ?session.ItemEvent) !void {
    const editor = session.get(tables);
    if (gesture.busy(gesture.get(tables)) or editor.gesture_active.* != 0 or editor.tx_active.* != 0) return error.GestureSettling;
    const definition = try session.readDefinition(tables, atoms, editor.doc.*);
    const definitions = try session.listDefinitions(tables, atoms);
    const handle = for (definitions) |entry| {
        if (entry.info.definition == editor.doc.* and entry.info.editor_open) break entry.handle;
    } else return error.ColorTargetChanged;
    const settings = config(tables);
    const targets = colorTargets(tables);
    settings.open.* = 0;
    targets.clear();
    errdefer targets.clear();
    var scope: Scope = .defaults;
    var shape_id: u32 = 0;
    var label = session.none;
    var color = defaultColor(drawing.config(tables), channel).*;
    var fallback = false;
    var anchor_y: f32 = 0;
    if (property) |item| {
        if (item.kind == names.shape) {
            const shape = session.findById(api.read.Shape, definition.shapes, item.id) orelse return error.MissingShape;
            if (!session.editableLayer(definition, shape.layer)) return error.LockedLayer;
            scope = .property;
            shape_id = shape.id;
            label = shape.name;
            color = if (channel == .fill) shape.fill_color else shape.stroke_color;
            fallback = (if (channel == .fill) shape.fill_paint else shape.stroke_paint) != 0;
        } else if (item.kind != prompts.defaults_kind) return error.InvalidColorTarget;
        var hits = editor_state.hitRegions(tables, atoms).query(struct { id: *[16]u8, pos: *session.Vec2 });
        const anchor = ui.ElementId{ .atom = names.@"figure.inspector.field", .extra = item.field };
        while (hits.next()) |hit| {
            const id = std.mem.bytesToValue(ui.ElementId, hit.view.id);
            if (std.meta.eql(id, anchor)) {
                anchor_y = hit.view.pos.y;
                break;
            }
        }
    } else {
        const ids = try selection.selectedShapeIds(tables);
        if (ids.len != 0) {
            scope = .selection;
            for (ids) |id| {
                const shape = session.findById(api.read.Shape, definition.shapes, id) orelse return error.MissingShape;
                if (!session.editableLayer(definition, shape.layer)) return error.LockedLayer;
                _ = try targets.insert(Target{ .doc = editor.doc.*, .shape = id });
                if (shape_id == 0 or id == editor.active_id.*) {
                    shape_id = id;
                    color = if (channel == .fill) shape.fill_color else shape.stroke_color;
                }
            }
        }
    }
    settings.scope.* = @intFromEnum(scope);
    settings.channel.* = @intFromEnum(channel);
    settings.doc.* = editor.doc.*;
    settings.mode.* = editor.mode.*;
    settings.table_index.* = handle.table_index;
    settings.table_generation.* = handle.table_generation;
    settings.row.* = handle.row;
    settings.generation.* = handle.generation;
    settings.shape.* = shape_id;
    settings.label.* = label;
    settings.anchor_y.* = anchor_y;
    settings.original.* = color;
    settings.before.* = color;
    settings.fallback.* = @intFromBool(fallback);
    settings.drag_part.* = 0;
    settings.sampling.* = 0;
    setColor(settings, color);
    settings.open.* = 1;
    drawing.config(tables).color_target.* = Atom.from(@tagName(channel));
}

fn beginEdit(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    try validate(tables, atoms);
    if (session.get(tables).tx_active.* != 0) return error.GestureSettling;
    const settings = config(tables);
    if (settings.open.* == 0) return error.ColorPickerClosed;
    const pointer = gesture.Pointer{ .point = session.zero, .screen = session.zero, .modifiers = 0 };
    try gesture.begin(gesture.get(tables), .{ .kind = .color, .doc = settings.doc.*, .pointer = pointer });
    settings.before.* = settings.current.*;
}

pub fn apply(tables: *Table.Registry, atoms: *Atom.Registry, color: session.Color) !void {
    try beginEdit(tables, atoms);
    setColor(config(tables), color);
    _ = gesture.record(gesture.get(tables), .{ .point = session.zero, .screen = session.zero, .modifiers = 0 });
    _ = gesture.end(gesture.get(tables), .commit);
}

pub fn applyToSelection(tables: *Table.Registry, atoms: *Atom.Registry, color: session.Color) !void {
    const channel: api.PaintChannel = if (drawing.config(tables).color_target.* == names.stroke) .stroke else .fill;
    try open(tables, atoms, channel, null);
    try apply(tables, atoms, color);
    // Standalone Eyedropper has no popover, but retains ownership until completion.
    config(tables).open.* = 0;
}

pub fn previewEdit(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    try validate(tables, atoms);
    const settings = config(tables);
    const channel = targetChannel(settings);
    const scope: Scope = @enumFromInt(settings.scope.*);
    if (scope == .defaults) {
        defaultColor(drawing.config(tables), channel).* = settings.current.*;
        return;
    }
    // Build the captured payload before resetting the previous preview.
    const definition = try session.readDefinition(tables, atoms, settings.doc.*);
    const transaction_open = gesture.get(tables).transaction_owned.* != 0;
    var payload: api.PreviewEdit = undefined;
    if (scope == .property) {
        const authored = session.findById(api.read.Shape, definition.shapes, settings.shape.*) orelse return error.MissingShape;
        // In Animate the color shown, and so the one an edit changes, is the working pose's.
        const shape = filmstrip.posedRow(session.get(tables), .shape, definition, authored);
        if (!session.editableLayer(definition, shape.layer)) return error.LockedLayer;
        const previous = if (channel == .fill) shape.fill_color else shape.stroke_color;
        if (!transaction_open and std.meta.eql(previous, settings.current.*)) return;
        payload = .{ .set_shape = .{
            .doc = settings.doc.*,
            .id = settings.shape.*,
            .fill_color = if (channel == .fill) settings.current.* else null,
            .stroke_color = if (channel == .stroke) settings.current.* else null,
        } };
    } else {
        const allocator = (try tables.memory.frameScratchAllocator()).allocator;
        const targets = colorTargets(tables);
        const ids = try allocator.alloc(u32, targets.count());
        var rows = targets.query();
        var count: usize = 0;
        var changed = false;
        while (rows.next()) |row| {
            const authored = session.findById(api.read.Shape, definition.shapes, row.view.shape.*) orelse return error.MissingShape;
            const shape = filmstrip.posedRow(session.get(tables), .shape, definition, authored);
            if (!session.editableLayer(definition, shape.layer)) return error.LockedLayer;
            const previous = if (channel == .fill) shape.fill_color else shape.stroke_color;
            const paint = if (channel == .fill) shape.fill_paint else shape.stroke_paint;
            if (paint != 0 or !std.meta.eql(previous, settings.current.*)) changed = true;
            ids[count] = row.view.shape.*;
            count += 1;
        }
        if (!transaction_open and !changed) return;
        payload = .{ .set_shape_color = .{ .doc = settings.doc.*, .ids = ids[0..count], .target = channel, .color = settings.current.* } };
    }
    // In Animate, a color goes to the working pose rather than the definition.
    const edits = try filmstrip.animated(tables, atoms, payload);
    try gesture.openTransaction(tables, atoms, names.color);
    try gesture.submitPreview(tables, atoms, .absolute, edits.slice());
}

/// Called only when the acknowledged gesture reaches its terminal state.
pub fn complete(session_table: *Table, settings: ConfigView, editor: session.View, draw_settings: drawing.ConfigView, recent_colors: drawing.RecentRows, feedback: session.FeedbackView, intent: gesture.Intent) void {
    const scope: Scope = @enumFromInt(settings.scope.*);
    settings.drag_part.* = 0;
    editor.gesture_active.* = 0;
    if (intent != .commit) {
        setColor(settings, settings.before.*);
        if (scope == .defaults) defaultColor(draw_settings, targetChannel(settings)).* = settings.before.*;
        return;
    }
    if (scope == .selection) defaultColor(draw_settings, targetChannel(settings)).* = settings.current.*;
    drawing.rememberColor(recent_colors, settings.current.*) catch |err| prompts.status(session_table, editor, feedback, @errorName(err));
}

pub fn dismiss(settings: ConfigView, gesture_state: gesture.View) void {
    settings.open.* = 0;
    settings.sampling.* = 0;
    if (gesture.activeKind(gesture_state) == .color) {
        _ = gesture.end(gesture_state, .cancel);
    }
}

pub fn cancel(settings: ConfigView, gesture_state: gesture.View) bool {
    if (gesture.activeKind(gesture_state) == .color) {
        _ = gesture.end(gesture_state, .cancel);
        return true;
    }
    if (settings.open.* == 0) return false;
    if (settings.sampling.* != 0) settings.sampling.* = 0 else settings.open.* = 0;
    return true;
}

pub fn sync(tables: *Table.Registry, atoms: *Atom.Registry) void {
    if (!isOpen(tables)) return;
    validate(tables, atoms) catch {
        dismiss(config(tables), gesture.get(tables));
        return;
    };
    const settings = config(tables);
    if (!workspace.stageShown(tables) or session.get(tables).mode.* != settings.mode.*) dismiss(config(tables), gesture.get(tables));
}

pub fn renameDocument(settings: ConfigView, color_targets: TargetRows, old: Atom, new: Atom) void {
    if (settings.doc.* == old) settings.doc.* = new;
    var rows = color_targets.query();
    while (rows.next()) |row| if (row.view.doc.* == old) {
        row.view.doc.* = new;
    };
}

fn colorFromHsv(hue: f32, saturation: f32, value: f32, alpha: f32) session.Color {
    const sector = hue * 6;
    const index = @as(u32, @intFromFloat(@floor(sector))) % 6;
    const f = sector - @floor(sector);
    const p = value * (1 - saturation);
    const q = value * (1 - saturation * f);
    const u = value * (1 - saturation * (1 - f));
    const rgb = switch (index) {
        0 => [3]f32{ value, u, p },
        1 => [3]f32{ q, value, p },
        2 => [3]f32{ p, value, u },
        3 => [3]f32{ p, q, value },
        4 => [3]f32{ u, p, value },
        else => [3]f32{ value, p, q },
    };
    return .{
        @intFromFloat(@round(std.math.clamp(rgb[0], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(rgb[1], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(rgb[2], 0, 1) * 255)),
        @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255)),
    };
}
fn setColor(settings: session.Row(Config), picker_color: session.Color) void {
    settings.current.* = picker_color;
    const r = @as(f32, @floatFromInt(picker_color[0])) / 255;
    const g = @as(f32, @floatFromInt(picker_color[1])) / 255;
    const b = @as(f32, @floatFromInt(picker_color[2])) / 255;
    const hi = @max(r, @max(g, b));
    const lo = @min(r, @min(g, b));
    const delta = hi - lo;
    var hue: f32 = 0;
    if (delta > 0) {
        hue = if (hi == r) (g - b) / delta else if (hi == g) 2 + (b - r) / delta else 4 + (r - g) / delta;
        hue /= 6;
        if (hue < 0) hue += 1;
    }
    settings.hue.* = hue;
    settings.saturation.* = if (hi > 0) delta / hi else 0;
    settings.value.* = hi;
    settings.alpha.* = @as(f32, @floatFromInt(picker_color[3])) / 255;
}

/// The popover's rows, top to bottom, each a line of text or a control of the editor's metrics.
const popover_padding: f32 = 10;
const popover_gap: f32 = 6;
const text_line = style.metric.text_line;
const control_height = style.metric.control_height;
const channels_height: f32 = 180;
const swatch_row_height: f32 = 18;
const popover_width: f32 = 280;
/// The popover's height: its rows and the gaps between them, within its padding.
const popover_height: f32 = 2 * popover_padding + text_line + channels_height + 2 * control_height +
    (text_line + 2 * swatch_row_height) + (text_line + swatch_row_height) + control_height + text_line + 8 * popover_gap;

pub fn bounds(tables: *Table.Registry, atoms: *Atom.Registry) ?panels_mod.Rect {
    if (!isOpen(tables)) return null;
    const stage = workspace.stageViewport(tables, atoms) orelse return null;
    const canvas = geometry.stageLayout(stage, workspace.stageChrome(session.observed(tables))).canvas;
    if (canvas.w < popover_width or canvas.h < popover_height) return null;
    const settings = config(tables);
    const top = std.math.clamp(settings.anchor_y.*, canvas.y, canvas.y + canvas.h - popover_height);
    return .{ .x = canvas.x + canvas.w - popover_width, .y = top, .w = popover_width, .h = popover_height };
}

fn controlRect(panel: panels_mod.Rect, part: Part) panels_mod.Rect {
    return .{
        .x = panel.x + switch (part) {
            .saturation_value, .none => @as(f32, 10),
            .hue => 198,
            .alpha => 226,
        },
        // Below the title.
        .y = panel.y + popover_padding + text_line + popover_gap,
        .w = if (part == .saturation_value) channels_height else 20,
        .h = channels_height,
    };
}

pub fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    if (!isOpen(tables)) return;
    if (config(tables).drag_part.* == 0) return;
    try workspace.appendInput(pass, .{ .mouse_move = .{ .capture = true } }, .from(Msg.figure_color_move));
    try workspace.appendInput(pass, .{ .mouse_button_up = .{ .button = .left, .capture = true } }, .from(Msg.figure_color_up));
    try workspace.appendInput(pass, .{ .pointer_cancel = .{} }, .from(Msg.figure_color_cancel));
}

fn move(settings: ConfigView, gesture_state: gesture.View, x: f32, y: f32) void {
    const part: Part = @enumFromInt(settings.drag_part.*);
    if (part == .none or gesture.phaseOf(gesture_state) != .sampling) return;
    const horizontal = std.math.clamp((x - settings.drag_x.*) / settings.drag_w.*, 0, 1);
    const vertical = std.math.clamp((y - settings.drag_y.*) / settings.drag_h.*, 0, 1);
    switch (part) {
        .saturation_value => {
            settings.saturation.* = horizontal;
            settings.value.* = 1 - vertical;
        },
        .hue => settings.hue.* = vertical,
        .alpha => settings.alpha.* = 1 - vertical,
        .none => unreachable,
    }
    settings.current.* = colorFromHsv(settings.hue.*, settings.saturation.*, settings.value.*, settings.alpha.*);
    _ = gesture.record(gesture_state, .{ .point = .{ .x = x, .y = y }, .screen = .{ .x = x, .y = y }, .modifiers = 0 });
}

pub fn handlePointer(tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) !bool {
    const settings = config(tables);
    switch (received.tag.to(Msg)) {
        .figure_color_cancel => {
            if (gesture.activeKind(gesture.get(tables)) == .color) _ = gesture.end(gesture.get(tables), .cancel);
            return true;
        },
        .figure_color_move => {
            const event = try received.payloadAs(input.MouseMoveMsg);
            move(config(tables), gesture.get(tables), event.x, event.y);
            return true;
        },
        .figure_color_up => {
            const event = try received.payloadAs(input.MouseButtonMsg);
            if (settings.drag_part.* != 0) {
                move(config(tables), gesture.get(tables), event.x, event.y);
                _ = gesture.end(gesture.get(tables), .commit);
                session.get(tables).gesture_active.* = 0;
            }
            return true;
        },
        .figure_color_down => {},
        else => return false,
    }
    if (settings.open.* == 0) return true;
    const event = try received.payloadAs(input.MouseButtonMsg);
    const panel = bounds(tables, atoms) orelse return true;
    for ([_]Part{ .saturation_value, .hue, .alpha }) |part| {
        const rect = controlRect(panel, part);
        if (!geometry.contains(rect, .{ .x = event.x, .y = event.y })) continue;
        try beginEdit(tables, atoms);
        settings.drag_part.* = @intFromEnum(part);
        settings.drag_x.* = rect.x;
        settings.drag_y.* = rect.y;
        settings.drag_w.* = rect.w;
        settings.drag_h.* = rect.h;
        session.get(tables).gesture_active.* = 1;
        move(config(tables), gesture.get(tables), event.x, event.y);
        break;
    }
    return true;
}

/// A press on the canvas while the popover samples: the host is asked what lies under it, and
/// `sampleAnswered` takes its colour. False when the popover does not sample.
pub fn pick(tables: *Table.Registry, atoms: *Atom.Registry, point: session.Vec2) !bool {
    const settings = config(tables);
    if (settings.open.* == 0 or settings.sampling.* == 0) return false;
    try asks.hitTest(tables, atoms, workspace.system(), .{ .purpose = .color_sample_press, .point = point });
    return true;
}

/// The popover takes the colour of the artwork the host found under its sampling press, or asks
/// the paint's colour there (`samplePaintAnswered`), and stops sampling; a press over nothing
/// leaves it sampling.
pub fn sampleAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const settings = config(tables);
    if (settings.open.* == 0 or settings.sampling.* == 0) return;
    try answer.failure.check();
    const sample = try drawing.sampleOf(tables, atoms, answer.hits()) orelse return;
    const asker = workspace.system();
    const color = try drawing.sampledColor(tables, atoms, asker, .color_sample_paint, answer.point, sample) orelse return;
    try apply(tables, atoms, color);
    settings.sampling.* = 0;
}

/// The popover takes the colour of the paint its sampling press found, and stops sampling.
pub fn samplePaintAnswered(tables: *Table.Registry, atoms: *Atom.Registry, answer: asks.Answer) !void {
    const settings = config(tables);
    if (settings.open.* == 0 or settings.sampling.* == 0) return;
    const color = try drawing.paintColor(answer);
    try apply(tables, atoms, color);
    settings.sampling.* = 0;
}

pub fn handleAction(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, received: sequencer.Message) !bool {
    const settings = config(tables);
    const message = received.tag.to(Msg);
    switch (message) {
        .figure_color_done => dismiss(config(tables), gesture.get(tables)),
        .figure_color_swatch => {
            const color = (try received.userDataAs(session.Color)).*;
            try apply(tables, atoms, color);
        },
        .figure_color_sample => {
            if (settings.open.* == 0) return error.ColorPickerClosed;
            settings.sampling.* = 1;
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Pick artwork on the canvas; Esc cancels picking");
        },
        .figure_color_fill, .figure_color_stroke => {
            const channel: api.PaintChannel = if (message == .figure_color_fill) .fill else .stroke;
            try open(tables, atoms, channel, null);
        },
        .figure_color_target_toggle => {
            const defaults = drawing.config(tables);
            const channel: api.PaintChannel = if (defaults.color_target.* == names.fill) .stroke else .fill;
            if (settings.open.* != 0) {
                try validate(tables, atoms);
                var color = defaultColor(drawing.config(tables), channel).*;
                const scope: Scope = @enumFromInt(settings.scope.*);
                if (scope != .defaults) {
                    const definition = try session.readDefinition(tables, atoms, settings.doc.*);
                    const shape = session.findById(api.read.Shape, definition.shapes, settings.shape.*) orelse return error.MissingShape;
                    color = if (channel == .fill) shape.fill_color else shape.stroke_color;
                    settings.fallback.* = @intFromBool(scope == .property and (if (channel == .fill) shape.fill_paint else shape.stroke_paint) != 0);
                }
                settings.channel.* = @intFromEnum(channel);
                settings.original.* = color;
                setColor(settings, color);
                defaults.color_target.* = Atom.from(@tagName(channel));
            } else defaults.color_target.* = Atom.from(@tagName(channel));
            prompts.inform(session.feedbackTable(tables), session.feedback(tables), if (channel == .fill) "Color target: fill" else "Color target: stroke");
        },
        .figure_color_hex, .figure_color_opacity => try promptForColor(mem, tables, atoms, settings, message),
        else => return false,
    }
    return true;
}

/// Opens the popover if it is closed, then prompts for its color as hex or its opacity.
fn promptForColor(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, settings: ConfigView, message: Msg) !void {
    if (settings.open.* == 0) {
        const channel: api.PaintChannel = if (drawing.config(tables).color_target.* == names.stroke) .stroke else .fill;
        try open(tables, atoms, channel, null);
    }
    const color = settings.current.*;
    var buffer: [32]u8 = undefined;
    const initial = if (message == .figure_color_hex)
        try std.fmt.bufPrint(&buffer, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ color[0], color[1], color[2], color[3] })
    else
        try std.fmt.bufPrint(&buffer, "{d:.1}", .{settings.alpha.* * 100});
    try prompts.show(mem, tables, atoms, if (message == .figure_color_hex) names.color_hex else names.color_opacity, initial);
}

fn rgba(color: session.Color) roop.Color {
    return roop.rgba(color[0], color[1], color[2], color[3]);
}

const Swatch = struct {
    color: session.Color,
    pub fn draw(self: *const Swatch, size: session.Vec2, ctx: *roop.Context) void {
        ctx.beginPath();
        ctx.rect(0, 0, size.x, size.y);
        ctx.fillColor(roop.rgba(244, 244, 244, 255));
        ctx.fill();
        ctx.beginPath();
        ctx.rect(0, 0, size.x / 2, size.y / 2);
        ctx.rect(size.x / 2, size.y / 2, size.x / 2, size.y / 2);
        ctx.fillColor(roop.rgba(189, 189, 189, 255));
        ctx.fill();
        ctx.beginPath();
        ctx.rect(0, 0, size.x, size.y);
        ctx.fillColor(rgba(self.color));
        ctx.fill();
    }
};

pub fn swatch(tree: *ui.Tree, id: anytype, color: session.Color, size: ui.Size) void {
    const drawable = tree.frame_allocator.allocator.create(Swatch) catch return;
    drawable.* = .{ .color = color };
    tree.custom(id, drawable, .{ .size = size });
}

const Channels = struct {
    hue: f32,
    saturation: f32,
    value: f32,
    alpha: f32,
    pub fn draw(self: *const Channels, _: session.Vec2, ctx: *roop.Context) void {
        const hue_color = colorFromHsv(self.hue, 1, 1, 1);
        const horizontal = roop.linearGradient(0, 0, 180, 0, roop.rgba(255, 255, 255, 255), rgba(hue_color));
        ctx.beginPath();
        ctx.rect(0, 0, 180, 180);
        ctx.fillPaint(horizontal);
        ctx.fill();
        const vertical = roop.linearGradient(0, 0, 0, 180, roop.rgba(0, 0, 0, 0), roop.rgba(0, 0, 0, 255));
        ctx.beginPath();
        ctx.rect(0, 0, 180, 180);
        ctx.fillPaint(vertical);
        ctx.fill();
        for (0..6) |index| {
            const y = @as(f32, @floatFromInt(index)) * 30;
            const start = colorFromHsv(@as(f32, @floatFromInt(index)) / 6, 1, 1, 1);
            const end = colorFromHsv(@as(f32, @floatFromInt(index + 1)) / 6, 1, 1, 1);
            const gradient = roop.linearGradient(188, y, 188, y + 30, rgba(start), rgba(end));
            ctx.beginPath();
            ctx.rect(188, y, 20, 30);
            ctx.fillPaint(gradient);
            ctx.fill();
        }
        const alpha_color = colorFromHsv(self.hue, self.saturation, self.value, 1);
        ctx.beginPath();
        ctx.rect(216, 0, 20, 180);
        ctx.fillColor(roop.rgba(202, 202, 202, 255));
        ctx.fill();
        for (0..18) |index| {
            ctx.beginPath();
            ctx.rect(216 + @as(f32, @floatFromInt(index % 2)) * 10, @as(f32, @floatFromInt(index)) * 10, 10, 10);
            ctx.fillColor(roop.rgba(244, 244, 244, 255));
            ctx.fill();
        }
        const transparent = roop.rgba(alpha_color[0], alpha_color[1], alpha_color[2], 0);
        const alpha_gradient = roop.linearGradient(216, 0, 216, 180, rgba(alpha_color), transparent);
        ctx.beginPath();
        ctx.rect(216, 0, 20, 180);
        ctx.fillPaint(alpha_gradient);
        ctx.fill();
        // A dark outer mark and light inner mark remain visible across the full gamut.
        for ([_]f32{ 4, 2 }) |width| {
            ctx.beginPath();
            ctx.circle(self.saturation * 180, (1 - self.value) * 180, 5);
            ctx.moveTo(186, self.hue * 180);
            ctx.lineTo(210, self.hue * 180);
            ctx.moveTo(214, (1 - self.alpha) * 180);
            ctx.lineTo(238, (1 - self.alpha) * 180);
            ctx.strokeColor(if (width == 4) roop.rgba(56, 66, 79, 255) else roop.rgba(255, 255, 255, 255));
            ctx.strokeWidth(width);
            ctx.stroke();
        }
    }
};

fn colorButton(tree: *ui.Tree, id: anytype, color: session.Color) void {
    if (!tree.beginRect(id, .{ .size = .{ .w = .fill, .h = .fill }, .padding = 1, .bg = style.col.border, .bg_hover = style.col.text })) return;
    defer tree.endRect();
    const click = workspace.to(tree, .from(Msg.figure_color_swatch), color);
    tree.onClick(click, .left);
    tree.trackHover("");
    const child = tree.toElementId(id);
    swatch(tree, .{ "figure.color.swatch", child.extra }, color, .{ .w = .fill, .h = .fill });
}

pub fn render(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, ctx: *roop.Context) void {
    if (!isOpen(tables)) return;
    const panel = bounds(tables, atoms) orelse return;
    const scratch = mem.frameScratchAllocator() catch return;
    var tree = ui.Tree.init(scratch, atoms, 192) catch return;
    const settings = config(tables);
    const channel = targetChannel(settings);
    if (tree.beginRect("figure.color.panel", .{ .size = .{ .w = .fill, .h = .fill }, .padding = popover_padding, .gap = popover_gap, .bg = style.col.sidebar, .border = style.col.accent_border, .border_size = 1, .clip_content = true })) {
        defer tree.endRect();
        chrome.hoverRegion(&tree, "Color popover");
        const object_name = switch (std.enums.fromInt(Scope, settings.scope.*) orelse .defaults) {
            .defaults => "New artwork",
            .selection => "Selected artwork",
            .property => atoms.lookup(settings.label.*) orelse "artwork",
        };
        const title = std.fmt.allocPrint(scratch.allocator, "{s} - {s}", .{ if (channel == .fill) "Fill" else "Stroke", object_name }) catch "Color";
        tree.text("figure.color.title", title, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill, .h = .{ .fixed = text_line } } });
        const channels = scratch.allocator.create(Channels) catch return;
        channels.* = .{ .hue = settings.hue.*, .saturation = settings.saturation.*, .value = settings.value.*, .alpha = settings.alpha.* };
        tree.custom("figure.color.channels", channels, .{ .size = .{ .w = .fill, .h = .{ .fixed = channels_height } } });
        if (tree.beginRect("figure.color.comparison", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = control_height } }, .gap = 6 })) {
            defer tree.endRect();
            tree.text("figure.color.new.label", "New", .{ .font = style.ui_font, .color = style.col.text });
            swatch(&tree, "figure.color.new", settings.current.*, .{ .w = .{ .fixed = 62 }, .h = .fill });
            tree.text("figure.color.old.label", "Old", .{ .font = style.ui_font, .color = style.col.text });
            colorButton(&tree, .{ "figure.color.old", @as(u64, 100) }, settings.original.*);
        }
        if (tree.beginRect("figure.color.fields", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = control_height } }, .gap = 6 })) {
            defer tree.endRect();
            const color = settings.current.*;
            const hex = std.fmt.allocPrint(scratch.allocator, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ color[0], color[1], color[2], color[3] }) catch "Hex RGBA";
            const alpha = std.fmt.allocPrint(scratch.allocator, "Alpha {d:.1}%", .{settings.alpha.* * 100}) catch "Alpha";
            button.render(&tree, "figure.color.hex", workspace.to(&tree, .from(Msg.figure_color_hex), {}), .{ .label = hex, .variant = .text_only, .size = .{ .w = .fill, .h = .fill } });
            button.render(&tree, "figure.color.opacity", workspace.to(&tree, .from(Msg.figure_color_opacity), {}), .{ .label = alpha, .variant = .text_only, .size = .{ .w = .fill, .h = .fill } });
        }
        if (tree.beginRect("figure.color.palette", .{ .size = .{ .w = .fill, .h = .{ .fixed = text_line + 2 * swatch_row_height } } })) {
            defer tree.endRect();
            tree.text("figure.color.palette.label", "Document", .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .fill, .h = .{ .fixed = text_line } } });
            const definition = session.readDefinition(tables, atoms, settings.doc.*) catch null;
            for (0..2) |row| {
                if (!tree.beginRect(.{ "figure.color.palette.row", row }, .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = swatch_row_height } }, .gap = 1 })) continue;
                defer tree.endRect();
                for (0..16) |column| {
                    const index = row * 16 + column;
                    if (definition != null and index < definition.?.palette.len) {
                        colorButton(&tree, .{ "figure.color.palette.item", index }, definition.?.palette[index]);
                    } else tree.rect(.{ "figure.color.palette.empty", index }, .{ .size = .{ .w = .fill, .h = .fill } });
                }
            }
        }
        if (tree.beginRect("figure.color.recents", .{ .size = .{ .w = .fill, .h = .{ .fixed = text_line + swatch_row_height } } })) {
            defer tree.endRect();
            tree.text("figure.color.recents.label", "Recent", .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .fill, .h = .{ .fixed = text_line } } });
            if (tree.beginRect("figure.color.recents.row", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = swatch_row_height } }, .gap = 1 })) {
                defer tree.endRect();
                var recent: [16]?session.Color = @splat(null);
                var rows = drawing.recentColors(tables).read();
                while (rows.next()) |row| if (row.view.index.* < recent.len) {
                    recent[row.view.index.*] = row.view.color.*;
                };
                for (recent, 0..) |color, index| {
                    if (color) |value| colorButton(&tree, .{ "figure.color.recent.item", index + 32 }, value) else tree.rect(.{ "figure.color.recent.empty", index }, .{ .size = .{ .w = .fill, .h = .fill } });
                }
            }
        }
        if (tree.beginRect("figure.color.buttons", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = control_height } }, .gap = 6 })) {
            defer tree.endRect();
            button.render(&tree, "figure.color.sample", workspace.to(&tree, .from(Msg.figure_color_sample), {}), .{ .label = if (settings.sampling.* != 0) "Pick on canvas..." else "Eyedropper", .selected = settings.sampling.* != 0, .variant = .compact, .size = .{ .w = .fill, .h = .fill } });
            button.render(&tree, "figure.color.done", workspace.to(&tree, .from(Msg.figure_color_done), {}), .{ .label = "Done", .variant = .compact, .size = .{ .w = .fill, .h = .fill } });
        }
        const help = if (settings.fallback.* != 0) "Fallback color; gradient stays enabled" else "Drag previews; Esc cancels the drag";
        tree.text("figure.color.help", help, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .fill, .h = .{ .fixed = text_line } } });
    }
    tree.commit(.{
        .root_size = .{ .x = panel.w, .y = panel.h },
        .origin = .{ .x = panel.x - viewport.x, .y = panel.y - viewport.y },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = editor_mod.kHitDepth + 1,
    }, ctx, editor_state.hitRegions(tables, atoms), editor_sequencer.redrawInbox());
    // The controls draw themselves, so these regions above the panel take their presses.
    const press = workspace.to(&tree, .from(Msg.figure_color_down), {});
    for ([_]Part{ .saturation_value, .hue, .alpha }) |part| {
        const rect = controlRect(panel, part);
        _ = editor_state.hitRegions(tables, atoms).insert(.{
            .pos = mesha.math.Vec2f{ .x = rect.x, .y = rect.y },
            .size = mesha.math.Vec2f{ .x = rect.w, .y = rect.h },
            .on_click = press.tag,
            .on_click_inbox = press.inbox,
            .depth = @as(u32, editor_mod.kHitDepth + 2),
        });
    }
}

test "HSV primary colors and alpha" {
    try std.testing.expectEqual(session.Color{ 255, 0, 0, 128 }, colorFromHsv(0, 1, 1, 0.5));
    try std.testing.expectEqual(session.Color{ 0, 255, 0, 255 }, colorFromHsv(1.0 / 3.0, 1, 1, 1));
}
