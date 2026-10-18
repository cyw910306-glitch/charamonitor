import Foundation

/// Internet speed via macOS's built-in networkQuality (Apple's test servers); the Mac App Store build, which may not
/// run system binaries, times a download and an upload with URLSession instead. Runs only when the user asks:
/// one test can move hundreds of MB on a fast line.
final class SpeedTest: ObservableObject {
    static let shared = SpeedTest()

    struct Reading: Codable, Equatable {
        var downMbps: Double
        var upMbps: Double
        var date: Date
    }

    @Published private(set) var last: Reading?
    @Published private(set) var isRunning = false
    @Published private(set) var failed = false

    private static let defaultsKey = "speedTest"

    private init() {
        last = AppDefaults.store.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Reading.self, from: $0) }
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        failed = false
        DispatchQueue.global(qos: .utility).async {
            let reading = Self.measure()
            DispatchQueue.main.async {
                self.isRunning = false
                guard let reading else { self.failed = true; return }
                self.save(reading)
                PetSignals.shared.send(.speedTest)
            }
        }
    }

    func save(_ reading: Reading) {
        last = reading
        if let data = try? JSONEncoder().encode(reading) { AppDefaults.store.set(data, forKey: Self.defaultsKey) }
    }

    #if MAS
    /// The 인터넷 속도 button's tooltip.
    static let helpText = L("Cloudflare 속도 측정 서버로 다운로드 10MB, 업로드 5MB를 보내 속도를 잽니다.")
    private static let downURL = URL(string: "https://speed.cloudflare.com/__down?bytes=10000000")!
    private static let upURL = URL(string: "https://speed.cloudflare.com/__up")!

    /// Blocking: up to about 40 s. nil when offline or either leg fails.
    // ponytail: fixed sizes, so a very fast line reads low (latency dominates 10 MB); stream with a delegate and
    // count bytes per second if that matters.
    static func measure() -> Reading? {
        guard let down = timed(URLRequest(url: downURL), upload: nil),
              let up = timed(URLRequest(url: upURL), upload: Data(count: 5_000_000)) else { return nil }
        return Reading(downMbps: down, upMbps: up, date: Date())
    }

    /// Megabits per second for one request, counting the bytes that actually moved.
    private static func timed(_ request: URLRequest, upload: Data?) -> Double? {
        var request = request
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        var bytes = 0, ok = false
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        let finish: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            bytes = upload?.count ?? data?.count ?? 0
            done.signal()
        }
        if let upload {
            request.httpMethod = "POST"
            URLSession.shared.uploadTask(with: request, from: upload, completionHandler: finish).resume()
        } else {
            URLSession.shared.dataTask(with: request, completionHandler: finish).resume()
        }
        done.wait()
        let seconds = Date().timeIntervalSince(start)
        return ok && bytes > 0 && seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : nil
    }
    #else
    static let helpText = L("Apple 서버로 약 15초 동안 다운로드·업로드 속도를 잽니다. 데이터를 꽤 씁니다.")
    private static let tool = "/usr/bin/networkQuality"

    /// Blocking: about 15 s. nil when the tool is missing, offline or the output is unreadable.
    static func measure() -> Reading? {
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-c", "-M", "15"]   // JSON output, at most 15 s
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // read before waiting, so a full pipe cannot block
        process.waitUntilExit()
        return parse(data, date: Date())
    }

    /// networkQuality -c prints dl_throughput / ul_throughput in bits per second.
    static func parse(_ data: Data, date: Date) -> Reading? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let down = (json["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (json["ul_throughput"] as? NSNumber)?.doubleValue,
              down > 0 || up > 0
        else { return nil }
        return Reading(downMbps: down / 1_000_000, upMbps: up / 1_000_000, date: date)
    }
    #endif
}
