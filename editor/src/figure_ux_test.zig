//! UX regression retained app-side; domain coverage now lives in systems.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const mesha_runtime = @import("mesha_runtime");
const workspace = @import("figure/workspace.zig");
const transport_fixture = @import("figure/transport_fixture.zig");
const figure_runtime = mesha_runtime.figure;
const button = @import("ui/button.zig");
const session = @import("figure/session.zig");
const selection = @import("figure/selection.zig");
const list = @import("figure/list_navigation.zig");
const panels = @import("figure/panels.zig");
pub const Fixture = figure_runtime.domain.tests.Fixture;
const t = figure_runtime.domain.tables;
const commands = figure_runtime.domain.command;

/// The end of a frame: the editor declares its watches, from every table of its own, and the
/// figure host publishes what it holds and answers them. A test that calls it tears the figure
/// runtime down.
fn publish(f: *Fixture) !void {
    try workspace.ensure(&f.mem, &f.atoms, &f.tables);
    try transport_fixture.synchronize(&f.mem, &f.atoms, &f.tables);
}

test "preview shared button disabled click stable IDs and icon fallback" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try ui.Tree.init(.{ .allocator = arena.allocator() }, &f.atoms, 64);
    button.render(&tree, "disabled", .{ .tag = @enumFromInt(42) }, .{ .label = "Disabled", .enabled = false, .icon = .add });
    try std.testing.expect(tree.elements[0].open_rect.on_click == null);
    try std.testing.expect(!tree.elements[0].open_rect.hover);
    const next = tree.count;
    button.render(&tree, "enabled", .{ .tag = @enumFromInt(7) }, .{ .label = "Enabled", .icon = .add, .icons_available = false });
    try std.testing.expectEqual(@as(mesha.Atom, @enumFromInt(7)), tree.elements[next].open_rect.on_click.?.tag);
    try std.testing.expect(tree.elements[next].open_rect.hover);
    try std.testing.expect(!std.meta.eql(tree.elements[0].open_rect.id, tree.elements[next].open_rect.id));
    // An unavailable icon leaves exactly the rect, readable label and closing scope.
    try std.testing.expectEqual(@as(usize, 3), tree.count - next);
    for (std.meta.tags(button.icons.Icon)) |icon| {
        const cp = try std.unicode.utf8Decode(button.icons.glyph(icon));
        const codepoints = &mesha.resources.font.legacy_icon_codepoints;
        try std.testing.expect(std.mem.indexOfScalar(u32, codepoints, cp) != null);
    }
}

test "artist blend document replacement preserves valid selection but cancels drag and close prunes state" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    defer figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
    try f.load("blue", figure_runtime.domain.tests.blue_source);
    const doc = f.atoms.intern("blue");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const s = session.get(&f.tables);
    s.doc.* = doc;
    try publish(&f);
    const layers = try t.family(&f.tables, doc, "layers");
    var rows = layers.query(t.Layer);
    const id = rows.next().?.view.id.*;
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), id, false, false);
    const folder = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{id} } })).?;
    try publish(&f);
    try selection.toggleCollapse(session.collapsedFolders(&f.tables), session.get(&f.tables), folder);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), id, false, false);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), folder, true, false);
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), id, true, false);
    s.outliner_drag.* = id;
    try f.load("blue", "not a figure file");
    try publish(&f);
    try std.testing.expectEqual(id, s.outliner_drag.*);
    try f.load("blue", figure_runtime.domain.tests.blue_source);
    try publish(&f);
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_drag.*);
    try std.testing.expect(selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), id));
    try std.testing.expectEqual(id, s.active_id.*);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), folder));
    try std.testing.expect(!selection.collapsed(session.collapsedFolders(&f.tables), session.get(&f.tables), folder));
    s.outliner_drag.* = 999999;
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_drag.*);
    s.outliner_drag.* = id;
    t.removeDocument(&f.tables, &f.atoms, doc);
    try publish(&f);
    selection.prune(&f.tables, &f.atoms);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_drag.*);
    try std.testing.expectEqual(@as(u32, 0), s.active_id.*);
    try std.testing.expect(!selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), id));
}

test "preview figure list wheel stays independent and keyboard reveal follows resize" {
    const Node = selection.OutlinerNode;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const layer = f.atoms.intern("layer");
    const clip = f.atoms.intern("clip");
    const pose = f.atoms.intern("pose");
    const nodes = [_]Node{
        .{ .kind = layer, .id = 1, .name = layer },
        .{ .kind = layer, .id = 2, .name = layer },
        .{ .kind = clip, .id = 1, .name = clip },
        .{ .kind = pose, .id = 1, .name = pose },
    };
    // Rows share one geometry with tabs: a bones/clips/poses list starts at 40,
    // the art tab adds its folder tools row.
    try std.testing.expectEqual(@as(usize, 3), list.visibleEnd(&nodes, 0, 136, list.top(288, false)));
    try std.testing.expectEqual(@as(usize, 4), list.visibleEnd(&nodes, 0, 300, list.top(288, false)));
    try std.testing.expectEqual(@as(usize, 2), list.visibleEnd(&nodes, 0, 136, list.top(288, true)));
    // Scrolling away from the selected first row must survive subsequent renders.
    const scrolled = list.wheel(0, -2, nodes.len - 1);
    try std.testing.expectEqual(@as(usize, 2), list.scrollStart(&nodes, scrolled, 0, 300, false, list.top(288, false)));
    try std.testing.expectEqual(@as(usize, 0), list.scrollStart(&nodes, scrolled, 0, 300, true, list.top(288, false)));
    // A selected bottom row remains visible when the panel shrinks.
    const resized = list.scrollStart(&nodes, 0, 3, 136, true, list.top(288, false));
    try std.testing.expect(resized > 0);
    try std.testing.expect(list.visibleEnd(&nodes, resized, 136, list.top(288, false)) > 3);
    try std.testing.expectEqual(@as(usize, 0), list.scrollStart(&nodes, resized, 0, 136, true, list.top(288, false)));
    // A width-only resize that rewraps the tab rows costs row capacity and must
    // still reveal the selected row.
    try std.testing.expectEqual(@as(usize, 3), list.scrollStart(&nodes, resized, 3, 136, true, list.top(190, true)));
}

test "preview figure outliner list top follows tab rows and art folder tools" {
    // Default-width dock: one tab row; art adds the folder tools row.
    try std.testing.expectEqual(@as(f32, 40), list.top(288, false));
    try std.testing.expectEqual(@as(f32, 76), list.top(288, true));
    // Narrow dock wraps the four tabs into two rows, including the 4 px gap.
    try std.testing.expectEqual(@as(f32, 76), list.top(160, false));
    try std.testing.expectEqual(@as(f32, 112), list.top(160, true));
}

test "preview figure outliner category tabs filter kinds and flatten pose and clip depth" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load("blue", figure_runtime.domain.tests.blue_source);
    const doc = f.atoms.intern("blue");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    session.get(&f.tables).doc.* = doc;
    _ = try commands.apply(&f.atoms, &f.tables, .{ .add_clip = .{ .doc = doc, .name = f.atoms.intern("walk") } });
    _ = try commands.apply(&f.atoms, &f.tables, .{ .save_pose = .{ .doc = doc, .name = f.atoms.intern("tired") } });
    try publish(&f);
    defer figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
    const a = std.testing.allocator;
    const layer = f.atoms.intern("layer");
    const shape = f.atoms.intern("shape");
    const bone = f.atoms.intern("bone");
    const clip = f.atoms.intern("clip");
    const pose = f.atoms.intern("pose");
    const art = try selection.categoryNodes(a, &f.tables, &f.atoms, .art);
    defer a.free(art);
    try std.testing.expect(art.len == 13);
    for (art) |node| try std.testing.expect(node.kind == layer or node.kind == shape);
    try std.testing.expectEqual(@as(u32, 0), art[0].depth);
    try std.testing.expect(art[1].depth > art[0].depth);
    const bones = try selection.categoryNodes(a, &f.tables, &f.atoms, .bones);
    defer a.free(bones);
    try std.testing.expectEqual(@as(usize, 10), bones.len);
    for (bones) |node| try std.testing.expectEqual(bone, node.kind);
    try std.testing.expectEqual(@as(u32, 0), bones[0].depth);
    try std.testing.expectEqual(@as(u32, 1), bones[1].depth);
    const clips = try selection.categoryNodes(a, &f.tables, &f.atoms, .clips);
    defer a.free(clips);
    try std.testing.expectEqual(@as(usize, 1), clips.len);
    try std.testing.expectEqual(clip, clips[0].kind);
    try std.testing.expectEqual(@as(u32, 0), clips[0].depth);
    const poses = try selection.categoryNodes(a, &f.tables, &f.atoms, .poses);
    defer a.free(poses);
    try std.testing.expectEqual(@as(usize, 1), poses.len);
    try std.testing.expectEqual(pose, poses[0].kind);
    try std.testing.expectEqual(@as(u32, 0), poses[0].depth);
}

test "preview figure outliner tab reveals category on selection and keeps view on multi-select" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load("blue", figure_runtime.domain.tests.blue_source);
    const doc = f.atoms.intern("blue");
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const s = session.get(&f.tables);
    s.doc.* = doc;
    try std.testing.expectEqual(selection.Category.art, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    // Primary selection is the boundary that reveals a category tab.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("bone"), 2, false, false);
    try std.testing.expectEqual(selection.Category.bones, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    // Adding to a multi-selection keeps the current tab.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, true, false);
    try std.testing.expectEqual(selection.Category.bones, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    // An explicit tab switch only changes the view.
    selection.setOutlinerTab(session.outlinerTab(&f.tables), .clips);
    try std.testing.expectEqual(selection.Category.clips, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, false, false);
    try std.testing.expectEqual(selection.Category.art, selection.outlinerCategory(session.outlinerTab(&f.tables)));
}

/// The id of the named row in a `figure_test_domain` table; loads keep ZON order.
fn figureTestId(f: *Fixture, doc: mesha.Atom, comptime family: []const u8, comptime view: type, name: []const u8) !u32 {
    const rows = try t.family(&f.tables, doc, family);
    const wanted = f.atoms.intern(name);
    var query = rows.query(view);
    while (query.next()) |row| if (row.view.name.* == wanted) return row.view.id.*;
    return error.FigureTestNameNotFound;
}

/// One outliner render into a scratch tree; the scroll/reveal bookkeeping in
/// session state is the observable, no roop drawing is needed.
fn renderOutlinerOnce(f: *Fixture, width: f32, height: f32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try ui.Tree.init(.{ .allocator = arena.allocator() }, &f.atoms, 8192);
    // As a frame does: the figure view's run settles where the list starts, then it is drawn.
    panels.settleOutlinerScroll(arena.allocator(), &f.tables, &f.atoms, width, height);
    panels.renderOutliner(arena.allocator(), &tree, &f.tables, &f.atoms, .{ .x = 0, .y = 0, .width = width, .height = height });
}

test "preview figure outliner tab browse renders from the top without re-revealing selection" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.load("blue", figure_runtime.domain.tests.blue_source);
    try publish(&f);
    defer figure_runtime.deinit(.{ .memory = &f.mem, .tables = &f.tables, .atoms = &f.atoms }) catch {};
    try session.ensure(&f.mem, &f.atoms, &f.tables);
    const s = session.get(&f.tables);
    s.doc.* = f.atoms.intern("blue");
    try publish(&f);
    const a = std.testing.allocator;
    // A short dock: the deep art shape `left_shin_stroke` needs scrolling.
    const deep_shape = try figureTestId(&f, f.atoms.intern("blue"), "shapes", t.Shape, "left_shin_stroke");
    const deep_bone = try figureTestId(&f, f.atoms.intern("blue"), "bones", t.Bone, "right_shin");
    const art = try selection.categoryNodes(a, &f.tables, &f.atoms, .art);
    defer a.free(art);
    var deep_shape_index: usize = 0;
    for (art, 0..) |node, index| if (node.id == deep_shape) {
        deep_shape_index = index;
        break;
    };
    // Selection boundary reveals the deep art row in a short dock.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("shape"), deep_shape, false, false);
    try renderOutlinerOnce(&f, 288, 190);
    try std.testing.expect(s.outliner_scroll.* > 0);
    try std.testing.expect(s.outliner_scroll.* <= deep_shape_index);
    try std.testing.expect(deep_shape_index < list.visibleEnd(art, s.outliner_scroll.*, 190, list.top(288, true)));
    // Browsing away filters the view only: top of Bones, selection untouched.
    workspace.browseOutlinerCategory(session.get(&f.tables), session.outlinerTab(&f.tables), session.observed(&f.tables), .bones);
    try renderOutlinerOnce(&f, 288, 190);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_scroll.*);
    try std.testing.expectEqual(selection.Category.bones, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    try std.testing.expectEqual(f.atoms.intern("shape"), s.active_kind.*);
    try std.testing.expectEqual(deep_shape, s.active_id.*);
    // Returning to Art layers stays at the top instead of snapping back to
    // the stale recorded index from the Bones render.
    workspace.browseOutlinerCategory(session.get(&f.tables), session.outlinerTab(&f.tables), session.observed(&f.tables), .art);
    try renderOutlinerOnce(&f, 288, 190);
    try std.testing.expectEqual(@as(u32, 0), s.outliner_scroll.*);
    // A new primary selection still reveals its category and row.
    selection.select(&f.tables, &f.atoms, f.atoms.intern("bone"), deep_bone, false, false);
    try renderOutlinerOnce(&f, 288, 190);
    const bones = try selection.categoryNodes(a, &f.tables, &f.atoms, .bones);
    defer a.free(bones);
    var deep_bone_index: usize = 0;
    for (bones, 0..) |node, index| if (node.id == deep_bone) {
        deep_bone_index = index;
        break;
    };
    try std.testing.expectEqual(selection.Category.bones, selection.outlinerCategory(session.outlinerTab(&f.tables)));
    try std.testing.expect(s.outliner_scroll.* <= deep_bone_index);
    try std.testing.expect(deep_bone_index < list.visibleEnd(bones, s.outliner_scroll.*, 190, list.top(288, false)));
    // A real resize still reveals the selected row after scrolling away.
    s.outliner_scroll.* = 0;
    session.observed(&f.tables).outliner_reveal.* = 0;
    try renderOutlinerOnce(&f, 288, 140);
    try std.testing.expect(s.outliner_scroll.* > 0);
    try std.testing.expect(s.outliner_scroll.* <= deep_bone_index);
    try std.testing.expect(deep_bone_index < list.visibleEnd(bones, s.outliner_scroll.*, 140, list.top(288, false)));
}

const api = mesha.figure;
const history = figure_runtime.domain.history;
test "artist blend representative staging and publication allocation failures are atomic" {
    for (0..3) |operation| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const doc = try f.create("allocation_transactions");
        try session.ensure(&f.mem, &f.atoms, &f.tables);
        session.get(&f.tables).doc.* = doc;
        const second = (try commands.apply(&f.atoms, &f.tables, .{ .add_layer = .{ .doc = doc } })).?;
        const folder = (try commands.apply(&f.atoms, &f.tables, .{ .group_layers = .{ .doc = doc, .ids = &.{1} } })).?;
        selection.select(&f.tables, &f.atoms, f.atoms.intern("layer"), 1, false, false);
        const request: api.Payload = switch (operation) {
            0 => .{ .group_layers = .{ .doc = doc, .ids = &.{ second, 1 } } },
            1 => .{ .set_layer = .{ .doc = doc, .id = second, .parent = folder } },
            else => .{ .delete_layer = .{ .doc = doc, .id = folder, .confirmed = true } },
        };
        // Count once, not exhaustive enumeration: first staging allocation and
        // final scratch allocation (the publication row-index map).
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var counting = std.testing.FailingAllocator.init(arena.allocator(), .{});
        _ = try commands.applyWithAllocator(&f.atoms, &f.tables, request, counting.allocator());
        const count = counting.alloc_index;
        try history.undo(&f.tables, &f.atoms, doc);
        const before = try f.contentBytes(doc);
        defer std.testing.allocator.free(before);
        const state = try figure_runtime.domain.history_state.get(&f.mem);
        for ([_]usize{ 0, count - 1 }) |index| {
            const used = state.journal.used;
            const next_sequence = state.journal.next_sequence;
            const metadata = f.tables.findByName(f.atoms.intern(history.table_name)).?;
            const metadata_count = metadata.count();
            // A fresh arena, as the count had: resizing in place depends on what an arena holds.
            var attempt_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer attempt_arena.deinit();
            var failing = std.testing.FailingAllocator.init(attempt_arena.allocator(), .{ .fail_index = index });
            try std.testing.expectError(error.OutOfMemory, commands.applyWithAllocator(&f.atoms, &f.tables, request, failing.allocator()));
            const after = try f.contentBytes(doc);
            defer std.testing.allocator.free(after);
            try std.testing.expectEqualStrings(before, after);
            try std.testing.expectEqual(used, state.journal.used);
            // Publication may consume a sequence, but must never rewind it and
            // risk reusing an ID observed while the transaction was active.
            try std.testing.expect(state.journal.next_sequence >= next_sequence);
            try std.testing.expectEqual(metadata_count, metadata.count());
            try std.testing.expect(!history.anyActive(&f.tables));
            try std.testing.expect(selection.contains(session.get(&f.tables), session.selections(&f.tables), f.atoms.intern("layer"), 1));
        }
        // Rejection must preserve the pre-existing redo branch too.
        try history.redo(&f.tables, &f.atoms, doc);
    }
}
