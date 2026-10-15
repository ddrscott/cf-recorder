import Foundation

/// `CFRecorder sync [connect [url] | status | disconnect]`
///
/// With no subcommand it pushes every call folder and prints one line per call.
enum SyncCommand {
    static func run(_ args: [String]) async -> Int32 {
        let say = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
        do {
            switch args.first {
            case "connect":
                _ = try await SyncClient.connect(server: args.dropFirst().first ?? SyncClient.defaultServer, log: say)
            case "status":
                guard let s = SyncClient.session else { print("not connected"); return 1 }
                print("\(s.server)\t\(s.email ?? "")")
            case "disconnect":
                SyncClient.disconnect()
                say("Disconnected.")
            case nil:
                let folders = MeetingStore.list().map(\.folder)
                for folder in folders {
                    let report = try await SyncClient.sync(folder: folder)
                    print("\(folder.lastPathComponent)\t\(report.uploaded.isEmpty ? "up to date" : "sent " + report.uploaded.joined(separator: ", "))")
                    fflush(stdout)
                }
            default:
                say("usage: CFRecorder sync [connect [url] | status | disconnect]")
                return 64
            }
            return 0
        } catch {
            say("sync: \(error.localizedDescription)")
            return 1
        }
    }
}
