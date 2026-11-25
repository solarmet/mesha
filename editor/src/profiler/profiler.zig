//! The Profiler panel: records frames, and shows what happened in each.
//!
//! Nothing is recorded until the record button is pressed; then the zone recorder captures
//! every frame's zones, by the main loop's frame index. Pressing record again stops and keeps
//! the recording. The step buttons hold a frame and move it a frame at a time; stepping
//! forward from the last recorded frame goes live again, and recording goes on from it. The
//! strip shows the recorded frames by their length; click or drag it to scrub, or use the
//! wheel to step.
//!
//! Selecting a zone, in the zones table or the lanes, charts it in the strip instead: the
//! statistic the table is sorted by, in every recorded frame. Selecting it again goes back to
//! frame lengths.
//!
//! Under the strip, the shown frame's zones as lanes of nested spans: the wheel zooms
//! around the pointer, a drag pans, a click selects a zone and a double click fits the view
//! to it. A ruler over the lanes gives the time from the frame's start, and the time under
//! the pointer. Under the lanes, a filter and two tables: every zone name with its
//! statistics, sortable, and the frame's log messages. The filter narrows both tables and
//! dims the zones it leaves out of the lanes.
//!
//! Log messages logged while recording are markers in their thread's lane header, coloured
//! by level; hovering one shows it, and clicking it or its row in the messages table
//! selects it and centres the timeline on it. The level buttons hide or show each level in
//! both. The strip marks the frames that logged a warning or an error.
//!
//! Dividers under the strip, under the timeline and between the tables are dragged to
//! resize them, and double-clicked to split the room they divide in half; the sizes are kept
//! with the panel's state. A timeline never resized fits its lanes.
//!
//! Each frame the panel asks the profiler system for a snapshot of the shown frame and
//! draws the latest one received; the snapshot is host memory, valid until two more have
//! been built, so only its address is kept here.
//!
//! The panel is a native system (`sequencer` in core, `system` below): its kernels take its
//! messages, writing its row, `editor_profiler`.
const std = @import("std");
const mesha = @import("mesha");
const ui = mesha.ui;
const Atom = mesha.Atom;
const memory_mod = mesha.memory;
const Table = mesha.Table;
const roop = mesha.roop;
const math = mesha.math;
const plugin = mesha.plugin;
const input = mesha.input;
const panels_mod = mesha.panels;
const panel_frame = @import("../panel_frame.zig");
const editor_state = @import("../state.zig");
const style = @import("../ui/style.zig");
const button = @import("../ui/button.zig");
const timeline = @import("timeline.zig");
const filter_field = ui.filter_field;
const marks = ui.marks;
const vsync = @import("../ui/vsync.zig");
const sequencer = mesha.sequencer;
const workspaces = @import("../workspaces.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const modes = @import("../modes.zig");

const profiler_api = plugin.profiler_api;
const Record = profiler_api.Record;
const Message = profiler_api.Message;
const Snapshot = profiler_api.Snapshot;

/// The profiler's root: its panel draws again when its system changes a table.
pub const profiler_root = Atom.from("profiler");
const Rect = panels_mod.Rect;

// ---- the system -----------------------------------------------------------------------------

/// The profiler as a system of kernels: one takes the messages its subscriptions, drawing and
/// actions send it, and one asks for the shown frame's snapshot. Drawing
/// and subscriptions only read, and stay plain functions.
pub fn system() sequencer.System {
    return .{
        .name = "profiler",
        .names = comptime &sequencer.enumNames(Msg),
        .root = profiler_root,
        .claims = claims,
        .access = access,
        .kernels = &.{
            .{ .name = "profiler.take_messages", .run = takeMessages },
            .{ .name = "profiler.request_snapshot", .run = requestSnapshot },
            .{ .name = "profiler.subscribe", .run = subscribe },
            .{ .name = "profiler.follow_modes", .run = followModes },
        },
    };
}

/// The profiler panel's modes, a `modes.PanelModesRow`.
pub const panel_modes_table_name = "profiler_panel_modes";

/// The panel's mode: `filter` while its filter is typed in, `global` otherwise.
fn followModes(pass: *sequencer.Pass) !void {
    const state = try pass.readSingleton(state_table, StateView);
    const major = if (state.filter_focused.* != 0) modes.filter else plugin.action_api.global_mode;
    const wanted = [_]modes.PanelMajor{.{ .panel = panel, .major = major }};
    try modes.syncPanelModes(pass, panel_modes_table_name, &wanted);
}

const input_subscriptions = Atom.from(input.subscriptions_table_name);

const state_table = Atom.from(state_table_name);
const panel = Atom.from(panel_name);
const panel_nodes_table = Atom.from(panels_mod.nodes_table_name);
const panel_state_table = Atom.from(panels_mod.state_table_name);

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Every frame: the panel's row and the panels it asks about; the row is written only while
/// there are messages.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    var result: sequencer.Access = .{};
    result.read(state_table);
    // `isShown`, `hasFocus` and the panel requests read the panels' tree and focus.
    result.readAll(&.{ panel_nodes_table, panel_state_table });
    result.write(input_subscriptions);
    // The snapshot each frame, and recording and holding frames, ask the recorder.
    result.writeIfPresent(frame.tables, Atom.from(profiler_api.commands_table_name));
    // Toggling the profiler shows or closes its panel, and may ask the panels for the focus.
    result.writeIfPresent(frame.tables, Atom.from(workspaces.shown_panels_table_name));
    result.writeIfPresent(frame.tables, Atom.from(plugin.panels.commands_table_name));
    if (frame.messages.len != 0) result.write(state_table);
    modes.declarePanelModes(&result, frame.tables, panel_modes_table_name);
    return result;
}

/// Each message the profiler claimed this frame, in order.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const state = try pass.writeSingleton(state_table, StateView);
    for (frame.messages) |received| {
        handle(pass, state, received) catch |err| received.unreadable(err);
    }
}

/// What the profiler's helpers ask of the hosts by their rows: the recorder and the panels.
const Outbox = struct {
    memory: *memory_mod.Memory,
    tables: *Table.Registry,
};

fn outboxOf(pass: *sequencer.Pass) Outbox {
    return .{ .memory = pass.frame.memory, .tables = pass.frame.tables };
}

/// Asks for this frame's snapshot while the panel is shown.
fn requestSnapshot(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (!isShown(frame.tables, frame.atoms)) return;
    const state = try pass.readSingleton(state_table, StateView);
    profiler_api.request(frame.memory, frame.tables, .{ .snapshot = .{
        .first_frame = state.shown_frame.*,
        .last_frame = state.shown_frame.*,
        .reply = sequencer.ReplyTo.of(system(), .from(Msg.profiler_snapshot)),
        .series_name = if (state.chartSource() == .zone) state.chart_zone.* else 0,
    } });
}

pub const state_table_name = "editor_profiler";

/// What the profiler's action, subscriptions, drawing and snapshot requests send it.
const Msg = enum(u64) {
    profiler_toggle = Atom.from("profiler_toggle").value(),
    profiler_snapshot = Atom.from("profiler_snapshot").value(),
    profiler_press = Atom.from("profiler_press").value(),
    profiler_release = Atom.from("profiler_release").value(),
    profiler_move = Atom.from("profiler_move").value(),
    profiler_scroll = Atom.from("profiler_scroll").value(),
    profiler_record = Atom.from("profiler_record").value(),
    profiler_show_live = Atom.from("profiler_show_live").value(),
    profiler_step_back = Atom.from("profiler_step_back").value(),
    profiler_step_forward = Atom.from("profiler_step_forward").value(),
    profiler_fit = Atom.from("profiler_fit").value(),
    profiler_sort = Atom.from("profiler_sort").value(),
    profiler_highlight = Atom.from("profiler_highlight").value(),
    profiler_filter_text = Atom.from("profiler_filter_text").value(),
    profiler_filter_key = Atom.from("profiler_filter_key").value(),
    profiler_filter_clear = Atom.from("profiler_filter_clear").value(),
    profiler_message_select = Atom.from("profiler_message_select").value(),
    profiler_message_level = Atom.from("profiler_message_level").value(),
    profiler_divider = Atom.from("profiler_divider").value(),
    _,
};

pub const actions = [_]plugin.action_api.Def{
    .{ .name = "profiler_toggle", .tag = @tagName(Msg.profiler_toggle), .doc = "Show or hide the profiler" },
};

/// A log message by its lane and time, as a message's row asks to select it.
const MessageRef = extern struct { begin_ns: u64, lane: u32, reserved: u32 = 0 };

const hit_depth = panels_mod.kPanelHitDepth;
const toolbar_height: f32 = 44;
const default_strip_height: f32 = 52;
const strip_least: f32 = 32;
/// The thickness of the dividers dragged to resize the strip, the timeline and the tables.
const divider_size: f32 = 6;
const default_zones_share: f32 = 0.55;
/// The narrowest a table may be dragged to while the other has room.
const table_least_width: f32 = 180;
const widget_title_height: f32 = 22;
const widgets_bar_height: f32 = 34;
const filter_width: f32 = 300;
/// The fewest rows the tables keep, however tall the lanes would like to be.
const min_table_rows: f32 = 6;
const row_height: f32 = 22;
const padding: f32 = 4;
/// Pixels a press may move and still count as a click.
const click_slop: f32 = 3;

const Drag = enum(u8) {
    none,
    pan,
    strip,
    strip_divider,
    timeline_divider,
    tables_divider,

    fn divider(drag: Drag) ?Divider {
        return switch (drag) {
            .strip_divider => .strip,
            .timeline_divider => .timeline,
            .tables_divider => .tables,
            .none, .pan, .strip => null,
        };
    }
};
/// The divider under the strip, the one under the timeline, and the one between the tables.
const Divider = enum {
    strip,
    timeline,
    tables,

    fn drag(divider: Divider) Drag {
        return switch (divider) {
            .strip => .strip_divider,
            .timeline => .timeline_divider,
            .tables => .tables_divider,
        };
    }
};
/// What the strip charts: each frame's length, or a zone's sorted statistic.
const ChartSource = enum(u8) { frames, zone };
pub const SortColumn = enum(u8) { name, count, total, self, mean, max };

/// The panel's state. The snapshot is the host's; see the file comment.
const StateView = struct {
    snapshot_address: *u64,
    /// Whether this panel asked the profiler to record.
    recording: *u8,
    /// The frames shown are a log file's, as the last snapshot said.
    showing_file: *u8,
    /// The frame held and shown; 0 shows the latest and holds nothing.
    shown_frame: *u64,
    /// The shown part of the frame, as offsets from its start; both 0 shows all of it.
    view_begin: *f64,
    view_end: *f64,
    pointer_x: *f32,
    pointer_y: *f32,
    drag: *u8,
    drag_x: *f32,
    drag_y: *f32,
    drag_moved: *u8,
    drag_view_begin: *f64,
    drag_view_end: *f64,
    /// A zone name the timeline picks out; 0 for none.
    highlight: *u64,
    selected_lane: *i32,
    selected_depth: *i32,
    selected_begin: *u64,
    sort: *u8,
    sort_ascending: *u8,
    stats_scroll: *i32,
    /// The filter the tables and lanes are narrowed to; see `mesha.ui.filter_field`.
    filter: *Table.String,
    filter_focused: *u8,
    chart: *u8,
    /// The zone name charted while `chart` is `zone`.
    chart_zone: *u64,
    /// The selected log message's time, 0 for none, and its lane.
    selected_message_ns: *u64,
    selected_message_lane: *i32,
    messages_scroll: *i32,
    /// The message levels shown, a bit per `timeline.LevelGroup`.
    message_levels: *u8,
    /// Where the dividers were dragged to: the strip's height, the timeline's (0 fits its
    /// lanes), and the zones table's share of the tables' width.
    strip_height: *f32,
    timeline_height: *f32,
    zones_share: *f32,
    /// The size a divider's drag started from: a height, or the zones table's width.
    drag_size: *f32,

    fn chartSource(state: StateView) ChartSource {
        return std.enums.fromInt(ChartSource, state.chart.*) orelse .frames;
    }

    /// `table` is the profiler's state table, which holds the filter's text.
    fn filterField(state: StateView, table: *Table) filter_field.Field {
        return .{ .table = table, .text = state.filter, .focused = state.filter_focused };
    }
};

const state_defaults = .{
    .snapshot_address = @as(u64, 0),
    .recording = @as(u8, 0),
    .showing_file = @as(u8, 0),
    .shown_frame = @as(u64, 0),
    .view_begin = @as(f64, 0),
    .view_end = @as(f64, 0),
    .pointer_x = @as(f32, -1),
    .pointer_y = @as(f32, -1),
    .drag = @as(u8, @intFromEnum(Drag.none)),
    .drag_x = @as(f32, 0),
    .drag_y = @as(f32, 0),
    .drag_moved = @as(u8, 0),
    .drag_view_begin = @as(f64, 0),
    .drag_view_end = @as(f64, 0),
    .highlight = @as(u64, 0),
    .selected_lane = @as(i32, -1),
    .selected_depth = @as(i32, -1),
    .selected_begin = @as(u64, 0),
    .sort = @as(u8, @intFromEnum(SortColumn.total)),
    .sort_ascending = @as(u8, 0),
    .stats_scroll = @as(i32, 0),
    .filter = Table.String{},
    .filter_focused = @as(u8, 0),
    .chart = @as(u8, @intFromEnum(ChartSource.frames)),
    .chart_zone = @as(u64, 0),
    .selected_message_ns = @as(u64, 0),
    .selected_message_lane = @as(i32, -1),
    .messages_scroll = @as(i32, 0),
    .message_levels = timeline.all_levels,
    .strip_height = default_strip_height,
    .timeline_height = @as(f32, 0),
    .zones_share = default_zones_share,
    .drag_size = @as(f32, 0),
};

fn addStateFields(schema: *Table.Schema) !void {
    try schema.addFieldFallible("snapshot_address", u64, .int);
    try schema.addFieldFallible("recording", u8, .int);
    try schema.addFieldFallible("showing_file", u8, .int);
    try schema.addFieldFallible("shown_frame", u64, .int);
    try schema.addFieldFallible("view_begin", f64, .int);
    try schema.addFieldFallible("view_end", f64, .int);
    try schema.addFieldFallible("pointer_x", f32, .int);
    try schema.addFieldFallible("pointer_y", f32, .int);
    try schema.addFieldFallible("drag", u8, .int);
    try schema.addFieldFallible("drag_x", f32, .int);
    try schema.addFieldFallible("drag_y", f32, .int);
    try schema.addFieldFallible("drag_moved", u8, .int);
    try schema.addFieldFallible("drag_view_begin", f64, .int);
    try schema.addFieldFallible("drag_view_end", f64, .int);
    try schema.addFieldFallible("highlight", u64, .int);
    try schema.addFieldFallible("selected_lane", i32, .int);
    try schema.addFieldFallible("selected_depth", i32, .int);
    try schema.addFieldFallible("selected_begin", u64, .int);
    try schema.addFieldFallible("sort", u8, .int);
    try schema.addFieldFallible("sort_ascending", u8, .int);
    try schema.addFieldFallible("stats_scroll", i32, .int);
    try schema.addFieldFallible("filter", Table.String, .text_field);
    try schema.addFieldFallible("filter_focused", u8, .int);
    try schema.addFieldFallible("chart", u8, .int);
    try schema.addFieldFallible("chart_zone", u64, .int);
    try schema.addFieldFallible("selected_message_ns", u64, .int);
    try schema.addFieldFallible("selected_message_lane", i32, .int);
    try schema.addFieldFallible("messages_scroll", i32, .int);
    try schema.addFieldFallible("message_levels", u8, .int);
    try schema.addFieldFallible("strip_height", f32, .int);
    try schema.addFieldFallible("timeline_height", f32, .int);
    try schema.addFieldFallible("zones_share", f32, .int);
    try schema.addFieldFallible("drag_size", f32, .int);
}

const state_field_count = 35;

pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, state_field_count);
    defer schema.deinit();
    try addStateFields(&schema);
    _ = try tables.ensureSingleton(&schema, state_table, state_defaults, .durable);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
}

pub fn prepareInit(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, state_field_count);
    defer schema.deinit();
    try addStateFields(&schema);
    _ = try editor_state.prepareSingletonSchema(tables, &schema, state_table, state_defaults, .durable);
    try modes.ensurePanelModes(scratch, atoms, tables, panel_modes_table_name);
}

/// The panel's row, for the entry points that are not kernels: drawing, subscriptions, and
/// what the editor asks of the panel.
fn stateOf(tables: *Table.Registry) ?StateView {
    const table = tables.findByName(state_table) orelse return null;
    return table.getRow(.{ .row = 0, .generation = table.rowGeneration(0) }, StateView);
}

fn snapshotOf(state: StateView) ?*const Snapshot {
    if (state.snapshot_address.* == 0) return null;
    return @ptrFromInt(state.snapshot_address.*);
}

// ---- geometry -------------------------------------------------------------------------------

/// Where the parts sit in the panel, in window coordinates. `timeline` is the ruler over the
/// `lanes`; `filter` sits in the bar over the tables, the zones table (`stats`) beside the
/// `messages` table. A divider under the strip, one under the timeline and one between the
/// tables are dragged to resize them; `content` is what the panel was laid out in.
const Regions = struct {
    content: Rect,
    toolbar: Rect,
    strip: Rect,
    strip_divider: Rect,
    timeline: Rect,
    ruler: Rect,
    lanes: Rect,
    timeline_divider: Rect,
    widgets_bar: Rect,
    filter: Rect,
    stats: Rect,
    tables_divider: Rect,
    messages: Rect,
};

/// The sizes the dividers were dragged to; see `StateView`.
const Layout = struct { strip_height: f32, timeline_height: f32, zones_share: f32 };

fn layoutOf(state: StateView) Layout {
    return .{ .strip_height = state.strip_height.*, .timeline_height = state.timeline_height.*, .zones_share = state.zones_share.* };
}

/// The strip and the timeline take the heights they were dragged to, as far as the panel
/// has room. A timeline never dragged takes what its lanes want, up to about half of what is
/// under the strip; the tables take the rest.
fn regionsOf(content: Rect, snapshot: ?*const Snapshot, layout: Layout) Regions {
    const inner: Rect = .{ .x = content.x + padding, .y = content.y + padding, .w = @max(content.w - 2 * padding, 0), .h = @max(content.h - 2 * padding, 0) };
    const strip_most = @max(inner.h * 0.5, strip_least);
    const strip_height = @round(@max(@min(layout.strip_height, strip_most), strip_least));
    const below_strip = @max(inner.h - toolbar_height - strip_height - 2 * divider_size, 0);
    // Whole pixels: everything below sits on this height, and text placed between pixels
    // renders soft.
    const timeline_height = @round(timelineHeight(below_strip, snapshot, layout.timeline_height));
    const widgets_height = @max(below_strip - timeline_height, 0);
    var y = inner.y;
    const toolbar: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = toolbar_height };
    y += toolbar_height;
    const strip: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = strip_height };
    y += strip_height;
    const strip_divider: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = divider_size };
    y += divider_size;
    const timeline_rect: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = timeline_height };
    const ruler: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = @min(timeline.ruler_height, timeline_height) };
    const lanes: Rect = .{ .x = inner.x, .y = y + ruler.h, .w = inner.w, .h = timeline_height - ruler.h };
    y += timeline_height;
    const timeline_divider: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = divider_size };
    y += divider_size;
    const bar_height = @min(widgets_bar_height, widgets_height);
    const widgets_bar: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = bar_height };
    const filter: Rect = .{ .x = inner.x + 4, .y = y + @round((bar_height - 26) * 0.5), .w = @min(filter_width, inner.w), .h = 26 };
    y += bar_height;
    const tables_height = widgets_height - bar_height;
    const tables_width = @max(inner.w - divider_size, 0);
    const stats_width = @round(zonesWidth(tables_width, layout.zones_share));
    const messages_x = inner.x + stats_width + divider_size;
    return .{
        .content = content,
        .toolbar = toolbar,
        .strip = strip,
        .strip_divider = strip_divider,
        .timeline = timeline_rect,
        .ruler = ruler,
        .lanes = lanes,
        .timeline_divider = timeline_divider,
        .widgets_bar = widgets_bar,
        .filter = filter,
        .stats = .{ .x = inner.x, .y = y, .w = stats_width, .h = tables_height },
        .tables_divider = .{ .x = inner.x + stats_width, .y = y, .w = divider_size, .h = tables_height },
        .messages = .{ .x = messages_x, .y = y, .w = @max(inner.x + inner.w - messages_x, 0), .h = tables_height },
    };
}

/// The timeline's height out of `below_strip`: `dragged` if set, leaving the tables a title
/// and a couple of rows, or else what the lanes want, leaving the tables `min_table_rows`.
fn timelineHeight(below_strip: f32, snapshot: ?*const Snapshot, dragged: f32) f32 {
    const timeline_least = @min(timeline.ruler_height + timeline.lane_header_height + timeline.row_height, below_strip);
    if (dragged > 0) {
        const tables_smallest = widgets_bar_height + widget_title_height + 3 * row_height + 12;
        return @max(@min(dragged, below_strip - tables_smallest), timeline_least);
    }
    var lanes_wanted: f32 = timeline.lane_header_height + 4 * timeline.row_height;
    if (snapshot) |shown| {
        if (shown.lanes.len > 0) lanes_wanted = 0;
        for (shown.lanes) |lane| lanes_wanted += timeline.lane_header_height + @as(f32, @floatFromInt(@max(lane.depths.len, 1))) * timeline.row_height;
    }
    const tables_least = widgets_bar_height + widget_title_height + (min_table_rows + 1) * row_height + 8;
    const timeline_most = @max(below_strip - tables_least, below_strip * 0.35);
    return @min(timeline.ruler_height + lanes_wanted + 4, timeline_most);
}

/// The zones table's width out of `tables_width`, leaving each table `table_least_width`
/// while there is room for both.
fn zonesWidth(tables_width: f32, share: f32) f32 {
    const wanted = tables_width * std.math.clamp(share, 0, 1);
    if (tables_width < 2 * table_least_width) return wanted;
    return std.math.clamp(wanted, table_least_width, tables_width - table_least_width);
}

/// The panel the profiler draws in.
pub const panel_name = "profiler";

/// Where the profiler opens: below the panel that asked for it.
/// The profiler's panel, a fixed panel the workspaces system declares while it is shown: it
/// opens below the panel that asked for it.
pub const fixed_panel: plugin.panels.Open = .{ .id = panel, .title = "Profiler", .root = profiler_root, .side = .bottom, .share = 0.4 };

/// Shows the log file at `path` in the profiler's panel.
pub fn openLog(tables: *Table.Registry, atoms: *Atom.Registry, path: []const u8) void {
    profiler_api.request(tables.memory, tables, .{ .load_file = path });
    workspaces.showPanel(tables, atoms, panel, .beside_focused, .take);
}

/// The profiler panel's content, or null while it is closed or hidden.
fn contentOf(tables: *Table.Registry, atoms: *Atom.Registry) ?Rect {
    return panel_frame.contentRect(tables, atoms, panel);
}

pub fn isShown(tables: *Table.Registry, atoms: *Atom.Registry) bool {
    return contentOf(tables, atoms) != null;
}

/// Each lane's rectangle in the timeline: rows for its depths under a header, the last
/// lane taking what is left.
fn laneRects(snapshot: *const Snapshot, area: Rect, out: []Rect) []Rect {
    var y = area.y;
    const count = @min(snapshot.lanes.len, out.len);
    for (snapshot.lanes[0..count], 0..) |lane, index| {
        const wanted = timeline.lane_header_height + @as(f32, @floatFromInt(@max(lane.depths.len, 1))) * timeline.row_height;
        const last = index + 1 == count;
        const height = if (last) @max(area.y + area.h - y, 0) else @min(wanted, @max(area.y + area.h - y, 0));
        out[index] = .{ .x = area.x, .y = y, .w = area.w, .h = height };
        y += height;
    }
    return out[0..count];
}

/// The time the timeline shows: the frame, or the zoomed part of it.
fn viewOf(state: StateView, snapshot: *const Snapshot, width: f32) timeline.View {
    const begin: f64 = @floatFromInt(snapshot.begin_ns);
    const end: f64 = @floatFromInt(snapshot.end_ns);
    if (state.view_end.* <= state.view_begin.*) return .{ .begin_ns = begin, .end_ns = @max(end, begin + 1), .width = width };
    return .{ .begin_ns = begin + state.view_begin.*, .end_ns = begin + state.view_end.*, .width = width };
}

fn setView(state: StateView, snapshot: *const Snapshot, view: timeline.View) void {
    const begin: f64 = @floatFromInt(snapshot.begin_ns);
    state.view_begin.* = view.begin_ns - begin;
    state.view_end.* = view.end_ns - begin;
}

/// Whether the game runs live beyond what was recorded: recording is off, frames were
/// recorded, and none is held.
fn pastEnd(state: StateView, snapshot: ?*const Snapshot) bool {
    const shown = snapshot orelse return false;
    return state.recording.* == 0 and state.shown_frame.* == 0 and shown.frames.len > 0;
}

/// The recorded frame shown, as an index into the snapshot's frames.
fn shownIndex(state: StateView, snapshot: *const Snapshot) ?usize {
    if (snapshot.frames.len == 0) return null;
    if (state.shown_frame.* == 0) return snapshot.frames.len - 1;
    for (snapshot.frames, 0..) |frame, index| if (frame.index == state.shown_frame.*) return index;
    return snapshot.frames.len - 1;
}

// ---- recording and scrubbing -----------------------------------------------------------------

/// Starts a new recording, or stops and keeps the one going.
fn toggleRecording(state: StateView, out: Outbox) void {
    const on = state.recording.* == 0;
    state.recording.* = @intFromBool(on);
    if (on) {
        state.shown_frame.* = 0;
        resetFrameView(state);
    }
    profiler_api.request(out.memory, out.tables, .{ .record = on });
}

/// Holds `frame`: the timeline shows it, and capture pauses while it is held.
fn hold(state: StateView, frame: u64, out: Outbox) void {
    if (state.shown_frame.* == frame) return;
    resetFrameView(state);
    if (state.shown_frame.* == 0 and state.recording.* != 0) profiler_api.request(out.memory, out.tables, .{ .pause = true });
    state.shown_frame.* = frame;
}

/// Lets go of the frame held, forgetting the frames after it, and goes live; a recording
/// goes on from it.
fn goLive(state: StateView, out: Outbox) void {
    const frame = state.shown_frame.*;
    if (frame == 0) return;
    state.shown_frame.* = 0;
    resetFrameView(state);
    profiler_api.request(out.memory, out.tables, .{ .truncate_after = frame });
    if (state.recording.* != 0) profiler_api.request(out.memory, out.tables, .{ .pause = false });
}

fn resetFrameView(state: StateView) void {
    state.view_begin.* = 0;
    state.view_end.* = 0;
    state.selected_lane.* = -1;
    state.selected_message_ns.* = 0;
    state.selected_message_lane.* = -1;
    state.messages_scroll.* = 0;
}

/// Holds the frame `steps` away from the one shown; a step forward from the last recorded
/// frame held goes live.
fn step(state: StateView, snapshot: *const Snapshot, steps: i32, out: Outbox) void {
    const index = shownIndex(state, snapshot) orelse return;
    const held_last = state.shown_frame.* != 0 and index + 1 == snapshot.frames.len;
    if (steps > 0 and held_last) return goLive(state, out);
    const last: i64 = @intCast(snapshot.frames.len - 1);
    const target: usize = @intCast(std.math.clamp(@as(i64, @intCast(index)) + steps, 0, last));
    hold(state, snapshot.frames[target].index, out);
}

// ---- requests and input ------------------------------------------------------------------

/// Hears the pointer while shown, and typing while its filter has the focus.
fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    if (!isShown(tables, atoms)) return;
    try appendInput(pass, .{ .mouse_button_down = .{ .button = .left, .scope = .global } }, .profiler_press);
    try appendInput(pass, .{ .mouse_button_up = .{ .button = .left } }, .profiler_release);
    try appendInput(pass, .{ .mouse_move = .{ .scope = .global } }, .profiler_move);
    try appendInput(pass, .{ .mouse_scroll = .{ .scope = .global } }, .profiler_scroll);
    const state = try pass.readSingleton(state_table, StateView);
    if (state.filter_focused.* == 0 or !panels_mod.hasFocus(tables, atoms, panel)) return;
    try appendInput(pass, filter_field.text_subscription, .profiler_filter_text);
    try appendInput(pass, filter_field.key_subscription, .profiler_filter_key);
}

fn appendInput(pass: *sequencer.Pass, subscription: input.Subscription, message: Msg) !void {
    const tag = Atom.from(message);
    const subscriptions = try pass.writeTable(input_subscriptions);
    try input.appendSubscription(subscriptions, input.subscriptionRow(subscription, tag, .plugin, sequencer.inboxOf(system())));
}

/// One of the panel's messages, `state` being its row, already recorded for writing.
fn handle(pass: *sequencer.Pass, state: StateView, received: sequencer.Message) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    const out = outboxOf(pass);
    const message = received.tag.to(Msg);
    switch (message) {
        .profiler_toggle => workspaces.togglePanel(tables, atoms, panel),
        .profiler_snapshot => {
            const reply = try received.payloadAs(profiler_api.SnapshotMsg);
            state.snapshot_address.* = @intFromPtr(reply.snapshot);
            // A log file took the place of the recording: nothing records, and a frame held
            // from the recording is not one of the file's.
            const file_arrived = reply.snapshot.from_file and state.showing_file.* == 0;
            const file_left = !reply.snapshot.from_file and state.showing_file.* != 0;
            if (file_arrived or file_left) {
                state.showing_file.* = @intFromBool(reply.snapshot.from_file);
                state.recording.* = 0;
                state.shown_frame.* = 0;
                resetFrameView(state);
            }
        },
        .profiler_show_live => profiler_api.request(out.memory, out.tables, .show_live),
        // A divider's click only gives it its cursor; the press under it drags it.
        .profiler_divider => {},
        .profiler_filter_clear, .profiler_filter_text, .profiler_filter_key => {
            const owner = tables.findByName(state_table) orelse return;
            try handleFilter(state.filterField(owner), state, message, received);
        },
        .profiler_record => toggleRecording(state, out),
        .profiler_message_level => {
            state.message_levels.* ^= (try received.userDataAs(u8)).*;
            state.messages_scroll.* = 0;
        },
        .profiler_fit => {
            state.view_begin.* = 0;
            state.view_end.* = 0;
        },
        .profiler_sort => {
            const column = (try received.userDataAs(u8)).*;
            if (state.sort.* == column) state.sort_ascending.* ^= 1 else state.sort_ascending.* = @intFromBool(column == @intFromEnum(SortColumn.name));
            state.sort.* = column;
        },
        .profiler_highlight => {
            const name = (try received.userDataAs(u64)).*;
            const charted = state.chartSource() == .zone and state.chart_zone.* == name;
            if (state.highlight.* == name or charted) {
                state.highlight.* = 0;
                chartFrames(state);
            } else {
                state.highlight.* = name;
                chartZone(state, name);
            }
        },
        .profiler_step_back, .profiler_step_forward => {
            const snapshot = snapshotOf(state) orelse return;
            const steps: i32 = if (message == .profiler_step_back) -1 else 1;
            step(state, snapshot, steps, out);
        },
        .profiler_message_select => {
            const snapshot = snapshotOf(state) orelse return;
            const content = contentOf(tables, atoms) orelse return;
            const regions = regionsOf(content, snapshot, layoutOf(state));
            const ref = (try received.userDataAs(MessageRef)).*;
            selectMessage(state, ref.lane, ref.begin_ns);
            centreOn(state, snapshot, regions.timeline.w, ref.begin_ns);
        },
        .profiler_press, .profiler_release, .profiler_move, .profiler_scroll => try handlePointer(tables, atoms, state, message, received, out),
        _ => {},
    }
}

/// The pointer over the panel: a press first focuses or lets go of the filter, then a press,
/// move or release may be a divider's, whether or not anything has been recorded.
fn handlePointer(tables: *Table.Registry, atoms: *Atom.Registry, state: StateView, message: Msg, received: sequencer.Message, out: Outbox) !void {
    if (message == .profiler_press) {
        const pressed = try received.payloadAs(input.MouseButtonMsg);
        const content = contentOf(tables, atoms) orelse return;
        const filter_rect = regionsOf(content, snapshotOf(state), layoutOf(state)).filter;
        state.filter_focused.* = @intFromBool(filter_rect.contains(pressed.x, pressed.y));
    }
    if (contentOf(tables, atoms)) |content| {
        const regions = regionsOf(content, snapshotOf(state), layoutOf(state));
        if (try handleDivider(state, snapshotOf(state), regions, message, received)) return;
    }
    const snapshot = snapshotOf(state) orelse return;
    const content = contentOf(tables, atoms) orelse return;
    const regions = regionsOf(content, snapshot, layoutOf(state));
    switch (message) {
        .profiler_move => {
            const move = try received.payloadAs(input.MouseMoveMsg);
            onMove(state, snapshot, regions, move.x, move.y, out);
        },
        .profiler_scroll => {
            const scroll = try received.payloadAs(input.MouseScrollMsg);
            onScroll(state, snapshot, regions, scroll.pointer_x, scroll.pointer_y, scroll.y, out);
        },
        .profiler_press => {
            const pressed = try received.payloadAs(input.MouseButtonMsg);
            onPress(state, snapshot, regions, pressed.x, pressed.y, pressed.clicks, out);
        },
        .profiler_release => {
            const released = try received.payloadAs(input.MouseButtonMsg);
            onRelease(state, snapshot, regions, released.x, released.y);
        },
        else => unreachable,
    }
}

// ---- what the strip charts --------------------------------------------------------------

/// Charts `name`'s sorted statistic in the strip.
fn chartZone(state: StateView, name: u64) void {
    state.chart.* = @intFromEnum(ChartSource.zone);
    state.chart_zone.* = name;
}

/// Back to each frame's length, letting go of what was charted.
fn chartFrames(state: StateView) void {
    state.chart.* = @intFromEnum(ChartSource.frames);
    state.chart_zone.* = 0;
}

/// The filter's typing, keys and clear button; the press that focuses it is the panel's own.
fn handleFilter(field: filter_field.Field, state: StateView, message: Msg, received: sequencer.Message) !void {
    switch (message) {
        .profiler_filter_clear => {
            field.clear();
            scrollTablesToTop(state);
        },
        .profiler_filter_text => {
            const typed = try received.payloadAs(input.TextInputMsg);
            if (filter_field.typeText(field, typed)) scrollTablesToTop(state);
        },
        .profiler_filter_key => {
            const pressed = try received.payloadAs(input.KeyInputMsg);
            switch (filter_field.pressKey(field, pressed)) {
                .edited, .cancelled => scrollTablesToTop(state),
                .ignored, .submitted => {},
            }
        },
        else => unreachable,
    }
}

/// The filter narrows both tables, so a new filter shows each from its top.
fn scrollTablesToTop(state: StateView) void {
    state.stats_scroll.* = 0;
    state.messages_scroll.* = 0;
}

// ---- dividers -----------------------------------------------------------------------------

/// A press on a divider, and the moves and release of its drag, whether or not anything was
/// recorded. Returns false for other messages.
fn handleDivider(state: StateView, snapshot: ?*const Snapshot, regions: Regions, message: Msg, received: sequencer.Message) !bool {
    if (message == .profiler_press) {
        const pressed = try received.payloadAs(input.MouseButtonMsg);
        const divider = dividerAt(regions, pressed.x, pressed.y) orelse {
            // A drag whose release was missed, as when the panel was hidden, ends here.
            if (@as(Drag, @enumFromInt(state.drag.*)).divider() != null) state.drag.* = @intFromEnum(Drag.none);
            return false;
        };
        if (pressed.clicks >= 2) {
            halveDivider(state, snapshot, regions, divider);
            return true;
        }
        state.drag.* = @intFromEnum(divider.drag());
        state.drag_x.* = pressed.x;
        state.drag_y.* = pressed.y;
        state.drag_size.* = switch (divider) {
            .strip => regions.strip.h,
            .timeline => regions.timeline.h,
            .tables => regions.stats.w,
        };
        return true;
    }
    const drag: Drag = @enumFromInt(state.drag.*);
    const divider = drag.divider() orelse return false;
    if (message == .profiler_release) {
        state.drag.* = @intFromEnum(Drag.none);
        return true;
    }
    if (message != .profiler_move) return false;
    const move = try received.payloadAs(input.MouseMoveMsg);
    state.pointer_x.* = move.x;
    state.pointer_y.* = move.y;
    dragDivider(state, snapshot, regions, divider, move.x, move.y);
    return true;
}

fn dividerAt(regions: Regions, x: f32, y: f32) ?Divider {
    if (regions.strip_divider.contains(x, y)) return .strip;
    if (regions.timeline_divider.contains(x, y)) return .timeline;
    if (regions.tables_divider.contains(x, y)) return .tables;
    return null;
}

/// Moves `divider` with the pointer from where its drag started.
fn dragDivider(state: StateView, snapshot: ?*const Snapshot, regions: Regions, divider: Divider, x: f32, y: f32) void {
    const moved = switch (divider) {
        .strip, .timeline => y - state.drag_y.*,
        .tables => x - state.drag_x.*,
    };
    const size = state.drag_size.* + moved;
    resizeDivider(state, snapshot, regions, divider, size);
}

/// Splits the room `divider` divides in half: the strip and what is under it, the timeline
/// and the tables under it, or the two tables.
fn halveDivider(state: StateView, snapshot: ?*const Snapshot, regions: Regions, divider: Divider) void {
    const tables_bottom = regions.stats.y + regions.stats.h;
    const room = switch (divider) {
        .strip => tables_bottom - regions.strip.y - 2 * divider_size,
        .timeline => tables_bottom - regions.timeline.y - divider_size,
        .tables => regions.stats.w + regions.messages.w,
    };
    const size = @round(room * 0.5);
    resizeDivider(state, snapshot, regions, divider, size);
}

/// Puts `divider` `size` from the start of what it resizes: the strip's or the timeline's
/// height, or the zones table's width.
fn resizeDivider(state: StateView, snapshot: ?*const Snapshot, regions: Regions, divider: Divider, size: f32) void {
    const tables_width = @max(regions.stats.w + regions.messages.w, 1);
    switch (divider) {
        .strip => state.strip_height.* = size,
        // 0 would fit the lanes again.
        .timeline => state.timeline_height.* = @max(size, 1),
        .tables => state.zones_share.* = size / tables_width,
    }
    // Keep the size the panel settles on, so a drag past a limit moves the divider as soon
    // as it comes back.
    const settled = regionsOf(regions.content, snapshot, layoutOf(state));
    switch (divider) {
        .strip => state.strip_height.* = settled.strip.h,
        .timeline => state.timeline_height.* = @max(settled.timeline.h, 1),
        .tables => state.zones_share.* = settled.stats.w / tables_width,
    }
}

/// The recorded frame under `x` in the strip.
fn stripFrameAt(snapshot: *const Snapshot, strip: Rect, x: f32) ?usize {
    return timeline.FrameStripDrawable.frameAt(snapshot.frames, strip.w, std.math.clamp(x - strip.x, 0, @max(strip.w - 1, 0)));
}

fn onMove(state: StateView, snapshot: *const Snapshot, regions: Regions, x: f32, y: f32, out: Outbox) void {
    state.pointer_x.* = x;
    state.pointer_y.* = y;
    const dx = x - state.drag_x.*;
    const dy = y - state.drag_y.*;
    if (@abs(dx) > click_slop or @abs(dy) > click_slop) state.drag_moved.* = 1;
    switch (@as(Drag, @enumFromInt(state.drag.*))) {
        // A divider's drag is `handleDivider`'s.
        .none, .strip_divider, .timeline_divider, .tables_divider => {},
        .strip => if (stripFrameAt(snapshot, regions.strip, x)) |index| hold(state, snapshot.frames[index].index, out),
        .pan => {
            const begin: f64 = @floatFromInt(snapshot.begin_ns);
            const anchor: timeline.View = .{ .begin_ns = begin + state.drag_view_begin.*, .end_ns = begin + state.drag_view_end.*, .width = regions.timeline.w };
            setView(state, snapshot, anchor.panned(dx));
        },
    }
}

fn onScroll(state: StateView, snapshot: *const Snapshot, regions: Regions, x: f32, y: f32, notches: f32, out: Outbox) void {
    // Up steps back, or scrolls a list up.
    const lines: i32 = @intFromFloat(@round(-notches * 3));
    if (regions.strip.contains(x, y)) {
        step(state, snapshot, if (notches > 0) -1 else 1, out);
    } else if (regions.timeline.contains(x, y)) {
        const view = viewOf(state, snapshot, regions.timeline.w);
        setView(state, snapshot, view.zoomed(x - regions.timeline.x, std.math.pow(f64, 0.8, notches)));
    } else if (regions.stats.contains(x, y)) {
        state.stats_scroll.* = @max(state.stats_scroll.* + lines, 0);
    } else if (regions.messages.contains(x, y)) {
        state.messages_scroll.* = @max(state.messages_scroll.* + lines, 0);
    }
}

fn onPress(state: StateView, snapshot: *const Snapshot, regions: Regions, x: f32, y: f32, clicks: u8, out: Outbox) void {
    state.drag_x.* = x;
    state.drag_y.* = y;
    state.drag_moved.* = 0;
    if (regions.strip.contains(x, y)) {
        state.drag.* = @intFromEnum(Drag.strip);
        if (stripFrameAt(snapshot, regions.strip, x)) |index| hold(state, snapshot.frames[index].index, out);
        return;
    }
    if (!regions.timeline.contains(x, y)) return;
    if (clicks >= 2) {
        // A double click fits the view to the zone under it.
        const found = hitAt(snapshot, regions, viewOf(state, snapshot, regions.timeline.w), x, y) orelse return;
        const zones = found.lane.depths[found.hit.depth][found.hit.span.first..][0..found.hit.span.count];
        const begin: f64 = @floatFromInt(zones[0].begin_ns);
        const end: f64 = @floatFromInt(zones[zones.len - 1].endNs());
        const margin = (end - begin) * 0.05;
        setView(state, snapshot, .{ .begin_ns = begin - margin, .end_ns = end + margin, .width = regions.timeline.w });
        return;
    }
    setView(state, snapshot, viewOf(state, snapshot, regions.timeline.w));
    state.drag.* = @intFromEnum(Drag.pan);
    state.drag_view_begin.* = state.view_begin.*;
    state.drag_view_end.* = state.view_end.*;
}

fn onRelease(state: StateView, snapshot: *const Snapshot, regions: Regions, x: f32, y: f32) void {
    const drag: Drag = @enumFromInt(state.drag.*);
    state.drag.* = @intFromEnum(Drag.none);
    if (drag != .pan or state.drag_moved.* != 0) return;
    // Not moved: a click, which selects what is under it: a message's marker in a lane's
    // header, or a zone, which it charts.
    const view = viewOf(state, snapshot, regions.timeline.w);
    if (messageHitAt(state, snapshot, regions, view, x, y)) |hit| {
        selectMessage(state, hit.lane_index, hit.message.begin_ns);
        return;
    }
    const found = hitAt(snapshot, regions, view, x, y) orelse {
        state.selected_lane.* = -1;
        // The zone picked out in the table stays charted.
        if (state.chartSource() == .zone and state.highlight.* == 0) chartFrames(state);
        return;
    };
    if (found.hit.span.count != 1) return;
    const zone = found.lane.depths[found.hit.depth][found.hit.span.first];
    state.selected_lane.* = @intCast(found.lane_index);
    state.selected_depth.* = @intCast(found.hit.depth);
    state.selected_begin.* = zone.begin_ns;
    chartZone(state, zone.name);
}

const LaneHit = struct { lane_index: usize, lane: profiler_api.Lane, hit: timeline.Hit };

fn hitAt(snapshot: *const Snapshot, regions: Regions, view: timeline.View, x: f32, y: f32) ?LaneHit {
    var buffer: [8]Rect = undefined;
    for (laneRects(snapshot, regions.lanes, &buffer), 0..) |rect, index| {
        if (!rect.contains(x, y)) continue;
        const lane = snapshot.lanes[index];
        const hit = timeline.zoneAt(lane.depths, view, x - rect.x, y - rect.y - timeline.lane_header_height) orelse return null;
        return .{ .lane_index = index, .lane = lane, .hit = hit };
    }
    return null;
}

const MessageHit = struct { lane_index: usize, message: Message };

/// The shown message whose marker is under `x`, `y` in a lane's header, if any.
fn messageHitAt(state: StateView, snapshot: *const Snapshot, regions: Regions, view: timeline.View, x: f32, y: f32) ?MessageHit {
    var buffer: [8]Rect = undefined;
    for (laneRects(snapshot, regions.lanes, &buffer), 0..) |rect, index| {
        if (!rect.contains(x, y) or y - rect.y >= timeline.lane_header_height) continue;
        const messages = snapshot.lanes[index].messages;
        const found = timeline.messageAt(messages, view, state.message_levels.*, x - rect.x) orelse return null;
        return .{ .lane_index = index, .message = messages[found] };
    }
    return null;
}

fn selectMessage(state: StateView, lane_index: usize, begin_ns: u64) void {
    state.selected_message_ns.* = begin_ns;
    state.selected_message_lane.* = @intCast(lane_index);
}

/// Moves the timeline to put `ns` in its middle, keeping the zoom, but no further than the
/// frame's edges; from the whole frame it zooms in to an eighth of it, so what is around the
/// time can be told apart.
fn centreOn(state: StateView, snapshot: *const Snapshot, width: f32, ns: u64) void {
    const zoomed = state.view_end.* > state.view_begin.*;
    const view = viewOf(state, snapshot, width);
    const span = if (zoomed) view.end_ns - view.begin_ns else @max((view.end_ns - view.begin_ns) / 8, 20_000);
    const frame_begin: f64 = @floatFromInt(snapshot.begin_ns);
    const frame_end: f64 = @floatFromInt(snapshot.end_ns);
    const centre: f64 = @floatFromInt(ns);
    var begin = centre - span / 2;
    if (span <= frame_end - frame_begin) begin = std.math.clamp(begin, frame_begin, frame_end - span);
    setView(state, snapshot, .{ .begin_ns = begin, .end_ns = begin + span, .width = width });
}

/// The selected zone and its lane, while the snapshot still holds it.
fn selectedZone(state: StateView, snapshot: *const Snapshot) ?struct { lane: profiler_api.Lane, depth: usize, zone: Record } {
    if (state.selected_lane.* < 0) return null;
    const lane_index: usize = @intCast(state.selected_lane.*);
    if (lane_index >= snapshot.lanes.len) return null;
    const lane = snapshot.lanes[lane_index];
    const depth: usize = @intCast(state.selected_depth.*);
    const zone = timeline.findZone(lane.depths, depth, state.selected_begin.*) orelse return null;
    return .{ .lane = lane, .depth = depth, .zone = zone };
}

// ---- statistics ---------------------------------------------------------------------------

const Stat = struct { name: u64, scope: u32 = 0, count: u32 = 0, total_ns: u64 = 0, self_ns: u64 = 0, max_ns: u64 = 0 };

fn statsOf(allocator: std.mem.Allocator, snapshot: *const Snapshot) ![]Stat {
    var by_name: std.AutoArrayHashMapUnmanaged(u64, Stat) = .empty;
    for (snapshot.lanes) |lane| {
        for (lane.depths, 0..) |zones, depth| {
            for (zones) |zone| {
                const entry = try by_name.getOrPut(allocator, zone.name);
                if (!entry.found_existing) entry.value_ptr.* = .{ .name = zone.name, .scope = zone.scope };
                const stat = entry.value_ptr;
                stat.count += 1;
                stat.total_ns += zone.duration_ns;
                stat.self_ns += timeline.selfNs(lane.depths, depth, zone);
                stat.max_ns = @max(stat.max_ns, zone.duration_ns);
            }
        }
    }
    return by_name.values();
}

fn meanNs(stat: Stat) u64 {
    return if (stat.count == 0) 0 else stat.total_ns / stat.count;
}

const SortContext = struct { column: SortColumn, ascending: bool, snapshot: *const Snapshot };

fn statLess(context: SortContext, a: Stat, b: Stat) bool {
    return if (context.ascending) lessBy(context, a, b) else lessBy(context, b, a);
}

fn lessBy(context: SortContext, a: Stat, b: Stat) bool {
    return switch (context.column) {
        .name => std.mem.lessThan(u8, context.snapshot.zoneName(a.name), context.snapshot.zoneName(b.name)),
        .count => a.count < b.count,
        .total => a.total_ns < b.total_ns,
        .self => a.self_ns < b.self_ns,
        .mean => meanNs(a) < meanNs(b),
        .max => a.max_ns < b.max_ns,
    };
}

// ---- drawing ------------------------------------------------------------------------------

/// Draws the panel: its header, then the profile under it. `frame` is the panel's frame in
/// the window and `ctx` begins at its corner.
pub fn render(memory: *memory_mod.Memory, tables: *Table.Registry, atoms: *Atom.Registry, frame: plugin.Viewport, ctx: *roop.Context) void {
    panel_frame.drawPlainHeader(memory, tables, atoms, panel, frame, ctx);
    const viewport = panel_frame.beginContent(tables, atoms, panel, frame, ctx) orelse return;
    defer panel_frame.endContent(ctx);
    const state = stateOf(tables) orelse return;
    const scratch = memory.frameScratchAllocator() catch return;
    const allocator = scratch.allocator;
    const content: Rect = .{ .x = viewport.x, .y = viewport.y, .w = viewport.width, .h = viewport.height };
    const snapshot = snapshotOf(state);
    const regions = regionsOf(content, snapshot, layoutOf(state));
    const owner = tables.findByName(state_table) orelse return;
    const filter = state.filterField(owner);
    const query = filter.query();
    const vsync_ms: f64 = vsync.intervalMs(tables, atoms);
    const focused = panels_mod.hasFocus(tables, atoms, panel);
    var tree = ui.Tree.init(scratch, atoms, 4096) catch return;
    if (tree.beginRect("profiler", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .padding = padding, .gap = 0, .bg = style.col.sidebar, .clip_content = true })) {
        defer tree.endRect();
        renderToolbar(&tree, state, snapshot, vsync_ms, allocator);
        const strip = allocator.create(timeline.FrameStripDrawable) catch return;
        const frames: []const profiler_api.FrameSpan = if (snapshot) |shown| shown.frames else &.{};
        strip.* = .{
            .frames = frames,
            .shown = if (snapshot) |shown| shownIndex(state, shown) else null,
            .past_end = pastEnd(state, snapshot),
            .budget_ms = vsync_ms,
            // Room for the vsync bands and some way past them.
            .scale_ms = @max(vsync_ms * 4, vsync.band_limit_ms * 1.5),
            .font = style.ui_font,
            .chart = if (snapshot) |shown| chartOf(state, shown, allocator) else null,
            .message_levels = if (snapshot) |shown| shown.frame_message_levels else &.{},
        };
        tree.custom("profiler.strip", strip, .{ .size = .{ .w = .fill, .h = .{ .fixed = regions.strip.h } }, .clip_content = true });
        renderDivider(&tree, "profiler.strip_divider", state, .strip, regions.strip_divider);
        renderTimeline(&tree, state, snapshot, regions, query, allocator);
        renderDivider(&tree, "profiler.timeline_divider", state, .timeline, regions.timeline_divider);
        renderWidgetsBar(&tree, state, filter, snapshot, regions, focused, allocator);
        if (tree.beginRect("profiler.widgets", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = regions.stats.h } }, .gap = 0 })) {
            defer tree.endRect();
            renderStats(&tree, state, snapshot, regions.stats, query, allocator);
            renderDivider(&tree, "profiler.tables_divider", state, .tables, regions.tables_divider);
            renderMessages(&tree, state, snapshot, regions.messages, query, allocator);
        }
    }
    tree.commit(.{
        .root_size = .{ .x = viewport.width, .y = viewport.height },
        .offset = .{ .x = viewport.x, .y = viewport.y },
        .hovered = editor_state.hoveredElementId(tables),
        .depth = hit_depth,
    }, ctx, editor_state.hitRegions(tables, atoms));
}

/// A divider, lit while hovered or dragged, with the cursor that says which way it moves.
fn renderDivider(tree: *ui.Tree, id: []const u8, state: StateView, divider: Divider, rect: Rect) void {
    const dragged = @as(Drag, @enumFromInt(state.drag.*)).divider() == divider;
    const size: ui.Size = switch (divider) {
        .strip, .timeline => .{ .w = .fill, .h = .{ .fixed = rect.h } },
        .tables => .{ .w = .{ .fixed = rect.w }, .h = .fill },
    };
    if (!tree.beginRect(id, .{
        .size = size,
        .bg = if (dragged) style.col.accent_deep else null,
        .bg_hover = style.col.tab_hover,
        .corner_radius = 2,
        .cursor = switch (divider) {
            .strip, .timeline => .resize_ns,
            .tables => .resize_ew,
        },
    })) return;
    defer tree.endRect();
    tree.onClick(editor_sequencer.to(tree, system(), .from(Msg.profiler_divider), {}), .left);
    tree.trackHover("Drag to resize, double-click to split in half");
}

/// What the strip charts instead of frame lengths, if anything: the charted zone's sorted
/// statistic, a value per recorded frame.
fn chartOf(state: StateView, snapshot: *const Snapshot, allocator: std.mem.Allocator) ?timeline.FrameStripDrawable.Chart {
    return switch (state.chartSource()) {
        .frames => null,
        .zone => zoneChart(state, snapshot, allocator),
    };
}

fn zoneChart(state: StateView, snapshot: *const Snapshot, allocator: std.mem.Allocator) ?timeline.FrameStripDrawable.Chart {
    // A snapshot asked for before the zone was chosen has another series, or none.
    if (snapshot.series_name != state.chart_zone.* or snapshot.series.len != snapshot.frames.len) return null;
    const column: SortColumn = std.enums.fromInt(SortColumn, state.sort.*) orelse .total;
    const values = allocator.alloc(f64, snapshot.series.len) catch return null;
    var largest: f64 = 0;
    for (snapshot.series, values) |totals, *value| {
        value.* = switch (column) {
            .count => @floatFromInt(totals.count),
            .name, .total => timeline.milliseconds(totals.total_ns),
            .self => timeline.milliseconds(totals.self_ns),
            .mean => if (totals.count == 0) 0 else timeline.milliseconds(totals.total_ns) / @as(f64, @floatFromInt(totals.count)),
            .max => timeline.milliseconds(totals.max_ns),
        };
        largest = @max(largest, value.*);
    }
    const statistic = switch (column) {
        .count => "count",
        .name, .total => "total ms",
        .self => "self ms",
        .mean => "mean ms",
        .max => "max ms",
    };
    const name = snapshot.zoneName(state.chart_zone.*);
    const label = if (column == .count)
        std.fmt.allocPrint(allocator, "{s}: {s} per frame, up to {d:.0}", .{ name, statistic, largest }) catch ""
    else
        std.fmt.allocPrint(allocator, "{s}: {s} per frame, up to {d:.3}", .{ name, statistic, largest }) catch "";
    const scope = snapshot.zoneScope(state.chart_zone.*);
    return .{ .values = values, .label = label, .color = timeline.colorOf(scope) };
}

/// The filter over the tables, and a button per message level that shows or hides it,
/// with how many the frame logged.
fn renderWidgetsBar(tree: *ui.Tree, state: StateView, filter: filter_field.Field, snapshot: ?*const Snapshot, regions: Regions, focused: bool, allocator: std.mem.Allocator) void {
    if (!tree.beginRect("profiler.widgets_bar", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = regions.widgets_bar.h } }, .padding = 4, .gap = 6 })) return;
    defer tree.endRect();
    const caret: filter_field.Caret = if (focused) .shown else .hidden;
    const filter_style = style.filterFieldStyle();
    filter_field.render(tree, "profiler.filter", filter, "Filter zones and messages", .{ .w = .{ .fixed = regions.filter.w }, .h = .{ .fixed = regions.filter.h } }, caret, editor_sequencer.to(tree, system(), .from(Msg.profiler_filter_clear), {}), null, filter_style);
    tree.rect("profiler.widgets_bar.gap", .{ .size = .{ .w = .{ .fixed = 6 }, .h = .fill } });
    var counts: [4]usize = @splat(0);
    if (snapshot) |shown| {
        for (shown.lanes) |lane| {
            for (lane.messages) |message| counts[@intFromEnum(timeline.LevelGroup.of(message.level))] += 1;
        }
    }
    const groups = [_]struct { group: timeline.LevelGroup, label: []const u8, tooltip: []const u8 }{
        .{ .group = .err, .label = "Errors", .tooltip = "Show or hide errors in the lanes and the messages" },
        .{ .group = .warn, .label = "Warnings", .tooltip = "Show or hide warnings in the lanes and the messages" },
        .{ .group = .info, .label = "Info", .tooltip = "Show or hide info messages in the lanes and the messages" },
        .{ .group = .debug, .label = "Debug", .tooltip = "Show or hide debug and trace messages in the lanes and the messages" },
    };
    for (groups) |entry| {
        const count = counts[@intFromEnum(entry.group)];
        const label = std.fmt.allocPrint(allocator, "{s} {d}", .{ entry.label, count }) catch entry.label;
        const shown = state.message_levels.* & entry.group.bit() != 0;
        const bit: u8 = entry.group.bit();
        button.render(tree, .{ "profiler.level", @intFromEnum(entry.group) }, editor_sequencer.to(tree, system(), .from(Msg.profiler_message_level), bit), .{ .label = label, .tooltip = entry.tooltip, .variant = .text_only, .selected = shown, .size = .{ .w = .{ .fixed = 96 }, .h = .{ .fixed = 26 } } });
    }
}

/// Opens a titled table of fixed width with `count` beside its title. Pair a true result
/// with `tree.endRect()`.
fn beginWidget(tree: *ui.Tree, id: []const u8, title: []const u8, count: []const u8, width: f32) bool {
    if (!tree.beginRect(id, .{ .axis = .vertical, .size = .{ .w = .{ .fixed = width }, .h = .fill }, .padding = 6, .gap = 0, .bg = style.col.inset, .corner_radius = 4, .clip_content = true })) return false;
    if (tree.beginRect(.{ id, @as(u32, 1) }, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = widget_title_height } }, .gap = 8 })) {
        defer tree.endRect();
        tree.text(.{ id, @as(u32, 2) }, title, .{ .font = style.ui_font, .color = style.col.text });
        tree.text(.{ id, @as(u32, 3) }, count, .{ .font = style.ui_font, .color = style.col.text_disabled });
    }
    return true;
}

/// Table rows that fit in `area` under the title and the column headings.
fn tableRows(area: Rect) usize {
    return @intFromFloat(@max(@floor((area.h - 12 - widget_title_height - row_height) / row_height), 0));
}

fn renderToolbar(tree: *ui.Tree, state: StateView, snapshot: ?*const Snapshot, vsync_ms: f64, allocator: std.mem.Allocator) void {
    if (!tree.beginRect("profiler.toolbar", .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = toolbar_height } }, .gap = 4, .clip_content = true })) return;
    defer tree.endRect();
    const recording = state.recording.* != 0;
    const has_frames = snapshot != null and snapshot.?.frames.len > 0;
    button.render(tree, "profiler.record", editor_sequencer.to(tree, system(), .from(Msg.profiler_record), {}), .{ .icon = .record, .variant = .icon_only, .tooltip = if (recording) "Stop recording" else "Record frames", .selected = recording });
    button.render(tree, "profiler.back", editor_sequencer.to(tree, system(), .from(Msg.profiler_step_back), {}), .{ .icon = .skip_previous, .variant = .icon_only, .tooltip = "Step back a frame", .enabled = has_frames });
    const held_last = has_frames and state.shown_frame.* != 0 and shownIndex(state, snapshot.?) == snapshot.?.frames.len - 1;
    const forward_tooltip = if (held_last) "Go live from the last recorded frame" else "Step forward a frame";
    button.render(tree, "profiler.forward", editor_sequencer.to(tree, system(), .from(Msg.profiler_step_forward), {}), .{ .icon = .skip_next, .variant = .icon_only, .tooltip = forward_tooltip, .enabled = has_frames });
    tree.rect("profiler.toolbar.gap", .{ .size = .{ .w = .{ .fixed = 8 }, .h = .fill } });
    const load_failure: profiler_api.LoadFailure = if (snapshot) |latest| latest.load_failure else .none;
    const failure_text: []const u8 = switch (load_failure) {
        .none => "",
        .unreadable => "That file could not be read as a log.",
        .no_zones => "That log has no zones: it was written while the profiler was not recording.",
    };
    if (failure_text.len != 0) tree.text("profiler.load_failure", failure_text, .{ .font = style.ui_font, .color = style.col.danger });
    if (!has_frames) {
        const hint = if (recording) "Recording: frames appear here as they are captured" else "Press record to capture frames, then scrub them in the strip below";
        tree.text("profiler.hint", hint, .{ .font = style.ui_font, .color = style.col.text_dim });
        return;
    }
    const shown = snapshot.?;
    const frame_ms = timeline.milliseconds(shown.end_ns -| shown.begin_ns);
    // A frame longer than a display refresh missed vsync.
    const over_budget = frame_ms > vsync_ms * 1.02;
    const status = if (shown.from_file) "log file" else if (pastEnd(state, snapshot)) "live, not recording" else if (recording and state.shown_frame.* == 0) "recording" else "held";
    const frame_label = std.fmt.allocPrint(allocator, "Frame {d}", .{shown.first_frame}) catch "";
    tree.text("profiler.frame", frame_label, .{ .font = style.ui_font, .color = style.col.text });
    const ms_label = std.fmt.allocPrint(allocator, "{d:.2} ms", .{frame_ms}) catch "";
    tree.text("profiler.frame_ms", ms_label, .{ .font = style.ui_font, .color = if (over_budget) style.col.danger else style.col.success });
    tree.text("profiler.status", status, .{ .font = style.ui_font, .color = style.col.text_disabled });
    if (shown.from_file) button.render(tree, "profiler.live", editor_sequencer.to(tree, system(), .from(Msg.profiler_show_live), {}), .{ .label = "Live", .tooltip = "Leave the log file and show the engine", .variant = .text_only, .size = .{ .w = .{ .fixed = 48 }, .h = .{ .fixed = 28 } } });
    tree.rect("profiler.toolbar.gap2", .{ .size = .{ .w = .{ .fixed = 8 }, .h = .fill } });
    button.render(tree, "profiler.fit", editor_sequencer.to(tree, system(), .from(Msg.profiler_fit), {}), .{ .label = "Fit", .tooltip = "Show the whole frame", .variant = .text_only, .size = .{ .w = .{ .fixed = 48 }, .h = .{ .fixed = 28 } } });
    const selected = selectedZone(state, shown) orelse return;
    const name = shown.zoneName(selected.zone.name);
    const self_ns = timeline.selfNs(selected.lane.depths, selected.depth, selected.zone);
    tree.rect("profiler.toolbar.gap3", .{ .size = .{ .w = .{ .fixed = 8 }, .h = .fill } });
    tree.text("profiler.selected.name", name, .{ .font = style.ui_font, .color = style.col.accent_bright });
    const detail = std.fmt.allocPrint(allocator, "{d:.3} ms, self {d:.3} ms", .{ timeline.milliseconds(selected.zone.duration_ns), timeline.milliseconds(self_ns) }) catch return;
    tree.text("profiler.selected", detail, .{ .font = style.ui_font, .color = style.col.text_dim });
}

fn renderTimeline(tree: *ui.Tree, state: StateView, snapshot: ?*const Snapshot, regions: Regions, query: []const u8, allocator: std.mem.Allocator) void {
    if (!tree.beginRect("profiler.timeline", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .{ .fixed = regions.timeline.h } }, .gap = 0, .bg = style.col.inset, .clip_content = true })) return;
    defer tree.endRect();
    const shown = snapshot orelse return emptyTimeline(tree, "Nothing recorded yet");
    if (shown.frames.len == 0 or shown.lanes.len == 0) return emptyTimeline(tree, if (state.recording.* != 0) "Waiting for the first recorded frame" else "Nothing recorded yet");
    const view = viewOf(state, shown, regions.timeline.w);
    const pointer: math.Vec2f = .{ .x = state.pointer_x.*, .y = state.pointer_y.* };
    const scrubbing = @as(Drag, @enumFromInt(state.drag.*)) == .strip;
    const cursor_x: ?f32 = if (regions.timeline.contains(pointer.x, pointer.y) and !scrubbing) pointer.x - regions.timeline.x else null;
    const ruler = allocator.create(timeline.RulerDrawable) catch return;
    ruler.* = .{ .view = view, .frame_begin_ns = @floatFromInt(shown.begin_ns), .font = style.ui_font, .cursor_x = cursor_x };
    tree.custom("profiler.ruler", ruler, .{ .size = .{ .w = .fill, .h = .{ .fixed = regions.ruler.h } }, .clip_content = true });
    var buffer: [8]Rect = undefined;
    const selected = selectedZone(state, shown);
    for (laneRects(shown, regions.lanes, &buffer), 0..) |rect, index| {
        const lane = allocator.create(timeline.LaneDrawable) catch return;
        const over = rect.contains(pointer.x, pointer.y) and @as(Drag, @enumFromInt(state.drag.*)) == .none;
        lane.* = .{
            .lane = shown.lanes[index],
            .view = view,
            .names = shown,
            .font = style.ui_font,
            .highlight = state.highlight.*,
            .filter = query,
            .pointer = if (over) .{ .x = pointer.x - rect.x, .y = pointer.y - rect.y } else null,
            .selected = if (selected != null and state.selected_lane.* == @as(i32, @intCast(index))) .{ .depth = selected.?.depth, .begin_ns = selected.?.zone.begin_ns } else null,
            .message_levels = state.message_levels.*,
            .selected_message_ns = if (state.selected_message_ns.* != 0) state.selected_message_ns.* else null,
            .cursor_x = cursor_x,
        };
        tree.custom(.{ "profiler.lane", index }, lane, .{ .size = .{ .w = .fill, .h = .{ .fixed = rect.h } }, .clip_content = true });
    }
}

fn emptyTimeline(tree: *ui.Tree, text: []const u8) void {
    if (!tree.beginRect("profiler.timeline.empty", .{ .axis = .horizontal, .cross_align = .center, .main_align = .center, .size = .{ .w = .fill, .h = .fill } })) return;
    defer tree.endRect();
    tree.text("profiler.timeline.empty.text", text, .{ .font = style.ui_font, .color = style.col.text_disabled });
}

/// A column of the zones table: its heading, width (0 takes what is left), and the order
/// a click on its heading sorts by, if any.
const StatColumn = struct { title: []const u8, width: f32, sort: ?SortColumn };

const stat_columns = [_]StatColumn{
    .{ .title = "Zone", .width = 0, .sort = .name },
    .{ .title = "Share of frame", .width = 110, .sort = .total },
    .{ .title = "Count", .width = 52, .sort = .count },
    .{ .title = "Total ms", .width = 70, .sort = .total },
    .{ .title = "Self ms", .width = 70, .sort = .self },
    .{ .title = "Mean ms", .width = 70, .sort = .mean },
    .{ .title = "Max ms", .width = 70, .sort = .max },
};

/// Every zone name in the frame that the filter leaves, sorted, a row each; a click picks
/// the zone out in the lanes.
fn renderStats(tree: *ui.Tree, state: StateView, snapshot: ?*const Snapshot, area: Rect, query: []const u8, allocator: std.mem.Allocator) void {
    // Stats come only from a snapshot, so a stat's names are always the snapshot's.
    const all: []Stat = if (snapshot) |shown| statsOf(allocator, shown) catch return else &.{};
    var stats: std.ArrayList(Stat) = .empty;
    for (all) |stat| {
        const name = snapshot.?.zoneName(stat.name);
        if (filter_field.matches(query, name)) stats.append(allocator, stat) catch return;
    }
    const column: SortColumn = std.enums.fromInt(SortColumn, state.sort.*) orelse .total;
    if (snapshot) |shown| std.mem.sort(Stat, stats.items, SortContext{ .column = column, .ascending = state.sort_ascending.* != 0, .snapshot = shown }, statLess);
    const count_label = if (query.len == 0)
        std.fmt.allocPrint(allocator, "{d}", .{all.len}) catch ""
    else
        std.fmt.allocPrint(allocator, "{d} of {d}", .{ stats.items.len, all.len }) catch "";
    if (!beginWidget(tree, "profiler.zones", "Zones", count_label, area.w)) return;
    defer tree.endRect();
    if (tree.beginRect("profiler.stats.header", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .gap = 0 })) {
        defer tree.endRect();
        for (stat_columns, 0..) |entry, index| {
            const sorted = entry.sort != null and entry.sort.? == column and !(index == 1);
            const arrow = if (state.sort_ascending.* != 0) " ^" else " v";
            const label = if (sorted) std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.title, arrow }) catch entry.title else entry.title;
            const click: ?ui.Target = if (entry.sort) |order| editor_sequencer.to(tree, system(), .from(Msg.profiler_sort), @as(u8, @intFromEnum(order))) else null;
            statCell(tree, .{ "profiler.stats.title", index }, label, entry.width, if (sorted) style.col.text else style.col.text_disabled, click);
        }
        tree.rect("profiler.stats.header.bar", .{ .size = .{ .w = .{ .fixed = scrollbar_width }, .h = .fill } });
    }
    const frame_ns: f64 = if (snapshot) |shown| @floatFromInt(@max(shown.end_ns -| shown.begin_ns, 1)) else 1;
    const rows = tableRows(area);
    const most = stats.items.len -| rows;
    state.stats_scroll.* = @intCast(@min(@as(usize, @intCast(@max(state.stats_scroll.*, 0))), most));
    const skip: usize = @intCast(state.stats_scroll.*);
    if (!tree.beginRect("profiler.stats.body", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .fill }, .gap = 0 })) return;
    defer tree.endRect();
    if (tree.beginRect("profiler.stats.rows", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .gap = 0, .clip_content = true })) {
        defer tree.endRect();
        if (stats.items.len == 0) {
            const empty = if (snapshot == null or all.len == 0) "No zones in this frame" else "No zone matches the filter";
            tableHint(tree, "profiler.stats.empty", empty);
        }
        for (stats.items[skip..][0..@min(rows, stats.items.len - skip)], 0..) |stat, index| {
            const charted = state.chartSource() == .zone and state.chart_zone.* == stat.name;
            const highlighted = state.highlight.* == stat.name or charted;
            const id = .{ "profiler.stats.row", index };
            if (!tree.beginRect(id, .{
                .axis = .horizontal,
                .size = .{ .w = .fill, .h = .{ .fixed = row_height } },
                .gap = 0,
                .bg = if (highlighted) style.col.accent_deep else if ((skip + index) % 2 == 0) ui.rgba(255, 255, 255, 6) else null,
                .bg_hover = if (highlighted) style.col.accent_deep else style.col.card_hover,
                .corner_radius = 3,
            })) continue;
            defer tree.endRect();
            tree.onClick(editor_sequencer.to(tree, system(), .from(Msg.profiler_highlight), stat.name), .left);
            tree.trackHover(if (highlighted) "Stop charting this zone" else "Chart this zone and pick it out in the timeline");
            const name = snapshot.?.zoneName(stat.name);
            statCell(tree, .{ "profiler.stats.name", index }, name, 0, style.col.text, null);
            const share: f32 = @floatCast(@as(f64, @floatFromInt(stat.total_ns)) / frame_ns);
            if (tree.beginRect(.{ "profiler.stats.share", index }, .{ .axis = .horizontal, .size = .{ .w = .{ .fixed = stat_columns[1].width }, .h = .fill }, .padding = 2 })) {
                defer tree.endRect();
                const bar_color = timeline.colorOf(stat.scope);
                marks.place(tree, .{ "profiler.stats.share.bar", index }, marks.ShareBar{ .fraction = share, .color = bar_color }, stat_columns[1].width - 4);
            }
            const cells = [_][]const u8{
                std.fmt.allocPrint(allocator, "{d}", .{stat.count}) catch "",
                std.fmt.allocPrint(allocator, "{d:.3}", .{timeline.milliseconds(stat.total_ns)}) catch "",
                std.fmt.allocPrint(allocator, "{d:.3}", .{timeline.milliseconds(stat.self_ns)}) catch "",
                std.fmt.allocPrint(allocator, "{d:.3}", .{timeline.milliseconds(meanNs(stat))}) catch "",
                std.fmt.allocPrint(allocator, "{d:.3}", .{timeline.milliseconds(stat.max_ns)}) catch "",
            };
            for (cells, stat_columns[2..], 0..) |cell, entry, cell_index| statCell(tree, .{ "profiler.stats.cell", index * 8 + cell_index }, cell, entry.width, style.col.text_dim, null);
        }
    }
    marks.place(tree, "profiler.stats.scrollbar", marks.ScrollBar{ .first = skip, .visible = rows, .total = stats.items.len }, scrollbar_width);
}

const scrollbar_width: f32 = 8;

/// A message of the shown frame and the lane it is in.
const MessageRow = struct { message: Message, lane_index: usize };

/// The frame's messages that the levels and the filter leave, in time order; `total` is
/// set to how many the frame has.
fn messageRows(allocator: std.mem.Allocator, snapshot: *const Snapshot, levels: u8, query: []const u8, total: *usize) ![]MessageRow {
    var rows: std.ArrayList(MessageRow) = .empty;
    total.* = 0;
    for (snapshot.lanes, 0..) |lane, lane_index| {
        total.* += lane.messages.len;
        for (lane.messages) |message| {
            if (!timeline.levelShown(levels, message.level)) continue;
            const scope_name = snapshot.scopeName(message.scope);
            if (!filter_field.matches(query, message.text) and !filter_field.matches(query, scope_name)) continue;
            try rows.append(allocator, .{ .message = message, .lane_index = lane_index });
        }
    }
    std.mem.sort(MessageRow, rows.items, {}, messageEarlier);
    return rows.items;
}

fn messageEarlier(_: void, a: MessageRow, b: MessageRow) bool {
    return a.message.begin_ns < b.message.begin_ns;
}

const message_columns = [_]StatColumn{
    .{ .title = "Time ms", .width = 64, .sort = null },
    .{ .title = "Thread", .width = 64, .sort = null },
    .{ .title = "Level", .width = 46, .sort = null },
    .{ .title = "Scope", .width = 96, .sort = null },
    .{ .title = "Message", .width = 0, .sort = null },
};

/// The frame's log messages, a row each in time order; a click selects the message and
/// centres the timeline on it.
fn renderMessages(tree: *ui.Tree, state: StateView, snapshot: ?*const Snapshot, area: Rect, query: []const u8, allocator: std.mem.Allocator) void {
    var total: usize = 0;
    const rows: []MessageRow = if (snapshot) |shown| messageRows(allocator, shown, state.message_levels.*, query, &total) catch return else &.{};
    const count_label = if (rows.len == total)
        std.fmt.allocPrint(allocator, "{d}", .{total}) catch ""
    else
        std.fmt.allocPrint(allocator, "{d} of {d}", .{ rows.len, total }) catch "";
    if (!beginWidget(tree, "profiler.messages", "Messages", count_label, area.w)) return;
    defer tree.endRect();
    if (tree.beginRect("profiler.messages.header", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .gap = 0 })) {
        defer tree.endRect();
        for (message_columns, 0..) |entry, index| statCell(tree, .{ "profiler.messages.title", index }, entry.title, entry.width, style.col.text_disabled, null);
        tree.rect("profiler.messages.header.bar", .{ .size = .{ .w = .{ .fixed = scrollbar_width }, .h = .fill } });
    }
    const visible = tableRows(area);
    const most = rows.len -| visible;
    state.messages_scroll.* = @intCast(@min(@as(usize, @intCast(@max(state.messages_scroll.*, 0))), most));
    const skip: usize = @intCast(state.messages_scroll.*);
    if (!tree.beginRect("profiler.messages.body", .{ .axis = .horizontal, .size = .{ .w = .fill, .h = .fill }, .gap = 0 })) return;
    defer tree.endRect();
    if (tree.beginRect("profiler.messages.rows", .{ .axis = .vertical, .size = .{ .w = .fill, .h = .fill }, .gap = 0, .clip_content = true })) {
        defer tree.endRect();
        if (rows.len == 0) {
            const empty = if (total == 0) "No messages logged in this frame" else "No message matches the filter and levels";
            tableHint(tree, "profiler.messages.empty", empty);
        }
        const shown = snapshot orelse return;
        for (rows[skip..][0..@min(visible, rows.len - skip)], 0..) |row, index| {
            const message = row.message;
            const selected = state.selected_message_ns.* == message.begin_ns and state.selected_message_lane.* == @as(i32, @intCast(row.lane_index));
            if (!tree.beginRect(.{ "profiler.messages.row", index }, .{
                .axis = .horizontal,
                .size = .{ .w = .fill, .h = .{ .fixed = row_height } },
                .gap = 0,
                .bg = if (selected) style.col.accent_deep else if ((skip + index) % 2 == 0) ui.rgba(255, 255, 255, 6) else null,
                .bg_hover = if (selected) style.col.accent_deep else style.col.card_hover,
                .corner_radius = 3,
            })) continue;
            defer tree.endRect();
            const ref: MessageRef = .{ .begin_ns = message.begin_ns, .lane = @intCast(row.lane_index) };
            tree.onClick(editor_sequencer.to(tree, system(), .from(Msg.profiler_message_select), ref), .left);
            tree.trackHover("Find this message in the timeline");
            const time_ms = timeline.milliseconds(message.begin_ns -| shown.begin_ns);
            const level_color = timeline.messageColor(message.level);
            const cells = [_]struct { text: []const u8, color: ui.Color }{
                .{ .text = std.fmt.allocPrint(allocator, "{d:.3}", .{time_ms}) catch "", .color = style.col.text_dim },
                .{ .text = shown.lanes[row.lane_index].name, .color = style.col.text_dim },
                .{ .text = timeline.levelName(message.level), .color = level_color },
                .{ .text = shown.scopeName(message.scope), .color = style.col.text_dim },
                .{ .text = message.text, .color = style.col.text },
            };
            for (cells, message_columns, 0..) |cell, entry, cell_index| statCell(tree, .{ "profiler.messages.cell", index * 8 + cell_index }, cell.text, entry.width, cell.color, null);
        }
    }
    marks.place(tree, "profiler.messages.scrollbar", marks.ScrollBar{ .first = skip, .visible = visible, .total = rows.len }, scrollbar_width);
}

fn tableHint(tree: *ui.Tree, id: []const u8, text: []const u8) void {
    if (!tree.beginRect(.{ id, @as(u32, 0) }, .{ .axis = .horizontal, .cross_align = .center, .size = .{ .w = .fill, .h = .{ .fixed = row_height } }, .padding = 4 })) return;
    defer tree.endRect();
    tree.text(id, text, .{ .font = style.ui_font, .color = style.col.text_disabled });
}

/// A cell of a table; width 0 takes the room the others leave.
fn statCell(tree: *ui.Tree, id: anytype, text: []const u8, width: f32, color: ui.Color, click: ?ui.Target) void {
    const size: ui.Size = .{ .w = if (width == 0) .fill else .{ .fixed = width }, .h = .fill };
    if (!tree.beginRect(id, .{ .axis = .horizontal, .cross_align = .center, .size = size, .padding = 4, .clip_content = true, .bg_hover = if (click != null) style.col.tab_hover else null, .corner_radius = 3 })) return;
    defer tree.endRect();
    if (click) |target| {
        tree.onClick(target, .left);
        tree.trackHover("Sort by this column");
    }
    tree.text(.{ id, @as(u32, 1) }, text, .{ .font = style.ui_font, .color = color });
}
