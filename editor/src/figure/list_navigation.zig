//! Shared list geometry and bounded wheel movement for rendering and picking.
const std = @import("std");
const metric = style.metric;
const style = @import("../ui/style.zig");
pub const row_height: f32 = metric.row_height;
pub const row_step: f32 = metric.row_height;
/// A row's disclosure sits left of the drag capture; its eye and lock sit right of it.
pub const capture_left: f32 = 28;
pub const capture_right: f32 = 64;
pub const toggle_width: f32 = 24;
pub const tab_row_height: f32 = metric.tab_height;
/// Below this width the four category tabs wrap into two rows of full labels.
pub const tab_wrap_width: f32 = 220;
pub const folder_tools_height: f32 = metric.button_height;
const panel_gap: f32 = 4;

/// First outliner row's y offset: panel padding, tab row(s) and, when
/// `folder_tools` is set, the art tab's folder tools row. Rendering and pointer
/// picking share this so visible rows cannot select a different underlying item.
pub fn top(width: f32, folder_tools: bool) f32 {
    const tab_rows: f32 = if (width >= tab_wrap_width) 1 else 2;
    var y: f32 = panel_gap;
    y += tab_rows * tab_row_height + (tab_rows - 1) * panel_gap;
    y += panel_gap;
    if (folder_tools) y += folder_tools_height + panel_gap;
    return y;
}

pub fn wheel(current_start: u32, delta: f32, maximum: usize) u32 {
    const limit: u32 = @intCast(@min(maximum, std.math.maxInt(u32)));
    const start_index = @min(current_start, limit);
    if (!std.math.isFinite(delta) or delta == 0) return start_index;
    const amount: u32 = @intFromFloat(@min(@ceil(@abs(delta)), @as(f64, std.math.maxInt(u32))));
    return if (delta > 0) start_index -| amount else @min(limit, start_index +| amount);
}

pub fn visibleEnd(outliner_nodes: anytype, start_index: usize, viewport_height: f32, first_row_y: f32) usize {
    var y: f32 = first_row_y;
    var row_index = start_index;
    while (row_index < outliner_nodes.len) : (row_index += 1) {
        if (y + row_height > viewport_height) break;
        y += row_step;
    }
    return row_index;
}

pub fn scrollStart(outliner_nodes: anytype, current_start: usize, selected_index: ?usize, viewport_height: f32, reveal: bool, first_row_y: f32) usize {
    var start_index: usize = @min(current_start, outliner_nodes.len -| 1);
    if (reveal) {
        if (selected_index) |row_index| {
            if (row_index < start_index) start_index = row_index;
            while (start_index < row_index and row_index >= visibleEnd(outliner_nodes, start_index, viewport_height, first_row_y)) start_index += 1;
        }
    }
    return start_index;
}

test "figure list wheel clamps both ends and ignores invalid deltas" {
    try std.testing.expectEqual(@as(u32, 3), wheel(0, -3, 12));
    try std.testing.expectEqual(@as(u32, 0), wheel(2, 5, 12));
    try std.testing.expectEqual(@as(u32, 12), wheel(10, -100, 12));
    try std.testing.expectEqual(@as(u32, 0), wheel(10, -1, 0));
    try std.testing.expectEqual(@as(u32, 4), wheel(3, -0.1, 12));
    try std.testing.expectEqual(@as(u32, 3), wheel(3, std.math.nan(f32), 12));
    try std.testing.expectEqual(@as(u32, 12), wheel(3, -std.math.floatMax(f32), 12));
}
