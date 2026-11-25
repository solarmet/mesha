//! Copying a figure's working pose and pasting it onto another figure whose rig matches by name.
//! Pure functions over a `read.Definition`: they read no table and keep nothing, so the editor
//! copies and pastes with them the way any plugin could.
const std = @import("std");
const Atom = @import("../../core/atom.zig").Atom;
const figure = @import("../figure.zig");
const read = @import("read.zig");
const Error = figure.PoseClipboardError;
const none: Atom = @enumFromInt(0);

fn boneById(data: read.Definition, id: u32) Error!read.Bone {
    for (data.bones) |bone| if (bone.id == id) return bone;
    return error.MissingBone;
}

fn rowNamed(comptime T: type, rows: []const T, name: Atom) Error!T {
    var found: ?T = null;
    for (rows) |row| if (row.name == name) {
        if (found != null) return error.AmbiguousPoseClipboardName;
        found = row;
    };
    if (found) |row| return row;
    return if (T == read.Bone) error.MissingPoseClipboardBone else error.MissingPoseClipboardIK;
}

fn parentName(data: read.Definition, bone: read.Bone) Error!Atom {
    if (bone.parent == 0) return none;
    const parent = try boneById(data, bone.parent);
    return parent.name;
}

/// `data`'s working pose (pose 0) with the whole rig it applies to: every bone's rest values and
/// the channels the pose sets on it, and every controller's settings and the pose's row for it.
/// Fails with `error.MissingBone` when a bone's parent or a controller's end bone is not in
/// `data`. The caller owns both slices, in `allocator`.
pub fn capture(data: read.Definition, allocator: std.mem.Allocator) Error!figure.PoseClipboard {
    const bones = try allocator.alloc(figure.PoseClipboardBone, data.bones.len);
    errdefer allocator.free(bones);
    const ik = try allocator.alloc(figure.PoseClipboardIK, data.ik.len);
    errdefer allocator.free(ik);
    for (data.bones, bones) |bone, *dest| {
        dest.* = .{
            .name = bone.name,
            .parent = try parentName(data, bone),
            .rest_local = bone.local,
            .rest_rotation = bone.rotation,
            .rest_scale = bone.scale,
            .rest_length = bone.length,
            .flags = bone.flags,
        };
        for (data.pose_channels) |channel| if (channel.pose == 0 and channel.bone == bone.id) {
            // Preserve sparse authored mask semantics; ignored values stay canonical defaults.
            dest.mask = channel.mask & 15;
            if (channel.mask & 1 != 0) dest.rotation = channel.rotation;
            if (channel.mask & 2 != 0) dest.local = channel.local;
            if (channel.mask & 4 != 0) dest.scale = channel.scale;
            if (channel.mask & 8 != 0) dest.length = channel.length;
            break;
        };
    }
    for (data.ik, ik) |controller, *dest| {
        const end = try boneById(data, controller.end_bone);
        dest.* = .{ .name = controller.name, .end = end.name, .chain = controller.chain, .bend = controller.bend, .flags = controller.flags };
        for (data.pose_ik) |row| if (row.pose == 0 and row.ik == controller.id) {
            dest.present = 1;
            dest.target = row.target;
            dest.target_rotation = row.target_rotation;
            dest.enabled = row.enabled;
            dest.pinned = row.pinned;
            dest.bend_side = row.bend_side;
            dest.pole_angle = row.pole_angle;
        };
    }
    return .{ .bones = bones, .ik = ik };
}

/// `source`, copied from some figure, as inputs that pose `data` the same way: each bone and
/// controller found in `data` by name, its parent or end bone, rest values and settings checked
/// against what was copied. Fails with `error.IncompatiblePoseClipboardRig` when the rigs differ
/// in size, values or settings, `error.AmbiguousPoseClipboardName` when two copied or two target
/// rows share a name, and `error.MissingPoseClipboardBone` or `MissingPoseClipboardIK` when
/// `data` lacks one. Borrows `source`; the caller owns both returned slices, in `allocator`.
pub fn remap(data: read.Definition, source: figure.PoseClipboard, allocator: std.mem.Allocator) Error!figure.CustomInputs {
    if (source.bones.len != data.bones.len or source.ik.len != data.ik.len) return error.IncompatiblePoseClipboardRig;
    var channels: std.ArrayListUnmanaged(figure.PoseChannels) = .empty;
    errdefer channels.deinit(allocator);
    var ik: std.ArrayListUnmanaged(figure.PoseIK) = .empty;
    errdefer ik.deinit(allocator);
    var seen = std.AutoHashMap(Atom, void).init(allocator);
    defer seen.deinit();
    for (source.bones) |copied| {
        const entry = try seen.getOrPut(copied.name);
        if (entry.found_existing) return error.AmbiguousPoseClipboardName;
        const bone = try rowNamed(read.Bone, data.bones, copied.name);
        const parent = try parentName(data, bone);
        const same_rest = copied.parent == parent and copied.flags == bone.flags and
            std.meta.eql(copied.rest_local, bone.local) and copied.rest_rotation == bone.rotation and
            std.meta.eql(copied.rest_scale, bone.scale) and copied.rest_length == bone.length;
        const known_mask = copied.mask & ~@as(u32, 15) == 0;
        if (!same_rest or !known_mask) return error.IncompatiblePoseClipboardRig;
        if (copied.mask != 0) try channels.append(allocator, .{
            .bone = bone.id,
            .rotation = if (copied.mask & 1 != 0) copied.rotation else null,
            .local = if (copied.mask & 2 != 0) copied.local else null,
            .scale = if (copied.mask & 4 != 0) copied.scale else null,
            .length = if (copied.mask & 8 != 0) copied.length else null,
        });
    }
    seen.clearRetainingCapacity();
    for (source.ik) |copied| {
        const entry = try seen.getOrPut(copied.name);
        if (entry.found_existing) return error.AmbiguousPoseClipboardName;
        const controller = try rowNamed(read.IK, data.ik, copied.name);
        const end = try boneById(data, controller.end_bone);
        const same_settings = copied.end == end.name and copied.chain == controller.chain and
            copied.bend == controller.bend and copied.flags == controller.flags;
        if (!same_settings) return error.IncompatiblePoseClipboardRig;
        if (copied.present != 0) try ik.append(allocator, .{
            .ik = controller.id,
            .target = copied.target,
            .target_rotation = copied.target_rotation,
            .enabled = copied.enabled,
            .pinned = copied.pinned,
            .bend_side = copied.bend_side,
            .pole_angle = copied.pole_angle,
        });
    }
    const owned_channels = try channels.toOwnedSlice(allocator);
    errdefer allocator.free(owned_channels);
    const owned_ik = try ik.toOwnedSlice(allocator);
    return .{ .channels = owned_channels, .ik = owned_ik };
}
