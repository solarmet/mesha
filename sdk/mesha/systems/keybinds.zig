//! The keybinds contract: chords as text, how code declares a mode's keys and a list of actions,
//! and the editor settings that choose among the keys.
//!
//! Keys are declared in code, a list per mode, as text as Emacs writes it (`C-x C-s`, `M-j`,
//! `RET`): `buildKeymap` reads a mode's list once, as its system starts, into a row of
//! `subscribed.keymaps`, which the system declares through a keymap sink each frame. A person's
//! own keys are such declarations in their plugin, of the rank `custom`, which applies over the
//! editor's `default` keys of the same mode. `pushActionDefinitions` declares a list of `ActionDefinition`s, which say nothing of keys, to
//! an action sink.
//!
//! `parse` reads a chord's text into a `Sequence` of `Token`s, `Sequence.chord` makes an
//! action chord of one, and `formatToken` writes a token back. `ChordLookup` finds the chord a
//! mode's keymap, or an ancestor's by the registered parents, gives an action; `displayChord`
//! shows a chord of one key. `init` registers the editor settings' schema.
const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const input = @import("input.zig");
const plugin = @import("plugin.zig");
const actions = plugin.action_api;
const Log = @import("../core/log.zig").scope("keybinds");

/// The most keys a chord's text names: `actions.kMaxChordTokens`.
pub const kMaxTokens: usize = actions.kMaxChordTokens;

/// The editor's settings: a singleton table the editor makes with its defaults. Nothing keeps
/// it in a file; a person sets what they want by writing its cells from their own plugin's code,
/// at each start. Its schema is registered here (`init`), so the editor and a person's plugin
/// agree on it.
pub const editor_settings_name = "user_editor_settings";
/// Which keys the text editors answer: `emacs` or `cua`.
pub const text_keymap_field = "text_keymap";
/// How long a key sequence waits for its next key before the keys it leads to are listed, in
/// milliseconds; 0 for the default.
pub const which_key_delay_field = "which_key_delay_ms";
/// The letters windows and places to jump to are named by, the first for the nearest; empty
/// for the default.
pub const hint_keys_field = "hint_keys";
/// How many seconds pass between the background refreshes of a version-control panel over a
/// repository on this machine, while it is shown and the engine's window has the focus; 0 turns
/// them off. A cell left absent leaves the panel's own default.
pub const vcs_refresh_field = "vcs_refresh_seconds";
/// How many seconds pass between the background refreshes of a version-control panel whose
/// every refresh is a round trip to a server, while it shows its lists and the engine's window
/// has the focus; 0, or a cell left absent, the default, turns them off.
pub const vcs_p4_refresh_field = "vcs_p4_refresh_seconds";
/// The `text_keymap` value for Emacs's keys, the keymaps of `text` and `buffer`.
pub const text_keymap_emacs = "emacs";
/// The `text_keymap` value for the common keys: the editor puts the minor mode `cua`, whose
/// keymap it declares, over the modes of a panel that edits text.
pub const text_keymap_cua = "cua";

/// Registers the editor settings' singleton schema (`editor_settings_name`) and interns the
/// `text_keymap` values. The host calls it before any plugin loads; calling it again changes
/// nothing.
pub fn init(atoms: *Atom.Registry, tables: *Table.Registry) !void {
    const scratch = try tables.memory.tableScratchAllocator();
    try atoms.tryInternAll(&.{ text_keymap_emacs, text_keymap_cua });
    var settings: Table.Schema = undefined;
    try settings.init(scratch.allocator, atoms, 5);
    defer settings.deinit();
    settings.addField(text_keymap_field, Atom, .atom);
    settings.addFieldOfType(which_key_delay_field, u32, .u32, .int);
    settings.addField(hint_keys_field, Table.String, .text_field);
    settings.addFieldOfType(vcs_refresh_field, u32, .u32, .int);
    settings.addFieldOfType(vcs_p4_refresh_field, u32, .u32, .int);
    try tables.registerSingletonSchema(atoms.intern(editor_settings_name), &settings);
}

/// Whether `id` names a table the editor keeps to itself: the chord state (`actions_chords`).
/// The editor opens no table window on an answer about one.
pub fn isInternalTable(id: Atom) bool {
    return id == Atom.from(plugin.action_api.chord_state_table);
}

/// One key of a chord's text, with the modifiers written before it.
pub const Token = struct {
    /// The key.
    key: input.Key,
    /// `C-` was written: Control is held.
    control: bool = false,
    /// `M-` was written: Alt is held.
    alt: bool = false,
    /// `S-` was written: Shift is held.
    shift: bool = false,
    /// `s-` was written: Super is held.
    super_key: bool = false,

    /// The token's modifiers as an input subscription matches them: each one written is required
    /// and each one not written is forbidden.
    pub fn filter(self: Token) input.ModifierFilter {
        return .{
            .control = if (self.control) .required else .forbidden,
            .alt = if (self.alt) .required else .forbidden,
            .shift = if (self.shift) .required else .forbidden,
            .super = if (self.super_key) .required else .forbidden,
        };
    }
};

/// A chord's text, read: its keys in the order pressed.
pub const Sequence = struct {
    /// The keys. Only the first `len` are defined.
    tokens: [kMaxTokens]Token = undefined,
    /// How many keys the sequence has, `kMaxTokens` at most.
    len: usize = 0,

    /// The first key, or null for an empty sequence.
    pub fn first(self: Sequence) ?Token {
        return if (self.len == 0) null else self.tokens[0];
    }

    /// The sequence as an action's chord, which holds as many keys as a sequence does.
    pub fn chord(self: Sequence) actions.Chord {
        var result: actions.Chord = .{ .len = @intCast(self.len) };
        for (self.tokens[0..self.len], result.tokens[0..self.len]) |token, *stored| {
            stored.* = .{
                .key = token.key,
                .control = token.control,
                .alt = token.alt,
                .shift = token.shift,
                .super_key = token.super_key,
            };
        }
        return result;
    }

    /// Whether both have the same keys, with the same modifiers, in the same order.
    pub fn eql(self: Sequence, other: Sequence) bool {
        if (self.len != other.len) return false;
        for (self.tokens[0..self.len], other.tokens[0..other.len]) |a, b| {
            if (a.key != b.key or a.control != b.control or a.alt != b.alt or
                a.shift != b.shift or a.super_key != b.super_key) return false;
        }
        return true;
    }
};

/// An action a system may offer this frame, with what the frame decided for it; see
/// `pushActionDefinitions`.
pub const ActionDefinition = struct {
    /// Offering it captures the keyboard; see `actions.Action.capture`.
    capture: bool = false,
    /// The action as code declares it.
    def: plugin.action_api.Def,
    /// Whether the action palette lists it.
    listed: bool = true,
};

/// A one-key chord as the UI shows it, such as `Ctrl+Shift+Z`, written to `buf`; the result is
/// the part of `buf` written. Null when the text does not parse, names more than one key, or does
/// not fit `buf`.
pub fn displayChord(buf: []u8, chord: []const u8) ?[]const u8 {
    const sequence = parse(chord) orelse return null;
    if (sequence.len != 1) return null;
    const token = sequence.tokens[0];
    var writer = std.Io.Writer.fixed(buf);
    if (token.control) writer.writeAll("Ctrl+") catch return null;
    if (token.alt) writer.writeAll("Alt+") catch return null;
    if (token.shift) writer.writeAll("Shift+") catch return null;
    if (token.super_key) writer.writeAll("Super+") catch return null;
    const name = displayKeyName(token.key);
    for (name, 0..) |character, i| {
        const shown = if (i == 0) std.ascii.toUpper(character) else character;
        writer.writeByte(shown) catch return null;
    }
    return writer.buffered();
}

fn displayKeyName(key: input.Key) []const u8 {
    return switch (key) {
        .left_bracket => "[",
        .right_bracket => "]",
        .equal => "=",
        .minus => "-",
        .apostrophe => "'",
        .semicolon => ";",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .backslash => "\\",
        else => @tagName(key),
    };
}

/// Declares each of `definitions` to `sink` as an `Action` of the mode `mode`, invoked into
/// `inbox`, the inbox of the system that runs it, under its tag with its params as user data. The
/// caller has chosen the definitions that apply this frame. One whose name is empty, longer than
/// `actions.kMaxActionNameLen` or holds a zero byte, or whose tag is empty or holds one, is left
/// out, and so is every one when `mode` is `actions.no_mode`. Interns each name and tag.
pub fn pushActionDefinitions(
    atoms: *Atom.Registry,
    sink: plugin.ActionSink,
    mode: Atom,
    inbox: Atom,
    definitions: []const ActionDefinition,
) void {
    if (mode == plugin.action_api.no_mode) return;
    for (definitions) |entry| {
        const def = entry.def;
        if (def.name.len == 0 or def.name.len > plugin.action_api.kMaxActionNameLen or def.tag.len == 0 or
            std.mem.indexOfScalar(u8, def.name, 0) != null or std.mem.indexOfScalar(u8, def.tag, 0) != null) continue;
        sink.declare(.{
            .capture = entry.capture,
            .id = .{ mode, atoms.intern(def.name) },
            .doc = def.doc,
            .inbox = inbox,
            .tag = atoms.intern(def.tag),
            .user_data = .{ .bytes = def.params },
            .scope = def.scope,
            .listed = entry.listed,
        });
    }
}

/// One key of a keymap as code declares it.
pub const KeyDef = struct {
    /// The chord as `parse` reads it.
    chord: []const u8,
    /// The action the chord invokes, its mode and its name; left as it is, the chord is unbound.
    /// Exactly one of the two empty is a mistake: the key is logged and left out.
    action: [2][]const u8 = .{ "", "" },
    /// How a chord of one key invokes the action.
    trigger: actions.Trigger = .once,
};

/// A mode's keys as code declares them.
pub const KeymapDef = struct {
    /// The mode whose keymap the keys are added to: a registered mode (`actions.registerMode`).
    mode: Atom,
    /// Whether the keys are defaults or a person's own; see `actions.Rank`.
    rank: actions.Rank = .custom,
    /// The keys, borrowed for the call.
    keys: []const KeyDef,
};

/// `def` as a row of `subscribed.keymaps`, its chords read and each action's mode and name
/// interned. Called once, where a system interns its names, as it starts: what it returns is
/// declared every frame through a `plugin.KeymapSink`, which copies it, and no kernel parses or
/// interns. The bindings are allocated in `allocator`, which holds them for as long as they are
/// declared. A chord that does not parse, or whose action has one text empty and the other not,
/// is logged and left out.
pub fn buildKeymap(allocator: std.mem.Allocator, atoms: *Atom.Registry, def: KeymapDef) error{OutOfMemory}!actions.Keymap {
    const bindings = try allocator.alloc(actions.Binding, def.keys.len);
    var count: usize = 0;
    for (def.keys) |key| {
        const sequence = parse(key.chord) orelse {
            Log.warn("keybind_chord_unparsed", .{ .mode = def.mode, .chord = key.chord });
            continue;
        };
        const mode_text, const name_text = key.action;
        if ((mode_text.len == 0) != (name_text.len == 0)) {
            Log.warn("keybind_action_incomplete", .{ .mode = def.mode, .chord = key.chord });
            continue;
        }
        var id = actions.no_action;
        if (mode_text.len != 0) {
            try atoms.tryInternAll(&key.action);
            id = .{ Atom.from(mode_text), Atom.from(name_text) };
        }
        bindings[count] = .{ .chord = sequence.chord(), .action = id, .trigger = key.trigger };
        count += 1;
    }
    return .{ .mode = def.mode, .rank = def.rank, .bindings = bindings[0..count] };
}

/// The chords the keymaps of a frame give actions, mode by mode: built once from the keymaps
/// declared and the modes registered, then asked any number of times (`chordFor`), as a list of
/// actions or a row of buttons shows each one's keys. In one mode the `default` rows apply
/// before the `custom` ones and the later binding of a chord is the one that counts; a mode's
/// binding or unbinding of a chord hides its ancestors' binding of it. Everything is in the
/// allocator it was built with, an arena's such as the frame's scratch, and lasts as long as the
/// keymaps it was built from are what the caller means to show.
pub const ChordLookup = struct {
    /// Where the lookup keeps what it builds, and what `chordFor` fills as it is asked.
    allocator: std.mem.Allocator,
    /// The modes registered, by `actions.ModeTree`.
    tree: actions.ModeTree,
    /// Each mode's own bindings, by its index in `tree.modes`: each chord once, with the action
    /// its latest binding gives it, in the order the chords first appear.
    own: []const []const Decided,
    /// Each mode's first chord for each action, by its index in `tree.modes`: filled the first
    /// time `chordFor` is asked of the mode.
    firsts: []?std.AutoHashMapUnmanaged(actions.ActionId, actions.Chord),

    /// A chord of a mode's own keymap and the action it gives.
    pub const Decided = struct {
        /// The chord.
        chord: actions.Chord,
        /// The action the chord's latest binding gives it; `actions.no_action` for an unbinding.
        action: actions.ActionId,
    };

    /// A chord as a hash map's key: every byte defined.
    const ChordKey = struct { keys: actions.ChordKeys, len: u8 };

    fn keyOf(chord: actions.Chord) ChordKey {
        return .{ .keys = actions.ChordKeys.from(chord), .len = chord.len };
    }

    /// The lookup of `keymaps`, anything whose `iterate` yields `actions.Keymap`s, as
    /// `subscribed.keymaps`, and `registry`, the table `actions_mode_registry`.
    pub fn build(allocator: std.mem.Allocator, keymaps: anytype, registry: *Table) error{OutOfMemory}!ChordLookup {
        const tree = try actions.ModeTree.build(allocator, registry);
        const lists = try allocator.alloc(std.ArrayListUnmanaged(Decided), tree.modes.len);
        @memset(lists, .empty);
        const places = try allocator.alloc(std.AutoHashMapUnmanaged(ChordKey, usize), tree.modes.len);
        @memset(places, .empty);
        for ([_]actions.Rank{ .default, .custom }) |rank| {
            var rows = keymaps.iterate();
            while (rows.next()) |keymap| {
                if (keymap.rank != rank) continue;
                const index = tree.indexOf(keymap.mode) orelse continue;
                for (keymap.bindings) |binding| {
                    const place = try places[index].getOrPut(allocator, keyOf(binding.chord));
                    if (place.found_existing) {
                        lists[index].items[place.value_ptr.*].action = binding.action;
                        continue;
                    }
                    place.value_ptr.* = lists[index].items.len;
                    try lists[index].append(allocator, .{ .chord = binding.chord, .action = binding.action });
                }
            }
        }
        const own = try allocator.alloc([]const Decided, tree.modes.len);
        for (lists, own) |list, *decided| decided.* = list.items;
        const firsts = try allocator.alloc(?std.AutoHashMapUnmanaged(actions.ActionId, actions.Chord), tree.modes.len);
        @memset(firsts, null);
        return .{ .allocator = allocator, .tree = tree, .own = own, .firsts = firsts };
    }

    /// The first chord bound to `action` in `mode`'s keymap, written as Emacs does with a space
    /// between keys, in `buf`; the result is the part of `buf` written. The own bindings of
    /// `mode` are read, then those of its parent as the registry gives it, and so on. Null when
    /// `mode` is not registered, no chord is bound to `action`, or the chord does not fit `buf`.
    pub fn chordFor(lookup: *ChordLookup, buf: []u8, mode: Atom, action: actions.ActionId) error{OutOfMemory}!?[]const u8 {
        const index = lookup.tree.indexOf(mode) orelse return null;
        if (lookup.firsts[index] == null) lookup.firsts[index] = try lookup.firstsOf(mode);
        const firsts = lookup.firsts[index].?;
        const chord = firsts.get(action) orelse return null;
        return formatChord(buf, chord);
    }

    /// The first chord of each action in `mode`'s keymap: the walk up its parents, each chord a
    /// mode binds hiding the chord in the modes above it.
    fn firstsOf(lookup: *ChordLookup, mode: Atom) error{OutOfMemory}!std.AutoHashMapUnmanaged(actions.ActionId, actions.Chord) {
        const allocator = lookup.allocator;
        var firsts: std.AutoHashMapUnmanaged(actions.ActionId, actions.Chord) = .empty;
        var hidden: std.AutoHashMapUnmanaged(ChordKey, void) = .empty;
        var current = mode;
        // Parents are acyclic once the tree is built, so the walk ends.
        while (lookup.tree.indexOf(current)) |index| : (current = lookup.tree.parentOf(current)) {
            const own = lookup.own[index];
            for (own) |decided| {
                const unbinds = std.mem.eql(Atom, &decided.action, &actions.no_action);
                if (unbinds or hidden.contains(keyOf(decided.chord))) continue;
                const first = try firsts.getOrPut(allocator, decided.action);
                if (!first.found_existing) first.value_ptr.* = decided.chord;
            }
            for (own) |decided| try hidden.put(allocator, keyOf(decided.chord), {});
        }
        return firsts;
    }
};

/// `chord` written with a space between its keys; null when it does not fit `buf`.
fn formatChord(buf: []u8, chord: actions.Chord) ?[]const u8 {
    var written: usize = 0;
    for (chord.slice(), 0..) |token, index| {
        if (index > 0) {
            if (written == buf.len) return null;
            buf[written] = ' ';
            written += 1;
        }
        const text = actions.formatToken(buf[written..], token);
        if (text.len == 0) return null;
        written += text.len;
    }
    return buf[0..written];
}

fn keyFromName(name: []const u8) ?input.Key {
    const aliases = std.StaticStringMap(input.Key).initComptime(.{
        .{ "RET", .enter },
        .{ "RETURN", .enter },
        .{ "TAB", .tab },
        .{ "SPC", .space },
        .{ "DEL", .backspace },
        .{ "ESC", .escape },
        .{ "/", .slash },
    });
    if (aliases.get(name)) |key| return key;
    return std.meta.stringToEnum(input.Key, name);
}

/// `token` as a chord's text writes it (`C-x`, `M-DEL`, `RET`), which `parse` reads back, written
/// to `buf`; the result is the part of `buf` written. Empty when the key's name does not fit.
pub fn formatToken(buf: []u8, token: Token) []const u8 {
    var n: usize = 0;
    const put = struct {
        fn put(b: []u8, i: *usize, s: []const u8) []const u8 {
            if (b.len - i.* < s.len) return b[0..0];
            @memcpy(b[i.*..][0..s.len], s);
            i.* += s.len;
            return b[0..i.*];
        }
    }.put;
    if (token.control) _ = put(buf, &n, "C-");
    if (token.alt) _ = put(buf, &n, "M-");
    if (token.shift) _ = put(buf, &n, "S-");
    if (token.super_key) _ = put(buf, &n, "s-");
    const name = aliasName(token.key) orelse std.enums.tagName(input.Key, token.key) orelse return buf[0..0];
    return put(buf, &n, name);
}

fn aliasName(key: input.Key) ?[]const u8 {
    return switch (key) {
        .enter => "RET",
        .tab => "TAB",
        .space => "SPC",
        .backspace => "DEL",
        .escape => "ESC",
        .slash => "/",
        else => null,
    };
}

/// Reads a chord's text: keys separated by spaces, each a key's name after any of the prefixes
/// `C-` (Control), `M-` (Alt), `S-` (Shift) and `s-` (Super). A key's name is its `input.Key`
/// value's, or one of `RET`, `RETURN`, `TAB`, `SPC`, `DEL`, `ESC` and `/`. Null for text with no
/// key, more than `kMaxTokens` keys, or a key or prefix it does not know.
pub fn parse(chord: []const u8) ?Sequence {
    var result: Sequence = .{};
    var it = std.mem.splitScalar(u8, chord, ' ');
    while (it.next()) |raw_token| {
        const token = std.mem.trim(u8, raw_token, " \t");
        if (token.len == 0) continue;
        if (result.len == kMaxTokens) return null;

        var parsed: Token = undefined;
        var control = false;
        var alt = false;
        var shift = false;
        var super_key = false;
        var parts = std.mem.splitScalar(u8, token, '-');
        var tail: []const u8 = "";
        var first_part = true;
        while (parts.next()) |part| {
            if (first_part) {
                tail = part;
                first_part = false;
                continue;
            }

            switch (tail.len) {
                1 => switch (tail[0]) {
                    'C' => control = true,
                    'M' => alt = true,
                    'S' => shift = true,
                    's' => super_key = true,
                    else => return null,
                },
                else => return null,
            }
            tail = part;
        }
        if (tail.len == 0) return null;
        parsed = .{ .key = keyFromName(tail) orelse return null, .control = control, .alt = alt, .shift = shift, .super_key = super_key };
        result.tokens[result.len] = parsed;
        result.len += 1;
    }
    if (result.len == 0) return null;
    return result;
}

test "parse single-token chords with and without modifiers" {
    const plain = parse("f").?;
    try std.testing.expectEqual(input.Key.f, plain.first().?.key);
    try std.testing.expectEqual(@as(usize, 1), plain.len);
    try std.testing.expectEqual(input.ModifierMatch.forbidden, plain.first().?.filter().control);
    try std.testing.expectEqual(input.ModifierMatch.forbidden, plain.first().?.filter().alt);

    const ctrl = parse("C-f").?;
    try std.testing.expectEqual(input.Key.f, ctrl.first().?.key);
    try std.testing.expectEqual(input.ModifierMatch.required, ctrl.first().?.filter().control);
    try std.testing.expectEqual(input.ModifierMatch.forbidden, ctrl.first().?.filter().alt);

    const meta = parse("M-backspace").?;
    try std.testing.expectEqual(input.Key.backspace, meta.first().?.key);
    try std.testing.expectEqual(input.ModifierMatch.required, meta.first().?.filter().alt);
    try std.testing.expectEqual(input.ModifierMatch.forbidden, meta.first().?.filter().control);

    const shift = parse("S-f").?;
    try std.testing.expectEqual(input.Key.f, shift.first().?.key);
    try std.testing.expectEqual(input.ModifierMatch.required, shift.first().?.filter().shift);

    const sup = parse("s-a").?;
    try std.testing.expectEqual(input.Key.a, sup.first().?.key);
    try std.testing.expectEqual(input.ModifierMatch.required, sup.first().?.filter().super);

    const stacked = parse("C-S-f").?;
    try std.testing.expectEqual(input.Key.f, stacked.first().?.key);
    try std.testing.expect(stacked.first().?.control);
    try std.testing.expect(stacked.first().?.shift);
    try std.testing.expect(!stacked.first().?.alt);
}

test "parse named keys and emacs aliases" {
    try std.testing.expectEqual(input.Key.page_up, parse("C-page_up").?.first().?.key);
    try std.testing.expectEqual(input.Key.enter, parse("RET").?.first().?.key);
    try std.testing.expectEqual(input.Key.enter, parse("RETURN").?.first().?.key);
    try std.testing.expectEqual(input.Key.tab, parse("TAB").?.first().?.key);
    try std.testing.expectEqual(input.Key.space, parse("SPC").?.first().?.key);
    try std.testing.expectEqual(input.Key.backspace, parse("DEL").?.first().?.key);
    try std.testing.expectEqual(input.Key.escape, parse("ESC").?.first().?.key);
    try std.testing.expectEqual(input.Key.@"2", parse("C-2").?.first().?.key);
    try std.testing.expectEqual(input.Key.f12, parse("f12").?.first().?.key);
}

test "parse multi-token chord sequences" {
    const chord = parse("C-x C-s").?;
    try std.testing.expectEqual(@as(usize, 2), chord.len);
    try std.testing.expectEqual(input.Key.x, chord.tokens[0].key);
    try std.testing.expect(chord.tokens[0].control);
    try std.testing.expectEqual(input.Key.s, chord.tokens[1].key);
    try std.testing.expect(chord.tokens[1].control);

    const triple = parse("C-x C-f RET").?;
    try std.testing.expectEqual(@as(usize, 3), triple.len);
    try std.testing.expectEqual(input.Key.enter, triple.tokens[2].key);
}

test "parse rejects malformed chords" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("   ") == null);
    try std.testing.expect(parse("C-") == null);
    try std.testing.expect(parse("C-foo") == null);
    try std.testing.expect(parse("X-f") == null);
    try std.testing.expect(parse("Cx-f") == null);
    try std.testing.expect(parse("C-f g h i j") == null);
    try std.testing.expectEqual(@as(usize, 4), parse("C-f g h i").?.len);
}

test "formatToken round-trips parse, canonical alias names" {
    var buf: [16]u8 = undefined;
    const seqOf = struct {
        fn f(t: Token) Sequence {
            return .{ .tokens = .{ t, undefined, undefined, undefined }, .len = 1 };
        }
    }.f;

    for ([_][]const u8{ "f", "C-f", "M-backspace", "S-f", "s-a", "C-S-f", "RET", "TAB", "SPC", "DEL", "ESC", "C-page_up", "C-2", "f12", "C-x" }) |text| {
        const token = parse(text).?.first().?;
        const formatted = formatToken(&buf, token);
        try std.testing.expect(seqOf(parse(formatted).?.first().?).eql(seqOf(token)));
    }

    for ([_][]const u8{ "f", "C-f", "S-f", "s-a", "C-S-f", "RET", "TAB", "SPC", "C-page_up", "C-2", "f12", "C-x" }) |text| {
        const token = parse(text).?.first().?;
        try std.testing.expectEqualStrings(text, formatToken(&buf, token));
    }
    try std.testing.expectEqualStrings("M-DEL", formatToken(&buf, parse("M-backspace").?.first().?));
    try std.testing.expectEqualStrings("ESC", formatToken(&buf, parse("ESC").?.first().?));
}

test "sequence equality covers modifiers and length" {
    const a = parse("C-x C-s").?;
    try std.testing.expect(a.eql(parse("C-x C-s").?));
    try std.testing.expect(!a.eql(parse("C-x C-f").?));
    try std.testing.expect(!a.eql(parse("C-x").?));
    try std.testing.expect(!a.eql(parse("s-x s-s").?));
    try std.testing.expect(parse("M-f").?.eql(parse("M-f").?));
    try std.testing.expect(!parse("M-f").?.eql(parse("C-f").?));
    try std.testing.expect(!parse("f").?.eql(parse("C-f").?));
}

fn keymapTestFixture(memory: *memory_mod.Memory, atoms: *Atom.Registry, tables: *Table.Registry) !plugin.KeymapRows {
    memory.init(std.testing.allocator);
    try atoms.init(memory);
    try tables.init(memory, 16);
    try plugin.Keymaps.ensure(try memory.tableScratchAllocator(), atoms, tables, actions.keymaps_table_name);
    return .{ .keymaps = plugin.Keymaps.of(memory, tables, actions.keymaps_table_name) };
}

test "buildKeymap makes one row, unbinding a chord with no action, and leaves out a bad chord" {
    var memory: memory_mod.Memory = undefined;
    var atoms: Atom.Registry = undefined;
    var tables: Table.Registry = undefined;
    var rows = try keymapTestFixture(&memory, &atoms, &tables);
    defer memory.deinit();
    defer atoms.deinit();
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const keys = [_]KeyDef{
        .{ .chord = "C-x C-s", .action = .{ "text", "save" } },
        .{ .chord = "C-" },
        .{ .chord = "C-q", .action = .{ "text", "" } },
        .{ .chord = "C-k" },
    };
    const built = try buildKeymap(arena.allocator(), &atoms, .{ .mode = atoms.intern("text"), .rank = .default, .keys = &keys });
    rows.sink().declare(built);

    var declared = rows.keymaps.iterate();
    const keymap = declared.next().?;
    try std.testing.expect(declared.next() == null);
    try std.testing.expectEqual(atoms.intern("text"), keymap.mode);
    try std.testing.expectEqual(actions.Rank.default, keymap.rank);
    try std.testing.expectEqual(@as(usize, 2), keymap.bindings.len);
    const save: actions.ActionId = .{ atoms.intern("text"), atoms.intern("save") };
    try std.testing.expectEqualSlices(Atom, &save, &keymap.bindings[0].action);
    try std.testing.expectEqual(@as(u8, 2), keymap.bindings[0].chord.len);
    try std.testing.expectEqualSlices(Atom, &actions.no_action, &keymap.bindings[1].action);
}

test "ChordLookup finds a chord through a parent unless a child hides it, a custom binding over a default" {
    var memory: memory_mod.Memory = undefined;
    var atoms: Atom.Registry = undefined;
    var tables: Table.Registry = undefined;
    var rows = try keymapTestFixture(&memory, &atoms, &tables);
    defer memory.deinit();
    defer atoms.deinit();
    defer tables.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const global = actions.global_mode;
    const text = atoms.intern("text");
    const global_keys = [_]KeyDef{
        .{ .chord = "C-x C-s", .action = .{ "text", "save" } },
        .{ .chord = "C-g", .action = .{ "text", "cancel" } },
    };
    const text_keys = [_]KeyDef{
        .{ .chord = "M-s", .action = .{ "text", "search" } },
        .{ .chord = "C-g" },
    };
    const sink = rows.sink();
    const global_keymap = try buildKeymap(arena.allocator(), &atoms, .{ .mode = global, .keys = &global_keys });
    sink.declare(global_keymap);
    const text_keymap = try buildKeymap(arena.allocator(), &atoms, .{ .mode = text, .keys = &text_keys });
    sink.declare(text_keymap);
    try actions.ensureTables(.{ .allocator = arena.allocator() }, &atoms, &tables);
    const registry = tables.findByName(Atom.from(actions.mode_registry_table)).?;
    _ = try registry.tryInsert(.{ .mode = text, .parent = global });

    // A custom row declared before the default one it overrides.
    const custom_keys = [_]KeyDef{.{ .chord = "M-s", .action = .{ "text", "find" } }};
    const custom_keymap = try buildKeymap(arena.allocator(), &atoms, .{ .mode = global, .keys = &custom_keys });
    sink.declare(custom_keymap);
    const default_keys = [_]KeyDef{.{ .chord = "M-s", .action = .{ "text", "search_default" } }};
    const default_keymap = try buildKeymap(arena.allocator(), &atoms, .{ .mode = global, .rank = .default, .keys = &default_keys });
    sink.declare(default_keymap);

    var lookup = try ChordLookup.build(arena.allocator(), rows.keymaps, registry);
    var buf: [32]u8 = undefined;
    const save: actions.ActionId = .{ text, atoms.intern("save") };
    try std.testing.expectEqualStrings("C-x C-s", (try lookup.chordFor(&buf, text, save)).?);
    const search: actions.ActionId = .{ text, atoms.intern("search") };
    try std.testing.expectEqualStrings("M-s", (try lookup.chordFor(&buf, text, search)).?);
    try std.testing.expect(try lookup.chordFor(&buf, global, search) == null);
    const cancel: actions.ActionId = .{ text, atoms.intern("cancel") };
    try std.testing.expectEqualStrings("C-g", (try lookup.chordFor(&buf, global, cancel)).?);
    try std.testing.expect(try lookup.chordFor(&buf, text, cancel) == null);
    const find: actions.ActionId = .{ text, atoms.intern("find") };
    try std.testing.expectEqualStrings("M-s", (try lookup.chordFor(&buf, global, find)).?);
    const search_default: actions.ActionId = .{ text, atoms.intern("search_default") };
    try std.testing.expect(try lookup.chordFor(&buf, global, search_default) == null);
}
