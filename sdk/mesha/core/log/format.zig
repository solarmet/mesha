//! The layout of a log file (`.meshalog`), which the log's writer thread writes and
//! `decoder.FileRecords` reads.
//!
//! A file is a `FileHeader`, then records until the end. Each record is a `RecordHeader` and
//! `length` bytes of payload: either a log record, a MessagePack array that begins with the
//! byte 0x96 (`record.zig`), or a 32-byte zone record that begins with `zones.record_kind`
//! (`zones.RingRecord`). The headers' integers are in the byte order of the machine that
//! wrote the file; the reader takes them as little-endian. Nothing is aligned or padded
//! between records, and a reader finds a record by its magic, so damage costs only the
//! records it covers.
const std = @import("std");

/// The first four bytes of a log file.
pub const file_magic: [4]u8 = "MSHF".*;
/// The first four bytes of each record's header.
pub const record_magic: [4]u8 = "MSHL".*;
/// The format's version, as `FileHeader.version` carries it.
pub const file_version: u8 = 1;

/// Not part of the file: the length a thread's ring (`buffer.SpscRingBuffer`) writes where a
/// record did not fit before the ring's end, telling its reader to go on from the start.
pub const skip_marker: u16 = 0xFFFF;

/// What precedes each record's payload in the file: 12 bytes.
pub const RecordHeader = extern struct {
    /// `record_magic`.
    magic: [4]u8 = record_magic,
    /// The payload's length in bytes.
    length: u32,
    /// The CRC-32 of the payload (`crc32`), which a reader checks.
    crc32: u32,
};

/// The first 8 bytes of a log file.
pub const FileHeader = extern struct {
    /// `file_magic`.
    magic: [4]u8 = file_magic,
    /// `file_version`.
    version: u8 = file_version,
    /// Zero.
    reserved: [3]u8 = .{ 0, 0, 0 },
};

/// The checksum a record's header carries for its payload: CRC-32 (`std.hash.Crc32`).
pub fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}
