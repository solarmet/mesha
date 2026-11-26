//! Dragging a numeric field sideways changes its value, as in Blender and Figma; on a vector,
//! the component the drag began on. A press only arms the field: a release without movement
//! still opens it for typing. Past the threshold the field owns a preview gesture, so a whole
//! drag is one undo step and Esc restores it.
const std = @import("std");
const mesha = @import("mesha");
const workspace = @import("workspace.zig");
const sequencer = mesha.sequencer;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;
const plugin = mesha.plugin;
const figure = mesha.figure;
const session = @import("session.zig");
const prompts = @import("prompts.zig");
const gesture = @import("gesture.zig");
const filmstrip = @import("filmstrip.zig");
const drawing = @import("drawing.zig");

const api = figure;

pub const name = "editor_figure_scrub";

/// Pixels of travel that separate a drag from a click.
const threshold: f32 = 3;
const coarse_factor: f32 = 10;
const fine_factor: f32 = 0.1;

const Phase = enum(u8) { idle, armed, dragging };

pub const State = struct {
    phase: u8 = @intFromEnum(Phase.idle),
    target_kind: Atom = session.none,
    id: u32 = 0,
    field: u32 = 0,
    /// A `session.ValuePart`: the component of a vector the drag changes.
    part: u32 = 0,
    press: session.Vec2 = session.zero,
    last: session.Vec2 = session.zero,
    /// Accumulates per move, so changing modifiers mid-drag changes the rate without a jump.
    value: session.Vec2 = session.zero,
    start: session.Vec2 = session.zero,
    /// The last value shown. An unchanged sample must not resubmit: a pose edit equal to the
    /// current state carries no channels, which would reset the preview to the press.
    sent: session.Vec2 = session.zero,
};
pub const View = session.Row(State);

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try session.prepareSingleton(State, mem, atoms, tables, name);
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareSingleton(State, mem, atoms, tables, name);
}

pub fn get(tables: *Table.Registry) View {
    const state_table = tables.findByName(Atom.from(name)).?;
    const row = Table.RowHandle{ .row = 0, .generation = state_table.rowGeneration(0) };
    return state_table.getRow(row, View).?;
}

fn phaseOf(state: View) Phase {
    return @enumFromInt(state.phase.*);
}

pub fn active(scrub_state: View) bool {
    return phaseOf(scrub_state) != .idle;
}

fn fieldOf(state: View) ?prompts.InspectorField {
    const fields = prompts.inspectorFields(state.target_kind.*);
    if (state.field.* >= fields.len) return null;
    return fields[state.field.*];
}

/// The row keeps the pointer until release, wherever the drag travels. Release is always
/// subscribed: a press and release in one input batch share one subscription list, and
/// arriving only after the press would leave the row armed with no button held.
pub fn subscribe(pass: *sequencer.Pass) !void {
    const scrubbing = active(get(pass.frame.tables));
    try workspace.appendInput(pass, .{ .mouse_button_up = .{ .button = .left, .capture = scrubbing } }, .from(workspace.Msg.figure_scrub_up));
    if (!scrubbing) return;
    try workspace.appendInput(pass, .{ .mouse_move = .{ .capture = true } }, .from(workspace.Msg.figure_scrub_move));
    try workspace.appendInput(pass, .{ .key_down = .{ .key = .escape, .capture = true } }, .from(workspace.Msg.figure_gesture_cancel));
}

pub fn arm(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, item: session.ItemEvent, press: session.Vec2) !void {
    const state = get(tables);
    const fields = prompts.inspectorFields(item.kind);
    const field = fields[item.field];
    const scratch = try mem.frameScratchAllocator();
    const current = try prompts.valueText(scratch.allocator, tables, atoms, item.kind, item.id, field.name);
    const start = try prompts.parseScrubValue(field.scrub.?, current);
    state.phase.* = @intFromEnum(Phase.armed);
    state.target_kind.* = item.kind;
    state.id.* = item.id;
    state.field.* = item.field;
    state.part.* = @intFromEnum(item.part);
    state.press.* = press;
    state.last.* = press;
    state.value.* = start;
    state.start.* = start;
    state.sent.* = start;
}

/// Editor settings rather than document data: they change directly, with no gesture or undo.
fn editsSettings(target_kind: Atom) bool {
    return target_kind == prompts.defaults_kind or target_kind == prompts.tool_option_kind;
}

/// Writes a setting through `text`, so tool options keep the validation typing has.
fn applySetting(settings: drawing.ConfigView, state: View, number: f32, text: []const u8) !void {
    if (state.target_kind.* == prompts.defaults_kind) {
        settings.stroke_width.* = number;
        return;
    }
    const field_index: u32 = state.field.*;
    const option = std.enums.values(drawing.ToolOption)[field_index];
    try option.apply(settings, text);
}

fn begin(editor: session.View, gesture_state: gesture.View, state: View, pointer: session.Vec2) !void {
    state.phase.* = @intFromEnum(Phase.dragging);
    state.last.* = pointer;
    if (editsSettings(state.target_kind.*)) return;
    try gesture.begin(gesture_state, .{ .kind = .scrub, .doc = editor.doc.*, .pointer = .{ .point = pointer, .screen = pointer, .modifiers = 0 } });
}

pub fn move(state: View, editor: session.View, gesture_state: gesture.View, draw_settings: drawing.ConfigView, event: input.MouseMoveMsg) !void {
    const phase = phaseOf(state);
    if (phase == .idle) return;
    const pointer = session.Vec2{ .x = event.x, .y = event.y };
    if (phase == .armed) {
        const dx = pointer.x - state.press.x;
        const dy = pointer.y - state.press.y;
        if (dx * dx + dy * dy < threshold * threshold) return;
        begin(editor, gesture_state, state, pointer) catch |err| {
            state.phase.* = @intFromEnum(Phase.idle);
            return err;
        };
        return;
    }
    const field = fieldOf(state) orelse return;
    const settings = field.scrub.?;
    var rate = settings.per_pixel;
    if (event.modifiers.shift) rate *= coarse_factor;
    if (event.modifiers.control) rate *= fine_factor;
    const travel = (pointer.x - state.last.x) * rate;
    const scrubs_y = settings.axes == .two and state.part.* == @intFromEnum(session.ValuePart.y);
    if (scrubs_y) {
        state.value.y = std.math.clamp(state.value.y + travel, settings.min, settings.max);
    } else {
        state.value.x = std.math.clamp(state.value.x + travel, settings.min, settings.max);
    }
    state.last.* = pointer;
    if (editsSettings(state.target_kind.*)) {
        var buffer: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "{d:.[1]}", .{ state.value.x, settings.decimals });
        try applySetting(draw_settings, state, state.value.x, text);
        return;
    }
    _ = gesture.record(gesture_state, .{ .point = pointer, .screen = pointer, .modifiers = 0 });
}

/// The clicked row when the press stayed a click, whose text field then opens.
pub fn release(state: View, gesture_state: gesture.View) ?session.ItemEvent {
    const phase = phaseOf(state);
    state.phase.* = @intFromEnum(Phase.idle);
    if (phase == .armed) return .{ .kind = state.target_kind.*, .id = state.id.*, .field = @intCast(state.field.*), .part = @enumFromInt(state.part.*) };
    if (phase == .dragging and !editsSettings(state.target_kind.*)) _ = gesture.end(gesture_state, .commit);
    return null;
}

/// Esc, or anything else that interrupts the drag. Returns whether a scrub was in progress.
pub fn cancel(state: View, draw_settings: drawing.ConfigView, gesture_state: gesture.View) bool {
    const phase = phaseOf(state);
    if (phase == .idle) return false;
    state.phase.* = @intFromEnum(Phase.idle);
    if (phase == .armed) return true;
    if (editsSettings(state.target_kind.*)) {
        // The exact starting value, not one rounded to the row's scrub precision.
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}", .{state.start.x}) catch unreachable;
        applySetting(draw_settings, state, state.start.x, text) catch unreachable;
    } else if (gesture.activeKind(gesture_state) == .scrub) {
        _ = gesture.end(gesture_state, .cancel);
    }
    return true;
}

/// Goes through the same command as typing the value, so its validation holds here too.
pub fn preview(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const state = get(tables);
    const field = fieldOf(state) orelse return error.MissingField;
    const settings = field.scrub.?;
    const scratch = try tables.memory.frameScratchAllocator();
    const text = try prompts.formatScrubValue(scratch.allocator, settings, state.value.*);
    const sent = try prompts.formatScrubValue(scratch.allocator, settings, state.sent.*);
    if (std.mem.eql(u8, text, sent)) return;
    const payload = try prompts.scrubCommand(tables, atoms, state.target_kind.*, state.id.*, field, text);
    const edit: api.PreviewEdit = switch (payload) {
        .set_bone => |request| .{ .set_bone = request },
        .set_shape => |request| .{ .set_shape = request },
        .set_layer => |request| .{ .set_layer = request },
        .set_pose_channels => |request| .{ .set_pose_channels = request },
        else => return error.InvalidField,
    };
    // In Animate, a look's value scrubs the working pose rather than the definition.
    const edits = try filmstrip.animated(tables, atoms, edit);
    try gesture.openTransaction(tables, atoms, names.property_scrub);
    try gesture.submitPreview(tables, atoms, .absolute, edits.slice());
    state.sent.* = state.value.*;
}
