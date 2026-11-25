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
const gesture = @import("gesture.zig");
const preview = @import("preview.zig");
const session = @import("session.zig");
const selection = @import("selection.zig");
const drawing = @import("drawing.zig");
const action_palette = @import("../action_palette.zig");
const weight = @import("weight.zig");
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
        // What the canvas writes when it takes the host's answers (`answerCanvas`).
        try action_palette.ensure(try f.mem.tableScratchAllocator(), &f.atoms, &f.tables);
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
    fn create(f: *Fixture, name: []const u8) !Atom {
        const id = f.atoms.intern(name);
        try library.create(&f.tables, &f.atoms, .{ .scope = mesha.resources.applicationScope(f.tables.memory), .doc = id });
        return id;
    }
};

test "drawing selection traversal wraps in outliner category and canvas mode" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("selection_traversal");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const shape1 = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = m.zero }, .{ .p = .{ .x = 10, .y = 0 } } } } })).?;
    const shape2 = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = m.zero }, .{ .p = .{ .x = 20, .y = 0 } } } } })).?;
    const editor = session.get(&f.tables);
    editor.doc.* = doc;
    editor.mode.* = f.atoms.intern("design");
    try f.transport.synchronize();
    const shape_kind = f.atoms.intern("shape");
    const nodes = try selection.categoryNodes(std.testing.allocator, &f.tables, &f.atoms, .art);
    defer std.testing.allocator.free(nodes);
    try std.testing.expect(nodes.len > 2);
    const first = nodes[0];
    const last = nodes[nodes.len - 1];
    try std.testing.expect(first.kind != last.kind);
    selection.select(&f.tables, &f.atoms, last.kind, last.id, false, false);
    try selection.selectRelative(std.testing.allocator, &f.tables, &f.atoms, .forward, .outliner_category);
    try std.testing.expectEqual(first.kind, editor.active_kind.*);
    try std.testing.expectEqual(first.id, editor.active_id.*);
    try selection.selectRelative(std.testing.allocator, &f.tables, &f.atoms, .backward, .outliner_category);
    try std.testing.expectEqual(last.kind, editor.active_kind.*);
    try std.testing.expectEqual(last.id, editor.active_id.*);
    selection.select(&f.tables, &f.atoms, shape_kind, shape2, false, false);
    try selection.selectRelative(std.testing.allocator, &f.tables, &f.atoms, .forward, .canvas_mode);
    try std.testing.expectEqual(shape_kind, editor.active_kind.*);
    try std.testing.expectEqual(shape1, editor.active_id.*);
    try selection.selectRelative(std.testing.allocator, &f.tables, &f.atoms, .backward, .canvas_mode);
    try std.testing.expectEqual(shape_kind, editor.active_kind.*);
    try std.testing.expectEqual(shape2, editor.active_id.*);
}

fn applyDrawing(f: *Fixture) !void {
    try f.transport.drain(false);
}

fn applyWeight(f: *Fixture) !void {
    try f.transport.drain(true);
}
test "weight editor settings validate atomically and screen falloff is bounded" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    try weight.ensure(&f.mem, &f.atoms, &f.tables);
    try std.testing.expect(try weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").weight_settings, "60:0.3:0.7"));
    const c = weight.config(&f.tables);
    try std.testing.expectEqual(@as(f32, 60), c.radius.*);
    try std.testing.expectError(error.InvalidBrushSettings, weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").weight_settings, "40:2:0.5"));
    try std.testing.expectEqual(@as(f32, 60), c.radius.*);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), c.strength.*, 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), weight.falloffFactor(f.atoms.intern("linear"), 30, 60));
    try std.testing.expectEqual(@as(f32, 0.84375), weight.falloffFactor(f.atoms.intern("smooth"), 15, 60));
    try std.testing.expectEqual(@as(f32, 1), weight.falloffFactor(f.atoms.intern("constant"), 59, 60));
    try std.testing.expectEqual(@as(f32, 0), weight.falloffFactor(f.atoms.intern("constant"), 60, 60));
    try std.testing.expectEqual(@as(f32, 0), weight.falloffFactor(f.atoms.intern("smooth"), 1, 0));
}
test "weight editor stroke locks numeric history and pure Test pose disposal" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("weight_tools");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    try weight.ensure(&f.mem, &f.atoms, &f.tables);
    const b1 = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .local = m.zero, .length = 40, .make_stroke = false } })).?;
    const b2 = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .parent = b1, .local = .{ .x = 40, .y = 0 }, .length = 40, .make_stroke = false } })).?;
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = .{ .x = 20, .y = 4 } }, .{ .p = .{ .x = 40, .y = 4 } }, .{ .p = .{ .x = 60, .y = 4 } } } } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = doc, .ids = &.{shape} } });
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("rig");
    s.tool.* = f.atoms.intern("weight");
    weight.sync(&f.tables, &f.atoms);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b1);
    const c = weight.config(&f.tables);
    c.point_shape.* = shape;
    c.point_index.* = 1;
    s.prompt_doc.* = doc;
    s.prompt_id.* = shape;
    const capture = session.observed(&f.tables);
    try f.transport.synchronize();
    const info = session.definitionInfo(&f.tables, &f.atoms, doc).?;
    capture.prompt_revision.* = info.authored_revision;
    capture.prompt_anchor_index.* = 1;
    c.point_shape.* = 0;
    c.point_index.* = 2;
    try std.testing.expect(try weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").weight_numeric, try std.fmt.allocPrint((try f.mem.frameScratchAllocator()).allocator, "{d}=0.5,{d}=0.5", .{ b1, b2 })));
    try applyWeight(&f);
    c.point_shape.* = shape;
    c.point_index.* = 1;
    // Lock bone 2; every generated dab and numeric edit carries the stable-ID lock list.
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b2);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_weight_lock"));
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b1);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer before.deinit(std.testing.allocator);
    try f.preparePreview();
    const press = gesture.Pointer{ .point = .{ .x = 20, .y = 4 }, .screen = .{ .x = 20, .y = 4 }, .modifiers = 0 };
    const move = gesture.Pointer{ .point = .{ .x = 40, .y = 4 }, .screen = .{ .x = 40, .y = 4 }, .modifiers = 0 };
    _ = try weight.pointerDown(&f.tables, &f.atoms, press);
    try f.transport.answerCanvas();
    _ = try weight.pointerMove(&f.tables, &f.atoms, move);
    const stroke_state = weight.stroke(&f.tables);
    try std.testing.expectEqual(@as(u32, 2), stroke_state.count.*);
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .commit));
    // Begin admission is not ownership; commit waits for every correlated result.
    gesture.update(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u8, 0), s.tx_active.*);
    try applyWeight(&f);
    try std.testing.expect(s.tx_active.* != 0);
    for (0..4) |_| {
        gesture.update(&f.tables, &f.atoms);
        try applyWeight(&f);
        if (!gesture.busy(gesture.get(&f.tables))) break;
    }
    try std.testing.expect(!gesture.busy(gesture.get(&f.tables)));
    var painted = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer painted.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, painted.points);
    for (painted.points, before.points) |p, old| {
        var old_lock: f32 = 0;
        var new_lock: f32 = 0;
        for (old.bones, old.weights) |b, v| if (b == b2) {
            old_lock = v;
        };
        for (p.bones, p.weights) |b, v| if (b == b2) {
            new_lock = v;
        };
        try std.testing.expectEqual(old_lock, new_lock);
    }
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    // An impossible two-bone locked edit cancels the entire stroke; undo removes numeric edit.
    // Recreate numeric state, unlock and verify a changed stroke cancels without history.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = doc } });
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b2);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_weight_lock"));
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b1);
    var baseline = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer baseline.deinit(std.testing.allocator);
    try f.preparePreview();
    _ = try weight.pointerDown(&f.tables, &f.atoms, move);
    try f.transport.answerCanvas();
    gesture.update(&f.tables, &f.atoms);
    try applyWeight(&f);
    gesture.update(&f.tables, &f.atoms);
    try applyWeight(&f);
    var changed = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer changed.deinit(std.testing.allocator);
    try std.testing.expect(!std.meta.eql(baseline.points[1].weights, changed.points[1].weights));
    try std.testing.expect(gesture.end(gesture.get(&f.tables), .cancel));
    gesture.update(&f.tables, &f.atoms);
    try applyWeight(&f);
    try std.testing.expect(!gesture.busy(gesture.get(&f.tables)));
    var canceled = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer canceled.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, baseline.points, canceled.points);
    const revision = t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, doc).?, t.Document).?.revision.*;
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_test_pose"));
    s.prompt_id.* = b1;
    s.prompt_target_kind.* = f.atoms.intern("bone");
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b2);
    _ = try weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").test_rotation, "65");
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b1);
    try f.preparePreview();
    const evaluated = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expect(@abs(evaluated.bones[0].tip.y) > 20);
    try std.testing.expectEqual(revision, t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, doc).?, t.Document).?.revision.*);
    s.mode.* = f.atoms.intern("design");
    s.tool.* = f.atoms.intern("select");
    weight.sync(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u8, 0), c.test_pose.*);
    try f.preparePreview();
    const rest = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rest.bones[0].tip.y, 1e-5);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_shape = .{ .doc = doc, .id = shape, .stroke_width = 9 } });
    s.prompt_id.* = shape;
    s.prompt_target_kind.* = f.atoms.intern("shape");
    try std.testing.expectError(error.PromptTargetChanged, weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").weight_numeric, "0=1"));
}

test "weight Test rotation pick threshold root reference and off-axis offset are pure" {
    const Drag = weight.TestRotationDrag;
    for ([_]f32{ 1, 2 }) |zoom| {
        var root = Drag.init(m.zero, m.zero, zoom, 0.7);
        try std.testing.expect(root.move(m.zero) == null);
        try std.testing.expect(root.move(.{ .x = 2 / zoom, .y = 0 }) == null);
        try std.testing.expect(root.move(.{ .x = 4 / zoom, .y = 0 }) == null);
        try std.testing.expectApproxEqAbs(@as(f32, 0.7 + std.math.pi / 2.0), root.move(.{ .x = 0, .y = 8 / zoom }).?, 1e-6);
        const start = m.Vec2{ .x = 40, .y = 3 / zoom };
        var off_axis = Drag.init(start, m.zero, zoom, 0.7);
        try std.testing.expect(off_axis.move(start) == null);
        try std.testing.expect(off_axis.move(.{ .x = start.x + 2 / zoom, .y = start.y }) == null);
        const next = m.Vec2{ .x = start.x + 4 / zoom, .y = start.y };
        const expected = 0.7 + std.math.atan2(next.y, next.x) - std.math.atan2(start.y, start.x);
        try std.testing.expectApproxEqAbs(expected, off_axis.move(next).?, 1e-6);
    }
    var wrapped = Drag.init(.{ .x = -10, .y = 0.1 }, m.zero, 100, 0.7);
    try std.testing.expect(@abs(wrapped.move(.{ .x = -10, .y = -0.1 }).? - 0.7) < 0.03);
}

test "weight Test rotation cancellation restores exact scratch mask rotation and evaluation" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("rotation_cancel");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    try weight.ensure(&f.mem, &f.atoms, &f.tables);
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .rotation = 0.7, .length = 100, .make_stroke = false } })).?;
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("rig");
    s.tool.* = f.atoms.intern("weight");
    try f.transport.synchronize();
    weight.sync(&f.tables, &f.atoms);
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), bone);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_test_pose"));
    s.prompt_doc.* = doc;
    s.prompt_id.* = bone;
    s.prompt_target_kind.* = f.atoms.intern("bone");
    _ = try weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").test_rotation, "55");
    const tab = f.tables.findByName(f.atoms.intern(weight.bones_name)).?;
    var q = tab.query(m.Row(weight.BoneState));
    const row = q.next().?.view;
    const alloc = (try f.mem.frameScratchAllocator()).allocator;
    const revision = t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, doc).?, t.Document).?.revision.*;
    const history_count = f.tables.findByName(f.atoms.intern("editor_figure_history")).?.count();
    for ([_]u32{ 0, m.Channels.local, m.Channels.local | m.Channels.rotation }) |mask| {
        row.mask.* = mask;
        row.rotation.* = 0.9599311;
        try f.preparePreview();
        // The host's until it next publishes, so the test keeps copies.
        const published = try preview.evaluation(&f.tables, &f.atoms);
        const baseline: mesha.figure.Evaluation = .{ .effective_revision = published.effective_revision, .bones = try alloc.dupe(mesha.figure.EvaluatedBone, published.bones), .skin = try alloc.dupe(mesha.math.Affine2f, published.skin), .channels = &.{}, .ik = &.{} };
        const mid = m.Vec2.scale(baseline.bones[0].tip, 0.5);
        try f.preparePreview();
        const press = gesture.Pointer{ .point = mid, .screen = mid, .modifiers = gesture.Modifiers.alt };
        const moved = m.Vec2{ .x = mid.x - 20, .y = mid.y + 20 };
        const move = gesture.Pointer{ .point = moved, .screen = moved, .modifiers = gesture.Modifiers.alt };
        _ = try weight.pointerDown(&f.tables, &f.atoms, press);
        _ = try weight.pointerMove(&f.tables, &f.atoms, move);
        try std.testing.expect(row.mask.* & m.Channels.rotation != 0);
        weight.endTestRotation(session.get(&f.tables), weight.config(&f.tables), weight.boneStates(&f.tables), .cancel);
        s.gesture_active.* = 0;
        try std.testing.expectEqual(mask, row.mask.*);
        try std.testing.expectEqual(@as(f32, 0.9599311), row.rotation.*);
        try f.preparePreview();
        const restored = try preview.evaluation(&f.tables, &f.atoms);
        try std.testing.expectEqualDeep(baseline.bones, restored.bones);
        try std.testing.expectEqualDeep(baseline.skin, restored.skin);
    }
    try std.testing.expectEqual(revision, t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, doc).?, t.Document).?.revision.*);
    try std.testing.expectEqual(history_count, f.tables.findByName(f.atoms.intern("editor_figure_history")).?.count());
}

test "weight numeric anchor selection invalidates only on successful active-document history changes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("numeric_history");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    try weight.ensure(&f.mem, &f.atoms, &f.tables);
    session.get(&f.tables).doc.* = doc;
    const c = weight.config(&f.tables);
    c.point_shape.* = 7;
    c.point_index.* = 1;
    weight.reconcileResult(weight.config(&f.tables), session.get(&f.tables), session.Metadata.from(@as(mesha.figure.Payload, .{ .undo = .{ .doc = f.atoms.intern("other_doc") } })), false);
    try std.testing.expectEqual(@as(u32, 7), c.point_shape.*);
    weight.reconcileResult(weight.config(&f.tables), session.get(&f.tables), session.Metadata.from(@as(mesha.figure.Payload, .{ .undo = .{ .doc = doc } })), true);
    try std.testing.expectEqual(@as(u32, 7), c.point_shape.*);
    weight.reconcileResult(weight.config(&f.tables), session.get(&f.tables), session.Metadata.from(@as(mesha.figure.Payload, .{ .undo = .{ .doc = doc } })), false);
    try std.testing.expectEqual(@as(u32, 0), c.point_shape.*);
    c.point_shape.* = 7;
    weight.reconcileResult(weight.config(&f.tables), session.get(&f.tables), session.Metadata.from(@as(mesha.figure.Payload, .{ .redo = .{ .doc = doc } })), false);
    try std.testing.expectEqual(@as(u32, 0), c.point_shape.*);
}

test {
    _ = @import("pose_test.zig");
    _ = @import("filmstrip_test.zig");
    _ = @import("gesture_test.zig");
}

test "the outliner reads a figure whose first revision never compiled" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("never_compiled");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    session.get(&f.tables).doc.* = doc;
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 10, .make_stroke = true, .layer = 1 } })).?;
    // Before the host first compiles it, the bone's stroke comes to follow a bone it does not have.
    const shapes = try t.family(&f.tables, doc, "shapes");
    var shape_rows = shapes.query(t.Shape);
    const stroke = shape_rows.next().?.view;
    stroke.bone.* = 99999;
    t.markDirty(&f.tables, &f.atoms, doc);
    try std.testing.expectError(error.CompileFailed, f.transport.synchronize());
    try std.testing.expect(session.definitionInfo(&f.tables, &f.atoms, doc).?.effective_revision == null);
    // The canvas has nothing to show, but the outliner lists the authored bone and its stroke.
    try std.testing.expectError(error.NotReady, preview.ready(&f.tables, &f.atoms));
    const a = std.testing.allocator;
    const nodes = try selection.outlinerNodes(a, &f.tables, &f.atoms);
    defer a.free(nodes);
    var bone_listed = false;
    var stroke_listed = false;
    for (nodes) |node| {
        if (node.kind == f.atoms.intern("bone") and node.id == bone) bone_listed = true;
        if (node.kind == f.atoms.intern("shape") and node.id == stroke.id.*) stroke_listed = true;
    }
    try std.testing.expect(bone_listed);
    try std.testing.expect(stroke_listed);
    try std.testing.expect(session.isValidObject(&f.tables, &f.atoms, doc, f.atoms.intern("bone"), bone));
}

test "artist blend folder outliner collapse is editor-only and inherits eligibility" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("folder_editor");
    try f.transport.synchronize();
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    session.get(&f.tables).doc.* = doc;
    const folder = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{1} } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = folder, .visible = 0, .locked = 1 } });
    try f.transport.synchronize();
    const a = std.testing.allocator;
    const before = try selection.outlinerNodes(a, &f.tables, &f.atoms);
    defer a.free(before);
    try std.testing.expectEqual(@as(usize, 2), before.len);
    try std.testing.expect(before[0].folder);
    try std.testing.expect(!before[1].visible and before[1].locked);
    try selection.toggleCollapse(session.collapsedFolders(&f.tables), session.get(&f.tables), folder);
    const collapsed = try selection.outlinerNodes(a, &f.tables, &f.atoms);
    defer a.free(collapsed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.len);
    try std.testing.expect(collapsed[0].collapsed);
    var data = try t.snapshot(a, &f.tables, &f.atoms, doc);
    defer data.deinit(a);
    // Collapsing is the editor's state: the saved file names nothing of it.
    const saved = try figure_runtime.domain.file.checked(a, &f.atoms, data);
    defer a.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "collapsed") == null);
    try selection.toggleCollapse(session.collapsedFolders(&f.tables), session.get(&f.tables), folder);
    try std.testing.expect(!selection.collapsed(session.collapsedFolders(&f.tables), session.get(&f.tables), folder));
}

test "artist blend subtree deletion prunes selection without undo restoration" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("folder_selection");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    session.get(&f.tables).doc.* = doc;
    const folder = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{1} } })).?;
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, false, false);
    try selection.toggleCollapse(session.collapsedFolders(&f.tables), session.get(&f.tables), folder);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .delete_layer = .{ .doc = doc, .id = folder } });
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expect(!selection.collapsed(session.collapsedFolders(&f.tables), session.get(&f.tables), folder));
    try std.testing.expectEqual(@as(u32, 0), session.get(&f.tables).active_id.*);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    selection.prune(&f.tables, &f.atoms);
    var restored = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer restored.deinit(std.testing.allocator);
    try std.testing.expect(m.get(m.Layer, restored.layers, 1) != null);
    try std.testing.expect(m.get(m.Layer, restored.layers, folder) != null);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), 1));
    try std.testing.expectEqual(@as(u32, 0), session.get(&f.tables).active_id.*);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = doc } });
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), session.get(&f.tables).active_id.*);
}

test "artist blend outliner cancellation leaves document and history unchanged" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const doc = try f.create("cancel_folder_drag");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.outliner_drag.* = 1;
    const file = figure_runtime.domain.file;
    var data = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer data.deinit(std.testing.allocator);
    const before = try file.write(std.testing.allocator, &f.atoms, data);
    defer std.testing.allocator.free(before);
    const host_transport = figure_runtime.HostTransport;
    const figure_requests = host_transport.Requests.of(&f.mem, &f.tables, host_transport.commands_table_name);
    const requests_before = figure_requests.count();
    @import("workspace.zig").cancel(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_drag.*);
    // Cancellation may release input capture, but must never ask for a figure edit.
    try std.testing.expectEqual(requests_before, figure_requests.count());
    var restored = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer restored.deinit(std.testing.allocator);
    const after = try file.write(std.testing.allocator, &f.atoms, restored);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "artist blend parent-only layer moves enforce inherited locks but allow explicit unlock" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = try f.create("locked_reparent");
    const folder = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{1} } })).?;
    const other = (try commands.apply(&f.atoms, &f.tables, .{ .add_layer = .{ .doc = doc } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = folder, .locked = 1 } });
    try std.testing.expectError(error.LockedLayer, commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = 1, .parent = 0 } }));
    try std.testing.expectError(error.LockedLayer, commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = other, .parent = folder } }));
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = folder, .parent = 0, .locked = 0 } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = 1, .parent = 0 } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = other, .locked = 1 } });
    try std.testing.expectError(error.LockedLayer, commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = other, .parent = folder, .locked = 0 } }));
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = other, .locked = 0 } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = other, .parent = folder } });
}

test "artist blend grouping reconciles created selection and prunes across undo redo" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const doc = try f.create("group_selection");
    try f.transport.synchronize();
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const s = session.get(&f.tables);
    s.doc.* = doc;
    const second = (try commands.apply(&f.atoms, &f.tables, .{ .add_layer = .{ .doc = doc, .name = f.atoms.intern("second") } })).?;
    try f.transport.synchronize();
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, false, false);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), second, true, false);
    const group = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{ 1, second } } })).?;
    try f.transport.synchronize();
    // UX consumes the created ID; domain history never writes selection.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), group, false, false);
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(group, s.active_id.*);
    try std.testing.expectEqual(group, s.active_layer.*);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), 1));
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try f.transport.synchronize();
    selection.prune(&f.tables, &f.atoms);
    var ungrouped = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer ungrouped.deinit(std.testing.allocator);
    try std.testing.expect(m.get(m.Layer, ungrouped.layers, group) == null);
    try std.testing.expect(m.get(m.Layer, ungrouped.layers, 1) != null);
    try std.testing.expect(m.get(m.Layer, ungrouped.layers, second) != null);
    try std.testing.expectEqual(@as(u32, 0), s.active_id.*);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), group));
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = doc } });
    try f.transport.synchronize();
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), s.active_id.*);
    // A new UX action may select the restored group, not undo history.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), group, false, false);
    try std.testing.expectEqual(group, s.active_id.*);
    try std.testing.expectEqual(group, s.active_layer.*);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), second));
    try drawing.ensure(&f.mem, &f.atoms, &f.tables);
    try std.testing.expect(try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_layer_delete")));
    try applyDrawing(&f);
    var remaining = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer remaining.deinit(std.testing.allocator);
    try std.testing.expect(m.get(m.Layer, remaining.layers, group) == null);
}

test {
    _ = @import("commands_test.zig");
}

/// The shapes of the pose the canvas shows under `point`, or in `rectangle`, within the canvas's
/// 4 screen pixels: what the editor's hit-test questions ask the host.
fn hitsAt(f: *Fixture, point: m.Vec2, rectangle: ?mesha.figure.Bounds) !mesha.figure.Hits {
    const shown = try preview.current(&f.tables, &f.atoms);
    const context = session.figureContext(&f.tables, &f.atoms);
    const tolerance = 4 / session.get(&f.tables).view_zoom.*;
    const allocator = (try f.mem.frameScratchAllocator()).allocator;
    return figure_runtime.hitTest(context, shown, .{ .point = point, .rectangle = rectangle, .tolerance = tolerance }, allocator);
}

test "drawing public preview picking marquee and posed contour share one effective instance" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const figure = mesha.figure;
    const doc = try f.create("public_picking");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("animate");
    s.view_zoom.* = 2;
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 30 } })).?;
    const points = [_]figure.Point{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 20, .y = 20 } }, .{ .p = .{ .x = 0, .y = 20 } } };
    const lower = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 0, 0, 255, 255 }, .stroke_width = 0 }, .points = &points } })).?;
    const upper = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 255, 0, 0, 255 }, .stroke_width = 0 }, .points = &points } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_rigid = .{ .doc = doc, .ids = &.{ lower, upper }, .bone = bone } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{.{ .bone = bone, .local = .{ .x = 50, .y = 10 } }} } });
    try f.preparePreview();
    const hit = try hitsAt(&f, .{ .x = 60, .y = 20 }, null);
    try std.testing.expectEqual(@as(usize, 2), hit.items.len);
    try std.testing.expectEqual(upper, hit.items[0].object.id);
    try f.preparePreview();
    const selected = try hitsAt(&f, .{ .x = 0, .y = 0 }, .{ .min = .{ .x = 55, .y = 15 }, .max = .{ .x = 65, .y = 25 } });
    try std.testing.expectEqualDeep(hit.items, selected.items);
    const context = session.figureContext(&f.tables, &f.atoms);
    try f.preparePreview();
    const shown = try preview.current(&f.tables, &f.atoms);
    const geometry = try figure_runtime.shapeGeometry(context, shown, upper, 2, std.testing.allocator);
    defer std.testing.allocator.free(geometry.points);
    const bounds = @import("geometry.zig").bounds(geometry.points).?;
    try std.testing.expectApproxEqAbs(@as(f32, 50), bounds.min.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 30), bounds.max.y, 1e-5);
    try std.testing.expectEqual(hit.effective_revision, geometry.effective_revision);
    // Design uses the same query path, but shows the rest pose. The canvas watches the contour
    // of the shape under the pointer.
    s.mode.* = f.atoms.intern("design");
    s.hover_kind.* = f.atoms.intern("shape");
    s.hover_id.* = upper;
    try f.preparePreview();
    const rest_hit = try hitsAt(&f, .{ .x = 10, .y = 10 }, null);
    try std.testing.expectEqual(@as(usize, 2), rest_hit.items.len);
    try std.testing.expectEqual(upper, rest_hit.items[0].object.id);
    const rest_geometry = try preview.geometry(&f.tables, &f.atoms, upper);
    const rest_bounds = @import("geometry.zig").bounds(rest_geometry.points).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0), rest_bounds.min.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 20), rest_bounds.max.y, 1e-5);
    s.mode.* = f.atoms.intern("animate");
    try f.preparePreview();
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = 1, .locked = 1 } });
    try f.preparePreview();
    try std.testing.expectEqual(@as(usize, 0), (try hitsAt(&f, .{ .x = 60, .y = 20 }, null)).items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 50), @import("geometry.zig").bounds(geometry.points).?.min.x, 1e-5);
}

test "drawing selected gradient properties identify paint and retain it during fallback edits" {
    const prompts = @import("prompts.zig");
    const api = mesha.plugin.figure_api;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("gradient_property");
    try f.transport.synchronize();
    const editor = session.get(&f.tables);
    editor.doc.* = doc;
    const scratch = try f.mem.tableScratchAllocator();
    try action_palette.ensure(scratch, &f.atoms, &f.tables);
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = m.zero }, .{ .p = .{ .x = 10, .y = 10 } } } } })).?;
    const paint = (try commands.apply(&f.atoms, &f.tables, .{ .set_paint = .{ .doc = doc, .shape = shape, .start = m.zero, .end = m.one } })).?;
    try f.transport.synchronize();
    const shape_kind = f.atoms.intern("shape");
    const fields = prompts.inspectorFields(shape_kind);
    const fill_index: u32 = for (fields, 0..) |field, index| {
        if (std.mem.eql(u8, field.name, "fill_color")) break @intCast(index);
    } else return error.MissingField;
    const frame = try f.mem.frameScratchAllocator();
    const display = try prompts.propertyValue(frame.allocator, &f.tables, &f.atoms, shape_kind, shape, fields[fill_index]);
    try std.testing.expectEqualStrings("Fill paint", display.label);
    const identifies_gradient = std.mem.startsWith(u8, display.text, "linear:");
    try std.testing.expect(identifies_gradient);
    try f.transport.synchronize();
    try prompts.editTarget(&f.mem, &f.tables, &f.atoms, shape_kind, shape, fill_index, .whole, null);
    // The palette opens the prompt in its run; what it sends its text editor is dropped here.
    const sequencer_mod = mesha.sequencer;
    try sequencer_mod.ensure(scratch, &f.atoms, &f.tables);
    const palette_alone: sequencer_mod.Sequencer = .{ .name = "palette_test", .steps = &.{.{ .system = action_palette.system() }} };
    @import("../editor_sequencer.zig").run(&f.mem, &f.atoms, &f.tables, &palette_alone, null);
    const request = action_palette.currentCompletions(&f.tables, &f.atoms).?;
    const labels_fallback = std.mem.indexOf(u8, request.prompt, "Fill fallback RGBA") != null;
    try std.testing.expect(labels_fallback);
    const payload = try prompts.fieldCommand(&f.tables, &f.atoms, editor, "#11223344");
    try std.testing.expect(payload.set_shape.fill_paint == null);
    _ = try commands.apply(&f.atoms, &f.tables, payload);
    try f.transport.synchronize();
    const definition = try session.readDefinition(&f.tables, &f.atoms, doc);
    const changed = session.findById(api.read.Shape, definition.shapes, shape).?;
    try std.testing.expectEqual(paint, changed.fill_paint);
    try std.testing.expectEqual(session.Color{ 0x11, 0x22, 0x33, 0x44 }, changed.fill_color);
    editor.prompt_field.* = f.atoms.intern("fill_on");
    const enabled = try prompts.fieldCommand(&f.tables, &f.atoms, editor, "true");
    try std.testing.expectEqual(paint, enabled.set_shape.fill_paint.?);
    try std.testing.expectEqual(changed.fill_color, enabled.set_shape.fill_color.?);
    editor.prompt_field.* = f.atoms.intern("cap");
    try std.testing.expectError(error.InvalidOption, prompts.fieldCommand(&f.tables, &f.atoms, editor, "triangle"));
    editor.prompt_field.* = f.atoms.intern("opacity");
    try std.testing.expectError(error.InvalidOpacity, prompts.fieldCommand(&f.tables, &f.atoms, editor, "1.5"));
}

test "drawing public paint mapping creates edits samples and copies posed gradients" {
    const figure = mesha.figure;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("drawing_paint_mapping");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("animate");
    s.tool.* = f.atoms.intern("gradient");
    s.active_layer.* = 1;
    s.view_zoom.* = 1;
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 30 } })).?;
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 0, 0, 255, 255 }, .stroke_width = 0 }, .points = &.{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 20, .y = 20 } }, .{ .p = .{ .x = 0, .y = 20 } } } } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_rigid = .{ .doc = doc, .ids = &.{shape}, .bone = bone } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{.{ .bone = bone, .local = .{ .x = 50, .y = 10 } }} } });
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    const c = drawing.config(&f.tables);
    c.fill_color.* = .{ 0, 0, 255, 255 };
    c.stroke_color.* = .{ 255, 0, 0, 128 };
    // A shape without paint uses identity paint mapping, but still reverses its binding.
    s.gesture_start.* = .{ .x = 50, .y = 10 };
    s.gesture_current.* = .{ .x = 70, .y = 10 };
    try f.preparePreview();
    _ = try drawing.pointerUp(&f.tables, &f.atoms);
    try f.transport.answerCanvas();
    try applyDrawing(&f);
    const first = try session.readDefinition(&f.tables, &f.atoms, doc);
    const paint_id = session.findById(figure.read.Shape, first.shapes, shape).?.fill_paint;
    const initial = session.findById(figure.read.Paint, first.paints, paint_id).?;
    try std.testing.expectEqualDeep(m.zero, initial.start);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 20, .y = 0 }, initial.end);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_paint = .{ .doc = doc, .id = paint_id, .shape = shape, .start = m.zero, .end = .{ .x = 10, .y = 0 }, .transform = .{ 2, 0, 0, 3, 4, 5 }, .colors = .{ c.fill_color.*, c.stroke_color.* } } });
    const context = session.figureContext(&f.tables, &f.atoms);
    try f.preparePreview();
    const handle = try preview.current(&f.tables, &f.atoms);
    const mapped = try figure_runtime.paintMapping(context, handle, shape, paint_id, .{ .x = 64, .y = 15 });
    try std.testing.expectEqualDeep(m.Vec2{ .x = 54, .y = 15 }, mapped.start.?);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 74, .y = 15 }, mapped.end.?);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 5, .y = 0 }, mapped.bind_point.?);
    try std.testing.expectEqualDeep(m.Color{ 128, 0, 128, 192 }, mapped.color.?);
    try std.testing.expectError(error.InvalidGeometry, figure_runtime.paintMapping(context, handle, shape, 999999, null));
    try std.testing.expectError(error.InvalidGeometry, figure_runtime.paintMapping(context, handle, 999999, null, null));
    try std.testing.expectError(error.InvalidGeometry, figure_runtime.paintMapping(context, handle, shape, 0, null));
    const identity = try figure_runtime.paintMapping(context, handle, shape, null, .{ .x = 64, .y = 15 });
    try std.testing.expectEqualDeep(m.Vec2{ .x = 14, .y = 5 }, identity.bind_point.?);
    try std.testing.expect(identity.start == null and identity.end == null and identity.color == null);
    s.mode.* = f.atoms.intern("design");
    try f.preparePreview();
    const design_handle = try preview.current(&f.tables, &f.atoms);
    const rest_mapping = try figure_runtime.paintMapping(context, design_handle, shape, paint_id, .{ .x = 14, .y = 5 });
    try std.testing.expectEqualDeep(m.Vec2{ .x = 4, .y = 5 }, rest_mapping.start.?);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 24, .y = 5 }, rest_mapping.end.?);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 5, .y = 0 }, rest_mapping.bind_point.?);
    s.mode.* = f.atoms.intern("animate");
    try f.preparePreview();
    // Retain coverage of the public mapping helper's posed-space contract too.
    // Drag the existing start handle in posed space; preserve its affine and colors.
    try f.preparePreview();
    // The handles a press picks are where the host says the paint lies.
    f.transport.runDrawing();
    try f.transport.answerDrawing();
    _ = try drawing.pointerDown(&f.tables, &f.atoms, mapped.start.?, false, false, false, 1, &.{});
    try std.testing.expectEqual(f.atoms.intern("draw_gradient_start"), s.gesture_kind.*);
    _ = try drawing.pointerMove(&f.tables, .{ .x = 64, .y = 15 }, false, false, false);
    try f.preparePreview();
    _ = try drawing.pointerUp(&f.tables, &f.atoms);
    try f.transport.answerCanvas();
    try applyDrawing(&f);
    s.gesture_active.* = 0;
    const edited_data = try session.readDefinition(&f.tables, &f.atoms, doc);
    const edited = session.findById(figure.read.Paint, edited_data.paints, paint_id).?;
    try std.testing.expectEqualDeep(m.Vec2{ .x = 5, .y = 0 }, edited.start);
    try std.testing.expectEqualDeep(initial.stop_colors, edited.stop_colors);
    try std.testing.expectEqualDeep([6]f32{ 2, 0, 0, 3, 4, 5 }, edited.transform);
    // Eyedropper reaches the same public sampler without recoloring the selected shape.
    selection.clear(session.get(&f.tables), session.observed(&f.tables), session.selections(&f.tables));
    s.tool.* = f.atoms.intern("eyedropper");
    try f.preparePreview();
    _ = try drawing.pointerDown(&f.tables, &f.atoms, .{ .x = 69, .y = 15 }, false, false, false, 1, &.{});
    try f.transport.answerCanvas();
    // The press found a painted shape, whose colour there the host is asked next.
    try f.transport.answerCanvas();
    gesture.update(&f.tables, &f.atoms);
    try std.testing.expectEqualDeep(m.Color{ 128, 0, 128, 192 }, c.fill_color.*);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    const encoded = try figure_runtime.encodeShapeClipboard(context, doc, &.{shape}, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded.len != 0);
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_copy"));
    try f.transport.answerDrawing();
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_paste"));
    try applyDrawing(&f);
    const pasted = try session.readDefinition(&f.tables, &f.atoms, doc);
    try std.testing.expectEqual(@as(usize, 2), pasted.shapes.len);
    const copy = pasted.shapes[1];
    try std.testing.expectEqual(f.atoms.intern("none"), copy.binding);
    const copy_paint = session.findById(figure.read.Paint, pasted.paints, copy.fill_paint).?;
    // Paste preserves the existing default (16,16) document-space offset.
    try std.testing.expectEqualDeep(m.Vec2{ .x = 80, .y = 31 }, (mesha.math.Affine2f{ .a = copy_paint.transform[0], .b = copy_paint.transform[1], .c = copy_paint.transform[2], .d = copy_paint.transform[3], .tx = copy_paint.transform[4], .ty = copy_paint.transform[5] }).apply(copy_paint.start));
    try f.preparePreview();
    const fresh = try preview.current(&f.tables, &f.atoms);
    try std.testing.expectError(error.InvalidGeometry, figure_runtime.paintMapping(context, fresh, copy.id, paint_id, null));
    // Owned clipboard output remains valid independently of preview lifetime.
    try std.testing.expect(encoded[0] != 0);
}

/// The clipboard's bytes, its chunks in order, in `allocator`.
fn clipboardBytes(tables: *Table.Registry, allocator: std.mem.Allocator) ![]u8 {
    const chunks = drawing.clipboardChunks(tables);
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    for (0..chunks.count()) |index| {
        var rows = chunks.read();
        while (rows.next()) |row| {
            if (row.view.index.* != index) continue;
            try bytes.appendSlice(allocator, row.view.bytes[0..row.view.len.*]);
        }
    }
    return bytes.toOwnedSlice(allocator);
}

test "drawing copy keeps the bytes the host encodes and a cut deletes only once they have come" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("drawing_copy_query");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("design");
    s.tool.* = f.atoms.intern("select");
    s.active_layer.* = 1;
    s.view_zoom.* = 1;
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 0, 0, 255, 255 } }, .points = &.{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 20, .y = 20 } } } } })).?;
    try f.transport.synchronize();
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    const context = session.figureContext(&f.tables, &f.atoms);
    const encoded = try figure_runtime.encodeShapeClipboard(context, doc, &.{shape}, std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_copy"));
    try f.transport.answerDrawing();
    const copied = try clipboardBytes(&f.tables, std.testing.allocator);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualSlices(u8, encoded, copied);
    // A cut deletes nothing until its copy has come back.
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_cut"));
    try applyDrawing(&f);
    const before_answer = try session.readDefinition(&f.tables, &f.atoms, doc);
    try std.testing.expectEqual(@as(usize, 1), before_answer.shapes.len);
    f.transport.runDrawing();
    try applyDrawing(&f);
    const after_answer = try session.readDefinition(&f.tables, &f.atoms, doc);
    try std.testing.expectEqual(@as(usize, 0), after_answer.shapes.len);
    const cut = try clipboardBytes(&f.tables, std.testing.allocator);
    defer std.testing.allocator.free(cut);
    try std.testing.expectEqualSlices(u8, encoded, cut);
    // Copying with nothing selected fails as the runtime's encoding of no shapes does, told in
    // the status, and the clipboard keeps what it had.
    selection.clear(s, session.observed(&f.tables), session.selections(&f.tables));
    const encode_none = figure_runtime.encodeShapeClipboard(context, doc, &.{}, std.testing.allocator);
    try std.testing.expectError(error.InvalidGeometry, encode_none);
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_copy"));
    try f.transport.answerDrawing();
    try std.testing.expectEqualStrings("InvalidGeometry", session.statusText(&f.tables));
    const kept = try clipboardBytes(&f.tables, std.testing.allocator);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualSlices(u8, encoded, kept);
}

test "drawing cut deletes the shapes it copied when the selection changed before the answer" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("drawing_cut_query");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("design");
    s.tool.* = f.atoms.intern("select");
    s.active_layer.* = 1;
    s.view_zoom.* = 1;
    const triangle = [_]mesha.figure.Point{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 20, .y = 20 } } };
    const copied = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .points = &triangle } })).?;
    const kept = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .points = &triangle } })).?;
    try f.transport.synchronize();
    const shape_kind = f.atoms.intern("shape");
    selection.select(&f.tables, &f.atoms, shape_kind, copied, false, false);
    _ = try drawing.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_cut"));
    // Another system selects something else before the copy comes back.
    selection.select(&f.tables, &f.atoms, shape_kind, kept, false, false);
    try f.transport.answerDrawing();
    try applyDrawing(&f);
    const definition = try session.readDefinition(&f.tables, &f.atoms, doc);
    try std.testing.expectEqual(@as(usize, 1), definition.shapes.len);
    try std.testing.expectEqual(kept, definition.shapes[0].id);
}

test "drawing gradient handles follow the selection and an answer for a shape no longer selected changes nothing" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("drawing_handles_query");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("design");
    s.tool.* = f.atoms.intern("gradient");
    s.active_layer.* = 1;
    s.view_zoom.* = 1;
    const square = [_]mesha.figure.Point{ .{ .p = .{ .x = 0, .y = 0 } }, .{ .p = .{ .x = 20, .y = 0 } }, .{ .p = .{ .x = 20, .y = 20 } }, .{ .p = .{ .x = 0, .y = 20 } } };
    const first = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 0, 0, 255, 255 } }, .points = &square } })).?;
    const second = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 0, 255, 0, 255 } }, .points = &square } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_paint = .{ .doc = doc, .shape = first, .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 10, .y = 0 } } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_paint = .{ .doc = doc, .shape = second, .start = .{ .x = 0, .y = 5 }, .end = .{ .x = 0, .y = 15 } } });
    try f.preparePreview();
    const definition = try session.readDefinition(&f.tables, &f.atoms, doc);
    const second_paint = session.findById(mesha.figure.read.Shape, definition.shapes, second).?.fill_paint;
    const settings = drawing.config(&f.tables);
    const shape_kind = f.atoms.intern("shape");
    // Asked for the first shape, whose selection is gone before the answer comes.
    selection.select(&f.tables, &f.atoms, shape_kind, first, false, false);
    f.transport.runDrawing();
    selection.clear(s, session.observed(&f.tables), session.selections(&f.tables));
    f.transport.runDrawing();
    try f.transport.answerDrawing();
    try std.testing.expectEqual(@as(u8, 0), settings.handles_known.*);
    try std.testing.expectEqual(@as(u32, 0), settings.handles_shape.*);
    // Asked for the first, then for the second before either answer: only the second's shows.
    selection.select(&f.tables, &f.atoms, shape_kind, first, false, false);
    f.transport.runDrawing();
    selection.select(&f.tables, &f.atoms, shape_kind, second, false, false);
    f.transport.runDrawing();
    try f.transport.answerDrawing();
    const context = session.figureContext(&f.tables, &f.atoms);
    const shown = try preview.current(&f.tables, &f.atoms);
    const expected = try figure_runtime.paintMapping(context, shown, second, second_paint, null);
    try std.testing.expectEqual(@as(u8, 1), settings.handles_known.*);
    try std.testing.expectEqual(second, settings.handles_shape.*);
    try std.testing.expectEqualDeep(expected.start.?, settings.handles_start.*);
    try std.testing.expectEqualDeep(expected.end.?, settings.handles_end.*);
}

test "drawing public path utilities retain primitive constraints cubic sampling and pencil fitting" {
    const figure = mesha.figure;
    const a = std.testing.allocator;
    const points = try figure.primitivePath(a, .rect, m.zero, .{ .x = 30, .y = 20 }, true, true, 0, 5);
    defer a.free(points);
    try std.testing.expectEqual(@as(usize, 4), points.len);
    try std.testing.expectEqualDeep(m.Vec2{ .x = -30, .y = -30 }, points[0].p);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 30, .y = 30 }, points[2].p);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 0, .y = -30 }, figure.pathCubic(points[0], points[1], 0.5));
    const fitted = try figure.fitPath(a, &.{ m.zero, .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 } }, 0.1, 1);
    defer a.free(fitted);
    try std.testing.expectEqual(@as(usize, 2), fitted.len);
    try std.testing.expectEqualDeep(m.zero, fitted[0].p);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 20, .y = 0 }, fitted[1].p);
}

test "weight public geometry copies stable influences samples Test pose and document diagnostics" {
    const figure = mesha_runtime.figure;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("weight_public_geometry");
    const s = session.get(&f.tables);
    s.doc.* = doc;
    s.mode.* = f.atoms.intern("rig");
    s.tool.* = f.atoms.intern("weight");
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 30 } });
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = doc, .length = 30 } })).?;
    const shape = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &.{ .{ .p = m.zero, .out = .{ .x = 0, .y = 10 } }, .{ .p = .{ .x = 20, .y = 0 }, .in = .{ .x = 0, .y = 10 } } } } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = doc, .ids = &.{shape}, .bones = &.{bone} } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = doc, .channels = &.{.{ .bone = bone, .local = .{ .x = 50, .y = 10 } }} } });
    const context = session.figureContext(&f.tables, &f.atoms);
    try f.preparePreview();
    const shown = try preview.current(&f.tables, &f.atoms);
    const info = try figure.definitionInfo(context, doc);
    const revision = info.authored_revision;
    var projected = try figure.weightGeometry(context, shown, .{ .tolerance = 0.25 }, std.testing.allocator);
    defer projected.deinit(std.testing.allocator);
    try std.testing.expectEqual(info.effective_revision.?, projected.effective_revision);
    try std.testing.expectEqual(@as(usize, 1), projected.shapes.len);
    try std.testing.expect(projected.shapes[0].brush_eligible and projected.shapes[0].overlay_visible);
    try std.testing.expectEqual(@as(usize, 2), projected.points.len);
    try std.testing.expectEqual(shape, projected.points[0].shape);
    try std.testing.expectEqual(@as(u32, 1), projected.points[1].index);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 70, .y = 10 }, projected.points[1].position);
    try std.testing.expectEqual(bone, projected.points[1].influences.bones[0]);
    try std.testing.expectEqual(@as(f32, 1), projected.points[1].influences.weights[0]);
    try std.testing.expect(projected.samples.len > 2);
    try std.testing.expectEqual(bone, projected.samples[1].influences.bones[0]);
    try std.testing.expectEqualDeep(projected.points[0].position, projected.samples[0].position);
    try std.testing.expectEqualDeep(projected.points[1].position, projected.samples[projected.samples.len - 1].position);
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), bone);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_test_pose"));
    s.prompt_doc.* = doc;
    s.prompt_id.* = bone;
    s.prompt_target_kind.* = f.atoms.intern("bone");
    _ = try weight.submitPrompt(&f.tables, &f.atoms, @import("names.zig").test_rotation, "90");
    try f.preparePreview();
    var rotated = try figure.weightGeometry(context, try preview.current(&f.tables, &f.atoms), .{ .include_samples = false }, std.testing.allocator);
    defer rotated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), rotated.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 50), rotated.points[1].position.x, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 30), rotated.points[1].position.y, 1e-4);
    try std.testing.expectEqual(revision, (try figure.definitionInfo(context, doc)).authored_revision);
    // Diagnostics read keep both exact strings, whatever is written after.
    const row = t.documentTable(&f.tables, &f.atoms).getRow(t.findDocument(&f.tables, &f.atoms, doc).?, t.Document).?;
    try t.setCatalogText(&f.tables, &f.atoms, doc, row.error_text, "Existing figure error");
    try t.setCatalogText(&f.tables, &f.atoms, doc, row.warning_text, "Existing figure warning");
    const diagnostics = try figure.definitionDiagnostics(context, doc);
    try t.setCatalogText(&f.tables, &f.atoms, doc, row.error_text, "Changed later");
    try std.testing.expectEqualStrings("Existing figure error", diagnostics.error_text);
    try std.testing.expectEqualStrings("Existing figure warning", diagnostics.warning_text);
    try std.testing.expectEqualDeep(m.Vec2{ .x = 70, .y = 10 }, projected.points[1].position);
}

test "drawing bulk solid color is atomic and preserves redo on rejection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const doc = try f.create("bulk_color");
    const layer = (try commands.apply(&f.atoms, &f.tables, .{ .add_layer = .{ .doc = doc } })).?;
    const points = [_]mesha.figure.Point{ .{ .p = m.zero }, .{ .p = .{ .x = 20, .y = 0 } } };
    const first = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = 1, .points = &points } })).?;
    const second = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = doc, .layer = layer, .points = &points } })).?;
    var original = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer original.deinit(std.testing.allocator);
    const green = m.Color{ 30, 140, 60, 255 };
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_shape_color = .{ .doc = doc, .ids = &.{ first, second }, .target = .fill, .color = green } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = doc } });
    try std.testing.expectError(error.MissingShape, commands.apply(&f.atoms, &f.tables, .{ .set_shape_color = .{ .doc = doc, .ids = &.{ first, 9999 }, .target = .stroke, .color = green } }));
    var rejected = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(original.shapes, rejected.shapes);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = doc } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = doc, .id = layer, .locked = 1 } });
    var colored = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer colored.deinit(std.testing.allocator);
    for (colored.shapes) |shape| try std.testing.expectEqual(green, shape.fill_color);
    try std.testing.expectError(error.LockedLayer, commands.apply(&f.atoms, &f.tables, .{ .set_shape_color = .{ .doc = doc, .ids = &.{ first, second }, .target = .stroke, .color = green } }));
    var locked = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, doc);
    defer locked.deinit(std.testing.allocator);
    try std.testing.expectEqualDeep(colored.shapes, locked.shapes);
}
