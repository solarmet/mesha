//! The figure editor's questions to the figure host, asked by command (`mesha.figure.Query`) and
//! answered in the asking system's inbox the frame after: a row of `editor_figure_asks` per
//! question in flight, which names why it was asked (its purpose), of which document, and what
//! its asker needs again to go on (a point and a value). A system's `take_answers` kernel, first
//! in it, finds each answer's row by the serial the answer carries back, drops the answer when
//! its row is gone or names another document, and goes on with what the purpose asked for.
//!
//! A purpose keeps at most one question, so asking again replaces the row and the older answer
//! finds none, except the eraser's samples, each of which keeps its own. While a question that
//! decides what a press does is in flight, the canvas holds the pointer's later messages back
//! (`gesture.hold`) and applies them after the answer, in order; while one a drag goes on from is
//! in flight, the drag sends nothing more and does not end (`awaited`).
const mesha = @import("mesha");
const std = @import("std");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory = mesha.memory;
const figure = mesha.figure;
const sequencer = mesha.sequencer;
const session = @import("session.zig");
const preview = @import("preview.zig");

pub const name = "editor_figure_asks";
/// Enough for the eraser's samples of a fast stroke over a frame or two.
const capacity = 2048;

/// A question in flight.
pub const Ask = struct {
    /// Which question it is: the user data its answer comes back with. Never 0.
    serial: u32 = 0,
    /// Why it was asked, a `Purpose`.
    purpose: Atom = session.none,
    /// The document asked about; an answer for another than the open one is dropped.
    document: Atom = session.none,
    /// Where the asker was looking, in document space.
    point: session.Vec2 = session.zero,
    /// What else the purpose needs again to go on, as it packs it.
    value: u32 = 0,
    /// The clock's frame (`time.FrameCountView`) of the first `take_answers` that found it
    /// waiting, which ages it; `unstamped` until then.
    asked_at: u64 = unstamped,
};

/// `Ask.asked_at` of a question no `take_answers` has seen waiting yet.
pub const unstamped = std.math.maxInt(u64);

/// How many frames a question that holds the pointer, or that a drag waits for, may wait before
/// it is given up. Its answer comes the frame after it was asked; an inbox that refused it is
/// offered it again at each later frame, so eight leaves room for a few refusals, while a lost
/// answer (one the host gave up, as while it reloads) frees the pointer within about a tenth of a
/// second at 60 Hz.
pub const answer_frames_max: u64 = 8;
pub const Rows = sequencer.Rows(session.Row(Ask));
pub fn rows(tables: *Table.Registry) Rows {
    return .of(tables.findByName(Atom.from(name)).?);
}

/// The tag answers arrive under; their user data is the question's serial.
pub const Msg = enum(u64) {
    figure_answer = Atom.from("figure_answer").value(),
    _,
};

/// Why a question was asked, and so what goes on with its answer.
pub const Purpose = enum(u64) {
    /// What the pointer is over on the canvas; the view's.
    hover = Atom.from("hover").value(),
    /// What a Select press picks, when no bone or handle took it. `value` is the press's
    /// `gesture.Modifiers` bits, as for the other presses that carry one.
    select_press = Atom.from("select_press").value(),
    /// What a Select double-click would edit the points of.
    point_edit_press = Atom.from("point_edit_press").value(),
    /// The colour the eyedropper's press samples.
    eyedropper_press = Atom.from("eyedropper_press").value(),
    /// The colour a press samples for the colour popover.
    color_sample_press = Atom.from("color_sample_press").value(),
    /// What the weight brush's press chooses or paints.
    weight_press = Atom.from("weight_press").value(),
    /// What a right-click opens the canvas menu over.
    menu_press = Atom.from("menu_press").value(),
    /// The artwork a released marquee gathers. `value` is 1 when it subtracts.
    marquee = Atom.from("marquee").value(),
    /// What an eraser sample claims.
    erase = Atom.from("erase").value(),
    /// The colour of the paint under the hover, when the shape it found is painted; the view's.
    /// `value` is the shape.
    hover_paint = Atom.from("hover_paint").value(),
    /// The colour of the paint the eyedropper's press found. `value` is the shape.
    eyedropper_paint = Atom.from("eyedropper_paint").value(),
    /// The colour of the paint the colour popover's sampling press found. `value` is the shape.
    color_sample_paint = Atom.from("color_sample_paint").value(),
    /// Where the selected shape's paint lies, for the gradient tools' handles; the drawing
    /// system's. `value` is the shape.
    paint_handles = Atom.from("paint_handles").value(),
    /// A released gradient drag's start carried into the paint's space. `value` is the shape.
    gradient_start = Atom.from("gradient_start").value(),
    /// A released gradient drag's end carried into the paint's space. `value` is the shape.
    gradient_end = Atom.from("gradient_end").value(),
    /// The solve an Auto IK press starts from: the bend the chain has at rest in its pose.
    pose_press = Atom.from("pose_press").value(),
    /// The solve of an Auto IK drag's latest target; the gesture system's.
    pose_drag = Atom.from("pose_drag").value(),
    /// The selected shapes as the clipboard keeps them; the drawing system's. `value` is what the
    /// copy is for, a `drawing.ClipboardUse`.
    clipboard = Atom.from("clipboard").value(),
    _,
};

/// Which query a purpose asks, and so which answer it takes.
pub fn kindFor(purpose: Purpose) figure.QueryKind {
    return switch (purpose) {
        .hover_paint, .eyedropper_paint, .color_sample_paint, .paint_handles, .gradient_start, .gradient_end => .paint_mapping,
        .pose_press, .pose_drag => .solve_transient_pose,
        .clipboard => .encode_shape_clipboard,
        else => .hit_test,
    };
}

/// Which pointer messages wait while a question is in flight.
pub const Holds = enum(u8) {
    /// None: the answer only shows something.
    nothing,
    /// Presses and releases: movement still samples, but the gesture cannot end before it.
    ends,
    /// Every one: the answer decides what the press is.
    everything,
};

/// What a purpose holds back while it is asked.
pub fn holdsFor(purpose: Purpose) Holds {
    return switch (purpose) {
        .hover, .hover_paint, .paint_handles => .nothing,
        // A pose drag samples on and waits for these itself (`awaited`).
        .pose_press, .pose_drag => .nothing,
        .erase => .ends,
        else => .everything,
    };
}

/// Whether a drag waits for `purpose`'s answer before it previews again or ends: the Auto IK
/// drag's solves, whose answers its previews are made of.
fn awaitedFor(purpose: Purpose) bool {
    return purpose == .pose_press or purpose == .pose_drag;
}

/// Whether a question a drag waits for is in flight (`awaitedFor`).
pub fn awaited(asked: Rows) bool {
    var entries = asked.read();
    while (entries.next()) |entry| {
        const purpose = entry.view.purpose.*.to(Purpose);
        if (awaitedFor(purpose)) return true;
    }
    return false;
}

/// Whether asking again for `purpose` keeps the earlier question: only the eraser's samples,
/// each of which claims what lies under it.
fn keepsEvery(purpose: Purpose) bool {
    return purpose == .erase;
}

/// What any question in flight holds back.
pub fn holding(asked: Rows) Holds {
    var result: Holds = .nothing;
    var entries = asked.read();
    while (entries.next()) |entry| {
        const purpose = entry.view.purpose.*.to(Purpose);
        const holds = holdsFor(purpose);
        if (@intFromEnum(holds) > @intFromEnum(result)) result = holds;
    }
    return result;
}

/// Why a question is asked and what its row keeps for the answer: for a hit test, the point to
/// look at or with `rectangle` what a marquee touches.
pub const Question = struct {
    purpose: Purpose,
    /// In document space; given back with the answer.
    point: session.Vec2,
    /// A hit test's marquee; null for a point, and for any other question.
    rectangle: ?figure.Bounds = null,
    /// Given back with the answer.
    value: u32 = 0,
};

/// Asks which shapes of the pose the canvas shows lie under `question`'s point, or in its
/// rectangle, within the canvas's 4 screen pixels, answered in `asker`'s inbox. The asker's
/// system declares this table and `commands.figure_queries` written.
pub fn hitTest(tables: *Table.Registry, atoms: *Atom.Registry, asker: sequencer.System, question: Question) !void {
    const shown = try preview.current(tables, atoms);
    const editor = session.get(tables);
    const tolerance = 4 / editor.view_zoom.*;
    const query: figure.Query = .{ .hit_test = .{
        .figure = shown,
        .query = .{ .point = question.point, .rectangle = question.rectangle, .tolerance = tolerance },
    } };
    const context = session.figureContext(tables, atoms);
    const asked = rows(tables);
    try ask(context, asked, editor, asker, query, question);
}

/// Asks where `paint` of `shape` lies in the pose the canvas shows (`figure.PaintMapping`), and
/// with `point` what that point is in the paint's space and the paint's colour there, answered
/// in `asker`'s inbox; a null `paint` maps `point` into the shape's bind space. The asker's
/// system declares this table and `commands.figure_queries` written.
pub fn paintMapping(tables: *Table.Registry, atoms: *Atom.Registry, asker: sequencer.System, question: Question, shape: u32, paint: ?u32, point: ?session.Vec2) !void {
    const shown = try preview.current(tables, atoms);
    const query: figure.Query = .{ .paint_mapping = .{ .figure = shown, .shape = shape, .paint = paint, .point = point } };
    const context = session.figureContext(tables, atoms);
    const asked = rows(tables);
    const editor = session.get(tables);
    try ask(context, asked, editor, asker, query, question);
}

/// Appends `query` to `commands.figure_queries` with a row that remembers `question`, replacing
/// the purpose's earlier question unless it keeps every one. Its slices are copied.
pub fn ask(context: figure.Context, asked: Rows, editor: session.View, asker: sequencer.System, query: figure.Query, question: Question) !void {
    if (!keepsEvery(question.purpose)) forget(asked, question.purpose);
    var serial = editor.ask_serial.* +% 1;
    if (serial == 0) serial = 1;
    editor.ask_serial.* = serial;
    const row = try asked.insert(Ask{
        .serial = serial,
        .purpose = .from(question.purpose),
        .document = editor.doc.*,
        .point = question.point,
        .value = question.value,
    });
    errdefer asked.free(row);
    const reply_to = sequencer.ReplyTo.of(asker, .from(Msg.figure_answer));
    const reply = reply_to.with(.of(&serial));
    try figure.appendQuery(context, .{ .query = query, .reply = reply });
}

/// Forgets the questions asked for `purpose`: their answers will change nothing.
pub fn forget(asked: Rows, purpose: Purpose) void {
    const purpose_atom: Atom = .from(purpose);
    var entries = asked.query();
    while (entries.next()) |entry| {
        if (entry.view.purpose.* == purpose_atom) asked.free(entry.handle);
    }
}

/// Forgets every question that holds the pointer back or that a drag waits for, as cancelling
/// does.
pub fn forgetHolding(asked: Rows) void {
    var entries = asked.query();
    while (entries.next()) |entry| {
        const purpose = entry.view.purpose.*.to(Purpose);
        if (holdsFor(purpose) != .nothing or awaitedFor(purpose)) asked.free(entry.handle);
    }
}

/// Whether a question for `purpose` is in flight.
pub fn pending(asked: Rows, purpose: Purpose) bool {
    const purpose_atom: Atom = .from(purpose);
    var entries = asked.read();
    while (entries.next()) |entry| {
        if (entry.view.purpose.* == purpose_atom) return true;
    }
    return false;
}

/// An answer to a question still asked, as its purpose goes on with it.
pub const Answer = struct {
    purpose: Purpose,
    point: session.Vec2,
    value: u32,
    /// Why the host could not answer, or `none`.
    failure: figure.Failure,
    /// The message: what the answer carries lies in the inbox's arena until the inbox is
    /// cleared, at the end of the run.
    message: sequencer.Message,

    /// The shapes found, frontmost first; empty for a failed answer.
    pub fn hits(answer: Answer) []const figure.Hit {
        return figure.QueryAnswer.hits(answer.message);
    }

    /// Where the paint lies, for a paint mapping; its defaults for a failed answer.
    pub fn paint(answer: Answer) figure.PaintMapping {
        const head = figure.QueryAnswer.of(answer.message) catch return .{ .effective_revision = 0 };
        return head.paint;
    }

    /// The rest of a solve's answer; its defaults for a failed answer.
    pub fn solution(answer: Answer) figure.QueryAnswer.Solution {
        const head = figure.QueryAnswer.of(answer.message) catch return .{};
        return head.solution;
    }

    /// The solved channels, one per bone of the chain, only their rotation set; empty for a
    /// failed answer.
    pub fn channels(answer: Answer) []const figure.PoseChannels {
        return figure.QueryAnswer.channels(answer.message);
    }

    /// The clipboard's bytes; empty for a failed answer.
    pub fn bytes(answer: Answer) []const u8 {
        return figure.QueryAnswer.bytes(answer.message);
    }
};

/// The question `received` answers, which it forgets: null for a message that is not an
/// answer, an answer whose question was replaced, forgotten or given up, or one asked about
/// another document than `document` or of another kind than its purposes ask.
pub fn take(asked: Rows, document: Atom, received: sequencer.Message) ?Answer {
    if (received.tag.to(Msg) != .figure_answer) return null;
    const serial = received.userDataAs(u32) catch |err| {
        received.unreadable(err);
        return null;
    };
    const head = figure.QueryAnswer.of(received) catch |err| {
        received.unreadable(err);
        return null;
    };
    var entries = asked.query();
    while (entries.next()) |entry| {
        if (entry.view.serial.* != serial.*) continue;
        const kept: Ask = .{
            .serial = entry.view.serial.*,
            .purpose = entry.view.purpose.*,
            .document = entry.view.document.*,
            .point = entry.view.point.*,
            .value = entry.view.value.*,
        };
        asked.free(entry.handle);
        if (kept.document != document) return null;
        const purpose = kept.purpose.to(Purpose);
        if (head.kind != kindFor(purpose)) return null;
        return .{ .purpose = purpose, .point = kept.point, .value = kept.value, .failure = head.failure, .message = received };
    }
    return null;
}

/// Marks the questions no `take_answers` has seen waiting yet as waiting since frame `now`.
pub fn stamp(asked: Rows, now: u64) void {
    var entries = asked.query();
    while (entries.next()) |entry| {
        if (entry.view.asked_at.* == unstamped) entry.view.asked_at.* = now;
    }
}

/// Gives up the questions that hold the pointer, or that a drag waits for, and have waited
/// `answer_frames_max` frames or more by frame `now`; the purpose of one of them, or null when
/// there were none.
pub fn expire(asked: Rows, now: u64) ?Purpose {
    var expired: ?Purpose = null;
    var entries = asked.query();
    while (entries.next()) |entry| {
        const purpose = entry.view.purpose.*.to(Purpose);
        if (holdsFor(purpose) == .nothing and !awaitedFor(purpose)) continue;
        const since = entry.view.asked_at.*;
        if (since == unstamped or now < since) continue;
        if (now - since < answer_frames_max) continue;
        asked.free(entry.handle);
        expired = purpose;
    }
    return expired;
}

/// What the person is told when a question for `purpose` is given up (`expire`), and what was
/// cancelled with it. A static string.
pub fn givenUpText(purpose: Purpose) []const u8 {
    return switch (purpose) {
        .pose_press, .pose_drag => "The figure host did not answer in time; the pose drag was cancelled",
        .clipboard => "The figure host did not answer in time; the copy was cancelled",
        .gradient_start, .gradient_end => "The figure host did not answer in time; the gradient edit was cancelled",
        .eyedropper_paint, .color_sample_paint => "The figure host did not answer in time; the colour sample was cancelled",
        else => "The figure host did not answer in time; the press was cancelled",
    };
}

pub fn ensure(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const previous = tables.scope;
    tables.scope = .editor;
    defer tables.scope = previous;
    _ = try session.ensureTable(Ask, mem, atoms, tables, name, capacity);
}

pub fn prepareInit(mem: *memory.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try session.prepareTable(Ask, mem, atoms, tables, name, capacity);
}
