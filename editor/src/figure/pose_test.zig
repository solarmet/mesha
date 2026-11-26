const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const math = mesha.math;
const Atom = mesha.Atom;
const memory = mesha.memory;
const Table = mesha.Table;
const m = figure_runtime.domain.model;
const t = figure_runtime.domain.tables;
const commands = figure_runtime.domain.command;
const library = figure_runtime.domain.library;
const pose = @import("pose.zig");
const gesture = @import("gesture.zig");
const session = @import("session.zig");
const asks = @import("asks.zig");
const preview = @import("preview.zig");
const Fixture = struct {
    mem: memory.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    transport: @import("transport_fixture.zig").Transport = undefined,
    fn init(f: *Fixture) !void {
        f.mem.init(std.testing.allocator);
        try f.atoms.init(&f.mem);
        try f.tables.init(&f.mem, 64);
        try f.transport.init(&f.mem, &f.atoms, &f.tables);
        try session.ensure(&f.mem, &f.atoms, &f.tables);
        try pose.ensure(&f.mem, &f.atoms, &f.tables);
    }
    fn deinit(f: *Fixture) void {
        // A test may end with requests the host has not applied; the host applies them before
        // it stops.
        f.transport.drain(true) catch {};
        figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
        f.tables.deinit();
        f.atoms.deinit();
        f.mem.deinit();
    }
    fn create(f: *Fixture, name: []const u8) !Atom {
        const doc = f.atoms.intern(name);
        try library.create(&f.tables, &f.atoms, .{ .scope = mesha.resources.applicationScope(f.tables.memory), .doc = doc });
        session.get(&f.tables).doc.* = doc;
        session.get(&f.tables).mode.* = f.atoms.intern("animate");
        return doc;
    }
    fn drain(f: *Fixture) !void {
        try f.transport.drain(false);
    }
    /// A pointer move Msg: it only replaces the gesture's latest sample.
    fn sample(f: *Fixture, point: m.Vec2) void {
        const pointer = gesture.Pointer{ .point = point, .screen = point, .modifiers = 0 };
        _ = gesture.record(gesture.get(&f.tables), pointer);
    }
    /// A pose press, and the host's answer to the solve an Auto IK press asks, which the drag
    /// goes on from.
    fn press(f: *Fixture, point: m.Vec2, alt: bool, control: bool) !bool {
        const pressed = try pose.pointerDown(&f.tables, &f.atoms, point, alt, control);
        try f.transport.answerSolves();
        return pressed;
    }
    /// A flush of the drag, and the host's answer to the solve an Auto IK flush asks, which the
    /// gesture system previews.
    fn update(f: *Fixture) !void {
        gesture.update(&f.tables, &f.atoms);
        try f.transport.answerSolves();
    }
};
test "pose FKDrag fixed affine press frame has no drift over 1000 moves and preserves off-axis offset" {
    const parent = math.Affine2f.fromTRS(30, -14, 0.6, -2, 0.7);
    const origin = parent.apply(.{ .x = 10, .y = 4 });
    const start = m.Vec2.add(origin, parent.applyVector(.{ .x = 40, .y = 6 }));
    const end = m.Vec2.add(origin, parent.applyVector(.{ .x = 20, .y = 50 }));
    var drag = pose.FKDrag.init(parent.inverse().?, origin, start, 0.3, 80, 2);
    try std.testing.expect(drag.move(start, true) == null);
    const expected = 0.3 + std.math.atan2(@as(f32, 50), 20) - std.math.atan2(@as(f32, 6), 40);
    for (0..1000) |i| {
        _ = drag.move(.{ .x = @floatFromInt(i), .y = -20 }, true);
        const value = drag.move(end, true).?;
        try std.testing.expectApproxEqAbs(expected, value.rotation, 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 80) * @sqrt(@as(f32, 2900)) / @sqrt(@as(f32, 1636)), value.length.?, 1e-4);
        try std.testing.expect(drag.move(end, false).?.length == null);
    }
    var root = pose.FKDrag.init(.identity, m.zero, m.zero, 0.7, 40, 2);
    try std.testing.expect(root.move(.{ .x = 1, .y = 0 }, false) == null);
    try std.testing.expect(root.move(.{ .x = 2, .y = 0 }, false) == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7 + std.math.pi / 2.0), root.move(.{ .x = 0, .y = 4 }, false).?.rotation, 1e-6);
}
test "pose editor drag settles final update before one commit, Escape cancels and static grabs reject" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_drag");
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50, .flags = 10 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, true);
    f.sample(.{ .x = 0, .y = 75 });
    try f.update();
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .commit));
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try std.testing.expect(s.tx_active.* == 0);
    try f.drain();
    try std.testing.expect(s.tx_active.* != 0);
    try f.update();
    try f.drain();
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    const p = try pose.readAuthoredChannels(&f.tables, &f.atoms, bone);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), p.rotation.?, 1e-6);
    try std.testing.expectEqual(@as(f32, 75), p.length.?);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try f.transport.synchronize();
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, bone)).rotation == null);
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, false);
    f.sample(.{ .x = 25, .y = 40 });
    try f.update();
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .cancel));
    try f.drain();
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, bone)).rotation == null);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_bone = .{ .doc = doc, .id = bone, .flags = 6 } });
    try f.transport.synchronize();
    try std.testing.expectError(error.StaticBone, pose.pointerDown(&f.tables, &f.atoms, .{ .x = 50, .y = 0 }, false, false));
}
test "pose clipboard transfers authored sparse rows by compatible names not stale IDs and rejects atomically" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_copy");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50 } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{.{ .bone = root, .rotation = 0.4 }} } });
    try f.transport.synchronize();
    try pose.copy(&f.tables, &f.atoms);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .reset_pose = .{ .doc = doc } });
    try f.transport.synchronize();
    _ = try commands.apply(&f.atoms, &f.tables, try pose.paste(&f.tables, &f.atoms));
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(f32, 0.4), (try pose.readAuthoredChannels(&f.tables, &f.atoms, root)).rotation.?);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .delete_bone = .{ .doc = doc, .id = root } });
    const recreated = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50 } })).?;
    try f.transport.synchronize();
    try std.testing.expect(recreated != root);
    _ = try commands.apply(&f.atoms, &f.tables, try pose.paste(&f.tables, &f.atoms));
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(f32, 0.4), (try pose.readAuthoredChannels(&f.tables, &f.atoms, recreated)).rotation.?);
    const other = try f.create("pose_destination");
    const mapped = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = other, .name = f.atoms.intern("root"), .length = 50 } })).?;
    try f.transport.synchronize();
    _ = try commands.apply(&f.atoms, &f.tables, try pose.paste(&f.tables, &f.atoms));
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(f32, 0.4), (try pose.readAuthoredChannels(&f.tables, &f.atoms, mapped)).rotation.?);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_bone = .{ .doc = other, .id = mapped, .name = f.atoms.intern("different") } });
    try f.transport.synchronize();
    const rev = t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, other).?, t.Document).?.revision.*;
    try std.testing.expectError(error.MissingPoseClipboardBone, pose.paste(&f.tables, &f.atoms));
    try std.testing.expectEqual(rev, t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, other).?, t.Document).?.revision.*);
    const bs = f.tables.findByName(f.atoms.intern(pose.clipboard_bones_name)).?;
    var q = bs.query(m.Row(pose.ClipboardBone));
    const b = t.readRow(pose.ClipboardBone, q.next().?.view);
    _ = try t.insert(pose.ClipboardBone, &f.tables, f.tables.findHandleByName(bs.name).?, b);
    try std.testing.expectError(error.IncompatiblePoseClipboardRig, pose.paste(&f.tables, &f.atoms));
}

test "pose clipboard row budgets reject overflow and duplicate names before any command" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    _ = try f.create("clipboard_bounds");
    try f.transport.synchronize();
    const bs = f.tables.findByName(f.atoms.intern(pose.clipboard_bones_name)).?;
    const ks = f.tables.findByName(f.atoms.intern(pose.clipboard_ik_name)).?;
    pose.config(&f.tables).clipboard_valid.* = 1;
    // Past the former 4096-row limit the tables grow. These blank rows match no rig, so only
    // the absence of a crash on paste is checked, not its result.
    for (0..4097) |_| _ = try t.insert(pose.ClipboardBone, &f.tables, f.tables.findHandleByName(bs.name).?, .{});
    try std.testing.expectEqual(@as(u32, 4097), bs.count());
    _ = pose.paste(&f.tables, &f.atoms) catch {};
    bs.clear();
    for (0..4097) |_| _ = try t.insert(pose.ClipboardIK, &f.tables, f.tables.findHandleByName(ks.name).?, .{});
    try std.testing.expectEqual(@as(u32, 4097), ks.count());
    _ = pose.paste(&f.tables, &f.atoms) catch {};
    ks.clear();
    const doc = session.get(&f.tables).doc.*;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("one"), .length = 10 } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("two"), .length = 10 } });
    try f.transport.synchronize();
    try pose.copy(&f.tables, &f.atoms);
    var q = bs.query(m.Row(pose.ClipboardBone));
    const first = q.next().?.view;
    q.next().?.view.name.* = first.name.*;
    try std.testing.expectError(error.AmbiguousPoseClipboardName, pose.paste(&f.tables, &f.atoms));
}

test "pose active IK outgoing numeric and FK deltas apply once without copying solved inputs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("outgoing_editor");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 60, .flags = 10 } })).?;
    const end = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .parent = root, .connected = true, .length = 50, .flags = 11 } })).?;
    const outgoing = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .parent = end, .local = .{ .x = 50, .y = 7 }, .rotation = 0.25, .length = 20, .flags = 10 } })).?;
    const descendant = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .parent = outgoing, .connected = true, .rotation = -0.2, .length = 15, .flags = 11 } })).?;
    const ik = (try commands.apply(&f.atoms, &f.tables, .{ .add_ik = .{ .doc = doc, .end_bone = end, .flags = 3 } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_ik_target = .{ .doc = doc, .id = ik, .target = .{ .x = 150, .y = 20 }, .target_rotation = 1.2 } });
    const saved = (try commands.apply(&f.atoms, &f.tables, .{ .save_pose = .{ .doc = doc, .name = f.atoms.intern("untouched") } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    for ([_]u32{ outgoing, descendant, root }) |id| {
        s.active_bone.* = id;
        inline for (.{ "angle", "length", "local", "scale" }) |field| {
            const text = try pose.editableText(&f.tables, &f.atoms, id, field);
            const payload = try pose.fieldCommand(&f.tables, &f.atoms, id, field, text);
            try std.testing.expectEqual(@as(usize, 0), payload.set_pose_channels.channels.len);
            _ = try commands.apply(&f.atoms, &f.tables, payload);
            try f.transport.synchronize();
        }
        const form = try pose.numericText(&f.tables, &f.atoms, id);
        _ = try pose.submitPrompt(&f.tables, &f.atoms, @import("names.zig").bone_values, form);
        try f.drain();
        try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, id)).rotation == null);
        try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, id)).length == null);
    }
    // Numerics address displayed angle by its shortest delta; all other sparse fields survive.
    const before = (try library.compiled(&f.mem, &f.tables, &f.atoms, doc));
    const e = try figure_runtime.domain.eval.evaluateCompiled((try f.mem.frameScratchAllocator()).allocator, before, .working);
    const index = before.rig.index.ids.get(outgoing).?;
    const display = e.channels[index].rotation;
    const text = try std.fmt.allocPrint((try f.mem.frameScratchAllocator()).allocator, "{d}", .{(display + 0.1) * 180 / std.math.pi});
    _ = try commands.apply(&f.atoms, &f.tables, try pose.fieldCommand(&f.tables, &f.atoms, outgoing, "angle", text));
    try f.transport.synchronize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), (try pose.readAuthoredChannels(&f.tables, &f.atoms, outgoing)).rotation.?, 1e-6);
    const rig = try library.compiled(&f.mem, &f.tables, &f.atoms, doc);
    const current = try figure_runtime.domain.eval.evaluateCompiled((try f.mem.frameScratchAllocator()).allocator, rig, .working);
    const b = current.bones[rig.rig.index.ids.get(outgoing).?];
    s.view_zoom.* = 2;
    s.gesture_start.* = b.tip;
    _ = try f.press(b.tip, false, false);
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .commit));
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    const end_point = m.Vec2.add(b.origin, math.Affine2f.fromTRS(0, 0, 0.12, 1, 1).applyVector(m.Vec2.sub(b.tip, b.origin)));
    s.gesture_start.* = b.tip;
    _ = try f.press(b.tip, false, false);
    f.sample(end_point);
    try f.update();
    try f.drain();
    try f.update();
    try f.drain();
    try std.testing.expectApproxEqAbs(@as(f32, 0.47), (try pose.readAuthoredChannels(&f.tables, &f.atoms, outgoing)).rotation.?, 1e-5);
    _ = gesture.end(gesture.get(&f.tables), .cancel);
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), (try pose.readAuthoredChannels(&f.tables, &f.atoms, outgoing)).rotation.?, 1e-6);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .apply_pose = .{ .doc = doc, .id = saved } });
    try f.transport.synchronize();
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, outgoing)).rotation == null);
}

test "only Rig admits structural rig actions; working-pose and explicit runtime commands are not guarded" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_guard");
    const s = session.get(&f.tables);
    s.active_kind.* = f.atoms.intern("bone");
    inline for (.{ "figure_delete_bone", "figure_delete_branch", "figure_reparent", "figure_mirror_branch", "figure_ik_values", "figure_rename" }) |name| {
        try std.testing.expectError(error.PoseRigEditRequiresRig, pose.guardRigAction(session.get(&f.tables), f.atoms.intern(name)));
    }
    inline for (.{ "figure_pose_reset_bone", "figure_pose_reset", "figure_pose_delete", "figure_pose_mirror", "figure_ik_target" }) |name| try pose.guardRigAction(session.get(&f.tables), f.atoms.intern(name));
    const id = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 10 } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_bone = .{ .doc = doc, .id = id, .length = 20 } });
    // Design's Delete removes artwork; the rest of the skeleton's structure is Rig's alone.
    s.mode.* = f.atoms.intern("design");
    try pose.guardRigAction(session.get(&f.tables), f.atoms.intern("figure_delete_bone"));
    inline for (.{ "figure_delete_branch", "figure_reparent", "figure_mirror_branch", "figure_ik_values", "figure_rename" }) |name| {
        try std.testing.expectError(error.PoseRigEditRequiresRig, pose.guardRigAction(session.get(&f.tables), f.atoms.intern(name)));
    }
    s.mode.* = f.atoms.intern("rig");
    inline for (.{ "figure_delete_bone", "figure_delete_branch", "figure_reparent", "figure_mirror_branch", "figure_ik_values", "figure_rename" }) |name| try pose.guardRigAction(session.get(&f.tables), f.atoms.intern(name));
}

test "pose inspector captures explicit bone target from bound shape and retains it until submit" {
    const prompts = @import("prompts.zig");
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("inspector_target");
    try f.transport.synchronize();
    // Completion presentation uses editor action palette tables, not a mock prompt.
    try @import("../action_palette.zig").ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 60, .flags = 10 } })).?;
    const other = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 40 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    s.active_kind.* = f.atoms.intern("shape");
    s.active_id.* = 99;
    s.active_bone.* = root;
    const before = (try t.boneTable(&f.tables, doc)).getRow(t.find((try t.boneTable(&f.tables, doc)), doc, root).?, t.Bone).?.rotation.*;
    try f.transport.synchronize();
    try prompts.editTarget(&f.mem, &f.tables, &f.atoms, f.atoms.intern("bone"), root, 2, .whole, null);
    try std.testing.expectEqual(f.atoms.intern("angle"), s.prompt_field.*);
    try std.testing.expectEqual(root, s.prompt_id.*);
    try std.testing.expectEqual(f.atoms.intern("bone"), s.prompt_target_kind.*);
    s.active_kind.* = f.atoms.intern("layer");
    s.active_id.* = other;
    s.active_bone.* = other;
    const payload = try prompts.fieldCommand(&f.tables, &f.atoms, s, "30");
    try std.testing.expect(payload == .set_pose_channels);
    try std.testing.expectEqual(root, payload.set_pose_channels.channels[0].bone);
    _ = try commands.apply(&f.atoms, &f.tables, payload);
    try f.transport.synchronize();
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 6.0), (try pose.readAuthoredChannels(&f.tables, &f.atoms, root)).rotation.?, 1e-6);
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, other)).rotation == null);
    try std.testing.expectEqual(before, (try t.boneTable(&f.tables, doc)).getRow(t.find((try t.boneTable(&f.tables, doc)), doc, root).?, t.Bone).?.rotation.*);
    s.doc.* = f.atoms.intern("changed_document");
    try std.testing.expectError(error.PromptDocumentChanged, prompts.fieldCommand(&f.tables, &f.atoms, s, "40"));
    s.doc.* = doc;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .delete_bone = .{ .doc = doc, .id = root } });
    try f.transport.synchronize();
    try std.testing.expectError(error.PromptTargetMissing, prompts.fieldCommand(&f.tables, &f.atoms, s, "40"));
    try library.close(&f.tables, &f.atoms, .{ .doc = doc, .discard = true });
    const replacement = try f.create("inspector_target");
    const replacement_bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = replacement, .length = 99 } })).?;
    try f.transport.synchronize();
    try std.testing.expectEqual(doc, replacement);
    try std.testing.expectEqual(root, replacement_bone);
    try f.transport.synchronize();
    try std.testing.expectError(error.PromptDocumentChanged, prompts.fieldCommand(&f.tables, &f.atoms, s, "40"));
}

test "selection inspector keyboard clamps stale shape index to highlighted layer field while explicit targets stay strict" {
    const prompts = @import("prompts.zig");
    const select = @import("selection.zig");
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("keyboard_inspector");
    try @import("../action_palette.zig").ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = m.zero }, .{ .p = .{ .x = 10, .y = 0 } } } } })).?;
    const s = session.get(&f.tables);
    s.mode.* = f.atoms.intern("design");
    select.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    s.inspector_field.* = 10;
    select.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, false, false);
    try std.testing.expectEqual(@as(u32, 10), s.inspector_field.*);
    try f.transport.synchronize();
    try prompts.editField(&f.mem, &f.tables, &f.atoms, null);
    try std.testing.expectEqual(f.atoms.intern("order"), s.prompt_field.*);
    try std.testing.expectEqual(f.atoms.intern("layer"), s.prompt_target_kind.*);
    try std.testing.expectEqual(@as(u32, 1), s.prompt_id.*);
    s.prompt_field.* = m.none;
    try std.testing.expectError(error.MissingField, prompts.editTarget(&f.mem, &f.tables, &f.atoms, f.atoms.intern("layer"), 1, 8, .whole, null));
    try std.testing.expectEqual(m.none, s.prompt_field.*);
    select.clear(@import("session.zig").get(&f.tables), @import("session.zig").observed(&f.tables), @import("session.zig").selections(&f.tables));
    s.inspector_field.* = std.math.maxInt(u32);
    try prompts.editField(&f.mem, &f.tables, &f.atoms, null);
    try std.testing.expectEqual(m.none, s.prompt_field.*);
}

test "pose clipboard public capture owns sparse FK and IK while remap checks full named rig" {
    const figure = mesha.figure;
    const api = figure;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("public_pose_clipboard");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50 } })).?;
    const end = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("end"), .flags = m.BoneFlags.deform, .parent = root, .connected = true, .local = .{ .x = 50, .y = 0 }, .length = 30 } })).?;
    const ik = (try commands.apply(&f.atoms, &f.tables, .{ .add_ik = .{ .doc = doc, .name = f.atoms.intern("hand"), .end_bone = end } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose = .{ .doc = doc, .channels = &.{ .{ .bone = root, .rotation = 0.4 }, .{ .bone = end, .local = .{ .x = 3, .y = 4 } } }, .ik = &.{.{ .ik = ik, .target = .{ .x = 20, .y = 30 }, .target_rotation = 0.6, .enabled = 0, .pinned = 1, .bend_side = -1, .pole_angle = 1.2 }} } });
    const a = std.testing.allocator;
    const context = @import("session.zig").figureContext(&f.tables, &f.atoms);
    var captured = blk: {
        var data = try figure_runtime.readDefinition(context, doc, a);
        defer data.deinit(a);
        break :blk try figure.capturePoseClipboard(data, a);
    };
    defer captured.deinit(a);
    // Source snapshot has been freed and working pose replaced; payload is independent.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .reset_pose = .{ .doc = doc } });
    var destination = try figure_runtime.readDefinition(context, doc, a);
    defer destination.deinit(a);
    var bones = [_]api.read.Bone{ destination.bones[0], destination.bones[1] };
    var controllers = [_]api.read.IK{destination.ik[0]};
    bones[0].id = 101;
    bones[1].id = 202;
    bones[1].parent = 101;
    controllers[0].id = 303;
    controllers[0].end_bone = 202;
    var mapped_rig = destination;
    mapped_rig.bones = &bones;
    mapped_rig.ik = &controllers;
    const result = try figure.remapPoseClipboard(mapped_rig, captured, a);
    defer a.free(result.channels);
    defer a.free(result.ik);
    try std.testing.expectEqual(@as(usize, 2), result.channels.len);
    try std.testing.expectEqualDeep(api.PoseChannels{ .bone = 101, .rotation = 0.4 }, result.channels[0]);
    try std.testing.expectEqualDeep(api.PoseChannels{ .bone = 202, .local = .{ .x = 3, .y = 4 } }, result.channels[1]);
    try std.testing.expectEqualDeep(api.PoseIK{ .ik = 303, .target = .{ .x = 20, .y = 30 }, .target_rotation = 0.6, .enabled = 0, .pinned = 1, .bend_side = -1, .pole_angle = 1.2 }, result.ik[0]);
    controllers[0].chain += 1;
    try std.testing.expectError(error.IncompatiblePoseClipboardRig, figure.remapPoseClipboard(mapped_rig, captured, a));
    controllers[0].chain -= 1;
    bones[1].parent = 0;
    try std.testing.expectError(error.IncompatiblePoseClipboardRig, figure.remapPoseClipboard(mapped_rig, captured, a));
}

test "pose gesture ignores unrelated requests and retains ownership after terminal failure" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_ownership");
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50 } });
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    const c = gesture.get(&f.tables);
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, false);
    f.sample(.{ .x = 0, .y = 50 });
    try f.update();
    const pending = c.in_flight.*;
    gesture.reconcileResult(&f.tables, &f.atoms, .{ .doc = doc, .request = 99999, .operation = .set_pose_channels }, true);
    try std.testing.expectEqual(pending, c.in_flight.*);
    try std.testing.expect(gesture.intentOf(c) != .failure);
    try f.drain();
    try f.update();
    try f.drain();
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .commit));
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    gesture.reconcileResult(&f.tables, &f.atoms, .{ .doc = doc, .request = 99999, .operation = .commit }, false);
    try std.testing.expectEqual(gesture.Phase.awaiting_terminal, gesture.phaseOf(c));
    // Deterministic rejected-terminal fixture: runtime transaction is still open.
    gesture.reconcileResult(&f.tables, &f.atoms, .{ .doc = doc, .request = c.terminal_request.*, .operation = .commit }, true);
    try std.testing.expectEqual(gesture.Phase.draining, gesture.phaseOf(c));
    try std.testing.expectEqual(gesture.Intent.failure, gesture.intentOf(c));
    try std.testing.expectEqual(@as(u8, 1), s.tx_active.*);
}

test "pose cancellation reason survives delayed edits and idle focus loss does not relabel it" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_cancel_feedback");
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50 } });
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    const workspace = @import("workspace.zig");
    const ux = @import("session.zig");
    const prompts = @import("prompts.zig");
    for ([_]bool{ false, true }) |focus_loss| {
        s.gesture_start.* = .{ .x = 50, .y = 0 };
        _ = try f.press(s.gesture_start.*, false, false);
        f.sample(.{ .x = 0, .y = 50 });
        try f.update();
        try f.drain();
        try f.update();
        const drag = gesture.get(&f.tables);
        try std.testing.expectEqual(@as(u8, 1), drag.transaction_owned.*);
        try std.testing.expectEqual(@as(u32, 1), drag.in_flight.*);
        if (focus_loss) workspace.focusLost(&f.tables, &f.atoms) else workspace.cancel(&f.tables, &f.atoms);
        const expected = if (focus_loss) "Cancelled: focus lost" else "Cancelled with Esc";
        try std.testing.expectEqualStrings(expected, ux.informationText(&f.tables));
        prompts.status(session.table(&f.tables), session.get(&f.tables), session.feedback(&f.tables), "Retained error");
        // Expiry before delayed acknowledgements must not revive cancellation text.
        if (focus_loss) prompts.tickInformation(session.feedback(&f.tables), 5);
        const after_tick = if (focus_loss) "" else expected;
        try f.drain();
        try std.testing.expectEqualStrings(after_tick, ux.informationText(&f.tables));
        try f.update();
        try f.drain();
        gesture.settle(&f.tables, &f.atoms);
        try f.drain();
        const drag_state = gesture.get(&f.tables);
        try std.testing.expectEqual(gesture.Phase.idle, gesture.phaseOf(drag_state));
        try std.testing.expectEqualStrings(after_tick, ux.informationText(&f.tables));
        workspace.focusLost(&f.tables, &f.atoms);
        try std.testing.expectEqualStrings(after_tick, ux.informationText(&f.tables));
        prompts.inform(session.feedbackTable(&f.tables), session.feedback(&f.tables), "Newer feedback");
        workspace.focusLost(&f.tables, &f.atoms);
        prompts.tickInformation(session.feedback(&f.tables), std.math.nan(f32));
        prompts.tickInformation(session.feedback(&f.tables), -1);
        try std.testing.expectEqualStrings("Newer feedback", ux.informationText(&f.tables));
        try f.drain();
        prompts.tickInformation(session.feedback(&f.tables), 5);
        try std.testing.expectEqualStrings("", ux.informationText(&f.tables));
        try std.testing.expectEqualStrings("Retained error", ux.statusText(&f.tables));
    }
}

test "pose latest sample survives admission pressure delayed batch and release" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_latest_sample");
    const id = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 50 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    const c = gesture.get(&f.tables);
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, false);
    for (0..session.pending_capacity) |_| {
        _ = try @import("commands.zig").submit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{} } });
    }
    for (0..1000) |i| {
        f.sample(.{ .x = @floatFromInt(i), .y = 50 });
    }
    try f.update();
    try std.testing.expectEqual(@as(u32, 0), c.in_flight.*);
    try std.testing.expect(gesture.intentOf(c) != .failure);
    try std.testing.expectEqual(@as(u8, 1), c.sample_pending.*);
    try f.drain();
    try f.update();
    try std.testing.expectEqual(@as(u32, 1), c.in_flight.*);
    try f.drain();
    try f.update();
    try std.testing.expectEqual(@as(u32, 1), c.in_flight.*);
    for (0..1000) |_| {
        f.sample(.{ .x = 0, .y = 50 });
        try f.update();
        try std.testing.expectEqual(@as(u32, 1), c.in_flight.*);
    }
    _ = gesture.end(gesture.get(&f.tables), .commit);
    gesture.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), c.terminal_request.*);
    try f.drain();
    try f.update();
    try std.testing.expectEqual(@as(u32, 1), c.in_flight.*);
    try f.drain();
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), (try pose.readAuthoredChannels(&f.tables, &f.atoms, id)).rotation.?, 1e-6);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try f.transport.synchronize();
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, id)).rotation == null);
}

test "pose automatic joint IK preserves lengths and root without controllers and explicit FK remains available" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("auto_joint");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("upper"), .length = 50 } })).?;
    const tip = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("lower"), .parent = root, .connected = true, .local = .{ .x = 50, .y = 0 }, .length = 50 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    s.gesture_start.* = .{ .x = 100, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, false);
    try std.testing.expectEqual(f.atoms.intern("pose_auto_ik"), s.gesture_kind.*);
    try std.testing.expectEqual(@as(u32, 2), pose.dragChainLength(pose.dragChainLinks(&f.tables)));
    try std.testing.expectError(error.PoseGestureSettling, pose.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_pose_chain_less")));
    f.sample(.{ .x = 50, .y = 50 });
    try f.update();
    _ = gesture.end(gesture.get(&f.tables), .commit);
    try f.drain();
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    try f.update();
    try f.drain();
    const e = try preview.workingEvaluation(&f.tables, false);
    for (e.bones) |b| {
        if (b.id == root) try std.testing.expectApproxEqAbs(@as(f32, 0), b.origin.x, 1e-4);
        if (b.id == tip) {
            try std.testing.expectApproxEqAbs(@as(f32, 50), b.tip.x, 1e-3);
            try std.testing.expectApproxEqAbs(@as(f32, 50), b.tip.y, 1e-3);
        }
    }
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, root)).length == null);
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, tip)).length == null);
    const data = try @import("session.zig").readDefinition(&f.tables, &f.atoms, doc);
    try std.testing.expectEqual(@as(usize, 0), data.ik.len);
    _ = try pose.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_pose_auto_ik"));
    s.gesture_start.* = .{ .x = 50, .y = 50 };
    _ = try f.press(s.gesture_start.*, false, false);
    try std.testing.expectEqual(f.atoms.intern("pose_fk"), s.gesture_kind.*);
    _ = gesture.end(gesture.get(&f.tables), .cancel);
    gesture.settle(&f.tables, &f.atoms);
}

test "pose Auto IK release before the last solve is answered still commits the last target" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("auto_release_early");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("upper"), .length = 50 } })).?;
    const tip = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("lower"), .parent = root, .connected = true, .local = .{ .x = 50, .y = 0 }, .length = 50 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    s.gesture_start.* = .{ .x = 100, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, false);
    try std.testing.expectEqual(f.atoms.intern("pose_auto_ik"), s.gesture_kind.*);
    // A solve is asked for the first target, and the pointer moves on and is released before
    // its answer comes.
    f.sample(.{ .x = 80, .y = 40 });
    gesture.update(&f.tables, &f.atoms);
    const asked = asks.rows(&f.tables);
    try std.testing.expect(asks.awaited(asked));
    const target: m.Vec2 = .{ .x = 50, .y = 50 };
    f.sample(target);
    const drag_state = gesture.get(&f.tables);
    try std.testing.expect(gesture.end(drag_state, .commit));
    gesture.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(gesture.Phase.draining, gesture.phaseOf(drag_state));
    try std.testing.expectEqual(@as(u32, 0), drag_state.terminal_request.*);
    // Frames go by, each answering what the last asked, until the drag has ended.
    var frames: usize = 0;
    while (gesture.busy(drag_state) and frames < 16) : (frames += 1) {
        try f.drain();
        f.transport.runGesture();
    }
    try std.testing.expect(!gesture.busy(drag_state));
    const solved = try preview.workingEvaluation(&f.tables, false);
    for (solved.bones) |bone| if (bone.id == tip) {
        try std.testing.expectApproxEqAbs(target.x, bone.tip.x, 1e-3);
        try std.testing.expectApproxEqAbs(target.y, bone.tip.y, 1e-3);
    };
    // One drag, one undo.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try f.transport.synchronize();
    try std.testing.expect((try pose.readAuthoredChannels(&f.tables, &f.atoms, tip)).rotation == null);
}

test "pose Auto IK press whose solve fails rejects the drag a frame later with the reason" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("auto_press_fails");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("upper"), .length = 50 } })).?;
    const tip = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("lower"), .parent = root, .connected = true, .local = .{ .x = 50, .y = 0 }, .length = 50 } })).?;
    try f.transport.synchronize();
    const s = session.get(&f.tables);
    s.gesture_start.* = .{ .x = 100, .y = 0 };
    _ = try pose.pointerDown(&f.tables, &f.atoms, s.gesture_start.*, false, false);
    try std.testing.expectEqual(f.atoms.intern("pose_auto_ik"), s.gesture_kind.*);
    const drag_state = gesture.get(&f.tables);
    try std.testing.expectEqual(gesture.Phase.sampling, gesture.phaseOf(drag_state));
    // The chain's end is gone by the time the host solves the press.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .delete_bone = .{ .doc = doc, .id = tip } });
    // The gesture system takes the failed answer and the drag ends, nothing having been sent.
    try f.transport.answerSolves();
    try std.testing.expect(!gesture.busy(drag_state));
    try std.testing.expectEqual(@as(u8, 0), s.gesture_active.*);
    try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
    const status = session.statusText(&f.tables);
    const named = std.mem.eql(u8, status, "MissingBone") or std.mem.eql(u8, status, "InvalidInput");
    try std.testing.expect(named);
}

test "pose selected-key no-op automatic IK submits no edit or key sync and creates no history" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("auto_noop_key");
    try f.transport.synchronize();
    const strip = @import("filmstrip.zig");
    const reads = @import("session.zig");
    try strip.ensure(&f.mem, &f.atoms, &f.tables);
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 50 } })).?;
    const clip = (try commands.apply(&f.atoms, &f.tables, .{ .add_clip = .{ .doc = doc, .name = f.atoms.intern("noop"), .frames = 8, .fps = 8 } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{.{ .bone = bone, .rotation = 0 }} } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .capture_clip_key = .{ .doc = doc, .clip = clip, .frame = 0 } });
    try f.transport.synchronize();
    const data = try reads.readDefinition(&f.tables, &f.atoms, doc);
    const key = data.clip_keys[0];
    const animation = strip.config(&f.tables);
    animation.doc.* = doc;
    animation.clip.* = clip;
    animation.selected_frame.* = 0;
    animation.loaded_pose.* = key.pose;
    animation.key_selected.* = 1;
    const s = session.get(&f.tables);
    s.mode.* = f.atoms.intern("animate");
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    try f.transport.synchronize();
    const before = (reads.definitionInfo(&f.tables, &f.atoms, doc).?).authored_revision;
    _ = try f.press(s.gesture_start.*, false, false);
    const c = pose.config(&f.tables);
    try std.testing.expectEqual(clip, c.key_clip.*);
    f.sample(.{ .x = 75, .y = 0 });
    try f.update();
    try std.testing.expectEqual(@as(u8, 1), c.has_target.*);
    try std.testing.expect(c.residual.* > 24);
    const drag_state = gesture.get(&f.tables);
    try std.testing.expectEqual(@as(u8, 0), drag_state.sample_pending.*);
    try std.testing.expectEqual(@as(u32, 0), drag_state.in_flight.*);
    try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
    _ = gesture.end(gesture.get(&f.tables), .commit);
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(before, (reads.definitionInfo(&f.tables, &f.atoms, doc).?).authored_revision);
    // Undo still removes the setup's captured key, not an extra drag history entry.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(usize, 0), (try reads.readDefinition(&f.tables, &f.atoms, doc)).clip_keys.len);
}

test "pose hover feedback shares automatic chain boundaries and distinguishes shaft FK" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("hover_feedback");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50, .flags = m.BoneFlags.deform } })).?;
    const tip = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("tip"), .parent = root, .connected = true, .length = 30, .flags = m.BoneFlags.deform } })).?;
    try f.transport.synchronize();
    const data = try @import("session.zig").readDefinition(&f.tables, &f.atoms, doc);
    var chain: [2]u32 = undefined;
    const count = pose.automaticChain(data, tip, 2, &chain);
    try std.testing.expectEqual(@as(u32, 2), count);
    try std.testing.expectEqualSlices(u32, &.{ root, tip }, chain[0..count]);
    try std.testing.expect(std.mem.startsWith(u8, pose.hoverIntent(data, tip, 1, true, chain[0..count]), "Move limb"));
    try std.testing.expect(std.mem.startsWith(u8, pose.hoverIntent(data, tip, 2, true, chain[0..count]), "Rotate bone"));
    try std.testing.expect(std.mem.startsWith(u8, pose.hoverIntent(data, tip, 1, false, &.{}), "Rotate bone (FK)"));
    try std.testing.expectEqual(@as(u32, 1), pose.automaticChain(data, tip, 1, &chain));
}

test "pose authored endpoint controller suppresses automatic hover chain" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("authored_hover");
    const root = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("root"), .length = 50, .flags = m.BoneFlags.deform } })).?;
    const tip = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = f.atoms.intern("tip"), .parent = root, .connected = true, .length = 30, .flags = m.BoneFlags.deform } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_ik = .{ .doc = doc, .end_bone = tip, .chain = 1 } });
    try f.transport.synchronize();
    const data = try @import("session.zig").readDefinition(&f.tables, &f.atoms, doc);
    var chain: [2]u32 = undefined;
    try std.testing.expect(pose.enabledEndpointController(data, tip) != null);
    try std.testing.expectEqual(@as(u32, 2), pose.automaticChain(data, tip, 2, &chain));
    try std.testing.expectEqual(@as(u32, 0), pose.automaticHoverChain(data, tip, 2, &chain));
    try std.testing.expectEqualStrings("Move authored IK target (pins preserved)", pose.hoverIntent(data, tip, 1, true, &.{}));
}

test "pose automatic drag captures a chain past the former 256 bones in table rows" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("long_chain");
    try f.transport.synchronize();
    const bone_count = 300;
    const bone_length = 10;
    var parent: u32 = 0;
    for (0..bone_count) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "link_{d}", .{i});
        const name_atom = f.atoms.intern(name);
        parent = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .name = name_atom, .parent = parent, .connected = parent != 0, .length = bone_length } })).?;
    }
    const tip = parent;
    try f.transport.synchronize();
    const settings = pose.config(&f.tables);
    settings.auto_chain_length.* = bone_count + 1;
    const editor = session.get(&f.tables);
    const start: @TypeOf(editor.gesture_start.*) = .{ .x = bone_count * bone_length, .y = 0 };
    editor.gesture_start.* = start;
    _ = try f.press(start, false, false);
    try std.testing.expectEqual(f.atoms.intern("pose_auto_ik"), editor.gesture_kind.*);
    try std.testing.expectEqual(@as(u32, bone_count), pose.dragChainLength(pose.dragChainLinks(&f.tables)));
    const drag_chain = try pose.dragChain(pose.dragChainLinks(&f.tables), std.testing.allocator);
    defer std.testing.allocator.free(drag_chain.bones);
    defer std.testing.allocator.free(drag_chain.seeds);
    try std.testing.expectEqual(tip, drag_chain.bones[bone_count - 1]);
    try std.testing.expectEqual(tip, drag_chain.seeds[bone_count - 1].bone);
    const target: @TypeOf(start) = .{ .x = bone_count * bone_length - 400, .y = 300 };
    f.sample(target);
    try f.update();
    _ = gesture.end(gesture.get(&f.tables), .commit);
    try f.drain();
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try f.drain();
    try f.update();
    try f.drain();
    const solved = try preview.workingEvaluation(&f.tables, false);
    for (solved.bones) |bone| if (bone.id == tip) {
        try std.testing.expectApproxEqAbs(target.x, bone.tip.x, 1);
        try std.testing.expectApproxEqAbs(target.y, bone.tip.y, 1);
    };
    // The outliner reports the full depth without walking the call stack or the list per level.
    const nodes = try @import("selection.zig").outlinerNodes(std.testing.allocator, &f.tables, &f.atoms);
    defer std.testing.allocator.free(nodes);
    var deepest: u32 = 0;
    for (nodes) |node| deepest = @max(deepest, node.depth);
    try std.testing.expectEqual(@as(u32, bone_count - 1), deepest);
}

test "pose rejection attribution survives actual transport consume" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("pose_consume_rejection");
    const adapter = @import("commands.zig");
    const context = mesha.figure.Context{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms };
    const request = try adapter.submit(context, .{ .commit = .{ .doc = doc } });
    const c = gesture.get(&f.tables);
    c.kind.* = @intFromEnum(gesture.Kind.pose);
    c.doc.* = doc;
    c.terminal_request.* = request;
    c.phase.* = @intFromEnum(gesture.Phase.awaiting_terminal);
    var result = mesha.figure.Result{ .request = request, .definition = doc, .current_definition = doc, .operation = .commit, .revision = 0, .outcome = .{ .failure = error.InvalidInput } };
    const diagnostic = "joint transform rejected by rig validation";
    @memcpy(result.diagnostic[0..diagnostic.len], diagnostic);
    try std.testing.expect(adapter.consume(context, result));
    try std.testing.expectEqualStrings("Pose edit rejected: joint transform rejected by rig validation", session.statusText(&f.tables));
    // The same failure on an unowned request retains the existing non-pose text.
    result.request = try adapter.submit(context, .{ .commit = .{ .doc = doc } });
    try std.testing.expect(adapter.consume(context, result));
    try std.testing.expectEqualStrings(diagnostic, session.statusText(&f.tables));
}
