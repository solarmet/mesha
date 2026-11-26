//! Table documents by name and by file: what a document's id may be and where its file lies.
//!
//! A table document is a table saved as a file, named by a snake_case id (`validId`). Its
//! file is binary (`file_extension`, read and written by `Table.readFile` and
//! `Table.writeFile`) in a directory `kTablesDir`; an id `<scope>_<stem>` is the file
//! `<stem>` of the scope's directory (`idForStem`, `tablePathFor`). A document carries
//! metadata, keys and values beside its rows (`MetadataEntry`, `validKey`,
//! `kMaxMetadataValueBytes`, `sortMetadata`), and `fingerprint` hashes a file's bytes so a
//! writer can tell the file is still the one it read.
//!
//! Nothing here opens a file or keeps state: the functions work on names, paths and bytes
//! the caller holds. The resources system (`runtime/resources.zig`) is the main caller, and
//! decides itself which loaded plugin an id belongs to and so which directory its file is in.
const std = @import("std");
const Atom = @import("atom.zig").Atom;
const zon = @import("zon.zig");
const Table = @import("table.zig");

/// The directory of a plugin's table documents, relative to the plugin's directory; also where
/// `tablePathFor` puts a document with no scope.
pub const kTablesDir = "assets/tables";

/// What follows a scope's directory in the path `tablePathFor` gives a scoped document.
pub const kScopeTablesSuffix = "/assets/tables";

/// The most bytes a metadata entry's value may have. Checked where metadata is written
/// (`resources.validateMetadataRow`), not by anything in this file.
pub const kMaxMetadataValueBytes: usize = 1024;

/// A key and value saved with a document, beside its rows (`Table.FileMetadata`). Both slices
/// are borrowed from wherever the entry was read or built.
pub const MetadataEntry = Table.FileMetadata;

/// What a table file's name ends in.
pub const file_extension = ".msht";

fn validSegment(seg: []const u8) bool {
    if (seg.len == 0) return false;
    if (!std.ascii.isLower(seg[0])) return false;
    for (seg[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_' and c != '-') return false;
    }
    return true;
}

/// Whether `name` is a lowercase letter followed by lowercase letters, digits, `_` and `-`.
/// `tablePathFor` does not use it: the scope it takes must be a `validId`, which allows no `-`.
pub fn validScope(name: []const u8) bool {
    return validSegment(name);
}

/// Whether a metadata entry's key is well formed: a lowercase letter followed by lowercase
/// letters, digits, `_`, `.` and `-` (`Table.validFieldName`).
pub const validKey = Table.validFieldName;

/// The id's text before its first `_`, a slice of `id`; null when it has no `_`, or its only
/// one is its first or last byte. This reads the text alone and does not check `id`: the
/// plugin an id belongs to, whose name may itself hold a `_`, is `plugins.scopeOwner`'s to say.
pub fn scopeOf(id: []const u8) ?[]const u8 {
    const separator = std.mem.indexOfScalar(u8, id, '_') orelse return null;
    if (separator == 0 or separator == id.len - 1) return null;
    return id[0..separator];
}

/// What follows `scopeOf(id)` and its `_`, a slice of `id`; the whole id when it has no scope.
pub fn assetStem(id: []const u8) []const u8 {
    const scope = scopeOf(id) orelse return id;
    return id[scope.len + 1 ..];
}

/// The id of the document `stem` in `scope`: `<scope>_<stem>` written into `buf`, or null when
/// it does not fit. With no scope it is `stem` itself, returned as given and not copied. Neither
/// part is checked; pass the result to `validId`.
pub fn idForStem(buf: []u8, scope: ?[]const u8, stem: []const u8) ?[]const u8 {
    const s = scope orelse return stem;
    return std.fmt.bufPrint(buf, "{s}_{s}", .{ s, stem }) catch null;
}

/// `tablePathFor` with a scope: `<scope>/assets/tables/<stem>.msht` in `buf`, null as it is
/// there.
pub fn pathForIdInScope(buf: []u8, id: []const u8, scope: []const u8) ?[]const u8 {
    return tablePathFor(buf, id, scope);
}

/// `tablePathFor` with the scope `scopeOf` reads from the id: `app_levels` is
/// `app/assets/tables/levels.msht`, and an id with no `_` is `assets/tables/<id>.msht`. The
/// path is in `buf`; null when the id is not a `validId` or the path does not fit.
pub fn pathForId(buf: []u8, id: []const u8) ?[]const u8 {
    if (!validId(id)) return null;
    if (scopeOf(id)) |scope| return tablePathFor(buf, id, scope);
    return tablePathFor(buf, id, null);
}

/// Whether `id` may name a table document: snake_case, a lowercase letter followed by
/// lowercase letters, digits and single `_`s, not ending in one (`zon.isSnakeCaseAtom`). So an
/// id holds nothing a path could be built from but a file's stem.
pub fn validId(id: []const u8) bool {
    return zon.isSnakeCaseAtom(id);
}

/// A table file's relative path from its id and, optionally, its scope:
/// `<scope>/assets/tables/<stem>.msht`, the stem being what follows `<scope>_` in the id, or
/// `assets/tables/<id>.msht` with no scope. The path is written into `buf` and returned as a
/// slice of it. Null when `id` or `scope` is not a `validId`, the id does not begin
/// `<scope>_` or has nothing after it, the scope is over 126 bytes, or the path does not fit.
pub fn tablePathFor(buf: []u8, id: []const u8, scope: ?[]const u8) ?[]const u8 {
    if (!validId(id)) return null;
    if (scope) |s| {
        if (!validId(s)) return null;
        var prefix_buf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buf, "{s}_", .{s}) catch return null;
        if (!std.mem.startsWith(u8, id, prefix)) return null;
        const stem = id[prefix.len..];
        if (stem.len == 0) return null;
        return std.fmt.bufPrint(buf, "{s}" ++ kScopeTablesSuffix ++ "/{s}" ++ file_extension, .{ s, stem }) catch null;
    }
    return std.fmt.bufPrint(buf, kTablesDir ++ "/{s}" ++ file_extension, .{id}) catch null;
}

/// A hash of a document file's bytes (Wyhash, seed 0). The resources system keeps it for a file
/// it read or wrote, and refuses to write over a file whose bytes no longer hash to it.
pub fn fingerprint(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

fn metadataLess(_: void, a: MetadataEntry, b: MetadataEntry) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

/// Sorts `entries` in place by key, bytewise ascending.
pub fn sortMetadata(entries: []MetadataEntry) void {
    std.mem.sort(MetadataEntry, entries, {}, metadataLess);
}

const testing = std.testing;

test "table IDs accept only lowercase snake_case atoms" {
    try testing.expect(validId("foo"));
    try testing.expect(validId("scene_example_scene_descriptions"));
    try testing.expect(validId("a1_b_c_d_e"));
    try testing.expect(!validId(""));
    try testing.expect(!validId("Foo"));
    try testing.expect(!validId("_foo"));
    try testing.expect(!validId("foo__bar"));
    try testing.expect(!validId("foo-bar"));
    try testing.expect(!validId("foo.bar"));
    try testing.expect(!validId("foo/bar"));
    try testing.expect(!validId("1foo"));
}

test "table IDs and scoped paths use snake_case" {
    var buf: [256]u8 = undefined;
    try testing.expect(validId("app_scenes"));
    try testing.expect(!validId("app.scenes"));
    try testing.expect(!validId("app-scenes"));
    try testing.expectEqualStrings("app/assets/tables/scenes.msht", tablePathFor(&buf, "app_scenes", "app").?);
    try testing.expectEqualStrings("editor/assets/tables/panel_layouts.msht", tablePathFor(&buf, "editor_panel_layouts", "editor").?);
    try testing.expectEqualStrings("assets/tables/levels.msht", tablePathFor(&buf, "levels", null).?);
    try testing.expect(tablePathFor(&buf, "app.scenes", "app") == null);
    try testing.expect(tablePathFor(&buf, "app_levels", "editor") == null);
}

test "validKey accepts safe atom keys only" {
    try testing.expect(validKey("owner"));
    try testing.expect(validKey("a_b.c-d"));
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("Owner"));
    try testing.expect(!validKey("_x"));
    try testing.expect(!validKey("a/b"));
}

test "pathForId maps snake_case IDs to table files" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("app/assets/tables/levels.msht", pathForId(&buf, "app_levels").?);
    try testing.expectEqualStrings("app/assets/tables/act1_scene1.msht", pathForId(&buf, "app_act1_scene1").?);
    try testing.expectEqualStrings("assets/tables/levels.msht", pathForId(&buf, "levels").?);
    try testing.expect(pathForId(&buf, "../evil") == null);
    try testing.expect(pathForId(&buf, "Foo") == null);

    try testing.expectEqualStrings("app", scopeOf("app_levels").?);
    try testing.expectEqualStrings("levels", assetStem("app_levels"));
    try testing.expectEqualStrings("act1_scene1", assetStem("app_act1_scene1"));
    try testing.expectEqualStrings("levels", assetStem("levels"));
    try testing.expect(scopeOf("levels") == null);

    try testing.expectEqualStrings("levels", idForStem(&buf, null, "levels").?);
    try testing.expectEqualStrings("app_levels", idForStem(&buf, "app", "levels").?);
}
