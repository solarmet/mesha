//! Animate session policy. All authoring is typed commands on the existing journal.
const std = @import("std");
const mesha = @import("mesha");
const modes = @import("../modes.zig");
const zon = mesha.zon;
const Atom = mesha.Atom;
const names = @import("names.zig");
const memory = mesha.memory;
const Table = mesha.Table;
const plugin = mesha.plugin;
const panels_mod = mesha.panels;
const workspaces = @import("../workspaces.zig");
const roop = mesha.roop;
const figure = mesha.figure;
const gesture = @import("gesture.zig");
const weight = @import("weight.zig");
const geometry = @import("geometry.zig");
const session = @import("session.zig");
const watches = @import("watches.zig");
const style = @import("../ui/style.zig");
const preview = @import("preview.zig");
const prompts = @import("prompts.zig");
const transport = @import("commands.zig");
const clip_sequencer = @import("sequencer.zig");
const api = plugin.figure_api;

const time = mesha.time;
const sequencer = mesha.sequencer;
const workspace = @import("workspace.zig");

// ---- the system -----------------------------------------------------------------------------

/// Animating: clips, keys and frames, playback on the time system's frames, and the edits
/// to a clip it sends the host as one transaction, settled after the frame's gestures.
pub fn system() sequencer.System {
    return .{
        .name = "figure_animation",
        .names = comptime &workspace.vocabulary,
        .root = workspace.figure_root,
        .claims = claims,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "figure_animation.tick", .run = playFrames },
            .{ .name = "figure_animation.take_actions", .run = takeActions },
            .{ .name = "figure_animation.settle", .run = settleKernel },
            .{ .name = "figure_animation.subscribe", .run = subscribe },
        },
    };
}

const time_subscriptions = Atom.from(time.subscriptions_table_name);

/// The tags of the animation's actions, and of the time system's frames it plays by.
pub const Msg = enum(u64) {
    figure_animation_frame = Atom.from("figure_animation_frame").value(),
    figure_mode_animate = Atom.from("figure_mode_animate").value(),
    figure_play_pause = Atom.from("figure_play_pause").value(),
    figure_frame_previous = Atom.from("figure_frame_previous").value(),
    figure_frame_next = Atom.from("figure_frame_next").value(),
    figure_frame_seek = Atom.from("figure_frame_seek").value(),
    figure_clip_select = Atom.from("figure_clip_select").value(),
    figure_clip_loop = Atom.from("figure_clip_loop").value(),
    figure_clip_fps = Atom.from("figure_clip_fps").value(),
    figure_clip_length = Atom.from("figure_clip_length").value(),
    figure_clip_add = Atom.from("figure_clip_add").value(),
    figure_clip_rename = Atom.from("figure_clip_rename").value(),
    figure_clip_duplicate = Atom.from("figure_clip_duplicate").value(),
    figure_clip_delete = Atom.from("figure_clip_delete").value(),
    figure_key_add = Atom.from("figure_key_add").value(),
    figure_key_delete = Atom.from("figure_key_delete").value(),
    figure_key_easing = Atom.from("figure_key_easing").value(),
    figure_key_hold = Atom.from("figure_key_hold").value(),
    figure_toggle_onion = Atom.from("figure_toggle_onion").value(),
    figure_strip_previous = Atom.from("figure_strip_previous").value(),
    figure_strip_next = Atom.from("figure_strip_next").value(),
    _,
};

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

fn isAction(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        .figure_animation_frame, _ => false,
        else => true,
    };
}

/// Hidden, an edit of the animation still settles, as one cancelled by leaving the workspace.
fn active(frame: *const sequencer.Frame) bool {
    if (workspace.shown(frame)) return true;
    return config(frame.tables).transaction.* != Transaction.none;
}

/// Every frame: the animation's settings, the shown pose, the status, and the requests its
/// edits send. Actions also reach the selection, the prompts they open and weight painting.
fn access(frame: *const sequencer.Frame) sequencer.Access {
    const groups = workspace.table_groups;
    var result: sequencer.Access = .{};
    // The host's publications the system's reads come from.
    watches.declareReads(&result);
    result.readAll(&groups.state);
    result.writeAll(&groups.state);
    result.writeAll(&.{ groups.commands, groups.figure_requests });
    result.write(time_subscriptions);
    if (takesAction(frame)) {
        result.writeAll(&groups.selected);
        result.writeAll(&.{ groups.palette_requests, Atom.from(weight.bones_name) });
    }
    return result;
}

/// Whether the inbox holds one of the animation's actions.
fn takesAction(frame: *const sequencer.Frame) bool {
    for (frame.messages) |received| {
        if (isAction(received.tag)) return true;
    }
    return false;
}

/// Hears the time system's frames while the clip plays on a shown canvas.
fn subscribe(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    if (workspaces.activeWorkspace(tables, atoms) != .figure) return;
    if (!enabled(session.get(tables))) return;
    if (workspace.canvasViewport(tables, atoms) == null) return;
    _ = try pass.append(time_subscriptions, .{ .kind = time.SubscriptionKind.frame, .inbox = sequencer.inboxOf(system()), .tag = Atom.from(Msg.figure_animation_frame) });
}

/// Plays the clip on, a frame's time at a time, while the figure workspace is shown.
fn playFrames(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    for (pass.frame.messages) |received| {
        if (received.tag.to(Msg) != .figure_animation_frame) continue;
        if (workspaces.activeWorkspace(tables, atoms) != .figure) continue;
        const time_frame = try received.payloadAs(time.FrameMsg);
        tick(tables, atoms, time_frame.dt);
    }
}

fn takeActions(pass: *sequencer.Pass) !void {
    try workspace.takeToolActions(pass, isAction, runAction);
}

fn runAction(frame: *const sequencer.Frame, received: sequencer.Message) !void {
    _ = try handleAction(frame.tables, frame.atoms, received.tag);
}

/// Sends the clip's settled edits, then follows the open document.
fn settleKernel(pass: *sequencer.Pass) !void {
    const tables = pass.frame.tables;
    const atoms = pass.frame.atoms;
    settle(tables, atoms);
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    reconcileWithReads(&reads);
}

const Log = mesha.log.scope("figure_animation");
const Zone = enum { timeline_lanes, timeline_draw };

pub const name = "editor_figure_animation";

pub const Transaction = struct {
    pub const none: u8 = 0;
    pub const editing: u8 = 1;
    pub const awaiting_terminal_result: u8 = 2;
};

const Ending = struct {
    const none: u8 = 0;
    const commit: u8 = 1;
    const cancel: u8 = 2;
};

pub const End = enum { commit, cancel };

/// What a press held on the timeline drags.
pub const Drag = struct {
    pub const none: u8 = 0;
    /// A key's exposure grip: its hold.
    pub const hold: u8 = 1;
    /// The playhead, along the ruler or empty track.
    pub const scrub: u8 = 2;
};

pub const Config = struct {
    doc: Atom = session.none,
    clip: u32 = 0,
    frame: u32 = 0,
    selected_frame: u32 = 0,
    loaded_pose: u32 = 0,
    key_selected: u8 = 0,
    playing: u8 = 0,
    preview: u8 = 0,
    onion: u8 = 0,
    seconds: f32 = 0,
    /// Property lanes scrolled past in the timeline.
    scroll: u32 = 0,
    /// The timeline's zoom, 1 with the whole clip across its track, and the frame at the
    /// track's left; see `clip_sequencer.Geometry`.
    zoom: f32 = 1,
    view_start: f32 = 0,
    serial: u32 = 0xe8000000,
    first_request: u32 = 0,
    last_request: u32 = 0,
    pending: u32 = 0,
    transaction: u8 = Transaction.none,
    ending: u8 = Ending.none,
    failed: u8 = 0,
    edit_doc: Atom = session.none,
    edit_clip: u32 = 0,
    edit_frame: u32 = 0,
    edit_pose: u32 = 0,
    old_clip: u32 = 0,
    old_frame: u32 = 0,
    old_selected_frame: u32 = 0,
    old_loaded_pose: u32 = 0,
    old_key_selected: u8 = 0,
    old_preview: u8 = 0,
    drag_start: f32 = 0,
    drag_hold: u32 = 1,
    drag_value: u32 = 1,
    /// What a held press drags: `Drag`.
    dragging: u8 = 0,
    /// The timeline's frame scale and frame 0's x when the press began.
    drag_scale: f32 = 8,
    drag_left: f32 = 0,
    /// The pointer over the timeline, for its hover cards; negative while it is elsewhere.
    hover_x: f32 = -1,
    hover_y: f32 = -1,
    next_clip: u32 = 0,
    select_after: u8 = 0,
};
pub const actions = blk: {
    const defs = .{
        .{
            Msg.figure_mode_animate,
            "Animate: filmstrip, transport and selected-key auto-key",
        },
        .{ Msg.figure_play_pause, "Animate play/pause (Space); never writes working pose" },
        .{ Msg.figure_frame_previous, "Previous frame (comma)" },
        .{ Msg.figure_frame_next, "Next frame (period)" },
        .{ Msg.figure_frame_seek, "Seek to an integer frame; loop or clamp to clip duration" },
        .{ Msg.figure_clip_select, "Choose a clip by name" },
        .{ Msg.figure_clip_loop, "Toggle selected clip loop" },
        .{ Msg.figure_clip_fps, "Set clip fps" },
        .{ Msg.figure_clip_length, "Set clip duration in frames" },
        .{ Msg.figure_clip_add, "Add a named clip" },
        .{ Msg.figure_clip_rename, "Rename selected clip" },
        .{ Msg.figure_clip_duplicate, "Deep duplicate selected clip and its poses" },
        .{ Msg.figure_clip_delete, "Delete clip and keys; preserve library poses" },
        .{
            Msg.figure_key_add,
            "Capture working pose at playhead; no off-key auto insertion",
        },
        .{ Msg.figure_key_delete, "Delete selected key only; preserve its library pose" },
        .{ Msg.figure_key_easing, "Outgoing easing: constant, linear or smooth" },
        .{ Msg.figure_key_hold, "Total exposure length; ripple later keys and duration" },
        .{
            Msg.figure_toggle_onion,
            "Previous/next saved key ghosts, red/green at 30% opacity",
        },
        .{ Msg.figure_strip_previous, "Scroll the timeline's lanes up" },
        .{ Msg.figure_strip_next, "Scroll the timeline's lanes down" },
    };
    var result: [defs.len]plugin.action_api.Def = undefined;
    for (defs, 0..) |d, i| result[i] = .{ .name = modes.shortName("figure", @tagName(d[0])), .tag = @tagName(d[0]), .doc = d[1] };
    break :blk result;
};
pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    try session.prepareSingleton(Config, mem, atoms, tables, name);
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareSingleton(Config, mem, atoms, tables, name);
}

pub const ConfigView = session.Row(Config);
pub fn config(tables: *Table.Registry) ConfigView {
    const config_table = tables.findByName(Atom.from(name)).?;
    return config_table.getRow(.{ .row = 0, .generation = config_table.rowGeneration(0) }, session.Row(Config)).?;
}

pub fn enabled(editor: session.View) bool {
    return editor.mode.* == names.animate;
}

/// A key's exposure block in the timeline `rect` of a clip `frames` long.
pub fn exposureRect(rect: panels_mod.Rect, frames: u32, key_frame: u32, duration: u32) panels_mod.Rect {
    return (clip_sequencer.Geometry{ .rect = rect, .frames = frames }).exposureRect(key_frame, duration);
}

/// The width of one frame in the timeline `rect` of a clip `frames` long.
pub fn framePixels(rect: panels_mod.Rect, frames: u32) f32 {
    return (clip_sequencer.Geometry{ .rect = rect, .frames = frames }).framePixels();
}

/// Each key's exposure in frames, in key order.
fn holds(allocator: std.mem.Allocator, list: []const api.read.ClipKey, frames: u32) ![]u32 {
    const result = try allocator.alloc(u32, list.len);
    for (result, 0..) |*duration, index| duration.* = hold(list, index, frames);
    return result;
}

/// The timeline's lanes for the selected clip, or none without one.
fn modelWithReads(reads: *session.ReadContext) !?clip_sequencer.Model {
    const clip = clipRowWithReads(reads) orelse return null;
    const editor = session.get(reads.tables);
    const data = try reads.definition(editor.doc.*);
    const list = try keysWithReads(reads);
    return try clip_sequencer.build(try reads.readAllocator(), reads.atoms, data, clip, list);
}

/// The timeline in `rect` for a clip `frames` long, zoomed and scrolled as stored.
fn timelineGeometry(settings: ConfigView, rect: panels_mod.Rect, frames: u32) clip_sequencer.Geometry {
    const view = clip_sequencer.bounded(frames, settings.zoom.*, settings.view_start.*);
    return .{ .rect = rect, .frames = frames, .zoom = view.zoom, .start = view.start };
}

/// Zooms the timeline in `rect` by `notches` of the wheel, keeping the frame under `x` in place.
pub fn wheelZoom(tables: *Table.Registry, atoms: *Atom.Registry, rect: panels_mod.Rect, x: f32, notches: f32) void {
    if (!std.math.isFinite(notches)) return;
    const clip = clipRow(tables, atoms) orelse return;
    const settings = config(tables);
    const timeline = timelineGeometry(settings, rect, clip.frames);
    const factor = std.math.pow(f32, 1.25, notches);
    const zoomed = clip_sequencer.zoomedAt(timeline, timeline.zoom * factor, x);
    settings.zoom.* = zoomed.zoom;
    settings.view_start.* = zoomed.start;
}

/// Moves the timeline in `rect` along the clip by `notches` of the wheel, a tenth of the track each.
pub fn wheelPan(tables: *Table.Registry, atoms: *Atom.Registry, rect: panels_mod.Rect, notches: f32) void {
    if (!std.math.isFinite(notches)) return;
    const clip = clipRow(tables, atoms) orelse return;
    const settings = config(tables);
    const timeline = timelineGeometry(settings, rect, clip.frames);
    const shown_frames = timeline.trackWidth() / timeline.framePixels();
    const moved = clip_sequencer.bounded(clip.frames, timeline.zoom, timeline.start - notches * shown_frames / 10);
    settings.view_start.* = moved.start;
}

/// The lanes scrolled past as shown: the stored scroll, short of leaving rows empty.
fn shownScroll(settings: session.Row(Config), model: clip_sequencer.Model, timeline: clip_sequencer.Geometry) usize {
    const lane_rows = timeline.visibleRows() -| 1;
    return @min(settings.scroll.*, model.lanes.len -| lane_rows);
}

/// How many property lanes the selected clip has, which bounds their scroll.
pub fn laneCount(tables: *Table.Registry, atoms: *Atom.Registry) usize {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    const model = (modelWithReads(&reads) catch null) orelse return 0;
    return model.lanes.len;
}

pub fn clipRow(tables: *Table.Registry, atoms: *Atom.Registry) ?api.read.Clip {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return clipRowWithReads(&reads);
}

pub fn clipRowWithReads(reads: *session.ReadContext) ?api.read.Clip {
    const editor = session.get(reads.tables);
    const settings = config(reads.tables);
    const data = reads.definition(editor.doc.*) catch return null;
    return session.findById(api.read.Clip, data.clips, settings.clip.*);
}

pub fn keys(tables: *Table.Registry, atoms: *Atom.Registry) ![]api.read.ClipKey {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return keysWithReads(&reads);
}

pub fn keysWithReads(reads: *session.ReadContext) ![]api.read.ClipKey {
    const editor = session.get(reads.tables);
    const settings = config(reads.tables);
    const data = try reads.definition(editor.doc.*);
    const allocator = try reads.readAllocator();
    var result: std.ArrayListUnmanaged(api.read.ClipKey) = .empty;
    errdefer result.deinit(allocator);
    for (data.clip_keys) |key| if (key.clip == settings.clip.*) try result.append(allocator, key);
    return result.toOwnedSlice(allocator);
}

/// Presentation may observe stale identity before update; lookup never repairs it.
pub fn selectedKey(tables: *Table.Registry, atoms: *Atom.Registry) !?api.read.ClipKey {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    return selectedKeyWithReads(&reads);
}

pub fn selectedKeyWithReads(reads: *session.ReadContext) !?api.read.ClipKey {
    const settings = config(reads.tables);
    const editor = session.get(reads.tables);
    if (settings.doc.* != editor.doc.* or settings.key_selected.* == 0) return null;
    const data = try reads.definition(editor.doc.*);
    return selectedKeyFromDefinition(settings, data);
}

fn selectedKeyFromDefinition(settings: session.Row(Config), data: api.read.Definition) ?api.read.ClipKey {
    if (settings.key_selected.* == 0) return null;
    for (data.clip_keys) |key| {
        if (key.clip == settings.clip.* and key.frame == settings.selected_frame.* and key.pose == settings.loaded_pose.*) return key;
    }
    return null;
}

// Clears stale selection identity when the selected key no longer exists.
pub fn reconcileSelectedKey(tables: *Table.Registry, atoms: *Atom.Registry) ?api.read.ClipKey {
    const settings = config(tables);
    if (settings.key_selected.* == 0) return null;
    const selected = selectedKey(tables, atoms) catch return null;
    if (selected) |key| return key;
    settings.key_selected.* = 0;
    settings.loaded_pose.* = 0;
    return null;
}

pub fn hold(list: []const api.read.ClipKey, index: usize, frames: u32) u32 {
    return (if (index + 1 < list.len) list[index + 1].frame else frames) - list[index].frame;
}

pub fn boundedFrame(seconds: f64, fps: f32, frames: u32, loop: bool) f64 {
    if (frames == 0 or !std.math.isFinite(seconds) or !std.math.isFinite(fps) or fps <= 0) return 0;
    const duration: f64 = @floatFromInt(frames);
    const f = seconds * @as(f64, fps);
    if (loop) return if (std.math.isFinite(f)) @mod(f, duration) else @mod(seconds, duration / fps) * fps;
    return std.math.clamp(f, 0, duration - 1);
}

pub fn validDuration(clip: api.read.Clip) !void {
    const duration = @as(f64, @floatFromInt(clip.frames)) / clip.fps;
    if (!std.math.isFinite(duration) or duration <= 0 or duration > std.math.floatMax(f32)) return error.TimeOverflow;
}

pub fn seek(tables: *Table.Registry, atoms: *Atom.Registry, frame: i64) !void {
    try idle(tables, atoms);
    const clip = clipRow(tables, atoms) orelse return error.SelectClip;
    try validDuration(clip);
    const settings = config(tables);
    settings.playing.* = 0;
    const frame_count: i64 = clip.frames;
    settings.frame.* = @intCast(if (clip.loop != 0) @mod(frame, frame_count) else std.math.clamp(frame, 0, frame_count - 1));
    settings.seconds.* = @floatCast(@as(f64, @floatFromInt(settings.frame.*)) / clip.fps);
    settings.key_selected.* = 0;
    settings.preview.* = 1;
}

pub fn tick(tables: *Table.Registry, atoms: *Atom.Registry, dt: f64) void {
    preview.advance(tables, atoms, dt) catch |err| {
        config(tables).playing.* = 0;
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
    };
}

pub fn idle(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const settings = config(tables);
    if (settings.transaction.* != Transaction.none or session.get(tables).tx_active.* != 0 or gesture.busy(gesture.get(tables))) return error.AnimationEditSettling;
    for (try session.listDefinitions(tables, atoms)) |entry| {
        if (entry.info.transaction_open) return error.AnimationEditSettling;
    }
}

pub fn canEditPose(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    if (!enabled(session.get(tables))) return;
    if (config(tables).playing.* != 0) return error.PausePlaybackToEdit;
    if (config(tables).transaction.* != Transaction.none) return error.AnimationEditSettling;
    config(tables).preview.* = 0;
    if (reconcileSelectedKey(tables, atoms) == null) prompts.inform(session.feedbackTable(tables), session.feedback(tables), "Off key: editing working pose only. Add key captures it; no saved key changes.");
}

fn tracked(tables: *Table.Registry, atoms: *Atom.Registry, payload: api.Payload) !void {
    const settings = config(tables);
    // One bounded in-flight batch; IDs distinguish UI-owned results from MCP edits.
    if (settings.serial.* >= 0xeffffffe) return error.CapacityExceeded;
    settings.serial.* = @max(settings.serial.* + 1, 0xe8000001);
    var request = payload;
    switch (request) {
        inline else => |*request_payload| request_payload.request = settings.serial.*,
    }
    try transport.send(tables, atoms, request);
    if (settings.pending.* == 0) settings.first_request.* = settings.serial.*;
    settings.last_request.* = settings.serial.*;
    settings.pending.* += 1;
}

fn begin(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    try idle(tables, atoms);
    const editor = session.get(tables);
    const settings = config(tables);
    settings.edit_doc.* = editor.doc.*;
    settings.edit_clip.* = settings.clip.*;
    settings.edit_frame.* = settings.selected_frame.*;
    settings.edit_pose.* = settings.loaded_pose.*;
    settings.old_clip.* = settings.clip.*;
    settings.old_frame.* = settings.frame.*;
    settings.old_selected_frame.* = settings.selected_frame.*;
    settings.old_loaded_pose.* = settings.loaded_pose.*;
    settings.old_key_selected.* = settings.key_selected.*;
    settings.old_preview.* = settings.preview.*;
    settings.next_clip.* = 0;
    settings.select_after.* = 0;
    settings.failed.* = 0;
    settings.ending.* = Ending.none;
    try tracked(tables, atoms, .{ .begin = .{ .doc = editor.doc.*, .label = names.animate_edit } });
    settings.transaction.* = Transaction.editing;
    editor.tx_active.* = 1;
}

pub fn edit(tables: *Table.Registry, atoms: *Atom.Registry, payload: api.Payload) !void {
    try begin(tables, atoms);
    errdefer {
        config(tables).failed.* = 1;
        config(tables).ending.* = Ending.cancel;
    }
    try tracked(tables, atoms, payload);
    config(tables).ending.* = Ending.commit;
}

pub fn editPose(tables: *Table.Registry, atoms: *Atom.Registry, payload: api.Payload) !void {
    if (!enabled(session.get(tables))) {
        try transport.send(tables, atoms, payload);
        return;
    }
    try canEditPose(tables, atoms);
    try begin(tables, atoms);
    errdefer {
        config(tables).failed.* = 1;
        config(tables).ending.* = Ending.cancel;
    }
    try tracked(tables, atoms, payload);
    const settings = config(tables);
    if (reconcileSelectedKey(tables, atoms) != null) try tracked(tables, atoms, .{
        .sync_clip_key = .{
            .doc = settings.edit_doc.*,
            .clip = settings.edit_clip.*,
            .frame = settings.edit_frame.*,
        },
    });
    settings.ending.* = Ending.commit;
}

/// What an edit becomes while animating: the edits to preview in its place, with the selected
/// key kept in step.
pub const AnimatedEdits = struct {
    edits: [api.max_preview_edits]api.PreviewEdit = undefined,
    count: usize = 0,

    pub fn slice(self: *const AnimatedEdits) []const api.PreviewEdit {
        return self.edits[0..self.count];
    }
};

/// In Animate, an edit of how a row looks goes to the working pose, and to the selected key
/// with it, so +Key captures it and a selected key keeps it. Other edits, and every edit
/// outside Animate, stay as they are. The rows live in this frame's scratch memory.
pub fn animated(tables: *Table.Registry, atoms: *Atom.Registry, requested: api.PreviewEdit) !AnimatedEdits {
    var result: AnimatedEdits = .{};
    result.edits[0] = requested;
    result.count = 1;
    if (!enabled(session.get(tables))) return result;
    const scratch = try tables.memory.frameScratchAllocator();
    const rows = (try api.animatedProperties(scratch.allocator, requested)) orelse return result;
    try canEditPose(tables, atoms);
    const doc = session.get(tables).doc.*;
    result.edits[0] = .{ .set_pose_properties = .{ .doc = doc, .pose = 0, .properties = rows } };
    if (reconcileSelectedKey(tables, atoms) != null) {
        const settings = config(tables);
        result.edits[1] = .{ .sync_clip_key = .{ .doc = doc, .clip = settings.clip.*, .frame = settings.selected_frame.* } };
        result.count = 2;
    }
    return result;
}

/// `row` as the working pose shows it in Animate, which may give it its own look; as
/// authored otherwise. `family` is the row's kind, `.shape` or `.layer`.
pub fn posedRow(editor: session.View, comptime family: api.PropertyFamily, data: api.read.Definition, row: anytype) @TypeOf(row) {
    var result = row;
    if (!enabled(editor)) return result;
    for (data.pose_properties) |property| {
        if (property.pose != 0 or property.family != @intFromEnum(family) or property.target != row.id) continue;
        inline for (@field(api.animatable_fields, @tagName(family))) |field_name| {
            if (property.field == Atom.from(field_name)) {
                @field(result, field_name) = api.propertyAs(@TypeOf(@field(result, field_name)), property.value);
            }
        }
    }
    return result;
}

/// Sends `payload`, given to the working pose in Animate when it edits how a row looks.
pub fn editLook(tables: *Table.Registry, atoms: *Atom.Registry, payload: api.Payload) !void {
    const look: api.PreviewEdit = switch (payload) {
        .set_shape => |request| .{ .set_shape = request },
        .set_layer => |request| .{ .set_layer = request },
        .set_shape_color => |request| .{ .set_shape_color = request },
        else => return transport.send(tables, atoms, payload),
    };
    if (!enabled(session.get(tables))) return transport.send(tables, atoms, payload);
    const scratch = try tables.memory.frameScratchAllocator();
    const rows = (try api.animatedProperties(scratch.allocator, look)) orelse return transport.send(tables, atoms, payload);
    const doc = switch (payload) {
        inline else => |request| request.doc,
    };
    try editPose(tables, atoms, .{ .set_pose_properties = .{ .doc = doc, .pose = 0, .properties = rows } });
}

pub fn selectClip(tables: *Table.Registry, atoms: *Atom.Registry, id: u32) !void {
    try idle(tables, atoms);
    const settings = config(tables);
    settings.clip.* = id;
    settings.frame.* = 0;
    settings.seconds.* = 0;
    settings.key_selected.* = 0;
    settings.playing.* = 0;
    settings.preview.* = 1;
    settings.scroll.* = 0;
    settings.zoom.* = 1;
    settings.view_start.* = 0;
}

pub fn selectKey(tables: *Table.Registry, atoms: *Atom.Registry, key: api.read.ClipKey) !void {
    const settings = config(tables);
    settings.playing.* = 0;
    try begin(tables, atoms);
    errdefer {
        config(tables).failed.* = 1;
        config(tables).ending.* = Ending.cancel;
    }
    settings.edit_frame.* = key.frame;
    settings.edit_pose.* = key.pose;
    settings.select_after.* = 1;
    try tracked(tables, atoms, .{ .apply_pose = .{ .doc = settings.edit_doc.*, .id = key.pose } });
    settings.ending.* = Ending.commit;
}

pub fn end(settings: ConfigView, ending: End) bool {
    if (settings.transaction.* != Transaction.editing) return false;
    settings.ending.* = switch (ending) {
        .commit => Ending.commit,
        .cancel => Ending.cancel,
    };
    settings.dragging.* = 0;
    return true;
}

pub fn settle(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const settings = config(tables);
    if (settings.transaction.* != Transaction.editing or settings.pending.* != 0 or settings.ending.* == Ending.none) return;
    tracked(tables, atoms, if (settings.failed.* != 0 or settings.ending.* == Ending.cancel) .{ .cancel = .{ .doc = settings.edit_doc.* } } else .{ .commit = .{ .doc = settings.edit_doc.* } }) catch |err| {
        prompts.status(session.table(tables), session.get(tables), session.feedback(tables), @errorName(err));
        return;
    };
    settings.transaction.* = Transaction.awaiting_terminal_result;
}

pub fn reconcileResult(tables: *Table.Registry, atoms: *Atom.Registry, metadata: session.Metadata, result: anyerror!?u32) void {
    const settings = config(tables);
    const request = metadata.request;
    const doc = metadata.doc;
    if (settings.transaction.* == Transaction.none or
        doc != settings.edit_doc.* or
        settings.pending.* == 0 or
        request < settings.first_request.* or
        request > settings.last_request.*) return;
    settings.pending.* -= 1;
    const created = result catch {
        settings.failed.* = 1;
        settings.ending.* = Ending.cancel;
        // If an end command itself rejects, do not strand editor ownership after
        // the runtime has already closed the journal (e.g. external close).
        if ((metadata.operation == .commit or
            metadata.operation == .cancel) and
            !(if (session.definitionInfo(tables, atoms, settings.edit_doc.*)) |info| info.transaction_open else false))
        {
            session.get(tables).tx_active.* = 0;
            settings.transaction.* = Transaction.none;
            settings.dragging.* = 0;
        } else if (metadata.operation == .commit or metadata.operation == .cancel) settings.transaction.* = Transaction.editing;
        return;
    };
    if (metadata.operation == .add_clip or metadata.operation == .duplicate_clip) settings.next_clip.* = created orelse 0;
    if (metadata.operation == .capture_clip_key) {
        settings.select_after.* = 1;
        settings.edit_frame.* = metadata.capture_frame;
        settings.edit_pose.* = created orelse 0;
    }
    if (metadata.operation != .commit and metadata.operation != .cancel) return;
    const editor = session.get(tables);
    editor.tx_active.* = 0;
    if (metadata.operation == .cancel) {
        settings.clip.* = settings.old_clip.*;
        settings.frame.* = settings.old_frame.*;
        settings.selected_frame.* = settings.old_selected_frame.*;
        settings.loaded_pose.* = settings.old_loaded_pose.*;
        settings.key_selected.* = settings.old_key_selected.*;
        settings.preview.* = settings.old_preview.*;
    } else if (settings.next_clip.* != 0) {
        settings.clip.* = settings.next_clip.*;
        settings.frame.* = 0;
        settings.key_selected.* = 0;
        settings.preview.* = 1;
    } else if (settings.select_after.* != 0) {
        settings.selected_frame.* = settings.edit_frame.*;
        settings.loaded_pose.* = settings.edit_pose.*;
        settings.frame.* = settings.edit_frame.*;
        settings.key_selected.* = 1;
        settings.preview.* = 0;
    }
    if (clipRow(tables, atoms)) |clip| {
        if (validDuration(clip)) |_| {
            settings.seconds.* = @floatCast(@as(f64, @floatFromInt(settings.frame.*)) / clip.fps);
        } else |_| {
            settings.playing.* = 0;
            settings.seconds.* = 0;
            settings.frame.* = 0;
            prompts.status(session.table(tables), session.get(tables), session.feedback(tables), "TimeOverflow");
        }
    }
    settings.transaction.* = Transaction.none;
    settings.ending.* = Ending.none;
    settings.dragging.* = 0;
}

pub fn reconcile(tables: *Table.Registry, atoms: *Atom.Registry) void {
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    reconcileWithReads(&reads);
}

pub fn reconcileWithReads(reads: *session.ReadContext) void {
    const tables = reads.tables;
    const settings = config(tables);
    const editor = session.get(tables);
    if (settings.doc.* != editor.doc.*) {
        settings.doc.* = editor.doc.*;
        settings.clip.* = 0;
        settings.frame.* = 0;
        settings.key_selected.* = 0;
        settings.preview.* = 0;
        settings.playing.* = 0;
        settings.seconds.* = 0;
        settings.scroll.* = 0;
        settings.zoom.* = 1;
        settings.view_start.* = 0;
    }
    if (!enabled(session.get(tables))) {
        settings.playing.* = 0;
        settings.key_selected.* = 0;
        settings.loaded_pose.* = 0;
    }
    if (settings.transaction.* != Transaction.none) return;
    const data = reads.definition(editor.doc.*) catch {
        settings.clip.* = 0;
        settings.key_selected.* = 0;
        settings.playing.* = 0;
        return;
    };
    if (session.findById(api.read.Clip, data.clips, settings.clip.*) == null) {
        settings.clip.* = if (data.clips.len == 0) 0 else data.clips[0].id;
        settings.key_selected.* = 0;
        settings.playing.* = 0;
    }
    if (session.findById(api.read.Clip, data.clips, settings.clip.*)) |clip| {
        validDuration(clip) catch {
            settings.playing.* = 0;
            settings.seconds.* = 0;
            settings.frame.* = 0;
            prompts.status(session.table(tables), session.get(tables), session.feedback(tables), "TimeOverflow");
            return;
        };
        var frame = boundedFrame(settings.seconds.*, clip.fps, clip.frames, clip.loop != 0);
        // A paused exact frame survives f32 phase rounding across reconciliation.
        const authored_frame: f64 = @floatFromInt(settings.frame.*);
        if (settings.playing.* == 0 and settings.frame.* < clip.frames and @abs(frame - authored_frame) < 0.0001) frame = authored_frame;
        settings.frame.* = @intFromFloat(@floor(frame));
        settings.seconds.* = @floatCast(frame / clip.fps);
        // A zoomed timeline pages along with the playhead while the clip plays.
        var view = clip_sequencer.bounded(clip.frames, settings.zoom.*, settings.view_start.*);
        const shown_frames = @as(f32, @floatFromInt(clip.frames)) / view.zoom;
        const playhead: f32 = @floatCast(frame);
        if (settings.playing.* != 0 and (playhead < view.start or playhead >= view.start + shown_frames)) {
            view = clip_sequencer.bounded(clip.frames, view.zoom, playhead);
        }
        settings.zoom.* = view.zoom;
        settings.view_start.* = view.start;
    }
    if (settings.key_selected.* != 0 and selectedKeyFromDefinition(settings, data) == null) {
        settings.key_selected.* = 0;
        settings.loaded_pose.* = 0;
    }
    if (enabled(session.get(tables)) and settings.scroll.* != 0) {
        const lanes = (modelWithReads(reads) catch null) orelse {
            settings.scroll.* = 0;
            return;
        };
        settings.scroll.* = @min(settings.scroll.*, @as(u32, @intCast(lanes.lanes.len -| 1)));
    }
}

/// A press on the timeline: a key's grip starts dragging its hold, a key selects it, and the
/// ruler or empty track moves the playhead and scrubs while held.
pub fn pointerDown(tables: *Table.Registry, atoms: *Atom.Registry, rect: panels_mod.Rect, point: session.Vec2) !bool {
    if (!enabled(session.get(tables)) or !geometry.contains(rect, point)) return false;
    if (point.y < rect.y + clip_sequencer.controls_height) return false;
    try idle(tables, atoms);
    const settings = config(tables);
    const clip = clipRow(tables, atoms) orelse return true;
    var reads = session.ReadContext{ .tables = tables, .atoms = atoms };
    defer reads.deinit();
    const model = (try modelWithReads(&reads)) orelse return true;
    const timeline = timelineGeometry(settings, rect, clip.frames);
    const durations = try holds(try reads.readAllocator(), model.keys, clip.frames);
    switch (clip_sequencer.hitAt(model, timeline, shownScroll(settings, model, timeline), point, durations)) {
        .none => {},
        .grip => |index| {
            try selectKey(tables, atoms, model.keys[index]);
            settings.ending.* = Ending.none;
            settings.dragging.* = Drag.hold;
            settings.drag_start.* = point.x;
            settings.drag_scale.* = timeline.framePixels();
            settings.drag_hold.* = durations[index];
            settings.drag_value.* = settings.drag_hold.*;
            const editor = session.get(tables);
            editor.gesture_active.* = 1;
            editor.gesture_kind.* = names.filmstrip_hold;
        },
        .key => |found| try selectKey(tables, atoms, model.keys[found.index]),
        .track => {
            try seek(tables, atoms, timeline.frameAt(point.x));
            settings.dragging.* = Drag.scrub;
            settings.drag_scale.* = timeline.framePixels();
            settings.drag_left.* = timeline.frameX(0);
            const editor = session.get(tables);
            editor.gesture_active.* = 1;
            editor.gesture_kind.* = names.filmstrip_scrub;
        },
    }
    return true;
}

pub fn pointerMove(tables: *Table.Registry, atoms: *Atom.Registry, x: f32) !bool {
    const settings = config(tables);
    if (settings.dragging.* == Drag.none) return false;
    if (settings.dragging.* == Drag.scrub) {
        const frame: i64 = @intFromFloat(@round((x - settings.drag_left.*) / settings.drag_scale.*));
        seek(tables, atoms, frame) catch {};
        return true;
    }
    if (settings.failed.* != 0 or settings.ending.* != Ending.none) return true;
    const delta = @round((x - settings.drag_start.*) / settings.drag_scale.*);
    const value: u32 = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(settings.drag_hold.*)) + delta, 1, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
    if (value == settings.drag_value.*) return true;
    try tracked(tables, atoms, .{
        .set_clip_hold = .{
            .doc = settings.edit_doc.*,
            .clip = settings.edit_clip.*,
            .frame = settings.edit_frame.*,
            .hold = value,
        },
    });
    settings.drag_value.* = value;
    return true;
}

/// Ends a scrub; true when one was under way.
pub fn endScrub(settings: ConfigView) bool {
    if (settings.dragging.* != Drag.scrub) return false;
    settings.dragging.* = Drag.none;
    return true;
}

/// Follows the pointer over the timeline for its hover cards; false once it is elsewhere.
pub fn hover(settings: ConfigView, editor: session.View, rect: ?panels_mod.Rect, point: session.Vec2) bool {
    const inside = if (rect) |area| enabled(editor) and geometry.contains(area, point) else false;
    settings.hover_x.* = if (inside) point.x else -1;
    settings.hover_y.* = if (inside) point.y else -1;
    return inside;
}

pub fn handleAction(tables: *Table.Registry, atoms: *Atom.Registry, tag: Atom) !bool {
    const editor = session.get(tables);
    const settings = config(tables);
    const message = tag.to(Msg);
    if (message == .figure_mode_animate) {
        try idle(tables, atoms);
        weight.discard(weight.config(tables), weight.boneStates(tables));
        settings.key_selected.* = 0;
        settings.loaded_pose.* = 0;
        editor.mode.* = names.animate;
        editor.tool.* = names.select;
        editor.space_held.* = 0;
        editor.reparent_active.* = 0;
        editor.fit_pending.* = 1;
        reconcile(tables, atoms);
        return true;
    }
    if (!enabled(session.get(tables))) return false;
    switch (message) {
        .figure_toggle_onion => settings.onion.* ^= 1,
        .figure_strip_previous => settings.scroll.* -|= 1,
        .figure_strip_next => settings.scroll.* +|= 1,
        .figure_play_pause => {
            try idle(tables, atoms);
            try validDuration(clipRow(tables, atoms) orelse return error.SelectClip);
            settings.playing.* ^= 1;
            settings.preview.* = 1;
            settings.key_selected.* = 0;
        },
        .figure_frame_previous, .figure_frame_next => {
            const step: i64 = if (message == .figure_frame_next) 1 else -1;
            try seek(tables, atoms, @as(i64, settings.frame.*) + step);
        },
        .figure_clip_select, .figure_frame_seek => {
            try idle(tables, atoms);
            const frame_allocator = try tables.memory.frameScratchAllocator();
            const clip = clipRow(tables, atoms);
            const choosing_clip = message == .figure_clip_select;
            if (!choosing_clip and clip == null) return error.SelectClip;
            const initial = if (choosing_clip)
                (if (clip) |current| atoms.lookup(current.name) orelse "" else "")
            else
                try std.fmt.allocPrint(frame_allocator.allocator, "{d}", .{settings.frame.*});
            const kind = if (choosing_clip) names.clip_select else names.clip_frame;
            const target_kind = names.clip;
            try prompts.showTarget(tables.memory, tables, atoms, kind, initial, target_kind, settings.clip.*);
        },
        .figure_clip_add, .figure_clip_rename, .figure_clip_duplicate, .figure_clip_fps, .figure_clip_length, .figure_key_easing, .figure_key_hold => try promptForClip(tables, atoms, settings, message),
        .figure_key_add => {
            const clip = clipRow(tables, atoms) orelse return error.SelectClip;
            if (settings.playing.* != 0) return error.PausePlaybackToEdit;
            try edit(tables, atoms, .{
                .capture_clip_key = .{ .doc = editor.doc.*, .clip = clip.id, .frame = settings.frame.* },
            });
        },
        .figure_key_delete => {
            const key = reconcileSelectedKey(tables, atoms) orelse return error.SelectKey;
            try edit(tables, atoms, .{
                .delete_clip_key = .{ .doc = editor.doc.*, .clip = key.clip, .frame = key.frame },
            });
        },
        .figure_clip_delete, .figure_clip_loop => {
            const clip = clipRow(tables, atoms) orelse return error.SelectClip;
            settings.playing.* = 0;
            try edit(tables, atoms, if (message == .figure_clip_delete) .{ .delete_clip = .{ .doc = editor.doc.*, .id = clip.id } } else .{ .set_clip = .{ .doc = editor.doc.*, .id = clip.id, .loop = 1 - clip.loop } });
        },
        .figure_mode_animate, .figure_animation_frame, _ => return false,
    }
    return true;
}

/// Opens the prompt a clip or key action asks with, its text the clip's or key's current value.
fn promptForClip(tables: *Table.Registry, atoms: *Atom.Registry, settings: ConfigView, message: Msg) !void {
    const kind = switch (message) {
        .figure_clip_add => names.clip_add,
        .figure_clip_rename => names.clip_rename,
        .figure_clip_duplicate => names.clip_duplicate,
        .figure_clip_fps => names.clip_fps,
        .figure_clip_length => names.clip_length,
        .figure_key_easing => names.key_easing,
        .figure_key_hold => names.key_hold,
        else => unreachable,
    };
    try idle(tables, atoms);
    settings.playing.* = 0;
    const frame_allocator = (try tables.memory.frameScratchAllocator()).allocator;
    var initial: []const u8 = "";
    if (message != .figure_clip_add) {
        const clip = clipRow(tables, atoms) orelse return error.SelectClip;
        switch (message) {
            .figure_clip_rename => initial = atoms.lookup(clip.name) orelse "",
            .figure_clip_fps => initial = try std.fmt.allocPrint(frame_allocator, "{d}", .{clip.fps}),
            .figure_clip_length => initial = try std.fmt.allocPrint(frame_allocator, "{d}", .{clip.frames}),
            .figure_key_easing => {
                const key = reconcileSelectedKey(tables, atoms) orelse return error.SelectKey;
                initial = atoms.lookup(key.easing) orelse "linear";
            },
            .figure_key_hold => {
                const key = reconcileSelectedKey(tables, atoms) orelse return error.SelectKey;
                const list = try keys(tables, atoms);
                for (list, 0..) |key_entry, i| if (key_entry.frame == key.frame) {
                    initial = try std.fmt.allocPrint(frame_allocator, "{d}", .{hold(list, i, clip.frames)});
                    break;
                };
            },
            else => {},
        }
    }
    const target_kind = names.clip;
    try prompts.showTarget(tables.memory, tables, atoms, kind, initial, target_kind, settings.clip.*);
}

pub fn validatePrompt(tables: *Table.Registry, atoms: *Atom.Registry) !void {
    const editor = session.get(tables);
    try session.validatePromptDocument(tables, atoms);
    if (editor.prompt_mode.* == names.animate) {
        const settings = config(tables);
        _ = reconcileSelectedKey(tables, atoms); // Invalidate a foreign same-frame pose replacement.
        if (!enabled(session.get(tables)) or
            editor.prompt_clip.* != settings.clip.* or
            editor.prompt_key_frame.* != settings.selected_frame.* or
            editor.prompt_key_selected.* != settings.key_selected.* or
            editor.prompt_key_pose.* != settings.loaded_pose.*) return error.PromptAnimationChanged;
    }
}

/// The prompts the animation answers.
const prompt_kinds = [_]Atom{ names.clip_add, names.clip_duplicate, names.clip_fps, names.clip_frame, names.clip_length, names.clip_rename, names.key_easing, names.key_hold };

pub fn submitPrompt(tables: *Table.Registry, atoms: *Atom.Registry, kind: Atom, text: []const u8) !bool {
    if (std.mem.indexOfScalar(Atom, &prompt_kinds, kind) == null) return false;
    try validatePrompt(tables, atoms);
    const editor = session.get(tables);
    const settings = config(tables);
    if (kind == names.clip_add or kind == names.clip_rename or kind == names.clip_duplicate) {
        if (!zon.isSnakeCaseAtom(text)) return error.InvalidName;
        const clip_name = atoms.intern(text);
        if (kind == names.clip_add) {
            try edit(tables, atoms, .{ .add_clip = .{
                .doc = editor.prompt_doc.*,
                .name = clip_name,
                .frames = 24,
            } });
        } else if (kind == names.clip_rename) {
            try edit(tables, atoms, .{ .set_clip = .{
                .doc = editor.prompt_doc.*,
                .id = editor.prompt_clip.*,
                .name = clip_name,
            } });
        } else {
            try edit(tables, atoms, .{ .duplicate_clip = .{
                .doc = editor.prompt_doc.*,
                .id = editor.prompt_clip.*,
                .name = clip_name,
            } });
        }
    } else if (kind == names.clip_frame) {
        _ = clipRow(tables, atoms) orelse return error.PromptTargetMissing;
        const frame = try std.fmt.parseInt(i64, text, 10);
        try seek(tables, atoms, frame);
    } else if (kind == names.clip_fps) {
        _ = clipRow(tables, atoms) orelse return error.PromptTargetMissing;
        const fps = try std.fmt.parseFloat(f32, text);
        if (!std.math.isFinite(fps) or fps <= 0) return error.InvalidFps;
        try edit(tables, atoms, .{
            .set_clip = .{ .doc = editor.prompt_doc.*, .id = editor.prompt_clip.*, .fps = fps },
        });
    } else if (kind == names.clip_length) {
        try edit(tables, atoms, .{
            .set_clip = .{
                .doc = editor.prompt_doc.*,
                .id = editor.prompt_clip.*,
                .frames = try std.fmt.parseInt(u32, text, 10),
            },
        });
    } else if (kind == names.key_easing) {
        if (!std.mem.eql(u8, text, "constant") and !std.mem.eql(u8, text, "linear") and !std.mem.eql(u8, text, "smooth")) return error.ExpectedConstantLinearSmooth;
        if (settings.key_selected.* == 0) return error.SelectKey;
        try edit(tables, atoms, .{
            .set_clip_key = .{
                .doc = editor.prompt_doc.*,
                .clip = editor.prompt_clip.*,
                .frame = editor.prompt_key_frame.*,
                .easing = atoms.intern(text),
            },
        });
    } else if (kind == names.key_hold) {
        if (settings.key_selected.* == 0) return error.SelectKey;
        try edit(tables, atoms, .{
            .set_clip_hold = .{
                .doc = editor.prompt_doc.*,
                .clip = editor.prompt_clip.*,
                .frame = editor.prompt_key_frame.*,
                .hold = try std.fmt.parseInt(u32, text, 10),
            },
        });
    } else return false;
    return true;
}

pub fn ghostPoses(list: []const api.read.ClipKey, frame: u32, loop: bool) [2]?u32 {
    var result: [2]?u32 = .{ null, null };
    for (list) |key| {
        if (key.frame < frame) result[0] = key.pose;
        if (key.frame > frame and result[1] == null) result[1] = key.pose;
    }
    if (loop and list.len > 1) {
        if (result[0] == null) result[0] = list[list.len - 1].pose;
        if (result[1] == null) result[1] = list[0].pose;
    }
    return result;
}

/// Draws the onion skins the editor watches (`watches.Key.ghost_before` and `ghost_after`) from
/// the drawings the host published for them, each leaving at least half the context's remaining
/// budget in reserve: a skin the budget refuses is skipped. Writes no table.
pub fn renderOnionSkins(tables: *Table.Registry, render_context: anytype) !void {
    const settings = config(tables);
    if (!enabled(session.get(tables)) or settings.onion.* == 0) return;
    const doc = session.get(tables).doc.*;
    const ghosts = [_]watches.Key{ .ghost_before, .ghost_after };
    for (ghosts) |key| {
        // No key on that side, or not answered yet.
        const found = watches.answer(tables, key) orelse continue;
        if (found.watch.definition != doc) continue;
        try found.published.failure.check();
        try found.published.drawing_failure.check();
        const ghost = found.published.drawing orelse continue;
        var reserve = preview.ui_reserve;
        const budget = render_context.pathBudget();
        inline for (std.meta.fields(api.Reserve)) |field| @field(reserve, field.name) = @max(@field(reserve, field.name), @field(budget, field.name) / 2);
        _ = api.draw(ghost, reserve, render_context) catch |err| {
            if (err != error.BudgetExceeded) return err;
            continue;
        };
    }
}

/// Draws the timeline below its transport bar; see `sequencer.zig`. `rect` is where it draws
/// in `render_context`, whose origin is `window_origin` in the window, where pointers are.
pub fn render(reads: *session.ReadContext, rect: panels_mod.Rect, window_origin: session.Vec2, render_context: *roop.Context) void {
    const tables = reads.tables;
    const atoms = reads.atoms;
    if (!enabled(session.get(tables))) return;
    const settings = config(tables);
    render_context.save();
    defer render_context.restore();
    render_context.intersectScissor(rect.x, rect.y, rect.w, rect.h, 0);
    const clip = clipRowWithReads(reads) orelse {
        render_context.beginPath();
        render_context.rect(rect.x, rect.y, rect.w, rect.h);
        render_context.fillColor(style.col.canvas);
        render_context.fill();
        render_context.fontFace(style.ui_font);
        render_context.textAlign(.{ .left = true, .baseline = true });
        render_context.fillColor(style.col.text_dim);
        _ = render_context.text(rect.x + 12, rect.y + clip_sequencer.controls_height + 28, "No clip yet: add one from the Properties panel");
        return;
    };
    const model, const durations = lanes: {
        const zone = Log.zone(Zone.timeline_lanes);
        defer zone.end();
        const model = (modelWithReads(reads) catch return) orelse return;
        const allocator = reads.readAllocator() catch return;
        const durations = holds(allocator, model.keys, clip.frames) catch return;
        break :lanes .{ model, durations };
    };
    const draw_zone = Log.zone(Zone.timeline_draw);
    defer draw_zone.end();
    const timeline = timelineGeometry(settings, rect, clip.frames);
    var selected: ?usize = null;
    if (settings.key_selected.* != 0) {
        for (model.keys, 0..) |key, index| if (key.frame == settings.selected_frame.*) {
            selected = index;
        };
    }
    const pointer: ?api.Vec2 = if (settings.hover_x.* >= 0 and settings.dragging.* == Drag.none) .{ .x = settings.hover_x.* - window_origin.x, .y = settings.hover_y.* - window_origin.y } else null;
    clip_sequencer.draw(render_context, atoms, model, timeline, .{
        .playhead = @as(f64, settings.seconds.*) * clip.fps,
        .selected_key = selected,
        .scroll = shownScroll(settings, model, timeline),
        .pointer = pointer,
        .holds = durations,
    });
}
