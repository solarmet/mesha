//! Admission arithmetic for layered drawing: what a recording's geometry and its layer targets
//! cost, and the ledgers that admit or refuse that cost against a frame slot's and the host's
//! limits. Everything here is checked integer arithmetic over plain values: it allocates nothing,
//! waits on no GPU work and evaluates no geometry. A figure's drawing (`figure.draw`) measures
//! its geometry in `Geometry`; the runtime's layer schedule sizes its targets with `targetBytes`
//! and admits a frame's layers through `reserve`, `commit` and `rollback`.
const std = @import("std");
const MiB = 1024 * 1024;

/// How much of each of a recording's capacities some drawing takes, counted as `Context.pathBudget`
/// counts them. As a limit, a zero field admits none of that capacity: the caller supplies the
/// real limits and occupancy.
pub const Geometry = struct {
    /// Draw calls.
    draws: u64 = 0,
    /// Paint uniforms.
    uniforms: u64 = 0,
    /// Flattened points uploaded to the GPU.
    points: u64 = 0,
    /// Tessellation jobs.
    shapes: u64 = 0,
    /// Vertices the GPU tessellates.
    gpu_vertices: u64 = 0,
    /// Vertices built on the CPU.
    cpu_vertices: u64 = 0,
    /// Indirect draws, one for each stroked subpath.
    indirect_draws: u64 = 0,
    /// Batched quads.
    quad_instances: u64 = 0,
};
/// What one frame slot holds or takes. `live_targets` and `live_bytes` are peaks held at once;
/// the other fields are totals the slot consumes over its frame.
pub const Slot = struct {
    /// Layer targets alive at once.
    live_targets: u64 = 0,
    /// Bytes of layer targets alive at once.
    live_bytes: u64 = 0,
    /// Bytes of the schedule's own records.
    metadata_bytes: u64 = 0,
    /// Bytes uploaded to the GPU.
    upload_bytes: u64 = 0,
    /// Layers composited onto their parents.
    layer_composites: u64 = 0,
    /// Composites onto the final target.
    final_composites: u64 = 0,
    /// Geometry recorded.
    geometry: Geometry = .{},
};
/// What a ledger has admitted: each of the two frame slots' consumption, and the targets and bytes
/// the persistent pool has taken on.
pub const Usage = struct {
    /// Indexed by frame slot.
    slots: [2]Slot = .{ .{}, .{} },
    /// Targets the pool has allocated or reserved.
    pool_targets: u64 = 0,
    /// Bytes the pool has allocated or reserved.
    pool_bytes: u64 = 0,
};
/// What a ledger admits: a limit for each slot, limits on the two slots together, and the pool's.
pub const Limits = struct {
    /// What each frame slot may hold or take.
    per_slot: Slot,
    /// Live target bytes both slots may hold at once.
    live_bytes_both_slots: u64,
    /// Upload bytes both slots may take together.
    upload_bytes_both_slots: u64,
    /// Targets the pool may hold.
    pool_targets: u64,
    /// Bytes the pool may hold.
    pool_bytes: u64,

    /// The limits of one document's drawing, with `geometry` as each slot's geometry. The pool is
    /// unlimited here: the host's ledger limits it.
    pub fn document(geometry: Geometry) Limits {
        return .{
            .per_slot = .{
                .live_targets = 24,
                .live_bytes = 256 * MiB,
                .metadata_bytes = MiB,
                .upload_bytes = 16 * MiB,
                .layer_composites = 128,
                .final_composites = 36,
                .geometry = geometry,
            },
            .live_bytes_both_slots = 256 * MiB,
            .upload_bytes_both_slots = 32 * MiB,
            .pool_targets = std.math.maxInt(u64),
            .pool_bytes = std.math.maxInt(u64),
        };
    }
    /// The limits of everything the host draws, with `geometry` as each slot's geometry.
    pub fn host(geometry: Geometry) Limits {
        return .{
            .per_slot = .{
                .live_targets = 64,
                .live_bytes = 512 * MiB,
                .metadata_bytes = 4 * MiB,
                .upload_bytes = 64 * MiB,
                .layer_composites = 512,
                .final_composites = 36,
                .geometry = geometry,
            },
            .live_bytes_both_slots = 512 * MiB,
            .upload_bytes_both_slots = 128 * MiB,
            .pool_targets = 64,
            .pool_bytes = 512 * MiB,
        };
    }
};
/// What one unit of drawing asks of a ledger, as its caller has proven it, not inferred from how
/// deeply its layers nest. The caller counts every color, depth, stencil, mask and backdrop
/// target it needs. Without proof that a target is safe to reuse on the GPU, admitted units add
/// up: their live targets count as held at once. Both slots keep what they hold until the caller
/// retires it, which admission never does.
pub const Requirements = struct {
    /// The frame slot, 0 or 1, the unit draws in.
    slot: usize = 0,
    /// How deeply the unit's layers nest.
    depth: u64 = 0,
    /// What the unit adds to its slot, peak and total fields as `Slot` defines them.
    peak: Slot = .{},
    /// Targets the pool newly allocates or reserves for the unit; storage the ledger already
    /// counts, reused, is not counted again.
    new_pool_targets: u64 = 0,
    /// Bytes the pool newly allocates or reserves for the unit.
    new_pool_bytes: u64 = 0,
};
/// One target attachment or copy as the device lays it out, for `targetBytes`.
pub const Target = struct {
    /// In pixels.
    width: u64,
    /// In pixels.
    height: u64,
    /// More than 0.
    bytes_per_pixel: u64,
    /// Samples per pixel, more than 0.
    samples: u64 = 1,
    /// Each row's bytes round up to a multiple of this; 0 is refused.
    row_alignment: u64 = 1,
    /// The whole target's bytes round up to a multiple of this; 0 is refused.
    allocation_alignment: u64 = 1,
};
fn add(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.Overflow;
}
fn mul(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b) catch error.Overflow;
}
fn aligned(n: u64, alignment: u64) !u64 {
    if (alignment == 0) return error.InvalidDescriptor;
    const remainder = n % alignment;
    return if (remainder == 0) n else add(n, alignment - remainder);
}
/// The bytes `targets` take, one entry for each attachment or copy, each with its rows and its
/// whole aligned. Assumes no resolution or format of its own. `InvalidDescriptor` for a zero
/// `bytes_per_pixel`, `samples` or alignment; `Overflow` when the sum does not fit in a u64.
pub fn targetBytes(targets: []const Target) !u64 {
    var bytes: u64 = 0;
    for (targets) |t| {
        if (t.bytes_per_pixel == 0 or t.samples == 0) return error.InvalidDescriptor;
        const row = try aligned(try mul(try mul(t.width, t.bytes_per_pixel), t.samples), t.row_alignment);
        bytes = try add(bytes, try aligned(try mul(row, t.height), t.allocation_alignment));
    }
    return bytes;
}
fn sum(comptime T: type, a: T, b: T) !T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |f| {
        @field(result, f.name) = if (f.type == u64) try add(@field(a, f.name), @field(b, f.name)) else try sum(f.type, @field(a, f.name), @field(b, f.name));
    }
    return result;
}
fn within(comptime T: type, value: T, limit: T) !void {
    inline for (std.meta.fields(T)) |f| {
        if (f.type == u64) {
            if (@field(value, f.name) > @field(limit, f.name)) return error.CapacityExceeded;
        } else try within(f.type, @field(value, f.name), @field(limit, f.name));
    }
}
fn candidate(usage: Usage, limits: Limits, r: Requirements) !Usage {
    if (r.slot >= 2) return error.InvalidSlot;
    var next = usage;
    next.slots[r.slot] = try sum(Slot, next.slots[r.slot], r.peak);
    next.pool_targets = try add(next.pool_targets, r.new_pool_targets);
    next.pool_bytes = try add(next.pool_bytes, r.new_pool_bytes);
    for (next.slots) |slot| try within(Slot, slot, limits.per_slot);
    if (try add(next.slots[0].live_bytes, next.slots[1].live_bytes) > limits.live_bytes_both_slots or
        try add(next.slots[0].upload_bytes, next.slots[1].upload_bytes) > limits.upload_bytes_both_slots or
        next.pool_targets > limits.pool_targets or next.pool_bytes > limits.pool_bytes) return error.CapacityExceeded;
    return next;
}
/// What has been admitted against a set of limits. Its owner keeps it across frames; `usage`
/// holds the occupancy that exists before a reservation, and nothing here resets or retires it.
pub const Ledger = struct {
    /// Everything admitted so far.
    usage: Usage = .{},
    /// What `usage` may grow to.
    limits: Limits,
    /// Counts reservations, so a token can tell it is stale.
    generation: u64 = 0,
    /// A reservation awaits its `commit` or `rollback`.
    pending: bool = false,
};
/// One pending reservation in two ledgers, from `reserve`: passed to `commit` to keep it or to
/// `rollback` to undo it. It points at both ledgers, which must outlive it.
pub const Token = struct {
    /// The document's ledger.
    document: *Ledger,
    /// The host's ledger.
    host: *Ledger,
    /// The document ledger's generation the reservation made.
    document_generation: u64,
    /// The host ledger's generation the reservation made.
    host_generation: u64,
    /// The document ledger's usage before the reservation, which `rollback` restores.
    document_before: Usage,
    /// The host ledger's usage before the reservation, which `rollback` restores.
    host_before: Usage,
};
/// Admits `r` into both ledgers at once, or into neither: `CapacityExceeded` when either's limits
/// refuse it, `InvalidSlot` for a slot past 1, `Overflow` when a count does not fit,
/// `AliasedLedger` when both are one ledger, and `PendingReservation` while either holds one not
/// yet committed or rolled back. Each ledger holds one pending reservation at a time: commit it
/// before admitting a later unit.
pub fn reserve(document: *Ledger, host: *Ledger, r: Requirements) !Token {
    if (document == host) return error.AliasedLedger;
    if (document.pending or host.pending) return error.PendingReservation;
    const document_candidate = try candidate(document.usage, document.limits, r);
    const host_candidate = try candidate(host.usage, host.limits, r);
    const document_generation = try add(document.generation, 1);
    const host_generation = try add(host.generation, 1);
    const token: Token = .{
        .document = document,
        .host = host,
        .document_generation = document_generation,
        .host_generation = host_generation,
        .document_before = document.usage,
        .host_before = host.usage,
    };
    document.usage = document_candidate;
    host.usage = host_candidate;
    document.generation = document_generation;
    host.generation = host_generation;
    document.pending = true;
    host.pending = true;
    return token;
}
fn check(token: Token) !void {
    if (!token.document.pending or !token.host.pending or token.document.generation != token.document_generation or token.host.generation != token.host_generation) return error.StaleToken;
}
/// Keeps the reservation `token` made. `StaleToken` when it was already committed or rolled back,
/// or a later reservation followed it.
pub fn commit(token: Token) !void {
    try check(token);
    token.document.pending = false;
    token.host.pending = false;
}
/// Undoes the reservation `token` made, putting both ledgers' usage back. `StaleToken` as for
/// `commit`.
pub fn rollback(token: Token) !void {
    try check(token);
    token.document.usage = token.document_before;
    token.host.usage = token.host_before;
    token.document.pending = false;
    token.host.pending = false;
}

test "every slot count and byte capacity exact and max plus one, independently" {
    inline for (.{ Limits.document(.{}), Limits.host(.{}) }) |base| {
        inline for (std.meta.fields(Slot)) |f| {
            if (f.type == u64) {
                var r: Requirements = .{};
                @field(r.peak, f.name) = @field(base.per_slot, f.name);
                _ = try candidate(.{}, base, r);
                @field(r.peak, f.name) += 1;
                try std.testing.expectError(error.CapacityExceeded, candidate(.{}, base, r));
            }
        }
        inline for (std.meta.fields(Geometry)) |f| {
            var limits = base;
            @field(limits.per_slot.geometry, f.name) = 17;
            var r: Requirements = .{};
            @field(r.peak.geometry, f.name) = 17;
            _ = try candidate(.{}, limits, r);
            @field(r.peak.geometry, f.name) = 18;
            try std.testing.expectError(error.CapacityExceeded, candidate(.{}, limits, r));
        }
    }
}
test "aggregate both slots and persistent pool exact and max plus one" {
    inline for (.{ Limits.document(.{}), Limits.host(.{}) }) |base| {
        inline for (.{ "live_bytes", "upload_bytes" }) |name| {
            const limit = if (std.mem.eql(u8, name, "live_bytes")) base.live_bytes_both_slots else base.upload_bytes_both_slots;
            var usage: Usage = .{};
            @field(usage.slots[0], name) = limit / 2;
            var r: Requirements = .{ .slot = 1 };
            @field(r.peak, name) = limit / 2;
            _ = try candidate(usage, base, r);
            @field(r.peak, name) += 1;
            try std.testing.expectError(error.CapacityExceeded, candidate(usage, base, r));
        }
    }
    const host = Limits.host(.{});
    _ = try candidate(.{}, host, .{ .new_pool_targets = 64, .new_pool_bytes = 512 * MiB });
    try std.testing.expectError(error.CapacityExceeded, candidate(.{}, host, .{ .new_pool_targets = 65 }));
    try std.testing.expectError(error.CapacityExceeded, candidate(.{}, host, .{ .new_pool_bytes = 512 * MiB + 1 }));
}
test "transaction preserves preceding units, pending state, rollback and stale tokens" {
    var d: Ledger = .{ .limits = Limits.document(.{}) };
    var h: Ledger = .{ .limits = Limits.host(.{}) };
    const empty = try reserve(&d, &h, .{});
    try commit(empty);
    const first = try reserve(&d, &h, .{ .peak = .{ .layer_composites = 10 } });
    try commit(first);
    const before_d = d;
    const before_h = h;
    try std.testing.expectError(error.CapacityExceeded, reserve(&d, &h, .{ .peak = .{ .layer_composites = 119 } }));
    try std.testing.expectEqualDeep(before_d, d);
    try std.testing.expectEqualDeep(before_h, h);
    const pending = try reserve(&d, &h, .{ .slot = 1, .peak = .{ .upload_bytes = 42 } });
    try std.testing.expectError(error.PendingReservation, reserve(&d, &h, .{}));
    try std.testing.expectError(error.StaleToken, rollback(first));
    try rollback(pending);
    try std.testing.expectEqualDeep(before_d.usage, d.usage);
    try std.testing.expectEqualDeep(before_h.usage, h.usage);
    try std.testing.expectError(error.StaleToken, rollback(pending));
    const later = try reserve(&d, &h, .{ .peak = .{ .layer_composites = 1 } });
    try std.testing.expectError(error.StaleToken, commit(pending));
    try commit(later);
    try std.testing.expectEqual(@as(u64, 11), d.usage.slots[0].layer_composites);
    try std.testing.expectError(error.StaleToken, commit(later));
    h.limits.per_slot.layer_composites = 11;
    const snapshot = d;
    try std.testing.expectError(error.CapacityExceeded, reserve(&d, &h, .{ .peak = .{ .layer_composites = 1 } }));
    try std.testing.expectEqualDeep(snapshot, d);
}
test "checked descriptor alignment and arithmetic overflow" {
    try std.testing.expectEqual(@as(u64, 512), try targetBytes(&.{ .{ .width = 3, .height = 2, .bytes_per_pixel = 4, .row_alignment = 16, .allocation_alignment = 256 }, .{ .width = 1, .height = 1, .bytes_per_pixel = 4, .allocation_alignment = 256 } }));
    try std.testing.expectEqual(@as(u64, 0), try targetBytes(&.{}));
    try std.testing.expectError(error.InvalidDescriptor, targetBytes(&.{.{ .width = 1, .height = 1, .bytes_per_pixel = 4, .row_alignment = 0 }}));
    try std.testing.expectError(error.Overflow, targetBytes(&.{.{ .width = std.math.maxInt(u64), .height = 1, .bytes_per_pixel = 4 }}));
    try std.testing.expectError(error.Overflow, aligned(std.math.maxInt(u64), 2));
    var usage: Usage = .{ .pool_bytes = std.math.maxInt(u64) };
    try std.testing.expectError(error.Overflow, candidate(usage, Limits.host(.{}), .{ .new_pool_bytes = 1 }));
    usage = .{};
    usage.slots[0].geometry.draws = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, candidate(usage, Limits.host(.{}), .{ .peak = .{ .geometry = .{ .draws = 1 } } }));
    try std.testing.expectError(error.InvalidSlot, candidate(.{}, Limits.host(.{}), .{ .slot = 2 }));
}

test "all cumulative fields and token generations reject checked overflow atomically" {
    inline for (std.meta.fields(Slot)) |f| {
        if (f.type == u64) {
            var usage: Usage = .{};
            @field(usage.slots[0], f.name) = std.math.maxInt(u64);
            var r: Requirements = .{};
            @field(r.peak, f.name) = 1;
            try std.testing.expectError(error.Overflow, candidate(usage, Limits.host(.{}), r));
        }
    }
    inline for (std.meta.fields(Geometry)) |f| {
        var usage: Usage = .{};
        @field(usage.slots[0].geometry, f.name) = std.math.maxInt(u64);
        var r: Requirements = .{};
        @field(r.peak.geometry, f.name) = 1;
        try std.testing.expectError(error.Overflow, candidate(usage, Limits.host(.{}), r));
    }
    var d: Ledger = .{ .limits = Limits.document(.{}) };
    var h: Ledger = .{ .limits = Limits.host(.{}), .generation = std.math.maxInt(u64) };
    const before_d = d;
    const before_h = h;
    try std.testing.expectError(error.Overflow, reserve(&d, &h, .{}));
    try std.testing.expectEqualDeep(before_d, d);
    try std.testing.expectEqualDeep(before_h, h);
    try std.testing.expectError(error.AliasedLedger, reserve(&d, &d, .{}));
}
