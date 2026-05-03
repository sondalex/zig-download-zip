//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const temp = @import("temp");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const zip = std.zip;

pub const CreateDirOptions = struct {
    fail: bool = false,
    recursive: bool = false,
};

pub const CreateDirError = Dir.CreateDirError || Dir.StatFileError;

// Copied from lib/std/zip.zig
fn isBadFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/')
        return true;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

pub fn extract_override(
    io: Io,
    dest: Dir,
    fr: *File.Reader,
    options: std.zip.ExtractOptions,
) !void {
    var iter = try std.zip.Iterator.init(fr);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (try iter.next()) |entry| {
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const filename_slice = filename_buf[0..entry.filename_len];
        try fr.interface.readSliceAll(filename_slice);

        // NOTE: Normalize and validate filename (CRITICAL - Do not delete)
        const filename = filename_slice;
        if (options.allow_backslashes) {
            std.mem.replaceScalar(u8, filename, '\\', '/');
        } else if (std.mem.findScalar(u8, filename, '\\')) |_| {
            return error.ZipFilenameHasBackslash;
        }
        if (isBadFilename(filename)) {
            return error.ZipBadFilename;
        }

        if (dest.statFile(io, filename, .{})) |stat| {
            if (stat.kind == .file) {
                try dest.deleteFile(io, filename);
            }
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        try entry.extract(fr, options, &filename_buf, dest);
    }
}

fn createDir(io: std.Io, path: []const u8, options: CreateDirOptions) CreateDirError!void {
    if (Dir.cwd().statFile(io, path, .{})) |stat| {
        if ((!options.fail) and (stat.kind == .directory)) {
            return;
        }
        if (stat.kind == .directory) {
            return error.PathAlreadyExists;
        }

        return error.NotDir;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (options.recursive) {
        try Dir.createDirPath(.cwd(), io, path);
    } else {
        try Dir.createDirAbsolute(io, path, std.Io.File.Permissions.default_dir);
    }
}

pub const DownloadZip = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,

    const Self = @This();

    pub fn init(environ: std.process.Environ, allocator: std.mem.Allocator, io: std.Io) Self {
        return DownloadZip{ .environ = environ, .allocator = allocator, .io = io };
    }

    pub fn downloadAndExtract(self: *Self, url: []const u8, dest_dir: []const u8) !void {
        try createDir(self.io, dest_dir, .{
            .fail = false,
            .recursive = true,
        });

        var temp_file = try temp.TempFile.create(self.io, self.allocator, .{
            .pattern = "archive-*.zip",
        }, self.environ);
        defer temp_file.deinit();

        var buffer: [Dir.max_path_bytes]u8 = undefined;
        const n = try temp_file.parent_dir.realPathFile(self.io, temp_file.basename, &buffer);
        const temp_path: []const u8 = buffer[0..n];
        try self.downloadFile(url, temp_path);
        try self.unzip(temp_path, dest_dir);
    }
    pub fn http_get(
        self: Self,
        url: []const u8,
        body: *std.ArrayList(u8),
    ) !void {
        var client: std.http.Client = .{ .io = self.io, .allocator = self.allocator };
        defer client.deinit();

        var redirect_buffer: [8 * 1024]u8 = undefined;

        var writer = std.Io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();

        const result = try client.fetch(.{
            .method = .GET,
            .location = .{ .url = url },
            .response_writer = &writer.writer,
            .redirect_buffer = &redirect_buffer,
        });

        if (!(result.status == .ok)) {
            std.debug.print("HTTP error: {}\n", .{result.status});
            return error.HttpRequestFailed;
        }

        try body.appendSlice(self.allocator, writer.written());
    }

    pub fn downloadFile(self: Self, url: []const u8, dest_path: []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try self.http_get(url, &body);
        {
            var file = try Dir.cwd().createFile(self.io, dest_path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(self.io);
            var writer = file.writer(self.io, &.{});
            try writer.interface.writeAll(body.items);
        }
    }

    pub fn unzip(self: Self, filepath: []const u8, dest_path: []const u8) !void {
        var file = try Dir.cwd().openFile(self.io, filepath, .{});
        var file_buffer: [4096]u8 = undefined;

        var reader = file.reader(self.io, &file_buffer);

        var dir = try Dir.openDirAbsolute(self.io, dest_path, .{});
        defer dir.close(self.io);

        try extract_override(self.io, dir, &reader, .{});
    }
};

pub fn addDownloadStep(
    b: *std.Build,
    url: []const u8,
    dest_dir: []const u8,
    step_name: []const u8,
    description: []const u8,
) *std.Build.Step {
    const dep = b.dependency("download_zip", .{});
    const mod = dep.module("download_zip");

    const dz_dep = b.dependency("download_zip", .{});
    const downloader = b.addExecutable(.{
        .name = "download_zip",
        .root_module = b.createModule(.{
            .root_source_file = dz_dep.path("src/downloader.zig"),
            .target = b.graph.host,
        }),
    });

    downloader.root_module.addImport("download_zip", mod);

    const run = b.addRunArtifact(downloader);
    run.addArgs(&.{ url, dest_dir });

    const step = b.step(step_name, description);
    step.dependOn(&run.step);

    return step;
}
