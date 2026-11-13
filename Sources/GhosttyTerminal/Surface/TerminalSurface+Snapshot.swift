//
//  TerminalSurface+Snapshot.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

public extension TerminalSurface {
    /// Replaces the terminal with the one in the Ghostty snapshot that `data`
    /// starts with, such as the one a terminal multiplexer sends ahead of a
    /// session's live output.
    ///
    /// The terminal takes everything the snapshot records: both screens and
    /// their scrollback, modes, the cursor, colors a program set, the title and
    /// working directory, which reach the delegate as if a program had just set
    /// them, and any escape sequence the snapshot was cut in the middle of. The
    /// surface keeps what its configuration sets, the default colors and
    /// palette and the scrollback and image limits, and its own grid size.
    ///
    /// With an in-memory session, load the snapshot before the session
    /// receives the output that follows it. Output the session has queued but
    /// not parsed yet lands on the restored terminal.
    ///
    /// - Returns: How many bytes of `data` the snapshot took; the rest is live
    ///   output. `nil` when `data` does not start with a whole snapshot this
    ///   build can read, and then the terminal is unchanged.
    @discardableResult
    func loadSnapshot(_ data: Data) -> Int? {
        guard let surface = rawValue else {
            TerminalDebugLog.log(.output, "surface snapshot ignored: missing surface")
            return nil
        }
        let consumed = data.withUnsafeBytes { buffer -> UInt in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return ghostty_surface_load_snapshot(surface, ptr, UInt(buffer.count))
        }
        TerminalDebugLog.log(
            .output,
            "surface snapshot load bytes=\(data.count) consumed=\(consumed)",
        )
        return consumed > 0 ? Int(consumed) : nil
    }

    /// A Ghostty snapshot of the terminal, which ``loadSnapshot(_:)`` loads.
    func snapshot() -> Data? {
        guard let surface = rawValue else { return nil }
        var result = ghostty_surface_snapshot_s()
        guard ghostty_surface_snapshot(surface, &result) else { return nil }
        defer { ghostty_surface_free_snapshot(surface, &result) }
        guard let bytes = result.bytes else { return Data() }
        return Data(bytes: bytes, count: Int(result.len))
    }
}
