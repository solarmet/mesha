//! The resources system's contract: what a plugin and the host share to load fonts and textures,
//! table documents, figure and sketch documents and configuration files. The runtime's side, which
//! reads files and owns the rows, is `runtime/resources.zig`.
//!
//! Everything is asked for with `request`, which appends a `CmdPayload` to `commands.resources`;
//! the host applies the rows after the frame's run. A request that names a `reply` route gets one
//! terminal message there, of the type its command says (`ResourceMsg`, `TableRequestMsg`,
//! `DocumentMsg` and the rest), in a later frame. What a request points at is copied when it is
//! appended.
//!
//! Resources live in memory scopes (`ScopeId`): a request names the scope's incarnation, and one
//! for a scope since closed is answered `stale_scope`. Fonts and textures are rows of the
//! `resources` table, a font found by name through a `FontProvider` as a `FontView`. Table
//! documents are indexed in `resources_table_assets`, with their metadata, instances and scopes
//! beside it; figure and sketch documents in `resources_document_assets`. The views here
//! (`TableAssetView` and the rest) read those tables' rows.
const std = @import("std");
const table_document_mod = @import("../core/table_document.zig");
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const gfx = @import("gfx.zig");
const font_mod = @import("font.zig");
const sequencer = @import("../core/sequencer.zig");
const builtin = @import("builtin");
const config_mod = @import("../core/config.zig");
const atom = @import("../core/atom.zig");
/// An interned name: a resource's, a document's id, a scope's.
pub const Atom = atom.Atom;

/// A parsed ZON document, as `load_config` answers with (`core/config.zig`).
pub const Config = config_mod.Config;

/// One incarnation of a memory scope: its name and a generation. A request carries it so that work
/// asked of a scope since closed, or closed and opened again, is refused as stale.
pub const ScopeId = memory_mod.Scope.Id;
/// The shared/UI scope, which lives until shutdown: fonts (`FontProvider` resolves through it),
/// inspectable table documents and anything else consumers borrow for the whole run.
pub const kApplicationScope: Atom = Atom.from("application");
/// Figure documents opened for authoring. This scope also lives until shutdown, and closing a
/// document returns its pages.
pub const kEditorDocumentsScope: Atom = Atom.from("editor_documents");

/// The application scope's id. Resolve it when submitting work and carry the id: dispatch must not
/// resolve the atom again. The runtime's `Resources.init` opens the scope before any plugin loads,
/// and without it this panics. Only unit tests, which have no host, may open it here.
pub fn applicationScope(memory: *memory_mod.Memory) ScopeId {
    if (memory.resolveScope(kApplicationScope)) |id| return id;
    if (!builtin.is_test) @panic("application scope is not open");
    return memory.openScope(kApplicationScope) catch |err| std.debug.panic("application scope: {s}", .{@errorName(err)});
}

/// The editor documents scope's id, under the same contract as `applicationScope`.
pub fn editorDocumentsScope(memory: *memory_mod.Memory) ScopeId {
    if (memory.resolveScope(kEditorDocumentsScope)) |id| return id;
    if (!builtin.is_test) @panic("editor documents scope is not open");
    _ = applicationScope(memory);
    return memory.openChildScope(kEditorDocumentsScope, kApplicationScope) catch |err| std.debug.panic("editor documents scope: {s}", .{@errorName(err)});
}

/// Scopes whose lifetime is the process: closing one by request is refused. Their figure
/// documents share one catalog and keep their plain id as store key, so at most one store of a
/// logical document exists across them.
pub fn isProcessScope(scope: ScopeId) bool {
    return scope.atom == kApplicationScope or scope.atom == kEditorDocumentsScope;
}
/// What a resource row holds: a `texture`, an image file uploaded as a texture, or a `font`, a font
/// file baked into an atlas with its glyphs.
pub const ResourceKind = enum(u32) { texture, font };

/// What to load: a file and the name it is known by in its scope. A change to this layout, or to
/// `FontView`'s, `CmdPayload`'s or a message's, needs the host and every plugin rebuilt together
/// and the host restarted.
pub const ResourceDecl = struct {
    /// The name the resource is found by in its scope; not the null atom.
    name: Atom,
    /// Whether the file is an image or a font.
    kind: ResourceKind,

    /// The file: under the plugin's `assets/` when the request names a plugin, else absolute or
    /// relative to the working directory when the request is applied (`CmdPayload.load_resource`).
    /// Not empty and holding no NUL. Borrowed for the call.
    path: []const u8,

    /// A font's baked height in pixels: above zero and no more than the atlas is wide. Unread for a
    /// texture.
    pixel_height: f32 = 0,

    /// The first codepoint of the contiguous range a font is baked with, when `glyph_codepoints` is
    /// empty.
    glyph_first_char: u32 = 32,
    /// The codepoints a font is baked with, `font.kMaxCodepoints` at most, each once. Empty bakes
    /// the contiguous range from `glyph_first_char` instead. Borrowed for the call.
    glyph_codepoints: []const u32 = &.{},
};

/// What `validateResourceDecl` finds wrong: `NullName`, `EmptyPath`, `PathContainsNul`, or for a
/// font one of `font.BakeInputError`. `InvalidKind` is never returned.
pub const ResourceDeclValidationError = error{
    InvalidKind,
    NullName,
    EmptyPath,
    PathContainsNul,
} || font_mod.BakeInputError;

/// Checks a declaration before anything is read: its name and path, and for a font what it is to be
/// baked with.
pub fn validateResourceDecl(decl: ResourceDecl) ResourceDeclValidationError!void {
    if (@intFromEnum(decl.name) == 0) return error.NullName;
    if (decl.path.len == 0) return error.EmptyPath;
    if (std.mem.indexOfScalar(u8, decl.path, 0) != null) return error.PathContainsNul;
    if (decl.kind == .font) {
        if (decl.glyph_codepoints.len == 0) {
            try font_mod.validateBakeParameters(decl.pixel_height, decl.glyph_first_char);
        } else {
            try font_mod.validateCodepoints(decl.pixel_height, decl.glyph_codepoints);
        }
    }
}

/// The catalog of table documents: a row for each document found on disk or resident, read as
/// `TableAssetView`.
pub const table_assets_name = "resources_table_assets";
/// The table documents' metadata: a row for each key of each document, read as `TableMetadataView`.
pub const table_metadata_name = "resources_table_metadata";
/// The table scopes the last index found, a row each holding the scope's name as text.
pub const table_scopes_name = "resources_table_scopes";
/// The table copies resident outside the application scope, read as `TableInstanceView`.
pub const table_instances_name = "resources_table_instances";
/// The rows `resources_table_assets` starts with room for; it grows as documents are found.
pub const kTableAssetsHint: u32 = 32;
/// One more than the longest metadata key, in bytes.
pub const kMetadataKeyBytes: usize = 128;
/// The rows `resources_table_metadata` starts with room for.
pub const kTableMetadataHint: u32 = 64;
/// The rows `resources_table_scopes` starts with room for.
pub const kTableScopesHint: u32 = 8;
/// The rows `resources_table_instances` starts with room for.
pub const kTableInstancesHint: u32 = 8;

/// Makes the four table catalogs, assets, metadata, scopes and instances, unless they are there.
/// The runtime's `Resources.init` calls it; a test without a host may. `allocator` holds each
/// schema while it is built. Errors are the allocator's and the registry's.
pub fn ensureTableAssetCatalog(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var assets_schema: Table.Schema = undefined;
    try assets_schema.init(allocator, atoms, 11);
    defer assets_schema.deinit();
    assets_schema.addField("id", Atom, .atom);
    assets_schema.addField("path", Table.String, .text_field);
    assets_schema.addField("state", u32, .int);
    assets_schema.addField("dirty", u8, .int);
    assets_schema.addField("persistable", u8, .int);
    assets_schema.addField("disk_present", u8, .int);
    assets_schema.addField("conflict", u8, .int);
    assets_schema.addField("fingerprint", u64, .hex);
    assets_schema.addField("table_index", u32, .int);
    assets_schema.addField("table_generation", u32, .int);
    assets_schema.addField("error_code", u32, .int);
    _ = try tables.ensure(&assets_schema, kTableAssetsHint, atoms.intern(table_assets_name), .durable);

    var meta_schema: Table.Schema = undefined;
    try meta_schema.init(allocator, atoms, 3);
    defer meta_schema.deinit();
    meta_schema.addField("id", Atom, .atom);
    meta_schema.addField("key", Table.String, .text_field);
    meta_schema.addField("value", Table.String, .text_field);
    _ = try tables.ensure(&meta_schema, kTableMetadataHint, atoms.intern(table_metadata_name), .durable);

    var scopes_schema: Table.Schema = undefined;
    try scopes_schema.init(allocator, atoms, 1);
    defer scopes_schema.deinit();
    scopes_schema.addField("name", Table.String, .text_field);
    _ = try tables.ensure(&scopes_schema, kTableScopesHint, atoms.intern(table_scopes_name), .durable);

    var instances_schema: Table.Schema = undefined;
    try instances_schema.init(allocator, atoms, 4);
    defer instances_schema.deinit();
    instances_schema.addField("key", Atom, .atom);
    instances_schema.addField("asset_id", Atom, .atom);
    instances_schema.addField("scope_atom", Atom, .atom);
    instances_schema.addField("scope_generation", u64, .int);
    _ = try tables.ensure(&instances_schema, kTableInstancesHint, atoms.intern(table_instances_name), .durable);
}

/// A resident table copy outside the application scope. `key` names its table, its
/// metadata rows and its row in the asset table, which holds its dirty state and save
/// baseline; `asset_id` is the document on disk. A row absent here is an application
/// instance, whose key is the asset id itself.
pub const TableInstanceView = struct {
    /// The copy's own name: its table's, and its row's `id` in the asset catalog.
    key: *Atom,
    /// The document the copy was made from.
    asset_id: *Atom,
    /// The name of the scope the copy lives in.
    scope_atom: *Atom,
    /// That scope's generation.
    scope_generation: *u64,
};

/// Where a table document stands, as its catalog row's `state`.
pub const TableAssetState = enum(u32) {
    /// Known by its file; no table is resident.
    indexed,

    /// Being read: set while a request loads the file.
    loading,

    /// Resident: `table_index` and `table_generation` name its table.
    attached,

    /// The last load or save failed; `error_code` says how.
    failed,
};

/// A row of `resources_table_assets`: one table document, or one resident copy of one.
pub const TableAssetView = struct {
    /// The document's id; for a copy outside the application scope, the copy's key.
    id: *Atom,
    /// Read when the row was fetched: a row whose path is written is fetched again.
    path: []const u8,
    /// A `TableAssetState`.
    state: *u32,

    /// 1 when the resident table has edits not yet saved.
    dirty: *u8,

    /// 1 when the resident table can be saved: it is persistent and its schema can be written.
    persistable: *u8,

    /// 1 when the document's file was there when last looked for.
    disk_present: *u8,

    /// 1 when the index found two files that claim the id.
    conflict: *u8,

    /// The hash of the file as last loaded or saved: what a save checks the file against.
    fingerprint: *u64,
    /// The resident table's handle index.
    table_index: *u32,
    /// The resident table's handle generation.
    table_generation: *u32,
    /// A `TableAssetError`.
    error_code: *u32,
};

/// A row of `resources_table_metadata`: one key and value of one document.
pub const TableMetadataView = struct {
    /// The document, or the copy's key.
    id: *Atom,
    /// The key, the table's until the row is written.
    key: []const u8,
    /// The value, the table's until the row is written.
    value: []const u8,
};

/// The metadata table, or null before the catalogs are made.
pub fn metadataTable(tables: *Table.Registry, atoms: *Atom.Registry) ?*Table {
    return tables.findByName(atoms.intern(table_metadata_name));
}

/// A metadata row as `MetadataRowIterator` gives it.
pub const MetadataRow = struct {
    /// The row, for writing or freeing it.
    handle: Table.RowHandle,
    /// The row's cells.
    view: TableMetadataView,
};

/// Walks the metadata table's rows, all of them or one document's. Make it with `metadataRows`.
pub const MetadataRowIterator = struct {
    /// The metadata table.
    meta: *Table,
    /// The document whose rows are given, or null for every row.
    id: ?Atom,
    /// The next row position to look at.
    r: u32 = 0,

    /// The next row, or null when there are no more.
    pub fn next(it: *MetadataRowIterator) ?MetadataRow {
        while (it.r < it.meta.rowCapacity()) : (it.r += 1) {
            if (!it.meta.isAllocated(it.r)) continue;
            const handle: Table.RowHandle = .{ .row = it.r, .generation = it.meta.rowGeneration(it.r) };
            const view = it.meta.getRow(handle, TableMetadataView) orelse continue;
            if (it.id) |want| if (view.id.* != want) continue;
            it.r += 1;
            return .{ .handle = handle, .view = view };
        }
        return null;
    }
};

/// The rows of `meta` for the document `id`, or every row when `id` is null.
pub fn metadataRows(meta: *Table, id: ?Atom) MetadataRowIterator {
    return .{ .meta = meta, .id = id };
}

/// Why a metadata row is refused: a key of `kMetadataKeyBytes` or more, or a value over
/// `table_document.kMaxMetadataValueBytes`.
pub const MetadataWriteError = error{ KeyTooLong, ValueTooLong };

/// Checks a key and a value against the lengths a metadata row may hold.
pub fn validateMetadataRow(key: []const u8, value: []const u8) MetadataWriteError!void {
    if (key.len >= kMetadataKeyBytes) return error.KeyTooLong;
    if (value.len > table_document_mod.kMaxMetadataValueBytes) return error.ValueTooLong;
}

/// Writes the metadata row `handle` of `meta` whole: its document, key and value. Errors: the
/// lengths `validateMetadataRow` refuses, and the table's when it cannot keep the text.
pub fn writeMetadataRow(meta: *Table, handle: Table.RowHandle, id: Atom, key: []const u8, value: []const u8) (MetadataWriteError || Table.PayloadWriteError)!void {
    try validateMetadataRow(key, value);
    try meta.setString(handle, "key", key);
    try meta.setString(handle, "value", value);
    try meta.writeFieldSingle(Atom, handle, "id", id);
}
/// The font atlas's shape and the checks on a bake (`font.zig`).
pub const font = font_mod;
/// Where a resource row stands, as its `state`.
pub const ResourceState = enum(u32) {
    /// No texture, sampler or image.
    unloaded,
    /// Read and decoded; its texture upload is with gfx.
    pending_texture,
    /// A font whose texture is made and whose sampler is with gfx.
    pending_sampler,
    /// Ready: a texture has its texture; a font has its texture, sampler and image handle.
    loaded,
    /// The load failed; the row holds nothing on the device.
    failed,

    /// Unloaded while an upload was in flight: the row waits for the upload's reply to free what it
    /// made, and is not found by name.
    evicted_pending,
};
/// Whether `table` is a copy of a table document outside the application scope: it lives in a scope
/// and its name is not interned.
pub fn isTableInstance(table: *const Table, atoms: *Atom.Registry) bool {
    return table.memory_scope != null and atoms.lookup(table.name) == null;
}

/// Whether `table`'s rows are resources' alone to create and release: a table copy, the instances
/// catalog, or the scoped `resources` table. Raw row operations on one would strand a payload
/// arena, GPU handles or waiting replies.
pub fn isOwnerManagedTable(table: *const Table, atoms: *Atom.Registry) bool {
    if (isTableInstance(table, atoms)) return true;
    if (table.name == atoms.intern(table_instances_name)) return true;
    return table.name == atoms.intern("resources") and table.getSchema().fieldIndex("scope_atom") != null;
}
/// Why a table document failed, as its catalog row's `error_code`: `none`; `file_read`; `parse`;
/// `invalid_id`; `duplicate_name`, when two files claim one id; `registry_full`; `not_persistable`,
/// a save of a table that cannot be written; `io`, a failed write.
pub const TableAssetError = enum(u32) { none, file_read, parse, invalid_id, duplicate_name, registry_full, not_persistable, io };
/// What a row owns, in an arena of its scope that is released with the row. A `FontView`
/// borrows these glyphs, so a view is valid only while its row stays loaded.
pub const ResourcePayload = struct {
    /// The file read: under the plugin's `assets/` when `plugin` names one.
    path: []const u8,
    /// The file's bytes when the host built them in, as the engine's font's are: read in place
    /// of `path`, which then only names them in logs. Static; empty for a file read from disk.
    embedded: []const u8 = &.{},
    /// The plugin whose directory `path` is in, whose release (`release_plugin`) unloads the
    /// row; `no_plugin` for a path the request named outright.
    plugin: Atom = no_plugin,
    /// A font's glyphs when it is baked by contiguous range.
    baked_chars: font_mod.BakedChars,
    /// A font's codepoints and glyphs when it is baked by list; its count is 0 otherwise.
    listed_glyphs: font_mod.ListedGlyphs,
    /// A font's em at the height it was baked, in pixels: the size its fallback glyphs are
    /// drawn at (`FontView.Fallback.em_pixels`).
    em_pixels: f32 = 0,
};
/// A resource row's `user_data` cell: unused, kept at its 64 bytes because the row schema
/// (`validateTableState`) requires it.
pub const RowUserData = [64]u8;
/// Makes the `resources` table, a row for each font and texture, with room for `capacity` rows. The
/// runtime's `Resources.init` calls it once. `allocator` holds the schema while it is built.
pub fn createRowTable(tables: *Table.Registry, atoms: *Atom.Registry, allocator: std.mem.Allocator, capacity: u32) !*Table {
    var schema: Table.Schema = undefined;
    // The runtime's `validateTableState` also accepts the schemas that keep glyphs in the row.
    try schema.init(allocator, atoms, 13);
    defer schema.deinit();
    schema.addField("scope_atom", Atom, .atom);
    schema.addField("scope_generation", u64, .int);
    schema.addField("name", Atom, .atom);
    schema.addField("kind", ResourceKind, .int);
    schema.addField("state", ResourceState, .int);
    schema.addField("texture", gfx.GfxResource, .hex);
    schema.addField("sampler", gfx.GfxResource, .hex);
    schema.addField("image", u32, .int);
    schema.addField("payload", ?*ResourcePayload, .hex);
    schema.addField("payload_arena", ?*memory_mod.Arena, .hex);
    schema.addField("pixel_height", f32, .{ .float_slider = .{ .min = 0, .max = 128 } });
    schema.addField("glyph_first_char", u32, .hex);
    schema.addField("user_data", RowUserData, .hex);
    const handle = try tables.create(&schema, capacity, atoms.intern("resources"), .durable);
    return tables.get(handle).?;
}
test "metadata row writes accept the longest key and value and reject longer ones" {
    var memory: memory_mod.Memory = undefined;
    memory.init(std.testing.allocator);
    defer memory.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&memory);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 8);
    defer tables.deinit();
    try ensureTableAssetCatalog(std.testing.allocator, &atoms, &tables);
    const meta = metadataTable(&tables, &atoms).?;
    const id: Atom = atoms.intern("test.metadata");
    const handle = try meta.alloc();
    const key = [_]u8{'k'} ** (kMetadataKeyBytes - 1);
    const value = [_]u8{'v'} ** table_document_mod.kMaxMetadataValueBytes;

    try writeMetadataRow(meta, handle, id, &key, &value);
    const view = meta.getRow(handle, TableMetadataView).?;
    try std.testing.expectEqualStrings(&value, view.value);
    try std.testing.expectEqualStrings(&key, view.key);

    const too_long_key = [_]u8{'k'} ** kMetadataKeyBytes;
    try std.testing.expectError(error.KeyTooLong, writeMetadataRow(meta, handle, id, &too_long_key, "value"));
    const too_long_value = [_]u8{'v'} ** (table_document_mod.kMaxMetadataValueBytes + 1);
    try std.testing.expectError(error.ValueTooLong, writeMetadataRow(meta, handle, id, "key", &too_long_value));
}
/// The metadata of the document `id`, sorted by key. The list and every key and value are
/// `allocator`'s: the caller frees each key and value, then the list. Empty before the catalogs are
/// made. Errors: `OutOfMemory`, with nothing left allocated.
pub fn metadataFor(allocator: std.mem.Allocator, tables: *Table.Registry, atoms: *Atom.Registry, id: Atom) ![]table_document_mod.MetadataEntry {
    const meta = metadataTable(tables, atoms) orelse return &.{};
    var entries: std.ArrayListUnmanaged(table_document_mod.MetadataEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.key);
            allocator.free(e.value);
        }
        entries.deinit(allocator);
    }
    var it = metadataRows(meta, id);
    while (it.next()) |row| {
        try entries.append(allocator, .{
            .key = try allocator.dupe(u8, row.view.key),
            .value = try allocator.dupe(u8, row.view.value),
        });
    }
    table_document_mod.sortMetadata(entries.items);
    return entries.toOwnedSlice(allocator);
}

/// The bound, in bytes, on a path resources keeps of a document or a table document: the
/// absolute path a figure's, a sketch's or a table's catalog row names, and `DocumentSaveMsg.path`,
/// is shorter than it. A request or save whose path, or that path made absolute, is this long or
/// longer is refused, and the person is told so; no path is kept cut.
pub const max_path = 1024;

/// Whether `path`, with `/` separators, is absolute by its text alone, the same on every system:
/// it begins at a root, `/`, a drive (`C:` alone or followed by `/`) or a server (`//name`). A
/// path that is not is relative to some working directory. The host makes paths absolute by
/// this rule (`runtime/path.zig`'s `rootOf`); `std.fs.path.isAbsolute` is not it, as on Linux it
/// takes `C:/x` for relative.
pub fn isAbsolutePath(path: []const u8) bool {
    const has_drive = path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
    if (has_drive) return path.len == 2 or path[2] == '/';
    return path.len != 0 and path[0] == '/';
}

test "a path is absolute by its root alone" {
    try std.testing.expect(isAbsolutePath("/x/fresh.mshf"));
    try std.testing.expect(isAbsolutePath("C:/x/fresh.mshf"));
    try std.testing.expect(isAbsolutePath("//server/x/fresh.mshf"));
    try std.testing.expect(!isAbsolutePath("fresh.mshf"));
    try std.testing.expect(!isAbsolutePath("C:fresh.mshf"));
    try std.testing.expect(!isAbsolutePath(""));
}

/// The catalog of figure and sketch documents by id: a row for each id a file holds, read as
/// `DocumentAssetView`.
pub const document_assets_name = "resources_document_assets";
/// The extension of figure documents, the `MSHF` files of `runtime/figure/file.zig`.
pub const figure_document_extension = ".mshf";
/// The extension of sketch documents, the `MSHS` files of `runtime/figure/sketch.zig`, kept beside
/// the figures they collect.
pub const sketch_document_extension = ".mshs";
/// The rows `resources_document_assets` starts with room for.
pub const kDocumentAssetsHint: u32 = 32;
/// A row of `resources_document_assets`: the file that holds a document id.
pub const DocumentAssetView = struct {
    /// The document's id, its file's stem.
    id: *Atom,
    /// `figure` or `sketch`.
    kind: *Atom,
    /// The file, absolute and shorter than `max_path`: the path the request or save that claimed
    /// the id named, made absolute when it was applied (a relative one against the working
    /// directory then), its directory resolved to its real path and its file's name as named.
    /// The table's until the row is written.
    path: []const u8,
    /// The hash of the file's bytes as last read or saved.
    fingerprint: *u64,
    /// 1 when the file was there as it was last read or saved. A request for the document by its
    /// id alone reads the file again and sets it (`request_document`); nothing else looks.
    disk_present: *u8,
    /// 1 while the document has edits not yet saved, as its store reports them.
    dirty: *u8,
};

/// Makes `resources_document_assets` unless it is there. The runtime's; `allocator` holds the
/// schema while it is built.
pub fn ensureDocumentAssetCatalog(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 6);
    defer schema.deinit();
    schema.addField("id", Atom, .atom);
    schema.addField("kind", Atom, .atom);
    schema.addField("path", Table.String, .text_field);
    schema.addField("fingerprint", u64, .hex);
    schema.addField("disk_present", u8, .int);
    schema.addField("dirty", u8, .int);
    _ = try tables.ensure(&schema, kDocumentAssetsHint, atoms.intern(document_assets_name), .durable);
}

/// How a request for a document ended.
pub const DocumentRequestResult = enum(u32) {
    /// The file was read: the reply carries its bytes and fingerprint.
    opened_loaded,
    /// No file: the catalog has none for the id, or the path names none.
    not_found,
    /// The file could not be read, or the request did not name a document file.
    load_failed,
    /// The file's size cannot be addressed in memory.
    too_large,
    /// The scope named was closed before the request was applied.
    stale_scope,
    /// Another file holds the id: the first file a request reaches claims it, until no other
    /// store holds a document of the id and its edits are saved. The reply's bytes are the
    /// holder's path, as the catalog keeps it.
    id_taken,
};
/// Whether a request for a document by path may claim its id for the file it reads.
pub const DocumentClaim = enum(u8) { claims, reads_only };
/// How a save of a document ended: `saved`; `conflict`, the file is not as `expected_fingerprint`
/// says, or the id is another file's; `too_large`, which no save gives; `write_failed`;
/// `stale_scope`; `directory_missing`, the folder the save names does not exist, and a save makes
/// no folder.
pub const DocumentSaveResult = enum(u32) { saved, conflict, too_large, write_failed, stale_scope, directory_missing };

/// A document reply as its receiver reads it (`documentOf`). Its payload is a `Head`, then the
/// document's bytes.
pub const DocumentMsg = struct {
    /// The incarnation named by the request, so a reply cannot be taken for a later one.
    scope: ScopeId,
    /// The document asked for.
    id: Atom,
    /// How the request ended.
    result: DocumentRequestResult,
    /// The message's own payload, the inbox arena's until the inbox is cleared: copy to keep.
    bytes: []const u8,
    /// The hash of `bytes`, to hand back as a save's `expected_fingerprint`; 0 without a document.
    fingerprint: u64,

    /// The fixed part of a document reply's payload; the document's bytes follow it.
    pub const Head = struct {
        /// The scope the request named.
        scope: ScopeId,
        /// The document asked for.
        id: Atom,
        /// How the request ended.
        result: DocumentRequestResult,
        /// The hash of the bytes that follow.
        fingerprint: u64,
    };

    fn head(document: DocumentMsg) Head {
        return .{ .scope = document.scope, .id = document.id, .result = document.result, .fingerprint = document.fingerprint };
    }
};

/// The document reply `received` carries, its bytes pointing into the message's payload; an
/// error when the payload is shorter than its head.
pub fn documentOf(received: sequencer.Message) error{MessageShape}!DocumentMsg {
    const payload = received.payload;
    if (payload.len < @sizeOf(DocumentMsg.Head)) return error.MessageShape;
    const head = std.mem.bytesToValue(DocumentMsg.Head, payload[0..@sizeOf(DocumentMsg.Head)]);
    return .{
        .scope = head.scope,
        .id = head.id,
        .result = head.result,
        .bytes = payload[@sizeOf(DocumentMsg.Head)..],
        .fingerprint = head.fingerprint,
    };
}

/// The payload of `document`'s reply, its head then its bytes, in `allocator`'s memory, as a
/// test answers a request by hand. Resources writes it into the inbox directly.
pub fn documentPayload(allocator: std.mem.Allocator, document: DocumentMsg) error{OutOfMemory}![]u8 {
    const head = document.head();
    const payload = try allocator.alloc(u8, @sizeOf(DocumentMsg.Head) + document.bytes.len);
    @memcpy(payload[0..@sizeOf(DocumentMsg.Head)], std.mem.asBytes(&head));
    @memcpy(payload[@sizeOf(DocumentMsg.Head)..], document.bytes);
    return payload;
}

/// The reply to `save_document`.
pub const DocumentSaveMsg = struct {
    /// The incarnation named by the request, so a reply cannot be taken for a later one.
    scope: ScopeId,
    /// The document saved.
    id: Atom,
    /// How the save ended.
    result: DocumentSaveResult,
    /// The file written, as the catalog keeps it, absolute (`DocumentAssetView.path`): inline
    /// and NUL-padded. Empty unless saved.
    path: [max_path]u8,
    /// The hash of the bytes written; 0 unless saved.
    fingerprint: u64,
};

/// `DocumentMsg` without the request's scope and id, as `Documents` produces it.
pub const DocumentReply = struct {
    /// How the request ended.
    result: DocumentRequestResult,
    /// The document's bytes, or under `id_taken` the holder's path. The runtime's reply arena's.
    bytes: []const u8,
    /// The hash of the document's bytes.
    fingerprint: u64,
};

/// `DocumentSaveMsg` without the request's scope and id, as `Documents` produces it.
pub const DocumentSaveReply = struct {
    /// How the save ended.
    result: DocumentSaveResult,
    /// The file written, absolute and NUL-padded; empty unless saved.
    path: [max_path]u8,
    /// The hash of the bytes written.
    fingerprint: u64,
};

/// Whether two paths name one document file (`same_document_file`).
pub const SameFileResult = enum(u32) { same, other, stale_scope };

/// The answer to `same_document_file`, naming what it asked about.
pub const SameFileMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// The document the request named.
    id: Atom,
    /// Whether the two paths name one file.
    result: SameFileResult,
};

/// A save of a document's bytes to its file (`save_document`). The file is `path`, or with none the
/// file the catalog has for the id; with neither the save is `write_failed`. Answered with a
/// `DocumentSaveMsg`.
pub const SaveDocument = struct {
    /// The scope of the store that saves.
    scope: ScopeId,
    /// The document's id, which is its file's stem.
    id: Atom,
    /// `figure` or `sketch`: it gives the file's extension.
    kind: Atom,
    /// The file to write, named `<id><kind's extension>` in a folder that exists: absolute, or
    /// relative to the working directory when the save is applied, and made absolute then; the
    /// catalog keeps it so. Null writes the file the catalog has for the id. Borrowed for the call.
    path: ?[]const u8 = null,
    /// The document as it is to be written. Borrowed for the call.
    bytes: []const u8,
    /// The fingerprint the file must have for the save to write over it, as a `DocumentMsg` or an
    /// earlier save gave it; a file that differs is a `conflict`. Null means create only: the save
    /// is a `conflict` when the file exists.
    expected_fingerprint: ?u64 = null,
    /// Where the `DocumentSaveMsg` is sent.
    reply: sequencer.ReplyTo = .{},
};
/// How a request for a table document ended.
pub const TableRequestResult = enum(u32) {
    /// The table was already resident in the scope.
    opened_resident,

    /// The table was loaded from its file.
    opened_loaded,

    /// A new, empty table was made (`create_table`).
    created,
    /// The id has no file.
    not_found,
    /// The id is not a table document's, or resolves to no path.
    invalid_id,
    /// The file could not be read or parsed, no code has registered its schema, or two files claim
    /// the id.
    load_failed,
    /// There was no room or memory for the table.
    registry_full,
    /// The scope named was closed before the request was applied.
    stale_scope,
};

/// The reply to `request_table`, `create_table` and `reload_table`.
pub const TableRequestMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// The document asked for.
    id: Atom,
    /// The table, when `result` is one of the three that open it; else the null handle.
    handle: Table.Handle,
    /// How the request ended.
    result: TableRequestResult,
};

/// The reply to `save_table`.
pub const TableSaveMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// The document saved.
    id: Atom,
    /// Whether the file was written.
    ok: bool,

    /// Whether the save was refused because the file changed on disk since it was loaded or saved,
    /// or because two files claim the id. `overwrite` saves over a changed file.
    conflict: bool,
};

/// The reply to `refresh_table_index`.
pub const TableIndexMsg = struct {
    /// How many table documents the scan found.
    count: u32,
};

/// A row of the `resources` table.
pub const ResourceHandle = Table.RowHandle;
/// A loaded font as text drawing reads it. Borrowed: valid only while the resource stays loaded.
pub const FontView = struct {
    /// The glyphs of the contiguous range from `first_char`; read when `listed_codepoints` is
    /// empty.
    baked_chars: *const font_mod.BakedChars,
    /// The height the font was baked at, in pixels.
    pixel_height: f32,
    /// The atlas's roop image handle.
    image: u32,
    /// The first codepoint of the contiguous range.
    first_char: u32,
    /// The codepoints of a font baked by list; empty for one baked by range.
    listed_codepoints: []const u32 = &.{},
    /// The glyph of each listed codepoint, at its index.
    listed_chars: []const font_mod.Glyph = &.{},
    /// Where a codepoint the font lacks is looked for; null while the host has no fallback
    /// fonts (`CmdPayload.set_fallback_fonts`).
    fallback: ?Fallback = null,

    /// The host's fallback fonts, as a font sees them: a codepoint the font lacks is looked
    /// for in each in turn, drawn at the font's em.
    pub const Fallback = struct {
        /// The host's cache of fallback glyphs, passed to `get_fn`.
        context: *anyopaque,
        /// The em of the font that falls back, in pixels: fallback glyphs are drawn at it so
        /// they match its letters.
        em_pixels: f32,
        /// Writes the glyph of `codepoint` at `em_pixels` to `found`, or returns false when
        /// no fallback font has it. The first time a glyph is asked for it is drawn into one
        /// of the host's atlases there and then; until that atlas is on the GPU, `found.image`
        /// is 0, and the glyph measures but draws nothing. C's calling convention: a plugin
        /// built by another backend than the host's calls it. The sim thread's.
        get_fn: *const fn (context: *anyopaque, em_pixels: f32, codepoint: u32, found: *FallbackGlyph) callconv(.c) bool,
    };

    /// A glyph and the atlas it is drawn from: the font's own, or a fallback font's.
    pub const Resolved = struct {
        /// The glyph, its box in `image`'s atlas.
        glyph: font_mod.Glyph,
        /// The atlas's roop image handle; 0 for a fallback glyph whose atlas is not yet on the
        /// GPU, which measures but draws nothing.
        image: u32,
    };

    /// The glyph for `codepoint` from the font, or else from its fallback fonts; null when
    /// none has it.
    pub fn resolve(self: FontView, codepoint: u32) ?Resolved {
        if (self.glyph(codepoint)) |own| return .{ .glyph = own.*, .image = self.image };
        const fallback = self.fallback orelse return null;
        var found: FallbackGlyph = undefined;
        const has_glyph = fallback.get_fn(fallback.context, fallback.em_pixels, codepoint, &found);
        if (!has_glyph) return null;
        return .{ .glyph = found.glyph, .image = found.image };
    }

    /// The glyph for `codepoint`, or null when the font was not baked with it. A listed font is
    /// searched in order. Its fallback fonts are not looked in (`resolve` does).
    pub fn glyph(self: FontView, codepoint: u32) ?*const font_mod.Glyph {
        if (self.listed_codepoints.len != 0) {
            for (self.listed_codepoints, 0..) |listed, index| {
                if (listed == codepoint) return &self.listed_chars[index];
            }
            return null;
        }
        if (codepoint < self.first_char) return null;
        const index = codepoint - self.first_char;
        if (index >= self.baked_chars.len) return null;
        return &self.baked_chars[index];
    }

    /// The font's metrics, as `resources_font_metrics` keeps them. It looks at every glyph.
    pub fn metrics(self: FontView) FontMetrics {
        const glyphs: []const font_mod.Glyph = if (self.listed_codepoints.len != 0) self.listed_chars else self.baked_chars;
        var highest: f32 = 0;
        for (glyphs) |baked| {
            const has_ink = baked.x0 != baked.x1;
            if (has_ink and baked.yoff < highest) highest = baked.yoff;
        }
        const ascender = -highest;
        var cap_height = ascender;
        if (self.glyph('H')) |capital| {
            if (capital.x0 != capital.x1) cap_height = -capital.yoff;
        }
        const mono_advance = if (self.glyph('M')) |wide| wide.xadvance else 0;
        return .{ .pixel_height = self.pixel_height, .ascender = ascender, .cap_height = cap_height, .mono_advance = mono_advance };
    }
};

/// A fallback glyph as the host hands it over (`FontView.Fallback.get_fn`).
pub const FallbackGlyph = extern struct {
    /// The glyph, its box in `image`'s atlas.
    glyph: font_mod.Glyph,
    /// The atlas's roop image handle, or 0 while the atlas is not yet on the GPU.
    image: u32,
};

/// What a font measures, for code that lays text out where nothing draws: a kernel that
/// scrolls by lines, or places a caret by cells. In pixels, at the height the font was baked.
pub const FontMetrics = struct {
    /// The height the font was baked at: a line of it is this tall before any spacing.
    pixel_height: f32,
    /// How far the font reaches above the baseline: the highest of its glyphs with ink.
    ascender: f32,
    /// The height of its capital letters above the baseline, its `H`'s; the ascender for a
    /// font without one, as an icon font.
    cap_height: f32,
    /// How far the pen moves after an `M`: a cell's width in a monospace font. Zero for a font
    /// without one.
    mono_advance: f32,
};

/// `resources_font_metrics`: a row for each font that is loaded, which the runtime writes when
/// a font finishes loading and removes when it goes, at the start of the next frame. Anything
/// reads it; only the runtime writes it.
pub const font_metrics_table_name = "resources_font_metrics";
/// The rows `resources_font_metrics` starts with room for.
pub const kFontMetricsHint: u32 = 32;
/// A row of `resources_font_metrics`.
pub const FontMetricsView = struct {
    /// The scope the font was loaded in, by its atom: `kApplicationScope` for the fonts text
    /// drawing resolves.
    scope: *Atom,
    /// The name the font was loaded under.
    name: *Atom,
    /// `FontMetrics.pixel_height`.
    pixel_height: *f32,
    /// `FontMetrics.ascender`.
    ascender: *f32,
    /// `FontMetrics.cap_height`.
    cap_height: *f32,
    /// `FontMetrics.mono_advance`.
    mono_advance: *f32,
};

/// Makes `resources_font_metrics` unless it is there. The runtime's; `allocator` holds the
/// schema while it is built.
pub fn ensureFontMetrics(allocator: std.mem.Allocator, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    var schema: Table.Schema = undefined;
    try schema.init(allocator, atoms, 6);
    defer schema.deinit();
    schema.addField("scope", Atom, .atom);
    schema.addField("name", Atom, .atom);
    schema.addField("pixel_height", f32, .{ .float_slider = .{ .min = 0, .max = 128 } });
    schema.addField("ascender", f32, .{ .float_slider = .{ .min = 0, .max = 128 } });
    schema.addField("cap_height", f32, .{ .float_slider = .{ .min = 0, .max = 128 } });
    schema.addField("mono_advance", f32, .{ .float_slider = .{ .min = 0, .max = 128 } });
    _ = try tables.ensure(&schema, kFontMetricsHint, atoms.intern(font_metrics_table_name), .durable);
}

/// The metrics of the font loaded as `name` in the scope `scope`, read from `metrics`, the
/// `resources_font_metrics` table; null while the font is not loaded. A kernel hands it the
/// table its system declared read.
pub fn fontMetrics(metrics: *Table, scope: Atom, name: Atom) ?FontMetrics {
    var rows = metrics.readQuery(FontMetricsView);
    while (rows.next()) |found| {
        const row = found.view;
        if (row.scope.* != scope or row.name.* != name) continue;
        return .{ .pixel_height = row.pixel_height.*, .ascender = row.ascender.*, .cap_height = row.cap_height.*, .mono_advance = row.mono_advance.* };
    }
    return null;
}

/// How text drawing finds a scope's fonts by name: a call into the host's resources. The runtime's
/// `Resources.fontProvider` makes one, and roop's `Renderer` holds it.
pub const FontProvider = struct {
    /// The host's state, passed to `get_fn`.
    context: *anyopaque,
    /// Names resolve only among this scope's fonts. A closed scope resolves nothing.
    scope: ScopeId,
    /// Writes the font named `name` to `found`, or returns false when there is none. C's calling
    /// convention: a plugin built by another backend than the host's calls it.
    get_fn: *const fn (context: *anyopaque, scope: *const ScopeId, name: Atom, found: *FontView) callconv(.c) bool,

    /// The font loaded as `name` in the provider's scope, or null when there is none or it has not
    /// finished loading.
    pub fn get(self: FontProvider, name: Atom) ?FontView {
        var view: FontView = undefined;
        const found = self.get_fn(self.context, &self.scope, name, &view);
        if (!found) return null;
        return view;
    }
};

/// No plugin: a `load_resource` whose path is the file's own.
pub const no_plugin: Atom = @enumFromInt(0);

/// A font text is drawn in, described by what it is: a file of a plugin's `assets/` baked at a
/// pixel height with a set of glyphs. Its row in the application scope is named by all of that
/// (`init`), so callers that describe the same font share one bake and agree on no name
/// beforehand. Text drawn in a font that is not loaded yet is drawn in the engine's font
/// (`engine`) while drawing asks for this one (roop's `Context.text`). A value whose slices
/// are static: `init` makes it at compile time.
pub const Font = struct {
    /// The name its row is found by in the application scope, made by `init` from the rest.
    name: Atom,
    /// What `name` is made from, as a person reads it in a log: `<plugin>/<path>@<height>`,
    /// then `+<first>` for a range that does not start at a space or `#<hash>` for a list.
    label: []const u8,
    /// The plugin whose `assets/` holds `path`; `no_plugin` for a font its owner loads itself.
    plugin: Atom,
    /// The file within the plugin's `assets/`. Empty for a font its owner loads itself, as the
    /// engine's is: drawing never asks for one (roop's `Context.fontView`).
    path: []const u8,
    /// The height it is baked at, in pixels; zero for the engine's font, whose height is the
    /// host's.
    pixel_height: f32,
    /// As `ResourceDecl.glyph_first_char`.
    glyph_first_char: u32 = 32,
    /// As `ResourceDecl.glyph_codepoints`. Static.
    glyph_codepoints: []const u32 = &.{},

    /// What `init` makes a font from: the plugin's name and the rest as `Font`'s fields.
    pub const Spec = struct {
        /// The name of the plugin whose `assets/` holds `path`.
        plugin: []const u8,
        /// The file within the plugin's `assets/`.
        path: []const u8,
        /// The height it is baked at, in pixels.
        pixel_height: f32,
        /// As `ResourceDecl.glyph_first_char`.
        glyph_first_char: u32 = 32,
        /// As `ResourceDecl.glyph_codepoints`.
        glyph_codepoints: []const u32 = &.{},
    };

    /// The font `spec` describes, named by all of it. A spec that cannot be baked is a compile
    /// error.
    pub fn init(comptime spec: Spec) Font {
        comptime {
            // Checking a list for repeats compares each codepoint with the rest.
            @setEvalBranchQuota(4 * font_mod.kMaxCodepoints * font_mod.kMaxCodepoints + 10_000);
            const range = spec.glyph_codepoints.len == 0;
            if (range) {
                font_mod.validateBakeParameters(spec.pixel_height, spec.glyph_first_char) catch |err| @compileError("font " ++ spec.path ++ ": " ++ @errorName(err));
            } else {
                font_mod.validateCodepoints(spec.pixel_height, spec.glyph_codepoints) catch |err| @compileError("font " ++ spec.path ++ ": " ++ @errorName(err));
            }
            const glyphs = if (!range)
                std.fmt.comptimePrint("#{x}", .{codepointsHash(spec.glyph_codepoints)})
            else if (spec.glyph_first_char != 32)
                std.fmt.comptimePrint("+{x}", .{spec.glyph_first_char})
            else
                "";
            const label = std.fmt.comptimePrint("{s}/{s}@{d}{s}", .{ spec.plugin, spec.path, spec.pixel_height, glyphs });
            return .{
                .name = Atom.from(label),
                .label = label,
                .plugin = Atom.from(spec.plugin),
                .path = spec.path,
                .pixel_height = spec.pixel_height,
                .glyph_first_char = spec.glyph_first_char,
                .glyph_codepoints = spec.glyph_codepoints,
            };
        }
    }

    /// The engine's font, which the host bakes before any plugin loads and which never goes:
    /// text that names no font is drawn in it, and so is text in a font not loaded yet.
    pub const engine: Font = .{ .name = Atom.from(engine_label), .label = engine_label, .plugin = no_plugin, .path = "", .pixel_height = 0 };
    const engine_label = "engine_font";

    /// Whether drawing may ask for it when it is not loaded: whether it has a file to load.
    pub fn askable(self: Font) bool {
        return self.path.len != 0;
    }

    /// The declaration that loads it; borrows its slices.
    pub fn decl(self: Font) ResourceDecl {
        return .{
            .name = self.name,
            .kind = .font,
            .path = self.path,
            .pixel_height = self.pixel_height,
            .glyph_first_char = self.glyph_first_char,
            .glyph_codepoints = self.glyph_codepoints,
        };
    }

    // FNV-1a over the codepoints' values, which compile-time code can read where it cannot
    // reinterpret them as bytes.
    fn codepointsHash(comptime codepoints: []const u32) u64 {
        @setEvalBranchQuota(20 * codepoints.len + 1000);
        var hash: u64 = 0xcbf29ce484222325;
        for (codepoints) |codepoint| {
            hash ^= codepoint;
            hash *%= 0x100000001b3;
        }
        return hash;
    }
};

/// Why a configuration file did not load: `invalid_path`, empty or holding a NUL; `read_failed`;
/// `parse_failed`; `out_of_memory`; `stale_scope`.
pub const ConfigLoadFailure = enum(u32) { invalid_path, read_failed, parse_failed, out_of_memory, stale_scope };

/// How `load_config` ended.
pub const ConfigResult = union(enum) {
    /// The parsed document. Borrowed from the runtime's reply arena, which is reset at a later
    /// `Resources.beginFrame` once the reply has been delivered: the receiver copies whatever it
    /// keeps and does not free this.
    loaded: *Config,
    /// Why nothing loaded.
    failed: ConfigLoadFailure,
};

/// The reply to `load_config`.
pub const ConfigMsg = struct {
    /// The document, or why there is none.
    result: ConfigResult,
};

/// Terminal outcome of one load or reload request. Each request that names a reply
/// route receives exactly one, including duplicates that join a load already running.
pub const ResourceLoadResult = enum(u32) {
    /// The file was read and its uploads finished: the row is ready.
    loaded,
    /// The resource was already resident; this request started no work.
    already_loaded,
    /// The file could not be read, decoded or uploaded, or its declaration was refused.
    load_failed,
    /// Unloaded or replaced before the load finished.
    cancelled,
    /// A reload of a name not resident, or a load naming a plugin that has no row.
    unknown_resource,
    /// The scope named was closed before the request was applied.
    stale_scope,
};

/// How an unload ended.
pub const ResourceUnloadResult = enum(u32) {
    /// The CPU row is gone. GPU destruction has been handed to the gfx queue, or will be
    /// when an in-flight upload reply arrives for a row a reload replaced. This does not
    /// mean the GPU is idle.
    unloaded,
    /// The scope has no resource of the name.
    not_resident,
    /// The scope named was closed before the request was applied.
    stale_scope,
    /// Refused before anything changed: no storage for this request's terminal reply.
    out_of_memory,
};

/// How a request to close a scope ended.
pub const ResourceScopeCloseResult = enum(u32) {
    /// Every row is gone and the scope's memory is released. Row bookkeeping lives in the
    /// shared registry table and is reused, not charged to the scope. GPU destruction has
    /// been handed to the gfx queue, which does not mean the GPU is idle.
    closed,
    /// The scope named was already closed.
    stale_scope,
    /// Refused before anything changed: an owner still holds the scope's direct backing.
    backing_outstanding,
    /// Refused before anything changed: a table instance has unsaved edits. Closing does
    /// not implicitly save or discard them.
    dirty_instances,
    /// A process scope (see `isProcessScope`) is not closed by request.
    unsupported_scope,
    /// Refused before anything changed: a figure document has unsaved edits or an open
    /// transaction. Closing does not implicitly save or discard them.
    dirty_documents,
    /// Refused before anything changed: a figure save is in flight and owns its reply.
    save_pending,
    /// Refused before anything changed: the editor holds a figure document of this scope open.
    documents_borrowed,
    /// Refused before anything changed: no storage for the results that must outlive the scope.
    out_of_memory,
};

/// The stores `Resources` releases with a scope, or asks about, but cannot name: the figure
/// library builds on this module. The host wires the one implementation; it is not a
/// destructor registry.
pub const ScopeStores = struct {
    /// The implementation's state, passed to each function.
    context: *anyopaque,
    /// Observation plus reservation for `drain`, before the scope changes state. Null admits it.
    preflight: *const fn (context: *anyopaque, scope: ScopeId) ?ResourceScopeCloseResult,
    /// Runs once for an accepted close, with the scope already closing and before its tables
    /// are destroyed. Releases instances and stores; moves results to surviving storage.
    drain: *const fn (context: *anyopaque, scope: ScopeId) void,
    /// Whether a store other than the asker's holds a document of `id`, and with it the id's
    /// catalog row: a figure loaded or being read in a scope other than `scope`, or an open
    /// sketch unless `kind` is `sketch`. The asker is the store of `kind` in `scope` whose
    /// request or save resources is weighing, never its own rival. An observation.
    holds_document: *const fn (context: *anyopaque, id: Atom, scope: ScopeId, kind: Atom) bool,
};

/// The reply to `close_resource_scope`.
pub const ResourceScopeClosedMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// How the close ended.
    result: ResourceScopeCloseResult,
};

/// The reply to `load_resource` and `reload_resource`.
pub const ResourceMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// The resource's name.
    name: Atom,
    /// Invalid when `result` is a rejection or the row has already been released.
    handle: ResourceHandle,
    /// How the load ended.
    result: ResourceLoadResult,
};

/// The reply to `unload_resource`.
pub const ResourceUnloadMsg = struct {
    /// The scope the request named.
    scope: ScopeId,
    /// The resource's name.
    name: Atom,
    /// How the unload ended.
    result: ResourceUnloadResult,
};

/// One request of the resources system. Slices are borrowed for the call that appends the request,
/// which copies them. Every `reply` is where the command's one terminal message is sent; left
/// empty, nothing is sent.
pub const CmdPayload = union(enum) {
    /// Reads and parses the ZON file at `path`. Answered with a `ConfigMsg`.
    load_config: struct {
        /// A scope that must still be open when the request is applied.
        scope: ScopeId,
        /// The file: absolute, or relative to the working directory when the request is
        /// applied, and made absolute then.
        path: []const u8,
        /// Where the `ConfigMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Loads `decl` as `decl.name` in `scope`, unless that name is resident there: then the
    /// request joins it and nothing is read. With `plugin` naming a loaded plugin, `decl.path`
    /// is relative to its `<directory>/assets/`, and the plugin's release unloads the row; a
    /// plugin no row names is answered `unknown_resource`. Without one, `decl.path` is the
    /// file's path: absolute, or relative to the working directory when the request is applied,
    /// and made absolute then, so a reload reads the same file wherever the working directory
    /// has gone.
    load_resource: struct {
        /// The scope the resource is loaded into and found in.
        scope: ScopeId,
        /// What to load, and under what name.
        decl: ResourceDecl,
        /// The plugin whose `assets/` holds the file, or `no_plugin`.
        plugin: Atom = no_plugin,
        /// Where the `ResourceMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Releases the resource `name` of `scope`: its row goes and its texture and sampler are
    /// destroyed through gfx, once any upload in flight has replied. Requests still waiting on its
    /// load hear `cancelled`. Answered with a `ResourceUnloadMsg`.
    unload_resource: struct {
        /// The scope the resource is in.
        scope: ScopeId,
        /// The resource's name.
        name: Atom,
        /// Where the `ResourceUnloadMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Closes `scope`: releases every resource, table copy and document store in it and its memory.
    /// New work in the scope stops at once; the reply follows once any upload in flight has
    /// replied. A close is refused whole when something in the scope holds unsaved work
    /// (`ResourceScopeCloseResult`). Answered with a `ResourceScopeClosedMsg`.
    close_resource_scope: struct {
        /// The scope to close.
        scope: ScopeId,
        /// Where the `ResourceScopeClosedMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Reads the file of the resident resource `name` again and replaces its row. A file that fails
    /// to load leaves the resident row as it was; requests still waiting on the old row hear
    /// `cancelled`. Answered with a `ResourceMsg`.
    reload_resource: struct {
        /// The scope the resource is in.
        scope: ScopeId,
        /// The resource's name.
        name: Atom,
        /// Where the `ResourceMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Sets the fonts text falls back to for a character its own font lacks, searched in
    /// order, replacing any set before: every font then looks in them (`FontView.resolve`).
    /// A file is read the first time a character is looked for in it; one that cannot be read,
    /// or is no font stb_truetype reads (a CFF2 variable font), is logged and left out.
    /// Characters are drawn one by one, never shaped: a script whose letters join or reorder
    /// (Arabic, the Indic scripts) shows each in its own form. Not answered.
    set_fallback_fonts: struct {
        /// Absolute paths of font files or collections (the first font of a collection is
        /// read), separated by `\n`; empty for none.
        paths: []const u8,
    },

    /// Scans the `assets/tables/` of each loaded plugin that holds tables again, and brings
    /// `resources_table_assets` and `resources_table_scopes` in step with what is found. Answered
    /// with a `TableIndexMsg`.
    refresh_table_index: struct {
        /// Where the `TableIndexMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Opens the table document `id` in `scope`: the resident table if there is one, else its file
    /// loaded. Answered with a `TableRequestMsg`.
    request_table: struct {
        /// The scope the table is opened in.
        scope: ScopeId,
        /// The document's id.
        id: Atom,
        /// Where the `TableRequestMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Makes the document's table, holding nothing: no rows, or a singleton's one row with
    /// every cell absent.
    create_table: struct {
        /// The scope the table is made in.
        scope: ScopeId,
        /// The document's id, under which code has registered a schema.
        id: Atom,
        /// Where the `TableRequestMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Writes the resident table `id` of `scope` to its document's file. A file changed on disk
    /// since it was loaded or saved is not written over unless `overwrite`. Answered with a
    /// `TableSaveMsg`.
    save_table: struct {
        /// The scope the table is resident in.
        scope: ScopeId,
        /// The document's id.
        id: Atom,
        /// Whether to write over a file that changed on disk.
        overwrite: bool = false,
        /// Where the `TableSaveMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// Reads the document's file again into the resident table `id` of `scope`; with no table
    /// resident, as `request_table`. Answered with a `TableRequestMsg`.
    reload_table: struct {
        /// The scope the table is resident in.
        scope: ScopeId,
        /// The document's id.
        id: Atom,
        /// Where the `TableRequestMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// The document `id`: with an empty `path`, the file the catalog has for it; else the file
    /// at `path` (absolute, or relative to the working directory when the request is applied,
    /// and made absolute then), whose stem is the id's and
    /// whose extension is `kind`'s. The first file a request reaches claims the id; another
    /// file's request for it is answered `id_taken`. A non-empty `holder` is the file a loaded
    /// document of the id holds, which the catalog may no longer name: another file is
    /// answered `id_taken` naming `holder`, claiming nothing; that file (as
    /// `same_document_file` compares) is answered as any request by path, which may claim it.
    /// With `claim` `.reads_only` the file is read and answered as it would be, and the id is
    /// claimed for no file: a save's look at the file it will write over. Reading the catalog's
    /// file sets its row's `disk_present`; finding it gone forgets the row, unless its document
    /// has edits not yet saved, whose row stays until they are.
    request_document: struct {
        /// The scope of the store that asks.
        scope: ScopeId,
        /// The document's id.
        id: Atom,
        /// The file to read, or empty for the file the catalog has for the id.
        path: []const u8 = "",
        /// `figure` or `sketch`, for a request by path; unread without a path.
        kind: Atom = @enumFromInt(0),
        /// The file a loaded document of the id holds, or empty.
        holder: []const u8 = "",
        /// Whether the request may claim the id for the file.
        claim: DocumentClaim = .claims,
        /// Where the `DocumentMsg` is sent; read it with `documentOf`.
        reply: sequencer.ReplyTo = .{},
    },

    /// Writes a document's bytes to its file (`SaveDocument`).
    save_document: SaveDocument,

    /// Whether the file at `path` is the file at `holder`, the file a loaded document `id`
    /// was read from: by their real paths when both are there; when both are gone, by the two
    /// paths made absolute as the catalog makes them (`DocumentAssetView.path`), the real path
    /// of a directory that is there, else against the working directory with `.`, `..` and
    /// repeated separators resolved by their text; one there and one gone are two files. An
    /// observation: it reads no document and changes no catalog row. Answered with a
    /// `SameFileMsg`.
    same_document_file: struct {
        /// The scope of the store that asks.
        scope: ScopeId,
        /// The loaded document.
        id: Atom,
        /// The file asked about.
        path: []const u8,
        /// The file the loaded document was read from.
        holder: []const u8,
        /// Where the `SameFileMsg` is sent.
        reply: sequencer.ReplyTo = .{},
    },

    /// The row of the plugin `plugin` is gone: destroys every table loaded from a document of
    /// its scope and forgets their catalog rows, so a plugin loaded next under the name reads
    /// its own files. A document is the plugin's when its id begins `<plugin>_` and no plugin
    /// still loaded with a name at least as long holds it (`plugins.scopeOwner`): releasing
    /// `game` leaves `game_engine_x` to a loaded `game_engine`. A table with unsaved edits is
    /// kept and logged, never dropped. Every resource loaded from the plugin's directory
    /// (`load_resource` naming it) is unloaded. Figures and sketches need nothing here: the
    /// host asks the Figure system to let go of the plugin's loads
    /// (`figure.RuntimeOperation.release_plugin_loads`), and their claims close with their last
    /// holder (`ScopeStores.holds_document`). Nothing replies.
    release_plugin: struct { plugin: Atom },
};

/// The resources system's requests, a row each, applied once the frame's run is flushed.
pub const commands_table_name = "commands.resources";
/// `commands.resources` as rows of `CmdPayload`.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks resources for `wanted`, copying what it points at. A journaled system that asks declares
/// the table written, so a fault takes its request back. A request that cannot be stored is dropped
/// and logged; before the runtime has made the table it is dropped silently.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(wanted);
}
test "a font is named by its plugin, file, height and glyphs, so describing it again finds the same row" {
    const sans = comptime Font.init(.{ .plugin = "editor", .path = "fonts/a.ttf", .pixel_height = 24 });
    try std.testing.expectEqual(sans.name, comptime Font.init(.{ .plugin = "editor", .path = "fonts/a.ttf", .pixel_height = 24 }).name);
    try std.testing.expectEqualStrings("editor/fonts/a.ttf@24", sans.label);
    try std.testing.expect(sans.name != comptime Font.init(.{ .plugin = "demo", .path = "fonts/a.ttf", .pixel_height = 24 }).name);
    try std.testing.expect(sans.name != comptime Font.init(.{ .plugin = "editor", .path = "fonts/a.ttf", .pixel_height = 17 }).name);
    const listed = comptime Font.init(.{ .plugin = "editor", .path = "fonts/a.ttf", .pixel_height = 24, .glyph_codepoints = &.{ 0x41, 0x42 } });
    const other_list = comptime Font.init(.{ .plugin = "editor", .path = "fonts/a.ttf", .pixel_height = 24, .glyph_codepoints = &.{ 0x41, 0x43 } });
    try std.testing.expect(listed.name != sans.name and listed.name != other_list.name);
    try std.testing.expect(sans.askable() and !Font.engine.askable());
}

test "resource declarations validate names, paths, and font parameters" {
    const name = Atom.from("resource.test");
    try validateResourceDecl(.{ .name = name, .kind = .texture, .path = "assets/test.png" });
    try validateResourceDecl(.{ .name = name, .kind = .font, .path = "assets/test.ttf", .pixel_height = 16, .glyph_first_char = 0xF060 });
    try std.testing.expectError(error.NullName, validateResourceDecl(.{ .name = @enumFromInt(0), .kind = .texture, .path = "x.png" }));
    try std.testing.expectError(error.EmptyPath, validateResourceDecl(.{ .name = name, .kind = .texture, .path = "" }));
    try std.testing.expectError(error.PathContainsNul, validateResourceDecl(.{ .name = name, .kind = .texture, .path = "a\x00b" }));
    try std.testing.expectError(error.InvalidPixelHeight, validateResourceDecl(.{ .name = name, .kind = .font, .path = "x.ttf" }));
    try std.testing.expectError(error.InvalidCodepointRange, validateResourceDecl(.{ .name = name, .kind = .font, .path = "x.ttf", .pixel_height = 16, .glyph_first_char = 0xd7d0 }));
}
