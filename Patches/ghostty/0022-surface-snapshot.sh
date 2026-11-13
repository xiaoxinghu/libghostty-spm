#!/bin/bash

set -euo pipefail

SOURCE_DIR="${1:?Usage: $0 <ghostty-source-dir>}"

# =============================================================================
# Load a terminal snapshot into a surface, and take one from it
# =============================================================================
#
# Ghostty's snapshot format (src/terminal/snapshot) records a whole terminal:
# both screens, scrollback, modes, cursor, colours, title, working directory,
# Kitty images, and the bytes of any escape sequence the snapshot was cut in
# the middle of. A host that feeds a surface the output of a terminal running
# elsewhere, such as a multiplexer's client, gets a snapshot followed by the
# live output. libghostty-vt decodes snapshots, but nothing put one into a
# surface: the decoder returns a new Terminal, and a surface's terminal is a
# value its renderer and stream handler hold the address of.
#
# ghostty_surface_load_snapshot decodes off the terminal-state mutex, then
# under it swaps the restored terminal in at the same address, the way a
# full reset replaces state in place. It returns how many bytes the snapshot
# took, so the host knows where the live output starts, or 0 when the bytes
# do not start with a whole snapshot this Ghostty can read; the surface is
# then unchanged. Inside the swap:
#
#   - What the surface's configuration set is kept from the old terminal:
#     the default colours and palette, the scrollback limits, the Kitty image
#     limits. Colours a program set travel with the snapshot.
#   - The restored terminal is resized to the surface's grid and cell size;
#     a snapshot carries the size of the terminal that wrote it.
#   - The selection gesture's tracked pin is released before the old pages
#     go, and each screen gets a new generation, so a running search drops
#     its handles to the old screens instead of reading freed pages.
#   - The stream is put back at ground, then fed the snapshot's continuation.
#   - The restored title and working directory reach the host as set_title
#     and pwd_change, which otherwise arrive only when a program sets them.
#
# ghostty_surface_snapshot encodes the surface's terminal, with its
# unfinished sequence, and ghostty_surface_free_snapshot frees the result.
# For tests and for hosts that save a surface. To carry an unfinished
# sequence the surface's stream now keeps one (continuation tracking, off by
# default upstream): nothing while the stream is at ground, which is where
# it ends nearly every write, and at most 1 MiB when it is not.
#
# Anchored edits (Script/support/anchored_edit.py) in src/termio/Termio.zig,
# include/ghostty.h and src/apprt/embedded.zig; the last two sit beside
# ghostty_surface_write_buffer_replay, so this runs after 0011.
# =============================================================================

PYTHONPATH="$(cd "$(dirname "$0")/../../Script/support" && pwd)" python3 - "$SOURCE_DIR" <<'PY'
import sys

from anchored_edit import Source

source_dir = sys.argv[1]

termio = Source(source_dir, "src/termio/Termio.zig")
termio.replace(
    """        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
        }),
""",
    """        .terminal_stream = .init(.{
            .allocator = alloc,
            .handler = handler,
            .continuation_max_bytes = snapshot_continuation_max_bytes,
        }),
""",
)
termio.insert_before(
    """/// Process output from readdata but the lock is already held.
""",
    """/// libghostty-spm: the most bytes of an unfinished escape sequence a
/// snapshot may carry, both for one loaded and for the stream's own, which it
/// keeps so that a snapshot of this terminal can carry it.
pub const snapshot_continuation_max_bytes = 1024 * 1024;

/// libghostty-spm: replace the terminal with the one in the snapshot at the
/// start of `bytes`, and return how many bytes the snapshot took. The bytes
/// after it are not read: they are the output that follows the snapshot.
///
/// The terminal takes everything the snapshot records: both screens and
/// their history, modes, cursor, colours a program set, title and working
/// directory, and any sequence the snapshot was cut in the middle of. What
/// this surface's configuration set is kept: the default colours and
/// palette, the scrollback and Kitty image limits. The restored terminal is
/// resized to this surface's grid.
///
/// Callable from any thread, like processOutput: decoding happens before the
/// terminal-state mutex is taken and the swap under it, so output processed
/// after this returns lands on the restored terminal. On an error the
/// terminal is unchanged.
pub fn loadSnapshot(
    self: *Termio,
    bytes: []const u8,
    selection_gesture: *terminalpkg.SelectionGesture,
) !usize {
    const alloc = self.alloc;

    const image_storage_limit = limit: {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());
        break :limit self.config.image_storage_limit;
    };

    // Decode off the lock: nothing here touches the live terminal.
    var reader: std.Io.Reader = .fixed(bytes);
    var decoded = try terminalpkg.snapshot.decode(alloc, global.io(), &reader, .{
        .max_continuation_bytes = snapshot_continuation_max_bytes,
        .kitty_image_storage_limit = image_storage_limit,
    });
    defer decoded.deinit(alloc);
    const consumed = reader.seek;

    var title_buf: [256]u8 = undefined;
    var title: ?[:0]const u8 = null;
    var pwd: apprt.surface.Message.WriteReq = .{ .stable = "" };
    {
        self.renderer_state.mutex.lockUncancelable(global.io());
        defer self.renderer_state.mutex.unlock(global.io());

        // The gesture tracks a pin in the old terminal's pages.
        selection_gesture.reset(&self.terminal);

        // The stream may be inside a sequence meant for the old terminal.
        // The restored one brings its own, in the continuation.
        const stream = &self.terminal_stream;
        if (!stream.ground()) {
            stream.parser.deinit();
            stream.parser = .init();
            stream.parser.osc_parser.alloc = alloc;
            stream.utf8decoder = .{};
            stream.handler.dcs.deinit();
            stream.handler.apc.state.deinit();
            stream.handler.apc.state = .inactive;
        }
        if (stream.continuation) |*tracker| tracker.reset();

        // The renderer and the stream handler hold the address of
        // self.terminal, so the restored terminal goes in at that address.
        var old = self.terminal;
        defer old.deinit(alloc);
        self.terminal = decoded.toOwned();
        const t = &self.terminal;

        // A screen that replaces an old one gets a newer generation, so a
        // running search sees its handle is stale even where the new screen
        // has the old one's address.
        for (std.enums.values(terminalpkg.ScreenSet.Key)) |key| {
            t.screens.generations.put(key, old.screens.generation(key) +% 1);
        }

        // What the configuration set, as the old terminal had it.
        t.colors.palette.changeDefault(alloc, old.colors.palette.original.*) catch |err| {
            log.warn("error keeping the default palette over a snapshot err={}", .{err});
            t.colors.palette.resetDefault(alloc);
        };
        t.colors.background.default = old.colors.background.default;
        t.colors.foreground.default = old.colors.foreground.default;
        t.colors.cursor.default = old.colors.cursor.default;
        const old_limits = old.screens.get(.primary).?.pages.limits;
        const pages = &t.screens.get(.primary).?.pages;
        pages.setMaxBytes(if (old_limits.bytes.explicit == std.math.maxInt(usize)) null else old_limits.bytes.explicit);
        pages.setMaxLines(if (old_limits.lines.explicit == std.math.maxInt(usize)) null else old_limits.lines.explicit);
        t.setKittyGraphicsLoadingLimits(.allWithTempDir(global.tmpDirPath()));

        // A snapshot carries the size of the terminal that wrote it.
        const grid = self.size.grid();
        t.resize(alloc, .{
            .cols = grid.columns,
            .rows = grid.rows,
            .cell_size_px = .{
                .width = self.size.cell.width,
                .height = self.size.cell.height,
            },
        }) catch |err| log.warn("error resizing a restored terminal err={}", .{err});

        switch (decoded.continuation) {
            .ground => {},
            .bytes => |continuation| stream.nextSlice(continuation),
        }

        // As the stream handler reports them: a terminal with no title is
        // shown by its working directory.
        const restored_title: []const u8 = t.getTitle() orelse "";
        const restored_pwd: []const u8 = t.getPwd() orelse "";
        stream.handler.seen_title = restored_title.len > 0;
        const shown = if (restored_title.len > 0) restored_title else restored_pwd;
        if (shown.len < title_buf.len) {
            @memcpy(title_buf[0..shown.len], shown);
            title_buf[shown.len] = 0;
            title = title_buf[0..shown.len :0];
        }
        if (restored_pwd.len > 0) {
            pwd = apprt.surface.Message.WriteReq.init(alloc, restored_pwd) catch |err| pwd: {
                log.warn("error reporting a restored working directory err={}", .{err});
                break :pwd .{ .stable = "" };
            };
        }

        t.flags.dirty.clear = true;
        t.flags.search_viewport_dirty = true;
        stream.handler.queueRender() catch {};
    }

    // Instant: a caller on the main thread would wait forever on a full
    // mailbox, which only the main thread drains.
    if (title) |_| {
        if (self.surface_mailbox.push(.{ .set_title = title_buf }, .{ .instant = {} }) == 0) {
            log.warn("surface mailbox full, restored title not reported", .{});
        }
    }
    if (self.surface_mailbox.push(.{ .pwd_change = pwd }, .{ .instant = {} }) == 0) {
        log.warn("surface mailbox full, restored working directory not reported", .{});
        pwd.deinit();
    }

    return consumed;
}

/// libghostty-spm: a snapshot of the terminal, with the stream's unfinished
/// sequence, allocated with `alloc`.
pub fn encodeSnapshot(self: *Termio, alloc: Allocator) ![]u8 {
    self.renderer_state.mutex.lockUncancelable(global.io());
    defer self.renderer_state.mutex.unlock(global.io());

    var continuation: std.Io.Writer.Allocating = .init(alloc);
    defer continuation.deinit();
    if (!self.terminal_stream.ground()) {
        try self.terminal_stream.writeContinuation(&continuation.writer);
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try terminalpkg.snapshot.encode(alloc, &out.writer, &self.terminal, .{
        .continuation = .{ .bytes = continuation.written() },
    });
    return try out.toOwnedSlice();
}

""",
)
termio.save()

header = Source(source_dir, "include/ghostty.h")
header.insert_after(
    "GHOSTTY_API void ghostty_surface_write_buffer_replay(ghostty_surface_t, const uint8_t*, uintptr_t);\n",
    """// libghostty-spm: ghostty_surface_load_snapshot, ghostty_surface_snapshot
typedef struct {
  const uint8_t* bytes;
  uintptr_t len;
} ghostty_surface_snapshot_s;
GHOSTTY_API uintptr_t ghostty_surface_load_snapshot(ghostty_surface_t, const uint8_t*, uintptr_t);
GHOSTTY_API bool ghostty_surface_snapshot(ghostty_surface_t, ghostty_surface_snapshot_s*);
GHOSTTY_API void ghostty_surface_free_snapshot(ghostty_surface_t, ghostty_surface_snapshot_s*);
""",
)
header.save()

src = Source(source_dir, "src/apprt/embedded.zig")
src.insert_after(
    """        surface.core_surface.io.processOutputSuppressingResponses(ptr[0..len]);
    }
""",
    """
    /// libghostty-spm: replace the surface's terminal with the one in the
    /// snapshot at the start of the buffer. Returns how many bytes the
    /// snapshot took; what follows is output for
    /// ghostty_surface_write_buffer. Returns 0, with the surface unchanged,
    /// when the buffer does not start with a whole snapshot this build can
    /// read.
    export fn ghostty_surface_load_snapshot(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) usize {
        if (len == 0) return 0;
        const core_surface = &surface.core_surface;
        return core_surface.io.loadSnapshot(
            ptr[0..len],
            &core_surface.mouse.selection_gesture,
        ) catch |err| {
            log.warn("snapshot not loaded err={}", .{err});
            return 0;
        };
    }

    // ghostty_surface_snapshot_s (libghostty-spm)
    const Snapshot = extern struct {
        bytes: ?[*]const u8,
        len: usize,
    };

    /// libghostty-spm: a snapshot of the surface's terminal, for
    /// ghostty_surface_load_snapshot. Free it with
    /// ghostty_surface_free_snapshot.
    export fn ghostty_surface_snapshot(surface: *Surface, result: *Snapshot) bool {
        const bytes = surface.core_surface.io.encodeSnapshot(global.alloc()) catch |err| {
            log.warn("snapshot not taken err={}", .{err});
            return false;
        };
        result.* = .{ .bytes = bytes.ptr, .len = bytes.len };
        return true;
    }

    export fn ghostty_surface_free_snapshot(_: *Surface, snapshot: *Snapshot) void {
        if (snapshot.bytes) |ptr| global.alloc().free(ptr[0..snapshot.len]);
        snapshot.* = .{ .bytes = null, .len = 0 };
    }
""",
)
src.save()
PY
