import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

/// A snapshot taken from one real surface and loaded into another of a
/// different size, which then goes on with live output.
@MainActor
struct TerminalSurfaceSnapshotTests {
    @Test
    func `a snapshot loads into a surface of another size and live output continues it`() async throws {
        // Scrollback, colours, a title, and an SGR cut after "\e[3".
        let source = await GhosttySurfaceHarness.make()
        source.receive((1 ... 300).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        source.receive("\u{1B}]2;restored\u{07}\u{1B}[1;32mgreen\u{1B}[0m\r\n\u{1B}[3")
        let sourceGrid = source.surface?.rawValue.map(ghostty_surface_size)
        let taken = source.surface?.snapshot()
        source.tearDown()
        let snapshot = try #require(taken)

        let target = await GhosttySurfaceHarness.make()
        defer { target.tearDown() }
        let surface = try #require(target.surface)
        let raw = try #require(surface.rawValue)
        await resize(target, raw, width: 480, height: 300)
        let grid = ghostty_surface_size(raw)
        #expect(grid.columns != sourceGrid?.columns)
        #expect(grid.rows != sourceGrid?.rows)

        target.receive("before\r\n")
        #expect(surface.loadSnapshot(snapshot.prefix(snapshot.count / 2)) == nil)
        #expect(screenText(surface).contains("before"))

        let live = Data("1mred\r\nafter\r\n".utf8)
        #expect(surface.loadSnapshot(snapshot + live) == snapshot.count)
        target.session.receive(live)
        target.session.waitForPendingOutput()

        let text = screenText(surface)
        #expect(!text.contains("before"))
        #expect(text.contains("line 1\n"))
        #expect(text.contains("line 300\n"))
        #expect(text.contains("green\n"))
        #expect(text.contains("red\nafter"))
        #expect(!text.contains("1mred"))

        // The restored terminal has this surface's grid, not the source's.
        target.session.receive(Data("\u{1B}[18t".utf8))
        let report = await target.takeOutbound()
        #expect(report == Data("\u{1B}[8;\(grid.rows);\(grid.columns)t".utf8))

        ghostty_surface_refresh(raw)
        ghostty_surface_draw(raw)
    }

    /// Resizes the surface and waits until its terminal has the new grid,
    /// which it reports in band (mode 2048) once the resize is applied.
    private func resize(
        _ harness: GhosttySurfaceHarness,
        _ raw: ghostty_surface_t,
        width: Int,
        height: Int,
    ) async {
        harness.receive("\u{1B}[?2048h")
        // Through the coordinator, which sizes the surface from the view on
        // every metrics sync and would put a direct resize back.
        harness.coordinator.viewSize = { (Double(width), Double(height)) }
        harness.coordinator.synchronizeMetrics()
        let grid = ghostty_surface_size(raw)
        let report = "\u{1B}[48;\(grid.rows);\(grid.columns);"
        // Ghostty coalesces resizes behind a short timer on its IO thread.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while clock.now < deadline {
            if await harness.takeOutbound().count(of: report) > 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the resize never reached the terminal")
    }

    private func screenText(_ surface: TerminalSurface) -> String {
        _ = surface.performBindingAction("select_all")
        return surface.readSelection() ?? ""
    }
}
