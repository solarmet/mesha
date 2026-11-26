const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const Atom = mesha.Atom;
const memory = mesha.memory;
const Table = mesha.Table;
const m = figure_runtime.domain.model;
const t = figure_runtime.domain.tables;
const commands = figure_runtime.domain.command;
const library = figure_runtime.domain.library;
const fstrip = @import("filmstrip.zig");
const pose = @import("pose.zig");
const gesture = @import("gesture.zig");
const geometry = @import("geometry.zig");
const session = @import("session.zig");
const preview = @import("preview.zig");
const watches = @import("watches.zig");
const selection = @import("selection.zig");
const transport_fixture = @import("transport_fixture.zig");
const workspace = @import("workspace.zig");
const action_palette = @import("../action_palette.zig");
const names = @import("names.zig");
const prompts = @import("prompts.zig");
const state = @import("../state.zig");
const fixed_panels = @import("../fixed_panels.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const commands_mod = @import("commands.zig");
const chrome = @import("chrome.zig");
const Fixture = struct {
    mem: memory.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    transport: transport_fixture.Transport = undefined,
    doc: Atom = m.none,
    bone: u32 = 0,
    clip: u32 = 0,
    fn init(f: *Fixture) !void {
        f.mem.init(std.testing.allocator);
        try f.atoms.init(&f.mem);
        try f.tables.init(&f.mem, 96);
        try f.transport.init(&f.mem, &f.atoms, &f.tables);
        try workspace.ensure(&f.mem, &f.atoms, &f.tables);
        f.doc = f.atoms.intern("filmstrip_test");
        try library.create(&f.tables, &f.atoms, .{ .scope = mesha.resources.applicationScope(f.tables.memory), .doc = f.doc });
        const s = session.get(&f.tables);
        s.doc.* = f.doc;
        s.mode.* = f.atoms.intern("animate");
        s.tool.* = f.atoms.intern("select");
        f.bone = (try f.apply(.{ .add_bone = .{ .doc = f.doc, .name = f.atoms.intern("root"), .length = 50, .flags = 10, .make_stroke = true, .layer = 1 } })).?;
        f.clip = (try f.apply(.{ .add_clip = .{ .doc = f.doc, .name = f.atoms.intern("walk"), .frames = 16, .fps = 8 } })).?;
        _ = try f.apply(.{ .capture_clip_key = .{ .doc = f.doc, .clip = f.clip, .frame = 0 } });
        _ = try f.apply(.{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 1 }} } });
        _ = try f.apply(.{ .capture_clip_key = .{ .doc = f.doc, .clip = f.clip, .frame = 8 } });
        try f.transport.synchronize();
        fstrip.reconcile(&f.tables, &f.atoms);
    }
    fn preparePreview(f: *Fixture) !void {
        _ = try f.transport.preparePreview();
    }
    fn deinit(f: *Fixture) void {
        figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
        f.tables.deinit();
        f.atoms.deinit();
        f.mem.deinit();
    }
    fn apply(f: *Fixture, payload: mesha.plugin.figure_api.Payload) !?u32 {
        return commands.apply(&f.atoms, &f.tables, payload);
    }
    fn drain(f: *Fixture, allow_failure: bool) !void {
        try f.transport.drain(allow_failure);
    }
    fn settle(f: *Fixture) !void {
        try f.drain(false);
        fstrip.settle(&f.tables, &f.atoms);
        gesture.settle(&f.tables, &f.atoms);
        try f.drain(false);
        fstrip.reconcile(&f.tables, &f.atoms);
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
    fn select(f: *Fixture, frame: u32) !void {
        for (try fstrip.keys(&f.tables, &f.atoms)) |k| if (k.frame == frame) {
            try fstrip.selectKey(&f.tables, &f.atoms, k);
            try f.settle();
            return;
        };
        return error.MissingKey;
    }
    fn revision(f: *Fixture) u64 {
        return t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, f.doc).?, t.Document).?.revision.*;
    }
    fn savedRotation(f: *Fixture, frame: u32) !?f32 {
        var data = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer data.deinit(std.testing.allocator);
        for (data.clip_keys) |k| if (k.clip == f.clip and k.frame == frame) {
            for (data.pose_channels) |p| if (p.pose == k.pose and p.bone == f.bone) return p.rotation;
            return null;
        };
        return error.MissingKey;
    }
};
test "filmstrip selected key observation leaves stale identity for update reconciliation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const settings = fstrip.config(&f.tables);
    const list = try fstrip.keys(&f.tables, &f.atoms);
    const selected = list[0];
    settings.selected_frame.* = selected.frame;
    settings.loaded_pose.* = selected.pose;
    settings.key_selected.* = 1;
    const present = try fstrip.selectedKey(&f.tables, &f.atoms);
    try std.testing.expectEqual(selected.pose, present.?.pose);
    const editor = session.get(&f.tables);
    editor.doc.* = session.none;
    const foreign = try fstrip.selectedKey(&f.tables, &f.atoms);
    try std.testing.expect(foreign == null);
    try std.testing.expectEqual(@as(u8, 1), settings.key_selected.*);
    try std.testing.expectEqual(selected.pose, settings.loaded_pose.*);
    editor.doc.* = f.doc;
    _ = try f.apply(.{ .delete_clip_key = .{ .doc = f.doc, .clip = f.clip, .frame = selected.frame } });
    try f.transport.synchronize();
    settings.scroll.* = 99;
    for (0..2) |_| {
        const stale = try fstrip.selectedKey(&f.tables, &f.atoms);
        try std.testing.expect(stale == null);
        try std.testing.expectEqual(@as(u8, 1), settings.key_selected.*);
        try std.testing.expectEqual(selected.pose, settings.loaded_pose.*);
        try std.testing.expectEqual(@as(u32, 99), settings.scroll.*);
    }
    fstrip.reconcile(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u8, 0), settings.key_selected.*);
    try std.testing.expectEqual(@as(u32, 0), settings.loaded_pose.*);
    try std.testing.expectEqual(@as(u32, 0), settings.scroll.*);
}

test "filmstrip positive modulo hold and onion neighbors" {
    try std.testing.expectEqual(@as(f64, 15), fstrip.boundedFrame(-0.125, 8, 16, true));
    try std.testing.expectEqual(@as(f64, 0), fstrip.boundedFrame(2, 8, 16, true));
    try std.testing.expectEqual(@as(f64, 15), fstrip.boundedFrame(100, 8, 16, false));
    try std.testing.expectEqual(@as(f64, 0), fstrip.boundedFrame(-100, 8, 16, false));
    try std.testing.expect(std.math.isFinite(fstrip.boundedFrame(1e308, 100, 16, true)));
    const list = [_]mesha.figure.read.ClipKey{ .{ .frame = 0, .pose = 1 }, .{ .frame = 8, .pose = 2 }, .{ .frame = 12, .pose = 3 } };
    try std.testing.expectEqual(@as(u32, 8), fstrip.hold(&list, 0, 16));
    try std.testing.expectEqual(@as(u32, 4), fstrip.hold(&list, 2, 16));
    try std.testing.expectEqual([2]?u32{ 3, 2 }, fstrip.ghostPoses(&list, 0, true));
    try std.testing.expectEqual([2]?u32{ null, 2 }, fstrip.ghostPoses(&list, 0, false));
    try std.testing.expectEqual([2]?u32{ 2, 3 }, fstrip.ghostPoses(&list, 10, false));
}
test "filmstrip frame delta playback pause seek step and pure preview never publish working pose or revision" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = fstrip.config(&f.tables);
    const revision = f.revision();
    const working = try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_play_pause"));
    try f.transport.tickPreview(0.5);
    try std.testing.expectEqual(@as(u32, 4), c.frame.*);
    try f.preparePreview();
    // The host's until it next publishes: the channel is kept as a copy.
    const evaluated = (try preview.evaluation(&f.tables, &f.atoms)).channels[0];
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), evaluated.rotation.?, 1e-6);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_play_pause"));
    try f.transport.tickPreview(1000);
    try std.testing.expectEqual(@as(u32, 4), c.frame.*);
    try fstrip.seek(&f.tables, &f.atoms, -1);
    try std.testing.expectEqual(@as(u32, 15), c.frame.*);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_frame_next"));
    try std.testing.expectEqual(@as(u32, 0), c.frame.*);
    try fstrip.seek(&f.tables, &f.atoms, 4);
    try f.preparePreview();
    const again = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expectEqual(evaluated, again.channels[0]);
    try std.testing.expectEqual(working, try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone));
    try std.testing.expectEqual(revision, f.revision());
    _ = try f.apply(.{ .set_clip = .{ .doc = f.doc, .id = f.clip, .loop = 0 } });
    c.playing.* = 1;
    try f.transport.tickPreview(100);
    try std.testing.expectEqual(@as(u32, 15), c.frame.*);
    try std.testing.expectEqual(@as(u8, 0), c.playing.*);
    c.playing.* = 1;
    try f.transport.tickPreview(std.math.nan(f64));
    try std.testing.expectEqual(@as(u32, 15), c.frame.*);
}
test "filmstrip frame prompt wraps or clamps without authoring and rejects a changed clip" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const scratch = try f.mem.tableScratchAllocator();
    try action_palette.ensure(scratch, &f.atoms, &f.tables);
    const action = f.atoms.intern("figure_frame_seek");
    const opened = try fstrip.handleAction(&f.tables, &f.atoms, action);
    try std.testing.expect(opened);
    // The request only queued action palette presentation, which this unit does not execute.
    const settings = fstrip.config(&f.tables);
    const revision = f.revision();
    try std.testing.expectError(error.InvalidCharacter, fstrip.submitPrompt(&f.tables, &f.atoms, names.clip_frame, "1.5"));
    try std.testing.expectEqual(@as(u32, 0), settings.frame.*);
    const wrapped = try fstrip.submitPrompt(&f.tables, &f.atoms, names.clip_frame, "-1");
    try std.testing.expect(wrapped);
    try std.testing.expectEqual(@as(u32, 15), settings.frame.*);
    try std.testing.expectEqual(revision, f.revision());

    _ = try f.apply(.{ .set_clip = .{ .doc = f.doc, .id = f.clip, .loop = 0 } });
    try f.transport.synchronize();
    const clamped_revision = f.revision();
    const clamped_end = try fstrip.submitPrompt(&f.tables, &f.atoms, names.clip_frame, "99");
    try std.testing.expect(clamped_end);
    try std.testing.expectEqual(@as(u32, 15), settings.frame.*);
    const clamped_start = try fstrip.submitPrompt(&f.tables, &f.atoms, names.clip_frame, "-1");
    try std.testing.expect(clamped_start);
    try std.testing.expectEqual(@as(u32, 0), settings.frame.*);
    try std.testing.expectEqual(clamped_revision, f.revision());

    settings.clip.* = 0;
    try std.testing.expectError(error.PromptAnimationChanged, fstrip.submitPrompt(&f.tables, &f.atoms, names.clip_frame, "4"));
    try std.testing.expectEqual(@as(u32, 0), settings.frame.*);
}

test "filmstrip actual card edge queues hold one undo and cancels before asynchronous results settle" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const rect = mesha.panels.Rect{ .x = 40, .y = 20, .w = 640, .h = 480 };
    // The fixture's clip is 16 frames, fitted to the timeline's width.
    const card = fstrip.exposureRect(rect, 16, 0, 8);
    const frame_width = fstrip.framePixels(rect, 16);
    const p = m.Vec2{ .x = card.x + card.w - 2, .y = card.y + card.h / 2 };
    try std.testing.expect(try fstrip.pointerDown(&f.tables, &f.atoms, rect, p));
    try std.testing.expect(try fstrip.pointerMove(&f.tables, &f.atoms, p.x + 3 * frame_width));
    _ = fstrip.end(fstrip.config(&f.tables), .commit);
    const pending = fstrip.config(&f.tables).pending.*;
    fstrip.reconcileResult(&f.tables, &f.atoms, session.Metadata.from(@as(mesha.figure.Payload, .{ .set_clip_hold = .{ .doc = f.doc, .clip = f.clip, .frame = 0, .hold = 6, .request = 17 } })), null);
    try std.testing.expectEqual(pending, fstrip.config(&f.tables).pending.*);
    fstrip.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u8, 1), fstrip.config(&f.tables).transaction.*);
    try f.settle();
    try std.testing.expectEqual(@as(u32, 19), fstrip.clipRow(&f.tables, &f.atoms).?.frames);
    try std.testing.expectEqual(@as(u32, 11), (try fstrip.keys(&f.tables, &f.atoms))[1].frame);
    _ = try f.apply(.{ .undo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(u32, 16), fstrip.clipRow(&f.tables, &f.atoms).?.frames);
    try std.testing.expectEqual(@as(u32, 8), (try fstrip.keys(&f.tables, &f.atoms))[1].frame);
    _ = try f.apply(.{ .redo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    try std.testing.expect(try fstrip.pointerDown(&f.tables, &f.atoms, rect, p));
    _ = try fstrip.pointerMove(&f.tables, &f.atoms, p.x + 5 * frame_width);
    workspace.focusLost(&f.tables, &f.atoms);
    try f.settle();
    try std.testing.expectEqual(@as(u32, 19), fstrip.clipRow(&f.tables, &f.atoms).?.frames);
    try std.testing.expectEqual(@as(u32, 11), (try fstrip.keys(&f.tables, &f.atoms))[1].frame);
    // A click on an already loaded edge changes neither hold nor history/revision.
    const revision = f.revision();
    _ = try fstrip.pointerDown(&f.tables, &f.atoms, rect, p);
    _ = fstrip.end(fstrip.config(&f.tables), .commit);
    try f.settle();
    try std.testing.expectEqual(revision, f.revision());
}
test "filmstrip selected-key FK gesture sync is one undo with pending final result and cancel restores both poses" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.select(0);
    const s = session.get(&f.tables);
    s.gesture_start.* = .{ .x = 50, .y = 0 };
    _ = try f.press(s.gesture_start.*, false, true);
    f.sample(.{ .x = 0, .y = 75 });
    // Deferred work owns the gesture even before the first admission succeeds.
    try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
    try std.testing.expectEqual(@as(u32, 0), gesture.get(&f.tables).in_flight.*);
    try std.testing.expect(gesture.busy(gesture.get(&f.tables)));
    const animation = fstrip.config(&f.tables);
    const frame = animation.frame.*;
    const key_selected = animation.key_selected.*;
    try std.testing.expectError(error.AnimationEditSettling, fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_play_pause")));
    try std.testing.expectError(error.AnimationEditSettling, fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_frame_next")));
    try std.testing.expectEqual(@as(u8, 0), animation.playing.*);
    try std.testing.expectEqual(frame, animation.frame.*);
    try std.testing.expectEqual(key_selected, animation.key_selected.*);
    try f.update();
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .commit));
    try f.update();
    gesture.settle(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 1), gesture.get(&f.tables).in_flight.*);
    try f.drain(false);
    try f.update();
    try std.testing.expectEqual(@as(u32, 1), gesture.get(&f.tables).in_flight.*);
    try f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), (try f.savedRotation(0)).?, 1e-6);
    try std.testing.expectEqual((try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation, try f.savedRotation(0));
    _ = try f.apply(.{ .undo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    try std.testing.expectEqual(@as(?f32, null), try f.savedRotation(0));
    try std.testing.expectEqual(@as(?f32, null), (try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation);
    _ = try f.apply(.{ .redo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    const before = (try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation;
    s.gesture_start.* = .{ .x = 0, .y = 75 };
    _ = try f.press(s.gesture_start.*, false, false);
    f.sample(.{ .x = -75, .y = 0 });
    try f.update();
    try f.drain(false);
    try f.update();
    try f.drain(false);
    const working_rotation = (try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation;
    const saved_rotation = try f.savedRotation(0);
    try std.testing.expect(working_rotation != before);
    try std.testing.expect(saved_rotation != before);
    try std.testing.expectEqual(working_rotation, saved_rotation);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), working_rotation.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi), saved_rotation.?, 1e-6);
    _ = gesture.end(gesture.get(&f.tables), .cancel);
    try f.settle();
    try std.testing.expectEqual(before, try f.savedRotation(0));
    try std.testing.expectEqual(before, (try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation);
    const revision = f.revision();
    const payload = try pose.fieldCommand(&f.tables, &f.atoms, f.bone, "angle", try pose.editableText(&f.tables, &f.atoms, f.bone, "angle"));
    try fstrip.editPose(&f.tables, &f.atoms, payload);
    try f.settle();
    try std.testing.expectEqual(revision, f.revision());
    // Off-key editing never silently inserts or changes a saved key.
    try fstrip.seek(&f.tables, &f.atoms, 4);
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 0.2 }} } });
    try f.settle();
    try std.testing.expectEqual(before, try f.savedRotation(0));
    try std.testing.expectEqual(@as(usize, 2), (try fstrip.keys(&f.tables, &f.atoms)).len);
    fstrip.config(&f.tables).playing.* = 1;
    try std.testing.expectError(error.PausePlaybackToEdit, pose.pointerDown(&f.tables, &f.atoms, .{ .x = 30, .y = 10 }, false, false));
}
test "filmstrip numeric prompt freezes key doc bone mode and no-op preserves redo" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try f.select(0);
    const s = session.get(&f.tables);
    try prompts.editTarget(&f.mem, &f.tables, &f.atoms, f.atoms.intern("bone"), f.bone, 2, .whole, null);
    // Discard only action palette presentation commands, not any document command.
    s.active_bone.* = 999;
    s.active_kind.* = f.atoms.intern("shape");
    s.active_id.* = 999;
    const payload = try prompts.fieldCommand(&f.tables, &f.atoms, s, "30");
    try std.testing.expectEqual(f.bone, payload.set_pose_channels.channels[0].bone);
    try fstrip.editPose(&f.tables, &f.atoms, payload);
    try f.settle();
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 6.0), (try f.savedRotation(0)).?, 1e-6);
    _ = try f.apply(.{ .undo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    const rev = f.revision();
    try fstrip.editPose(&f.tables, &f.atoms, try pose.fieldCommand(&f.tables, &f.atoms, f.bone, "angle", "0"));
    try f.settle();
    try std.testing.expectEqual(rev, f.revision());
    _ = try f.apply(.{ .redo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 6.0), (try f.savedRotation(0)).?, 1e-6);
    fstrip.config(&f.tables).selected_frame.* = 8;
    try std.testing.expectError(error.PromptAnimationChanged, prompts.fieldCommand(&f.tables, &f.atoms, s, "45"));
    s.doc.* = f.atoms.intern("other");
    try std.testing.expectError(error.PromptDocumentChanged, prompts.fieldCommand(&f.tables, &f.atoms, s, "45"));
}
test "filmstrip capture unique names deep duplicate independent poses key delete clip settings and rejected command cancel" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = fstrip.config(&f.tables);
    try fstrip.seek(&f.tables, &f.atoms, 4);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_key_add"));
    try f.settle();
    try std.testing.expectEqual(@as(u8, 1), c.key_selected.*);
    try std.testing.expectEqual(@as(usize, 3), (try fstrip.keys(&f.tables, &f.atoms)).len);
    const pose_id = fstrip.reconcileSelectedKey(&f.tables, &f.atoms).?.pose;
    const poses = try t.family(&f.tables, f.doc, "poses");
    try std.testing.expectEqual(f.atoms.intern("walk_f4"), poses.getRow(t.find(poses, f.doc, pose_id).?, m.Row(m.Pose)).?.name.*);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_key_delete"));
    try f.settle();
    try std.testing.expect(t.find(poses, f.doc, pose_id) != null);
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_key_add"));
    try f.settle();
    const second_id = fstrip.reconcileSelectedKey(&f.tables, &f.atoms).?.pose;
    try std.testing.expectEqual(f.atoms.intern("walk_f4_1"), poses.getRow(t.find(poses, f.doc, second_id).?, m.Row(m.Pose)).?.name.*);
    try fstrip.edit(&f.tables, &f.atoms, .{ .duplicate_clip = .{ .doc = f.doc, .id = f.clip, .name = f.atoms.intern("copy") } });
    try f.settle();
    const duplicate = c.clip.*;
    const list = try fstrip.keys(&f.tables, &f.atoms);
    for (list) |k| try std.testing.expect(k.pose != pose_id and k.pose != second_id);
    try f.select(0);
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 0.8 }} } });
    try f.settle();
    try std.testing.expectEqual(@as(?f32, null), try f.savedRotation(0));
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_clip_loop"));
    try f.settle();
    try std.testing.expectEqual(@as(u8, 0), fstrip.clipRow(&f.tables, &f.atoms).?.loop);
    try fstrip.edit(&f.tables, &f.atoms, .{ .set_clip = .{ .doc = f.doc, .id = duplicate, .fps = 20, .frames = 24 } });
    try f.settle();
    try std.testing.expectEqual(@as(f32, 20), fstrip.clipRow(&f.tables, &f.atoms).?.fps);
    const rev = f.revision();
    try fstrip.edit(&f.tables, &f.atoms, .{ .set_clip = .{ .doc = f.doc, .id = duplicate, .frames = 1 } });
    try f.drain(true);
    try std.testing.expectEqual(rev, f.revision());
    fstrip.settle(&f.tables, &f.atoms);
    try f.drain(false);
    try std.testing.expectEqual(@as(u8, 0), c.transaction.*);
    try std.testing.expectEqual(@as(u32, 24), fstrip.clipRow(&f.tables, &f.atoms).?.frames);
    try std.testing.expectEqual(rev + 1, f.revision()); // Existing journal cancel invalidates compiled previews.
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_clip_delete"));
    try f.settle();
    try std.testing.expectEqual(f.clip, c.clip.*);
    try std.testing.expect(t.find(poses, f.doc, second_id) != null);
}
test "filmstrip Animate structural guards and clip outliner are separate from pose and bone actions" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const s = session.get(&f.tables);
    s.active_kind.* = f.atoms.intern("bone");
    inline for (.{ "figure_delete_bone", "figure_delete_branch", "figure_reparent", "figure_mirror_branch", "figure_rename", "figure_ik_values" }) |name| try std.testing.expectError(error.PoseRigEditRequiresRig, pose.guardRigAction(session.get(&f.tables), f.atoms.intern(name)));
    try pose.guardRigAction(session.get(&f.tables), f.atoms.intern("figure_key_delete"));
    const nodes = try selection.outlinerNodes(std.testing.allocator, &f.tables, &f.atoms);
    defer std.testing.allocator.free(nodes);
    var found = false;
    for (nodes) |node| if (node.kind == f.atoms.intern("clip") and node.id == f.clip) {
        found = true;
    };
    try std.testing.expect(found);
}

const GhostContext = struct {
    const Color = mesha.color.Color;
    const Budget = struct {
        paths: usize = 1024,
        commands: usize = 65536,
        points: usize = 65536,
        draws: usize = 1024,
        uniforms: usize = 1024,
        gpu_points: usize = 65536,
        shapes: usize = 2048,
        gpu_vertices: usize = 262144,
        cpu_vertices: usize = 65536,
        indirect_draws: usize = 1024,
        layer_targets: usize = 8,
        stroke_divisions: usize = 23,
        fringe_width: f32 = 1,
        miter_limit: f32 = 10,
        tess_tol: f32 = 0.25,
        alpha: f32 = 1,
    };
    budget: Budget = .{},
    matrix: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    color: Color = Color.black,
    alpha: f32 = 1,
    count: usize = 0,
    colors: [4]Color = undefined,
    paints: [4]mesha.roop.Paint = undefined,
    paint_count: usize = 0,
    alphas: [4]f32 = undefined,
    depth: usize = 0,
    layer_alpha: f32 = 1,
    pub fn layerDepth(c: *@This()) usize {
        return c.depth;
    }
    pub fn reserveLayers(_: *@This(), _: usize) !void {}
    pub fn beginLayer(c: *@This(), options: mesha.roop.layer_stream.Begin) !void {
        c.depth += 1;
        c.layer_alpha *= options.opacity;
    }
    pub fn endLayer(c: *@This()) !void {
        c.depth -= 1;
        if (c.depth == 0) c.layer_alpha = 1;
    }
    pub fn currentTransform(c: *@This()) [6]f32 {
        return c.matrix;
    }
    pub fn pathBudget(c: *@This()) Budget {
        return c.budget;
    }
    pub fn save(_: *@This()) void {}
    pub fn restore(_: *@This()) void {}
    pub fn setTransform(c: *@This(), matrix: [6]f32) void {
        c.matrix = matrix;
    }
    pub fn globalAlpha(c: *@This(), alpha: f32) void {
        c.alpha = alpha;
    }
    pub fn lineCap(_: *@This(), _: enum { butt, round, square }) void {}
    pub fn lineJoin(_: *@This(), _: enum { miter, round, bevel }) void {}
    pub fn beginPath(_: *@This()) void {}
    pub fn moveTo(_: *@This(), _: f32, _: f32) void {}
    pub fn lineTo(_: *@This(), _: f32, _: f32) void {}
    pub fn closePath(_: *@This()) void {}
    pub fn pathWinding(_: *@This(), _: enum { cw, ccw }) void {}
    pub fn fillColor(c: *@This(), color: Color) void {
        c.color = color;
    }
    pub fn strokeColor(c: *@This(), color: Color) void {
        c.color = color;
    }
    pub fn fillPaint(c: *@This(), paint: mesha.roop.Paint) void {
        c.strokePaint(paint);
    }
    pub fn strokePaint(c: *@This(), paint: mesha.roop.Paint) void {
        c.paints[c.paint_count] = paint;
        c.paint_count += 1;
    }
    pub fn strokeGlow(_: *@This(), _: mesha.roop.Color, _: f32) void {}
    pub fn strokeWidth(_: *@This(), _: f32) void {}
    pub fn fill(c: *@This()) void {
        c.stroke();
    }
    pub fn stroke(c: *@This()) void {
        c.colors[c.count] = c.color;
        c.alphas[c.count] = c.alpha * c.layer_alpha;
        c.count += 1;
    }
};
test "filmstrip onions render red green at thirty percent with independent inputs and GPU budget reservation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = fstrip.config(&f.tables);
    c.onion.* = 1;
    c.frame.* = 4;
    const compiled = try library.compiled(&f.mem, &f.tables, &f.atoms, f.doc);
    const source_color = compiled.shapes[0].source.stroke_color;
    const revision = f.revision();
    const working = try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone);
    c.preview.* = 1;
    c.seconds.* = 0.5;
    c.playing.* = 1;
    try f.preparePreview();
    const clock = c.seconds.*;
    var ctx = GhostContext{};
    try fstrip.renderOnionSkins(&f.tables, &ctx);
    try std.testing.expectEqual(clock, c.seconds.*);
    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    try std.testing.expectEqual(mesha.roop.rgba(255, 0, 0, 255), ctx.colors[0]);
    try std.testing.expectEqual(mesha.roop.rgba(0, 255, 0, 255), ctx.colors[1]);
    try std.testing.expectEqual(@as(f32, 0.3), ctx.alphas[0]);
    try std.testing.expectEqual(@as(f32, 0.3), ctx.alphas[1]);
    try std.testing.expectEqual(source_color, compiled.shapes[0].source.stroke_color);
    try std.testing.expectEqual(working, try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone));
    try std.testing.expectEqual(revision, f.revision());
    c.onion.* = 0;
    ctx.count = 0;
    try fstrip.renderOnionSkins(&f.tables, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
    c.onion.* = 1;
    ctx.budget.draws = 0;
    try fstrip.renderOnionSkins(&f.tables, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}

test "filmstrip undoing a key load clears auto-key relationship instead of overwriting an unrelated saved pose" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.select(0);
    _ = try f.apply(.{ .undo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    workspace.reconcileResult(&f.tables, &f.atoms, session.Metadata.from(@as(mesha.figure.Payload, .{ .undo = .{ .doc = f.doc } })), null);
    const c = fstrip.config(&f.tables);
    try std.testing.expectEqual(@as(u8, 0), c.key_selected.*);
    try std.testing.expectEqual(@as(u8, 1), c.preview.*);
    try std.testing.expectEqual(@as(?f32, 1), (try pose.readAuthoredChannels(&f.tables, &f.atoms, f.bone)).rotation);
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 0.4 }} } });
    try f.settle();
    try std.testing.expectEqual(@as(?f32, null), try f.savedRotation(0));
    try std.testing.expectEqual(@as(?f32, 1), try f.savedRotation(8));
}

test "filmstrip leaving Animate for Rig and history there require a fresh card load before auto key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    const second = (try f.apply(.{ .add_bone = .{ .doc = f.doc, .name = f.atoms.intern("second"), .length = 30 } })).?;
    _ = try f.apply(.{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = second, .rotation = 0.7 }} } });
    const s = session.get(&f.tables);
    const c = fstrip.config(&f.tables);
    try f.select(0);
    try std.testing.expect(try pose.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_tool_ik")));
    try f.settle();
    try std.testing.expectEqual(@as(u8, 0), c.key_selected.*);
    const undo: mesha.plugin.figure_api.Payload = .{ .undo = .{ .doc = f.doc } };
    const result = f.apply(undo);
    workspace.reconcileResult(&f.tables, &f.atoms, session.Metadata.from(@as(mesha.figure.Payload, undo)), result);
    _ = try result;
    try std.testing.expectEqual(@as(u8, 0), c.key_selected.*);
    // Working-only editing must not restore the old relationship on reentry.
    s.mode.* = f.atoms.intern("animate");
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = second, .rotation = 1.1 }} } });
    try f.settle();
    _ = try fstrip.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_mode_animate"));
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 0.4 }} } });
    try f.settle();
    try std.testing.expectEqual(@as(?f32, null), try f.savedRotation(0));
    var data = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer data.deinit(std.testing.allocator);
    const key = (try fstrip.keys(&f.tables, &f.atoms))[0];
    for (data.pose_channels) |p| try std.testing.expect(p.pose != key.pose or p.bone != second);
}

test "filmstrip foreign same-frame pose replacement rejects frozen numeric prompt and disables stale auto key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const second = (try f.apply(.{ .add_bone = .{ .doc = f.doc, .name = f.atoms.intern("second"), .length = 30 } })).?;
    _ = try f.apply(.{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{ .{ .bone = f.bone, .rotation = -0.4 }, .{ .bone = second, .rotation = 0.7 } } } });
    const replacement = (try f.apply(.{ .save_pose = .{ .doc = f.doc, .name = f.atoms.intern("replacement") } })).?;
    try f.transport.synchronize();
    try f.select(0);
    const s = session.get(&f.tables);
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try prompts.editTarget(&f.mem, &f.tables, &f.atoms, f.atoms.intern("bone"), f.bone, 2, .whole, null);
    const payload: mesha.plugin.figure_api.Payload = .{ .set_clip_key = .{ .doc = f.doc, .clip = f.clip, .frame = 0, .pose = replacement } };
    const result = f.apply(payload);
    workspace.reconcileResult(&f.tables, &f.atoms, session.Metadata.from(@as(mesha.figure.Payload, payload)), result);
    _ = try result;
    try f.transport.synchronize();
    try std.testing.expectError(error.PromptAnimationChanged, prompts.fieldCommand(&f.tables, &f.atoms, s, "30"));
    try std.testing.expectEqual(@as(u8, 0), fstrip.config(&f.tables).key_selected.*);
    try fstrip.editPose(&f.tables, &f.atoms, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = f.bone, .rotation = 0.3 }} } });
    try f.settle();
    try std.testing.expectEqual(@as(?f32, -0.4), try f.savedRotation(0));
    var data = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer data.deinit(std.testing.allocator);
    var found = false;
    for (data.pose_channels) |p| if (p.pose == replacement and p.bone == second) {
        found = true;
        try std.testing.expectEqual(@as(f32, 0.7), p.rotation);
    };
    try std.testing.expect(found);
    try f.select(0);
    try std.testing.expectEqual(replacement, fstrip.reconcileSelectedKey(&f.tables, &f.atoms).?.pose);
}

test "filmstrip duration shortening normalizes displayed frame sample and next step from one time" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const c = fstrip.config(&f.tables);
    inline for (.{ true, false }) |loop| {
        _ = try f.apply(.{ .set_clip = .{ .doc = f.doc, .id = f.clip, .frames = 16, .loop = @intFromBool(loop) } });
        try f.transport.synchronize();
        try fstrip.seek(&f.tables, &f.atoms, 15);
        try fstrip.edit(&f.tables, &f.atoms, .{ .set_clip = .{ .doc = f.doc, .id = f.clip, .frames = 12 } });
        try f.settle();
        const expected: u32 = if (loop) 3 else 11;
        try std.testing.expectEqual(expected, c.frame.*);
        try std.testing.expectEqual(@as(f64, @floatFromInt(expected)) / 8, c.seconds.*);
        const compiled = try library.compiled(&f.mem, &f.tables, &f.atoms, f.doc);
        try f.preparePreview();
        const actual = try preview.evaluation(&f.tables, &f.atoms);
        const a = (try f.mem.frameScratchAllocator()).allocator;
        const input = try figure_runtime.domain.sample.clip(a, compiled, f.clip, @as(f64, @floatFromInt(expected)) / 8);
        var wanted = try figure_runtime.domain.eval.evaluateInputs(a, compiled, input.channels, input.ik);
        defer wanted.deinit(a);
        try std.testing.expectEqual(wanted.bones[0].tip, actual.bones[0].tip);
        try fstrip.seek(&f.tables, &f.atoms, @as(i64, c.frame.*) + 1);
        try std.testing.expectEqual(@as(u32, if (loop) 4 else 11), c.frame.*);
        try std.testing.expectEqual(@as(f64, @floatFromInt(c.frame.*)) / 8, c.seconds.*);
    }
}

test "filmstrip inspectable f32 phase bounded loops pause and unsupported duration overflow" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const source = f.tables.findByName(f.atoms.intern(fstrip.name)).?;
    const schema = source.getSchema();
    try std.testing.expectEqual(Table.FieldType.f32, schema.fields[schema.fieldIndex("seconds").?].field_type.?);
    const c = fstrip.config(&f.tables);
    c.playing.* = 1;
    try f.transport.tickPreview(0.125);
    try std.testing.expectEqual(@as(f32, 0.125), c.seconds.*);
    for (0..2000) |_| try f.transport.tickPreview(12345.125);
    try std.testing.expect(c.seconds.* >= 0 and c.seconds.* < 2);
    c.playing.* = 0;
    const paused = c.seconds.*;
    try f.transport.tickPreview(1);
    try std.testing.expectEqual(paused, c.seconds.*);
    _ = try f.apply(.{ .set_clip = .{ .doc = f.doc, .id = f.clip, .fps = std.math.floatMin(f32), .frames = std.math.maxInt(u32) } });
    try f.transport.synchronize();
    try std.testing.expectError(error.TimeOverflow, fstrip.seek(&f.tables, &f.atoms, 1));
    c.playing.* = 1;
    try f.transport.tickPreview(1);
    try std.testing.expectEqual(@as(u8, 0), c.playing.*);
    try std.testing.expectEqual(paused, c.seconds.*);
    fstrip.reconcile(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(f32, 0), c.seconds.*);
    try std.testing.expectEqual(@as(u32, 0), c.frame.*);
}

test "filmstrip Tools coordinates are independent of full Stage capture" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const panels_mod = mesha.panels;
    const input = mesha.input;
    try state.ensureViewFocus(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try panels_mod.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    panels_mod.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
    // The editor's fixed panels, whose figure stage being shown is when the figure editor runs.
    try fixed_panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    fixed_panels.layOutNow(&f.tables, &f.atoms, .figure_stage);
    state.setViewFocus(&f.tables, &f.atoms, f.atoms.intern(workspace.canvas_id));
    const s = workspace.session.get(&f.tables);
    s.mode.* = f.atoms.intern("design");
    s.tool.* = f.atoms.intern("stick");
    const viewport = workspace.canvasViewport(&f.tables, &f.atoms).?;
    const bounds = viewport;
    try std.testing.expectEqual(viewport, bounds);
    // The stage's header strip: on the stage, but off the canvas.
    const tools = panels_mod.Rect{ .x = viewport.x, .y = viewport.y - 60, .w = 60, .h = 60 };
    inline for (.{ false, true }) |empty| {
        s.doc.* = if (empty) m.none else f.doc;
        inline for (.{ 12, 24, 36, 48 }) |x| {
            const point = m.Vec2{ .x = tools.x + x, .y = tools.y + 46 };
            try std.testing.expect(!geometry.contains(bounds, point));
            const event = input.MouseButtonMsg{ .x = point.x, .y = point.y };
            const pressed: mesha.sequencer.Message = .{ .tag = f.atoms.intern("figure_pointer_down"), .payload = std.mem.asBytes(&event) };
            try std.testing.expect(workspace.handle(&f.mem, &f.tables, &f.atoms, pressed));
            try std.testing.expectEqual(@as(u8, 0), s.gesture_active.*);
            try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
        }
    }
    const tiny = mesha.panels.Rect{ .x = 10, .y = 20, .w = 80, .h = 32 };
    try std.testing.expectEqual(@as(f32, 32), tiny.h);
    try std.testing.expectEqual(@as(f32, 20), tiny.y);
}

test "filmstrip focused Timeline Space subscription toggles playback once" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const panels_mod = mesha.panels;
    try state.ensureViewFocus(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try panels_mod.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    panels_mod.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
    // The editor's fixed panels, whose figure stage being shown is when the figure editor runs.
    try fixed_panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    fixed_panels.layOutNow(&f.tables, &f.atoms, .figure_stage);
    state.setViewFocus(&f.tables, &f.atoms, f.atoms.intern(workspace.canvas_id));
    // The view's subscribe kernel alone, as the frame's last system runs it.
    const subscribing: mesha.sequencer.Sequencer = .{ .name = "subscribing", .steps = &.{.{ .system = subscriber() }} };
    try mesha.sequencer.ensureInboxes(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, &subscribing);
    editor_sequencer.run(&f.mem, &f.atoms, &f.tables, &subscribing, null);
    var down_count: usize = 0;
    var up_count: usize = 0;
    const rows = f.tables.findByName(workspace.input_subscriptions).?;
    var subscribed = rows.query(mesha.input.SubscriptionRow);
    while (subscribed.next()) |row| switch (row.view.subscription.*) {
        .key_down => |key| if (key.key == .space) {
            down_count += 1;
            const pressed: mesha.sequencer.Message = .{ .tag = key.tag };
            try std.testing.expect(workspace.handle(&f.mem, &f.tables, &f.atoms, pressed));
        },
        .key_up => |key| if (key.key == .space) {
            up_count += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), down_count);
    try std.testing.expectEqual(@as(usize, 1), up_count);
    try std.testing.expectEqual(@as(u8, 1), fstrip.config(&f.tables).playing.*);
}

fn subscriber() mesha.sequencer.System {
    return .{
        .name = "test_subscriber",
        .root = workspace.figure_root,
        .claims = claimsNothing,
        .access = subscriberAccess,
        .kernels = &.{.{ .name = "test_subscriber.subscribe", .run = workspace.subscribe }},
    };
}

fn claimsNothing(tag: mesha.Atom) bool {
    _ = tag;
    return false;
}

fn subscriberAccess(frame: *const mesha.sequencer.Frame) mesha.sequencer.Access {
    _ = frame;
    var access: mesha.sequencer.Access = .{};
    access.writeAll(&.{ workspace.input_subscriptions, workspace.time_subscriptions });
    return access;
}

test "filmstrip ignores stale animation frames while the figure stage is not shown" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The editor's fixed panels, whose figure stage being shown is when the figure editor runs.
    try fixed_panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    const settings = fstrip.config(&f.tables);
    settings.playing.* = 1;
    settings.seconds.* = 0;
    const frame_tag = f.atoms.intern("figure_animation_frame");
    const frame = mesha.time.FrameMsg{
        .raw_dt = 0.125,
        .dt = 0.125,
        .frame_index = 0,
    };
    const animation_only: mesha.sequencer.Sequencer = .{ .name = "animation_only", .steps = &.{.{ .system = fstrip.system() }} };
    try mesha.sequencer.ensureInboxes(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, &animation_only);
    const cases = [_]struct {
        layout: fixed_panels.FixtureLayout,
        expected_seconds: f32,
    }{
        .{ .layout = .empty, .expected_seconds = 0 },
        .{ .layout = .figure_stage, .expected_seconds = 0.125 },
        .{ .layout = .empty, .expected_seconds = 0.125 },
    };
    for (cases) |case| {
        fixed_panels.layOutNow(&f.tables, &f.atoms, case.layout);
        try mesha.sequencer.deliverMessage(&f.tables, mesha.sequencer.inboxOf(fstrip.system()), frame_tag, &.{}, std.mem.asBytes(&frame));
        editor_sequencer.run(&f.mem, &f.atoms, &f.tables, &animation_only, null);
        try std.testing.expectEqual(case.expected_seconds, settings.seconds.*);
    }
}

test "the filmstrip hears the time system's frames only while its clip plays" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try state.ensureViewFocus(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    try mesha.panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    mesha.panels.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
    try fixed_panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    fixed_panels.layOutNow(&f.tables, &f.atoms, .figure_stage);
    const animation_only: mesha.sequencer.Sequencer = .{ .name = "animation_only", .steps = &.{.{ .system = fstrip.system() }} };
    try mesha.sequencer.ensureInboxes(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables, &animation_only);
    const inbox = mesha.sequencer.inboxOf(fstrip.system());
    // Animating, paused, playing, paused again: each frame heard draws the figure's panels.
    for ([_]u8{ 0, 1, 0 }) |playing| {
        fstrip.config(&f.tables).playing.* = playing;
        editor_sequencer.run(&f.mem, &f.atoms, &f.tables, &animation_only, null);
        var frames_heard: u8 = 0;
        var rows = f.tables.findByName(workspace.time_subscriptions).?.query(mesha.time.SubscriptionRow);
        while (rows.next()) |row| {
            if (row.view.inbox.* == inbox and row.view.kind.* == .frame) frames_heard += 1;
        }
        try std.testing.expectEqual(playing, frames_heard);
    }
}

test "the figure stage shown in place of the focused panel, closed and shown again keeps the document session" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const panels_mod = mesha.panels;
    try panels_mod.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    panels_mod.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
    const retained_session = workspace.session.get(&f.tables);
    retained_session.view_zoom.* = 2.5;
    retained_session.active_id.* = 42;
    fstrip.config(&f.tables).frame.* = 7;
    try fixed_panels.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
    const figure_stage = f.atoms.intern(workspace.canvas_id);
    workspace.showStage(&f.tables, &f.atoms);
    // Shown alone: Layers and Properties open only when asked for.
    try std.testing.expect(fixed_panels.panelShown(&f.tables, figure_stage));
    try std.testing.expect(!fixed_panels.panelShown(&f.tables, workspace.outliner_panel.id));
    try std.testing.expect(!fixed_panels.panelShown(&f.tables, workspace.inspector_panel.id));
    fixed_panels.hidePanel(&f.tables, figure_stage);
    try std.testing.expect(!fixed_panels.panelShown(&f.tables, figure_stage));
    workspace.showStage(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(f32, 2.5), retained_session.view_zoom.*);
    try std.testing.expectEqual(@as(u32, 42), retained_session.active_id.*);
    try std.testing.expectEqual(@as(u32, 7), fstrip.config(&f.tables).frame.*);
}

test "preview shows rest in Design, the working pose elsewhere, and nothing once closed" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const figure = mesha_runtime.figure;
    const context = session.figureContext(&f.tables, &f.atoms);
    const s = session.get(&f.tables);
    s.mode.* = f.atoms.intern("design");
    try f.preparePreview();
    // The host's, until it next publishes: read before the next preparation.
    const rest = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rest.channels[0].rotation.?, 1e-6);
    s.mode.* = f.atoms.intern("animate");
    try f.preparePreview();
    const working = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expectApproxEqAbs(@as(f32, 1), working.channels[0].rotation.?, 1e-6);
    _ = try commands_mod.submit(context, .{ .close_doc = .{ .doc = f.doc, .discard = true } });
    // Admitting the close already hides the canvas, before the close runs.
    try std.testing.expectError(error.Busy, preview.ready(&f.tables, &f.atoms));
    try f.drain(false);
    try std.testing.expectError(error.MissingDefinition, figure.definitionInfo(context, f.doc));
}

test "filmstrip public presentation override precedes tint and preserves solid and gradient alpha" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const figure = mesha.figure;
    const context = session.figureContext(&f.tables, &f.atoms);
    const data = try figure_runtime.readDefinition(context, f.doc, (try f.mem.frameScratchAllocator()).allocator);
    const shape = data.shapes[0].id;
    _ = try f.apply(.{ .set_shape = .{ .doc = f.doc, .id = shape, .stroke_color = .{ 0, 0, 255, 96 } } });
    const options = figure.RenderOptions{ .color_override = .{ 255, 0, 0 }, .tint = .{ 128, 255, 255, 128 }, .opacity = 0.3 };
    var solid = GhostContext{};
    _ = try figure_runtime.render(context, .{ .definition = f.doc }, (try f.mem.frameScratchAllocator()).allocator, .{}, options, &solid);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), solid.colors[0].r, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), solid.colors[0].b);
    try std.testing.expectApproxEqAbs(@as(f32, 96.0 / 255.0), solid.colors[0].a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3 * 128.0 / 255.0), solid.alphas[0], 1e-6);
    _ = try f.apply(.{ .set_paint = .{ .doc = f.doc, .shape = shape, .stroke = true, .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 50, .y = 0 }, .colors = .{ .{ 0, 0, 255, 64 }, .{ 0, 0, 255, 192 } } } });
    var gradient = GhostContext{};
    _ = try figure_runtime.render(context, .{ .definition = f.doc }, (try f.mem.frameScratchAllocator()).allocator, .{}, options, &gradient);
    try std.testing.expectEqual(@as(usize, 1), gradient.paint_count);
    const paint = gradient.paints[0];
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), paint.inner_color.r, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), paint.outer_color.r, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), paint.inner_color.b);
    try std.testing.expectEqual(@as(f32, 0), paint.outer_color.b);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), paint.inner_color.a, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 192.0 / 255.0), paint.outer_color.a, 1e-6);
}

test "preview clip clock wraps a looping clip and stops a one-shot on its last frame" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const animation = fstrip.config(&f.tables);
    animation.preview.* = 1;
    animation.playing.* = 1;
    animation.seconds.* = 0;
    try f.preparePreview();
    try preview.advance(&f.tables, &f.atoms, 0.125);
    try std.testing.expectEqual(@as(f32, 0.125), animation.seconds.*);
    const shown = try f.transport.preparePreview();
    try std.testing.expectEqual(@as(f32, 0.125), shown.pose.clip.time);
    _ = try f.apply(.{ .set_clip = .{ .doc = f.doc, .id = f.clip, .loop = 0 } });
    try f.transport.synchronize();
    try preview.advance(&f.tables, &f.atoms, 3);
    try std.testing.expectEqual(@as(u8, 0), animation.playing.*);
    try std.testing.expectEqual(@as(f32, 1.875), animation.seconds.*);
}

test "the canvas reads an empty stage when the watched figure closes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.preparePreview();
    // Open, the canvas reads the definition and the pose it shows, as its drawing does.
    var reads = session.ReadContext{ .tables = &f.tables, .atoms = &f.atoms };
    defer reads.deinit();
    _ = try reads.definition(f.doc);
    _ = try preview.evaluation(&f.tables, &f.atoms);

    // A layer is being dragged in the outliner as the figure closes under the editor, which
    // still watches it, and the host publishes.
    session.get(&f.tables).outliner_drag.* = 1;
    try library.close(&f.tables, &f.atoms, .{ .doc = f.doc, .discard = true });
    try f.transport.synchronize();
    // With its document gone, the drag goes with the selection.
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), session.get(&f.tables).outliner_drag.*);
    try std.testing.expectEqual(f.doc, session.get(&f.tables).doc.*);
    const closed = watches.answer(&f.tables, .rest).?;
    try std.testing.expectEqual(mesha.figure.Failure.missing_definition, closed.published.failure);
    try std.testing.expect(closed.published.content == null);
    try std.testing.expect(closed.published.evaluation == null);
    try std.testing.expect(closed.published.bounds == null);
    // The pose the canvas showed fails alike, with nothing to draw. It was declared from the
    // catalog before the close: a frame later, with no pose to show, the canvas stops watching one.
    const shown = watches.answer(&f.tables, .shown).?;
    try std.testing.expectEqual(mesha.figure.Failure.missing_definition, shown.published.failure);
    try std.testing.expect(shown.published.drawing == null);
    try std.testing.expect(shown.published.evaluation == null);
    try f.transport.synchronize();
    try std.testing.expect(watches.answer(&f.tables, .shown) == null);
    // What the canvas draws from is gone: it draws the stage alone.
    try std.testing.expectError(error.NotReady, reads.definition(f.doc));
    try std.testing.expectError(error.NotReady, preview.ready(&f.tables, &f.atoms));
    try std.testing.expectError(error.NotReady, preview.evaluation(&f.tables, &f.atoms));
}

test "preview main render budget rejection returns overlays for canvas continuation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.preparePreview();
    const editor = session.get(&f.tables);
    try session.table(&f.tables).assignString(editor.status, "authoritative sentinel");
    const flags_before = editor.flags.*;
    const animation = fstrip.config(&f.tables);
    const seconds_before = animation.seconds.*;
    const selected_before = animation.key_selected.*;
    for (0..2) |_| {
        var ctx = GhostContext{};
        ctx.budget.draws = 0;
        const rendered = try preview.renderEvaluated(&f.tables, &f.atoms, &ctx);
        // The host's, until it next publishes.
        const overlay = rendered.evaluation.?;
        // Actual exhausted rendering still produces usable fallback overlays.
        try std.testing.expect(overlay.bones.len > 0);
        try std.testing.expectEqual(@as(usize, 0), ctx.count);
        try std.testing.expectEqual(@as(?anyerror, error.BudgetExceeded), rendered.render_error);
        try std.testing.expectEqual(@as(?anyerror, null), rendered.fallback_error);

        // The failure is kept for the person to be told of, and the status stays as it was.
        chrome.noteRendering(session.feedback(&f.tables), .{ .main_error = rendered.render_error });
        const noted: u32 = @intFromError(error.BudgetExceeded);
        try std.testing.expectEqual(noted, session.feedback(&f.tables).render_artwork_error.*);
        const status_after = session.statusText(&f.tables);
        try std.testing.expectEqualStrings("authoritative sentinel", status_after);
        try std.testing.expectEqual(flags_before, editor.flags.*);
        try std.testing.expectEqual(seconds_before, animation.seconds.*);
        try std.testing.expectEqual(selected_before, animation.key_selected.*);
    }
}
