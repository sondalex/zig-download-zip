const std = @import("std");
const dz = @import("download_zip");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 3) {
        std.debug.print("Usage: {s} <url> <dest_dir>\n", .{args[0]});
        std.process.exit(1);
    }

    const url = args[1];
    const dest_dir = args[2];

    var downloader = dz.DownloadZip.init(environ, gpa, io);
    try downloader.downloadAndExtract(url, dest_dir);
}
