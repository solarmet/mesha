//! The time system's contract: the clock, the frames and fixed ticks a system may hear, and
//! animations of table cells. The clock itself and the system that runs each frame are the
//! runtime's (`mesha_runtime.time`).
//!
//! - The clock is `time.state`, which any system reads (`ClockView`): it makes a fixed tick for
//!   each `fixed_dt` seconds of frame time, so several in a slow frame and none in a quick one.
//! - A row of `subscriptions.time` (`SubscriptionRow`) asks for a `FrameMsg` each frame or a
//!   `TickMsg` each fixed tick, in the inbox and under the tag it names.
//! - `request` appends to `commands.time`: `animate` moves one cell of a table from a value to
//!   another over time, and `cancel_animation` ends that. What happens to an animation is told to
//!   its request's reply as `AnimationMsg`s. `wake` asks for one `WakeMsg` after so many seconds
//!   of real time, which wakes a sleeping host when it falls due, and `cancel_wake` takes one
//!   back: what a system that does work now and then in the background asks, in place of
//!   hearing every frame.
//! - `frame_stats` holds how long frames take.
//!
//! Times are seconds unless a name says milliseconds.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");

const sequencer = @import("../core/sequencer.zig");
const Log = @import("../core/log.zig").scope("time");
const math = @import("../core/math.zig");

/// A frame's payload, under the tag its subscription named.
pub const FrameMsg = struct {
    /// Seconds since the frame before, never negative.
    raw_dt: f32,
    /// `raw_dt`, but no more than the clock's longest step: what the frame adds to the fixed
    /// ticks' time.
    dt: f32,
    /// The frame's number, counted from the clock's first.
    frame_index: u64,
};

/// A fixed tick's payload, under the tag its subscription named.
pub const TickMsg = struct {
    /// The length of a fixed tick, in seconds.
    dt: f32,
    /// The tick's number, counted from the clock's first.
    tick_index: u64,
};

/// A cell's address. Handles are generational, so an animation outliving its row or table
/// ends with `.cancelled` instead of writing to whatever took the slot.
pub const AnimationTarget = struct {
    /// The cell's table.
    table: Table.Handle,
    /// The cell's row.
    row: Table.RowHandle,
    /// Matched against `FieldDescriptor.name_id`.
    field: Atom,
};

/// One variant per interpolable `Table.FieldType`, in that field's storage layout. Other
/// fields, including ones declared without a `FieldType`, cannot be animated.
pub const AnimationValue = union(enum) {
    /// A 32-bit float.
    f32: f32,
    /// A 32-bit integer; values between are rounded.
    i32: i32,
    /// Two floats.
    vec2f: math.Vec2f,
    /// Three floats.
    vec3f: math.Vec3f,
    /// RGBA bytes, interpolated per channel in the sRGB space they are stored in.
    color: [4]u8,

    /// The `Table.FieldType` a cell must have to take the value.
    pub fn fieldType(self: AnimationValue) Table.FieldType {
        return switch (self) {
            .f32 => .f32,
            .i32 => .i32,
            .vec2f => .vec2f,
            .vec3f => .vec3f,
            .color => .color,
        };
    }

    fn isFinite(self: AnimationValue) bool {
        return switch (self) {
            .f32 => |value| std.math.isFinite(value),
            .vec2f => |value| std.math.isFinite(value.x) and std.math.isFinite(value.y),
            .vec3f => |value| std.math.isFinite(value.x) and std.math.isFinite(value.y) and std.math.isFinite(value.z),
            .i32, .color => true,
        };
    }

    /// `amount` may leave 0 to 1 for overshooting curves; integers and color channels saturate
    /// at their range. Both values must hold the same variant.
    pub fn lerp(from: AnimationValue, to: AnimationValue, amount: f32) AnimationValue {
        return switch (from) {
            .f32 => |start| .{ .f32 = lerpFloat(start, to.f32, amount) },
            .i32 => |start| .{ .i32 = lerpInt(start, to.i32, amount) },
            .vec2f => |start| .{ .vec2f = .{
                .x = lerpFloat(start.x, to.vec2f.x, amount),
                .y = lerpFloat(start.y, to.vec2f.y, amount),
            } },
            .vec3f => |start| .{ .vec3f = .{
                .x = lerpFloat(start.x, to.vec3f.x, amount),
                .y = lerpFloat(start.y, to.vec3f.y, amount),
                .z = lerpFloat(start.z, to.vec3f.z, amount),
            } },
            .color => |start| blk: {
                var channels: [4]u8 = undefined;
                for (&channels, start, to.color) |*channel, channel_from, channel_to| {
                    const blended = lerpFloat(@floatFromInt(channel_from), @floatFromInt(channel_to), amount);
                    const clamped = std.math.clamp(blended, 0, 255);
                    channel.* = @intFromFloat(@round(clamped));
                }
                break :blk .{ .color = channels };
            },
        };
    }
};

fn lerpFloat(from: f32, to: f32, amount: f32) f32 {
    return from + (to - from) * amount;
}

fn lerpInt(from: i32, to: i32, amount: f32) i32 {
    const start: f64 = @floatFromInt(from);
    const end: f64 = @floatFromInt(to);
    const blended = start + (end - start) * amount;
    const lowest: f64 = @floatFromInt(std.math.minInt(i32));
    const highest: f64 = @floatFromInt(std.math.maxInt(i32));
    const clamped = std.math.clamp(blended, lowest, highest);
    return @intFromFloat(@round(clamped));
}

/// How an animation's progress is shaped: a curve, and which end of the leg it eases.
pub const Easing = struct {
    /// The curve's shape.
    curve: Curve = .linear,
    /// Which end is eased.
    direction: Direction = .in_out,

    /// The shapes: `linear` is none, `quad` through `quint` are powers of the progress, and
    /// `back` and `elastic` pass the ends before they settle.
    pub const Curve = enum { linear, quad, cubic, quart, quint, sine, expo, circ, back, elastic, bounce };
    /// `in` starts slowly, `out` ends slowly, `in_out` does both.
    pub const Direction = enum { in, out, in_out };

    /// Maps progress in 0 to 1 onto the curve. `back` and `elastic` overshoot that range.
    pub fn apply(self: Easing, progress: f32) f32 {
        const t = std.math.clamp(progress, 0, 1);
        return switch (self.direction) {
            .in => curveIn(self.curve, t),
            .out => 1 - curveIn(self.curve, 1 - t),
            .in_out => if (t < 0.5)
                curveIn(self.curve, 2 * t) / 2
            else
                1 - curveIn(self.curve, 2 - 2 * t) / 2,
        };
    }
};

fn curveIn(curve: Easing.Curve, t: f32) f32 {
    switch (curve) {
        .linear => return t,
        .quad => return t * t,
        .cubic => return t * t * t,
        .quart => return t * t * t * t,
        .quint => return t * t * t * t * t,
        .sine => return 1 - @cos(t * std.math.pi / 2),
        .expo => return if (t <= 0) 0 else std.math.pow(f32, 2, 10 * t - 10),
        .circ => return 1 - @sqrt(1 - t * t),
        .back => {
            const overshoot: f32 = 1.70158;
            return (overshoot + 1) * t * t * t - overshoot * t * t;
        },
        .elastic => {
            if (t <= 0) return 0;
            if (t >= 1) return 1;
            const envelope = std.math.pow(f32, 2, 10 * t - 10);
            const phase = (10 * t - 10.75) * (2 * std.math.pi / 3.0);
            return -envelope * @sin(phase);
        },
        .bounce => return 1 - bounceOut(1 - t),
    }
}

fn bounceOut(t: f32) f32 {
    const scale: f32 = 7.5625;
    const span: f32 = 2.75;
    if (t < 1 / span) return scale * t * t;
    if (t < 2 / span) {
        const offset = t - 1.5 / span;
        return scale * offset * offset + 0.75;
    }
    if (t < 2.5 / span) {
        const offset = t - 2.25 / span;
        return scale * offset * offset + 0.9375;
    }
    const offset = t - 2.625 / span;
    return scale * offset * offset + 0.984375;
}

/// What an animation does when a leg ends.
pub const AnimationPlayback = enum {
    /// One leg from `from` to `to`.
    once,
    /// Each leg restarts at `from`.
    loop,
    /// Legs alternate direction, starting towards `to`.
    ping_pong,
};

/// A request to move one cell from a value to another over time; `validateAnimate` says what is
/// valid.
pub const Animate = struct {
    /// The cell to animate.
    target: AnimationTarget,
    /// The value a leg ends at, of the cell's field type.
    to: AnimationValue,
    /// Null reads the cell when the animation begins, after any delay.
    from: ?AnimationValue = null,
    /// Seconds per leg. Only `.once` may be zero, which jumps to `to` when it begins.
    duration: f32,
    /// Seconds before `.begin`, during which the cell is not touched.
    delay: f32 = 0,
    /// How progress through a leg is shaped.
    easing: Easing = .{},
    /// What happens when a leg ends.
    playback: AnimationPlayback = .once,
    /// Legs to play under `.loop` and `.ping_pong`, null for until cancelled. Ignored by `.once`.
    /// A ping-pong's last leg decides where it rests: odd counts at `to`, even at `from`.
    cycles: ?u32 = null,
    /// Where each of this animation's events goes as an `AnimationMsg`, `.update` included:
    /// whoever draws the cell hears every change to it, so it can draw again. None for a
    /// requester that waits on nothing.
    reply: sequencer.ReplyTo = .{},
};

// ---- the time system's tables ----------------------------------------------------------------

/// Systems append a row per subscription in their runs, each system's rows lasting until it
/// runs again (`sequencer.ensureSubscriptions`); the time system delivers frames and ticks to
/// the inboxes the rows name.
pub const subscriptions_table_name = "subscriptions.time";

/// `time.state`, the clock, which other systems read: how many fixed ticks it has made and
/// how long each is, and how many frames it has advanced through, among its other fields.
pub const state_table_name = "time.state";
/// A view of what a system reads of the clock: the length of a fixed tick in seconds, and how
/// many ticks the clock has made.
pub const ClockView = struct { fixed_dt: *f32, fixed_tick_index: *u64 };
/// A view of how many frames the clock has advanced through, counted from its first: one more
/// for each frame the host runs, for a system that ages what it waits for in frames rather than
/// in time. A frame comes only when there is work, so a quiet host counts none. The view points
/// into the singleton `time.state`, which the host's time system owns and advances once a
/// frame, outside any run; it is good for the run that read it, whose system declares
/// `time.state` read, and is read again in a later run, never kept.
pub const FrameCountView = struct { frame_index: *u64 };
/// A view of the instant on the host's awake clock (`std.Io.Clock.awake`) the time system last
/// read: as each frame begins, and as the host wakes from sleeping between frames, so the time
/// the host slept is in it, unlike in the frames' lengths. Wakes fall due on this clock. It
/// points into `time.state`, as `FrameCountView` does, and is good for the run that read it,
/// whose system declares `time.state` read.
pub const AwakeView = struct { prev_time: *std.Io.Timestamp };
/// A fixed tick of the clock: its count, the length of a tick, and the instant on the awake
/// clock it stands for.
pub const Tick = struct { index: u64, fixed_dt: f32, instant: std.Io.Timestamp };
/// Systems append a row per request; the time system admits them in append order once the
/// frame's runs are done, and clears the table.
pub const commands_table_name = "commands.time";

/// What a time subscription hears: every frame, or every fixed tick.
pub const SubscriptionKind = enum(u8) { frame, tick };

/// A row of `subscriptions.time`: what to hear, the inbox it goes to and the tag it arrives
/// under there.
pub const SubscriptionRow = struct { kind: *SubscriptionKind, inbox: *Atom, tag: *Atom };

/// What a row of `commands.time` asks.
pub const CommandOp = enum(u8) { animate, cancel_animation, wake, cancel_wake };

// A row of `commands.time` holds `op`, with `animate` for `.animate`, `target` for
// `.cancel_animation`, or `wake` for `.wake` and `.cancel_wake`.

/// A wake a system asks for (`CmdPayload.wake`): one `WakeMsg`, `after` seconds of the host's
/// awake clock from when the time system admits the request, to `inbox` under `tag`. A wake is
/// known by its `inbox` and `tag`: asking again for the same pair replaces the one pending, which
/// then counts from the new request; `cancel_wake` with the same pair drops it. It is one-shot:
/// once delivered it is gone, and a system that wants another asks again. While the host sleeps
/// (no work for a few frames) the wake is still counted, in real time, and its falling due runs
/// a frame, about as late as the host's idle poll (50 ms). While the engine's window is
/// minimized the host runs no frame and delivers no wake: one that falls due then is delivered
/// once the window is restored, so a background refresh waits until then. Pending wakes are the
/// host's: they outlive a reload of the plugin that asked, and are delivered to its inbox, where
/// a tag no system claims any more is dropped.
///
/// A wake the time system cannot hold (its `after` out of range, or `max_wakes` already pending
/// for other pairs) is rejected: logged as `wake_rejected`, never delivered and never answered.
/// A system that counts on its wake therefore notes when it asked and asks again once it has
/// heard nothing for longer than it waits.
pub const Wake = extern struct {
    /// The inbox the message goes to: the asking system's (`sequencer.inboxOf`).
    inbox: Atom,
    /// The tag it arrives under, which the asking system claims.
    tag: Atom,
    /// How many seconds from now: finite, from 0 to `max_wake_after`, else the request is
    /// rejected. Unused by `cancel_wake`.
    after: f32 = 0,
    /// Nothing: keeps the bytes defined.
    unused: u32 = 0,
};

/// The most wakes the time system holds pending at once, across every system: a request for
/// another pair while this many are pending is rejected (`Wake`); one for a pair pending still
/// replaces it.
pub const max_wakes = 64;

/// The longest a wake waits, in seconds: a year. A longer `Wake.after` is rejected.
pub const max_wake_after: f32 = 365 * 24 * 60 * 60;

/// The payload of a wake's message: how many seconds after it was asked it was asked for.
pub const WakeMsg = struct {
    /// The wake's `after`.
    after: f32,
};

/// What happened to an animation, as its request's reply hears it.
pub const AnimationEvent = enum {
    /// Never started: the request is invalid, the target did not resolve, or storage ran out.
    rejected,
    /// The delay is over and the cell starts to change.
    begin,
    /// A step wrote the cell a new value, every frame the animation runs; `.end` reports the
    /// last write instead.
    update,
    /// A `.loop` restarted at `from`.
    looped,
    /// A `.ping_pong` changed direction.
    reversed,
    /// Terminal: the cell holds its final value.
    end,
    /// Terminal: cancelled, replaced by a newer animation of the same cell, or the target is
    /// gone. The cell keeps whatever value it last had.
    cancelled,
};

/// Several legs passing within one step report once, with `cycle` carrying the true count.
pub const AnimationMsg = struct {
    /// What happened.
    event: AnimationEvent,
    /// The cell the animation is of.
    target: AnimationTarget,
    /// Legs completed so far.
    cycle: u32,
};

/// A request to the time system.
pub const CmdPayload = union(enum) {
    /// A cell has at most one animation: animating it again replaces the current one.
    animate: Animate,
    /// Ends the cell's animation, which answers `.cancelled`. The cell keeps the value it has.
    cancel_animation: AnimationTarget,
    /// Asks for one `WakeMsg` after `Wake.after` seconds, in place of any pending for the same
    /// inbox and tag.
    wake: Wake,
    /// Drops the wake pending for the inbox and tag named (`after` unread); nothing when none is.
    cancel_wake: Wake,
};

/// Why an animation is not valid. `InvalidDuration`: negative or not finite, or zero for a
/// `.loop` or a `.ping_pong`. `InvalidDelay`: negative or not finite. `InvalidCycles`: zero legs
/// for a `.loop` or a `.ping_pong`. `MismatchedValues`: `from` and `to` are of different kinds.
/// `NonFiniteValue`: a float of `from` or `to` is not finite.
pub const AnimationValidationError = error{
    InvalidDuration,
    InvalidDelay,
    InvalidCycles,
    MismatchedValues,
    NonFiniteValue,
};

/// Checks an animation request without its target; see `AnimationValidationError`. The time
/// system answers `.rejected` to one that fails, or whose target is not a cell of `to`'s type.
pub fn validateAnimate(animation: Animate) AnimationValidationError!void {
    if (!std.math.isFinite(animation.duration) or animation.duration < 0) return error.InvalidDuration;
    if (animation.duration == 0 and animation.playback != .once) return error.InvalidDuration;
    if (!std.math.isFinite(animation.delay) or animation.delay < 0) return error.InvalidDelay;
    if (animation.playback != .once and animation.cycles == 0) return error.InvalidCycles;
    if (!animation.to.isFinite()) return error.NonFiniteValue;
    if (animation.from) |from| {
        if (from.fieldType() != animation.to.fieldType()) return error.MismatchedValues;
        if (!from.isFinite()) return error.NonFiniteValue;
    }
}

/// The most fixed ticks one advance of the clock may make.
pub const kMaxTicksPerAdvance: usize = 16;

/// Why a clock's step is not valid. `NonFiniteRawDelta`: the frame's time is not finite.
/// `InvalidFixedDelta`: the tick's length is not finite or not above zero. `InvalidMaxDelta`: the
/// longest step is negative or not finite. `InvalidAccumulator`: the time carried over is
/// negative, not finite, or a whole tick or more. `TooManyTicks`: the step would make more than
/// `kMaxTicksPerAdvance` ticks.
pub const StepValidationError = error{
    NonFiniteRawDelta,
    InvalidFixedDelta,
    InvalidMaxDelta,
    InvalidAccumulator,
    TooManyTicks,
};

/// Checks a frame's time `raw_dt`, a tick's length `fixed_dt` and the longest step `max_dt`, all
/// in seconds. A negative `raw_dt` is valid: the clock counts it as zero.
pub fn validateStep(raw_dt: f32, fixed_dt: f32, max_dt: f32) StepValidationError!void {
    if (!std.math.isFinite(raw_dt)) return error.NonFiniteRawDelta;
    if (!std.math.isFinite(fixed_dt) or fixed_dt <= 0) return error.InvalidFixedDelta;
    if (!std.math.isFinite(max_dt) or max_dt < 0) return error.InvalidMaxDelta;
}

/// Checks a step as `validateStep` does, and that with `accumulator` seconds carried over it
/// makes no more than `kMaxTicksPerAdvance` ticks.
pub fn validateStepBudget(raw_dt: f32, fixed_dt: f32, max_dt: f32, accumulator: f32) StepValidationError!void {
    try validateStep(raw_dt, fixed_dt, max_dt);
    if (!std.math.isFinite(accumulator) or accumulator < 0 or accumulator >= fixed_dt)
        return error.InvalidAccumulator;
    const accumulated_delta = accumulator + @min(@max(raw_dt, 0), max_dt);
    if (!std.math.isFinite(accumulated_delta)) return error.TooManyTicks;
    const tick_budget_ratio = accumulated_delta / fixed_dt;
    if (!std.math.isFinite(tick_budget_ratio) or @floor(tick_budget_ratio) > kMaxTicksPerAdvance)
        return error.TooManyTicks;
}

/// `frame_stats`, a singleton of how long frames take: the sim thread's, as the clock measures
/// them, and the render thread's, as the host reports them.
pub const frame_stats_table = "frame_stats";
/// The column of `frame_stats` with the sim thread's frame time, in milliseconds.
pub const frame_time_field = "frame_time_ms";
/// The column of `frame_stats` with the render thread's frame time, in milliseconds.
pub const render_frame_time_field = "render_frame_time_ms";

/// The time system's subscription and command tables.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var subscriptions: Table.Schema = undefined;
    try subscriptions.init(scratch.allocator, atoms, 5);
    defer subscriptions.deinit();
    try subscriptions.addFieldFallible("kind", SubscriptionKind, .int);
    try subscriptions.addFieldFallible("inbox", Atom, .atom);
    try subscriptions.addFieldFallible("tag", Atom, .atom);
    try subscriptions.addFieldFallible(sequencer.subscriber_field, Atom, .atom);
    try subscriptions.addFieldFallible(sequencer.subscription_order_field, u32, .int);
    try atoms.tryInternAll(&.{ subscriptions_table_name, commands_table_name });
    _ = try tables.ensure(&subscriptions, 32, Atom.from(subscriptions_table_name), .durable);
    try sequencer.ensureSubscriptions(scratch, atoms, tables, subscriptions_table_name);
    var commands: Table.Schema = undefined;
    try commands.init(scratch.allocator, atoms, 5);
    defer commands.deinit();
    try commands.addFieldFallible("op", CommandOp, .int);
    try commands.addFieldFallible("animate", Animate, .hex);
    try commands.addFieldFallible("target", AnimationTarget, .hex);
    try commands.addFieldFallible("reply_user_data", Table.Bytes, .bytes);
    try commands.addFieldFallible("wake", Wake, .hex);
    _ = try tables.ensure(&commands, 32, Atom.from(commands_table_name), .durable);
}

/// Appends `wanted` to `commands.time`, which the time system admits in order in its next run.
/// Nothing happens before the table exists; a row the table cannot take is logged and dropped.
pub fn request(tables: *Table.Registry, wanted: CmdPayload) void {
    const commands = tables.findByName(Atom.from(commands_table_name)) orelse return;
    const appended = switch (wanted) {
        .animate => |animate| appendAnimate(commands, animate),
        .cancel_animation => |target| appendCancel(commands, target),
        .wake => |wake| appendWake(commands, .wake, wake),
        .cancel_wake => |wake| appendWake(commands, .cancel_wake, wake),
    };
    appended catch |err| Log.err("time_request_dropped", .{ .@"error" = @errorName(err) });
}

/// Appends an animation request to `commands`, `commands.time`, as a run does through its
/// layer: its reply's user data a bytes cell of the table, as the `animate` cell holds no
/// slice.
pub fn appendAnimate(commands: *Table, animate: Animate) !void {
    var stored = animate;
    stored.reply.user_data = .none;
    const handle = try commands.tryInsert(.{ .op = CommandOp.animate, .animate = stored });
    errdefer commands.free(handle);
    const user_data = animate.reply.user_data.bytes;
    if (user_data.len != 0) try commands.setBytes(handle, "reply_user_data", user_data);
}

fn appendCancel(commands: *Table, target: AnimationTarget) !void {
    _ = try commands.tryInsert(.{ .op = CommandOp.cancel_animation, .target = target });
}

/// Appends a wake or its cancel to `commands`, `commands.time`, as a run does through its layer.
pub fn appendWake(commands: *Table, op: CommandOp, wake: Wake) !void {
    _ = try commands.tryInsert(.{ .op = op, .wake = wake });
}

test "time step budget rejects pathological tick work and invalid accumulators" {
    try validateStepBudget(0.1, 1.0 / 60.0, 0.1, 0.01);
    try std.testing.expectError(error.TooManyTicks, validateStepBudget(1, 0.001, 1, 0));
    try std.testing.expectError(error.InvalidAccumulator, validateStepBudget(0, 0.01, 0.1, 0.01));
    try std.testing.expectError(error.InvalidAccumulator, validateStepBudget(0, 0.01, 0.1, std.math.nan(f32)));
}

test "time step validation accepts negative raw deltas but rejects invalid configuration" {
    try validateStep(-1, 1.0 / 60.0, 0.1);
    try std.testing.expectError(error.NonFiniteRawDelta, validateStep(std.math.nan(f32), 1.0 / 60.0, 0.1));
    try std.testing.expectError(error.InvalidFixedDelta, validateStep(0.016, 0, 0.1));
    try std.testing.expectError(error.InvalidMaxDelta, validateStep(0.016, 1.0 / 60.0, -0.1));
}

test "every easing starts at 0 and ends at 1" {
    for (std.enums.values(Easing.Curve)) |curve| {
        for (std.enums.values(Easing.Direction)) |direction| {
            const easing: Easing = .{ .curve = curve, .direction = direction };
            try std.testing.expectApproxEqAbs(@as(f32, 0), easing.apply(0), 0.002);
            try std.testing.expectApproxEqAbs(@as(f32, 1), easing.apply(1), 0.002);
        }
    }
}

test "lerp saturates integers and color channels when a curve overshoots" {
    const low: AnimationValue = .{ .color = .{ 0, 100, 200, 255 } };
    const high: AnimationValue = .{ .color = .{ 255, 100, 250, 255 } };
    try std.testing.expectEqual([4]u8{ 255, 100, 255, 255 }, low.lerp(high, 1.5).color);
    const largest: AnimationValue = .{ .i32 = std.math.maxInt(i32) };
    const zero: AnimationValue = .{ .i32 = 0 };
    try std.testing.expectEqual(std.math.maxInt(i32), zero.lerp(largest, 2).i32);
}
