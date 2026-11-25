//! Acknowledged pointer-gesture ownership. Absolute tools replace their latest
//! sample and recompute from the press origin; Weight owns an ordered sample FIFO
//! and publishes cumulative batches. One flush runs per update when no request is
//! in flight. Release drains pending samples before one commit; cancellation and
//! rejection drain admitted work before cancelling the owned transaction, and an answer a drag
//! goes on from (`asks.awaited`) is owed as a preview is. While the host is asked what lies under
//! a press (`asks.zig`), the canvas's later input is held here and applied after the answer, in
//! the order it came.
const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;
const figure = mesha.figure;
const session = @import("session.zig");
const asks = @import("asks.zig");
const watches = @import("watches.zig");
const prompts = @import("prompts.zig");
const transport = @import("commands.zig");
const workspace = @import("workspace.zig");
const drawing = @import("drawing.zig");
const pose = @import("pose.zig");
const weight = @import("weight.zig");
const color_picker = @import("color_picker.zig");
const scrub = @import("scrub.zig");
const sequencer = mesha.sequencer;

// ---- the system -----------------------------------------------------------------------------

/// Sends what the frame's drags sampled, after every system that samples: one preview while
/// none is in flight, then the commit or cancel once the drag has ended and nothing is owed.
/// It claims no messages; the canvas samples, and the host's results reach it through the
/// document. Its inbox hears the answers to the solves an Auto IK drag asks (`pose.zig`).
pub fn system() sequencer.System {
    return .{
        .name = "figure_gesture",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claimsNothing,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_gesture.take_answers", .run = takeAnswers },
            .{ .name = "figure_gesture.flush", .run = flushKernel },
        },
    };
}

fn claimsNothing(tag: Atom) bool {
    _ = tag;
    return false;
}

/// Hidden, a gesture still drains and ends, as one cancelled by leaving the workspace.
fn active(frame: *const sequencer.Frame) bool {
    if (workspace.shown(frame)) return true;
    return phaseOf(get(frame.tables)) != .idle;
}

/// Nothing while idle. During a drag, the editor's state, the rows the tool samples into, and
/// the requests its previews send.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    // Answers free their questions' rows, and a drag asks again.
    if (frame.messages.len != 0) groups.declareAsking(&result, frame.tables);
    if (phaseOf(get(frame.tables)) == .idle) return result;
    result.writeAll(&groups.state);
    groups.declareSampling(&result, frame.tables);
    groups.declareAsking(&result, frame.tables);
    return result;
}

/// The answers to the solves an Auto IK drag asked, each going on with the drag before the frame
/// flushes it. A solve that fails ends the drag as a preview that fails does.
fn takeAnswers(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const asked = asks.rows(tables);
    for (pass.frame.messages) |received| {
        const document = session.get(tables).doc.*;
        const answer = asks.take(asked, document, received) orelse continue;
        switch (answer.purpose) {
            .pose_press => pose.pressAnswered(tables, answer),
            .pose_drag => pose.dragAnswered(tables, atoms, answer) catch |err| switch (err) {
                // Admission pressure keeps the sample pending for a later flush to ask again.
                error.CapacityExceeded, error.Busy => {},
                else => {
                    const session_table = session.table(tables);
                    const state = get(tables);
                    const editor = session.get(tables);
                    const feedback = session.feedback(tables);
                    reject(session_table, state, editor, feedback, err);
                },
            },
            else => {},
        }
    }
}

fn flushKernel(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    if (phaseOf(get(tables)) == .idle) return;
    update(tables, atoms);
}

const api = figure;

pub const name = "editor_figure_gesture";

pub const Phase = enum(u8) {
    idle,
    /// Pointer held: absolute tools replace the latest sample; strokes enqueue samples.
    sampling,
    /// No new samples. A commit still flushes its final sample; every intent drains
    /// in-flight results before the terminal request.
    draining,
    /// The terminal commit or cancel was submitted; its result returns the owner to idle.
    awaiting_terminal,
};

/// How the gesture ends. `failure` is a cancellation caused by a rejected request.
pub const Intent = enum(u8) { none, commit, cancel, failure };

/// Selects the tool and its absolute-preview or cumulative-stroke policy.
pub const Kind = enum(u8) { none, move_shapes, bone_root, bone_tip, points, rotate, scale, pose, weight, duplicate_shapes, color, scrub, erase };

pub const End = enum { commit, cancel };

/// Bit layout shared with `session.Data.gesture_modifiers`.
pub const Modifiers = struct {
    pub const shift: u8 = 1;
    pub const alt: u8 = 2;
    pub const control: u8 = 4;
};

/// Enums are stored as u8 like other editor tables; read them through the
/// typed accessors below.
pub const State = struct {
    phase: u8 = @intFromEnum(Phase.idle),
    kind: u8 = @intFromEnum(Kind.none),
    intent: u8 = @intFromEnum(Intent.none),
    doc: Atom = session.none,
    origin: session.Vec2 = session.zero,
    origin_screen: session.Vec2 = session.zero,
    latest: session.Vec2 = session.zero,
    latest_screen: session.Vec2 = session.zero,
    modifiers: u8 = 0,
    sample_pending: u8 = 0,
    in_flight: u32 = 0,
    preview_request: u32 = 0,
    terminal_request: u32 = 0,
    begin_request: u32 = 0,
    transaction_owned: u8 = 0,
    duplicate_first: u32 = 0,
    duplicate_count: u32 = 0,
};
pub const View = session.Row(State);

/// One pointer observation in document and screen space.
pub const Pointer = struct {
    point: session.Vec2,
    screen: session.Vec2,
    modifiers: u8,
};

pub const Press = struct {
    kind: Kind,
    doc: Atom,
    pointer: Pointer,
};

/// Flush input: every preview is computed from the press origin and the latest sample.
pub const Drag = struct {
    doc: Atom,
    origin: session.Vec2,
    origin_screen: session.Vec2,
    latest: Pointer,
};

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
    const table_name = Atom.from(name);
    const state_table = tables.findByName(table_name).?;
    const row = Table.RowHandle{ .row = 0, .generation = state_table.rowGeneration(0) };
    return state_table.getRow(row, View).?;
}

pub fn phaseOf(state: View) Phase {
    return @enumFromInt(state.phase.*);
}

pub fn kindOf(state: View) Kind {
    return @enumFromInt(state.kind.*);
}

pub fn intentOf(state: View) Intent {
    return @enumFromInt(state.intent.*);
}

/// Ownership starts at press, before the first preview opens a runtime transaction.
pub fn busy(state: View) bool {
    return phaseOf(state) != .idle;
}

/// The owned drag kind, or `.none` while idle.
pub fn activeKind(state: View) Kind {
    return kindOf(state);
}

pub fn modifierBits(modifiers: input.ModifierState) u8 {
    var bits: u8 = 0;
    if (modifiers.shift) bits |= Modifiers.shift;
    if (modifiers.alt) bits |= Modifiers.alt;
    if (modifiers.control) bits |= Modifiers.control;
    return bits;
}

/// Admits a drag at press. Nothing is submitted until a flush needs a preview.
pub fn begin(state: View, press: Press) !void {
    if (phaseOf(state) != .idle) return error.GestureSettling;
    state.phase.* = @intFromEnum(Phase.sampling);
    state.kind.* = @intFromEnum(press.kind);
    state.intent.* = @intFromEnum(Intent.none);
    state.doc.* = press.doc;
    state.origin.* = press.pointer.point;
    state.origin_screen.* = press.pointer.screen;
    state.latest.* = press.pointer.point;
    state.latest_screen.* = press.pointer.screen;
    state.modifiers.* = press.pointer.modifiers;
    state.sample_pending.* = 0;
    state.in_flight.* = 0;
    state.preview_request.* = 0;
    state.terminal_request.* = 0;
    state.begin_request.* = 0;
    state.transaction_owned.* = 0;
    state.duplicate_first.* = 0;
    state.duplicate_count.* = 0;
}

/// Pointer Msgs only replace the latest sample. Returns whether a gesture owns the pointer.
pub fn record(state: View, pointer: Pointer) bool {
    const phase = phaseOf(state);
    if (phase == .idle or kindOf(state) == .weight) return false;
    if (phase != .sampling) return true;
    state.latest.* = pointer.point;
    state.latest_screen.* = pointer.screen;
    state.modifiers.* = pointer.modifiers;
    state.sample_pending.* = 1;
    return true;
}

/// Stops sampling. A commit keeps the final sample; a cancel drops it. A submitted
/// terminal never changes, and a commit never overrides a cancel or failure.
pub fn end(state: View, ending: End) bool {
    const phase = phaseOf(state);
    if (phase == .idle) return false;
    if (phase == .awaiting_terminal) return true;
    const intent = intentOf(state);
    switch (ending) {
        .commit => {
            if (intent == .none) state.intent.* = @intFromEnum(Intent.commit);
        },
        .cancel => {
            if (intent != .failure) state.intent.* = @intFromEnum(Intent.cancel);
            state.sample_pending.* = 0;
        },
    }
    state.phase.* = @intFromEnum(Phase.draining);
    return true;
}

/// Once per update pump, from workspace.sync: at most one preview flush, then settlement.
pub fn update(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const state = get(tables);
    const phase = phaseOf(state);
    const intent = intentOf(state);
    const accepts_preview = phase == .sampling or (phase == .draining and intent == .commit);
    // A solve the drag goes on from is owed as a preview is.
    const asked = asks.rows(tables);
    const answer_owed = asks.awaited(asked);
    const sample_ready = state.sample_pending.* != 0 and state.in_flight.* == 0 and !answer_owed;
    if (accepts_preview and sample_ready) flush(tables, atoms);
    settle(tables, atoms);
}

fn flush(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const state = get(tables);
    const drag = Drag{
        .doc = state.doc.*,
        .origin = state.origin.*,
        .origin_screen = state.origin_screen.*,
        .latest = .{
            .point = state.latest.*,
            .screen = state.latest_screen.*,
            .modifiers = state.modifiers.*,
        },
    };
    const kind = kindOf(state);
    preview(tables, atoms, kind, drag) catch |err| {
        // Admission pressure keeps the latest sample for a later pump; requests
        // admitted before the error stay tracked and are waited for.
        if (err == error.CapacityExceeded or err == error.Busy) return;
        reject(session.table(tables), get(tables), session.get(tables), session.feedback(tables), err);
        return;
    };
    // The stroke callback retains pending work when only a FIFO prefix fitted.
    if (kind != .weight) state.sample_pending.* = 0;
}

fn preview(tables: *Table.Registry, atoms: *Atom.Registry, kind: Kind, drag: Drag) !void {
    switch (kind) {
        .none => {},
        .move_shapes => try workspace.previewMoveShapes(tables, atoms, drag, .move),
        .duplicate_shapes => try workspace.previewMoveShapes(tables, atoms, drag, .duplicate),
        .bone_root => try workspace.previewJoint(tables, atoms, drag, .root),
        .bone_tip => try workspace.previewJoint(tables, atoms, drag, .tip),
        .points => try drawing.previewPoints(tables, atoms, drag),
        .rotate => try drawing.previewTransform(tables, atoms, drag, .rotate),
        .scale => try drawing.previewTransform(tables, atoms, drag, .scale),
        .pose => try pose.previewDrag(tables, atoms, drag),
        .weight => try weight.flushStroke(tables, atoms),
        .color => try color_picker.previewEdit(tables, atoms),
        .scrub => try scrub.preview(tables, atoms),
        .erase => try drawing.previewEraser(tables, atoms, drag),
    }
}

/// Submits the single terminal once nothing is owed, no answer a drag goes on from among it
/// (`asks.awaited`); end paths may call it directly.
pub fn settle(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const state = get(tables);
    if (phaseOf(state) != .draining) return;
    if (state.in_flight.* != 0 or state.sample_pending.* != 0) return;
    const asked = asks.rows(tables);
    if (asks.awaited(asked)) return;
    const editor = session.get(tables);
    if (state.transaction_owned.* != 0) {
        const doc = state.doc.*;
        const terminal: api.Payload = switch (intentOf(state)) {
            .commit => .{ .commit = .{ .doc = doc } },
            .none, .cancel, .failure => .{ .cancel = .{ .doc = doc } },
        };
        const context = session.figureContext(tables, atoms);
        const request = transport.submit(context, terminal) catch |err| {
            const reason = @errorName(err);
            if (intentOf(state) != .failure) prompts.status(session.table(tables), session.get(tables), session.feedback(tables), reason);
            return;
        };
        state.terminal_request.* = request;
        state.phase.* = @intFromEnum(Phase.awaiting_terminal);
    } else {
        // No preview opened a transaction, so there is nothing to terminate.
        becomeIdle(session.table(tables), session.get(tables), weight.stroke(tables), weight.strokeTargets(tables), weight.strokeSamples(tables), weight.strokeShapes(tables), weight.strokeLocks(tables), color_picker.config(tables), drawing.config(tables), drawing.recentColors(tables), session.feedback(tables), state);
    }
    editor.gesture_active.* = 0;
}

/// Opens the runtime transaction with the first preview; later previews reuse it.
pub fn openTransaction(tables: *Table.Registry, atoms: *Atom.Registry, label: Atom) !void {
    const state = get(tables);
    if (state.transaction_owned.* != 0) return;
    if (state.begin_request.* != 0) return error.Busy;
    const context = session.figureContext(tables, atoms);
    const request = try transport.submit(context, .{ .begin = .{ .doc = state.doc.*, .label = label, .kind = .gesture } });
    state.begin_request.* = request;
    state.in_flight.* += 1;
    return error.Busy;
}

/// One envelope owns every edit in the flush and its single correlated result.
pub fn submitPreview(tables: *Table.Registry, atoms: *Atom.Registry, mode: api.PreviewMode, edits: []const api.PreviewEdit) !void {
    const state = get(tables);
    if (state.in_flight.* != 0) return error.Busy;
    const context = session.figureContext(tables, atoms);
    const payload = api.Payload{ .preview = .{ .doc = state.doc.*, .mode = mode, .edits = edits } };
    state.preview_request.* = try transport.submit(context, payload);
    state.in_flight.* = 1;
}

/// The kind owning a request, or `.none`; used for result attribution.
pub fn requestOwner(state: View, doc: Atom, request: u32) Kind {
    if (phaseOf(state) == .idle or doc != state.doc.* or request == 0) return .none;
    if (request == state.terminal_request.* or request == state.begin_request.*) return kindOf(state);
    if (request == state.preview_request.*) return kindOf(state);
    return .none;
}

/// Correlates by gesture document and request id; unrelated results are ignored.
pub fn reconcileResult(tables: *Table.Registry, atoms: *Atom.Registry, metadata: session.Metadata, failed: bool) void {
    const state = get(tables);
    const phase = phaseOf(state);
    if (phase == .idle or metadata.doc != state.doc.* or metadata.request == 0) return;
    if (metadata.request == state.begin_request.*) {
        state.begin_request.* = 0;
        state.in_flight.* -= 1;
        if (failed) {
            fail(state);
        } else {
            state.transaction_owned.* = 1;
            session.get(tables).tx_active.* = 1;
        }
        return;
    }
    if (phase == .awaiting_terminal and metadata.request == state.terminal_request.*) {
        reconcileTerminal(tables, atoms, state, failed);
        return;
    }
    if (metadata.request == state.preview_request.*) {
        state.preview_request.* = 0;
        state.in_flight.* = 0;
        if (failed) fail(state);
    }
}

fn reconcileTerminal(tables: *Table.Registry, atoms: *Atom.Registry, state: View, failed: bool) void {
    const editor = session.get(tables);
    state.terminal_request.* = 0;
    const info = session.definitionInfo(tables, atoms, state.doc.*);
    const transaction_open = if (info) |definition| definition.transaction_open else false;
    if (failed and transaction_open) {
        // A rejected commit can leave the runtime transaction open. Drain it
        // through cancellation; never pretend a failed terminal succeeded.
        state.intent.* = @intFromEnum(Intent.failure);
        state.phase.* = @intFromEnum(Phase.draining);
        editor.tx_active.* = 1;
        return;
    }
    editor.tx_active.* = 0;
    state.transaction_owned.* = 0;
    if (failed) state.intent.* = @intFromEnum(Intent.failure);
    becomeIdle(session.table(tables), session.get(tables), weight.stroke(tables), weight.strokeTargets(tables), weight.strokeSamples(tables), weight.strokeShapes(tables), weight.strokeLocks(tables), color_picker.config(tables), drawing.config(tables), drawing.recentColors(tables), session.feedback(tables), state);
}

/// A local sampling/flush failure cannot commit a partial gesture.
pub fn reject(session_table: *Table, state: View, editor: session.View, feedback: session.FeedbackView, err: anyerror) void {
    fail(state);
    const reason = @errorName(err);
    prompts.status(session_table, editor, feedback, reason);
}

/// A rejected or uncomputable preview ends the gesture as a cancellation.
fn fail(state: View) void {
    state.intent.* = @intFromEnum(Intent.failure);
    state.sample_pending.* = 0;
    if (phaseOf(state) == .sampling) state.phase.* = @intFromEnum(Phase.draining);
}

// ---- input held behind a question -----------------------------------------------------------

/// The canvas's input held while a question decides what an earlier press does
/// (`asks.holdsFor`), a row each, applied after the answer in the order it arrived.
pub const held_name = "editor_figure_gesture_held";
const held_capacity = 1024;
/// A held message, as the canvas received it.
const Held = struct {
    /// Its place in arrival order among the rows held.
    order: u32 = 0,
    tag: Atom = session.none,
    /// Its `HeldKind`.
    kind: u8 = 0,
    payload: Table.Bytes = .{},
    user_data: Table.Bytes = .{},
    /// A press's, movement's or release's place in the document when it arrived, so a view that
    /// changes before it is applied does not move it.
    point: session.Vec2 = session.zero,
    has_point: u8 = 0,
};
pub const HeldRows = sequencer.Rows(session.Row(Held));
pub fn heldInput(tables: *Table.Registry) HeldRows {
    return .of(tables.findByName(Atom.from(held_name)).?);
}

/// How a message the canvas takes waits behind a question (`workspace.heldKind` decides).
pub const HeldKind = enum(u8) {
    /// Never: it cancels what waits, or it is not input.
    never,
    /// The pointer's movement, which an eraser sample's question lets through.
    movement,
    /// A press or a release, which ends or starts a gesture.
    end,
    /// Any other input the canvas takes: a key's action, the wheel, a click on its chrome.
    other,
};

/// Whether a message of `kind` waits: one that arrives after another that waits, or while a
/// question in flight holds it back (`holding`).
pub fn holds(held: HeldRows, holding: asks.Holds, kind: HeldKind) bool {
    if (kind == .never) return false;
    if (held.count() != 0) return true;
    return waits(holding, kind);
}

/// Whether a question in flight holds back a message of `kind`.
fn waits(holding: asks.Holds, kind: HeldKind) bool {
    return switch (holding) {
        .nothing => false,
        .ends => kind == .end,
        .everything => kind != .never,
    };
}

/// Holds `received`, of `kind`, after the messages already held, with the document point of a
/// press, movement or release.
pub fn hold(held: HeldRows, received: sequencer.Message, kind: HeldKind, point: ?session.Vec2) !void {
    var order: u32 = 0;
    var entries = held.read();
    while (entries.next()) |entry| order = @max(order, entry.view.order.* + 1);
    const payload = try copyBytes(held.table, received.payload);
    const user_data = try copyBytes(held.table, received.user_data);
    _ = try held.insert(Held{
        .order = order,
        .tag = received.tag,
        .kind = @intFromEnum(kind),
        .payload = payload,
        .user_data = user_data,
        .point = point orelse session.zero,
        .has_point = @intFromBool(point != null),
    });
}

fn copyBytes(table: *Table, bytes: []const u8) !Table.Bytes {
    if (bytes.len == 0) return .{};
    const payload = try table.appendPayload(bytes, Table.bytes_alignment);
    return .{ .payload = payload };
}

/// A held message given back as the canvas received it, its bytes in the allocator `release`
/// was given.
pub const Released = struct {
    message: sequencer.Message,
    /// The document point it held; null for a message that is not the pointer's.
    point: ?session.Vec2,
};

/// Takes the oldest held message off the rows, unless a question still holds it (`holding`):
/// its bytes are copied into `allocator`, aligned as an inbox aligns them.
pub fn release(held: HeldRows, holding: asks.Holds, allocator: std.mem.Allocator) !?Released {
    var oldest: ?Table.RowHandle = null;
    var oldest_order: u32 = 0;
    var entries = held.read();
    while (entries.next()) |entry| {
        const earlier = oldest == null or entry.view.order.* < oldest_order;
        if (!earlier) continue;
        oldest = entry.handle;
        oldest_order = entry.view.order.*;
    }
    const handle = oldest orelse return null;
    const found = held.readRow(handle) orelse return null;
    const tag = found.tag.*;
    const kind = std.enums.fromInt(HeldKind, found.kind.*) orelse .other;
    if (waits(holding, kind)) return null;
    const payload = try copyOut(held.table, found.payload.*, allocator);
    const user_data = try copyOut(held.table, found.user_data.*, allocator);
    const point: ?session.Vec2 = if (found.has_point.* != 0) found.point.* else null;
    held.free(handle);
    return .{ .message = .{ .tag = tag, .payload = payload, .user_data = user_data }, .point = point };
}

fn copyOut(table: *Table, bytes: Table.Bytes, allocator: std.mem.Allocator) ![]const u8 {
    const stored = table.bytesOf(bytes);
    if (stored.len == 0) return &.{};
    const copy = try allocator.alignedAlloc(u8, Table.bytes_alignment, stored.len);
    @memcpy(copy, stored);
    return copy;
}

pub fn prepareHeld(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareTable(Held, mem, atoms, tables, held_name, held_capacity);
}

pub fn ensureHeld(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    _ = try session.ensureTable(Held, mem, atoms, tables, held_name, held_capacity);
}

/// Presses were rejected while busy, so the session interaction identity still
/// belongs to this drag and is cleared with it.
fn becomeIdle(session_table: *Table, editor: session.View, weight_stroke: weight.StrokeView, stroke_targets: weight.TargetRows, stroke_samples: weight.SampleRows, stroke_shapes: weight.TargetShapeRows, stroke_locks: weight.StrokeLockRows, picker: color_picker.ConfigView, draw_settings: drawing.ConfigView, recent_colors: drawing.RecentRows, feedback: session.FeedbackView, state: View) void {
    if (kindOf(state) == .weight) weight.clearStroke(weight_stroke, stroke_targets, stroke_samples, stroke_shapes, stroke_locks);
    if (kindOf(state) == .color) color_picker.complete(session_table, picker, editor, draw_settings, recent_colors, feedback, intentOf(state));
    state.phase.* = @intFromEnum(Phase.idle);
    state.kind.* = @intFromEnum(Kind.none);
    state.intent.* = @intFromEnum(Intent.none);
    state.sample_pending.* = 0;
    editor.gesture_kind.* = session.none;
}
