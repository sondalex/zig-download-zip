# zig-download-zip

**A simple and reusable Zig module for downloading and extracting ZIP files at build time.**

Designed to be used comfortably from `build.zig`.

## Installation

Add the dependency to your project's `build.zig.zon`:

```bash
zig fetch --save "https://github.com/sondalex/zig-download-zip/archive/refs/heads/main.tar.gz"
```

Then run:

```bash
zig build
```

## Usage

### In your `build.zig`

Below is an example on downloading a zip file from [nerd fonts](https://www.nerdfonts.com/).

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const download_zip_dep = b.dependency("download_zip", .{});
    const dz = download_zip_dep.module("zig_download_zip");

    _ = dz.DownloadZip.addDownloadStep(
        b,
        "https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/DejaVuSansMono.zip",
        "fonts/DejaVuSansMono",
        "dz", // dz for download zip
        "Download DejaVuSansMono Nerd Font",
    );
}
```

## Dependencies

- [`abhinav/temp.zig`](https://github.com/abhinav/temp.zig) — for temporary files

