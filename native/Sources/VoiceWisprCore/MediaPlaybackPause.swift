import Foundation

/// Serializes media commands and carries pause ownership into an immediate
/// follow-up capture instead of dispatching its still-pending resume.
@MainActor public final class MediaPlaybackPause {
    private let run: ([String]) async -> String?
    private var session: UUID?
    private var operation: Task<String?, Never>?
    private var capturesWhilePreparing = false

    public convenience init() { self.init(run: Self.runScript) }
    init(run: @escaping ([String]) async -> String?) { self.run = run }

    /// Claim the session synchronously so Stop can resume even while the
    /// asynchronous player query is pending. Audio startup need not wait for it.
    @discardableResult public func beginPause(for id: UUID) -> Bool {
        schedulePause(for: id, capturesWhilePreparing: true)
    }
    private func schedulePause(for id: UUID, capturesWhilePreparing: Bool) -> Bool {
        guard session == nil, !Task.isCancelled else { return false }
        session = id
        self.capturesWhilePreparing = capturesWhilePreparing
        let previous = operation
        let task = Task<String?, Never> {
            let inheritedPlayer = await previous?.value
            guard self.session == id, !Task.isCancelled else { return nil }
            return await self.run(["pause"]) ?? inheritedPlayer
        }
        operation = task
        return true
    }
    public func pause(for id: UUID) async {
        guard schedulePause(for: id, capturesWhilePreparing: false), let task = operation else { return }
        _ = await task.value
    }
    public func resume(for id: UUID? = nil) {
        guard let active = session, id == nil || id == active else { return }
        session = nil
        let previous = operation
        operation = Task {
            guard let player = await previous?.value, !Task.isCancelled else { return nil }
            guard self.session == nil || !self.capturesWhilePreparing else { return player }
            _ = await self.run(["resume", player])
            return nil
        }
    }
    public func finishPendingCommands() async { _ = await operation?.value }

    /// Sleep discards ownership without starting playback.
    public func discard() { session = nil; operation?.cancel() }

    nonisolated static var scriptURL: URL? {
        let installed = Bundle.main.resourceURL?.appendingPathComponent("VoiceWispr_VoiceWisprCore.bundle/Resources/media-playback.jxa")
        if let installed, FileManager.default.fileExists(atPath: installed.path) { return installed }
        return Bundle.module.url(forResource: "media-playback", withExtension: "jxa", subdirectory: "Resources")
    }
    private static func runScript(_ arguments: [String]) async -> String? {
        guard let script = scriptURL else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let child = Process(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            child.arguments = ["-l", "JavaScript", script.path] + arguments
            child.standardInput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            child.standardOutput = output
            do { try child.run() } catch { return nil }
            let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
            defer { deadline.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, data.count <= 4096,
                  let response = try? JSONDecoder().decode([String: String].self, from: data),
                  let player = response["pausedPlayer"], !player.isEmpty else { return nil }
            return player
        }.value
    }
}
