//! The frame journal: what a sequencer's run writes, held apart from the tables until the run
//! is known to have succeeded.
//!
//! A run gets a `Layer` over its parent's layer, the root's being over the tables. A write
//! never reaches a table: the first write to a row copies it into the layer's overlay table for
//! that table (the same schema), and the writer gets a view of the copy. An insert reserves a
//! free row id in the table, not yet live, and keeps the row's values in the overlay. A remove
//! marks the row removed. Reads look a row up in the layers, nearest first, before the table,
//! so a run sees its own writes and its parent's.
//!
//! A run that succeeds merges its layer into its parent's; one that fails discards it, and
//! the row ids its inserts reserved go back to the tables. At the end of the frame the root
//! layer is flushed into the tables. A table no layer touched is read directly.
//!
//! A layer lasts one run, its bookkeeping in the frame's allocator. Its overlay tables are
//! tables like any other, named for the layer and the table they overlay, and the next run
//! of the same name finds and reuses them.
//!
//! Reads hand out views of `*const` fields (`Const`); a writable view comes only from
//! `write`, which is what puts the row in the overlay.
//!
//! Code that reaches tables through `Table` itself is journaled too: a layer `attach`es to
//! the tables a run may use, and the tables send their row reads and writes to it
//! (`Table.Journal`). A table attached for `.write` copies a row into the overlay whenever
//! code asks for a mutable row (`getRow`, `getField`), since a pointer may be written; one
//! attached for `.read` hands out the row where it is.
//!
//! The sequencer is the caller (`sequencer.run`). For each run it makes a `Layer` with
//! `Layer.init`; for each journaled system it `attach`es the system's inbox and the tables the
//! system declared, calls `attachTouched`, runs the kernels, checks `failure`, asks `differs`
//! of each written table, and `detach`es. A run that ends well calls `merge` (the root's
//! `flush`), a faulted one `discard`, and both then `deinit`. Kernels do not hold a `Layer`:
//! they use `Table` calls, which the attachment sends here.
const std = @import("std");
const Atom = @import("atom.zig").Atom;
const Table = @import("table.zig");

const RowHandle = Table.RowHandle;
const Mask = Table.Mask;
const TableJournal = Table.Journal;

/// What a layer's calls fail with. `OutOfMemory`: the layer's bookkeeping, an overlay table or a
/// payload could not be allocated. `StaleTable`: the handle names no table. `StaleRow`: the row
/// is not live as the layer sees it, removed by a layer or never there under that generation.
/// `SingletonInsert`: an insert into a singleton table. `ReadOnlyTable`: an insert, remove or
/// clear through a table attached for `.read`.
pub const Error = error{ OutOfMemory, StaleTable, StaleRow, SingletonInsert, ReadOnlyTable };

/// `View`, a struct of pointers to a row's fields, with every pointer read-only.
pub const Const = Table.ReadView;

fn constView(comptime View: type, view: View) Const(View) {
    return Table.readViewOf(View, view);
}

/// The fields a view needs present in a row's mask.
fn requiredMask(comptime View: type, table: *const Table) Mask {
    var mask: Mask = .empty;
    inline for (std.meta.fields(View)) |field| {
        const index = table.getSchema().fieldIndex(field.name) orelse unreachable;
        mask.set(table.getSchema().fields[index].bit);
    }
    return mask;
}

fn covers(mask: Mask, required: Mask) bool {
    for (mask.words, required.words) |have, want| {
        if (have & want != want) return false;
    }
    return true;
}

const Op = enum(u8) { write, insert, remove };

/// What a layer does to one row of a table. `overlay` is the overlay table's row holding the
/// row's values; a remove has none.
const Entry = struct { op: Op, generation: u32, overlay: u32 };

const no_overlay = std.math.maxInt(u32);

/// A layer's overlay of one table: its entries by row id, in the order they were made, and
/// the overlay table holding their values.
const Overlay = struct {
    target: Table.Handle,
    values: Table.Handle,
    entries: std.AutoArrayHashMapUnmanaged(u32, Entry) = .empty,
};

/// Where a row's current values are: in the table, in an overlay, or nowhere.
const Source = union(enum) {
    base: RowHandle,
    overlay: struct { table: *Table, row: u32, generation: u32 },
    gone,

    /// The row as the table itself has it, for a layer with no parent.
    fn baseOnly(source: Source, handle: RowHandle) Source {
        return switch (source) {
            .gone => .gone,
            else => .{ .base = handle },
        };
    }
};

/// How a run may use a table it attaches to. `read`: rows are handed out where they are, and an
/// insert, remove or clear through the table is refused (`error.ReadOnlyTable`). `write`: a
/// mutable row access copies the row into the layer, and inserts, removes and clears are the
/// layer's entries.
pub const Mode = enum { read, write };

/// A table the layer is attached to, and the journal it had before.
const Attachment = struct { handle: Table.Handle, previous: ?*const TableJournal, mode: Mode };

/// Sets a table's journal aside while a layer reaches the table's own storage.
const SetAside = struct {
    table: *Table,
    journal: ?*const TableJournal,

    fn of(table: *Table) SetAside {
        const set_aside: SetAside = .{ .table = table, .journal = table.journal };
        table.journal = null;
        return set_aside;
    }

    fn restore(set_aside: SetAside) void {
        set_aside.table.journal = set_aside.journal;
    }
};

/// One run's writes, inserts and removes, held over its parent's layer or, for the root, over
/// the tables. `attach` keeps a pointer to the layer in each attached table, so the layer must
/// not move between `attach` and `detach`.
pub const Layer = struct {
    /// Holds the layer's bookkeeping for its run: the frame's scratch, which code of either
    /// image calls directly.
    arena: *memory_mod.Arena,
    /// The registry of the tables the layer overlays, where its overlay tables are made too.
    tables: *Table.Registry,
    /// The layer of the run this one is a step of, which reads fall through to and `merge` hands
    /// the entries to; null for the root, which is over the tables themselves.
    parent: ?*Layer,
    /// Names this layer's overlay tables apart from other layers'.
    name: Atom,
    /// This layer's overlay of each table it has entries for, by the table handle's index.
    overlays: std.AutoArrayHashMapUnmanaged(u32, Overlay) = .empty,
    /// What attached tables send their row accesses to; points at this layer once attached.
    binding: TableJournal = undefined,
    /// The tables attached since the last `detach`, by handle index, in the order attached.
    attachments: std.AutoArrayHashMapUnmanaged(u32, Attachment) = .empty,
    /// The first error an attached table's access could not return to its caller. The run
    /// that owns the layer faults on it.
    failure: ?Error = null,

    /// A layer with no entries and nothing attached; allocates nothing. `arena` must outlive the
    /// layer, and `parent`, when given, must stay where it is until this layer is merged or
    /// discarded. `name` is the run's, an atom: two layers alive at once must not share one, since
    /// it names their overlay tables.
    pub fn init(arena: *memory_mod.Arena, tables: *Table.Registry, parent: ?*Layer, name: Atom) Layer {
        return .{ .arena = arena, .tables = tables, .parent = parent, .name = name };
    }

    /// For use there and then, in the calling image.
    fn allocator(layer: *const Layer) std.mem.Allocator {
        return layer.arena.allocator();
    }

    /// Releases the layer's bookkeeping; its overlay tables stay, empty, for the next run of
    /// its name. Its entries must have been merged, discarded or flushed.
    pub fn deinit(layer: *Layer) void {
        std.debug.assert(layer.attachments.count() == 0);
        layer.attachments.deinit(layer.allocator());
        for (layer.overlays.values()) |*overlay| {
            std.debug.assert(overlay.entries.count() == 0);
            overlay.entries.deinit(layer.allocator());
        }
        layer.overlays.deinit(layer.allocator());
    }

    /// Whether this layer's entries for `table` change it from what the layers below it, or
    /// the table, hold: a row inserted or removed, or a written row whose values differ.
    pub fn differs(layer: *const Layer, table: Table.Handle) bool {
        const overlay = layer.overlayOf(table) orelse return false;
        const target = layer.tables.get(table) orelse return false;
        const set_aside = SetAside.of(target);
        defer set_aside.restore();
        const values = layer.tables.get(overlay.values) orelse return false;
        for (overlay.entries.keys(), overlay.entries.values()) |row, entry| {
            if (entry.op != .write) return true;
            const handle: RowHandle = .{ .row = row, .generation = entry.generation };
            const below = if (layer.parent) |parent| parent.resolve(table, handle) else layer.resolve(table, handle).baseOnly(handle);
            switch (below) {
                .gone => return true,
                .base => if (!sameRow(values, entry.overlay, target, row)) return true,
                .overlay => |found| if (!sameRow(values, entry.overlay, found.table, found.row)) return true,
            }
        }
        return false;
    }

    /// Sends the table's row reads and writes through this layer until `detach`. Attaching
    /// again for `.write` widens a `.read` attachment. The journal the table had, a parent
    /// layer's for one, is kept and given back by `detach`. Fails with `error.StaleTable` when
    /// the handle names no table, and `error.OutOfMemory`.
    pub fn attach(layer: *Layer, handle: Table.Handle, mode: Mode) Error!void {
        const table = layer.tables.get(handle) orelse return error.StaleTable;
        layer.binding = .{ .context = layer, .vtable = &binding_vtable };
        if (layer.attachments.getPtr(handle.index)) |attached| {
            if (mode == .write) attached.mode = .write;
            return;
        }
        try layer.attachments.put(layer.allocator(), handle.index, .{ .handle = handle, .previous = table.journal, .mode = mode });
        table.journal = &layer.binding;
    }

    /// Attaches for reading every table this layer or a parent's has entries for and that is
    /// not attached yet, so code reading a table it did not declare still sees what the run
    /// wrote to it.
    pub fn attachTouched(layer: *Layer) Error!void {
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            for (found.overlays.values()) |overlay| {
                if (overlay.entries.count() == 0) continue;
                if (layer.attachments.contains(overlay.target.index)) continue;
                if (!layer.tables.valid(overlay.target)) continue;
                try layer.attach(overlay.target, .read);
            }
        }
    }

    /// Gives the attached tables back the journals they had before, in reverse order, and
    /// forgets the attachments. The layer's entries stay, to be merged, flushed or discarded.
    pub fn detach(layer: *Layer) void {
        var index = layer.attachments.count();
        while (index > 0) {
            index -= 1;
            const attached = layer.attachments.values()[index];
            const table = layer.tables.get(attached.handle) orelse continue;
            table.journal = attached.previous;
        }
        layer.attachments.clearRetainingCapacity();
    }

    /// Whether this layer, or a parent's, has written, inserted or removed a row of `table`.
    pub fn touches(layer: *const Layer, table: Table.Handle) bool {
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            if (found.overlayOf(table)) |overlay| if (overlay.entries.count() != 0) return true;
        }
        return false;
    }

    /// The row's current values, read-only, or null for a row removed or never there. The
    /// view points into the table or an overlay table and copies nothing. Use it there and
    /// then: it does not follow the row into the copy a later first write makes, and an
    /// overlay table is emptied when its layer is merged, discarded or flushed.
    pub fn get(layer: *const Layer, table: Table.Handle, row: RowHandle, comptime View: type) ?Const(View) {
        const target = layer.tables.get(table) orelse return null;
        const set_aside = SetAside.of(target);
        defer set_aside.restore();
        const found = layer.viewOf(table, row, View) orelse return null;
        return constView(View, found);
    }

    /// A writable view of the row, copying it into this layer's overlay on its first write.
    /// What is written through the view is the run's and its children's until the flush. The
    /// view points into the overlay table: use it there and then, since a later insert or first
    /// write may grow that table, and merging, discarding or flushing the layer empties it.
    /// Fails with `error.StaleTable`, with `error.StaleRow` for a row not live as the run sees
    /// it, and with `error.OutOfMemory`.
    pub fn write(layer: *Layer, table: Table.Handle, row: RowHandle, comptime View: type) Error!View {
        const target = layer.tables.get(table) orelse return error.StaleTable;
        const set_aside = SetAside.of(target);
        defer set_aside.restore();
        const place = try layer.writePlace(table, row);
        return place.table.storedRow(place.row, View, target);
    }

    /// A new row of `values`, live for this run and its children, in the table once flushed.
    /// `values` is a struct of field values by field name; the row's mask holds those fields.
    /// A slice value is copied into the table's payload arena, where it stays even if the
    /// layer is discarded. The handle returned is the one the row keeps after the flush. Fails
    /// with `error.StaleTable`, `error.SingletonInsert` for a singleton table, and
    /// `error.OutOfMemory`.
    pub fn insert(layer: *Layer, table: Table.Handle, values: anytype) Error!RowHandle {
        const target = layer.tables.get(table) orelse return error.StaleTable;
        const set_aside = SetAside.of(target);
        defer set_aside.restore();
        const row = try layer.insertEmpty(table);
        const overlay = layer.overlayOf(table).?;
        const overlay_table = layer.tables.get(overlay.values).?;
        const copy = overlay.entries.get(row.row).?.overlay;
        const copy_handle: RowHandle = .{ .row = copy, .generation = overlay_table.rowGeneration(copy) };
        inline for (std.meta.fields(@TypeOf(values))) |field| {
            const index = overlay_table.getSchema().fieldIndex(field.name) orelse unreachable;
            if (comptime Table.isPayloadSlice(field.type)) {
                // The overlay's cells name the target's arena.
                const descriptor = &target.getSchema().fields[index];
                const slice_bytes = std.mem.sliceAsBytes(@field(values, field.name));
                const payload = target.appendPayload(slice_bytes, descriptor.payloadAlignment()) catch return error.OutOfMemory;
                overlay_table.getFieldByIndex(Table.Payload, copy_handle, @intCast(index)).?.* = payload;
            } else {
                const cell = overlay_table.getFieldByIndex(field.type, copy_handle, @intCast(index)).?;
                cell.* = @field(values, field.name);
            }
        }
        overlay_table.setRowMask(copy_handle, values);
        return row;
    }

    /// Removes the row for this run and its children, and from the table once flushed.
    /// Removing a row this layer inserted gives its reserved id back at once. Fails with
    /// `error.StaleTable`, with `error.StaleRow` for a row already removed or never there, and
    /// with `error.OutOfMemory`.
    pub fn remove(layer: *Layer, table: Table.Handle, row: RowHandle) Error!void {
        const target = layer.tables.get(table) orelse return error.StaleTable;
        const set_aside = SetAside.of(target);
        defer set_aside.restore();
        return layer.removeRow(table, row);
    }

    fn removeRow(layer: *Layer, table: Table.Handle, row: RowHandle) Error!void {
        const overlay = try layer.overlayFor(table);
        if (overlay.entries.getPtr(row.row)) |entry| {
            if (entry.op == .remove or entry.generation != row.generation) return error.StaleRow;
            layer.freeOverlayRow(overlay, entry.overlay);
            if (entry.op == .insert) {
                // Inserted by this run: the reserved id simply goes back.
                layer.release(table, row.row);
                _ = overlay.entries.orderedRemove(row.row);
            } else entry.* = .{ .op = .remove, .generation = row.generation, .overlay = no_overlay };
            return;
        }
        if (layer.resolve(table, row) == .gone) return error.StaleRow;
        try overlay.entries.put(layer.allocator(), row.row, .{ .op = .remove, .generation = row.generation, .overlay = no_overlay });
    }

    /// The table's rows as this run sees them: the table's, with the layers' writes and
    /// removes, then the layers' inserts. Only rows holding every field of `View`. The query
    /// borrows the layer: do not write, insert or remove through the layer while walking it.
    pub fn query(layer: *const Layer, table: Table.Handle, comptime View: type) Query(View) {
        return Query(View).init(layer, table);
    }

    /// How many rows the table has as this run sees it; 0 when the handle names no table.
    /// Walks every row when a layer has entries for the table.
    pub fn count(layer: *const Layer, table: Table.Handle) u32 {
        const base = layer.tables.get(table) orelse return 0;
        const set_aside = SetAside.of(base);
        defer set_aside.restore();
        if (!layer.touches(table)) return base.count();
        var rows = layer.query(table, struct {});
        var total: u32 = 0;
        while (rows.next()) |_| total += 1;
        return total;
    }

    /// Hands this run's entries to its parent's layer, as if the parent had made them, and
    /// leaves this layer empty. A layer with no parent flushes instead. Call after `detach`.
    /// On `error.OutOfMemory` the parent keeps the entries it was already handed and this
    /// layer the rest, which the caller discards.
    pub fn merge(layer: *Layer) Error!void {
        const parent = layer.parent orelse return layer.flush();
        for (layer.overlays.values()) |*overlay| {
            const values = layer.tables.get(overlay.values) orelse continue;
            var entries = overlay.entries.iterator();
            while (entries.next()) |item| {
                const row = item.key_ptr.*;
                const entry = item.value_ptr.*;
                try parent.adopt(overlay.target, row, entry, values);
            }
            layer.clearOverlay(overlay);
        }
    }

    /// Drops this run's entries; the row ids its inserts reserved go back to their tables,
    /// their generations spent. The tables and the parent's layer are as if the run had not
    /// been, but for payload bytes it appended.
    pub fn discard(layer: *Layer) void {
        for (layer.overlays.values()) |*overlay| {
            for (overlay.entries.keys(), overlay.entries.values()) |row, entry| {
                if (entry.op == .insert) layer.release(overlay.target, row);
            }
            layer.clearOverlay(overlay);
        }
    }

    /// Writes the root layer's entries into the tables: written rows that differ are copied
    /// over, inserted rows become live under their reserved ids, removed rows are freed. A
    /// table something changed in has its revision advanced; entries for a table destroyed
    /// during the frame are dropped. The layer must have no parent and nothing attached. No
    /// step of it returns an error.
    pub fn flush(layer: *Layer) Error!void {
        std.debug.assert(layer.parent == null);
        std.debug.assert(layer.attachments.count() == 0);
        for (layer.overlays.values()) |*overlay| {
            const target = layer.tables.get(overlay.target) orelse {
                // The table went during the frame; what was written to it goes with it, and
                // so does its overlay table.
                layer.clearOverlay(overlay);
                if (layer.tables.valid(overlay.values)) layer.tables.destroy(overlay.values);
                continue;
            };
            const values = layer.tables.get(overlay.values).?;
            var changed = false;
            for (overlay.entries.keys(), overlay.entries.values()) |row, entry| {
                const handle: RowHandle = .{ .row = row, .generation = entry.generation };
                switch (entry.op) {
                    .write => {
                        if (!target.valid(handle)) continue;
                        // A row fetched mutably but left as it was is no change.
                        if (sameRow(values, entry.overlay, target, row)) continue;
                        copyRow(values, entry.overlay, target, row);
                    },
                    .insert => {
                        target.restoreRowState(row, entry.generation, .empty, true);
                        copyRow(values, entry.overlay, target, row);
                    },
                    .remove => target.free(handle),
                }
                changed = true;
            }
            // Revisions tell observers a table changed; a frame that wrote nothing new leaves it.
            if (changed) target.touch();
            layer.clearOverlay(overlay);
        }
    }

    // ---- inside a layer: the attached tables' journals are set aside ---------------------

    /// This layer's copy of the row, made on its first write.
    fn writePlace(layer: *Layer, table: Table.Handle, row: RowHandle) Error!TableJournal.Place {
        const overlay = try layer.overlayFor(table);
        const values = layer.tables.get(overlay.values) orelse return error.StaleTable;
        if (overlay.entries.get(row.row)) |entry| {
            if (entry.op == .remove or entry.generation != row.generation) return error.StaleRow;
            return .{ .table = values, .row = entry.overlay };
        }
        const source = layer.resolve(table, row);
        const copy = switch (source) {
            .gone => return error.StaleRow,
            else => try layer.copyInto(overlay, source),
        };
        try overlay.entries.put(layer.allocator(), row.row, .{ .op = .write, .generation = row.generation, .overlay = copy });
        return .{ .table = values, .row = copy };
    }

    /// Reserves the row id an allocation would take, held back from the table until the
    /// flush, with an empty overlay row for its values.
    fn insertEmpty(layer: *Layer, table: Table.Handle) Error!RowHandle {
        const target = layer.tables.get(table) orelse return error.StaleTable;
        if (target.isSingleton()) return error.SingletonInsert;
        if (target.reusableRows().len == 0) target.reserveCapacity(target.rowCapacity() + 1) catch return error.OutOfMemory;
        const overlay = try layer.overlayFor(table);
        const copy = try overlayRow(layer.tables, overlay.values);
        try overlay.entries.ensureUnusedCapacity(layer.allocator(), 1);
        const free = target.reusableRows();
        const row = free.at(free.len - 1);
        target.removeReusableAt(free.len - 1);
        const generation = target.storedGeneration(row) +% 1;
        overlay.entries.putAssumeCapacity(row, .{ .op = .insert, .generation = generation, .overlay = copy });
        return .{ .row = row, .generation = generation };
    }

    /// The row id's generation as this run sees it; null when not live.
    fn generationOf(layer: *const Layer, table: Table.Handle, row: u32) ?u32 {
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            const overlay = found.overlayOf(table) orelse continue;
            const entry = overlay.entries.get(row) orelse continue;
            return if (entry.op == .remove) null else entry.generation;
        }
        const base = layer.tables.get(table) orelse return null;
        if (!base.isAllocated(row)) return null;
        return base.storedGeneration(row);
    }

    /// Whether the nearest layer with an entry for the row id removed it.
    fn removedRow(layer: *const Layer, table: Table.Handle, row: u32) bool {
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            const overlay = found.overlayOf(table) orelse continue;
            const entry = overlay.entries.get(row) orelse continue;
            return entry.op == .remove;
        }
        return false;
    }

    /// The `index`th insert across the layers, nearest layer first, in insertion order.
    fn insertedRow(layer: *const Layer, table: Table.Handle, index: usize) ?RowHandle {
        var remaining = index;
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            const overlay = found.overlayOf(table) orelse continue;
            for (overlay.entries.keys(), overlay.entries.values()) |row, entry| {
                if (entry.op != .insert) continue;
                if (remaining == 0) return .{ .row = row, .generation = entry.generation };
                remaining -= 1;
            }
        }
        return null;
    }

    fn noteFailure(layer: *Layer, failure: Error) void {
        if (layer.failure == null) layer.failure = failure;
    }

    fn attachmentOf(layer: *const Layer, table: *const Table) Attachment {
        return layer.attachments.get(table.handle.index).?;
    }

    fn overlayOf(layer: *const Layer, table: Table.Handle) ?*Overlay {
        const overlay = layer.overlays.getPtr(table.index) orelse return null;
        if (overlay.target.generation != table.generation) return null;
        return overlay;
    }

    /// This layer's overlay of `table`, made on its first write.
    fn overlayFor(layer: *Layer, table: Table.Handle) Error!*Overlay {
        if (layer.overlayOf(table)) |overlay| return overlay;
        const target = layer.tables.get(table) orelse return error.StaleTable;
        if (layer.overlays.getPtr(table.index)) |stale| {
            // The table at this index was replaced during the run; its old overlay goes.
            stale.entries.deinit(layer.allocator());
            if (layer.tables.valid(stale.values)) layer.tables.destroy(stale.values);
            _ = layer.overlays.orderedRemove(table.index);
        }
        var name_buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "journal.{x}.{d}.{d}", .{ @intFromEnum(layer.name), table.index, table.generation }) catch unreachable;
        const values = try layer.overlayTable(target, Atom.from(name));
        try layer.overlays.put(layer.allocator(), table.index, .{ .target = table, .values = values });
        return layer.overlays.getPtr(table.index).?;
    }

    /// The overlay table of this name an earlier run left, emptied, or a new one. One whose
    /// schema no longer matches its table's, after a migration, is replaced.
    fn overlayTable(layer: *Layer, target: *const Table, name: Atom) Error!Table.Handle {
        if (layer.tables.findHandleByName(name)) |existing| {
            const found = layer.tables.get(existing).?;
            if (Table.schemasEqual(found.getSchema(), target.getSchema())) {
                found.clear();
                return existing;
            }
            layer.tables.destroy(existing);
        }
        return layer.tables.create(target.getSchema(), 8, name, .transient) catch error.OutOfMemory;
    }

    /// Where the row's values are, looking through this layer and its parents.
    fn resolve(layer: *const Layer, table: Table.Handle, row: RowHandle) Source {
        var current: ?*const Layer = layer;
        while (current) |found| : (current = found.parent) {
            const overlay = found.overlayOf(table) orelse continue;
            const entry = overlay.entries.get(row.row) orelse continue;
            if (entry.generation != row.generation or entry.op == .remove) return .gone;
            const values = found.tables.get(overlay.values) orelse return .gone;
            return .{ .overlay = .{ .table = values, .row = entry.overlay, .generation = values.rowGeneration(entry.overlay) } };
        }
        const base = layer.tables.get(table) orelse return .gone;
        if (!base.valid(row)) return .gone;
        return .{ .base = row };
    }

    fn viewOf(layer: *const Layer, table: Table.Handle, row: RowHandle, comptime View: type) ?View {
        return switch (layer.resolve(table, row)) {
            .gone => null,
            .base => |handle| (layer.tables.get(table) orelse return null).getRow(handle, View),
            // An overlay row's payload cells name the target's arena.
            .overlay => |found| found.table.storedRow(found.row, View, layer.tables.get(table) orelse return null),
        };
    }

    /// A new overlay row holding a copy of the row at `source`.
    fn copyInto(layer: *Layer, overlay: *Overlay, source: Source) Error!u32 {
        const copy = try overlayRow(layer.tables, overlay.values);
        const values = layer.tables.get(overlay.values).?;
        switch (source) {
            .base => |handle| copyRow(layer.tables.get(overlay.target).?, handle.row, values, copy),
            .overlay => |found| copyRow(found.table, found.row, values, copy),
            .gone => unreachable,
        }
        return copy;
    }

    /// Takes over an entry a child layer made, with its values from `child_values`.
    fn adopt(layer: *Layer, table: Table.Handle, row: u32, entry: Entry, child_values: *Table) Error!void {
        const overlay = try layer.overlayFor(table);
        const values = layer.tables.get(overlay.values).?;
        if (overlay.entries.getPtr(row)) |mine| {
            switch (entry.op) {
                .write => copyRow(child_values, entry.overlay, values, mine.overlay),
                // A child cannot insert a row id its parent holds.
                .insert => unreachable,
                .remove => {
                    layer.freeOverlayRow(overlay, mine.overlay);
                    if (mine.op == .insert) {
                        layer.release(table, row);
                        _ = overlay.entries.orderedRemove(row);
                    } else mine.* = .{ .op = .remove, .generation = entry.generation, .overlay = no_overlay };
                },
            }
            return;
        }
        var adopted = entry;
        if (entry.op != .remove) {
            adopted.overlay = try overlayRow(layer.tables, overlay.values);
            copyRow(child_values, entry.overlay, values, adopted.overlay);
        }
        try overlay.entries.put(layer.allocator(), row, adopted);
    }

    /// Returns a row id an insert reserved to its table.
    fn release(layer: *const Layer, table: Table.Handle, row: u32) void {
        const target = layer.tables.get(table) orelse return;
        // The reserved generation is spent, as a freed row's is, so no handle to the
        // discarded insert names a later row.
        target.restoreRowState(row, target.storedGeneration(row) +% 1, .empty, false);
        target.insertReusableAt(target.reusableRows().len, row);
    }

    fn freeOverlayRow(layer: *const Layer, overlay: *Overlay, row: u32) void {
        if (row == no_overlay) return;
        const values = layer.tables.get(overlay.values) orelse return;
        values.free(.{ .row = row, .generation = values.rowGeneration(row) });
    }

    fn clearOverlay(layer: *const Layer, overlay: *Overlay) void {
        overlay.entries.clearRetainingCapacity();
        if (layer.tables.get(overlay.values)) |values| values.clear();
    }
};

// ---- what attached tables call ----------------------------------------------------------

const binding_vtable: TableJournal.VTable = .{
    .read = bindingRead,
    .access = bindingAccess,
    .generation = bindingGeneration,
    .insert = bindingInsert,
    .remove = bindingRemove,
    .clear = bindingClear,
    .count = bindingCount,
    .removed = bindingRemoved,
    .inserted = bindingInserted,
};

fn layerOf(context: *anyopaque) *Layer {
    return @ptrCast(@alignCast(context));
}

fn bindingRead(context: *anyopaque, table: *Table, handle: RowHandle) ?TableJournal.Place {
    const layer = layerOf(context);
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    return switch (layer.resolve(table.handle, handle)) {
        .gone => null,
        .base => .{ .table = table, .row = handle.row },
        .overlay => |found| .{ .table = found.table, .row = found.row },
    };
}

fn bindingAccess(context: *anyopaque, table: *Table, handle: RowHandle) ?TableJournal.Place {
    const layer = layerOf(context);
    if (layer.attachmentOf(table).mode == .read) return bindingRead(context, table, handle);
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    return layer.writePlace(table.handle, handle) catch |failure| {
        if (failure != error.StaleRow) layer.noteFailure(failure);
        return null;
    };
}

fn bindingGeneration(context: *anyopaque, table: *Table, row: u32) ?u32 {
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    return layerOf(context).generationOf(table.handle, row);
}

fn bindingInsert(context: *anyopaque, table: *Table) anyerror!RowHandle {
    const layer = layerOf(context);
    if (layer.attachmentOf(table).mode == .read) return error.ReadOnlyTable;
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    return layer.insertEmpty(table.handle);
}

fn bindingRemove(context: *anyopaque, table: *Table, handle: RowHandle) void {
    const layer = layerOf(context);
    if (layer.attachmentOf(table).mode == .read) return layer.noteFailure(error.ReadOnlyTable);
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    layer.removeRow(table.handle, handle) catch |failure| {
        // Freeing a row that is not there does nothing, as it does in a table.
        if (failure != error.StaleRow) layer.noteFailure(failure);
    };
}

fn bindingClear(context: *anyopaque, table: *Table) void {
    const layer = layerOf(context);
    if (layer.attachmentOf(table).mode == .read) return layer.noteFailure(error.ReadOnlyTable);
    // Collected first: removing an insert changes the entries a query walks.
    var visible: std.ArrayList(RowHandle) = .empty;
    defer visible.deinit(layer.allocator());
    var rows = layer.query(table.handle, struct {});
    while (rows.next()) |row| visible.append(layer.allocator(), row.handle) catch return layer.noteFailure(error.OutOfMemory);
    const set_aside = SetAside.of(table);
    defer set_aside.restore();
    for (visible.items) |row| layer.removeRow(table.handle, row) catch |failure| layer.noteFailure(failure);
}

fn bindingCount(context: *anyopaque, table: *Table) u32 {
    return layerOf(context).count(table.handle);
}

fn bindingRemoved(context: *anyopaque, table: *Table, row: u32) bool {
    return layerOf(context).removedRow(table.handle, row);
}

fn bindingInserted(context: *anyopaque, table: *Table, index: usize) ?RowHandle {
    return layerOf(context).insertedRow(table.handle, index);
}

/// A row in an overlay table, growing it when full.
fn overlayRow(tables: *Table.Registry, handle: Table.Handle) Error!u32 {
    const values = tables.get(handle) orelse return error.StaleTable;
    if (values.reusableRows().len == 0) tables.grow(handle, values.rowCapacity() * 2) catch return error.OutOfMemory;
    const row = values.alloc() catch return error.OutOfMemory;
    return row.row;
}

/// Copies a row's field bytes and presence between two tables of one schema.
fn copyRow(from: *const Table, from_row: u32, to: *Table, to_row: u32) void {
    const fields = from.getSchema().fields;
    for (fields, to.getSchema().fields) |*from_field, *to_field| {
        if (from_field.size == 0) continue;
        @memcpy(to.rowCellBytes(to_row, to_field), from.rowCellBytes(from_row, from_field));
    }
    to.setMask(to_row, from.rowMask(from_row));
}

/// Whether two rows of one schema hold the same fields with the same bytes.
fn sameRow(a: *const Table, a_row: u32, b: *const Table, b_row: u32) bool {
    const mask = a.rowMask(a_row);
    if (!std.meta.eql(mask, b.rowMask(b_row))) return false;
    for (a.getSchema().fields, b.getSchema().fields) |*a_field, *b_field| {
        if (a_field.size == 0 or !mask.has(a_field.bit)) continue;
        if (!std.mem.eql(u8, a.rowCellBytes(a_row, a_field), b.rowCellBytes(b_row, b_field))) return false;
    }
    return true;
}

/// The rows of a table as a layer sees them; see `Layer.query`. An iterator: call `next` until
/// it gives null. Its fields are its own state.
pub fn Query(comptime View: type) type {
    return struct {
        /// The layer whose view of the table this walks.
        layer: *const Layer,
        /// The table walked.
        handle: Table.Handle,
        /// The table itself; null when `handle` named none, and the query is then empty.
        table: ?*Table,
        /// The fields of `View`, which a row's mask must hold for the row to be given.
        required: Mask = .empty,
        /// Untouched by every layer: the table's own query.
        direct: ?Table.Query(View) = null,
        /// The next of the table's own rows to look at, by position.
        position: u32 = 0,
        /// After the table's rows: the layers' inserts, nearest layer first.
        inserting: bool = false,
        /// The layer whose inserts are being given; null once every layer's are.
        insert_layer: ?*const Layer = null,
        /// The next of `insert_layer`'s entries to look at.
        insert_index: usize = 0,

        const Self = @This();
        /// A row the query gives: its handle, and a read-only view of its values as the run sees
        /// them, which points into the table or an overlay table and holds as `Layer.get`'s does.
        pub const Item = struct { handle: RowHandle, view: Const(View) };

        fn init(layer: *const Layer, handle: Table.Handle) Self {
            const table = layer.tables.get(handle);
            var self: Self = .{ .layer = layer, .handle = handle, .table = table, .insert_layer = layer };
            const found = table orelse return self;
            const set_aside = SetAside.of(found);
            defer set_aside.restore();
            if (!layer.touches(handle)) {
                self.direct = found.query(View);
                return self;
            }
            self.required = requiredMask(View, found);
            return self;
        }

        /// The next row, or null when there are no more: the table's own rows first, then the
        /// layers' inserts, nearest layer first.
        pub fn next(self: *Self) ?Item {
            const table = self.table orelse return null;
            const set_aside = SetAside.of(table);
            defer set_aside.restore();
            if (self.direct) |*direct| {
                const found = direct.next() orelse return null;
                return .{ .handle = found.handle, .view = constView(View, found.view) };
            }
            while (!self.inserting and self.position < table.count()) {
                const row = table.rowAtPosition(self.position);
                self.position += 1;
                const handle: RowHandle = .{ .row = row, .generation = table.rowGeneration(row) };
                if (self.item(handle)) |found| return found;
            }
            self.inserting = true;
            while (self.insert_layer) |layer| {
                const overlay = layer.overlayOf(self.handle) orelse {
                    self.nextLayer();
                    continue;
                };
                while (self.insert_index < overlay.entries.count()) {
                    const row = overlay.entries.keys()[self.insert_index];
                    const entry = overlay.entries.values()[self.insert_index];
                    self.insert_index += 1;
                    if (entry.op != .insert) continue;
                    if (self.item(.{ .row = row, .generation = entry.generation })) |found| return found;
                }
                self.nextLayer();
            }
            return null;
        }

        fn nextLayer(self: *Self) void {
            self.insert_layer = self.insert_layer.?.parent;
            self.insert_index = 0;
        }

        /// The row as the nearest layer has it, if it is there and holds the view's fields.
        fn item(self: *const Self, handle: RowHandle) ?Item {
            const source = self.layer.resolve(self.handle, handle);
            const mask = switch (source) {
                .gone => return null,
                .base => |row| self.table.?.rowMask(row.row),
                .overlay => |found| found.table.rowMask(found.row),
            };
            if (!covers(mask, self.required)) return null;
            const found = self.layer.viewOf(self.handle, handle, View) orelse return null;
            return .{ .handle = handle, .view = constView(View, found) };
        }
    };
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;
const memory_mod = @import("memory.zig");

const test_schema: Table.Schema = .{ .fields = &.{
    .{ .name = "value", .size = 4, .stride = 4, .column_index = 0, .bit = 0, .field_type = .i32 },
    .{ .name = "other", .size = 4, .stride = 4, .column_index = 1, .bit = 1, .field_type = .i32 },
    .{ .name = "name", .size = 8, .stride = 8, .column_index = 2, .bit = 2, .field_type = .string },
} };
const ValueView = struct { value: *i32 };

const Fixture = struct {
    memory: memory_mod.Memory = undefined,
    tables: Table.Registry = undefined,
    handle: Table.Handle = undefined,
    /// The layers' bookkeeping, as a sequencer's run keeps it.
    arena: *memory_mod.Arena = undefined,

    fn init(f: *Fixture) !void {
        f.memory.init(testing.allocator);
        errdefer f.memory.deinit();
        f.arena = try f.memory.frameScratchArena();
        try f.tables.init(&f.memory, 16);
        f.handle = try f.tables.create(&test_schema, 4, Atom.from("journal_test"), .durable);
    }

    fn deinit(f: *Fixture) void {
        f.tables.deinit();
        f.memory.deinit();
    }

    fn table(f: *Fixture) *Table {
        return f.tables.get(f.handle).?;
    }

    fn baseRow(f: *Fixture, value: i32) !RowHandle {
        return f.table().tryInsert(.{ .value = value, .other = @as(i32, 0) });
    }

    fn values(f: *Fixture, layer: *const Layer) ![]i32 {
        var found: std.ArrayList(i32) = .empty;
        var rows = layer.query(f.handle, ValueView);
        while (rows.next()) |row| try found.append(testing.allocator, row.view.value.*);
        std.mem.sort(i32, found.items, {}, std.sort.asc(i32));
        return found.toOwnedSlice(testing.allocator);
    }
};

test "a layer's writes, inserts and removes are its own until flushed" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const kept = try f.baseRow(1);
    const removed = try f.baseRow(2);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();

    (try root.write(f.handle, kept, ValueView)).value.* = 10;
    try root.remove(f.handle, removed);
    const added = try root.insert(f.handle, .{ .value = @as(i32, 3), .other = @as(i32, 0) });

    try testing.expectEqual(@as(i32, 10), root.get(f.handle, kept, ValueView).?.value.*);
    try testing.expect(root.get(f.handle, removed, ValueView) == null);
    try testing.expectEqual(@as(i32, 3), root.get(f.handle, added, ValueView).?.value.*);
    const seen = try f.values(&root);
    defer testing.allocator.free(seen);
    try testing.expectEqualSlices(i32, &.{ 3, 10 }, seen);
    try testing.expectEqual(@as(u32, 2), root.count(f.handle));
    // The table itself is as it was.
    try testing.expectEqual(@as(i32, 1), f.table().getField(i32, kept, "value").?.*);
    try testing.expect(f.table().valid(removed));
    try testing.expect(!f.table().valid(added));

    try root.flush();
    try testing.expectEqual(@as(i32, 10), f.table().getField(i32, kept, "value").?.*);
    try testing.expect(!f.table().valid(removed));
    try testing.expectEqual(@as(i32, 3), f.table().getField(i32, added, "value").?.*);
    try testing.expect(!root.touches(f.handle));
}

test "a discarded layer leaves the table and its free rows as they were" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const kept = try f.baseRow(1);
    const free_before = f.table().reusableRows().len;
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();

    (try root.write(f.handle, kept, ValueView)).value.* = 7;
    const added = try root.insert(f.handle, .{ .value = @as(i32, 5), .other = @as(i32, 0) });
    try root.remove(f.handle, kept);
    root.discard();

    try testing.expectEqual(@as(i32, 1), root.get(f.handle, kept, ValueView).?.value.*);
    try testing.expect(root.get(f.handle, added, ValueView) == null);
    try testing.expectEqual(free_before, f.table().reusableRows().len);
    try testing.expectEqual(@as(u32, 1), f.table().count());
}

test "a child layer sees its parent's writes, merges into it, or is discarded alone" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const row = try f.baseRow(1);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    (try root.write(f.handle, row, ValueView)).value.* = 2;

    var failed = Layer.init(f.arena, &f.tables, &root, Atom.from("failed"));
    defer failed.deinit();
    try testing.expectEqual(@as(i32, 2), failed.get(f.handle, row, ValueView).?.value.*);
    (try failed.write(f.handle, row, ValueView)).value.* = 99;
    _ = try failed.insert(f.handle, .{ .value = @as(i32, 50), .other = @as(i32, 0) });
    failed.discard();
    try testing.expectEqual(@as(i32, 2), root.get(f.handle, row, ValueView).?.value.*);
    try testing.expectEqual(@as(u32, 1), root.count(f.handle));

    var child = Layer.init(f.arena, &f.tables, &root, Atom.from("child"));
    defer child.deinit();
    (try child.write(f.handle, row, ValueView)).value.* = 3;
    const added = try child.insert(f.handle, .{ .value = @as(i32, 4), .other = @as(i32, 0) });
    try testing.expectEqual(@as(i32, 2), root.get(f.handle, row, ValueView).?.value.*);
    try child.merge();
    try testing.expectEqual(@as(i32, 3), root.get(f.handle, row, ValueView).?.value.*);
    try testing.expectEqual(@as(i32, 4), root.get(f.handle, added, ValueView).?.value.*);

    // A later child removes what an earlier one inserted: the row id goes back.
    var remover = Layer.init(f.arena, &f.tables, &root, Atom.from("remover"));
    defer remover.deinit();
    try remover.remove(f.handle, added);
    try remover.merge();
    try testing.expect(root.get(f.handle, added, ValueView) == null);

    try root.flush();
    try testing.expectEqual(@as(i32, 3), f.table().getField(i32, row, "value").?.*);
    try testing.expectEqual(@as(u32, 1), f.table().count());
}

test "queries keep to rows holding the view's fields" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    _ = try root.insert(f.handle, .{ .value = @as(i32, 1) });
    _ = try root.insert(f.handle, .{ .value = @as(i32, 2), .other = @as(i32, 9) });
    var rows = root.query(f.handle, struct { other: *i32 });
    var count: usize = 0;
    while (rows.next()) |row| {
        try testing.expectEqual(@as(i32, 9), row.view.other.*);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
    root.discard();
}

test "an attached table sends its row reads and writes through the layer" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const kept = try f.baseRow(1);
    const removed = try f.baseRow(2);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .write);

    // Code that knows nothing of journals: plain table calls.
    const table = f.table();
    table.getField(i32, kept, "value").?.* = 10;
    table.free(removed);
    const added = try table.tryInsert(.{ .value = @as(i32, 3), .other = @as(i32, 0) });
    try testing.expect(table.valid(added));
    try testing.expect(!table.valid(removed));
    try testing.expectEqual(@as(u32, 2), table.count());
    var total: i32 = 0;
    var rows = table.query(ValueView);
    while (rows.next()) |row| total += row.view.value.*;
    try testing.expectEqual(@as(i32, 13), total);

    root.detach();
    // Detached, the table is as it was until the flush.
    try testing.expectEqual(@as(i32, 1), table.getField(i32, kept, "value").?.*);
    try testing.expect(table.valid(removed));
    try testing.expect(!table.valid(added));
    try root.flush();
    try testing.expectEqual(@as(i32, 10), table.getField(i32, kept, "value").?.*);
    try testing.expect(!table.valid(removed));
    try testing.expectEqual(@as(i32, 3), table.getField(i32, added, "value").?.*);
}

test "a read query of a table attached for writing sees the run's rows and copies none" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const first = try f.baseRow(1);
    _ = try f.baseRow(2);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .write);
    const table = f.table();

    var total: i32 = 0;
    var read_rows = table.readQuery(ValueView);
    while (read_rows.next()) |row| total += row.view.value.*;
    try testing.expectEqual(@as(i32, 3), total);
    try testing.expectEqual(@as(i32, 1), table.readRow(first, ValueView).?.value.*);
    try testing.expect(!root.touches(f.handle));

    // A write is seen by the read query that follows; a plain query copies what it visits.
    table.getField(i32, first, "value").?.* = 10;
    total = 0;
    read_rows = table.readQuery(ValueView);
    while (read_rows.next()) |row| total += row.view.value.*;
    try testing.expectEqual(@as(i32, 12), total);
    root.detach();
    try root.flush();
}

test "a child attached over its parent is discarded alone, and clear is journaled" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const row = try f.baseRow(1);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .write);
    f.table().getField(i32, row, "value").?.* = 2;

    var child = Layer.init(f.arena, &f.tables, &root, Atom.from("child"));
    defer child.deinit();
    try child.attach(f.handle, .write);
    f.table().clear();
    _ = try f.table().tryInsert(.{ .value = @as(i32, 9) });
    try testing.expectEqual(@as(u32, 1), f.table().count());
    child.detach();
    child.discard();

    try testing.expectEqual(@as(u32, 1), f.table().count());
    try testing.expectEqual(@as(i32, 2), f.table().getField(i32, row, "value").?.*);
    root.detach();
    root.discard();
    try testing.expectEqual(@as(i32, 1), f.table().getField(i32, row, "value").?.*);
}

test "a table attached for reading hands out rows in place and refuses inserts" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const row = try f.baseRow(1);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .read);
    try testing.expectEqual(@as(i32, 1), f.table().getField(i32, row, "value").?.*);
    try testing.expect(!root.touches(f.handle));
    try testing.expectError(error.ReadOnlyTable, f.table().tryInsert(.{ .value = @as(i32, 2) }));
    root.detach();
}

test "a later run of the same name reuses the overlay tables, and differs sees real changes" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const row = try f.baseRow(1);
    for (0..2) |_| {
        var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
        defer root.deinit();
        try root.attach(f.handle, .write);
        const value = f.table().getField(i32, row, "value").?;
        try testing.expect(!root.differs(f.handle));
        value.* += 1;
        try testing.expect(root.differs(f.handle));
        root.detach();
        try root.flush();
    }
    try testing.expectEqual(@as(i32, 3), f.table().getField(i32, row, "value").?.*);
    var name_buffer: [64]u8 = undefined;
    const overlay_name = try std.fmt.bufPrint(&name_buffer, "journal.{x}.{d}.{d}", .{ Atom.from("root").value(), f.handle.index, f.handle.generation });
    try testing.expect(f.tables.findHandleByName(Atom.from(overlay_name)) != null);
}

test "iterating an attached table after a remove visits the table's other rows" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const first = try f.baseRow(1);
    _ = try f.baseRow(2);
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .write);
    f.table().free(first);
    var seen: u32 = 0;
    var rows = f.table().query(ValueView);
    while (rows.next()) |row| {
        try testing.expectEqual(@as(i32, 2), row.view.value.*);
        seen += 1;
    }
    try testing.expectEqual(@as(u32, 1), seen);
    root.detach();
    root.discard();
}

test "a table touched earlier in the run reads through the layer though not declared" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    try root.attach(f.handle, .write);
    _ = try f.table().tryInsert(.{ .value = @as(i32, 5) });
    root.detach();
    // A later system that did not declare the table.
    try root.attachTouched();
    try testing.expectEqual(@as(u32, 1), f.table().count());
    root.detach();
    root.discard();
}

const NameView = struct { name: []const u8 };

test "a layer's string writes name the table's arena and go with a discarded layer" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const table = f.table();
    const kept = try table.tryInsert(.{ .value = @as(i32, 1), .name = @as([]const u8, "before") });
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();

    try root.attach(f.handle, .write);
    try table.setString(kept, "name", "written in the run");
    const added = try table.tryInsert(.{ .value = @as(i32, 2), .name = @as([]const u8, "inserted") });
    // The run reads its own text, through the table it knows.
    try testing.expectEqualStrings("written in the run", table.readRow(kept, NameView).?.name);
    try testing.expectEqualStrings("inserted", table.getRow(added, NameView).?.name);
    var seen: u32 = 0;
    var rows = table.readQuery(NameView);
    while (rows.next()) |row| seen += @intCast(row.view.name.len);
    try testing.expectEqual(@as(u32, "written in the run".len + "inserted".len), seen);
    root.detach();

    // Outside the run the table is as it was.
    try testing.expectEqualStrings("before", table.readRow(kept, NameView).?.name);
    try testing.expectEqualStrings("written in the run", root.get(f.handle, kept, NameView).?.name);
    root.discard();
    try testing.expectEqualStrings("before", table.readRow(kept, NameView).?.name);
    try testing.expect(!table.valid(added));
}

test "a flushed layer's strings are the table's, and a child's merge through its parent" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const table = f.table();
    const kept = try table.tryInsert(.{ .value = @as(i32, 1), .name = @as([]const u8, "before") });
    var root = Layer.init(f.arena, &f.tables, null, Atom.from("root"));
    defer root.deinit();
    var child = Layer.init(f.arena, &f.tables, &root, Atom.from("child"));
    defer child.deinit();

    try child.attach(f.handle, .write);
    try table.setString(kept, "name", "from the child");
    const added = try child.insert(f.handle, .{ .value = @as(i32, 2), .name = @as([]const u8, "inserted by the child") });
    child.detach();
    try child.merge();
    try testing.expectEqualStrings("from the child", root.get(f.handle, kept, NameView).?.name);
    try root.flush();

    try testing.expectEqualStrings("from the child", table.readRow(kept, NameView).?.name);
    try testing.expectEqualStrings("inserted by the child", table.readRow(added, NameView).?.name);
}
