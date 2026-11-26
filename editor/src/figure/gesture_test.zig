//! Absolute drag lifecycle through the editor's real pointer Msg path: canvas
//! pointer Msgs enter workspace.handle, and workspace.sync is the update pump.
const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const figure_runtime = mesha_runtime.figure;
const os = mesha.os;
const Atom = mesha.Atom;
const memory = mesha.memory;
const Table = mesha.Table;
const input = mesha.input;
const panels_mod = mesha.panels;
const figure = mesha.figure;
const m = figure_runtime.domain.model;
const t = figure_runtime.domain.tables;
const commands = figure_runtime.domain.command;
const library = figure_runtime.domain.library;
const editor_state = @import("../state.zig");
const geometry = @import("geometry.zig");
const gesture = @import("gesture.zig");
const selection = @import("selection.zig");
const session = @import("session.zig");
const workspace = @import("workspace.zig");
const asks = @import("asks.zig");
const view = @import("view.zig");
const preview = @import("preview.zig");
const transport_fixture = @import("transport_fixture.zig");
const action_palette = @import("../action_palette.zig");
const fixed_panels = @import("../fixed_panels.zig");
const commands_mod = @import("commands.zig");
const weight = @import("weight.zig");
const names_mod = @import("names.zig");
const prompts = @import("prompts.zig");
const context_menu = @import("context_menu.zig");

const Operation = std.meta.Tag(figure.Payload);

const Fixture = struct {
    mem: memory.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    transport: transport_fixture.Transport = undefined,
    doc: Atom = m.none,

    fn init(f: *Fixture, name: []const u8) !void {
        f.mem.init(std.testing.allocator);
        try f.atoms.init(&f.mem);
        try f.tables.init(&f.mem, 96);
        try f.transport.init(&f.mem, &f.atoms, &f.tables);
        const scratch = try f.mem.tableScratchAllocator();
        try editor_state.ensureViewFocus(scratch, &f.atoms, &f.tables);
        try action_palette.ensure(scratch, &f.atoms, &f.tables);
        const HoverState = struct { hovered_id: [16]u8 = @splat(0) };
        _ = try session.ensureSingleton(HoverState, &f.mem, &f.atoms, &f.tables, editor_state.app_state_name);
        const stage = f.atoms.intern(workspace.canvas_id);
        panels_mod.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
        // The editor's fixed panels, the figure stage shown among them.
        try fixed_panels.ensure(scratch, &f.atoms, &f.tables);
        fixed_panels.layOutNow(&f.tables, &f.atoms, .figure_stage);
        editor_state.setViewFocus(&f.tables, &f.atoms, stage);
        // workspace.handle reports figure Msgs by their interned tag names.
        for ([_][]const u8{ "figure_pointer_down", "figure_pointer_move", "figure_pointer_up" }) |tag_name| {
            _ = f.atoms.intern(tag_name);
        }
        f.doc = f.atoms.intern(name);
        try library.create(&f.tables, &f.atoms, .{ .scope = mesha.resources.applicationScope(f.tables.memory), .doc = f.doc });
        const editor = session.get(&f.tables);
        editor.doc.* = f.doc;
        editor.tool.* = f.atoms.intern("select");
        // A fixed camera keeps document and screen samples comparable.
        editor.fit_pending.* = 0;
        editor.view_center.* = m.zero;
        editor.view_zoom.* = 1;
        try f.transport.synchronize();
    }

    fn deinit(f: *Fixture) void {
        figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
        f.tables.deinit();
        f.atoms.deinit();
        f.mem.deinit();
    }

    /// Artwork tall enough that a fitted zoom depends on the canvas height.
    fn addTallArtwork(f: *Fixture) !void {
        const points = [_]figure.Point{
            .{ .p = .{ .x = 0, .y = 0 } },
            .{ .p = .{ .x = 300, .y = 0 } },
            .{ .p = .{ .x = 300, .y = 3000 } },
            .{ .p = .{ .x = 0, .y = 3000 } },
        };
        _ = try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = f.doc, .layer = 1, .closed = 1, .style = .{ .fill_color = .{ 255, 0, 0, 255 } }, .points = &points } });
    }

    fn settleDesignLayout(f: *Fixture) void {
        panels_mod.relayout(&f.tables, &f.atoms, .{ .w = 1920, .h = 1080 });
    }

    fn preparePreview(f: *Fixture) !void {
        _ = try f.transport.preparePreview();
    }

    fn screen(f: *Fixture, point: m.Vec2) m.Vec2 {
        const rect = workspace.canvasViewport(&f.tables, &f.atoms).?;
        const editor = session.get(&f.tables);
        return geometry.toScreen(rect, editor.view_center.*, editor.view_zoom.*, point);
    }

    fn button(f: *Fixture, tag: Atom, point: m.Vec2) !void {
        const screen_point = f.screen(point);
        const event = input.MouseButtonMsg{ .x = screen_point.x, .y = screen_point.y };
        const received: mesha.sequencer.Message = .{ .tag = tag, .payload = std.mem.asBytes(&event) };
        const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, received);
        try std.testing.expect(handled);
    }

    fn action(f: *Fixture, name: []const u8) !void {
        const tag = f.atoms.intern(name);
        const invoked: mesha.sequencer.Message = .{ .tag = tag };
        const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, invoked);
        try std.testing.expect(handled);
    }

    fn down(f: *Fixture, point: m.Vec2) !void {
        try input.writeHover(&f.tables, &f.atoms, .{});
        try f.button(Atom.from(workspace.Msg.figure_pointer_down), point);
    }

    fn up(f: *Fixture, point: m.Vec2) !void {
        try f.button(Atom.from(workspace.Msg.figure_pointer_up), point);
    }

    fn move(f: *Fixture, point: m.Vec2) !void {
        // Idle motion over the canvas has input report it over the canvas.
        const editor = session.get(&f.tables);
        if (editor.gesture_active.* == 0) {
            const canvas = view.canvas_hover_id;
            try input.writeHover(&f.tables, &f.atoms, .{ .element = std.mem.toBytes(canvas) });
        }
        const screen_point = f.screen(point);
        const event = input.MouseMoveMsg{ .x = screen_point.x, .y = screen_point.y };
        const received: mesha.sequencer.Message = .{ .tag = Atom.from(workspace.Msg.figure_pointer_move), .payload = std.mem.asBytes(&event) };
        const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, received);
        try std.testing.expect(handled);
    }

    /// One frame of the editor's systems.
    fn pump(f: *Fixture) void {
        transport_fixture.runSystems(&f.mem, &f.atoms, &f.tables);
    }

    /// The host answers what a press asked, and the canvas goes on with it the next frame.
    fn answer(f: *Fixture) !void {
        try f.transport.answerCanvas();
    }

    /// The host answers what the hover asked in the frame `pump` ran, and the next frame shows it.
    fn answerHover(f: *Fixture) !void {
        try f.transport.synchronize();
        f.pump();
    }

    fn drain(f: *Fixture, allow_failure: bool) !void {
        try f.transport.drain(allow_failure);
    }

    /// Counts editor figure requests whose results have not returned, optionally of one operation.
    fn expectPending(f: *Fixture, operation: ?Operation, expected: usize) !void {
        const table_name = f.atoms.intern(session.pending_name);
        const pending_table = f.tables.findByName(table_name).?;
        var rows = pending_table.query(session.Row(session.Pending));
        var count: usize = 0;
        while (rows.next()) |row| {
            const matches = if (operation) |wanted| row.view.operation.* == @intFromEnum(wanted) else true;
            if (matches) count += 1;
        }
        try std.testing.expectEqual(expected, count);
    }

    fn historyCount(f: *Fixture) u32 {
        const table_name = f.atoms.intern("editor_figure_history");
        const history_table = f.tables.findByName(table_name).?;
        return history_table.count();
    }

    fn expectStatus(f: *Fixture, expected: []const u8) !void {
        const status = session.statusText(&f.tables);
        try std.testing.expectEqualStrings(expected, status);
    }

    fn expectKind(f: *Fixture, expected: gesture.Kind) !void {
        const kind = gesture.activeKind(gesture.get(&f.tables));
        try std.testing.expectEqual(expected, kind);
    }

    /// No owned drag and no open editor transaction remain.
    fn expectSettled(f: *Fixture) !void {
        const editor = session.get(&f.tables);
        const busy = gesture.busy(gesture.get(&f.tables));
        try std.testing.expect(!busy);
        try std.testing.expectEqual(@as(u8, 0), editor.tx_active.*);
    }

    fn selected(f: *Fixture, shape: u32) bool {
        const shape_kind = f.atoms.intern("shape");
        return selection.contains(session.get(&f.tables), session.selections(&f.tables), shape_kind, shape);
    }

    fn addSquare(f: *Fixture) !u32 {
        const corners = [_]figure.Point{
            .{ .p = .{ .x = 0, .y = 0 } },
            .{ .p = .{ .x = 40, .y = 0 } },
            .{ .p = .{ .x = 40, .y = 40 } },
            .{ .p = .{ .x = 0, .y = 40 } },
        };
        const created = try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{
            .doc = f.doc,
            .layer = 1,
            .closed = 1,
            .style = .{ .fill_color = .{ 0, 0, 255, 255 }, .stroke_width = 0 },
            .points = &corners,
        } });
        return created.?;
    }

    fn expectOffset(f: *Fixture, before: m.Document, offset: m.Vec2) !void {
        var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqual(before.points.len, after.points.len);
        for (before.points, after.points) |old, new| {
            try std.testing.expectApproxEqAbs(old.p.x + offset.x, new.p.x, 1e-4);
            try std.testing.expectApproxEqAbs(old.p.y + offset.y, new.p.y, 1e-4);
        }
    }

    fn boneChannels(f: *Fixture, bone: u32) !figure.read.Bone {
        const definition = try session.readDefinition(&f.tables, &f.atoms, f.doc);
        return session.findById(figure.read.Bone, definition.bones, bone).?;
    }
};

test "drawing camera actions apply in order" {
    var f: Fixture = undefined;
    try f.init("camera_action_order");
    defer f.deinit();
    try f.addTallArtwork();
    f.transport.layout_commands = .apply;
    for (0..2) |_| {
        f.pump();
        try f.drain(false);
    }
    const editor = session.get(&f.tables);
    const fitted = workspace.fittedCamera(&f.tables, &f.atoms, session.figureExtent(session.observed(&f.tables), session.get(&f.tables))).?;
    try std.testing.expect(@abs(fitted.zoom - 1) > 0.01);
    const increased_zoom = std.math.clamp(fitted.zoom * 1.25, geometry.minimum_zoom, geometry.maximum_zoom);
    const cases = [_]struct { first: []const u8, last: []const u8, zoom: f32 }{
        .{ .first = "figure_view_fit", .last = "figure_view_reset", .zoom = 1 },
        .{ .first = "figure_view_reset", .last = "figure_view_fit", .zoom = fitted.zoom },
        .{ .first = "figure_view_fit", .last = "figure_zoom_in", .zoom = increased_zoom },
        .{ .first = "figure_zoom_in", .last = "figure_view_fit", .zoom = fitted.zoom },
    };
    for (cases) |case| {
        editor.view_center.* = .{ .x = 91, .y = 73 };
        editor.view_zoom.* = 2;
        try f.action(case.first);
        try f.action(case.last);
        f.pump();
        try f.drain(false);
        try std.testing.expectEqual(@as(u8, 0), editor.fit_pending.*);
        try std.testing.expectApproxEqAbs(case.zoom, editor.view_zoom.*, 1e-5);
        try std.testing.expectEqualDeep(fitted.center, editor.view_center.*);
    }
}

test "drawing chrome bounds exclude controls and preserve captured release outside the canvas" {
    var f: Fixture = undefined;
    try f.init("chrome_bounds");
    defer f.deinit();
    _ = try f.addSquare();
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const stage = workspace.stageViewport(&f.tables, &f.atoms).?;
    const layout = geometry.stageLayout(stage, .{});
    const rect = workspace.canvasViewport(&f.tables, &f.atoms).?;
    try std.testing.expectEqualDeep(layout.canvas, rect);
    const observed = session.observed(&f.tables);
    try std.testing.expectEqual(rect.x, observed.canvas_x.*);
    try std.testing.expectEqual(rect.y, observed.canvas_y.*);
    try std.testing.expectEqual(rect.w, observed.canvas_width.*);
    try std.testing.expectEqual(rect.h, observed.canvas_height.*);

    const editor = session.get(&f.tables);
    const original_zoom = editor.view_zoom.*;
    const original_center = editor.view_center.*;
    const controls = [_]panels_mod.Rect{ layout.header, layout.options };
    for (controls) |control| {
        const down = input.MouseButtonMsg{ .x = control.x + control.w * 0.5, .y = control.y + control.h * 0.5 };
        const received: mesha.sequencer.Message = .{ .tag = Atom.from(workspace.Msg.figure_pointer_down), .payload = std.mem.asBytes(&down) };
        const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, received);
        try std.testing.expect(handled);
        try f.expectSettled();
        try f.expectPending(.begin, 0);
    }

    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    const press = m.Vec2{ .x = 10, .y = 10 };
    const outside_screen = m.Vec2{ .x = layout.header.x + 8, .y = layout.header.y + layout.header.h * 0.5 };
    const outside = geometry.toDocument(rect, original_center, original_zoom, outside_screen);
    const delta = mesha.math.Vec2f.sub(outside, press);
    try f.down(press);
    try f.answer();
    try f.expectKind(.move_shapes);
    try f.move(outside);
    f.pump();
    try f.expectPending(.begin, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    try f.drain(false);
    try f.expectOffset(before, delta);
    try f.up(outside);
    for (0..4) |_| {
        f.pump();
        try f.drain(false);
    }
    try f.expectSettled();
    try f.expectOffset(before, delta);
    const committed_history = f.historyCount();
    try std.testing.expectEqual(history_before + 1, committed_history);
}

test "gesture preview select-move coalesces moves, keeps one preview in flight and commits once after draining" {
    var f: Fixture = .{};
    try f.init("gesture_select_move");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    const origin = m.Vec2{ .x = 20, .y = 20 };
    try f.down(origin);
    try f.answer();
    try f.expectKind(.move_shapes);
    // Many pointer Msgs between pumps only replace the latest sample.
    for (1..64) |i| {
        const step: f32 = @floatFromInt(i);
        try f.move(.{ .x = origin.x + step, .y = origin.y - step });
    }
    try f.move(.{ .x = 30, .y = 25 });
    try f.expectPending(null, 0);
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.begin, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.preview, 1);
    // Later samples wait while any request of the preview is in flight.
    try f.move(.{ .x = 35, .y = 30 });
    f.pump();
    f.pump();
    try f.expectPending(null, 1);
    try f.drain(false);
    try f.expectOffset(before, .{ .x = 10, .y = 5 });
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.begin, 0);
    // Release: the release sample waits for the in-flight preview, and the
    // commit waits for the final preview.
    try f.up(.{ .x = 40, .y = 32 });
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    // A press while the drag settles is rejected before it changes press-time state.
    try f.down(.{ .x = 5, .y = 5 });
    try f.expectStatus("GestureSettling");
    try f.expectKind(.move_shapes);
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    f.pump();
    try f.expectPending(null, 1);
    try f.drain(false);
    try f.expectOffset(before, .{ .x = 15, .y = 10 });
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.commit, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(null, 0);
    try f.drain(false);
    try f.expectSettled();
    try f.expectOffset(before, .{ .x = 20, .y = 12 });
    try std.testing.expectEqual(history_before + 1, f.historyCount());
    // The whole drag is one undo step.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
    try f.expectOffset(before, m.zero);
}

test "gesture preview cancel and focus loss mid-drag restore the document after draining" {
    for ([_]bool{ false, true }) |focus_loss| {
        var f: Fixture = .{};
        try f.init("gesture_cancel");
        defer f.deinit();
        const editor = session.get(&f.tables);
        editor.mode.* = f.atoms.intern("design");
        const shape = try f.addSquare();
        try f.preparePreview();
        var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer before.deinit(std.testing.allocator);
        const history_before = f.historyCount();
        try f.down(.{ .x = 20, .y = 20 });
        try f.answer();
        try std.testing.expect(f.selected(shape));
        try f.move(.{ .x = 30, .y = 28 });
        f.pump();
        try f.drain(false);
        f.pump();
        try f.drain(false);
        try f.expectOffset(before, .{ .x = 10, .y = 8 });
        try f.move(.{ .x = 50, .y = 40 });
        f.pump();
        const drag_state = gesture.get(&f.tables);
        try std.testing.expect(drag_state.in_flight.* != 0);
        if (focus_loss) workspace.focusLost(&f.tables, &f.atoms) else workspace.cancel(&f.tables, &f.atoms);
        // The cancel waits for the in-flight preview instead of racing it.
        try f.expectPending(.cancel, 0);
        try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
        try f.drain(false);
        f.pump();
        try f.expectPending(null, 1);
        try f.expectPending(.cancel, 1);
        try f.drain(false);
        f.pump();
        try f.drain(false);
        try f.expectSettled();
        try f.expectOffset(before, m.zero);
        try std.testing.expectEqual(history_before, f.historyCount());
        // Select-tool cancellation still restores the press-time selection and feedback.
        try std.testing.expect(!f.selected(shape));
        const information = session.informationText(&f.tables);
        try std.testing.expectEqualStrings("Cancelled with Esc", information);
        try f.expectStatus("");
    }
}

test "gesture preview rejection ends the drag cancelled with status and never commits" {
    var f: Fixture = .{};
    try f.init("gesture_rejected");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    try f.down(.{ .x = 20, .y = 20 });
    try f.answer();
    // Locking after admission makes the first preview's move_selection fail.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_layer = .{ .doc = f.doc, .id = 1, .locked = 1 } });
    var locked = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer locked.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    try f.move(.{ .x = 30, .y = 28 });
    f.pump();
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    try f.drain(true);
    const drag_state = gesture.get(&f.tables);
    try std.testing.expectEqual(gesture.Intent.failure, gesture.intentOf(drag_state));
    try std.testing.expectEqual(gesture.Phase.draining, gesture.phaseOf(drag_state));
    try f.expectStatus("LockedLayer");
    // Later samples are ignored; the next pump drains into one cancel.
    try f.move(.{ .x = 40, .y = 30 });
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.cancel, 1);
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    // The release of an ended drag submits nothing.
    try f.up(.{ .x = 40, .y = 30 });
    try f.expectPending(null, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(null, 0);
    try f.drain(false);
    try f.expectSettled();
    try f.expectOffset(locked, m.zero);
    try std.testing.expectEqual(history_before, f.historyCount());
    try f.expectStatus("LockedLayer");
}

test "gesture preview rig joint drag submits one set_bone from the latest sample" {
    var f: Fixture = .{};
    try f.init("gesture_joint");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("rig");
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 50 } })).?;
    try f.preparePreview();
    try f.down(.{ .x = 50, .y = 0 });
    try f.expectKind(.bone_tip);
    for (0..32) |i| {
        const step: f32 = @floatFromInt(i);
        try f.move(.{ .x = 50 - step, .y = step });
    }
    try f.move(.{ .x = 0, .y = 50 });
    f.pump();
    try f.expectPending(.begin, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(null, 1);
    try f.expectPending(.preview, 1);
    try f.move(.{ .x = -30, .y = 0 });
    f.pump();
    try f.expectPending(null, 1);
    try f.drain(false);
    const dragged = try f.boneChannels(bone);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), dragged.rotation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 50), dragged.length, 1e-4);
    // The release sample replaces the unflushed one before the final preview.
    try f.up(.{ .x = 0, .y = 80 });
    f.pump();
    try f.expectPending(.preview, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    f.pump();
    try f.expectPending(.commit, 1);
    try f.drain(false);
    try f.expectSettled();
    const released = try f.boneChannels(bone);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), released.rotation, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 80), released.length, 1e-4);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
    try f.transport.synchronize();
    const restored = try f.boneChannels(bone);
    try std.testing.expectApproxEqAbs(@as(f32, 0), restored.rotation, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 50), restored.length, 1e-6);
}

test "gesture preview focus loss after release cancels a draining drag" {
    var f: Fixture = .{};
    try f.init("gesture_release_focus_loss");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    try f.down(.{ .x = 20, .y = 20 });
    try f.answer();
    try f.move(.{ .x = 30, .y = 28 });
    f.pump();
    try f.up(.{ .x = 40, .y = 35 });
    workspace.focusLost(&f.tables, &f.atoms);
    try f.drain(false);
    f.pump();
    try f.expectPending(.cancel, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    try f.expectSettled();
    try f.expectOffset(before, m.zero);
    try std.testing.expectEqual(history_before, f.historyCount());
}

test "gesture preview rejected begin never edits or cancels foreign transaction" {
    var f: Fixture = .{};
    try f.init("gesture_foreign_transaction");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    const shape = try f.addSquare();
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const context = session.figureContext(&f.tables, &f.atoms);
    _ = try commands_mod.submit(context, .{ .begin = .{ .doc = f.doc, .label = f.atoms.intern("foreign") } });
    const items = [_]figure.Selection{.{ .kind = f.atoms.intern("shape"), .id = shape }};
    _ = try commands_mod.submit(context, .{ .move_selection = .{ .doc = f.doc, .items = &items, .delta = .{ .x = 7, .y = 4 } } });
    try f.drain(false);
    try f.expectOffset(before, .{ .x = 7, .y = 4 });
    try f.down(.{ .x = 27, .y = 24 });
    try f.answer();
    try f.move(.{ .x = 40, .y = 30 });
    f.pump();
    try f.expectPending(.begin, 1);
    try f.expectPending(.preview, 0);
    try f.drain(true);
    f.pump();
    try f.expectPending(.cancel, 0);
    try f.expectSettled();
    try f.expectOffset(before, .{ .x = 7, .y = 4 });
    try std.testing.expect(session.definitionInfo(&f.tables, &f.atoms, f.doc).?.transaction_open);
    _ = try commands_mod.submit(context, .{ .commit = .{ .doc = f.doc } });
    try f.drain(false);
}

test "gesture preview pending activation blocks press and key releases survive busy phases" {
    var f: Fixture = .{};
    try f.init("gesture_activation_old");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    const context = session.figureContext(&f.tables, &f.atoms);
    const next = f.atoms.intern("gesture_activation_new");
    _ = try commands_mod.submit(context, .{ .new_doc = .{ .scope = mesha.resources.applicationScope(context.memory), .doc = next } });
    var figure_commands: figure_runtime.HostTransport.HostContext = .{ .host = &f.transport.host };
    try figure_runtime.HostTransport.dispatch(&figure_commands);
    try f.down(.{ .x = 20, .y = 20 });
    try f.expectStatus("DocumentActivating");
    try f.expectSettled();
    try f.drain(false);
    try std.testing.expectEqual(next, editor.doc.*);
    try f.expectSettled();
    editor.doc.* = f.doc;
    editor.tool.* = f.atoms.intern("select");
    try f.preparePreview();
    try f.down(.{ .x = 20, .y = 20 });
    try f.answer();
    try f.expectKind(.move_shapes);
    try f.move(.{ .x = 30, .y = 30 });
    f.pump();
    try f.up(.{ .x = 30, .y = 30 });
    editor.space_held.* = 1;
    const space_up: mesha.sequencer.Message = .{ .tag = f.atoms.intern("figure_space_up") };
    _ = workspace.handle(&f.mem, &f.tables, &f.atoms, space_up);
    try std.testing.expectEqual(@as(u8, 0), editor.space_held.*);
    try f.drain(false);
    f.pump();
    try f.drain(false);
    f.pump();
    try f.drain(false);
    try f.expectSettled();
}

test "gesture preview release before begin result retains final sample" {
    var f: Fixture = .{};
    try f.init("gesture_release_begin_pending");
    defer f.deinit();
    session.get(&f.tables).mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    try f.down(.{ .x = 20, .y = 20 });
    try f.answer();
    try f.move(.{ .x = 30, .y = 25 });
    f.pump();
    try f.up(.{ .x = 40, .y = 32 });
    try f.expectPending(.begin, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    try f.drain(false);
    f.pump();
    try f.expectPending(.commit, 1);
    try f.drain(false);
    try f.expectSettled();
    try f.expectOffset(before, .{ .x = 20, .y = 12 });
}

const SampleDelivery = enum { individual, grouped };

fn drawingEquivalenceRun(delivery: SampleDelivery) !m.Document {
    var f: Fixture = .{};
    try f.init("drawing_equivalence");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    editor.tool.* = f.atoms.intern("pencil");
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const history_before = f.historyCount();
    try f.down(.{ .x = 0, .y = 0 });
    const samples = [_]m.Vec2{ .{ .x = 10, .y = 5 }, .{ .x = 20, .y = 12 }, .{ .x = 30, .y = 8 }, .{ .x = 40, .y = 15 } };
    for (samples) |point| {
        try f.move(point);
        if (delivery == .individual) {
            f.pump();
            try f.drain(false);
        }
        var draft = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer draft.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), draft.points.len);
        try std.testing.expectEqual(history_before, f.historyCount());
    }
    try f.up(.{ .x = 50, .y = 20 });
    try f.drain(false);
    f.pump();
    try f.drain(false);
    try f.expectSettled();
    var result = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    errdefer result.deinit(std.testing.allocator);
    try std.testing.expect(result.points.len > 1);
    try std.testing.expectEqual(history_before + 1, f.historyCount());
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
    var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer undone.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), undone.points.len);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = f.doc } });
    var redone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer redone.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, result.points, redone.points);
    return result;
}

test "drawing pencil pointer delivery grouping preserves fitted path and history" {
    var individual = try drawingEquivalenceRun(.individual);
    defer individual.deinit(std.testing.allocator);
    var grouped = try drawingEquivalenceRun(.grouped);
    defer grouped.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, individual.points, grouped.points);
}

fn weightEquivalenceRun(delivery: SampleDelivery) !m.Document {
    var f: Fixture = .{};
    try f.init("weight_equivalence");
    defer f.deinit();
    const b1 = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    const b2 = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    const spare = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    const shape = try f.addSquare();
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = f.doc, .ids = &.{shape} } });
    try f.transport.synchronize();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("rig");
    editor.tool.* = f.atoms.intern("weight");
    weight.sync(&f.tables, &f.atoms);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, false, false);
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), spare);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_weight_lock"));
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b1);
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_test_pose"));
    editor.prompt_doc.* = f.doc;
    editor.prompt_id.* = b1;
    editor.prompt_target_kind.* = f.atoms.intern("bone");
    _ = try weight.submitPrompt(&f.tables, &f.atoms, names_mod.test_rotation, "45");
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), b2);
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const evaluation = try preview.evaluation(&f.tables, &f.atoms);
    var rotated = false;
    for (evaluation.bones) |bone| {
        if (bone.id == b1 and @abs(bone.tip.y) > 20) rotated = true;
    }
    try std.testing.expect(rotated);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    const settings = weight.config(&f.tables);
    settings.radius.* = 90;
    settings.strength.* = 0.2;
    try f.down(.{ .x = 0, .y = 0 });
    try f.answer();
    try f.expectKind(.weight);
    const stroke = weight.stroke(&f.tables);
    try std.testing.expectEqual(@as(u32, 1), stroke.shape_count.*);
    try std.testing.expectEqual(@as(u32, 4), stroke.point_count.*);
    try std.testing.expectEqual(@as(u32, 1), stroke.lock_count.*);
    const lock_table_name = f.atoms.intern(weight.locks_name);
    const lock_table = f.tables.findByName(lock_table_name).?;
    var lock_rows = lock_table.query(struct { ordinal: *u32, bone: *u32 });
    const captured_lock = lock_rows.next().?.view;
    try std.testing.expectEqual(@as(u32, 0), captured_lock.ordinal.*);
    try std.testing.expectEqual(spare, captured_lock.bone.*);
    try std.testing.expect(lock_rows.next() == null);
    selection.clear(session.get(&f.tables), session.observed(&f.tables), session.selections(&f.tables));
    _ = try weight.handleAction(&f.tables, &f.atoms, f.atoms.intern("figure_weight_lock"));
    try std.testing.expect(weight.locked(weight.boneStates(&f.tables), b2));
    try std.testing.expect(!f.selected(shape));
    if (delivery == .individual) {
        for (0..3) |_| {
            f.pump();
            try f.drain(false);
        }
    }
    const points = [_]m.Vec2{ .{ .x = 12, .y = 10 }, .{ .x = 25, .y = 15 }, .{ .x = 35, .y = 25 } };
    for (points, 0..) |point, i| {
        settings.strength.* = if (i == 1) 0.45 else 0.15;
        settings.radius.* = if (i == 2) 65 else 90;
        try f.move(point);
        if (delivery == .individual) {
            f.pump();
            try f.drain(false);
        }
    }
    try f.up(.{ .x = 40, .y = 30 });
    for (0..12) |_| {
        f.pump();
        try f.drain(false);
        if (!gesture.busy(gesture.get(&f.tables))) break;
    }
    try f.expectSettled();
    try f.expectPending(null, 0);
    var result = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    errdefer result.deinit(std.testing.allocator);
    var changed = false;
    for (before.points, result.points) |old, new| {
        if (!std.meta.eql(old.weights, new.weights)) changed = true;
    }
    try std.testing.expect(changed);
    try std.testing.expectEqual(history_before + 1, f.historyCount());
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
    var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer undone.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, undone.points);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = f.doc } });
    var redone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer redone.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, result.points, redone.points);
    return result;
}

test "weight first press only selects and strokes skip an anchor's only bone" {
    var f: Fixture = .{};
    try f.init("weight_targeting");
    defer f.deinit();
    const only_bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    try f.transport.synchronize();
    const shape = try f.addSquare();
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = f.doc, .ids = &.{shape} } });
    try f.transport.synchronize();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("rig");
    editor.tool.* = f.atoms.intern("weight");
    weight.sync(&f.tables, &f.atoms);
    const settings = weight.config(&f.tables);
    try std.testing.expectEqual(only_bone, settings.bone.*);
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const history_before = f.historyCount();
    const inside = m.Vec2{ .x = 20, .y = 20 };

    try f.down(inside);
    try f.answer();
    try f.up(inside);
    try std.testing.expect(f.selected(shape));
    try f.expectKind(.none);

    settings.brush_mode.* = f.atoms.intern("subtract");
    settings.radius.* = 90;
    try f.down(inside);
    try f.answer();
    try f.expectKind(.weight);
    try f.up(inside);
    for (0..12) |_| {
        f.pump();
        try f.drain(false);
        if (!gesture.busy(gesture.get(&f.tables))) break;
    }
    try f.expectSettled();
    try std.testing.expectEqual(history_before, f.historyCount());
    try std.testing.expectEqualStrings("", session.statusText(&f.tables));
    try std.testing.expect(session.informationText(&f.tables).len != 0);
}

test "weight pointer delivery grouping preserves posed stroke and history" {
    var individual = try weightEquivalenceRun(.individual);
    defer individual.deinit(std.testing.allocator);
    var grouped = try weightEquivalenceRun(.grouped);
    defer grouped.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, individual.points, grouped.points);
}

fn setupWeightFailureFixture(f: *Fixture, shape_count: usize) !void {
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } });
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("rig");
    editor.tool.* = f.atoms.intern("weight");
    weight.sync(&f.tables, &f.atoms);
    weight.pickBone(weight.config(&f.tables), session.get(&f.tables), bone);
    const settings = weight.config(&f.tables);
    settings.radius.* = 100;
    settings.strength.* = 0.1;
    settings.brush_mode.* = f.atoms.intern("replace");
    settings.value.* = 0.3;
    for (0..shape_count) |i| {
        const shape = try f.addSquare();
        _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = f.doc, .ids = &.{shape} } });
        selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), shape, i != 0, false);
    }
    try f.preparePreview();
    f.pump();
    try f.drain(false);
}

fn expectWeightSnapshotCleared(f: *Fixture) !void {
    const state = weight.stroke(&f.tables);
    try std.testing.expectEqual(@as(u32, 0), state.count.*);
    try std.testing.expectEqual(@as(u32, 0), state.shape_count.*);
    try std.testing.expectEqual(@as(u32, 0), state.point_count.*);
    try std.testing.expectEqual(@as(u32, 0), state.lock_count.*);
    for ([_][]const u8{ weight.targets_name, weight.samples_name, weight.shapes_name, weight.locks_name }) |name| {
        const table_name = f.atoms.intern(name);
        const owned_table = f.tables.findByName(table_name).?;
        const row_count = owned_table.count();
        try std.testing.expectEqual(@as(u32, 0), row_count);
    }
}

test "weight stroke schemas support complete runtime table inspection" {
    const rpc = mesha_runtime.mcp.table_rpc;
    var f: Fixture = .{};
    try f.init("weight_schema");
    defer f.deinit();
    const names = [_][]const u8{ weight.stroke_name, weight.targets_name, weight.samples_name, weight.shapes_name, weight.locks_name };
    for (names) |name| {
        const table_name = f.atoms.intern(name);
        const owned_table = f.tables.findByName(table_name).?;
        try rpc.validateRpcSchema(owned_table);
    }
}

test "weight saturated in-flight batch drains then rolls back" {
    var f: Fixture = .{};
    try f.init("weight_saturation");
    defer f.deinit();
    try setupWeightFailureFixture(&f, 1);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history = f.historyCount();
    try f.down(.{ .x = 10, .y = 10 });
    try f.answer();
    f.pump();
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    for (0..weight.sample_capacity + 1) |i| try f.move(.{ .x = if (i % 2 == 0) 12 else 10, .y = 10 });
    try f.expectStatus("WeightStrokeQueueFull");
    try f.expectPending(.cancel, 0);
    try f.drain(false);
    var changed = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer changed.deinit(std.testing.allocator);
    try std.testing.expect(!std.meta.eql(before.points[0].weights, changed.points[0].weights));
    f.pump();
    try f.expectPending(.cancel, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    f.pump();
    try f.drain(false);
    try f.expectSettled();
    try f.expectStatus("WeightStrokeQueueFull");
    try expectWeightSnapshotCleared(&f);
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, after.points);
    try std.testing.expectEqual(history, f.historyCount());
}

test "weight release drains complete batch prefixes before commit" {
    var f: Fixture = .{};
    try f.init("weight_prefix");
    defer f.deinit();
    try setupWeightFailureFixture(&f, 2);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history = f.historyCount();
    try f.down(.{ .x = 10, .y = 10 });
    try f.answer();
    for (0..140) |i| try f.move(.{ .x = if (i % 2 == 0) 12 else 10, .y = 10 });
    try f.up(.{ .x = 10, .y = 10 });
    const state = weight.stroke(&f.tables);
    try std.testing.expectEqual(@as(u32, 2), state.shape_count.*);
    try std.testing.expectEqual(@as(u32, 141), state.count.*);
    f.pump();
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    try f.expectPending(.commit, 0);
    try std.testing.expectEqual(@as(u32, 13), state.count.*);
    try f.drain(false);
    f.pump();
    try f.expectPending(.preview, 1);
    try f.expectPending(.commit, 0);
    try std.testing.expectEqual(@as(u32, 0), state.count.*);
    try f.drain(false);
    f.pump();
    try f.expectPending(.commit, 1);
    try f.drain(false);
    f.pump();
    try f.drain(false);
    try f.expectSettled();
    try expectWeightSnapshotCleared(&f);
    try std.testing.expectEqual(history + 1, f.historyCount());
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    var any_changed = false;
    for (before.points, after.points) |old, new| {
        if (!std.meta.eql(old.weights, new.weights)) any_changed = true;
    }
    try std.testing.expect(any_changed);
    _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
    var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer undone.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, undone.points);
}

test "drawing eraser drag deletes crossed strokes in one undo and spares filled interiors" {
    for ([_]bool{ true, false }) |commits| {
        var f: Fixture = .{};
        try f.init("drawing_eraser");
        defer f.deinit();
        const editor = session.get(&f.tables);
        editor.mode.* = f.atoms.intern("design");
        editor.tool.* = f.atoms.intern("eraser");
        const body = try f.addSquare();
        const stroke_points = [_]figure.Point{ .{ .p = .{ .x = 10, .y = 5 } }, .{ .p = .{ .x = 10, .y = 35 } } };
        const stroke = (try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{
            .doc = f.doc,
            .layer = 1,
            .style = .{ .stroke_color = .{ 0, 0, 0, 255 }, .stroke_width = 1 },
            .points = &stroke_points,
        } })).?;
        try f.preparePreview();
        const history = f.historyCount();
        // The drag starts and stays inside the body, and one long move spans the stroke.
        try f.down(.{ .x = 21, .y = 20 });
        try f.answer();
        try f.move(.{ .x = 5, .y = 20 });
        try f.answer();
        f.pump();
        try f.drain(false);
        f.pump();
        try f.drain(false);
        var during = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer during.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), during.shapes.len);
        try std.testing.expectEqual(body, during.shapes[0].id);
        if (commits) {
            try f.up(.{ .x = 5, .y = 20 });
        } else {
            workspace.cancel(&f.tables, &f.atoms);
        }
        try f.drain(false);
        f.pump();
        try f.drain(false);
        f.pump();
        try f.drain(false);
        try f.expectSettled();
        var settled = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer settled.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, if (commits) 1 else 2), settled.shapes.len);
        try std.testing.expectEqual(history + @as(u32, if (commits) 1 else 0), f.historyCount());
        if (commits) {
            _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
            var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
            defer undone.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 2), undone.shapes.len);
            try std.testing.expect(session.findById(m.Shape, undone.shapes, stroke) != null);
        }
    }
}

test "drawing pencil draft past the former 1024-point limit publishes on release" {
    var f: Fixture = .{};
    try f.init("drawing_overflow");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    editor.tool.* = f.atoms.intern("pencil");
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const history = f.historyCount();
    try f.down(.{ .x = 0, .y = 0 });
    for (1..1026) |i| {
        const x: f32 = @floatFromInt(i * 4);
        try f.move(.{ .x = x, .y = 0 });
        if (editor.gesture_active.* == 0) break;
    }
    try std.testing.expectEqual(@as(u8, 1), editor.gesture_active.*);
    const draft = f.tables.findByName(f.atoms.intern(session.draft_name)).?;
    try std.testing.expect(draft.count() > 1024);
    try f.up(.{ .x = 4100, .y = 0 });
    try f.drain(false);
    f.pump();
    try f.drain(false);
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expect(after.points.len >= 2);
    try std.testing.expectEqual(history + 1, f.historyCount());
    try f.expectSettled();
}

test "weight rejected foreign begin preserves foreign transaction" {
    var f: Fixture = .{};
    try f.init("weight_foreign");
    defer f.deinit();
    try setupWeightFailureFixture(&f, 1);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const context = session.figureContext(&f.tables, &f.atoms);
    _ = try commands_mod.submit(context, .{ .begin = .{ .doc = f.doc, .label = f.atoms.intern("foreign") } });
    try f.drain(false);
    const history = f.historyCount();
    try f.down(.{ .x = 10, .y = 10 });
    try f.answer();
    f.pump();
    try f.expectPending(.begin, 1);
    try f.drain(true);
    f.pump();
    try f.expectPending(.cancel, 0);
    try f.expectPending(.preview, 0);
    try f.drain(false);
    try f.expectSettled();
    try expectWeightSnapshotCleared(&f);
    try std.testing.expect(session.definitionInfo(&f.tables, &f.atoms, f.doc).?.transaction_open);
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, after.points);
    try std.testing.expectEqual(history, f.historyCount());
    _ = try commands_mod.submit(context, .{ .cancel = .{ .doc = f.doc } });
    try f.drain(false);
}

test "weight focus loss cancels changed stroke" {
    var f: Fixture = .{};
    try f.init("weight_focus_cancel");
    defer f.deinit();
    try setupWeightFailureFixture(&f, 1);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history = f.historyCount();
    try f.down(.{ .x = 10, .y = 10 });
    try f.answer();
    f.pump();
    try f.drain(false);
    f.pump();
    try f.drain(false);
    var changed = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer changed.deinit(std.testing.allocator);
    try std.testing.expect(!std.meta.eql(before.points[0].weights, changed.points[0].weights));
    workspace.focusLost(&f.tables, &f.atoms);
    f.pump();
    try f.expectPending(.cancel, 1);
    try f.expectPending(.commit, 0);
    try f.drain(false);
    f.pump();
    try f.drain(false);
    try f.expectSettled();
    try expectWeightSnapshotCleared(&f);
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, after.points);
    try std.testing.expectEqual(history, f.historyCount());
}

test "preview shows the working pose in Animate and the rest pose in Rig at once" {
    var f: Fixture = .{};
    try f.init("preview_held_pose");
    defer f.deinit();
    f.settleDesignLayout();
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = bone, .rotation = 1.0 }} } });
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("animate");
    try f.preparePreview();
    // The host's, until it next publishes: read before the next preparation.
    const posed = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expect(@abs(posed.bones[0].tip.y) > 20);
    editor.mode.* = f.atoms.intern("rig");
    try f.preparePreview();
    prompts.status(session.table(&f.tables), session.get(&f.tables), session.feedback(&f.tables), "sentinel");
    const rest = try preview.evaluation(&f.tables, &f.atoms);
    try std.testing.expectApproxEqAbs(@as(f32, 0), rest.bones[0].tip.y, 0.0001);
    // The preview changed since the last pick, so the first sync only clears the hover.
    editor.hover_kind.* = f.atoms.intern("bone");
    try f.move(.{ .x = 20, .y = 0 });
    f.pump();
    try std.testing.expectEqual(session.none, editor.hover_kind.*);
    try f.move(.{ .x = 20, .y = 0 });
    f.pump();
    const bone_kind = f.atoms.intern("bone");
    try std.testing.expectEqual(bone_kind, editor.hover_kind.*);
    try std.testing.expectEqual(bone, editor.hover_id.*);
    try f.expectStatus("sentinel");
    try f.drain(false);

    // A tool switch updates the cursor with the pointer at rest.
    editor.tool.* = f.atoms.intern("pen");
    try f.move(.{ .x = 200, .y = 200 });
    f.pump();
    const feedback = session.feedback(&f.tables);
    try std.testing.expectEqual(@intFromEnum(os.CursorKind.crosshair), feedback.cursor_kind.*);
    editor.tool.* = f.atoms.intern("hand");
    f.pump();
    try f.answerHover();
    try std.testing.expectEqual(@intFromEnum(os.CursorKind.hand), feedback.cursor_kind.*);
    try f.drain(false);
}

const DrawingBinding = enum { rigid, skinned };

test "drawing preview Select moves bound artwork in rest with cancel undo and redo" {
    for ([_]DrawingBinding{ .rigid, .skinned }) |binding| {
        var f: Fixture = .{};
        try f.init("drawing_bound_move");
        defer f.deinit();
        const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
        const shape = try f.addSquare();
        const paint = (try commands.apply(&f.atoms, &f.tables, .{ .set_paint = .{ .doc = f.doc, .shape = shape, .start = m.zero, .end = .{ .x = 10, .y = 0 }, .transform = .{ 2, 0, 0, 3, 4, 5 } } })).?;
        switch (binding) {
            .rigid => _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_rigid = .{ .doc = f.doc, .ids = &.{shape}, .bone = bone } }),
            .skinned => _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_skinned = .{ .doc = f.doc, .ids = &.{shape}, .bones = &.{bone} } }),
        }
        _ = try commands.apply(&f.atoms, &f.tables, .{ .set_pose_channels = .{ .doc = f.doc, .channels = &.{.{ .bone = bone, .local = .{ .x = 80, .y = 50 }, .rotation = 0.5 }} } });
        session.get(&f.tables).mode.* = f.atoms.intern("design");
        try f.preparePreview();
        const context = session.figureContext(&f.tables, &f.atoms);
        const shown = try preview.current(&f.tables, &f.atoms);
        const mapped_before = try figure_runtime.paintMapping(context, shown, shape, paint, null);
        var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer before.deinit(std.testing.allocator);
        const history = f.historyCount();
        for (0..2) |attempt| {
            try f.down(.{ .x = 20, .y = 25 });
            try f.answer();
            try f.expectKind(.move_shapes);
            try f.move(.{ .x = 30, .y = 33 });
            f.pump();
            try f.drain(false);
            f.pump();
            try f.drain(false);
            try f.expectOffset(before, .{ .x = 10, .y = 8 });
            if (attempt == 0) {
                workspace.cancel(&f.tables, &f.atoms);
            } else {
                try f.up(.{ .x = 30, .y = 33 });
            }
            for (0..8) |_| {
                f.pump();
                try f.drain(false);
                if (!gesture.busy(gesture.get(&f.tables))) break;
            }
            try f.expectSettled();
            if (attempt == 0) {
                try f.expectOffset(before, m.zero);
                try std.testing.expectEqual(history, f.historyCount());
            }
        }
        try std.testing.expectEqual(history + 1, f.historyCount());
        var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer after.deinit(std.testing.allocator);
        for (before.points, after.points) |old, new| try std.testing.expectEqualDeep(old.weights, new.weights);
        var expected_shape = before.shapes[0];
        expected_shape.start.x += 10;
        expected_shape.start.y += 8;
        expected_shape.end.x += 10;
        expected_shape.end.y += 8;
        try std.testing.expectEqualDeep(expected_shape, after.shapes[0]);
        try std.testing.expectEqualSlices(m.PoseChannel, before.pose_channels, after.pose_channels);
        try std.testing.expectEqualSlices(m.Bone, before.bones, after.bones);
        try f.preparePreview();
        const moved = try preview.current(&f.tables, &f.atoms);
        const mapped_after = try figure_runtime.paintMapping(context, moved, shape, paint, null);
        try std.testing.expectApproxEqAbs(mapped_before.start.?.x + 10, mapped_after.start.?.x, 1e-4);
        try std.testing.expectApproxEqAbs(mapped_before.start.?.y + 8, mapped_after.start.?.y, 1e-4);
        try std.testing.expectApproxEqAbs(mapped_before.end.?.x + 10, mapped_after.end.?.x, 1e-4);
        try std.testing.expectApproxEqAbs(mapped_before.end.?.y + 8, mapped_after.end.?.y, 1e-4);
        _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
        var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer undone.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(m.Point, before.points, undone.points);
        try std.testing.expectEqualSlices(m.Paint, before.paints, undone.paints);
        try std.testing.expectEqualSlices(m.Shape, before.shapes, undone.shapes);
        try std.testing.expectEqualSlices(m.PoseChannel, before.pose_channels, undone.pose_channels);
        _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = f.doc } });
        var redone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer redone.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(m.Point, after.points, redone.points);
        try std.testing.expectEqualSlices(m.Paint, after.paints, redone.paints);
        try std.testing.expectEqualSlices(m.Shape, after.shapes, redone.shapes);
        try std.testing.expectEqualSlices(m.PoseChannel, after.pose_channels, redone.pose_channels);
    }
}

test "drawing preview workspace Delete removes what its tab edits atomically and undo restores the binding" {
    for ([_]bool{ false, true }) |rigging| {
        var f: Fixture = .{};
        try f.init("drawing_delete_selection");
        defer f.deinit();
        const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 40, .make_stroke = false } })).?;
        const shape = try f.addSquare();
        _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_rigid = .{ .doc = f.doc, .ids = &.{shape}, .bone = bone } });
        try f.preparePreview();
        const bone_kind = f.atoms.intern("bone");
        const shape_kind = f.atoms.intern("shape");
        // Design deletes the selected artwork; Rig deletes the selected bones and keeps artwork.
        session.get(&f.tables).mode.* = f.atoms.intern(if (rigging) "rig" else "design");
        if (rigging) selection.select(&f.tables, &f.atoms, bone_kind, bone, false, false);
        selection.select(&f.tables, &f.atoms, shape_kind, shape, rigging, false);
        const history = f.historyCount();
        const delete_tag = f.atoms.intern("figure_delete_bone");
        const invoked: mesha.sequencer.Message = .{ .tag = delete_tag };
        const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, invoked);
        try std.testing.expect(handled);
        try f.drain(false);
        var removed = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer removed.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, if (rigging) 1 else 0), removed.shapes.len);
        try std.testing.expectEqual(@as(usize, if (rigging) 0 else 1), removed.bones.len);
        try std.testing.expectEqual(history + 1, f.historyCount());
        _ = try commands.apply(&f.atoms, &f.tables, .{ .undo = .{ .doc = f.doc } });
        var undone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer undone.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), undone.shapes.len);
        try std.testing.expectEqual(@as(usize, 1), undone.bones.len);
        try std.testing.expectEqual(bone, undone.shapes[0].bone);
        _ = try commands.apply(&f.atoms, &f.tables, .{ .redo = .{ .doc = f.doc } });
        var redone = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer redone.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(m.Shape, removed.shapes, redone.shapes);
        try std.testing.expectEqualSlices(m.Bone, removed.bones, redone.bones);
    }
}

test "drawing preview Select shares hover press priority in Rig and a marquee gathers what its tab edits" {
    var f: Fixture = .{};
    try f.init("drawing_selection_priority");
    defer f.deinit();
    f.settleDesignLayout();
    const bone = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 80, .make_stroke = false } })).?;
    const shape = try f.addSquare();
    _ = try commands.apply(&f.atoms, &f.tables, .{ .bind_rigid = .{ .doc = f.doc, .ids = &.{shape}, .bone = bone } });
    try f.preparePreview();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("rig");
    const bone_kind = f.atoms.intern("bone");
    const shape_kind = f.atoms.intern("shape");
    const samples = [_]struct { point: m.Vec2, kind: Atom, id: u32 }{
        .{ .point = .{ .x = 0, .y = 0 }, .kind = bone_kind, .id = bone },
        .{ .point = .{ .x = 20, .y = 0 }, .kind = bone_kind, .id = bone },
        .{ .point = .{ .x = 20, .y = 20 }, .kind = shape_kind, .id = shape },
        .{ .point = .{ .x = 60, .y = 0 }, .kind = bone_kind, .id = bone },
    };
    f.pump();
    try f.drain(false);
    for (samples) |sample| {
        try f.move(.{ .x = -20, .y = -20 });
        try f.move(sample.point);
        f.pump();
        try f.answerHover();
        try std.testing.expectEqual(sample.kind, editor.hover_kind.*);
        try std.testing.expectEqual(sample.id, editor.hover_id.*);
        try f.down(sample.point);
        try f.answer();
        try std.testing.expectEqual(sample.kind, editor.active_kind.*);
        try std.testing.expectEqual(sample.id, editor.active_id.*);
        workspace.cancel(&f.tables, &f.atoms);
        for (0..8) |_| {
            f.pump();
            try f.drain(false);
            if (!gesture.busy(gesture.get(&f.tables))) break;
        }
    }
    // Design picks artwork alone, through the bones drawn over it.
    editor.mode.* = f.atoms.intern("design");
    try f.move(.{ .x = 60, .y = 0 });
    f.pump();
    try f.answerHover();
    try std.testing.expectEqual(@as(u32, 0), editor.hover_id.*);
    try f.down(.{ .x = 60, .y = 0 });
    try f.answer();
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), bone_kind, bone));
    try f.up(.{ .x = 60, .y = 0 });
    try f.answer();
    try f.down(.{ .x = -20, .y = -20 });
    try f.answer();
    try f.move(.{ .x = 100, .y = 60 });
    try f.up(.{ .x = 100, .y = 60 });
    try f.answer();
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), bone_kind, bone));
    try std.testing.expect(selection.contains(session.get(&f.tables), session.selections(&f.tables), shape_kind, shape));
    // Rig's marquee gathers bones alone, and its traversal steps through them.
    editor.mode.* = f.atoms.intern("rig");
    try f.down(.{ .x = -20, .y = -20 });
    try f.answer();
    try f.move(.{ .x = 100, .y = 60 });
    try f.up(.{ .x = 100, .y = 60 });
    try std.testing.expect(selection.contains(session.get(&f.tables), session.selections(&f.tables), bone_kind, bone));
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), shape_kind, shape));
    const next: mesha.sequencer.Message = .{ .tag = f.atoms.intern("figure_select_next") };
    _ = workspace.handle(&f.mem, &f.tables, &f.atoms, next);
    try std.testing.expectEqual(bone_kind, editor.active_kind.*);
    // Design's traversal steps through artwork, and a bound shape names its bone.
    editor.mode.* = f.atoms.intern("design");
    selection.select(&f.tables, &f.atoms, shape_kind, shape, false, false);
    try std.testing.expectEqual(bone, editor.active_bone.*);
    _ = workspace.handle(&f.mem, &f.tables, &f.atoms, next);
    try std.testing.expectEqual(shape_kind, editor.active_kind.*);
    try std.testing.expectEqual(bone, editor.active_bone.*);
    const shape_fields = prompts.inspectorFields(shape_kind);
    session.observed(&f.tables).key_panel.* = f.atoms.intern(workspace.inspector_id);
    editor.inspector_field.* = @intCast(shape_fields.len - 1);
    _ = workspace.handle(&f.mem, &f.tables, &f.atoms, next);
    try std.testing.expectEqual(@as(u32, 0), editor.inspector_field.*);
    try f.drain(false);
}

test "drawing preview bone stroke and joint fill body drags report follows bones without edits" {
    for ([_]bool{ false, true }) |joint_fill| {
        var f: Fixture = .{};
        try f.init("drawing_special_no_move");
        defer f.deinit();
        if (joint_fill) {
            const first = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 10, .make_stroke = false } })).?;
            const second = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .local = .{ .x = 80, .y = 0 }, .length = 10, .make_stroke = false } })).?;
            const third = (try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .local = .{ .x = 0, .y = 80 }, .length = 10, .make_stroke = false } })).?;
            const joint_fill_kind = f.atoms.intern("joint_fill");
            _ = try commands.apply(&f.atoms, &f.tables, .{ .add_shape = .{ .doc = f.doc, .layer = 1, .kind = joint_fill_kind, .closed = 1, .style = .{ .fill_color = .{ 255, 0, 0, 255 }, .stroke_width = 0 }, .points = &.{ .{ .joint_bone = first, .joint_end = 0 }, .{ .joint_bone = second, .joint_end = 0 }, .{ .joint_bone = third, .joint_end = 0 } } } });
        } else {
            _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 80, .make_stroke = true } });
        }
        try f.preparePreview();
        var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer before.deinit(std.testing.allocator);
        const history = f.historyCount();
        const point: m.Vec2 = if (joint_fill) .{ .x = 20, .y = 20 } else .{ .x = 40, .y = 0 };
        try f.down(point);
        try f.answer();
        const information = session.informationText(&f.tables);
        try std.testing.expectEqualStrings("This artwork follows its bones; move a bone instead", information);
        try f.expectStatus("");
        try std.testing.expect(f.selected(before.shapes[0].id));
        try f.expectSettled();
        try f.move(.{ .x = 50, .y = 35 });
        try f.up(.{ .x = 50, .y = 35 });
        f.pump();
        try f.drain(false);
        try f.expectSettled();
        try std.testing.expectEqual(history, f.historyCount());
        var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
        defer after.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(m.Shape, before.shapes, after.shapes);
        try std.testing.expectEqualSlices(m.Bone, before.bones, after.bones);
        try std.testing.expectEqualSlices(m.Point, before.points, after.points);
        try std.testing.expectEqualSlices(m.Paint, before.paints, after.paints);
        try std.testing.expectEqualSlices(m.PoseChannel, before.pose_channels, after.pose_channels);
    }
}

test "context menu closes on dismiss even though its tags are not interned" {
    var f: Fixture = .{};
    try f.init("context_menu_dismiss");
    defer f.deinit();
    context_menu.open(context_menu.get(&f.tables), .canvas, 10, 10);
    const dismiss: mesha.sequencer.Message = .{ .tag = Atom.from(workspace.Msg.figure_menu_dismiss) };
    const handled = workspace.handle(&f.mem, &f.tables, &f.atoms, dismiss);
    try std.testing.expect(handled);
    try std.testing.expect(!context_menu.isOpen(context_menu.get(&f.tables)));
}

test "drawing preview an answer for a replaced question changes nothing" {
    var f: Fixture = .{};
    try f.init("asks_replaced");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    const shape = try f.addSquare();
    try f.preparePreview();
    f.pump();
    try f.drain(false);
    const shape_kind = f.atoms.intern("shape");
    const over_shape = m.Vec2{ .x = 20, .y = 20 };
    // The hover shows the square.
    try f.move(over_shape);
    f.pump();
    try f.answerHover();
    try std.testing.expectEqual(shape_kind, editor.hover_kind.*);
    try std.testing.expectEqual(shape, editor.hover_id.*);
    // The pointer leaves it: the hover asks about empty canvas, and the host answers.
    try f.move(.{ .x = 200, .y = 200 });
    f.pump();
    try f.transport.synchronize();
    // Before the view takes that answer, the hover asks again, replacing the question.
    try asks.hitTest(&f.tables, &f.atoms, view.system(), .{ .purpose = .hover, .point = over_shape });
    // The replaced question's answer arrives and changes nothing: the square is still hovered.
    f.pump();
    try std.testing.expectEqual(shape_kind, editor.hover_kind.*);
    try std.testing.expectEqual(shape, editor.hover_id.*);
    // The question that replaced it is answered in turn.
    try f.answerHover();
    try std.testing.expectEqual(shape, editor.hover_id.*);
    try std.testing.expectEqual(@as(u32, 0), asks.rows(&f.tables).count());
}

test "drawing preview a press, drag and release within one frame select and move what was under the press" {
    var f: Fixture = .{};
    try f.init("asks_press_drag_release");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    const shape = try f.addSquare();
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const history_before = f.historyCount();
    // All three arrive before the host has said what lies under the press.
    try f.down(.{ .x = 20, .y = 20 });
    try f.move(.{ .x = 30, .y = 25 });
    try f.up(.{ .x = 40, .y = 32 });
    try std.testing.expect(!f.selected(shape));
    try f.expectKind(.none);
    try std.testing.expectEqual(@as(u32, 2), gesture.heldInput(&f.tables).count());
    // The answer selects the square and starts moving it; the drag and the release follow.
    try f.answer();
    try std.testing.expect(f.selected(shape));
    try f.expectKind(.move_shapes);
    try std.testing.expectEqual(@as(u32, 0), gesture.heldInput(&f.tables).count());
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    for (0..8) |_| {
        f.pump();
        try f.drain(false);
        if (!gesture.busy(gesture.get(&f.tables))) break;
    }
    try f.expectSettled();
    try f.expectOffset(before, .{ .x = 20, .y = 12 });
    try std.testing.expectEqual(history_before + 1, f.historyCount());
}

test "weight press whose focus is lost before its answer begins no stroke" {
    var f: Fixture = .{};
    try f.init("asks_focus_lost");
    defer f.deinit();
    try setupWeightFailureFixture(&f, 1);
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    try f.down(.{ .x = 10, .y = 10 });
    // Focus moves away in the frame of the press, before the host has answered it.
    workspace.focusLost(&f.tables, &f.atoms);
    try f.answer();
    try f.expectKind(.none);
    try std.testing.expectEqual(@as(u8, 0), session.get(&f.tables).gesture_active.*);
    f.pump();
    try f.expectPending(null, 0);
    try f.drain(false);
    try f.expectSettled();
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(m.Point, before.points, after.points);
}

test "drawing preview a press whose answer never comes is given up and the next press works" {
    var f: Fixture = .{};
    try f.init("asks_lost_answer");
    defer f.deinit();
    // The host's clock, which ages the questions in flight.
    const Clock = struct { frame_index: u64 = 0 };
    const clock_table = try session.ensureSingleton(Clock, &f.mem, &f.atoms, &f.tables, mesha.time.state_table_name);
    const clock = clock_table.getRow(.{ .row = 0, .generation = clock_table.rowGeneration(0) }, session.Row(Clock)).?;
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    const shape = try f.addSquare();
    try f.preparePreview();
    try f.down(.{ .x = 20, .y = 20 });
    try f.move(.{ .x = 30, .y = 25 });
    // The host never answers: its question is gone before it synchronizes.
    figure.Queries.of(&f.mem, &f.tables, figure.queries_table_name).reset();
    try std.testing.expectEqual(@as(u32, 1), gesture.heldInput(&f.tables).count());
    // The first frame after the press finds it waiting; it is given up that many frames later.
    clock.frame_index.* = 1;
    f.transport.runCanvas();
    for (1..asks.answer_frames_max) |waited| {
        clock.frame_index.* = 1 + waited;
        f.transport.runCanvas();
        try std.testing.expectEqual(@as(u32, 1), asks.rows(&f.tables).count());
    }
    clock.frame_index.* = 1 + asks.answer_frames_max;
    f.transport.runCanvas();
    try std.testing.expectEqual(@as(u32, 0), asks.rows(&f.tables).count());
    try std.testing.expectEqual(@as(u32, 0), gesture.heldInput(&f.tables).count());
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    try std.testing.expect(!f.selected(shape));
    try std.testing.expectEqualStrings("The figure host did not answer in time; the press was cancelled", session.informationText(&f.tables));
    // The release that ends the given-up press does nothing, and the next press works.
    try f.up(.{ .x = 30, .y = 25 });
    try f.down(.{ .x = 20, .y = 20 });
    try f.answer();
    try std.testing.expect(f.selected(shape));
    try f.expectKind(.move_shapes);
}

/// How many of the canvas's subscriptions to the clock's frames `subscriptions.time` holds.
fn canvasFrameSubscriptions(tables: *Table.Registry) usize {
    const rows = tables.findByName(Atom.from(mesha.time.subscriptions_table_name)) orelse return 0;
    const frame_tag = Atom.from(workspace.Msg.figure_information_frame);
    var count: usize = 0;
    var subscribed = rows.query(mesha.time.SubscriptionRow);
    while (subscribed.next()) |row| {
        if (row.view.tag.* == frame_tag) count += 1;
    }
    return count;
}

test "drawing preview a question whose answer is lost keeps frames coming until it is given up" {
    var f: Fixture = .{};
    try f.init("asks_lost_frames");
    defer f.deinit();
    // The host's clock, which ages the questions in flight.
    const Clock = struct { frame_index: u64 = 0 };
    const clock_table = try session.ensureSingleton(Clock, &f.mem, &f.atoms, &f.tables, mesha.time.state_table_name);
    const clock = clock_table.getRow(.{ .row = 0, .generation = clock_table.rowGeneration(0) }, session.Row(Clock)).?;
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    _ = try f.addSquare();
    try f.preparePreview();
    f.pump();
    // Nothing waits: the canvas does not hear the clock, and a quiet host may sleep.
    try std.testing.expectEqual(@as(usize, 0), canvasFrameSubscriptions(&f.tables));
    try f.down(.{ .x = 20, .y = 20 });
    // The host never answers: its question is gone before it synchronizes.
    figure.Queries.of(&f.mem, &f.tables, figure.queries_table_name).reset();
    // The frame ends with the view, which hears the clock while the question holds input.
    f.pump();
    try std.testing.expectEqual(@as(u32, 1), asks.rows(&f.tables).count());
    try std.testing.expectEqual(@as(usize, 1), canvasFrameSubscriptions(&f.tables));
    // The frames that brings come with no input, and the canvas gives the question up.
    for (1..asks.answer_frames_max + 2) |frame_index| {
        clock.frame_index.* = frame_index;
        f.transport.runCanvas();
    }
    try std.testing.expectEqual(@as(u32, 0), asks.rows(&f.tables).count());
    try std.testing.expectEqual(@as(u8, 0), editor.gesture_active.*);
    // Once the person has read why, nothing keeps the canvas hearing the clock.
    session.feedback(&f.tables).information_seconds.* = 0;
    f.pump();
    try std.testing.expectEqual(@as(usize, 0), canvasFrameSubscriptions(&f.tables));
}

test "drawing preview a key held behind a press acts on the selection the press made" {
    var f: Fixture = .{};
    try f.init("asks_ordered_key");
    defer f.deinit();
    const editor = session.get(&f.tables);
    editor.mode.* = f.atoms.intern("design");
    // A bone's stroke: a press selects it without starting a drag.
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_bone = .{ .doc = f.doc, .length = 80, .make_stroke = true } });
    try f.preparePreview();
    var before = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer before.deinit(std.testing.allocator);
    const stroke = before.shapes[0].id;
    try f.down(.{ .x = 40, .y = 0 });
    // Delete arrives in the frame of the press, before the host has said what lies under it.
    try f.action("figure_delete_bone");
    try std.testing.expect(!f.selected(stroke));
    try f.expectPending(.delete_selection, 0);
    try f.answer();
    try std.testing.expect(f.selected(stroke));
    try f.expectPending(.delete_selection, 1);
    try f.drain(false);
    var after = try t.snapshot(std.testing.allocator, &f.tables, &f.atoms, f.doc);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(before.shapes.len - 1, after.shapes.len);
}
