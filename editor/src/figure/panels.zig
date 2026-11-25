const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panel_frame = @import("../panel_frame.zig");
const roop = mesha.roop;
const session = @import("session.zig");
const ui_button = @import("../ui/button.zig");
const marks = ui.marks;
const vector_field = ui.vector_field;
const drawing = @import("drawing.zig");
const pose = @import("pose.zig");
const gesture = @import("gesture.zig");
const weight = @import("weight.zig");
const editor_module = @import("../editor.zig");
const selection = @import("selection.zig");
const prompts = @import("prompts.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");
const filmstrip = @import("filmstrip.zig");
const filmstrip_sequencer = @import("sequencer.zig");
const list = @import("list_navigation.zig");
const action_palette = @import("../action_palette.zig");
const workspace = @import("workspace.zig");
const chrome = @import("chrome.zig");

const Log = mesha.log.scope("figure_editor");
/// This file's profile zones, in its log scope.
const Zone = enum { ui_commit };

pub fn render(
    mem: *memory.Memory,
    tables: *Table.Registry,
    atoms: *Atom.Registry,
    id: Atom,
    frame: plugin.Viewport,
    render_context: *roop.Context,
    hits: *Table,
    depth: u32,
) void {
    panel_frame.drawPlainHeader(mem, tables, atoms, id, frame, render_context);
    const viewport = panel_frame.beginContent(tables, atoms, id, frame, render_context) orelse return;
    defer panel_frame.endContent(render_context);
    const frame_allocator = mem.frameScratchAllocator() catch return;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms, .allocator = frame_allocator.allocator };
    defer reads.deinit();
    const editor = session.get(tables);
    var tree = ui.Tree.init(frame_allocator, atoms, 8192) catch return;
    if (tree.beginRect("figure.panel.root", .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .fill },
        .padding = 4,
        .gap = 4,
        .bg = style.col.sidebar,
        .clip_content = true,
    })) {
        defer tree.endRect();
        const surface: workspace.ScrollSurface = if (id == names.figure_outliner) .outliner else .properties;
        tree.onScroll(workspace.to(&tree, .from(workspace.Msg.figure_scroll), surface));
        if (id == names.figure_outliner) {
            renderOutliner(frame_allocator.allocator, &tree, tables, atoms, viewport);
        } else if (filmstrip.enabled(session.get(tables))) {
            renderAnimation(&tree, &reads);
        } else if (editor.tool.* == names.weight) {
            weight_controls: {
                const settings = weight.config(tables);
                const weight_frame_allocator = (tables.memory.frameScratchAllocator() catch break :weight_controls).allocator;
                if (!tree.beginRect("weight.controls", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .gap = 4, .clip_content = true })) break :weight_controls;
                defer tree.endRect();
                const feedback = weight.brushFeedback(tables, atoms) catch weight.BrushFeedback{
                    .title = "Weight targets are unavailable.",
                    .detail = "Wait for the figure to finish loading.",
                };
                tree.text("weight.eligibility.title", feedback.title, .{ .font = style.ui_font, .color = style.col.text });
                tree.text("weight.eligibility.detail", feedback.detail, .{ .font = style.ui_font, .color = style.col.text_dim });
                switch (feedback.action) {
                    .none => {},
                    .make_skinned => actionButton(&tree, @tagName(weight.Msg.figure_weight_make_skinned), "Make skinned"),
                    // The brush bone row below always owns the lock toggle.
                    .unlock_bone => {},
                }
                if (tree.beginRect("weight.legend", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = 18 } }, .gap = 0, .cross_align = .center })) {
                    defer tree.endRect();
                    tree.text("weight.legend.none", "No influence ", .{ .font = style.ui_font, .color = style.col.text_dim });
                    for (0..5) |step| {
                        const step_index: f32 = @floatFromInt(step);
                        const swatch = ui.ElementId{ .atom = names.@"weight.legend.swatch", .extra = @intCast(step) };
                        if (tree.beginRect(swatch, .{ .size = .{ .w = .{ .fixed = 18 }, .h = .{ .fixed = 10 } }, .bg = weight.heatColor(step_index / 4, 255) })) tree.endRect();
                    }
                    tree.text("weight.legend.full", " Full", .{ .font = style.ui_font, .color = style.col.text_dim });
                }
                const bone_locked = weight.locked(weight.boneStates(tables), settings.bone.*);
                if (settings.bone.* != 0) actionButton(&tree, @tagName(weight.Msg.figure_weight_lock), if (bone_locked) "Unlock bone" else "Lock bone");
                groupDivider(&tree, "weight.divider.anchor");
                const inspected = weight.inspectedAnchor(&reads, weight_frame_allocator) catch null;
                if (inspected) |influences| {
                    const anchor_title = std.fmt.allocPrint(weight_frame_allocator, "Anchor {d} weights", .{settings.point_index.*}) catch "Anchor weights";
                    tree.text("weight.anchor.title", anchor_title, .{ .font = style.ui_font, .color = style.col.text });
                    for (influences, 0..) |influence, index| {
                        const row_id = ui.ElementId{ .atom = names.@"weight.anchor.row", .extra = @intCast(index) };
                        const row_text = std.fmt.allocPrint(weight_frame_allocator, "{s}: {d:.2}", .{ influence.name, influence.weight }) catch "";
                        tree.text(row_id, row_text, .{ .font = style.ui_font, .color = style.col.accent_bright });
                    }
                    actionButton(&tree, @tagName(weight.Msg.figure_weight_numeric), "Edit anchor weights");
                } else {
                    tree.text("weight.anchor.help", "Ctrl-click an anchor to see its weights.", .{ .font = style.ui_font, .color = style.col.text_dim });
                }
                actionButton(&tree, @tagName(weight.Msg.figure_subdivide_for_deform), "Add anchors along path");
                const test_on = settings.test_pose.* != 0;
                actionToggleRow(&tree, tables, @tagName(weight.Msg.figure_test_pose), "Test pose", test_on);
                if (test_on and settings.bone.* != 0) actionButton(&tree, @tagName(weight.Msg.figure_test_rotation), "Test angle");
                if (settings.test_pose.* != 0) tree.text("weight.test.help", "Alt-drag a bone to bend it while you paint.", .{ .font = style.ui_font, .color = style.col.text_dim });
            }
        } else {
            const target = prompts.inspectorTarget(session.get(tables), drawing.config(tables));
            // Rig shows how a shape is bound; its look is Design's to edit.
            const binding_shape = editor.mode.* == names.rig and target.kind == names.shape;
            if (binding_shape) {
                if (tree.beginRect("figure.binding.row", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = style.metric.field_height } }, .gap = 6, .clip_content = true })) {
                    defer tree.endRect();
                    tree.text("figure.binding.label", "Binding", .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .{ .fixed = action_row_label_width } } });
                    const binding_text = prompts.valueTextWithReads(frame_allocator.allocator, &reads, target.kind, target.id, "binding") catch "?";
                    tree.text("figure.binding.value", binding_text, .{ .font = style.ui_font, .color = style.col.text });
                }
                if (ui_button.beginRow(&tree, "figure.binding.bind")) {
                    defer tree.endRect();
                    actionButton(&tree, @tagName(weight.Msg.figure_bind_rigid), "Bind rigid");
                    actionButton(&tree, @tagName(weight.Msg.figure_bind_skinned), "Auto skin");
                }
                if (ui_button.beginRow(&tree, "figure.binding.unbind")) {
                    defer tree.endRect();
                    actionButton(&tree, @tagName(weight.Msg.figure_unbind), "Unbind: rest");
                    actionButton(&tree, @tagName(weight.Msg.figure_unbind_current), "Unbind: pose 0");
                }
                actionButton(&tree, @tagName(weight.Msg.figure_mode_weight), "Weight brush");
            }
            const fields = prompts.inspectorFields(target.kind);
            if (binding_shape) {
                // The binding controls above are all Rig says of a shape.
            } else if ((target.id == 0 and target.kind != prompts.defaults_kind) or fields.len == 0) {
                const empty_hint = if (editor.mode.* == names.rig) "Select a bone, or artwork to bind." else "Select a shape or layer.";
                tree.text("figure.inspector.empty", empty_hint, .{ .font = style.ui_font, .color = style.col.text });
            } else {
                // Room above the rows: the panel's padding.
                const reserved_height: f32 = 12;
                const active = @min(editor.inspector_field.*, fields.len - 1);
                const shown = shownFieldRows(fields, active, viewport.height - reserved_height);
                for (fields[shown.start..shown.end], shown.start..) |field, index| {
                    if (field.section.len != 0) sectionHeading(&tree, .{ "figure.inspector.section", index }, field.section);
                    inspectorRow(&tree, &reads, target, field, index, @min(action_row_label_width, viewport.width * 0.4), .inspector);
                }
            }
        }
    }
    const zone = Log.zone(Zone.ui_commit);
    defer zone.end();
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = depth,
    }, render_context, hits);
}

/// The gap between the inspector's rows, and what a field's row and a section's heading each
/// take of the panel's height with it.
const inspector_row_gap: f32 = 4;
const field_row_pitch: f32 = style.metric.field_height + inspector_row_gap;
const section_heading_height: f32 = 30;
const section_heading_pitch: f32 = section_heading_height + inspector_row_gap;

fn fieldRowsHeight(fields: []const prompts.InspectorField) f32 {
    var height: f32 = 0;
    for (fields) |field| {
        height += field_row_pitch;
        if (field.section.len != 0) height += section_heading_pitch;
    }
    return height;
}

const FieldRows = struct { start: usize, end: usize };

/// The rows that fit in `available` height, section headings counted: from the first field
/// unless the active one would then be cut off, in which case as few as that takes are
/// dropped from the top. The active row always shows.
fn shownFieldRows(fields: []const prompts.InspectorField, active: usize, available: f32) FieldRows {
    var start: usize = 0;
    while (start < active and fieldRowsHeight(fields[start .. active + 1]) > available) start += 1;
    var end = active + 1;
    while (end < fields.len and fieldRowsHeight(fields[start .. end + 1]) <= available) end += 1;
    return .{ .start = start, .end = end };
}

/// The prompt is an inline field for exactly this row while it edits `part` of this target's
/// field.
fn editingField(tables: *Table.Registry, atoms: *Atom.Registry, target_kind: Atom, target_id: u32, field_name: []const u8, part: session.ValuePart) bool {
    const completions = action_palette.currentCompletions(tables, atoms) orelse return false;
    if (completions.presentation != .inline_field) return false;
    const editor = session.get(tables);
    return editor.prompt_kind.* == names.field and editor.prompt_target_kind.* == target_kind and
        editor.prompt_id.* == target_id and editor.prompt_field.* == Atom.from(field_name) and
        editor.prompt_part.* == @intFromEnum(part);
}

/// Whether the pointer is over the row a value sits in, which lights the value.
const RowPointer = enum { away, over };

fn rowPointer(tables: *Table.Registry, row: ui.ElementId) RowPointer {
    const hovered = editor_state.hoveredElementId(tables) orelse return .away;
    return if (hovered.atom == row.atom and hovered.extra == row.extra) .over else .away;
}

/// A value that opens for editing when its row is pressed. The row keeps the route, so a drag
/// that starts on the label still scrubs.
pub fn fieldValue(tree: *ui.Tree, id: anytype, text: []const u8, color: ?session.Color, pointer: RowPointer) void {
    const element = tree.toElementId(id);
    var frame = style.fieldFrame(.idle, .{ .w = .fill, .h = .fill });
    if (pointer == .over) frame.bg = style.col.field_hover;
    if (!tree.beginRect(element, frame)) return;
    defer tree.endRect();
    if (color) |swatch| {
        const swatch_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 1 };
        @import("color_picker.zig").swatch(tree, swatch_id, swatch, .{ .w = .{ .fixed = 18 }, .h = .{ .fixed = 16 } });
    }
    const text_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 2 };
    tree.text(text_id, text, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill } });
}

/// An on/off value flips on press rather than opening for typing, so it looks like a button.
pub fn toggleValue(tree: *ui.Tree, id: anytype, on: bool, pointer: RowPointer) void {
    const element = tree.toElementId(id);
    const off_fill = if (pointer == .over) style.col.button_hover else style.col.button;
    if (!tree.beginRect(element, .{
        .axis = .horizontal,
        .cross_align = .center,
        .main_align = .center,
        .size = .{ .w = .fill, .h = .fill },
        .bg = if (on) style.col.accent_deep else off_fill,
        .corner_radius = style.metric.button_radius,
        .clip_content = true,
    })) return;
    defer tree.endRect();
    const text_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 1 };
    tree.text(text_id, if (on) "On" else "Off", .{ .font = style.ui_font, .color = style.col.text });
}

/// The action palette owns this text and caret; a panel only shows them in place: the
/// request's text editor's drawing, once that holds the text.
pub fn renderInlineField(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, id: anytype) void {
    const element = tree.toElementId(id);
    if (!tree.beginRect(element, style.fieldFrame(.active, .{ .w = .fill, .h = .fill }))) return;
    defer tree.endRect();
    inlineFieldText(tree, tables, atoms, element);
}

/// The open prompt's text and caret, inside the field frame `element` already begun.
fn inlineFieldText(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, element: ui.ElementId) void {
    const prompt_state = action_palette.prompt(tables, atoms);
    if (action_palette.editorDrawable(tables, atoms)) |editor| {
        const drawable = tree.frame_allocator.allocator.create(@TypeOf(editor)) catch return;
        drawable.* = editor;
        tree.custom(ui.ElementId{ .atom = element.atom, .extra = element.extra +% 3 }, drawable, .{ .size = .{ .w = .fill, .h = .fill } });
        return;
    }
    const query = action_palette.promptText(tables, atoms);
    const text_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 1 };
    const cursor_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 2 };
    if (prompt_state.text_selected.* != 0) {
        if (tree.beginRect(cursor_id, .{ .axis = .horizontal, .cross_align = .center, .bg = style.col.accent_deep })) {
            defer tree.endRect();
            tree.text(text_id, query, .{ .font = style.ui_font, .color = style.col.text });
        }
        return;
    }
    tree.text(text_id, if (query.len != 0) query else " ", .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill } });
    tree.cursor(cursor_id, prompt_state.cursor.*, .{ .bg = style.col.accent_bright });
}

/// Settles where the outliner's list starts, for a panel `width` by `height`: the row the
/// selection, a resize or a wrap of the tab rows reveals, or the top of the list after a tab
/// was clicked. The figure view's run calls it after every system that changes the
/// selection; `renderOutliner` then draws from `outliner_scroll` and writes nothing.
pub fn settleOutlinerScroll(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, width: f32, height: f32) void {
    const editor = session.get(tables);
    const tab_state = session.outlinerTab(tables);
    const category = selection.outlinerCategory(tab_state);
    const first_row_y = list.top(width, category == .art);
    // An explicit tab click consumes its one-shot marker here: this frame keeps the
    // handler's top-of-list reset instead of re-revealing the selected row through the
    // previous category's recorded index or the folder-tools offset change.
    const browsed = tab_state.browsed.* != 0;
    if (browsed) tab_state.browsed.* = 0;
    // Echo the offset so a width-only resize that rewraps the tab rows still reveals the
    // selected row, which the unchanged height would hide.
    const list_top_changed = tab_state.list_top.* != first_row_y;
    if (list_top_changed) tab_state.list_top.* = first_row_y;
    if (session.definitionInfo(tables, atoms, editor.doc.*) == null) return;
    const nodes = selection.categoryNodes(allocator, tables, atoms, category) catch return;
    const observed = session.observed(tables);
    const selected = selectedNode(nodes, editor);
    const selected_index: u32 = if (selected) |index| @intCast(index) else std.math.maxInt(u32);
    // Selection events (outliner_reveal) and real resizes still reveal; a browse only
    // suppresses the row-index and offset comparisons.
    const row_reveal = !browsed and (list_top_changed or observed.outliner_selected_index.* != selected_index);
    const reveal = observed.outliner_reveal.* != 0 or row_reveal or observed.outliner_height.* != height;
    const start: u32 = @intCast(list.scrollStart(nodes, editor.outliner_scroll.*, selected, height, reveal, first_row_y));
    if (observed.outliner_reveal.* != 0) observed.outliner_reveal.* = 0;
    if (observed.outliner_height.* != height) observed.outliner_height.* = height;
    if (observed.outliner_selected_index.* != selected_index) observed.outliner_selected_index.* = selected_index;
    if (editor.outliner_scroll.* != start) editor.outliner_scroll.* = start;
}

/// The index in `nodes` of the editor's active item, if it is listed.
fn selectedNode(nodes: anytype, editor: session.View) ?usize {
    for (nodes, 0..) |node, index| {
        if (node.kind == editor.active_kind.* and node.id == editor.active_id.*) return index;
    }
    return null;
}

/// Outliner panel: category tabs, the filtered list, and per-category context.
/// Geometry mirrors workspace.outlinerPointer; keep list.top in sync with it.
pub fn renderOutliner(allocator: std.mem.Allocator, tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport) void {
    const editor = session.get(tables);
    const category = selection.outlinerCategory(session.outlinerTab(tables));
    const folder_tools = category == .art;
    const first_row_y = list.top(viewport.width, folder_tools);
    renderOutlinerTabs(tree, viewport.width, category);
    if (folder_tools) {
        if (ui_button.beginRow(tree, "figure.folder.tools")) {
            defer tree.endRect();
            const folder_buttons = [_]struct { label: []const u8, action: []const u8 }{
                .{ .label = "Layer", .action = @tagName(drawing.Msg.figure_layer_add) },
                .{ .label = "Folder", .action = @tagName(workspace.Msg.figure_folder_add) },
                .{ .label = "Group", .action = @tagName(workspace.Msg.figure_folder_group) },
                .{ .label = "Ungroup", .action = @tagName(workspace.Msg.figure_folder_ungroup) },
            };
            for (folder_buttons) |folder_button| {
                const action = Atom.from(folder_button.action);
                const click = workspace.to(tree, action, {});
                const creates_item = std.mem.eql(u8, folder_button.action, @tagName(workspace.Msg.figure_folder_add)) or std.mem.eql(u8, folder_button.action, @tagName(drawing.Msg.figure_layer_add));
                ui_button.render(tree, folder_button.action, click, .{
                    .label = folder_button.label,
                    .icon = if (creates_item) .add else null,
                    .variant = .compact,
                });
            }
        }
    }
    if (session.definitionInfo(tables, atoms, editor.doc.*) == null) {
        tree.text("figure.outliner.empty", "New or Open a figure", .{ .font = style.ui_font, .color = style.col.text_dim });
        tree.text("figure.outliner.empty.hint", "to begin.", .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    }
    const nodes = selection.categoryNodes(allocator, tables, atoms, category) catch return;
    // Where `settleOutlinerScroll` left the list.
    const start: usize = @min(editor.outliner_scroll.*, nodes.len);
    const visible_end = list.visibleEnd(nodes, start, viewport.height, first_row_y);
    // Below the wrap width the tab labels already state the category, so rows
    // drop only the redundant kind/binding text and shrink controls; the
    // visibility, lock, disclosure and multi-select cells all remain operable.
    // Fills the panel so a press below the last row still reaches the list.
    const list_press = workspace.to(tree, .from(workspace.Msg.figure_outliner_down), {});
    const hovered = editor_state.hoveredElementId(tables);
    if (tree.beginRect("figure.outliner.rows", .{ .size = .{ .w = .fill, .h = .fill } })) {
        tree.onClick(list_press, .all);
        defer tree.endRect();
        for (nodes[start..visible_end], start..) |node, i| {
            const primary = node.kind == editor.active_kind.* and node.id == editor.active_id.*;
            // While the weight brush is in hand, the bone it paints is the one chosen here.
            const brush_bone = editor.tool.* == names.weight and node.kind == names.bone and node.id == weight.config(tables).bone.*;
            const selected_row = primary or brush_bone or selection.contains(session.get(tables), session.selections(tables), node.kind, node.id) or (node.kind == names.layer and node.id == editor.outliner_drag.*);
            const is_layer = node.kind == names.layer;
            // The row lights up under the pointer wherever on it the pointer is: input reports
            // the innermost part, so the row asks whether that is one of its own.
            const row_parts = [_]ui.ElementId{
                tree.toElementId(.{ "figure.outliner.row", i }),
                tree.toElementId(.{ "figure.folder.disclosure", i }),
                tree.toElementId(.{ "figure.outliner.name.rect", i }),
                tree.toElementId(.{ "figure.outliner.eye", i }),
                tree.toElementId(.{ "figure.outliner.lock", i }),
            };
            const row_hovered = containsElement(&row_parts, hovered);
            const row_fill: ?ui.Color = if (selected_row) style.col.accent_deep else if (row_hovered) style.col.card_hover else null;
            if (tree.beginRect(.{ "figure.outliner.row", i }, .{
                .axis = .horizontal,
                .cross_align = .center,
                .size = .{ .w = .fill, .h = .{ .fixed = list.row_height } },
                .gap = 2,
                .bg = row_fill,
                .clip_content = true,
            })) {
                defer tree.endRect();
                tree.onClick(workspace.to(tree, .from(workspace.Msg.figure_select_item), session.ItemEvent{ .kind = node.kind, .id = node.id }), .left);
                tree.trackHover("");
                const indent = 4 + @as(f32, @floatFromInt(node.depth)) * 14;
                tree.rect(.{ "figure.outliner.indent", i }, .{ .size = .{ .w = .{ .fixed = indent }, .h = .fill } });
                if (node.folder) {
                    if (tree.beginRect(.{ "figure.folder.disclosure", i }, .{ .size = .{ .w = .{ .fixed = list.capture_left - indent }, .h = .fill }, .bg_hover = row_control_hover, .corner_radius = style.metric.button_radius })) {
                        defer tree.endRect();
                        tree.onClick(workspace.to(tree, .from(workspace.Msg.figure_folder_collapse), session.ItemEvent{ .kind = node.kind, .id = node.id }), .left);
                        tree.trackHover(if (node.collapsed) "Expand this folder" else "Collapse this folder");
                        const chevron = tree.frame_allocator.allocator.create(marks.Chevron) catch unreachable;
                        chevron.* = .{ .direction = if (node.collapsed) .right else .down, .color = style.col.text_dim };
                        tree.custom(.{ "figure.folder.disclosure.mark", i }, chevron, .{ .size = .{ .w = .fill, .h = .fill } });
                    }
                } else if (category == .art) {
                    const icon: ui_button.icons.Icon = if (is_layer) .layers else if (node.binding == names.skinned) .bone else if (node.binding == names.rigid) .vector_link else .vector_polygon;
                    const drawable = tree.frame_allocator.allocator.create(ui_button.SmallIcon) catch unreachable;
                    drawable.* = .{ .text = ui_button.icons.glyph(icon), .color = style.col.text_dim };
                    tree.custom(.{ "figure.outliner.kind", i }, drawable, .{ .size = .{ .w = .{ .fixed = 18 }, .h = .fill } });
                }
                // Long names clip in their own rect so they cannot paint through the controls.
                if (tree.beginRect(.{ "figure.outliner.name.rect", i }, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .fill }, .clip_content = true })) {
                    defer tree.endRect();
                    // The name is where a row can be dragged; its edges stay plain selection.
                    tree.onClick(list_press, .all);
                    tree.trackHover(switch (category) {
                        .art => "Drag to reorder. Shift-click adds to the selection.",
                        .bones => "Click to select this bone",
                        .clips => "Click to preview this clip from frame 0",
                        .poses => "Click to apply this saved pose",
                    });
                    tree.text(.{ "figure.outliner.name", i }, atoms.lookup(node.name) orelse "?", .{
                        .font = style.ui_font,
                        .color = if (!node.visible) style.col.text_dim else if (is_layer or selected_row) style.col.text else style.col.text_dim,
                    });
                }
                if (is_layer or node.kind == names.shape) {
                    const eye_icon: ui_button.icons.Icon = if (node.visible) .eye else .eye_off;
                    const eye_hint = if (node.visible) "Hide" else "Show";
                    outlinerToggle(tree, .{ "figure.outliner.eye", i }, eye_icon, node.visible, eye_hint, @tagName(workspace.Msg.figure_item_visible), node);
                }
                if (is_layer) {
                    const lock_icon: ui_button.icons.Icon = if (node.locked) .lock else .lock_open;
                    const lock_hint = if (node.locked) "Unlock this layer" else "Lock this layer against edits";
                    outlinerToggle(tree, .{ "figure.outliner.lock", i }, lock_icon, !node.locked, lock_hint, @tagName(workspace.Msg.figure_item_lock), node);
                } else if (node.kind == names.shape) {
                    tree.rect(.{ "figure.outliner.lock.space", i }, .{ .size = .{ .w = .{ .fixed = list.toggle_width }, .h = .fill } });
                }
            }
        }
    }
    if (nodes.len == 0) {
        const empty_lines = switch (category) {
            .art => [_][]const u8{ "No art layers.", "Add a layer or folder." },
            .bones => [_][]const u8{ "No bones - use the", "Bone tool in Rig mode." },
            .clips => [_][]const u8{ "No clips - create", "one in Animate mode." },
            .poses => [_][]const u8{ "No saved poses -", "save the working pose." },
        };
        tree.text("figure.outliner.empty", empty_lines[0], .{ .font = style.ui_font, .color = style.col.text_dim });
        tree.text("figure.outliner.empty.hint", empty_lines[1], .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    }
}

/// What a control inside a row adds to the row's own fill while the pointer is on it, whether
/// that fill is the hover's or the selection's.
const row_control_hover = ui.rgba(255, 255, 255, 28);

fn containsElement(elements: []const ui.ElementId, wanted: ?ui.ElementId) bool {
    const element = wanted orelse return false;
    for (elements) |candidate| {
        if (candidate.atom == element.atom and candidate.extra == element.extra) return true;
    }
    return false;
}

fn outlinerToggle(tree: *ui.Tree, id: anytype, icon: ui_button.icons.Icon, quiet: bool, hint: []const u8, comptime action: []const u8, node: selection.OutlinerNode) void {
    const element = tree.toElementId(id);
    if (!tree.beginRect(element, .{ .size = .{ .w = .{ .fixed = list.toggle_width }, .h = .fill }, .bg_hover = row_control_hover, .corner_radius = style.metric.button_radius })) return;
    defer tree.endRect();
    tree.onClick(workspace.to(tree, Atom.from(action), session.ItemEvent{ .kind = node.kind, .id = node.id }), .left);
    tree.trackHover(hint);
    const drawable = tree.frame_allocator.allocator.create(ui_button.SmallIcon) catch unreachable;
    drawable.* = .{ .text = ui_button.icons.glyph(icon), .color = if (quiet) style.col.text_dim else style.col.text };
    const icon_id = ui.ElementId{ .atom = element.atom, .extra = element.extra +% 1 };
    tree.custom(icon_id, drawable, .{ .size = .{ .w = .fill, .h = .fill } });
}

fn renderOutlinerTabs(tree: *ui.Tree, width: f32, active: selection.Category) void {
    const categories = std.enums.values(selection.Category);
    if (width >= list.tab_wrap_width) {
        renderOutlinerTabRow(tree, 0, categories[0..], active);
        return;
    }
    // Two rows keep the full labels at the dock's 160 px minimum width.
    renderOutlinerTabRow(tree, 0, categories[0..2], active);
    renderOutlinerTabRow(tree, 1, categories[2..], active);
}

fn renderOutlinerTabRow(tree: *ui.Tree, row: usize, categories: []const selection.Category, active: selection.Category) void {
    if (!ui_button.beginTabStrip(tree, .{ "figure.outliner.tabs", row }, list.tab_row_height, .equal)) return;
    defer ui_button.endTabStrip(tree, .{ "figure.outliner.tabs", row });
    for (categories) |category| {
        ui_button.render(tree, .{ "figure.outliner.tab", @intFromEnum(category) }, workspace.to(tree, .from(workspace.Msg.figure_outliner_tab), session.ItemEvent{ .kind = selection.categoryAtom(category), .id = 0 }), .{
            .label = switch (category) {
                .art => "Art layers",
                .bones => "Bones",
                .clips => "Clips",
                .poses => "Poses",
            },
            .variant = .tab,
            .size = .{ .w = .fill, .h = .fill },
            .selected = category == active,
        });
    }
}

fn outlinerKindLabel(node: selection.OutlinerNode) []const u8 {
    if (node.folder) return "Folder";
    if (node.kind == names.layer) return "Layer";
    if (node.kind == names.shape) return "Shape";
    if (node.kind == names.bone) return "Bone";
    if (node.kind == names.clip) return "Clip";
    if (node.kind == names.pose) return "Pose";
    return "Layer";
}

fn shapeBindingLabel(node: selection.OutlinerNode) []const u8 {
    if (node.binding == names.skinned) return "Skinned";
    if (node.binding == names.rigid) return "Rigid";
    return "Unbound";
}

pub const action_row_label_width: f32 = 96;

pub fn groupDivider(tree: *ui.Tree, id: []const u8) void {
    tree.rect(id, .{ .size = .{ .w = .fill, .h = .{ .fixed = 1 } }, .bg = style.col.divider });
}

fn beginActionRow(tree: *ui.Tree, comptime action: []const u8, label: []const u8) bool {
    if (!tree.beginRect("panel.row." ++ action, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = style.metric.field_height } }, .gap = 6 })) return false;
    const action_atom = Atom.from(action);
    tree.onClick(workspace.to(tree, action_atom, {}), .left);
    tree.trackHover("");
    tree.text("panel.label." ++ action, label, .{ .font = style.ui_font, .color = style.col.text_dim, .size_hint = .{ .w = .{ .fixed = action_row_label_width } } });
    return true;
}

/// A labeled value whose action opens a prompt for it.
fn actionFieldRow(tree: *ui.Tree, tables: *Table.Registry, comptime action: []const u8, label: []const u8, value: []const u8) void {
    if (!beginActionRow(tree, action, label)) return;
    defer tree.endRect();
    const pointer = rowPointer(tables, tree.toElementId("panel.row." ++ action));
    fieldValue(tree, "panel.value." ++ action, value, null, pointer);
}

/// A labeled on/off whose action flips it.
fn actionToggleRow(tree: *ui.Tree, tables: *Table.Registry, comptime action: []const u8, label: []const u8, on: bool) void {
    if (!beginActionRow(tree, action, label)) return;
    defer tree.endRect();
    const pointer = rowPointer(tables, tree.toElementId("panel.row." ++ action));
    toggleValue(tree, "panel.value." ++ action, on, pointer);
}

fn actionButton(tree: *ui.Tree, comptime action: []const u8, text: []const u8) void {
    ui_button.render(tree, action, workspace.to(tree, Atom.from(action), {}), .{ .label = text, .variant = .compact });
}

/// Keeps apart the rows of two targets a panel shows together: the pose rows of a bone under
/// the look rows of a shape. A row's element ids are its field's index past its base.
const RowIdBase = enum(usize) { inspector = 0, pose = 64 };

/// Decimals a scrubbed field shows: what a drag steps it by, and never fewer than any number.
fn shownDecimals(scrub: prompts.Scrub) u8 {
    return @max(scrub.decimals, vector_field.shown_decimals);
}

/// One of the inspector's labeled values: a click types it or steps it, a drag scrubs it.
/// `index` is the field's place in the target's whole field list, which its route names.
fn inspectorRow(tree: *ui.Tree, reads: *session.ReadContext, target: prompts.InspectorTarget, field: prompts.InspectorField, index: usize, label_width: f32, id_base: RowIdBase) void {
    if (field.isVector()) return inspectorVectorRow(tree, reads, target, field, index, label_width, id_base);
    const tables = reads.tables;
    const atoms = reads.atoms;
    const allocator = reads.readAllocator() catch return;
    const value = prompts.propertyValueWithReads(allocator, reads, target.kind, target.id, field) catch prompts.PropertyValue{ .label = field.label, .text = "?" };
    const key = @intFromEnum(id_base) + index;
    const row_id = tree.toElementId(.{ "figure.inspector.field", key });
    if (!tree.beginRect(row_id, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = style.metric.field_height } },
        .gap = 6,
        .cursor = if (field.scrub != null) .resize_ew else .arrow,
    })) return;
    defer tree.endRect();
    const action = Atom.from(workspace.Msg.figure_inspector_field);
    const item = session.ItemEvent{ .kind = target.kind, .id = target.id, .field = @intCast(index) };
    tree.onClick(workspace.to(tree, action, item), .left);
    tree.trackHover(rowHint(target, field));
    tree.text(.{ "figure.inspector.label", key }, value.label, .{
        .font = style.ui_font,
        .color = style.col.text_dim,
        .size_hint = .{ .w = .{ .fixed = label_width } },
    });
    const pointer = rowPointer(tables, row_id);
    if (editingField(tables, atoms, target.kind, target.id, field.name, .whole)) {
        renderInlineField(tree, tables, atoms, .{ "figure.inspector.edit", key });
    } else if (field.isToggle()) {
        toggleValue(tree, .{ "figure.inspector.value", key }, std.mem.eql(u8, value.text, "true"), pointer);
    } else {
        // A number that drags shows rounded, as a vector's components do; typing starts exact.
        const shown_text = shown: {
            const scrub = field.scrub orelse break :shown value.text;
            const number = std.fmt.parseFloat(f32, value.text) catch break :shown value.text;
            break :shown vector_field.formatNumber(allocator, number, shownDecimals(scrub)) catch value.text;
        };
        fieldValue(tree, .{ "figure.inspector.value", key }, shown_text, value.color, pointer);
    }
}

fn rowHint(target: prompts.InspectorTarget, field: prompts.InspectorField) []const u8 {
    if (target.kind == prompts.defaults_kind) return "Applies to new artwork only";
    if (field.scrub != null) return "Drag to change: Shift x10, Ctrl x0.1. Click to type.";
    return "Click to change";
}

/// A vector among the inspector's values: its label, then a field for each component, each
/// pressed, dragged and typed on its own.
fn inspectorVectorRow(tree: *ui.Tree, reads: *session.ReadContext, target: prompts.InspectorTarget, field: prompts.InspectorField, index: usize, label_width: f32, id_base: RowIdBase) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    const allocator = reads.readAllocator() catch return;
    const key = @intFromEnum(id_base) + index;
    if (!tree.beginRect(.{ "figure.inspector.field", key }, .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = style.metric.field_height } },
        .gap = 6,
    })) return;
    defer tree.endRect();
    tree.text(.{ "figure.inspector.label", key }, field.label, .{
        .font = style.ui_font,
        .color = style.col.text_dim,
        .size_hint = .{ .w = .{ .fixed = label_width } },
    });
    // Arrow keys and Enter still type the whole vector, as "x,y", in the row's place.
    if (editingField(tables, atoms, target.kind, target.id, field.name, .whole)) {
        renderInlineField(tree, tables, atoms, .{ "figure.inspector.edit", key });
        return;
    }
    const vector: ?session.Vec2 = prompts.vectorValueWithReads(allocator, reads, target.kind, target.id, field) catch null;
    if (!vector_field.begin(tree, .{ "figure.inspector.vector", key })) return;
    defer tree.endRect();
    const vector_style = style.vectorFieldStyle();
    const action = Atom.from(workspace.Msg.figure_inspector_field);
    const decimals = shownDecimals(field.scrub.?);
    const parts = [_]session.ValuePart{ .x, .y };
    for (parts, 0..) |part, component_index| {
        // Spaced so a component's own children (its letter, text and caret) never meet the next's.
        const component_id = tree.toElementId(.{ "figure.inspector.component", key * 16 + component_index * 8 });
        if (editingField(tables, atoms, target.kind, target.id, field.name, part)) {
            if (vector_field.beginEditing(tree, component_id, component_index, vector_style)) {
                defer tree.endRect();
                inlineFieldText(tree, tables, atoms, component_id);
            }
            continue;
        }
        const text = shown: {
            const value = vector orelse break :shown "?";
            const number = if (part == .x) value.x else value.y;
            break :shown vector_field.formatNumber(allocator, number, decimals) catch "?";
        };
        const item = session.ItemEvent{ .kind = target.kind, .id = target.id, .field = @intCast(index), .part = part };
        vector_field.component(tree, component_id, .{
            .index = component_index,
            .text = text,
            .click = workspace.to(tree, action, item),
            .tooltip = rowHint(target, field),
            .drag = .scrubs,
        }, vector_style);
    }
}

/// Whether a pose may give `field` of a shape or layer its own value.
fn animatableField(target_kind: Atom, field: prompts.InspectorField) bool {
    if (target_kind == Atom.from("shape")) return listed(plugin.figure_api.animatable_fields.shape, field.name);
    if (target_kind == Atom.from("layer")) return listed(plugin.figure_api.animatable_fields.layer, field.name);
    return false;
}

fn listed(comptime candidates: anytype, name: []const u8) bool {
    inline for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// A titled break between a panel's groups of controls: the title, then a rule to the edge.
fn sectionHeading(tree: *ui.Tree, id: anytype, title: []const u8) void {
    if (!tree.beginRect(id, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = section_heading_height } }, .padding = 2, .gap = 8 })) return;
    defer tree.endRect();
    tree.text(ui.partId(tree, id, "title"), title, .{ .font = style.ui_font, .color = style.col.accent_bright });
    tree.rect(ui.partId(tree, id, "rule"), .{ .size = .{ .w = .fill, .h = .{ .fixed = 1 } }, .bg = style.col.region_border });
}

/// A quiet line of guidance where a group has nothing to show yet.
fn panelHint(tree: *ui.Tree, id: []const u8, text: []const u8) void {
    tree.text(id, text, .{ .font = style.ui_font, .color = style.col.text_disabled, .size_hint = .{ .w = .fill } });
}

/// One of a row of buttons sharing its width: an icon and a short label, the action's own
/// description as its tooltip.
fn rowButton(tree: *ui.Tree, comptime action: []const u8, label: []const u8, icon: ?ui_button.icons.Icon, hint: []const u8) void {
    ui_button.render(tree, action, workspace.to(tree, Atom.from(action), {}), .{
        .label = label,
        .icon = icon,
        .tooltip = hint,
        .variant = if (icon != null) .icon_text else .compact,
    });
}

/// The selected clip's settings, the selected key's timing when there is a clip, then the pose
/// controls and the selected shape's or layer's look, which need no clip. The pose comes before
/// the look, so a short panel clips the look rather than the bone's controls.
fn renderAnimation(tree: *ui.Tree, reads: *session.ReadContext) void {
    const atoms = reads.atoms;
    const allocator = reads.readAllocator() catch return;
    sectionHeading(tree, "animation.clip.heading", "Clip");
    const clip = filmstrip.clipRowWithReads(reads);
    if (clip) |shown| {
        actionFieldRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_clip_rename), "Name", atoms.lookup(shown.name) orelse "?");
        const length_text = std.fmt.allocPrint(allocator, "{d} frames", .{shown.frames}) catch "?";
        actionFieldRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_clip_length), "Length", length_text);
        const fps_text = std.fmt.allocPrint(allocator, "{d}", .{shown.fps}) catch "?";
        actionFieldRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_clip_fps), "FPS", fps_text);
        actionToggleRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_clip_loop), "Loop", shown.loop != 0);
    } else {
        panelHint(tree, "animation.clip.none", "No clip yet. Add one to start keying.");
    }
    if (ui_button.beginRow(tree, "animation.clip.actions")) {
        defer tree.endRect();
        rowButton(tree, @tagName(filmstrip.Msg.figure_clip_add), "New", .plus, "Add a named clip");
        if (clip != null) {
            rowButton(tree, @tagName(filmstrip.Msg.figure_clip_duplicate), "Copy", .layers, "Deep copy this clip and its poses");
            rowButton(tree, @tagName(filmstrip.Msg.figure_clip_delete), "Delete", .delete, "Delete this clip and its keys; library poses stay");
        }
    }
    // Keys need a clip; the working pose and the look below do not.
    if (clip) |shown| {
        const selected = filmstrip.selectedKeyWithReads(reads) catch null;
        if (selected) |key| {
            const heading = std.fmt.allocPrint(allocator, "Key at frame {d}", .{key.frame}) catch "Key";
            sectionHeading(tree, "animation.key.heading", heading);
            const keys = filmstrip.keysWithReads(reads) catch &.{};
            const hold = for (keys, 0..) |candidate, index| {
                if (candidate.frame == key.frame) break filmstrip.hold(keys, index, shown.frames);
            } else 0;
            const hold_text = std.fmt.allocPrint(allocator, "{d} frames", .{hold}) catch "?";
            actionFieldRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_key_hold), "Hold", hold_text);
            actionFieldRow(tree, reads.tables, @tagName(filmstrip.Msg.figure_key_easing), "Easing", atoms.lookup(key.easing) orelse "?");
        } else {
            sectionHeading(tree, "animation.key.heading", "Key");
            panelHint(tree, "animation.key.none", "Click a key in the timeline to change its hold and easing. Edits off a key stay in the working pose until +Key.");
        }
    }
    renderPose(tree, reads);
    // The selected shape's or layer's look, which a key can change like a bone.
    const target = prompts.inspectorTarget(session.get(reads.tables), drawing.config(reads.tables));
    if (target.id != 0 and (target.kind == names.shape or target.kind == names.layer)) {
        const name = prompts.valueTextWithReads(allocator, reads, target.kind, target.id, "name") catch "";
        const heading = std.fmt.allocPrint(allocator, "Look of {s}", .{name}) catch "Look";
        sectionHeading(tree, "animation.look.heading", heading);
        for (prompts.inspectorFields(target.kind), 0..) |field, index| {
            if (!animatableField(target.kind, field)) continue;
            inspectorRow(tree, reads, target, field, index, action_row_label_width, .inspector);
        }
    }
}

fn renderPose(tree: *ui.Tree, reads: *session.ReadContext) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    if (!tree.beginRect("pose.controls", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .hug }, .gap = 4, .clip_content = true })) return;
    defer tree.endRect();
    const editor = session.get(tables);
    const bone_name = bone_name: {
        if (editor.active_bone.* == 0) break :bone_name "";
        const data = reads.definition(editor.doc.*) catch break :bone_name "";
        const bone = session.findById(session.api.read.Bone, data.bones, editor.active_bone.*) orelse break :bone_name "";
        break :bone_name atoms.lookup(bone.name) orelse "";
    };
    const heading = if (bone_name.len != 0) std.fmt.allocPrint(reads.readAllocator() catch return, "Bone {s}", .{bone_name}) catch "Bone" else "Bone";
    sectionHeading(tree, "pose.bone.heading", heading);
    if (editor.active_bone.* == 0) panelHint(tree, "pose.bone.none", "Click a bone on the canvas to pose it.");
    if (editor.active_bone.* != 0) {
        // The same rows Design shows for the bone, so a value reads and edits alike in both.
        const bone_target = prompts.InspectorTarget{ .kind = names.bone, .id = editor.active_bone.* };
        const bone_fields = prompts.inspectorFields(names.bone);
        const posed_fields = [_]u32{
            prompts.boneFieldIndex("angle"),
            prompts.boneFieldIndex("length"),
            prompts.boneFieldIndex("local"),
            prompts.boneFieldIndex("scale"),
        };
        for (posed_fields) |field_index| {
            inspectorRow(tree, reads, bone_target, bone_fields[field_index], field_index, action_row_label_width, .pose);
        }
    }
    if (ui_button.beginRow(tree, "pose.reset.row")) {
        defer tree.endRect();
        if (editor.active_bone.* != 0) rowButton(tree, @tagName(pose.Msg.figure_pose_reset_bone), "Reset bone", .undo, "Reset this bone and its active chain to rest");
        rowButton(tree, @tagName(pose.Msg.figure_pose_reset), "Reset all", .undo, "Reset the whole working pose to rest");
    }
    sectionHeading(tree, "pose.ik.heading", "IK");
    // The options bar pins and unpins the endpoint.
    actionButton(tree, @tagName(pose.Msg.figure_ik_target), "Set target and angle...");
    sectionHeading(tree, "pose.library.heading", "Pose library");
    if (ui_button.beginRow(tree, "pose.library.row")) {
        defer tree.endRect();
        rowButton(tree, @tagName(pose.Msg.figure_pose_save), "Save as...", .content_save, "Save the working pose with a name");
        rowButton(tree, @tagName(pose.Msg.figure_pose_apply), "Apply...", .human, "Apply a named pose to the working pose");
    }
    if (ui_button.beginRow(tree, "pose.clipboard.row")) {
        defer tree.endRect();
        rowButton(tree, @tagName(pose.Msg.figure_pose_copy), "Copy", null, "Copy the working pose to the clipboard");
        rowButton(tree, @tagName(pose.Msg.figure_pose_paste), "Paste", null, "Replace the working pose with a compatible copied one");
        rowButton(tree, @tagName(pose.Msg.figure_pose_mirror), "Mirror", .flip_horizontal, "Mirror the working pose across a symmetric rig");
    }
    actionButton(tree, @tagName(pose.Msg.figure_pose_delete), "Delete selected pose");
}

/// One transport control: an action, its icon and label, and when it applies.
const TransportButton = struct { action: []const u8, label: []const u8, icon: ui_button.icons.Icon, hint: []const u8, width: f32, selected: bool = false };

/// Play, step, key and onion controls, then the frame the playhead is on.
fn renderTransport(tree: *ui.Tree, tables: *Table.Registry, atoms: *Atom.Registry, reads: *session.ReadContext) void {
    const settings = filmstrip.config(tables);
    // One lookup of the keys for every button's tooltip.
    var shortcuts = editor_module.Shortcuts.of(tree.frame_allocator.allocator, tables);
    const clip = filmstrip.clipRowWithReads(reads);
    const selected_key = filmstrip.selectedKeyWithReads(reads) catch null;
    const playing = settings.playing.* != 0;
    // A button fills the row inside its padding, so the row's height alone decides both.
    const size_of = struct {
        fn of(width: f32) ui.Size {
            return .{ .w = .{ .fixed = width }, .h = .fill };
        }
    }.of;
    const step_buttons = [_]TransportButton{
        .{ .action = @tagName(filmstrip.Msg.figure_play_pause), .label = if (playing) "Pause" else "Play", .icon = if (playing) .pause else .play, .hint = "Play or pause the clip", .width = 78, .selected = playing },
        .{ .action = @tagName(filmstrip.Msg.figure_frame_previous), .label = "", .icon = .skip_previous, .hint = "Previous frame", .width = 34 },
        .{ .action = @tagName(filmstrip.Msg.figure_frame_next), .label = "", .icon = .skip_next, .hint = "Next frame", .width = 34 },
    };
    for (step_buttons) |entry| {
        chrome.actionButton(tree, &shortcuts, .timeline, .{ .action = entry.action, .label = entry.label, .icon = entry.icon, .hint = entry.hint }, .{
            .variant = .icon_text,
            .size = size_of(entry.width),
            .enabled = clip != null,
            .selected = entry.selected,
        });
    }
    transportDivider(tree, "figure.timeline.divider.keys");
    chrome.actionButton(tree, &shortcuts, .timeline, .{ .action = @tagName(filmstrip.Msg.figure_key_add), .label = "Key", .icon = .timeline_plus, .hint = "Capture the working pose as a key at the playhead" }, .{ .variant = .icon_text, .size = size_of(72), .enabled = clip != null });
    chrome.actionButton(tree, &shortcuts, .timeline, .{ .action = @tagName(filmstrip.Msg.figure_key_delete), .label = "Delete", .icon = .timeline_minus, .hint = "Delete the selected key, keeping its pose" }, .{ .variant = .icon_text, .size = size_of(86), .enabled = selected_key != null });
    // The selected key's easing, which the button cycles.
    const easing = if (selected_key) |key| atoms.lookup(key.easing) orelse "?" else "Easing";
    chrome.actionButton(tree, &shortcuts, .timeline, .{ .action = @tagName(filmstrip.Msg.figure_key_easing), .label = easing, .hint = "How the selected key eases into the next: constant, linear or smooth" }, .{ .variant = .text_only, .size = size_of(82), .enabled = selected_key != null });
    transportDivider(tree, "figure.timeline.divider.onion");
    chrome.actionButton(tree, &shortcuts, .timeline, .{ .action = @tagName(filmstrip.Msg.figure_toggle_onion), .label = "Onion", .icon = .layers, .hint = "Show the keys either side as red and green ghosts" }, .{ .variant = .icon_text, .size = size_of(84), .enabled = clip != null, .selected = settings.onion.* != 0 });
    tree.rect("figure.timeline.space", .{ .size = .{ .w = .fill, .h = .fill } });
    if (clip) |shown| {
        const readout = std.fmt.allocPrint(tree.frame_allocator.allocator, "{s}   frame {d} of {d}   {d} fps", .{ atoms.lookup(shown.name) orelse "clip", settings.frame.*, shown.frames, shown.fps }) catch "";
        tree.text("figure.timeline.readout", readout, .{ .font = style.ui_font, .color = style.col.text_dim });
    }
}

fn transportDivider(tree: *ui.Tree, id: []const u8) void {
    tree.rect(id, .{ .size = .{ .w = .{ .fixed = 1 }, .h = .{ .fixed = 18 } }, .bg = style.col.region_border });
}

pub fn renderTimeline(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, render_context: *roop.Context) void {
    const id = Atom.from(workspace.sequencer_id);
    panel_frame.drawPlainHeader(mem, tables, atoms, id, frame, render_context);
    const viewport = panel_frame.beginContent(tables, atoms, id, frame, render_context) orelse return;
    defer panel_frame.endContent(render_context);
    if (viewport.width <= 0 or viewport.height <= 0) return;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    const rect = mesha.panels.Rect{ .w = viewport.width, .h = viewport.height };
    filmstrip.render(&reads, rect, .{ .x = viewport.x, .y = viewport.y }, render_context);
    const scratch = mem.frameScratchAllocator() catch return;
    const hovered = editor_state.hoveredElementId(tables);
    const hits = editor_state.hitRegions(tables, atoms);
    // The filmstrip draws itself, so regions of its own give it the wheel and its presses.
    var strip = ui.Tree.init(scratch, atoms, 6) catch return;
    const wheel = workspace.to(&strip, .from(workspace.Msg.figure_scroll), workspace.ScrollSurface.timeline);
    if (strip.beginRect("figure.timeline.wheel", .{ .size = .{ .w = .fill, .h = .fill }, .on_scroll = wheel })) {
        defer strip.endRect();
        const press = workspace.to(&strip, .from(workspace.Msg.figure_pointer_down), {});
        strip.rect("figure.timeline.header", .{ .size = .{ .w = .fill, .h = .{ .fixed = filmstrip_sequencer.controls_height } } });
        strip.rect("figure.timeline.keys", .{ .size = .{ .w = .fill, .h = .fill } });
        strip.onClick(press, .all);
    }
    strip.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .depth = editor_module.kHitDepth,
    }, render_context, hits);
    var tree = ui.Tree.init(scratch, atoms, 128) catch return;
    const editor = session.get(tables);
    const available = session.definitionInfo(tables, atoms, editor.doc.*) != null;
    if (tree.beginRect("figure.timeline.controls", .{
        .axis = .horizontal,
        .cross_align = .center,
        .size = .{ .w = .fill, .h = .{ .fixed = filmstrip_sequencer.controls_height } },
        .padding = 4,
        .gap = 4,
        .bg = style.col.sidebar,
        .clip_content = true,
        .on_scroll = wheel,
    })) {
        defer tree.endRect();
        if (!available or !filmstrip.enabled(session.get(tables))) {
            tree.text("figure.timeline.unavailable", "New or Open a figure to begin", .{ .font = style.ui_font, .color = style.col.text_dim });
        } else {
            renderTransport(&tree, tables, atoms, &reads);
        }
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = hovered,
        .depth = editor_module.kHitDepth,
    }, render_context, hits);
}
