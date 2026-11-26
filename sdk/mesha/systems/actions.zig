//! The actions contract. An action is something a person asks for by name: with a key chord, from
//! the action palette, or through `requestInvoke`. A system offers its actions each frame as rows
//! of `subscribed.actions` (an `Action` each, declared through a `plugin.ActionSink`), naming the
//! inbox and the tag the action's message arrives under. An action is identified by an
//! `ActionId`, the pair of the mode it belongs to and its name.
//!
//! A mode exists once it is registered (`registerMode`), once, as the system that owns it starts,
//! with its parent: the mode whose keymap its own starts from, which is active wherever it is.
//! The actions system keeps the modes registered in `actions_mode_registry`, `global` among them
//! from the start. Keys are declared apart from actions, as keymaps of registered modes: rows of
//! `subscribed.keymaps` (a `Keymap` each), which bind chords to action ids under a mode. Anyone
//! may bind any action in any mode. The actions system keeps one major mode and up to
//! `kMaxMinorModes` minor modes in `actions_modes`; a mode is active when it is one of them or an
//! ancestor of one by the registered parents, and `global` always is (`activeModes`). Each frame,
//! before input is dispatched, it stacks the active modes' keymaps, the minor modes' over the
//! major mode's (over `global`'s when the major mode is not registered), leaves out each binding
//! whose action's mode is not active, turns what is left into input subscriptions, and publishes
//! it as `actions_bindings`.
//!
//! Every request to the actions system is a row of the one table `commands.actions` (a
//! `Command` each): to invoke an action, to change the modes, and to register a mode. After each
//! dispatch the system applies the rows in order, so a change of modes is in force for the
//! requests after it, and delivers each invoked action that is available, offered in that frame
//! and of an active mode, to the inbox of the system that offers it. It keeps the keys pressed so
//! far of an unfinished chord in `actions_chords`. Ids are unique among a frame's actions. What
//! it warns of, a conflict while it stands and a dead key once per press, it records in
//! `actions_warned`.
//!
//! A plugin that draws a panel and wants modes for it does this, in order:
//!
//! 1. Registers each of its modes once, with its parent (`registerMode`), from the first run of a
//!    system after its init, which declares `commands.actions` written. A mode that edits text
//!    has `text` among its ancestors; any other has `global`.
//! 2. Keeps the major mode and the minor modes of each panel it draws in a table of its own, and
//!    writes a panel's row whenever what decides its modes changes. No other system reads it.
//! 3. Each frame, reads `events.panels` (`plugin.panels.Events`) under its own name, and asks for
//!    a panel's modes (`requestModes`) on a `focused` event for that panel (a `resized` one asks
//!    nothing), and whenever the
//!    modes of the panel that has the focus change. When the focus comes to another panel the
//!    actions system sets `global` and no minor mode before it applies the frame's requests, so
//!    the owner's request lands after the reset, and a panel whose owner asks nothing has the
//!    global keys.
//! 4. To open a prompt, which suspends the focus and reports the panel `unfocused`: as it opens,
//!    keeps the modes `actions_modes` holds and asks for the prompt's; as it closes, picked from
//!    or not, asks for the modes it kept. The `focused` event that follows the close makes the
//!    panel's owner ask for the panel's own again.
//!
//! A minor mode that comes and goes within the focused panel is turned on and off with
//! `requestMinor`. The editor does this for its panels in `editor/src/modes.zig`
//! (`syncPanelModes`, `followPrompt`).
//!
//! `KeyToken` and `Chord` are a binding's keys; `Def` is an action as code declares it; the
//! functions over `actions_chords` read and write the chord state, which the editor shows on the
//! minibuffer's line.
const std = @import("std");
/// The atom type, `mesha.Atom`.
pub const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const input = @import("input.zig");
const sequencer = @import("../core/sequencer.zig");

/// The most keys a chord has: a sequence as long as `C-x 4 C-f`, and one to spare.
pub const kMaxChordTokens: usize = 4;
/// The most bytes the text of an action's name, or of its mode, has.
pub const kMaxActionNameLen: usize = 64;
/// What identifies an action: the mode it belongs to, then its name. Both are interned text.
pub const ActionId = [2]Atom;
/// The mode of no mode, which no action has.
pub const no_mode: Atom = @enumFromInt(0);
/// The id of no action.
pub const no_action: ActionId = .{ no_mode, @enumFromInt(0) };
/// The mode of an action that is about the whole editor rather than one mode of it.
pub const global_mode = Atom.from("global");
/// The tag the editor takes the action palette's answer under when the palette listed the actions
/// and a person chose one.
pub const kActionSelectedTag = Atom.from("actions_action_selected");
/// The most minor modes on at once.
pub const kMaxMinorModes: usize = 8;

/// `commands.actions`, the requests to the actions system, a `Command` each, which it applies in
/// order after each dispatch and then clears.
pub const commands_table_name = "commands.actions";

/// A row of `commands.actions`.
pub const Command = union(enum) {
    /// Invoke the action of this id when it is available: offered, and of a mode active under the
    /// modes as the requests before it left them (`activeModes`). Its message then reaches the
    /// system that offers it. A warning is logged, and nothing invoked, when no system offers it
    /// or its mode is not active.
    invoke: ActionId,
    /// Replace the major mode and the minor modes, as when a panel takes the focus. A major mode
    /// of none becomes `global`; a minor mode that is none, repeats an earlier one or is past
    /// `minor_count` is dropped. Modes that leave `actions_modes` as it was leave a chord under
    /// way as it was; any other change forgets it.
    set_modes: Modes,
    /// Turn this minor mode on, over those on already. Refused with a warning when
    /// `kMaxMinorModes` are on; a mode on already stays where it is.
    enable_minor: Atom,
    /// Turn this minor mode off; one that is not on changes nothing, a chord under way included.
    disable_minor: Atom,
    /// Register `mode` with `parent`, as a row of `actions_mode_registry`. Registering a mode
    /// again with the same parent changes nothing; with another, the parent is replaced and a
    /// warning logged. A parent that is not registered, or a cycle of parents, warns and counts
    /// as no parent while it stands (`ModeTree`), so modes may be registered in any order. A
    /// mode of none, and `global`, which is registered from the start without a parent, are
    /// refused with a warning (`warnings.registration_refused`); a row the registry cannot take
    /// is logged and dropped.
    register_mode: struct {
        /// The mode registered.
        mode: Atom,
        /// The mode whose keymap `mode`'s starts from, which is active wherever `mode` is; none
        /// for none.
        parent: Atom = no_mode,
    },
};

/// The typed handle on `commands.actions`.
pub const Requests = sequencer.Commands(Command);

/// Pushes `command` to `commands.actions`. Nothing happens before the table exists; a row the
/// table cannot take is logged and dropped.
fn request(tables: *Table.Registry, command: Command) void {
    Requests.of(tables.memory, tables, commands_table_name).push(command);
}

/// Asks for the action `id` to be invoked: its message reaches the system that offers it when
/// the actions system next applies its requests, and goes nowhere, with a warning, if no system
/// offers it then or its mode is not active then. So whatever asks gives the focus to the panel
/// the action acts on first, and asks once that panel's modes are in `actions_modes`, or asks
/// for the modes itself just before (`requestModes`). A journaled system that asks declares
/// `commands.actions` written, so a fault takes its request back.
pub fn requestInvoke(tables: *Table.Registry, id: ActionId) void {
    request(tables, .{ .invoke = id });
}

/// Asks for the major mode and the minor modes to become `modes`, normalised as `Command.set_modes`
/// says, in order with the other requests of `commands.actions`: a request after it is judged by
/// the normalised modes. A journaled system that asks declares `commands.actions` written.
pub fn requestModes(tables: *Table.Registry, modes: Modes) void {
    request(tables, .{ .set_modes = modes });
}

/// Whether `requestMinor` turns its mode on or off.
pub const MinorChange = enum { enable, disable };

/// Asks for the minor mode `mode` to be turned on or off, in order with the other requests of
/// `commands.actions`. A journaled system that asks declares `commands.actions` written.
pub fn requestMinor(tables: *Table.Registry, mode: Atom, change: MinorChange) void {
    const command: Command = switch (change) {
        .enable => .{ .enable_minor = mode },
        .disable => .{ .disable_minor = mode },
    };
    request(tables, command);
}

/// Asks for `mode` to be registered with `parent`, none for none, as `Command.register_mode`
/// says. A system registers its modes once, as it starts; registering them again, as a plugin
/// loaded again does, changes nothing. A journaled system that asks declares `commands.actions`
/// written.
pub fn registerMode(tables: *Table.Registry, mode: Atom, parent: Atom) void {
    request(tables, .{ .register_mode = .{ .mode = mode, .parent = parent } });
}

/// The rows `actions_mode_registry` has room for as it is made, `global` among them; it grows as
/// more modes are registered.
pub const kModeRegistryCapacity: u32 = 64;

/// `actions_mode_registry`, the modes registered, a row each (`ModeRegistryView`), in the order
/// they were first registered: `global`, with no parent, from the start. The actions system
/// writes it as it applies `register_mode`; anyone may read it. It lasts as long as the process:
/// a mode stays registered when the plugin that registered it is unloaded.
pub const mode_registry_table = "actions_mode_registry";

/// A row of `actions_mode_registry`.
pub const ModeRegistryView = struct {
    /// The mode registered; in one row only.
    mode: *Atom,
    /// The parent it was last registered with; none for none. Whether it counts, being
    /// registered and on no cycle, is `ModeTree`'s to say.
    parent: *Atom,
};

/// A major mode and the minor modes on over it, as `actions_modes` keeps them and `set_modes`
/// asks for them.
pub const Modes = struct {
    /// The major mode; never none in `actions_modes`.
    major: Atom = global_mode,
    /// The minor modes, in the order they were turned on; only the first `minor_count` count.
    minors: [kMaxMinorModes]Atom = @splat(no_mode),
    /// How many of `minors` are on: `kMaxMinorModes` at most.
    minor_count: u8 = 0,

    /// The minor modes on, in the order they were turned on: a slice of `modes.minors`.
    pub fn minorSlice(modes: *const Modes) []const Atom {
        const count = @min(modes.minor_count, kMaxMinorModes);
        return modes.minors[0..count];
    }
};

/// `actions_modes`, one row: the current `Modes`, and the panel they were last reset for. See
/// `ModesView`. The actions system writes it; anyone may read it.
pub const modes_table = "actions_modes";

/// The one row of `actions_modes`.
pub const ModesView = struct {
    /// The major mode.
    major: *Atom,
    /// The minor modes, in the order they were turned on; only the first `minor_count` count.
    minors: *[kMaxMinorModes]Atom,
    /// How many of `minors` are on.
    minor_count: *u8,
    /// The focused panel the modes were last reset for: when the focus comes to another panel,
    /// the actions system sets the major mode to `global` and turns every minor mode off, before
    /// it applies that frame's requests. None until a panel is focused.
    focus: *Atom,
};

/// The modes `view` holds; a count past `kMaxMinorModes`, as a table edit can leave, counts as
/// `kMaxMinorModes`.
pub fn currentModes(view: ModesView) Modes {
    const count: u8 = @intCast(@min(view.minor_count.*, kMaxMinorModes));
    return .{ .major = view.major.*, .minors = view.minors.*, .minor_count = count };
}

/// How a chord of one key invokes its action. A chord of several keys invokes on the press of
/// its last key, whatever the trigger.
pub const Trigger = enum {
    /// On the press alone.
    once,
    /// On the press, then at each dispatch once the key has been held 150 ms, for what repeats.
    repeat,
    /// At each dispatch while the key is held.
    held,
    /// On the release.
    release,
};

/// A chord bound to an action in a keymap. `action` is `no_action` to unbind `chord`: the
/// binding removes what it replaces and adds nothing.
pub const Binding = struct {
    /// The keys to press: one to `kMaxChordTokens`.
    chord: Chord,
    /// The action the chord invokes, or `no_action`.
    action: ActionId,
    /// How a chord of one key invokes it.
    trigger: Trigger = .once,
};

/// Whose bindings a keymap row holds, which orders them within their mode.
pub const Rank = enum {
    /// Defaults, as the editor's own lists: they apply first.
    default,
    /// A person's or a plugin's own keys: they apply after every default row of their mode,
    /// whatever order the rows were declared in.
    custom,
};

/// A row of `subscribed.keymaps`: bindings added to the keymap of `mode`, a registered mode.
/// Several rows may name one mode. A mode's keymap starts as its parent's, by the registry
/// (`ModeTree`), then takes its own bindings over it: those of its `default` rows in row order,
/// then those of its `custom` rows in row order. A binding replaces any earlier one of the same
/// chord, of a chord it is a prefix of, or of a prefix of it. Two of the mode's own bindings of
/// one rank that replace one another conflict, which warns; the later holds. A `custom` binding
/// or unbinding that replaces a `default` one does not conflict. A row for a mode not registered
/// warns and binds nothing.
pub const Keymap = struct {
    /// The mode whose keymap this adds to: a registered mode.
    mode: Atom,
    /// Whether the bindings are defaults or a person's own, which apply after the defaults.
    rank: Rank = .custom,
    /// The bindings, in the order they apply; copied into the table's arena.
    bindings: []const Binding = &.{},
};

/// The keymaps systems declare this frame, a row each, appended in their runs and cleared before
/// the next.
pub const keymaps_table_name = "subscribed.keymaps";

/// What `actions_mode_registry` says of the modes: each registered mode once, in the registry's
/// row order, with its parent. `global` is the first, a mode whether or not a row names it, as
/// the mode the actions system falls back to. Built for a frame; its slices are the builder's
/// allocator's.
pub const ModeTree = struct {
    /// `global`, then the other modes registered, each once, in row order.
    modes: []const Atom,
    /// Each mode's parent as it counts: the registered one, or none for none, for a parent that
    /// is not registered and for a mode on a cycle of parents.
    parents: []const Atom,
    /// Each mode's parent as registered, before the checks above.
    stated_parents: []const Atom,

    /// The tree of `registry`, the table `actions_mode_registry`, in `allocator`, an arena's:
    /// what a failure leaves is not freed. Parents are resolved here, against every row, so a
    /// mode registered before its parent inherits it once the parent is registered.
    pub fn build(allocator: std.mem.Allocator, registry: *Table) !ModeTree {
        var modes: std.ArrayListUnmanaged(Atom) = .empty;
        var stated: std.ArrayListUnmanaged(Atom) = .empty;
        try modes.append(allocator, global_mode);
        try stated.append(allocator, no_mode);
        var rows = registry.readQuery(ModeRegistryView);
        while (rows.next()) |row| {
            const mode = row.view.mode.*;
            // A row a table edit left that repeats a mode, or names none, counts for nothing.
            if (mode == no_mode or indexIn(modes.items, mode) != null) continue;
            try modes.append(allocator, mode);
            try stated.append(allocator, row.view.parent.*);
        }
        const parents = try allocator.alloc(Atom, modes.items.len);
        for (modes.items, stated.items, parents) |mode, parent, *resolved| {
            const registered = indexIn(modes.items, parent) != null;
            const cut = !registered or onCycle(modes.items, stated.items, mode);
            resolved.* = if (cut) no_mode else parent;
        }
        return .{
            .modes = try modes.toOwnedSlice(allocator),
            .parents = parents,
            .stated_parents = try stated.toOwnedSlice(allocator),
        };
    }

    /// Where `mode` is in `tree.modes`; null for a mode not there.
    pub fn indexOf(tree: ModeTree, mode: Atom) ?usize {
        return indexIn(tree.modes, mode);
    }

    /// The parent of `mode`; none for a mode without one, or not in the tree.
    pub fn parentOf(tree: ModeTree, mode: Atom) Atom {
        const index = tree.indexOf(mode) orelse return no_mode;
        return tree.parents[index];
    }

    fn indexIn(modes: []const Atom, mode: Atom) ?usize {
        if (mode == no_mode) return null;
        return std.mem.indexOfScalar(Atom, modes, mode);
    }

    /// Whether following the stated parents from `mode` comes back to it.
    fn onCycle(modes: []const Atom, stated: []const Atom, mode: Atom) bool {
        var current = mode;
        for (0..modes.len) |_| {
            const index = indexIn(modes, current) orelse return false;
            current = stated[index];
            if (current == mode) return true;
        }
        return false;
    }
};

/// The modes active under `modes`: the major mode, the minor modes and their ancestors by the
/// parents `registry`, the table `actions_mode_registry`, gives, each once, then `global` when
/// none of them is: `global` is always active, whatever the major mode. A mode not registered,
/// but `global`, is not active, nor are its actions available. Allocated in `allocator`, an
/// arena's.
pub fn activeModes(allocator: std.mem.Allocator, registry: *Table, modes: Modes) ![]const Atom {
    const tree = try ModeTree.build(allocator, registry);
    return activeModesOf(allocator, tree, modes);
}

/// `activeModes` of a tree already built.
pub fn activeModesOf(allocator: std.mem.Allocator, tree: ModeTree, modes: Modes) ![]const Atom {
    var active: std.ArrayListUnmanaged(Atom) = .empty;
    const minors = modes.minorSlice();
    for (0..minors.len + 1) |index| {
        var mode = if (index == 0) modes.major else minors[index - 1];
        // Parents are acyclic once built, so the walk ends.
        while (tree.indexOf(mode) != null) : (mode = tree.parentOf(mode)) {
            if (std.mem.indexOfScalar(Atom, active.items, mode) != null) break;
            try active.append(allocator, mode);
        }
    }
    const global_active = std.mem.indexOfScalar(Atom, active.items, global_mode) != null;
    if (!global_active) try active.append(allocator, global_mode);
    return active.toOwnedSlice(allocator);
}

/// `actions_bindings`, the bindings the active keymaps leave, a row each, rewritten each frame
/// before input is dispatched, for whatever shows keys. See `BoundView`.
pub const bindings_table_name = "actions_bindings";

/// A row of `actions_bindings`.
pub const BoundView = struct {
    /// The chord's keys; the first `len` count.
    keys: *ChordKeys,
    /// How many keys the chord has.
    len: *u8,
    /// The mode of the bound action's id.
    mode: *Atom,
    /// The name of the bound action's id.
    name: *Atom,
    /// The mode whose keymap rows declared the binding: an active mode, or an ancestor of one.
    keymap: *Atom,
};

/// `actions_warned`, the warnings standing: the conflicts and unknown modes of this frame's
/// keymaps and modes, the parents of the registry that do not count, and the refused requests,
/// replaced parents and dead keys of the last application of requests. A
/// warning is logged when its row is new; the rows are rewritten each frame before input is
/// dispatched, so a conflict warns once while it stands. See `WarnedView`; for debugging and
/// tests.
pub const warned_table_name = "actions_warned";

/// A row of `actions_warned`: what the warning is of, and the atoms and chord it names.
pub const WarnedView = struct {
    /// Which warning, one of `warnings`.
    kind: *Atom,
    /// The first atom it names, as its kind says; none for none.
    a: *Atom,
    /// The second atom it names; none for none.
    b: *Atom,
    /// The third atom it names; none for none.
    c: *Atom,
    /// The chord it is of; the first `len` keys count.
    keys: *ChordKeys,
    /// How many keys of `keys` count; zero for a warning of no chord.
    len: *u8,
};

/// The kinds of `actions_warned`'s rows, with the atoms each names in `a`, `b` and `c`.
pub const warnings = struct {
    /// One mode's own bindings of one rank replace one another: the mode, then the later
    /// binding's action id; the chord is the later binding's.
    pub const keymap_conflict = Atom.from("keymap_conflict");
    /// A mode registered again with another parent, which replaced the earlier: the mode, the
    /// earlier parent, the later.
    pub const parent_conflict = Atom.from("parent_conflict");
    /// A mode's registered parent is not registered: the mode, the parent.
    pub const parent_unknown = Atom.from("parent_unknown");
    /// The registered parents of modes make a cycle: one mode on it; every mode on it has no
    /// parent.
    pub const parent_cycle = Atom.from("parent_cycle");
    /// A binding's chord has no key, or more than `kMaxChordTokens`: the mode, the action id.
    pub const binding_invalid = Atom.from("binding_invalid");
    /// A mode not registered, but `global`, named as the major mode or a minor mode, or by a row
    /// of `subscribed.keymaps`: the mode. Such a major mode's keymap is `global`'s; such a minor
    /// mode adds no keymap, and such a row binds nothing.
    pub const mode_unknown = Atom.from("mode_unknown");
    /// A minor mode refused, `kMaxMinorModes` being on: the mode.
    pub const minor_refused = Atom.from("minor_refused");
    /// A request, or a key, invoked an action nobody offers: the action id.
    pub const action_not_offered = Atom.from("action_not_offered");
    /// A request, or a key, invoked an action offered in a mode that is not active: the action
    /// id, whose first atom is the mode.
    pub const action_mode_inactive = Atom.from("action_mode_inactive");
    /// A `register_mode` refused: of none, or of `global`, which is registered from the start
    /// without a parent. The mode, then the parent asked for.
    pub const registration_refused = Atom.from("registration_refused");

    /// Every kind's name, interned by `ensureTables`.
    pub const names = [_][]const u8{
        "keymap_conflict",      "parent_conflict",      "parent_unknown", "parent_cycle",
        "binding_invalid",      "mode_unknown",         "minor_refused",  "action_not_offered",
        "action_mode_inactive", "registration_refused",
    };
};

/// `id` as text, `mode.name`, written to `buf`; the result is the part of `buf` written. An atom
/// the registry does not know is written as `?`; text that does not fit `buf` is truncated.
pub fn formatId(buf: []u8, atoms: *Atom.Registry, id: ActionId) []const u8 {
    const mode_text = atoms.lookup(id[0]) orelse "?";
    const name_text = atoms.lookup(id[1]) orelse "?";
    var writer = std.Io.Writer.fixed(buf);
    writer.print("{s}.{s}", .{ mode_text, name_text }) catch {};
    return writer.buffered();
}

/// One key of a chord, with the modifiers held as it is pressed. A modifier that is not set must
/// not be held.
pub const KeyToken = struct {
    /// The key.
    key: input.Key,
    /// Control is held; `C-` in a chord's text.
    control: bool = false,
    /// Alt is held; `M-` in a chord's text.
    alt: bool = false,
    /// Shift is held; `S-` in a chord's text.
    shift: bool = false,
    /// Super is held; `s-` in a chord's text.
    super_key: bool = false,

    /// Whether both name the same key with the same modifiers.
    pub fn eql(a: KeyToken, b: KeyToken) bool {
        return a.key == b.key and a.control == b.control and a.alt == b.alt and
            a.shift == b.shift and a.super_key == b.super_key;
    }
};

/// The keys bound to an action: one key, or up to `kMaxChordTokens` pressed one after another, as
/// `C-x C-s`.
pub const Chord = struct {
    /// The keys, in the order pressed. Only the first `len` are defined.
    tokens: [kMaxChordTokens]KeyToken = undefined,
    /// How many keys the chord has; zero is no chord.
    len: u8 = 0,

    /// The chord of `keys`, which are `kMaxChordTokens` at most.
    pub fn of(keys: []const KeyToken) Chord {
        var chord: Chord = .{ .len = @intCast(keys.len) };
        @memcpy(chord.tokens[0..keys.len], keys);
        return chord;
    }

    /// The chord's keys: a slice of the chord's own array.
    pub fn slice(chord: *const Chord) []const KeyToken {
        return chord.tokens[0..chord.len];
    }

    /// Whether both have the same keys, with the same modifiers, in the same order.
    pub fn eql(a: Chord, b: Chord) bool {
        if (a.len != b.len) return false;
        for (a.tokens[0..a.len], b.tokens[0..b.len]) |left, right| {
            if (!KeyToken.eql(left, right)) return false;
        }
        return true;
    }
};

/// The tags of an action list, for a system's `claims`.
pub fn tags(comptime defs: []const Def) [defs.len]Atom {
    // Hashing each name at compile time takes a branch per byte.
    @setEvalBranchQuota(1000 * defs.len + 1000);
    var result: [defs.len]Atom = undefined;
    for (defs, &result) |def, *tag| tag.* = Atom.from(def.tag);
    return result;
}

/// An action as code declares it, with its name and tag as text: `keybinds.pushActionDefinitions`
/// makes an `Action` of each.
pub const Def = struct {
    /// The action's name in its mode, which keymaps and the action palette know it by: at most
    /// `kMaxActionNameLen` bytes.
    name: []const u8,
    /// The tag its message arrives under in the declaring system's inbox.
    tag: []const u8,
    /// Bytes its message carries back as user data; empty for none.
    params: []const u8 = "",
    /// What the action does, in a line a person reads in the action palette.
    doc: []const u8 = "",
    /// `global` for actions about the whole window, whose keys answer wherever the focus is: the
    /// action palette, moving between panels, switching workspaces. See `Action.scope`.
    scope: input.Scope = .local,
};

/// An action a system offers this frame, a row of `subscribed.actions`: invoking it delivers a
/// message under `tag` to `inbox`, with `user_data` as its user data and no payload. Slices
/// and the user data are copied into the table's arena.
pub const Action = struct {
    /// The action's mode and name, interned so that it lists and logs as text; unique among the
    /// actions offered in a frame, and never none.
    id: ActionId,
    /// What the action does, in a line a person reads in the action palette.
    doc: []const u8 = "",
    /// The inbox of the system that runs it.
    inbox: Atom = @enumFromInt(0),
    /// What its message arrives under in `inbox`, the tag the system takes it by.
    tag: Atom,
    /// The declarer's own words for it, which its message carries back unchanged: which
    /// command of several sharing a tag, or which view offered it.
    user_data: sequencer.UserData = .none,
    /// Whether `listEntries` lists it, as for the action palette. An action not listed can still
    /// be invoked by its keys and by name.
    listed: bool = true,
    /// Whether offering it captures the keyboard. While an action of an active mode other than
    /// `global` captures, as an editor of text in a cell, a form or a prompt does while a person
    /// types, every key the active keymaps bind, to any action, takes part in an input capture
    /// (see the input Subscription), and other subscriptions to the keys that do not capture
    /// hear nothing. A capturing action of `global` captures for its own keys alone.
    capture: bool = false,
    /// Whether the keys a keymap binds to it fire only while the offering system owns the focused
    /// panel, or wherever the focus is; see the input Subscription.
    scope: input.Scope = .local,
};

/// The actions systems offer this frame, a row each, appended in their runs and cleared before
/// the next.
pub const subscribed_table_name = "subscribed.actions";

/// An action as a list shows it.
pub const ListEntry = struct {
    /// The action's id.
    id: ActionId,
    /// The id's mode as text: the atom registry's.
    mode: []const u8,
    /// The id's name as text: the atom registry's.
    label: []const u8,
    /// The action's `doc`.
    doc: []const u8 = "",
    /// The action's keys as text, for whoever shows the list to fill; `listEntries` leaves it
    /// empty.
    key_text: []const u8 = "",
};

/// Which modes `listEntries` lists the actions of.
pub const ModeFilter = union(enum) {
    /// Every mode's.
    all,
    /// Only these modes', as `activeModes` gives them; borrowed for the call.
    only: []const Atom,

    /// Whether an action of `mode` passes.
    pub fn admits(filter: ModeFilter, mode: Atom) bool {
        return switch (filter) {
            .all => true,
            .only => |modes| std.mem.indexOfScalar(Atom, modes, mode) != null,
        };
    }
};

/// The listed actions among `actions` (anything whose `iterate` yields `Action`s) of the modes
/// `modes` admits whose name, mode or description holds `query`, ignoring case: matches on the
/// name first, earliest first, then on the mode, then on the description; ties by name, then by
/// the mode's text. Everything is allocated in `allocator`.
pub fn listEntries(allocator: std.mem.Allocator, atoms: *Atom.Registry, actions: anytype, modes: ModeFilter, query: []const u8) ![]const ListEntry {
    const Ranked = struct { entry: ListEntry, rank: usize };
    var ranked: std.ArrayListUnmanaged(Ranked) = .empty;
    defer ranked.deinit(allocator);
    var all = actions.iterate();
    while (all.next()) |action| {
        if (!action.listed) continue;
        if (!modes.admits(action.id[0])) continue;
        const mode_text = atoms.lookup(action.id[0]) orelse continue;
        const label = atoms.lookup(action.id[1]) orelse continue;
        // Each kind of match ranks below every match of the kinds before it, however early it
        // falls.
        const mode_rank_base = 1 << 16;
        const doc_rank_base = 2 << 16;
        const rank = if (query.len == 0)
            0
        else if (std.ascii.indexOfIgnoreCase(label, query)) |at|
            at
        else if (std.ascii.indexOfIgnoreCase(mode_text, query)) |at|
            mode_rank_base + at
        else if (std.ascii.indexOfIgnoreCase(action.doc, query)) |at|
            doc_rank_base + at
        else
            continue;
        try ranked.append(allocator, .{ .entry = .{ .id = action.id, .mode = mode_text, .label = label, .doc = action.doc }, .rank = rank });
    }
    const less = struct {
        fn less(_: void, a: Ranked, b: Ranked) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            const names_differ = !std.ascii.eqlIgnoreCase(a.entry.label, b.entry.label);
            if (names_differ) return std.ascii.lessThanIgnoreCase(a.entry.label, b.entry.label);
            return std.ascii.lessThanIgnoreCase(a.entry.mode, b.entry.mode);
        }
    }.less;
    std.mem.sort(Ranked, ranked.items, {}, less);
    const entries = try allocator.alloc(ListEntry, ranked.items.len);
    for (ranked.items, 0..) |item, i| entries[i] = item.entry;
    return entries;
}

/// `actions_chords`, one row: the keys of the sequence being typed. See `ChordStateView`.
pub const chord_state_table = "actions_chords";

/// A `KeyToken` as a table cell holds it, with every byte defined.
pub const KeyTokenBits = extern struct {
    /// The key's number among `input.Key`'s values.
    key: u32 = 0,
    /// 1 when Control is held, else 0.
    control: u8 = 0,
    /// 1 when Alt is held, else 0.
    alt: u8 = 0,
    /// 1 when Shift is held, else 0.
    shift: u8 = 0,
    /// 1 when Super is held, else 0.
    super_key: u8 = 0,

    /// `value` as a cell holds it.
    pub fn from(value: KeyToken) KeyTokenBits {
        return .{
            .key = @intFromEnum(value.key),
            .control = @intFromBool(value.control),
            .alt = @intFromBool(value.alt),
            .shift = @intFromBool(value.shift),
            .super_key = @intFromBool(value.super_key),
        };
    }

    /// The token the cell holds; null for a key number or a flag no token has, as a table edit
    /// can leave.
    pub fn token(self: KeyTokenBits) ?KeyToken {
        if (self.key >= input.num_keys or self.control > 1 or self.alt > 1 or self.shift > 1 or self.super_key > 1) return null;
        return .{
            .key = @enumFromInt(self.key),
            .control = self.control == 1,
            .alt = self.alt == 1,
            .shift = self.shift == 1,
            .super_key = self.super_key == 1,
        };
    }
};

/// The keys of a sequence as a table cell holds them: every byte defined. How many of them
/// count is in the cell beside it.
pub const ChordKeys = extern struct {
    /// The keys, in the order pressed; those past the count beside the cell are zero.
    tokens: [kMaxChordTokens]KeyTokenBits = @splat(.{}),

    /// `value`'s keys as a cell holds them.
    pub fn from(value: Chord) ChordKeys {
        var keys: ChordKeys = .{};
        for (value.slice(), 0..) |token, index| keys.tokens[index] = KeyTokenBits.from(token);
        return keys;
    }

    /// Null for a count or a key a table edit left that no chord has.
    pub fn toChord(keys: ChordKeys, len: u8) ?Chord {
        if (len > kMaxChordTokens) return null;
        var result: Chord = .{ .len = len };
        for (keys.tokens[0..len], 0..) |token, index| result.tokens[index] = token.token() orelse return null;
        return result;
    }
};

/// What the input gate knows a pending prefix by: a hash of its keys and their modifiers,
/// never `input.no_chord_prefix`.
pub fn prefixHash(keys: []const KeyToken) input.ChordPrefix {
    var hasher = std.hash.Wyhash.init(0);
    for (keys) |key| {
        const bits = KeyTokenBits.from(key);
        hasher.update(std.mem.asBytes(&bits));
    }
    const hash = hasher.final();
    return if (hash == input.no_chord_prefix) 1 else hash;
}

/// The one row of `actions_chords`. `pending` counts the keys pressed so far of a sequence not
/// yet ended, which are `keys`; `undefined_chord` counts those of the last sequence that led
/// to nothing, `undefined_keys`, the last of them the key no binding took. At most one of
/// the two counts is not zero.
pub const ChordStateView = struct {
    /// How many keys of `keys` are pressed so far; zero when no sequence waits for more.
    pending: *u8,
    /// The keys pressed so far.
    keys: *ChordKeys,
    /// How many keys of `undefined_keys` the last sequence that led to nothing had; zero for
    /// none.
    undefined_chord: *u8,
    /// The last sequence that led to nothing.
    undefined_keys: *ChordKeys,
};

/// Makes `actions_chords` unless it is there, with nothing pending. `scratch` allocates the
/// schema for the call.
pub fn ensureChordState(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(scratch.allocator, atoms, 4);
    defer schema.deinit();
    schema.addField("pending", u8, .int);
    schema.addField("keys", ChordKeys, .text_field);
    schema.addField("undefined_chord", u8, .int);
    schema.addField("undefined_keys", ChordKeys, .text_field);
    _ = try tables.ensureSingleton(&schema, atoms.intern(chord_state_table), .{
        .pending = @as(u8, 0),
        .keys = ChordKeys{},
        .undefined_chord = @as(u8, 0),
        .undefined_keys = ChordKeys{},
    }, .durable);
}

fn chordState(tables: *Table.Registry, atoms: *Atom.Registry) ?ChordStateView {
    const table = tables.findByName(atoms.intern(chord_state_table)) orelse return null;
    const handle = Table.RowHandle{ .row = 0, .generation = table.rowGeneration(0) };
    return table.getRow(handle, ChordStateView);
}

/// The state as it must be: sequences that read as chords, one of them at most holding keys,
/// and an undefined one of two keys or more. A table edit can leave it otherwise.
fn chordStateIsValid(state: ChordStateView) bool {
    // A pending prefix leaves room for the key that ends its sequence.
    if (state.pending.* >= kMaxChordTokens) return false;
    if (state.pending.* != 0 and state.undefined_chord.* != 0) return false;
    if (state.undefined_chord.* == 1) return false;
    if (state.keys.toChord(state.pending.*) == null) return false;
    return state.undefined_keys.toChord(state.undefined_chord.*) != null;
}

/// The keys pressed so far of a sequence that waits for more, as `state` has them.
pub fn pendingOf(state: ChordStateView) ?Chord {
    if (!chordStateIsValid(state) or state.pending.* == 0) return null;
    return state.keys.toChord(state.pending.*);
}

/// The last sequence that led to nothing, as `state` has it: its last key is the one no
/// binding took.
pub fn undefinedOf(state: ChordStateView) ?Chord {
    if (!chordStateIsValid(state) or state.undefined_chord.* == 0) return null;
    return state.undefined_keys.toChord(state.undefined_chord.*);
}

/// The keys pressed so far of a sequence that waits for more. A state a table edit left
/// unreadable is cleared.
pub fn pendingPrefix(tables: *Table.Registry, atoms: *Atom.Registry) ?Chord {
    const state = chordState(tables, atoms) orelse return null;
    if (!chordStateIsValid(state)) {
        clearChordState(tables, atoms);
        return null;
    }
    return pendingOf(state);
}

/// The last sequence that led to nothing, until the next key of a binding.
pub fn undefinedChord(tables: *Table.Registry, atoms: *Atom.Registry) ?Chord {
    const state = chordState(tables, atoms) orelse return null;
    if (!chordStateIsValid(state)) {
        clearChordState(tables, atoms);
        return null;
    }
    return undefinedOf(state);
}

/// Records `prefix` as the keys pressed so far and forgets the last undefined sequence. A prefix
/// has fewer than `kMaxChordTokens` keys, leaving room for the key that ends it. The actions
/// system calls it; nothing happens before the table exists.
pub fn setPendingPrefix(tables: *Table.Registry, atoms: *Atom.Registry, prefix: Chord) void {
    const state = chordState(tables, atoms) orelse return;
    state.pending.* = prefix.len;
    state.keys.* = ChordKeys.from(prefix);
    state.undefined_chord.* = 0;
    state.undefined_keys.* = .{};
}

/// Forgets the keys pressed so far and the last undefined sequence.
pub fn clearChordState(tables: *Table.Registry, atoms: *Atom.Registry) void {
    const state = chordState(tables, atoms) orelse return;
    state.pending.* = 0;
    state.keys.* = .{};
    state.undefined_chord.* = 0;
    state.undefined_keys.* = .{};
}

/// `InvalidChord`: `actions_chords` is missing, or holds what no sequence of keys leaves.
pub const ChordStateValidationError = error{InvalidChord};

/// Checks that `actions_chords` is there and holds a state the actions system could have left, as
/// a tool that wrote the table must leave it.
pub fn validateChordState(tables: *Table.Registry, atoms: *Atom.Registry) ChordStateValidationError!void {
    const state = chordState(tables, atoms) orelse return error.InvalidChord;
    if (!chordStateIsValid(state)) return error.InvalidChord;
}

/// Records that `key` followed the pending prefix and no binding took it: the prefix and the key
/// become the undefined sequence, and nothing stays pending. Without a pending prefix the state
/// is cleared.
pub fn setUndefinedChord(tables: *Table.Registry, atoms: *Atom.Registry, key: KeyToken) void {
    const state = chordState(tables, atoms) orelse return;
    if (!chordStateIsValid(state) or state.pending.* == 0) {
        clearChordState(tables, atoms);
        return;
    }
    var undefined_chord = state.keys.toChord(state.pending.*).?;
    undefined_chord.tokens[undefined_chord.len] = key;
    undefined_chord.len += 1;
    state.undefined_chord.* = undefined_chord.len;
    state.undefined_keys.* = ChordKeys.from(undefined_chord);
    state.pending.* = 0;
    state.keys.* = .{};
}

/// The actions system's tables: its chord state, its commands, `actions_mode_registry` with
/// `global` registered, `actions_modes` with the major mode `global` and no minor mode,
/// `actions_bindings` and `actions_warned`. Interns the text of `global_mode`, which an action id
/// written as text needs, and of the kinds of warnings.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try ensureChordState(scratch, atoms, tables);
    try Requests.ensure(scratch, atoms, tables, commands_table_name);
    try atoms.tryInternAll(&.{ "global", mode_registry_table, modes_table, bindings_table_name, warned_table_name });
    try atoms.tryInternAll(&warnings.names);

    var registry_schema: Table.Schema = undefined;
    try registry_schema.init(scratch.allocator, atoms, 2);
    defer registry_schema.deinit();
    try registry_schema.addFieldFallible("mode", Atom, .atom);
    try registry_schema.addFieldFallible("parent", Atom, .atom);
    const registry = try tables.ensure(&registry_schema, kModeRegistryCapacity, Atom.from(mode_registry_table), .durable);
    if (registry.created) _ = try registry.table.tryInsert(.{ .mode = global_mode, .parent = no_mode });

    var modes_schema: Table.Schema = undefined;
    try modes_schema.init(scratch.allocator, atoms, 4);
    defer modes_schema.deinit();
    try modes_schema.addFieldFallible("major", Atom, .atom);
    try modes_schema.addFieldFallible("minors", [kMaxMinorModes]Atom, .hex);
    try modes_schema.addFieldFallible("minor_count", u8, .int);
    try modes_schema.addFieldFallible("focus", Atom, .atom);
    const initial: Modes = .{};
    _ = try tables.ensureSingleton(&modes_schema, Atom.from(modes_table), .{
        .major = initial.major,
        .minors = initial.minors,
        .minor_count = initial.minor_count,
        .focus = no_mode,
    }, .durable);

    var bindings_schema: Table.Schema = undefined;
    try bindings_schema.init(scratch.allocator, atoms, 5);
    defer bindings_schema.deinit();
    try bindings_schema.addFieldFallible("keys", ChordKeys, .text_field);
    try bindings_schema.addFieldFallible("len", u8, .int);
    try bindings_schema.addFieldFallible("mode", Atom, .atom);
    try bindings_schema.addFieldFallible("name", Atom, .atom);
    try bindings_schema.addFieldFallible("keymap", Atom, .atom);
    _ = try tables.ensure(&bindings_schema, 64, Atom.from(bindings_table_name), .durable);

    var warned_schema: Table.Schema = undefined;
    try warned_schema.init(scratch.allocator, atoms, 6);
    defer warned_schema.deinit();
    try warned_schema.addFieldFallible("kind", Atom, .atom);
    try warned_schema.addFieldFallible("a", Atom, .atom);
    try warned_schema.addFieldFallible("b", Atom, .atom);
    try warned_schema.addFieldFallible("c", Atom, .atom);
    try warned_schema.addFieldFallible("keys", ChordKeys, .text_field);
    try warned_schema.addFieldFallible("len", u8, .int);
    _ = try tables.ensure(&warned_schema, 8, Atom.from(warned_table_name), .durable);
}

/// Why an action is refused. `InvalidActionName`: the mode or the name is none, or is not interned
/// text. `ActionNameTooLong`: the text of the mode or of the name is longer than
/// `kMaxActionNameLen`.
pub const ValidationError = error{
    InvalidActionName,
    ActionNameTooLong,
};

/// Checks what can be checked of `action` without the atom registry: a mode and a name. The
/// actions system checks the texts and their lengths too.
pub fn validateAction(action: Action) ValidationError!void {
    if (action.id[0] == no_mode or action.id[1] == no_action[1]) return error.InvalidActionName;
}

/// `token` as Emacs writes a key (`C-x`, `M-RET`, `S-f`, `s-a`), written to `buf`; the result is
/// the part of `buf` written. Enter, Tab, Space, Backspace and Escape are `RET`, `TAB`, `SPC`,
/// `DEL` and `ESC`; any other key is its `input.Key` name. A part that does not fit `buf` is left
/// out.
pub fn formatToken(buf: []u8, token: KeyToken) []const u8 {
    var written: usize = 0;
    const put = struct {
        fn write(buffer: []u8, cursor: *usize, text: []const u8) void {
            if (text.len > buffer.len - cursor.*) return;
            @memcpy(buffer[cursor.* .. cursor.* + text.len], text);
            cursor.* += text.len;
        }
    }.write;
    if (token.control) put(buf, &written, "C-");
    if (token.alt) put(buf, &written, "M-");
    if (token.shift) put(buf, &written, "S-");
    if (token.super_key) put(buf, &written, "s-");
    const alias: ?[]const u8 = switch (token.key) {
        .enter => "RET",
        .tab => "TAB",
        .space => "SPC",
        .backspace => "DEL",
        .escape => "ESC",
        else => null,
    };
    const name = alias orelse std.enums.tagName(input.Key, token.key) orelse return buf[0..0];
    put(buf, &written, name);
    return buf[0..written];
}

test "action API validates names" {
    const action: Action = .{
        .id = .{ global_mode, Atom.from("save") },
        .tag = Atom.from("test_action"),
    };
    try validateAction(action);

    var invalid = action;
    invalid.id = no_action;
    try std.testing.expectError(error.InvalidActionName, validateAction(invalid));
    invalid = action;
    invalid.id[0] = no_mode;
    try std.testing.expectError(error.InvalidActionName, validateAction(invalid));
}

test "listEntries ranks a match in the name before one in the mode, then in the description" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    const offered = [_]Action{
        .{ .id = .{ atoms.intern("global"), atoms.intern("save") }, .tag = Atom.from("test_action") },
        .{ .id = .{ atoms.intern("figure"), atoms.intern("new") }, .tag = Atom.from("test_action") },
        .{ .id = .{ atoms.intern("text"), atoms.intern("figure_caption") }, .tag = Atom.from("test_action") },
    };
    const Offered = struct {
        items: []const Action,
        fn iterate(self: @This()) Iterator {
            return .{ .items = self.items };
        }
        const Iterator = struct {
            items: []const Action,
            at: usize = 0,
            fn next(self: *Iterator) ?Action {
                if (self.at == self.items.len) return null;
                defer self.at += 1;
                return self.items[self.at];
            }
        };
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source: Offered = .{ .items = &offered };

    const by_figure = try listEntries(arena.allocator(), &atoms, source, .all, "fig");
    try std.testing.expectEqual(@as(usize, 2), by_figure.len);
    try std.testing.expectEqualSlices(Atom, &.{ atoms.intern("text"), atoms.intern("figure_caption") }, &by_figure[0].id);
    try std.testing.expectEqualSlices(Atom, &.{ atoms.intern("figure"), atoms.intern("new") }, &by_figure[1].id);

    const by_mode = try listEntries(arena.allocator(), &atoms, source, .all, "glob");
    try std.testing.expectEqual(@as(usize, 1), by_mode.len);
    try std.testing.expectEqualSlices(Atom, &.{ global_mode, atoms.intern("save") }, &by_mode[0].id);
}
