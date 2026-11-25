//! The contract of the editor's action palette, the prompt on the minibuffer's line, and of its
//! status bar: what a system hands the palette to ask a person something, and what it hears back.
//!
//! A requester fills a `Completions`, the question and the entries it offers, in memory that
//! outlasts the request, and asks the palette to present it, naming where the answer goes (a
//! `sequencer.ReplyTo`). The palette answers with events in that inbox: `query_changed` as the
//! text typed changes, and one `completed` when the request ends, with the entry chosen or with
//! none. A receiver reads an event from its message with `eventOf`; `eventPayload` is how the
//! palette writes one.
//!
//! Tab completes the text to the selected entry, as vertico's `vertico-insert` does: the text
//! becomes the entry's `completes_to`, or its `label` when it has none, unless the request's
//! `tab` says Tab leaves the text. It never moves the selection; in a dialog, which takes no
//! text, Tab selects the next button.
//!
//! `CmdPayload` is what the editor plugin's `commands.app` rows carry for the palette
//! (`plugin.app_commands`).
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const sequencer = @import("../core/sequencer.zig");

/// The prompt row's inline text. Prompt text past it moves to growing storage.
pub const kBufSize: usize = 256;
/// The bytes of a completion's `data`.
pub const kCompletionDataSize: usize = 64;

/// One entry a prompt offers. Display strings are owner-provided while offered. A chosen
/// completion reaches its requester as a copy, so nothing keeps the owner's storage alive past
/// the choice.
pub const Completion = struct {
    /// The owner's own text for the entry, such as a path. The palette does not show it; it comes
    /// back with the choice.
    key: []const u8 = "",
    /// What the list shows for the entry.
    label: []const u8,
    /// More of the owner's text about the entry, which comes back with the choice.
    detail: []const u8 = "",
    /// The owner's own bytes for the entry, which come back with the choice.
    data: [kCompletionDataSize]u8 = [_]u8{0} ** kCompletionDataSize,
    /// The text Tab makes the prompt's while this entry is selected; null means `label`. Set
    /// it where the label is not what the text should become: a label with words added, or a
    /// path shown short whose whole path is the answer; the text as it is, even empty, for an
    /// entry Tab leaves the text at. Owner-provided like the rest, and it does not come back
    /// with the choice.
    completes_to: ?[]const u8 = null,
};

/// A request to the palette: what to ask and the entries to offer. The palette keeps a pointer to
/// it, so it and everything it points at must remain valid while the request is open.
pub const Completions = struct {
    /// How the palette shows a request.
    pub const Presentation = enum(u8) {
        /// Text typed in the minibuffer's line, its completions listed above it.
        prompt,
        /// A question in the minibuffer's line, its answers a row of buttons above it.
        dialog,
        /// Takes text like a prompt, but the requester's own panel draws the text and caret.
        /// A click anywhere else commits, as leaving a field does in Figma.
        inline_field,

        /// Whether typing edits the request's text: every presentation but `dialog`.
        pub fn takesText(self: Presentation) bool {
            return self != .dialog;
        }
    };

    /// What typing does to `initial_query` when the request opens: replaces it, selected, or
    /// adds to its end, as to a directory a path is being typed in.
    pub const InitialQueryEdit = enum(u8) { replace, append };

    /// What Tab does to the text.
    pub const Tab = enum(u8) {
        /// Makes the text the selected entry's `completes_to`, or its `label`.
        selected,
        /// Leaves the text: it is a pattern and not a name, as ripgrep's is, or the entries are
        /// not what it could become.
        nothing,
    };

    /// Opaque owner identifier; the action palette never interprets it.
    owner: Atom = @enumFromInt(0),
    /// The owner's own number for the request, which the palette never interprets either: an
    /// owner tells its requests apart by it.
    identity: u64 = 0,
    /// How the request is shown.
    presentation: Presentation = .prompt,
    /// The label before the text on the minibuffer's line.
    prompt: []const u8 = "",
    /// The text the prompt opens with.
    initial_query: []const u8 = "",
    /// What typing does to `initial_query`.
    initial_query_edit: InitialQueryEdit = .replace,
    /// What Tab does to the text. A dialog's Tab selects its next button whatever this says.
    tab: Tab = .selected,
    /// The request's title, shown on the minibuffer's line.
    title: []const u8 = "",
    /// More for the person to read, shown with the request.
    body: []const u8 = "",
    /// A dialog's entry selected as it opens; null selects none.
    default_entry: ?u32 = null,
    /// With no entries, a submit ends the prompt with the text typed and a completion that
    /// holds nothing, so its owner can tell it from a cancel; without this it does nothing.
    accepts_text: bool = false,
    /// The entries offered, in the order listed.
    entries: []const Completion,
};

/// The palette's messages: the events it answers a requester with, and the tags its own keys and
/// clicks arrive under.
pub const Msg = struct {
    /// What an event tells: `query_changed`, the text typed changed; `completed`, the request
    /// ended, with an entry chosen or with none.
    pub const EventKind = enum(u8) { query_changed, completed };

    /// An event as its receiver reads it (`eventOf`). Its texts are the message's own payload,
    /// the inbox arena's until the inbox is cleared, whatever happens to the request or its
    /// arena meanwhile. Copy to keep them longer.
    pub const Event = struct {
        /// What happened.
        kind: EventKind,
        /// The entry chosen; null when there is none.
        completion: ?Completion,
        /// The text typed.
        query: []const u8,
    };

    /// The fixed part of an event's payload. The texts follow it, one after another: the
    /// query, then the chosen completion's key, label and detail, each empty when nothing
    /// was chosen.
    pub const EventHead = extern struct {
        /// The query's length in bytes.
        query_len: u32,
        /// The chosen completion's key's length in bytes.
        key_len: u32,
        /// The chosen completion's label's length in bytes.
        label_len: u32,
        /// The chosen completion's detail's length in bytes.
        detail_len: u32,
        /// An `EventKind`.
        kind: u8,
        /// 1 when a completion was chosen, 0 when not.
        chosen: u8,
        /// Zero, so the payload's bytes are all the sender's.
        padding: [2]u8 = @splat(0),
        /// The chosen completion's `data`; zeros when nothing was chosen.
        data: [kCompletionDataSize]u8,
    };

    /// The tag a character typed at the prompt arrives under.
    pub const char = Atom.from("action_palette_char");
    /// The tag of the left arrow at the prompt.
    pub const left = Atom.from("action_palette_left");
    /// The tag of the right arrow at the prompt.
    pub const right = Atom.from("action_palette_right");
    /// The tag of the up arrow, and of Shift with Tab, at the prompt.
    pub const up = Atom.from("action_palette_up");
    /// The tag of the down arrow, and of Tab, at the prompt.
    pub const down = Atom.from("action_palette_down");
    /// The tag of Enter at the prompt, and of a click outside an inline field.
    pub const submit = Atom.from("action_palette_submit");
    /// The tag of Escape at the prompt, and of a click outside a prompt or a dialog.
    pub const cancel = Atom.from("action_palette_cancel");
    /// The tag of a click the palette takes and does nothing with.
    pub const consume = Atom.from("action_palette_consume");
    /// The tag of a click on an entry, which chooses it.
    pub const invoke = Atom.from("action_palette_invoke");
};

/// The payload of `event`, its head then its texts, in `allocator`'s memory.
pub fn eventPayload(allocator: std.mem.Allocator, event: Msg.Event) error{ OutOfMemory, Overflow }![]u8 {
    const chosen = event.completion orelse Completion{ .label = "" };
    const texts = [_][]const u8{ event.query, chosen.key, chosen.label, chosen.detail };
    const head: Msg.EventHead = .{
        .query_len = try textLength(event.query),
        .key_len = try textLength(chosen.key),
        .label_len = try textLength(chosen.label),
        .detail_len = try textLength(chosen.detail),
        .kind = @intFromEnum(event.kind),
        .chosen = @intFromBool(event.completion != null),
        .data = chosen.data,
    };
    var length: usize = @sizeOf(Msg.EventHead);
    for (texts) |text| length += text.len;
    const payload = try allocator.alloc(u8, length);
    @memcpy(payload[0..@sizeOf(Msg.EventHead)], std.mem.asBytes(&head));
    var offset: usize = @sizeOf(Msg.EventHead);
    for (texts) |text| {
        @memcpy(payload[offset..][0..text.len], text);
        offset += text.len;
    }
    return payload;
}

fn textLength(text: []const u8) error{Overflow}!u32 {
    return std.math.cast(u32, text.len) orelse error.Overflow;
}

/// The palette event `received` carries, its texts pointing into the message's payload; an
/// error when the payload's length is not its head's and the texts' it names.
pub fn eventOf(received: sequencer.Message) error{MessageShape}!Msg.Event {
    const payload = received.payload;
    if (payload.len < @sizeOf(Msg.EventHead)) return error.MessageShape;
    const head = std.mem.bytesToValue(Msg.EventHead, payload[0..@sizeOf(Msg.EventHead)]);
    const kind = std.enums.fromInt(Msg.EventKind, head.kind) orelse return error.MessageShape;
    if (head.chosen > 1) return error.MessageShape;
    const lengths = [_]u32{ head.query_len, head.key_len, head.label_len, head.detail_len };
    var texts: [lengths.len][]const u8 = undefined;
    var offset: usize = @sizeOf(Msg.EventHead);
    for (lengths, 0..) |length, index| {
        if (payload.len - offset < length) return error.MessageShape;
        texts[index] = payload[offset..][0..length];
        offset += length;
    }
    if (offset != payload.len) return error.MessageShape;
    const completion: ?Completion = if (head.chosen == 1) .{
        .key = texts[1],
        .label = texts[2],
        .detail = texts[3],
        .data = head.data,
    } else null;
    return .{ .kind = kind, .completion = completion, .query = texts[0] };
}

/// The action palette's commands. `emit` is its answer to a requester, which the plugin's
/// command hook delivers. `present`, `replace` and `dismiss` the hook appends as requests for
/// the palette's run, as the editor's own modules append them directly. Tag ordinals are kept,
/// as a held command outlives a reload of the plugin.
pub const CmdPayload = union(enum) {
    /// Opens the request `completions` points at, answering `reply` with its events.
    present: struct { completions: *const Completions, reply: sequencer.ReplyTo },
    /// Shows `completions` in place of the open request's, keeping the request open.
    replace: struct { completions: *const Completions },
    /// Ends the open request; its requester hears `completed` with no entry.
    dismiss: struct {},
    /// One event for a requester, delivered to `reply`. A `completed` its inbox cannot take is
    /// kept and tried again.
    emit: struct {
        /// Where the event goes.
        reply: sequencer.ReplyTo,
        /// What happened.
        kind: Msg.EventKind,
        /// Copied with the command, like `query`: these outlive the request across a hold.
        completion: ?Completion = null,
        /// The text typed.
        query: []const u8 = "",
        /// Already counted in the palette's `held_responses`, which landing uncounts.
        counted_as_held: bool = false,
    },
};

/// A request to the editor's status bar.
pub const StatusBarCmd = union(enum) {
    /// Shows `text` in the status bar as what the pointer is over. The text is copied into
    /// command storage at submission and into the bar on processing.
    set_hover: []const u8,
    /// Shows nothing as what the pointer is over.
    clear_hover,
};
