const std = @import("std");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const names = @import("names.zig");
const workspace = @import("workspace.zig");
const Table = mesha.Table;
const figure = mesha.figure;
const session = @import("session.zig");
const filmstrip = @import("filmstrip.zig");
pub const OutlinerNode = struct {
    folder: bool = false,
    collapsed: bool = false,
    kind: Atom,
    id: u32,
    name: Atom,
    depth: u32 = 0,
    visible: bool = true,
    locked: bool = false,
    binding: Atom = session.none,
};
/// Outliner display category. Art keeps the folder/layer/shape hierarchy and
/// bones their parent chain; clips and poses are flat lists.
pub const Category = enum { art, bones, clips, poses };

pub fn categoryAtom(category: Category) Atom {
    return Atom.from(@tagName(category));
}

pub fn categoryOfAtom(value: Atom) ?Category {
    for (std.enums.values(Category)) |category| if (categoryAtom(category) == value) return category;
    return null;
}

fn categoryOfKind(kind: Atom) ?Category {
    if (kind == names.layer or kind == names.shape) return .art;
    if (kind == names.bone) return .bones;
    if (kind == names.clip) return .clips;
    if (kind == names.pose) return .poses;
    return null;
}

pub fn outlinerCategory(outliner_tab: session.OutlinerTabView) Category {
    return categoryOfAtom(outliner_tab.category.*) orelse .art;
}

pub fn setOutlinerTab(outliner_tab: session.OutlinerTabView, category: Category) void {
    outliner_tab.category.* = categoryAtom(category);
}

fn frameAllocator(tables: *Table.Registry) !std.mem.Allocator {
    return (try tables.memory.frameScratchAllocator()).allocator;
}
// Point selections carry the ID of their owning shape.
pub fn artworkItems(tables: *Table.Registry) ![]session.api.Selection {
    var selected_items: std.ArrayListUnmanaged(session.api.Selection) = .empty;
    const editor = session.get(tables);
    var rows = session.selections(tables).read();
    while (rows.next()) |row| {
        if (row.view.doc.* == editor.doc.* and (row.view.kind.* == names.shape or row.view.kind.* == names.point)) {
            const frame_allocator = try frameAllocator(tables);
            try selected_items.append(frame_allocator, .{
                .kind = row.view.kind.*,
                .id = row.view.id.*,
                .sub = row.view.sub.*,
            });
        }
    }
    return selected_items.toOwnedSlice(try frameAllocator(tables));
}
pub fn selectedShapeIds(tables: *Table.Registry) ![]u32 {
    const items = try artworkItems(tables);
    var selected_items: std.ArrayListUnmanaged(u32) = .empty;
    for (items) |item| {
        if (std.mem.indexOfScalar(u32, selected_items.items, item.id) == null) try selected_items.append(try frameAllocator(tables), item.id);
    }
    return selected_items.toOwnedSlice(try frameAllocator(tables));
}
pub fn contains(editor: session.View, selected: session.SelectionRows, kind: Atom, id: u32) bool {
    const doc = editor.doc.*;
    var query = selected.query();
    while (query.next()) |row| if (row.view.doc.* == doc and row.view.kind.* == kind and row.view.id.* == id) return true;
    return false;
}
pub fn clear(editor: session.View, observed: session.ObservedView, selected: session.SelectionRows) void {
    observed.selection_version.* +%= 1;
    session.removeRows(selected.table, editor.doc.*);
    editor.active_kind.* = session.none;
    editor.active_id.* = 0;
    editor.active_bone.* = 0;
}
pub fn select(tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, id: u32, add: bool, subtract: bool) void {
    const editor = session.get(tables);
    const observed = session.observed(tables);
    observed.selection_version.* +%= 1;
    if (!add and !subtract) clear(session.get(tables), session.observed(tables), session.selections(tables));
    const selection_table = session.selections(tables);
    var found: ?Table.RowHandle = null;
    var query = selection_table.query();
    while (query.next()) |row| if (row.view.doc.* == editor.doc.*) {
        if (row.view.kind.* == kind and row.view.id.* == id) found = row.handle;
        row.view.primary.* = 0;
    };
    if (subtract) {
        if (found) |row| selection_table.free(row);
        editor.active_kind.* = session.none;
        editor.active_id.* = 0;
        editor.active_bone.* = 0;
        query = selection_table.query();
        while (query.next()) |row| if (row.view.doc.* == editor.doc.*) {
            row.view.primary.* = 1;
            editor.active_kind.* = row.view.kind.*;
            editor.active_id.* = row.view.id.*;
            break;
        };
    } else if (id != 0) {
        const row = found orelse (selection_table.alloc() catch return);
        session.writeRow(session.Selection, selection_table.table, row, .{ .doc = editor.doc.*, .kind = kind, .id = id, .primary = 1 });
        editor.active_kind.* = kind;
        editor.active_id.* = id;
    }
    session.observed(tables).outliner_reveal.* = 1;
    // Primary selection is the boundary where the outliner reveals its tab;
    // adding to or subtracting from a multi-selection keeps the current view.
    if (!add and !subtract and id != 0) {
        if (categoryOfKind(kind)) |category| setOutlinerTab(session.outlinerTab(tables), category);
    }
    syncOperationalSelection(tables, atoms, .use_selection);
}
const LayerTarget = enum { use_selection, preserve_target };
fn syncOperationalSelection(tables: *Table.Registry, atoms: *Atom.Registry, layer_target: LayerTarget) void {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    syncOperationalSelectionWithReads(&reads, layer_target);
}

fn syncOperationalSelectionWithReads(reads: *session.ReadContext, layer_target: LayerTarget) void {
    const tables = reads.tables;
    const editor = session.get(tables);
    editor.active_bone.* = if (editor.active_kind.* == names.bone) editor.active_id.* else 0;
    if (editor.active_kind.* == names.shape) {
        const definition = reads.definition(editor.doc.*) catch return;
        if (session.findById(session.api.read.Shape, definition.shapes, editor.active_id.*)) |shape| {
            if (layer_target == .use_selection) editor.active_layer.* = shape.layer;
            editor.active_bone.* = shape.bone;
        }
    } else if (editor.active_kind.* == names.layer and layer_target == .use_selection) {
        editor.active_layer.* = editor.active_id.*;
    }
}
/// Category-filtered outliner rows: the one projection shared by rendering,
/// wheel scrolling, pointer picking and outliner-focused keyboard traversal.
pub fn categoryNodes(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, category: Category) ![]OutlinerNode {
    const nodes = try outlinerNodes(allocator, tables, atoms);
    defer allocator.free(nodes);
    var filtered: std.ArrayListUnmanaged(OutlinerNode) = .empty;
    errdefer filtered.deinit(allocator);
    for (nodes) |node| {
        if (categoryOfKind(node.kind) != category) continue;
        try filtered.append(allocator, node);
    }
    return filtered.toOwnedSlice(allocator);
}

const unknown_depth = std.math.maxInt(u32);

/// Ancestors counted once each, so a deep hierarchy stays linear. A parent absent from the
/// outline still counts as one level.
fn outlineDepth(items: []const session.api.OutlinerItem, rows_by_object: *const std.AutoHashMap(session.api.ObjectId, u32), depths: []u32, start: u32) u32 {
    var unresolved: u32 = 0;
    var known = start;
    const known_depth: u32 = while (depths[known] == unknown_depth) {
        const parent = items[known].parent orelse break 0;
        const parent_row = rows_by_object.get(parent) orelse break 1;
        unresolved += 1;
        known = parent_row;
    } else depths[known];
    depths[known] = known_depth;
    var row = start;
    var remaining = unresolved;
    while (remaining > 0) : (remaining -= 1) {
        depths[row] = known_depth + remaining;
        row = rows_by_object.get(items[row].parent.?).?;
    }
    return depths[start];
}

pub fn outlinerNodes(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry) ![]OutlinerNode {
    const doc = session.get(tables).doc.*;
    const definition = try session.readDefinition(tables, atoms, doc);
    const outline = try figure.projectOutliner(definition, allocator);
    defer allocator.free(outline.items);
    var result: std.ArrayListUnmanaged(OutlinerNode) = .empty;
    errdefer result.deinit(allocator);
    const depths = try allocator.alloc(u32, outline.items.len);
    defer allocator.free(depths);
    @memset(depths, unknown_depth);
    var rows_by_object = std.AutoHashMap(session.api.ObjectId, u32).init(allocator);
    defer rows_by_object.deinit();
    for (outline.items, 0..) |entry, row| {
        const slot = try rows_by_object.getOrPut(entry.object);
        if (!slot.found_existing) slot.value_ptr.* = @intCast(row);
    }
    for (outline.items, 0..) |entry, row| {
        // IK controls remain canvas/pose UX, not selectable outliner rows.
        if (entry.object.kind == .ik) continue;
        // Clips and poses are flat lists; only art and bone rows carry hierarchy.
        const depth = outlineDepth(outline.items, &rows_by_object, depths, @intCast(row));
        const layer = if (entry.object.kind == .layer) session.findById(session.api.read.Layer, definition.layers, entry.object.id) else null;
        const shape = if (entry.object.kind == .shape) session.findById(session.api.read.Shape, definition.shapes, entry.object.id) else null;
        // In Animate, the working pose may show or hide the row itself; its folders still hide it.
        var visible = entry.visible;
        if (layer) |authored| {
            const posed = filmstrip.posedRow(session.get(tables), .layer, definition, authored);
            if (posed.visible != authored.visible) visible = posed.visible != 0;
        }
        if (shape) |authored| {
            const posed = filmstrip.posedRow(session.get(tables), .shape, definition, authored);
            if (posed.visible != authored.visible) visible = posed.visible != 0;
        }
        try result.append(
            allocator,
            .{
                .kind = Atom.from(@tagName(entry.object.kind)),
                .id = entry.object.id,
                .name = entry.name,
                .depth = depth,
                .visible = visible,
                .locked = entry.locked,
                .folder = if (layer) |folder_layer| folder_layer.kind == names.folder else false,
                .binding = if (shape) |bound_shape| bound_shape.binding else session.none,
            },
        );
    }
    var visible_count: usize = 0;
    var hidden_depth: ?u32 = null;
    for (result.items) |entry| {
        if (hidden_depth) |collapsed_depth| {
            if (entry.depth > collapsed_depth) continue;
            hidden_depth = null;
        }
        var node = entry;
        if (node.folder and collapsed(session.collapsedFolders(tables), session.get(tables), node.id)) {
            node.collapsed = true;
            hidden_depth = node.depth;
        }
        result.items[visible_count] = node;
        visible_count += 1;
    }
    result.items.len = visible_count;
    return result.toOwnedSlice(allocator);
}
pub const TraversalDirection = enum { forward, backward };
pub const TraversalScope = enum { outliner_category, canvas_mode };

pub fn selectRelative(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, direction: TraversalDirection, scope: TraversalScope) !void {
    const editor = session.get(tables);
    // Outliner traversal stays category-scoped; canvas traversal follows the tab.
    const outliner_nodes = if (scope == .outliner_category)
        try categoryNodes(allocator, tables, atoms, outlinerCategory(session.outlinerTab(tables)))
    else
        try outlinerNodes(allocator, tables, atoms);
    defer allocator.free(outliner_nodes);
    var eligible_nodes: std.ArrayListUnmanaged(OutlinerNode) = .empty;
    defer eligible_nodes.deinit(allocator);
    const bone_kind = names.bone;
    const shape_kind = names.shape;
    for (outliner_nodes) |node| {
        if (scope == .outliner_category) {
            try eligible_nodes.append(allocator, node);
            continue;
        }
        // The canvas steps through what its tab edits: artwork in Design, bones in Rig and Animate.
        const kind = if (editor.mode.* == names.design) shape_kind else bone_kind;
        if (node.kind != kind) continue;
        try eligible_nodes.append(allocator, node);
    }
    if (eligible_nodes.items.len == 0) return;
    var current_index: ?usize = null;
    for (eligible_nodes.items, 0..) |node, index| if (node.kind == editor.active_kind.* and node.id == editor.active_id.*) {
        current_index = index;
        break;
    };
    const index = if (current_index) |selected_index|
        if (direction == .forward)
            (selected_index + 1) % eligible_nodes.items.len
        else
            (selected_index + eligible_nodes.items.len - 1) % eligible_nodes.items.len
    else if (direction == .forward)
        @as(usize, 0)
    else
        eligible_nodes.items.len - 1;
    const next = eligible_nodes.items[index];
    select(tables, atoms, next.kind, next.id, false, false);
}
pub fn prune(tables: *Table.Registry, atoms: *Atom.Registry) void {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    pruneWithReads(&reads);
}

/// Whether `pruneWithReads` would remove a row: a selected item or a collapsed folder the
/// document no longer has. Reads only.
pub fn stale(reads: *session.ReadContext) bool {
    const tables = reads.tables;
    var query = session.selections(tables).query();
    while (query.next()) |row| {
        if (!selectedStillExists(reads, row.view)) return true;
    }
    const collapse_table = session.collapsedFolders(tables);
    var collapse_query = collapse_table.query();
    while (collapse_query.next()) |row| {
        if (!collapsedStillFolder(reads, row.view)) return true;
    }
    return false;
}

/// A row of a document whose content the host has not published for the editor, as another
/// loaded document or the open one before its watch is answered, stays while the host still
/// holds the document.
fn selectedStillExists(reads: *session.ReadContext, row: session.Row(session.Selection)) bool {
    const doc = row.doc.*;
    const exists = session.objectExists(reads.tables, reads.atoms, doc, row.kind.*, row.id.*);
    return exists orelse documentHeld(reads, doc);
}

fn documentHeld(reads: *session.ReadContext, doc: Atom) bool {
    return session.definitionInfo(reads.tables, reads.atoms, doc) != null;
}

fn collapsedStillFolder(reads: *session.ReadContext, row: session.Row(session.Selection)) bool {
    const definition = reads.definition(row.doc.*) catch return documentHeld(reads, row.doc.*);
    const layer = session.findById(session.api.read.Layer, definition.layers, row.id.*) orelse return false;
    return layer.kind == names.folder;
}

pub fn pruneWithReads(reads: *session.ReadContext) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const editor = session.get(tables);
    if (editor.outliner_drag.* != 0) {
        // As a selected row: dropped once its layer is gone, or its document is.
        const dragged = session.objectExists(tables, atoms, editor.doc.*, names.layer, editor.outliner_drag.*);
        const exists = dragged orelse documentHeld(reads, editor.doc.*);
        if (!exists) editor.outliner_drag.* = 0;
    }
    const selection_table = session.selections(tables);
    var query = selection_table.query();
    while (query.next()) |row| {
        if (!selectedStillExists(reads, row.view)) {
            if (row.view.doc.* == editor.doc.*) {
                const observed = session.observed(tables);
                observed.selection_version.* +%= 1;
            }
            selection_table.free(row.handle);
        }
    }
    const collapse_table = session.collapsedFolders(tables);
    var collapse_query = collapse_table.query();
    while (collapse_query.next()) |row| {
        if (!collapsedStillFolder(reads, row.view)) collapse_table.free(row.handle);
    }
    var primary_query = selection_table.read();
    while (primary_query.next()) |row| if (row.view.doc.* == editor.doc.* and row.view.primary.* != 0) {
        editor.active_kind.* = row.view.kind.*;
        editor.active_id.* = row.view.id.*;
        editor.active_bone.* = if (row.view.kind.* == names.bone) row.view.id.* else 0;
        break;
    };
    // Explicit selection chooses a creation layer; reconciliation must retain a
    // later user choice from Tool defaults, even while that artwork stays selected.
    syncOperationalSelectionWithReads(reads, .preserve_target);
    if (editor.active_id.* != 0 and !contains(session.get(tables), session.selections(tables), editor.active_kind.*, editor.active_id.*)) {
        editor.active_id.* = 0;
        editor.active_bone.* = 0;
        editor.active_kind.* = session.none;
    }
}

pub fn collapsed(collapse_table: session.CollapsedRows, editor: session.View, id: u32) bool {
    return session.findRow(collapse_table.table, editor.doc.*, id) != null;
}
pub fn toggleCollapse(collapse_table: session.CollapsedRows, editor: session.View, id: u32) !void {
    const doc = editor.doc.*;
    if (session.findRow(collapse_table.table, doc, id)) |row_handle| collapse_table.free(row_handle) else {
        _ = try collapse_table.insert(session.Selection{ .doc = doc, .id = id });
    }
}
