//! Attention animations for the figure editor. Only meaningful changes move: the active mode or
//! tool changing, a new error or warning, and a modal state the next key depends on. Each sync
//! compares editor state against what was last announced, so every path into a change animates
//! alike, and presentation only reads the cells Time tweens.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const text_editor = mesha.text_editor;
const Atom = mesha.Atom;
const Table = mesha.Table;
const time = mesha.time;
const sequencer = mesha.sequencer;
const figure = mesha.figure;
const session = @import("session.zig");
const chrome = @import("chrome.zig");
const drawing = @import("drawing.zig");
const status_bar = @import("../status_bar.zig");
const style = @import("../ui/style.zig");

const glide_seconds: f32 = 0.14;
const glide_easing = time.Easing{ .curve = .cubic, .direction = .out };
const alert_seconds: f32 = 0.45;
const alert_easing = time.Easing{ .curve = .quad, .direction = .out };
/// How far an alert's color reaches into a surface at full energy. Text in the same color sits
/// on that surface, so this has to stay low enough to read it at the peak.
const tint_strength: f32 = 0.3;

pub const Tone = enum(u8) {
    none,
    active,
    warning,
    failure,

    pub fn color(tone: Tone) ui.Color {
        return switch (tone) {
            .none => style.col.text_dim,
            .active => style.col.accent_bright,
            .warning => style.col.warning,
            .failure => style.col.danger,
        };
    }
};

fn toneOf(stored: u8) Tone {
    return std.enums.fromInt(Tone, stored) orelse .none;
}

fn mix(from: ui.Color, to: ui.Color, amount: f32) ui.Color {
    return .{
        .r = from.r + (to.r - from.r) * amount,
        .g = from.g + (to.g - from.g) * amount,
        .b = from.b + (to.b - from.b) * amount,
        .a = from.a + (to.a - from.a) * amount,
    };
}

fn tint(surface: ui.Color, tone: Tone, energy: f32) ui.Color {
    if (tone == .none) return surface;
    return mix(surface, tone.color(), energy * tint_strength);
}

fn cellTarget(tables: *Table.Registry, comptime field: []const u8) time.AnimationTarget {
    const table_name = Atom.from(session.motion_name);
    const handle = tables.findHandleByName(table_name).?;
    const motion_table = tables.get(handle).?;
    return .{
        .table = handle,
        .row = .{ .row = 0, .generation = motion_table.rowGeneration(0) },
        .field = Atom.from(field),
    };
}

/// Each step of a glide or a played tween, for the figure stage that draws the cell.
/// The tag of the steps the view hears.
pub const Msg = enum(u64) {
    figure_motion_update = Atom.from("figure_motion_update").value(),
    _,
};

/// The view's inbox hears each step, under `figure_motion_update`, so the stage draws again.
fn replyTo() sequencer.ReplyTo {
    return sequencer.ReplyTo.of(@import("view.zig").system(), .from(Msg.figure_motion_update));
}

/// The time system's request rows, which motion appends to.
pub const RequestView = struct { op: *time.CommandOp };
pub const Requests = sequencer.Rows(RequestView);

fn animate(requests: Requests, request: time.Animate) !void {
    try time.appendAnimate(requests.table, request);
}

/// Starts from the cell's current value, so a change mid-glide turns around where it is.
fn glide(tables: *Table.Registry, requests: Requests, comptime field: []const u8, to: f32) !void {
    const target = cellTarget(tables, field);
    try animate(requests, .{
        .target = target,
        .to = .{ .f32 = to },
        .duration = glide_seconds,
        .easing = glide_easing,
        .reply = replyTo(),
    });
}

fn snap(tables: *Table.Registry, requests: Requests, comptime field: []const u8, cell: *f32, to: f32) !void {
    const target = cellTarget(tables, field);
    _ = try requests.insert(.{ .op = time.CommandOp.cancel_animation, .target = target });
    cell.* = to;
}

fn syncMode(tables: *Table.Registry, requests: Requests) !void {
    const state = session.motion(tables);
    const mode = session.get(tables).mode.*;
    if (state.mode.* == mode) return;
    const first_sync = state.mode.* == session.none;
    state.mode.* = mode;
    const slot = chrome.modeSlot(mode) orelse return;
    // Nothing can be running yet, so there is no animation to cancel.
    if (first_sync) {
        state.mode_slot.* = slot;
        return;
    }
    try glide(tables, requests, "mode_slot", slot);
}

/// Tools only travel within one row: another mode's dock holds different tools, so there is
/// nothing on screen to leave from.
fn syncTool(tables: *Table.Registry, requests: Requests) !void {
    const state = session.motion(tables);
    const editor = session.get(tables);
    const first_sync = state.tool_row.* == session.none;
    const same_row = state.tool_row.* == editor.mode.*;
    if (same_row and state.tool.* == editor.tool.*) return;
    state.tool_row.* = editor.mode.*;
    state.tool.* = editor.tool.*;
    const left = chrome.selectedToolLeft(editor.mode.*, editor.tool.*) orelse return;
    if (first_sync) {
        state.tool_left.* = left;
        return;
    }
    if (!same_row) {
        try snap(tables, requests, "tool_left", state.tool_left, left);
        return;
    }
    try glide(tables, requests, "tool_left", left);
}

/// Writes the start value now because this frame's render runs before Time's first step.
fn play(tables: *Table.Registry, requests: Requests, comptime field: []const u8, cell: *f32, from: f32, to: f32, duration: f32, easing: time.Easing) !void {
    cell.* = from;
    const target = cellTarget(tables, field);
    try animate(requests, .{
        .target = target,
        .from = .{ .f32 = from },
        .to = .{ .f32 = to },
        .duration = duration,
        .easing = easing,
        .reply = replyTo(),
    });
}

fn textHash(bytes: []const u8) u64 {
    const shown = session.text(bytes);
    if (shown.len == 0) return 0;
    return std.hash.Wyhash.hash(0, shown);
}

/// What one of rendering's parts failed with, as it is told; `stored` is the error's integer.
fn tellRenderFailure(tables: *Table.Registry, part: []const u8, stored: u32) void {
    if (stored == 0) return;
    const failure = @errorFromInt(@as(std.meta.Int(.unsigned, @bitSizeOf(anyerror)), @intCast(stored)));
    var line_buffer: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "{s}: {s}", .{ part, @errorName(failure) }) catch return;
    text_editor.message(tables.memory, tables, line);
}

/// Tells the person, in `*Messages*` and so on the minibuffer's line, each error, warning and
/// piece of information as it first shows.
fn syncFeedback(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const state = session.motion(tables);
    const editor = session.get(tables);
    const context = session.figureContext(tables, atoms);
    const diagnostics = figure.definitionDiagnostics(context, editor.doc.*) catch figure.DefinitionDiagnostics{};
    const status_hash = textHash(session.table(tables).textOf(editor.status.*));
    const definition_error_hash = textHash(diagnostics.error_text);
    const error_hash = status_hash ^ definition_error_hash;
    const warning_hash = textHash(diagnostics.warning_text);
    const information_hash = textHash(session.feedbackTable(tables).textOf(session.feedback(tables).information.*));

    const new_error = error_hash != 0 and (error_hash != state.seen_error.* or state.rejection_pending.* != 0);
    state.rejection_pending.* = 0;
    const new_warning = warning_hash != 0 and warning_hash != state.seen_warning.*;
    const new_information = information_hash != 0 and information_hash != state.seen_information.*;
    const memory = tables.memory;
    if (new_error) {
        const status = session.text(session.table(tables).textOf(editor.status.*));
        if (status.len != 0) text_editor.message(memory, tables, status);
        const definition_error = session.text(diagnostics.error_text);
        if (definition_error.len != 0) text_editor.message(memory, tables, definition_error);
    }
    if (new_warning) text_editor.message(memory, tables, session.text(diagnostics.warning_text));
    if (new_information) {
        const information = session.text(session.feedbackTable(tables).textOf(session.feedback(tables).information.*));
        text_editor.message(memory, tables, information);
    }
    state.seen_error.* = error_hash;
    state.seen_warning.* = warning_hash;
    state.seen_information.* = information_hash;

    // What rendering found last frame, told when it changes.
    const feedback = session.feedback(tables);
    const rendering = [_]u32{
        feedback.render_artwork_error.*,
        feedback.render_evaluation_error.*,
        feedback.render_onion_error.*,
        feedback.render_weights_error.*,
        feedback.render_overlay_limited.*,
    };
    const nothing_found = std.mem.allEqual(u32, &rendering, 0);
    const rendering_hash: u64 = if (nothing_found) 0 else std.hash.Wyhash.hash(0, std.mem.asBytes(&rendering));
    const new_rendering = rendering_hash != 0 and rendering_hash != state.seen_rendering.*;
    state.seen_rendering.* = rendering_hash;
    if (!new_rendering) return;
    tellRenderFailure(tables, "Artwork", feedback.render_artwork_error.*);
    tellRenderFailure(tables, "Evaluation", feedback.render_evaluation_error.*);
    tellRenderFailure(tables, "Onion", feedback.render_onion_error.*);
    tellRenderFailure(tables, "Weights", feedback.render_weights_error.*);
    if (feedback.render_overlay_limited.* != 0) text_editor.message(memory, tables, "Overlay budget reached; zoom in to inspect.");
}

/// What the status bar's hint is asking of the next key, when getting it wrong matters.
fn statusTone(draw_settings: drawing.ConfigView, editor: session.View) Tone {
    if (draw_settings.pending_delete_layer.* != 0) return .warning;
    if (editor.reparent_active.* != 0) return .active;
    return .none;
}

fn syncStatus(tables: *Table.Registry, requests: Requests) !void {
    const state = session.motion(tables);
    const tone = statusTone(drawing.config(tables), session.get(tables));
    if (@intFromEnum(tone) == state.status_tone.*) return;
    state.status_tone.* = @intFromEnum(tone);
    if (tone == .none) return;
    try play(tables, requests, "status_energy", state.status_energy, 1, 0, alert_seconds, alert_easing);
}

pub fn sync(tables: *Table.Registry, atoms: *Atom.Registry, requests: Requests) !void {
    try syncMode(tables, requests);
    try syncTool(tables, requests);
    syncFeedback(tables, atoms);
    try syncStatus(tables, requests);
}

/// A refused action often repeats the error already showing, which still deserves an answer.
pub fn announceRejection(motion_view: session.MotionView) void {
    motion_view.rejection_pending.* = 1;
}

/// The color stays once the flash has decayed, for as long as the state does.
pub fn statusLook(state: session.MotionView) status_bar.Look {
    const tone = toneOf(state.status_tone.*);
    return .{
        .fill = tint(style.col.sidebar, tone, state.status_energy.*),
        .hint = tone.color(),
    };
}
