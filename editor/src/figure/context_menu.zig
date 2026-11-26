//! The right-click menu. It is modal the way the action palette is: while open, the figure's pointer
//! captures step aside and a full-window backdrop takes the next click. Rows only invoke named
//! actions, so a menu item can never do anything its shortcut would not.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const modes = @import("../modes.zig");
const workspace = @import("workspace.zig");
const drawing = @import("drawing.zig");
const pose = @import("pose.zig");
const filmstrip = @import("filmstrip.zig");
const sequencer = mesha.sequencer;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const roop = mesha.roop;
const keybinds = mesha.keybinds;
const session = @import("session.zig");
const selection = @import("selection.zig");
const chrome = @import("chrome.zig");
const style = @import("../ui/style.zig");
const editor_state = @import("../state.zig");
const editor_mod = @import("../editor.zig");
const editor_sequencer = @import("../editor_sequencer.zig");

pub const name = "editor_figure_context_menu";

pub const Origin = enum(u8) { canvas, layers };

const State = struct {
    open: u8 = 0,
    origin: u8 = @intFromEnum(Origin.canvas),
    x: f32 = 0,
    y: f32 = 0,
};

const Item = struct { label: []const u8 = "", action: []const u8 = "" };
const separator = Item{};

const view_items = [_]Item{
    .{ .label = "Zoom to fit", .action = @tagName(workspace.Msg.figure_view_fit) },
    .{ .label = "Zoom to 100%", .action = @tagName(workspace.Msg.figure_view_reset) },
    .{ .label = "Show grid", .action = @tagName(workspace.Msg.figure_toggle_grid) },
    .{ .label = "Show bones", .action = @tagName(workspace.Msg.figure_toggle_bones) },
};
const canvas_empty = [_]Item{
    .{ .label = "Paste", .action = @tagName(drawing.Msg.figure_paste) },
    .{ .label = "Select all", .action = @tagName(workspace.Msg.figure_select_all) },
    separator,
} ++ view_items;
const object_items = [_]Item{
    .{ .label = "Cut", .action = @tagName(drawing.Msg.figure_cut) },
    .{ .label = "Copy", .action = @tagName(drawing.Msg.figure_copy) },
    .{ .label = "Paste", .action = @tagName(drawing.Msg.figure_paste) },
    .{ .label = "Duplicate", .action = @tagName(drawing.Msg.figure_duplicate) },
    separator,
    .{ .label = "Group", .action = @tagName(workspace.Msg.figure_folder_group) },
    .{ .label = "Ungroup", .action = @tagName(workspace.Msg.figure_folder_ungroup) },
    separator,
    .{ .label = "Bring to front", .action = @tagName(drawing.Msg.figure_shape_front) },
    .{ .label = "Send to back", .action = @tagName(drawing.Msg.figure_shape_back) },
    separator,
    .{ .label = "Rename", .action = @tagName(workspace.Msg.figure_rename) },
    .{ .label = "Show/hide", .action = @tagName(workspace.Msg.figure_toggle_visible) },
    .{ .label = "Lock/unlock", .action = @tagName(workspace.Msg.figure_toggle_lock) },
    separator,
    .{ .label = "Zoom to selection", .action = @tagName(workspace.Msg.figure_view_selection) },
    .{ .label = "Delete", .action = @tagName(workspace.Msg.figure_delete_bone) },
};
const row_items = [_]Item{
    .{ .label = "Rename", .action = @tagName(workspace.Msg.figure_rename) },
    .{ .label = "Delete", .action = @tagName(workspace.Msg.figure_delete_bone) },
    separator,
    .{ .label = "New layer", .action = @tagName(drawing.Msg.figure_layer_add) },
};
const pose_items = [_]Item{
    .{ .label = "Copy pose", .action = @tagName(pose.Msg.figure_pose_copy) },
    .{ .label = "Paste pose", .action = @tagName(pose.Msg.figure_pose_paste) },
    .{ .label = "Mirror pose", .action = @tagName(pose.Msg.figure_pose_mirror) },
    separator,
    .{ .label = "Reset bone", .action = @tagName(pose.Msg.figure_pose_reset_bone) },
    .{ .label = "Reset all", .action = @tagName(pose.Msg.figure_pose_reset) },
    separator,
} ++ view_items;
const animate_items = [_]Item{
    .{ .label = "Add key", .action = @tagName(filmstrip.Msg.figure_key_add) },
    .{ .label = "Delete key", .action = @tagName(filmstrip.Msg.figure_key_delete) },
    separator,
} ++ pose_items;

const menu_width: f32 = 260;
const row_height: f32 = style.metric.row_height;
const separator_height: f32 = 9;
const padding: f32 = 4;

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareSingleton(State, mem, atoms, tables, name);
}

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try session.prepareSingleton(State, mem, atoms, tables, name);
}

pub const View = session.Row(State);
pub fn get(tables: *Table.Registry) View {
    const state_table = tables.findByName(Atom.from(name)).?;
    const row = Table.RowHandle{ .row = 0, .generation = state_table.rowGeneration(0) };
    return state_table.getRow(row, session.Row(State)).?;
}

pub fn isOpen(menu: View) bool {
    return menu.open.* != 0;
}

pub fn open(state: View, origin: Origin, x: f32, y: f32) void {
    state.open.* = 1;
    state.origin.* = @intFromEnum(origin);
    state.x.* = x;
    state.y.* = y;
}

/// Returns whether a menu was open, so Esc closes only the menu.
pub fn close(state: View) bool {
    const was_open = state.open.* != 0;
    state.open.* = 0;
    return was_open;
}

/// The left button reaches the backdrop through its hit region, as any press does.
pub fn subscribe(pass: *sequencer.Pass) !void {
    try workspace.appendInput(pass, .{ .mouse_button_down = .{ .button = .right, .capture = true } }, .from(workspace.Msg.figure_menu_dismiss));
    try workspace.appendInput(pass, .{ .key_down = .{ .key = .escape, .capture = true } }, .from(workspace.Msg.figure_menu_dismiss));
}

fn items(editor: session.View, origin: Origin) []const Item {
    if (editor.mode.* == names.animate) return &animate_items;
    const kind = editor.active_kind.*;
    const object = editor.active_id.* != 0 and (kind == names.shape or kind == names.layer);
    if (object) return &object_items;
    if (origin == .layers) return &row_items;
    return if (editor.active_id.* != 0) &row_items else &canvas_empty;
}

pub fn render(mem: *memory.Memory, tables: *Table.Registry, atoms: *Atom.Registry, viewport: plugin.Viewport, hit_depth: u32, ctx: *roop.Context) void {
    const state = get(tables);
    if (state.open.* == 0) return;
    const screen_w = viewport.width;
    const screen_h = viewport.height;
    const offset = mesha.math.Vec2f{ .x = viewport.x, .y = viewport.y };
    const scratch = mem.frameScratchAllocator() catch return;
    const hits = editor_state.hitRegions(tables, atoms);
    const hovered = editor_state.hoveredElementId(tables);

    var backdrop = ui.Tree.init(scratch, atoms, 8) catch return;
    if (backdrop.beginRect("figure.menu.backdrop", .{ .size = .{ .w = .fill, .h = .fill } })) {
        backdrop.onClick(workspace.to(&backdrop, .from(workspace.Msg.figure_menu_dismiss), {}), .left);
        // Hover skips regions without a route, so without one the chrome below would light up.
        backdrop.trackHover("");
        backdrop.endRect();
    }
    backdrop.commit(.{ .root_size = .{ .x = screen_w, .y = screen_h }, .offset = offset, .hovered = hovered, .depth = hit_depth }, ctx, hits, editor_sequencer.redrawInbox());

    const entries = items(session.get(tables), @enumFromInt(state.origin.*));
    var height = 2 * padding;
    for (entries) |entry| height += if (entry.action.len == 0) separator_height else row_height;
    // Kept on screen by sliding, so the row under the pointer stays near it.
    const x = std.math.clamp(state.x.* - offset.x, 0, @max(0, screen_w - menu_width));
    const y = std.math.clamp(state.y.* - offset.y, 0, @max(0, screen_h - height));

    var tree = ui.Tree.init(scratch, atoms, 32 + entries.len * 8) catch return;
    // One lookup of the keys for every row.
    var shortcuts = editor_mod.Shortcuts.of(scratch.allocator, tables);
    if (tree.beginRect("figure.menu", .{
        .axis = .vertical,
        .size = .{ .w = .fill, .h = .fill },
        .padding = padding,
        .bg = style.col.sidebar,
        .border = style.col.border,
        .border_size = style.metric.glow,
        .corner_radius = 6,
        .clip_content = true,
    })) {
        defer tree.endRect();
        tree.onClick(workspace.to(&tree, .from(workspace.Msg.figure_menu_dismiss), {}), .left);
        tree.trackHover("");
        for (entries, 0..) |entry, index| {
            if (entry.action.len == 0) {
                if (tree.beginRect(.{ "figure.menu.separator", index }, .{ .axis = .vertical, .padding = 4, .size = .{ .w = .fill, .h = .{ .fixed = separator_height } } })) {
                    defer tree.endRect();
                    tree.rect(.{ "figure.menu.rule", index }, .{ .size = .{ .w = .fill, .h = .{ .fixed = 1 } }, .bg = style.col.divider });
                }
                continue;
            }
            if (!tree.beginRect(.{ "figure.menu.row", index }, .{
                .axis = .horizontal,
                .cross_align = .center,
                .size = .{ .w = .fill, .h = .{ .fixed = row_height } },
                .padding = 6,
                .padding_y = 0,
                .bg_hover = style.col.accent_deep,
                .corner_radius = 3,
            })) continue;
            defer tree.endRect();
            const short_name = modes.shortName("figure", entry.action);
            const action_id: plugin.action_api.ActionId = .{ modes.figure, Atom.from(short_name) };
            tree.onClick(workspace.to(&tree, .from(workspace.Msg.figure_menu_item), action_id), .left);
            tree.trackHover("");
            tree.text(.{ "figure.menu.label", index }, entry.label, .{ .font = style.ui_font, .color = style.col.text, .size_hint = .{ .w = .fill } });
            const shortcut = shortcuts.text(modes.figure, action_id) orelse continue;
            tree.text(.{ "figure.menu.shortcut", index }, shortcut, .{ .font = style.ui_font, .color = style.col.text_dim });
        }
    }
    tree.commit(.{ .root_size = .{ .x = menu_width, .y = height }, .origin = .{ .x = x, .y = y }, .offset = offset, .hovered = hovered, .depth = hit_depth + 1 }, ctx, hits, editor_sequencer.redrawInbox());
}
