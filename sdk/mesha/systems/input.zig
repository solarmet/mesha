//! Input's contract: the keys, pointer and text events the platform delivers, the subscriptions
//! systems append to `subscriptions.input`, the requests simulated input makes, and the tables
//! other systems read. The host system that batches and delivers them is the runtime's
//! (`mesha_runtime.input`).
//!
//! A system hears input by appending a row per `Subscription` to `subscriptions.input` in its run
//! (`appendSubscription` of a `subscriptionRow`), naming its inbox, a tag and its `Source`. Each
//! frame the host gathers the platform's events into a batch and delivers each `Event`, in order,
//! to every subscription it matches: a message in the subscription's inbox under its tag, with
//! the payload its kind sends (`MouseButtonMsg`, `KeyInputMsg` and the others) and the
//! subscription's user data. A `local` subscription fires only while its source owns the focused
//! panel. While any subscription sets `capture`, only the capturing ones receive.
//!
//! An `on_mouse` subscription names a table of hit regions instead of a tag: a press or a wheel
//! goes to the topmost region under the pointer, under that region's own tag (`region_routes`),
//! and the element the pointer is over is kept in `input.hover`.
//!
//! Pointer positions are framebuffer pixels from the window's top left. Simulated input
//! (`CmdPayload`, rows of `commands.input`) joins the batch of the frame after it is asked.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");
const math = @import("../core/math.zig");

/// A key, by its place on the keyboard: each is named for what a US layout prints there, whatever
/// layout the person types with. The characters typed arrive apart, as `TextInputMsg`.
pub const Key = enum {
    space,
    apostrophe,
    comma,
    minus,
    period,
    slash,
    /// The digit row's `0`.
    @"0",
    /// The digit row's `1`.
    @"1",
    /// The digit row's `2`.
    @"2",
    /// The digit row's `3`.
    @"3",
    /// The digit row's `4`.
    @"4",
    /// The digit row's `5`.
    @"5",
    /// The digit row's `6`.
    @"6",
    /// The digit row's `7`.
    @"7",
    /// The digit row's `8`.
    @"8",
    /// The digit row's `9`.
    @"9",
    semicolon,
    equal,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    left_bracket,
    backslash,
    right_bracket,
    /// The backquote key, left of the digit row.
    grave_accent,
    /// The key beside Enter that a US keyboard lacks (ISO `#`).
    world_1,
    /// The key beside the left Shift that a US keyboard lacks (ISO `\`).
    world_2,

    /// Escape; `ESC` in a chord.
    escape,
    /// Enter, on the main block; `RET` in a chord.
    enter,
    /// Tab; `TAB` in a chord.
    tab,
    /// Backspace; `DEL` in a chord.
    backspace,
    insert,
    /// Delete, forward.
    delete,
    right,
    left,
    down,
    up,
    page_up,
    page_down,
    home,
    end,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,

    /// The keypad's `0`.
    kp_0,
    /// The keypad's `1`.
    kp_1,
    /// The keypad's `2`.
    kp_2,
    /// The keypad's `3`.
    kp_3,
    /// The keypad's `4`.
    kp_4,
    /// The keypad's `5`.
    kp_5,
    /// The keypad's `6`.
    kp_6,
    /// The keypad's `7`.
    kp_7,
    /// The keypad's `8`.
    kp_8,
    /// The keypad's `9`.
    kp_9,
    /// The keypad's `.`.
    kp_decimal,
    /// The keypad's `/`.
    kp_divide,
    /// The keypad's `*`.
    kp_multiply,
    /// The keypad's `-`.
    kp_subtract,
    /// The keypad's `+`.
    kp_add,
    /// The keypad's Enter.
    kp_enter,
    /// The keypad's `=`.
    kp_equal,

    /// The left Shift.
    left_shift,
    /// The left Control.
    left_ctrl,
    /// The left Alt.
    left_alt,
    /// The left Super (Windows, Command).
    left_super,
    /// The right Shift.
    right_shift,
    /// The right Control.
    right_ctrl,
    /// The right Alt.
    right_alt,
    /// The right Super (Windows, Command).
    right_super,
    /// The Menu (Application) key.
    menu,
};

/// A mouse button.
pub const MouseButton = enum { left, right, middle };
/// Whether a button went down or came up.
pub const MouseAction = enum { press, release };

/// Whether `key` is a modifier: a Shift, Control, Alt or Super key, or Menu. A modifier's press
/// is no part of a key sequence, and a `key_input` subscription does not hear it.
pub fn isModifierKey(key: Key) bool {
    return switch (key) {
        .left_shift,
        .left_ctrl,
        .left_alt,
        .left_super,
        .right_shift,
        .right_ctrl,
        .right_alt,
        .right_super,
        .menu,
        => true,
        else => false,
    };
}

/// How many keys `Key` has; every key's number is below it.
pub const num_keys = @typeInfo(Key).@"enum".fields.len;

/// The modifiers held as an event arrived; either key of a pair counts.
pub const ModifierState = struct { shift: bool = false, control: bool = false, alt: bool = false, super: bool = false };
/// A button's payload, for a button subscription, a hit region's click or a release: where the
/// pointer was (`x`, `y`, framebuffer pixels), which button, whether the press was the first,
/// second or third of a run of clicks (`clicks`), and the modifiers held. A key going down or up
/// carries no payload: its tag is all it says.
pub const MouseButtonMsg = struct { x: f32, y: f32, button: MouseButton = .left, clicks: u8 = 1, modifiers: ModifierState = .{} };

/// How a subscription treats one modifier: `any` does not care, `required` wants it held,
/// `forbidden` wants it not held.
pub const ModifierMatch = enum { any, required, forbidden };

/// Which modifiers an event must have had held for a subscription to match it.
pub const ModifierFilter = struct {
    /// What Shift must be.
    shift: ModifierMatch = .any,
    /// What Control must be.
    control: ModifierMatch = .any,
    /// What Alt must be.
    alt: ModifierMatch = .any,
    /// What Super must be.
    super: ModifierMatch = .any,
};

/// An editing operation asked of whatever takes text, apart from the characters typed. It comes
/// from simulated input (`CmdPayload.text_input`) or from a key subscription that names one
/// (`text_navigation`).
pub const TextNavigation = enum {
    /// Move one character forward.
    forward_character,
    /// Move one character back.
    backward_character,
    /// Move one word forward.
    forward_word,
    /// Move one word back.
    backward_word,
    /// Move to the next line.
    next_line,
    /// Move to the previous line.
    prev_line,
    /// Move to the line's beginning.
    beginning_of_line,
    /// Move to the line's end.
    end_of_line,
    /// Delete the character after the caret.
    delete,
    /// Kill from the caret to the line's end.
    kill_line,
    /// Kill the word after the caret.
    kill_word_forward,
    /// Kill the word before the caret.
    kill_word_back,
    /// Insert the clipboard's text.
    paste,
    /// Copy the selection.
    copy,
    /// Move a page down.
    page_down,
    /// Move a page up.
    page_up,
};

/// A press or an operating system repeat of any key but a modifier, with what was held.
pub const KeyInputMsg = struct { key: Key, modifiers: ModifierState };

/// A pointer motion's payload: where the pointer is, in framebuffer pixels, and the modifiers
/// held.
pub const MouseMoveMsg = struct { x: f32, y: f32, modifiers: ModifierState = .{} };
/// A wheel's payload: `x` and `y` are the wheel's deltas, `pointer_x` and `pointer_y` where the
/// pointer is, in framebuffer pixels as a button's and a motion's are.
pub const MouseScrollMsg = struct { x: f32, y: f32, pointer_x: f32 = 0, pointer_y: f32 = 0, modifiers: ModifierState = .{} };
/// Why a capture ended from outside: the host cancelled it (`cancelled`), Escape was pressed, the
/// window lost the focus, or input could not keep every event (`overflow`).
pub const PointerCancelReason = enum { cancelled, escape, focus_lost, overflow };
/// The payload a `pointer_cancel` subscription receives.
pub const PointerCancelMsg = struct { reason: PointerCancelReason };

/// What a `mouse_move` subscription wants of a burst of motion: `latest` lets consecutive motions
/// merge into the last as they arrive, `all` keeps every sample in order.
pub const MovePolicy = enum { latest, all };

/// A typed character's payload: its Unicode scalar value.
pub const TextInputMsg = struct { codepoint: u32 };

/// The UTF-8 of the character `typed` carries, written into `buffer`, which the slice returned
/// views; null for a codepoint that is no Unicode scalar value, which has none.
pub fn typedText(typed: *const TextInputMsg, buffer: *[4]u8) ?[]const u8 {
    const codepoint: u21 = std.math.cast(u21, typed.codepoint) orelse return null;
    const length = std.unicode.utf8Encode(codepoint, buffer) catch return null;
    return buffer[0..length];
}
/// An editing operation's payload.
pub const TextNavigationMsg = struct { operation: TextNavigation };

/// Simulated input, as MCP sends it: a row of `commands.input`, which input takes as if the
/// window had seen it, with the batch of the next frame. `validateCommand` says what is valid.
pub const CmdPayload = union(enum) {
    /// A key goes down. With no modifier flag set and `modifiers_present` false, the event has
    /// the modifiers the host holds.
    key_down: struct {
        /// The key.
        key: Key,
        /// Shift is held for this event.
        shift: bool = false,
        /// Control is held for this event.
        control: bool = false,
        /// Alt is held for this event.
        alt: bool = false,
        /// Super is held for this event.
        super: bool = false,
        /// When true, the modifier flags replace the host's currently-held modifiers.
        modifiers_present: bool = false,
    },
    /// A key comes up; its fields are `key_down`'s.
    key_up: struct {
        /// The key.
        key: Key,
        /// Shift is held for this event.
        shift: bool = false,
        /// Control is held for this event.
        control: bool = false,
        /// Alt is held for this event.
        alt: bool = false,
        /// Super is held for this event.
        super: bool = false,
        /// When true, the modifier flags replace the host's currently-held modifiers.
        modifiers_present: bool = false,
    },
    /// A button goes down or comes up at (`x`, `y`), framebuffer pixels. `clicks` is 1 to 3;
    /// `modifiers` null uses those the host holds.
    mouse_button: struct { button: MouseButton, x: f32, y: f32, action: MouseAction, clicks: u8 = 1, modifiers: ?ModifierState = null },
    /// The pointer moves to (`x`, `y`), framebuffer pixels. `modifiers` null uses those the host
    /// holds.
    mouse_move: struct { x: f32, y: f32, modifiers: ?ModifierState = null },
    /// The wheel turns by (`x`, `y`). `pointer` null leaves the pointer where it last was;
    /// `modifiers` null uses those the host holds.
    mouse_scroll: struct { x: f32, y: f32, pointer: ?math.Vec2f = null, modifiers: ?ModifierState = null },
    /// Text as typed, in order with the frame's other simulated events.
    text_input: union(enum) {
        /// A character, as its Unicode scalar value.
        entry: u32,
        /// An editing operation.
        navigation: TextNavigation,
    },
};

/// A key's part in a sequence of keys: `arm` begins one, `extend` goes on with one and waits
/// for more, `continuation` ends one, and `cancel` drops whichever is pending.
pub const ChordRole = enum { none, arm, extend, continuation, cancel };

/// Names the keys of a sequence pressed so far. The subscriber makes it, as a hash of those
/// keys and their modifiers; the gate only compares it. Zero is no prefix.
pub const ChordPrefix = u64;
/// No prefix: no sequence is pending.
pub const no_chord_prefix: ChordPrefix = 0;

/// What the host tells a dispatch about the sequence under way: it makes one each frame from the
/// keys the actions system keeps in `actions_chords`.
pub const ChordGate = struct {
    /// The prefix pending as the batch begins.
    pending_prefix: ChordPrefix = no_chord_prefix,
};

/// The systems that subscribe to input and own panels: the host's chrome (`host`), the editor
/// plugin's systems and the actions system's keybinds (`plugin`), and the game (`game`). The focused
/// panel's owner is the one whose local subscriptions fire.
pub const Source = enum(u8) { host, plugin, game };

/// Whether a subscription fires only while its system owns the focused panel (`local`), or
/// wherever the focus is (`global`). Releases reach their subscribers either way, so a key or
/// button pressed in one panel and released in another never sticks.
pub const Scope = enum(u8) { local, global };

/// What a `pressed` or a `delay_pressed` subscription asks for: a key, held.
pub const KeySubscription = struct {
    /// The key.
    key: Key,
    /// Whether it fires only while its source owns the focused panel.
    scope: Scope = .local,
    /// Takes part in a capture; see `Subscription`.
    capture: bool = false,
    /// The modifiers the key must have been pressed with.
    modifiers: ModifierFilter = .{},
    /// The tag its messages arrive under; none hears nothing.
    tag: Atom = no_tag,
    /// With an operation, each message carries a `TextNavigationMsg` of it instead of no payload.
    text_navigation: ?TextNavigation = null,
};

/// What a `mouse_button_down` or a `mouse_button_up` subscription asks for. Its messages carry a
/// `MouseButtonMsg`.
pub const MouseButtonSubscription = struct {
    /// The button; null for any.
    button: ?MouseButton = null,
    /// Whether it fires only while its source owns the focused panel. A release reaches its
    /// subscriber either way.
    scope: Scope = .local,
    /// Takes part in a capture; see `Subscription`.
    capture: bool = false,
    /// The tag its messages arrive under; none hears nothing.
    tag: Atom = no_tag,
};

/// What a subscriber asks to hear. Each kind says what it matches and what its messages carry.
///
/// While any subscription in a frame's list sets `capture`, only those subscriptions receive
/// input. The one exception is the release of a key or button held when the capture began, which
/// still reaches its own subscribers so that press-driven state cannot stick. A capture lasts
/// while a subscription that sets `capture` is there, so whoever captures keeps subscribing
/// through the gesture; Escape (when a `pointer_cancel` is among the capturing subscriptions),
/// the window losing the focus, lost events or the host end it from outside.
pub const Subscription = union(enum) {
    /// A key held: a message at each dispatch while the key is down, with no payload.
    pressed: KeySubscription,
    /// A key held, for what repeats: a message on the press, then at each dispatch once the key
    /// has been held for 150 ms, with no payload.
    delay_pressed: KeySubscription,

    /// A key's press: one message, with no payload unless `text_navigation` is set. With a
    /// `chord` role the key is part of a sequence of keys.
    key_down: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// The key.
        key: Key,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The modifiers that must be held.
        modifiers: ModifierFilter = .{},
        /// The tag its message arrives under; none hears nothing.
        tag: Atom = no_tag,

        /// The key's part in a sequence of keys; `none` for a key bound by itself.
        chord: ChordRole = .none,

        /// The pending prefix an `extend` or a `continuation` goes on from.
        prefix: ChordPrefix = no_chord_prefix,
        /// The prefix pending once an `arm` or an `extend` has taken its key.
        arms: ChordPrefix = no_chord_prefix,

        /// With an operation, the message carries a `TextNavigationMsg` of it instead of no
        /// payload.
        text_navigation: ?TextNavigation = null,
    },

    /// A key's release: one message, with no payload.
    key_up: struct {
        /// Releases reach their subscribers whatever their scope.
        scope: Scope = .local,
        /// The key.
        key: Key,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The modifiers that must be held.
        modifiers: ModifierFilter = .{},
        /// The tag its message arrives under; none hears nothing.
        tag: Atom = no_tag,
    },

    /// Every key press and repeat but a modifier's, for a view that interprets the keyboard
    /// itself: a `KeyInputMsg` each.
    key_input: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The tag its messages arrive under; none hears nothing.
        tag: Atom = no_tag,
    },

    /// What ends a capture from outside: Escape, which it consumes, focus loss, input overflow, or
    /// the host. Sends a PointerCancelMsg. The rest of that batch goes nowhere.
    pointer_cancel: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// Takes part in the capture it hears the end of.
        capture: bool = true,
        /// The tag its message arrives under; none hears nothing.
        tag: Atom = no_tag,
    },

    /// A button's press: a `MouseButtonMsg`.
    mouse_button_down: MouseButtonSubscription,
    /// A button's release: a `MouseButtonMsg`.
    mouse_button_up: MouseButtonSubscription,

    /// The pointer's motion: a `MouseMoveMsg` each.
    mouse_move: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// Whether a burst of motion may merge into its last position.
        moves: MovePolicy = .latest,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The tag its messages arrive under; none hears nothing.
        tag: Atom = no_tag,
    },

    /// The wheel: a `MouseScrollMsg` each.
    mouse_scroll: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The modifiers that must be held.
        modifiers: ModifierFilter = .{},
        /// The tag its messages arrive under; none hears nothing.
        tag: Atom = no_tag,
    },

    /// Text: each character typed, a `TextInputMsg` under `tag`, and each editing operation, a
    /// `TextNavigationMsg` under `navigation_tag`. Neither is delivered while a key sequence is
    /// under way or has just ended.
    text_input: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,
        /// The modifiers that must be held as the text arrives.
        modifiers: ModifierFilter = .{},

        /// The tag characters arrive under; none hears no character.
        tag: Atom = no_tag,
        /// The tag typed navigation arrives under; none hears no navigation.
        navigation_tag: Atom = no_tag,
    },

    /// Hit regions. `table` has a row per region: `pos` and `size` (see
    /// `validateMouseTableSchema`), and optionally `depth`, `hover`, `id` and the columns of
    /// `region_routes`. A press goes to the topmost region under the pointer that has a click
    /// route, by `depth` and then by the later row, as a `MouseButtonMsg` under the tag that
    /// region has for the button; a region with any click route takes every press on it. The
    /// wheel goes to the topmost region under the pointer, if it has a scroll route. A motion
    /// moves `input.hover` among the regions whose `hover` is set. A region's message goes to the
    /// inbox its route names, or to the subscription's. `table` is borrowed through the host's
    /// same-frame input dispatch.
    on_mouse: struct {
        /// Whether it fires only while its source owns the focused panel.
        scope: Scope = .local,
        /// The regions.
        table: *const Table,
        /// Takes part in a capture; see `Subscription`.
        capture: bool = false,

        /// Where the regions' origin is, in framebuffer pixels: subtracted from the pointer
        /// before a press or a motion is tested against them.
        offset: math.Vec2f = .{ .x = 0, .y = 0 },

        /// With it, the release of `button` anywhere sends a `MouseButtonMsg` under `tag` to the
        /// subscription's inbox.
        on_release: ?struct {
            /// The button whose release is heard.
            button: MouseButton = .left,
            /// The tag the release arrives under.
            tag: Atom = no_tag,
        } = null,
    },

    /// Whether the subscription sets `capture`.
    pub fn captures(self: Subscription) bool {
        return switch (self) {
            inline else => |subscription| subscription.capture,
        };
    }

    /// The subscription's scope.
    pub fn scope(self: Subscription) Scope {
        return switch (self) {
            inline else => |subscription| subscription.scope,
        };
    }

    /// A release, which reaches its subscribers whatever their scope.
    pub fn isRelease(self: Subscription) bool {
        return switch (self) {
            .key_up, .mouse_button_up => true,
            else => false,
        };
    }
};

/// Systems append a row per subscription in their runs, naming their inbox; a system's rows
/// last until it runs again (`sequencer.ensureSubscriptions`), and input reads the rows there
/// are when it dispatches a batch.
pub const subscriptions_table_name = "subscriptions.input";

/// A subscriber: the subscription, whose tags its messages arrive under in its inbox; the
/// system it came from, for focus scoping, null firing it wherever the focus is; its inbox,
/// none for a subscriber that hears nothing; and the user data its messages carry back, and
/// a text subscription's navigation's. Stored as an `Entry`, which copies the user data
/// (`appendSubscription`).
pub const SubscriptionValues = struct {
    /// What to hear.
    subscription: Subscription,
    /// The system it came from; null fires it wherever the focus is.
    source: ?Source = null,
    /// The inbox its messages go to; none hears nothing.
    inbox: Atom = no_inbox,
    /// What its messages carry back.
    user_data: sequencer.UserData = .none,
    /// What a text subscription's navigation messages carry back.
    navigation_user_data: sequencer.UserData = .none,
};

/// A row of `subscriptions.input` and of the input system's subscriber tables: a subscriber,
/// its user data bytes cells of the table it is in.
pub const Entry = struct {
    /// What to hear.
    subscription: Subscription,
    /// The system it came from; null fires it wherever the focus is.
    source: ?Source = null,
    /// The inbox its messages go to; none hears nothing.
    inbox: Atom = no_inbox,
    /// What its messages carry back: bytes in the table's payloads.
    user_data: Table.Bytes = .{},
    /// What a text subscription's navigation messages carry back: bytes in the table's payloads.
    navigation_user_data: Table.Bytes = .{},
};

/// Appends `values` to `table`, a table of `Entry` rows, copying its user data into the table's
/// payloads. Through a run's layer when the table is attached to one. Fails when the table cannot
/// take the row or the bytes, leaving no row.
pub fn appendSubscription(table: *Table, values: SubscriptionValues) !void {
    const handle = try table.tryInsert(Entry{ .subscription = values.subscription, .source = values.source, .inbox = values.inbox });
    errdefer table.free(handle);
    const user_data = values.user_data.bytes;
    if (user_data.len != 0) try table.setBytes(handle, "user_data", user_data);
    const navigation_user_data = values.navigation_user_data.bytes;
    if (navigation_user_data.len != 0) try table.setBytes(handle, "navigation_user_data", navigation_user_data);
}

/// `input.subscribed`, the input system's own table of the subscriptions pushed through a
/// `Subscriber` while the host collects the frame's subscriptions: the host's chrome's, and the
/// keybinds the actions system makes of the frame's active keymaps. The host clears it before it
/// collects them again.
pub const subscribed_table_name = "input.subscribed";

/// `input.hover`, a single row: the element whose region the pointer is over, among the
/// regions of `on_mouse` tables whose `hover` is set. A zero element is none. Input moves it
/// only when a dispatched motion does, or when the regions under it go. What the element says
/// stays in its region's row, for whoever shows it to read there.
pub const hover_table_name = "input.hover";
/// What the pointer is over.
pub const Hover = struct {
    /// The element's id, as its region's `id` cell has it; all zero for none.
    element: [16]u8 = std.mem.zeroes([16]u8),

    /// Whether the pointer is over an element.
    pub fn isOver(hover: Hover) bool {
        return !std.mem.allEqual(u8, &hover.element, 0);
    }
};

/// Sets what `input.hover` holds, making the table if it is missing: for a host or a test
/// that runs without the input system.
pub fn writeHover(tables: *Table.Registry, atoms: *Atom.Registry, hover: Hover) !void {
    const name = atoms.intern(hover_table_name);
    if (tables.findByName(name) == null) {
        var schema: Table.Schema = undefined;
        try schema.init(tables.memory.globalAllocator(), atoms, 1);
        defer schema.deinit();
        try schema.addFieldFallible("element", [16]u8, .hex);
        _ = try tables.ensureSingleton(&schema, name, Hover{}, .durable);
    }
    const found = tables.findByName(name).?;
    const handle: Table.RowHandle = .{ .row = 0, .generation = found.rowGeneration(0) };
    const row = found.getRow(handle, struct { element: *[16]u8 }).?;
    row.element.* = hover.element;
}

/// What `input.hover` holds, or none while the table is missing.
pub fn hovered(tables: *Table.Registry) Hover {
    const found = tables.findByName(Atom.from(hover_table_name)) orelse return .{};
    const handle: Table.RowHandle = .{ .row = 0, .generation = found.rowGeneration(0) };
    const row = found.getRow(handle, struct { element: *[16]u8 }) orelse return .{};
    return .{ .element = row.element.* };
}

/// What a host system pushes its subscriptions through, outside any run: rows of
/// `input.subscribed` from one source, their messages going to `inbox`. Without a source, its
/// subscriptions fire wherever the focus is.
pub const Subscriber = struct {
    /// The registry `input.subscribed` is found in.
    tables: *Table.Registry,
    /// The system the subscriptions are of; null fires them wherever the focus is.
    source: ?Source,
    /// The inbox table the subscriber's messages are delivered to; none hears nothing.
    inbox: Atom = no_inbox,

    /// Pushes `subscription`, its messages carrying `user_data` back, copied now.
    pub fn push(subscriber: Subscriber, subscription: Subscription, user_data: sequencer.UserData) void {
        const subscribed = subscriber.tables.findByName(Atom.from(subscribed_table_name)) orelse return;
        const row: SubscriptionValues = .{ .subscription = subscription, .source = subscriber.source, .inbox = subscriber.inbox, .user_data = user_data };
        // A subscriber missing from the frame would have its input go elsewhere; the batch
        // stays deliverable to the rest.
        appendSubscription(subscribed, row) catch return;
    }

    /// The subscriptions pushed through any `Subscriber` since the host last cleared
    /// `input.subscribed`.
    pub fn count(subscriber: Subscriber) u32 {
        const subscribed = subscriber.tables.findByName(Atom.from(subscribed_table_name)) orelse return 0;
        return subscribed.count();
    }
};

/// A view of an `Entry` row's subscription, source and inbox.
pub const SubscriptionRow = struct { subscription: *Subscription, source: *?Source, inbox: *Atom };

/// Why a table cannot be an `on_mouse` subscription's regions: it has no `pos` or no `size`
/// column, or its `pos` or `size` is not a `Vec2f`, its `on_click` not an atom's size, its
/// `hover` not a byte or its `depth` not a `u32`.
pub const MouseTableValidationError = error{
    MissingPositionField,
    MissingSizeField,
    InvalidPositionField,
    InvalidSizeField,
    InvalidClickPayloadField,
    InvalidHoverField,
    InvalidDepthField,
};

fn vec2FieldValid(field: Table.FieldDescriptor) bool {
    if (field.size != @sizeOf(math.Vec2f) or field.stride != @sizeOf(math.Vec2f)) return false;
    if (field.field_type) |field_type| if (field_type != .vec2f) return false;
    return switch (field.view_kind) {
        .vector => |cfg| cfg.components == 2,
        else => false,
    };
}

/// A region's click route column holds the tag its message goes under.
fn payloadFieldValid(field: Table.FieldDescriptor) bool {
    return field.size == @sizeOf(Atom) and field.stride == @sizeOf(Atom);
}

/// Checks that a table of `schema` can be an `on_mouse` subscription's regions: `pos` and `size`
/// columns of two floats each, and, where present, `on_click` of an atom's size, `hover` of a
/// byte and `depth` of a `u32`.
pub fn validateMouseTableSchema(schema: *const Table.Schema) MouseTableValidationError!void {
    const pos_idx = schema.fieldIndex("pos") orelse return error.MissingPositionField;
    const size_idx = schema.fieldIndex("size") orelse return error.MissingSizeField;
    if (!vec2FieldValid(schema.fields[pos_idx])) return error.InvalidPositionField;
    if (!vec2FieldValid(schema.fields[size_idx])) return error.InvalidSizeField;
    if (schema.fieldIndex("on_click")) |idx| if (!payloadFieldValid(schema.fields[idx])) return error.InvalidClickPayloadField;
    if (schema.fieldIndex("hover")) |idx| {
        const field = schema.fields[idx];
        if (field.size != @sizeOf(u8) or field.stride != @sizeOf(u8)) return error.InvalidHoverField;
    }
    if (schema.fieldIndex("depth")) |idx| {
        const field = schema.fields[idx];
        if (field.size != @sizeOf(u32) or field.stride != @sizeOf(u32)) return error.InvalidDepthField;
    }
}

/// Why a simulated command is refused: a character that is no Unicode scalar value, a click count
/// outside 1 to 3, or a coordinate or wheel delta that is not finite.
pub const CommandValidationError = error{ InvalidTextCodepoint, InvalidClickCount, InvalidPointerCoordinate };

/// Checks a simulated command before it is taken; key commands are always valid.
pub fn validateCommand(command: CmdPayload) CommandValidationError!void {
    switch (command) {
        .mouse_button => |c| {
            if (c.clicks < 1 or c.clicks > 3) return error.InvalidClickCount;
            if (!std.math.isFinite(c.x) or !std.math.isFinite(c.y)) return error.InvalidPointerCoordinate;
        },
        .mouse_move => |c| {
            if (!std.math.isFinite(c.x) or !std.math.isFinite(c.y)) return error.InvalidPointerCoordinate;
        },
        .mouse_scroll => |c| {
            if (!std.math.isFinite(c.x) or !std.math.isFinite(c.y)) return error.InvalidPointerCoordinate;
            if (c.pointer) |p| if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return error.InvalidPointerCoordinate;
        },
        .text_input => |text| switch (text) {
            .entry => |codepoint| {
                if (codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff))
                    return error.InvalidTextCodepoint;
            },
            .navigation => {},
        },
        else => {},
    }
}

const no_inbox = sequencer.no_inbox;
/// No tag: a subscription that names none hears nothing.
pub const no_tag: Atom = @enumFromInt(0);

/// The event a simulated command stands for. An event has no modifiers: the command's travel
/// beside it.
pub fn toEvent(cmd: CmdPayload) Event {
    return switch (cmd) {
        .key_down => |c| .{ .key_down = c.key },
        .key_up => |c| .{ .key_up = c.key },
        .mouse_button => |c| .{ .mouse_button = .{ .button = c.button, .x = c.x, .y = c.y, .action = c.action, .clicks = c.clicks } },
        .mouse_move => |c| .{ .mouse_move = .{ .x = c.x, .y = c.y } },
        .mouse_scroll => |c| .{ .mouse_scroll = .{ .x = c.x, .y = c.y, .pointer = c.pointer } },
        .text_input => |text| switch (text) {
            .entry => |codepoint| .{ .char_input = codepoint },
            .navigation => |operation| .{ .text_navigation = operation },
        },
    };
}

/// What the platform, or simulated input, tells input. A batch is these in the order they
/// arrived.
pub const Event = union(enum) {
    /// A key went down.
    key_down: Key,
    /// A key came up.
    key_up: Key,
    /// The operating system's repeat of a held key. Seen only by `key_input` subscribers: the
    /// other key subscriptions keep their own repeat timing.
    key_repeat: Key,
    /// The window's size changed. No subscription hears it; the size is `os_window`'s.
    resize: struct { width: u32, height: u32 },
    /// A button went down or came up at (`x`, `y`), framebuffer pixels.
    mouse_button: struct { button: MouseButton, x: f32, y: f32, action: MouseAction, clicks: u8 = 1 },
    /// The pointer moved to (`x`, `y`), framebuffer pixels.
    mouse_move: struct { x: f32, y: f32 },
    /// The wheel turned by (`x`, `y`). `pointer` null stands for where the pointer last was.
    mouse_scroll: struct { x: f32, y: f32, pointer: ?math.Vec2f = null },
    /// The window lost the focus: the keys held are forgotten and a capture ends.
    focus_lost,

    /// A character was typed: its Unicode scalar value.
    char_input: u32,
    /// An editing operation was asked for.
    text_navigation: TextNavigation,
};

/// The rows each of input's tables starts with; they grow as events and subscriptions need. The
/// runtime's, which this file uses too; not part of what a plugin relies on.
pub const kInitialRows = 64;

/// A key that followed a pending prefix and that no binding took, with the modifiers held.
pub const UndefinedChord = struct {
    /// The key.
    key: Key,
    /// Shift was held.
    shift: bool = false,
    /// Control was held.
    control: bool = false,
    /// Alt was held.
    alt: bool = false,
    /// Super was held.
    super_key: bool = false,
};

// ---- the tables ----------------------------------------------------------------------------

/// A row of `input.undefined_chords`. The runtime's, which this file's `UndefinedChordView`
/// uses; not part of what a plugin relies on.
pub const UndefinedChordRow = struct { chord: UndefinedChord };

/// The requests to input, a row each, run with the next batch; moves may coalesce.
pub const commands_table_name = "commands.input";
/// The batch's keys that completed no chord, for the actions system to read after dispatch.
pub const undefined_chords_table_name = "input.undefined_chords";
/// A view of a row of `input.undefined_chords`.
pub const UndefinedChordView = View(UndefinedChordRow);
/// The batch's presses that may move the focus: each the first press of the frame with no
/// button held. The panels system focuses the panel under each.
pub const focus_presses_table_name = "input.focus_presses";

/// A row of `input.focus_presses`: where a press was, in framebuffer pixels.
pub const FocusPress = struct { x: f32, y: f32 };
/// A view of a row of `input.focus_presses`.
pub const FocusPressView = struct { x: *f32, y: *f32 };

/// A struct of pointers to `Row`'s fields: a view of a row of the table `Row` describes.
/// The runtime's, which this file uses too; not part of what a plugin relies on.
pub fn View(comptime Row: type) type {
    const fields = std.meta.fields(Row);
    var types: [fields.len]type = undefined;
    for (fields, &types) |field, *field_type| field_type.* = *field.type;
    return @Struct(.auto, null, std.meta.fieldNames(Row), &types, &@splat(.{}));
}

/// Initializes `schema` with a field per field of `Row` and room for `extra` more. The caller
/// deinits it. The runtime's, which this file uses too; not part of what a plugin relies on.
pub fn schemaOf(comptime Row: type, scratch: memory_mod.Scratch, atoms: *Atom.Registry, schema: *Table.Schema, extra: usize) !void {
    const fields = std.meta.fields(Row);
    try schema.init(scratch.allocator, atoms, fields.len + extra);
    errdefer schema.deinit();
    inline for (fields) |field| {
        const view_kind: Table.ViewKind = if (field.type == Atom) .atom else if (field.type == Table.Bytes) .bytes else .hex;
        try schema.addFieldFallible(field.name, field.type, view_kind);
    }
}

/// A `subscriptions.input` row: `subscription`, its messages arriving under `tag` in
/// `inbox`, the inbox of a system of `source`. An `on_mouse` subscription's tags are its
/// regions' own.
pub fn subscriptionRow(subscription: Subscription, tag: Atom, source: Source, inbox: Atom) SubscriptionValues {
    var addressed = subscription;
    switch (addressed) {
        inline else => |*variant| if (@hasField(@TypeOf(variant.*), "tag")) {
            variant.tag = tag;
        },
    }
    return .{ .subscription = addressed, .source = source, .inbox = inbox };
}

/// `subscriptions.input`, which systems append to in their runs. Not the input system's own
/// memory: systems journal their appends to it, and the sequencer keeps each system's rows
/// until it runs again.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schemaOf(Entry, scratch, atoms, &schema, 2);
    defer schema.deinit();
    try schema.addFieldFallible(sequencer.subscriber_field, Atom, .atom);
    try schema.addFieldFallible(sequencer.subscription_order_field, u32, .int);
    try atoms.tryInternAll(&.{subscriptions_table_name});
    _ = try tables.ensure(&schema, kInitialRows, Atom.from(subscriptions_table_name), .durable);
    try sequencer.ensureSubscriptions(scratch, atoms, tables, subscriptions_table_name);
}

/// A hit region's columns for one of its routes: the tag, the user data and the inbox its
/// message goes to. The regions table is `ui`'s (`ui.region_routes`), or a host's like it.
pub const RegionRoute = struct { tag: []const u8, user_data: []const u8, inbox: []const u8 };

/// The routes a region may have, in this order: a left click, a right click, a middle click and
/// the wheel.
pub const region_routes = [_]RegionRoute{
    .{ .tag = "on_click", .user_data = "on_click_user_data", .inbox = "on_click_inbox" },
    .{ .tag = "on_right_click", .user_data = "on_right_click_user_data", .inbox = "on_right_click_inbox" },
    .{ .tag = "on_middle_click", .user_data = "on_middle_click_user_data", .inbox = "on_middle_click_inbox" },
    .{ .tag = "on_scroll", .user_data = "on_scroll_user_data", .inbox = "on_scroll_inbox" },
};

test "mouse table schema requires position and size" {
    const fields = [_]Table.FieldDescriptor{
        .{ .name = "pos", .size = @sizeOf(math.Vec2f), .stride = @sizeOf(math.Vec2f), .column_index = 0, .bit = 0, .field_type = .vec2f, .view_kind = .{ .vector = .{ .components = 2 } } },
        .{ .name = "size", .size = @sizeOf(math.Vec2f), .stride = @sizeOf(math.Vec2f), .column_index = 1, .bit = 1, .field_type = .vec2f, .view_kind = .{ .vector = .{ .components = 2 } } },
    };
    const schema = Table.Schema{ .fields = &fields };
    try validateMouseTableSchema(&schema);

    const incomplete_fields = [_]Table.FieldDescriptor{
        .{ .name = "pos", .size = @sizeOf(math.Vec2f), .stride = @sizeOf(math.Vec2f), .column_index = 0, .bit = 0 },
    };
    const incomplete = Table.Schema{ .fields = &incomplete_fields };
    try std.testing.expectError(error.MissingSizeField, validateMouseTableSchema(&incomplete));

    var wrong_size_fields = fields;
    wrong_size_fields[0].size = @sizeOf(f32);
    wrong_size_fields[0].stride = @sizeOf(f32);
    const wrong_size = Table.Schema{ .fields = &wrong_size_fields };
    try std.testing.expectError(error.InvalidPositionField, validateMouseTableSchema(&wrong_size));

    var wrong_payload_fields = [_]Table.FieldDescriptor{
        fields[0],
        fields[1],
        .{ .name = "on_click", .size = 4, .stride = 4, .column_index = 2, .bit = 2 },
    };
    const wrong_payload = Table.Schema{ .fields = &wrong_payload_fields };
    try std.testing.expectError(error.InvalidClickPayloadField, validateMouseTableSchema(&wrong_payload));
}

test "simulated text commands accept only Unicode scalar values" {
    try validateCommand(.{ .text_input = .{ .entry = 0x1f98a } });
    try std.testing.expectError(error.InvalidTextCodepoint, validateCommand(.{ .text_input = .{ .entry = 0xd800 } }));
    try std.testing.expectError(error.InvalidTextCodepoint, validateCommand(.{ .text_input = .{ .entry = 0x110000 } }));
}

test "pointer commands reject invalid clicks and nonfinite coordinates" {
    for ([_]u8{ 0, 4, 255 }) |clicks| {
        try std.testing.expectError(error.InvalidClickCount, validateCommand(.{ .mouse_button = .{ .button = .left, .x = 0, .y = 0, .action = .press, .clicks = clicks } }));
    }
    try std.testing.expectError(error.InvalidPointerCoordinate, validateCommand(.{ .mouse_move = .{ .x = std.math.nan(f32), .y = 0 } }));
    try std.testing.expectError(error.InvalidPointerCoordinate, validateCommand(.{ .mouse_scroll = .{ .x = 0, .y = 1, .pointer = .{ .x = 0, .y = std.math.inf(f32) } } }));
}
