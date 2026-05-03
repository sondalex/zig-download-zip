const std = @import("std");
const download_zip = @import("download_zip");
const temp = @import("temp");

const testing = std.testing;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const fs = std.fs;

const LOCAL_FILE_HEADER_SIGNATURE: u32 = 0x04034B50;
const CENTRAL_DIRECTORY_SIGNATURE: u32 = 0x02014B50;
const EOCD_SIGNATURE: u32 = 0x06054B50;

const TestDir = struct {
    allocator: std.mem.Allocator,
    dir: testing.TmpDir,
    io: Io,

    pub fn init(allocator: std.mem.Allocator) !TestDir {
        const io = testing.io;
        const temp_dir = testing.tmpDir(.{});
        return TestDir{
            .allocator = allocator,
            .dir = temp_dir,
            .io = io,
        };
    }

    pub fn deinit(self: *TestDir) void {
        self.dir.cleanup();
    }

    pub fn createFile(self: *TestDir, name: []const u8, content: []const u8) !File {
        const file = try self.dir.dir.createFile(
            self.io,
            name,
            .{},
        );
        var file_buffer: [4096]u8 = undefined;
        var w = file.writer(self.io, &file_buffer);

        try w.interface.writeAll(content);
        try w.interface.flush();
        return file;
    }

    pub fn join(self: TestDir, path: []const u8, buf: *[Dir.max_path_bytes]u8) ![]const u8 {
        const len = try self.dir.dir.realPath(self.io, buf);
        buf[len] = '/';
        @memcpy(buf[len + 1 ..][0..path.len], path);
        return buf[0 .. len + 1 + path.len];
    }
};

/// Create a minimal ZIP archive in memory containing one file.
/// Compression method = 0 (stored, no compression)
// See: https://en.wikipedia.org/wiki/ZIP_(file_format)
pub fn createTestZip(
    allocator: std.mem.Allocator,
    filename: []const u8,
    content: []const u8,
) ![]u8 {
    const local_header_size: usize = 30 + filename.len + content.len;
    const central_directory_offset: u32 = @intCast(local_header_size);
    const central_directory_size: u32 = @intCast(46 + filename.len);
    const zip_size: usize = local_header_size + (46 + filename.len) + 22;

    var list = try std.ArrayList(u8).initCapacity(allocator, zip_size);
    errdefer list.deinit(allocator);

    var aw = std.Io.Writer.Allocating.fromArrayList(allocator, &list);
    const w = &aw.writer;

    const crc = std.hash.Crc32.hash(content);

    const local_header_offset: u32 = 0;

    try w.writeInt(u32, LOCAL_FILE_HEADER_SIGNATURE, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, @intCast(content.len), .little);
    try w.writeInt(u32, @intCast(content.len), .little);
    try w.writeInt(u16, @intCast(filename.len), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeAll(filename);
    try w.writeAll(content);

    // Central Directory Header
    try w.writeInt(u32, CENTRAL_DIRECTORY_SIGNATURE, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 20, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, crc, .little);
    try w.writeInt(u32, @intCast(content.len), .little);
    try w.writeInt(u32, @intCast(content.len), .little);
    try w.writeInt(u16, @intCast(filename.len), .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, local_header_offset, .little);
    try w.writeAll(filename);

    // End of Central Directory
    try w.writeInt(u32, EOCD_SIGNATURE, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u32, central_directory_size, .little);
    try w.writeInt(u32, central_directory_offset, .little);
    try w.writeInt(u16, 0, .little);
    list = aw.toArrayList();

    return list.toOwnedSlice(allocator);
}

// ========== TESTS ==========

test "extract_override: overwrite existing file" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // 1. Create a ZIP file with "test.txt" containing "hello"
    const zip_data = try createTestZip(allocator, "test.txt", "hello");
    defer allocator.free(zip_data);
    const zip_file = try test_dir.createFile("test.zip", zip_data);
    zip_file.close(test_dir.io);
    var zip_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zip_path = try test_dir.join("test.zip", &zip_path_buf);

    // 2. Create an existing file to overwrite
    const existing_file = try test_dir.createFile("test.txt", "old content");
    existing_file.close(test_dir.io);

    // 3. Extract and overwrite
    const zip = try Dir.cwd().openFile(test_dir.io, zip_path, .{});
    defer zip.close(test_dir.io);
    var zip_buffer: [4096]u8 = undefined;
    var reader = zip.reader(test_dir.io, &zip_buffer);
    try download_zip.extract_override(test_dir.io, test_dir.dir.dir, &reader, .{});

    // 4. Verify the file was overwritten
    const extracted_file = try Dir.cwd().openFile(test_dir.io, try test_dir.join("test.txt", &zip_path_buf), .{});
    defer extracted_file.close(test_dir.io);
    var buf: [1024]u8 = undefined;
    var r = extracted_file.reader(io, &buf);
    var content: [1024]u8 = undefined;
    const n = try r.interface.readSliceShort(&content);
    try testing.expectEqualStrings("hello", content[0..n]);
}

test "extract_override: create new file" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // 1. Create a ZIP file with "new.txt" containing "world"
    const zip_data = try createTestZip(allocator, "new.txt", "world");
    defer (allocator.free(zip_data));
    const zip_file = try test_dir.createFile("test.zip", zip_data);
    zip_file.close(test_dir.io);

    var zip_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zip_path = try test_dir.join("test.zip", &zip_path_buf);

    // 2. Extract (file doesn't exist yet)
    const zip = try Dir.cwd().openFile(test_dir.io, zip_path, .{});
    defer zip.close(test_dir.io);
    var zip_buffer: [4096]u8 = undefined;
    var reader = zip.reader(test_dir.io, &zip_buffer);
    try download_zip.extract_override(test_dir.io, test_dir.dir.dir, &reader, .{});

    // 3. Verify the file was created
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const extracted_file_path = try test_dir.join("new.txt", &path_buf);
    std.debug.print("Extracted filepath {s}\n", .{extracted_file_path});
    const extracted_file = try Dir.cwd().openFile(test_dir.io, extracted_file_path, .{});
    defer extracted_file.close(test_dir.io);
    var buf: [1024]u8 = undefined;
    var r = extracted_file.reader(io, &buf);

    var content: [1024]u8 = undefined;
    const n = try r.interface.readSliceShort(&content);
    try testing.expectEqualStrings("world", content[0..n]);
}

test "extract_override: reject bad filename (path traversal)" {
    const allocator = testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // 1. Create a ZIP file with a bad filename (e.g., "../etc/passwd")
    const zip_data = try createTestZip(allocator, "../etc/passwd", "hacked");
    defer allocator.free(zip_data);
    const zip_file = try test_dir.createFile("test.zip", zip_data);
    zip_file.close(test_dir.io);

    var zip_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zip_path = try test_dir.join("test.zip", &zip_path_buf);

    // 2. Expect extraction to fail
    const zip = try Dir.cwd().openFile(test_dir.io, zip_path, .{});
    defer zip.close(test_dir.io);
    var zip_buffer: [4096]u8 = undefined;
    var reader = zip.reader(test_dir.io, &zip_buffer);
    try testing.expectError(error.ZipBadFilename, download_zip.extract_override(test_dir.io, Dir.cwd(), &reader, .{}));
}

test "extract_override: skip existing directory" {
    const allocator = testing.allocator;
    var test_dir = try TestDir.init(allocator);
    defer test_dir.deinit();

    // 1. Create a ZIP file with a directory entry "mydir/"
    const zip_data = try createTestZip(allocator, "mydir/", "");
    defer allocator.free(zip_data);
    const zip_file = try test_dir.createFile("test.zip", zip_data);
    zip_file.close(test_dir.io);

    var zip_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zip_path = try test_dir.join("test.zip", &zip_path_buf);

    // 2. Create the directory manually
    var mydir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try Dir.cwd().createDir(test_dir.io, try test_dir.join("mydir", &mydir_path_buf), std.Io.File.Permissions.default_dir);

    // 3. Extract (should not fail or delete the directory)
    const zip = try Dir.cwd().openFile(test_dir.io, zip_path, .{});
    defer zip.close(test_dir.io);

    var zip_buffer: [4096]u8 = undefined;
    var reader = zip.reader(test_dir.io, &zip_buffer);
    try download_zip.extract_override(test_dir.io, Dir.cwd(), &reader, .{});

    // 4. Verify the directory still exists
    const stat = try Dir.cwd().statFile(test_dir.io, try test_dir.join("mydir", &mydir_path_buf), .{});
    try testing.expect(stat.kind == .directory);
}
