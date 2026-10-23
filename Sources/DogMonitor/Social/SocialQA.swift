#if !MAS
import Combine
import Foundation

/// QA only (`--qa-defaults <suite>`, direct build): two copies of the built app on one Mac pair, chat and sync status
/// with no clicks. The preferences live in that suite and friend keys in memory, so the owner's are never touched.
/// `--qa-host <file>` shows a code and writes it to the file; `--qa-join <file>` reads it, joins the Mac showing a
/// code, then says hello and picks 식사. Both print what they see to stderr.
enum SocialQA {
    static var active = false
    private static var bag = Set<AnyCancellable>()

    static func start(_ args: [String]) {
        active = true
        let bus = SocialBus.shared
        bus.keys = .memory()
        func arg(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        func log(_ s: String) { fputs("QA \(s)\n", stderr) }
        bus.$isOn.removeDuplicates().sink { log("on \($0)") }.store(in: &bag)
        bus.$online.removeDuplicates().sink { log("online \($0.sorted())") }.store(in: &bag)
        bus.$friends.removeDuplicates().sink { log("friends \($0.map { "\($0.nickname):\($0.status.rawValue)" })") }.store(in: &bag)
        bus.$nearby.removeDuplicates().sink { log("nearby \($0.map(\.nickname))") }.store(in: &bag)
        bus.inbox.sink { log("from \($0.from.prefix(8)) \($0.message)") }.store(in: &bag)
        if let file = arg("--qa-host") {
            bus.$code.compactMap { $0 }.sink { c in
                log("code shown")
                try? c.write(toFile: file, atomically: true, encoding: .utf8)
            }.store(in: &bag)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { log("show code"); bus.showCode() }
        }
        if let file = arg("--qa-join") {
            var joined = false
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                if !joined, let mac = bus.nearby.first, let code = try? String(contentsOfFile: file, encoding: .utf8) {
                    joined = true
                    log("join \(mac.nickname)")
                    bus.join(mac, code: code)
                }
                guard let f = bus.friends.first, bus.online.contains(f.id) else { return }
                t.invalidate()
                log("chat sent \(bus.chat("QA 안녕", to: f.id))")
                bus.myStatus = .meal
                log("status sent meal")
            }
        }
    }
}
#endif
