import Foundation

#if !MAS
// 비서가 행동하기 v2 through the claude CLI (direct build only). The app is the MCP server "chara" on a 0600 Unix socket;
// the CLI reaches it through `DogMonitor --agent-bridge <sock>`, a stdio relay it starts itself. Every call still goes
// through the ToolHost, so the gate lives in the app, not in CLI flags. Design: docs/AGENT-DESIGN.md sections 2, 14.

/// Newline-delimited JSON on a Unix socket: the first line is {"token":"…"}, then MCP JSON-RPC 2.0. One client at a time.
@MainActor
final class AgentBridgeServer {
    let tools: [AgentTool]
    let host: ToolHost
    /// Tests point this at a temp folder.
    var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DogMonitor/Agent", isDirectory: true)
    /// tools/call past this many answer budget_exhausted without reaching the host.
    var maxSteps = Int.max
    private(set) var steps = 0
    /// Set when a control tool ended the run.
    private(set) var lastStop: LoopStop?
    /// Called right after lastStop is set (the runner stops the CLI).
    var onStop: (() -> Void)?
    private var link: Link?

    init(tools: [AgentTool], host: ToolHost) {
        self.tools = tools
        self.host = host
    }

    func start() throws -> (socketPath: String, token: String) {
        stop()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)   // an older folder may have looser bits
        let id = UUID().uuidString
        var path = directory.appendingPathComponent("run-\(id).sock").path
        // sun_path holds 103 bytes: a long home folder gets a shorter name.
        if path.utf8.count > 103 { path = directory.appendingPathComponent("run-\(id.prefix(8)).sock").path }
        guard var addr = AgentBridge.address(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            unlink(path)
            throw POSIXError(code)
        }
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let link = Link(listener: fd, path: path, token: token)
        self.link = link
        steps = 0
        lastStop = nil
        Thread.detachNewThread { [weak self] in
            Self.serve(link) { line in await self?.handle(line) }
        }
        return (path, token)
    }

    func stop() {
        guard let link else { return }
        link.stop()
        unlink(link.path)
        self.link = nil
    }

    /// One JSON-RPC message in, the reply line out (nil for a notification).
    func handle(_ line: String) async -> String? {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            return Self.reply(NSNull(), error: (-32700, "Parse error"))
        }
        guard let id = msg["id"], !(id is NSNull) else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        switch msg["method"] as? String {
        case "initialize":
            return Self.reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                           "capabilities": ["tools": [String: Any]()],
                                           "serverInfo": ["name": "chara", "version": "1"]])
        case "ping":
            return Self.reply(id, result: [:])
        case "tools/list":
            return Self.reply(id, result: ["tools": AgentTools.mcp(tools)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            func text(_ t: String, error: Bool) -> String? {
                Self.reply(id, result: ["content": [["type": "text", "text": t]], "isError": error])
            }
            guard tools.contains(where: { $0.name == name }) else { return text("unknown_tool: \(name)", error: true) }
            guard lastStop == nil else { return text("run_stopped", error: true) }
            steps += 1
            guard steps <= maxSteps else { return text("budget_exhausted", error: true) }
            let outcome = await host.run(ToolCall(id: "\(id)", name: name, input: params["arguments"] as? [String: Any] ?? [:]))
            if let stop = outcome.stop, lastStop == nil {
                lastStop = stop
                onStop?()
            }
            return text(outcome.text, error: false)
        default:
            return Self.reply(id, error: (-32601, "Method not found"))
        }
    }

    private static func reply(_ id: Any, result: [String: Any]? = nil, error: (Int, String)? = nil) -> String? {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { o["error"] = ["code": error.0, "message": error.1] } else { o["result"] = result ?? [:] }
        return (try? JSONSerialization.data(withJSONObject: o)).map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Socket side (a background thread; host calls hop to the main actor)

    private final class Link: @unchecked Sendable {
        let listener: Int32, path: String, token: String
        private let lock = NSLock()
        private var stopped = false
        private var client: Int32 = -1

        init(listener: Int32, path: String, token: String) { (self.listener, self.path, self.token) = (listener, path, token) }

        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true; if client >= 0 { shutdown(client, SHUT_RDWR) } } }
        /// false when stop() came first.
        func use(_ fd: Int32) -> Bool { lock.withLock { client = fd; return !stopped || fd < 0 } }
    }

    private final class Box: @unchecked Sendable { var line: String? }

    private nonisolated static func serve(_ link: Link, answer: @escaping (String) async -> String?) {
        defer { close(link.listener) }
        while !link.isStopped {
            guard AgentBridge.wait(link.listener, stop: { link.isStopped }) else { return }
            let fd = accept(link.listener, nil, nil)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            if link.use(fd) { serveClient(fd, link, answer) }
            _ = link.use(-1)
            close(fd)
        }
    }

    private nonisolated static func serveClient(_ fd: Int32, _ link: Link, _ answer: @escaping (String) async -> String?) {
        let reader = AgentBridge.LineReader(fd: fd)
        let stop = { link.isStopped }
        guard let first = reader.next(stop: stop),
              let hello = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any],
              let token = hello["token"] as? String, AgentBridge.same(token, link.token) else { return }
        while let line = reader.next(stop: stop) {
            let box = Box(), done = DispatchSemaphore(value: 0)
            Task { box.line = await answer(String(decoding: line, as: UTF8.self)); done.signal() }
            done.wait()
            if let out = box.line, !AgentBridge.writeAll(fd, Data((out + "\n").utf8)) { return }
        }
    }
}

enum AgentBridge {
    static let tokenEnv = "CHARA_BRIDGE_TOKEN"

    /// `DogMonitor --agent-bridge <sock>`, started by the claude CLI as its MCP server. No AppKit.
    static func relay(socketPath: String) -> Never {
        signal(SIGPIPE, SIG_IGN)
        guard let token = ProcessInfo.processInfo.environment[tokenEnv], !token.isEmpty else {
            fputs("CHARA_BRIDGE_TOKEN 이 없어요\n", stderr)
            exit(2)
        }
        exit(relay(socketPath: socketPath, token: token, input: 0, output: 1))
    }

    /// Sends the token line, then copies input to the socket and the socket to output until either side closes.
    /// 0 after a session, 1 when the socket could not be reached.
    static func relay(socketPath: String, token: String, input: Int32, output: Int32) -> Int32 {
        guard var addr = address(socketPath) else { return 1 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let hello = (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data()
        guard connected == 0, writeAll(fd, hello + Data("\n".utf8)) else { close(fd); return 1 }
        // The first pump to end ends the session; the socket closes once both have stopped using it.
        let first = DispatchSemaphore(value: 0), both = DispatchGroup()
        for (from, to) in [(input, fd), (fd, output)] {
            both.enter()
            Thread.detachNewThread { pump(from, to); first.signal(); both.leave() }
        }
        first.wait()
        shutdown(fd, SHUT_RDWR)
        both.notify(queue: .global()) { close(fd) }
        return 0
    }

    static func pump(_ from: Int32, _ to: Int32) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0, writeAll(to, Data(chunk[0..<n])) else { return }
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                off += n
            }
            return true
        }
    }

    /// Constant time, so a wrong token says nothing about how close it was.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Waits until `fd` is readable; false when `stop` says so or the descriptor failed.
    static func wait(_ fd: Int32, stop: () -> Bool) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while !stop() {
            let r = poll(&p, 1, 200)
            if r > 0 { return true }
            if r < 0 && errno != EINTR { return false }
        }
        return false
    }

    /// Lines from a socket, checking `stop` every 200 ms. A line over 4 MB ends the session.
    final class LineReader {
        let fd: Int32
        private var buf = Data()
        static let maxLine = 4 << 20

        init(fd: Int32) { self.fd = fd }

        func next(stop: () -> Bool) -> Data? {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                if let i = buf.firstIndex(of: 10) {
                    let line = Data(buf[buf.startIndex..<i])
                    buf.removeSubrange(buf.startIndex...i)
                    return line
                }
                guard buf.count < Self.maxLine, AgentBridge.wait(fd, stop: stop) else { return nil }
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return nil }
                buf.append(contentsOf: chunk[0..<n])
            }
        }
    }
}

// MARK: - The claude CLI driver

/// One run of the owner's claude CLI with only the chara tools. Fails closed when this CLI lacks a flag that keeps its
/// own tools, settings and sessions off.
@MainActor
final class ClaudeAgentRun {
    let system: String
    let tools: [AgentTool]
    let host: ToolHost
    let limits: LoopLimits
    let model: String?
    let onEvent: (LoopEvent) -> Void
    /// Tests point these at fakes.
    var cli = BYOCLIClient(provider: .claude)
    var executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var socketDirectory: URL?

    private var child: Child?
    private var cancelled = false
    private var timedOut = false

    static let prefix = "mcp__chara__"
    static let requiredFlags = ["--tools", "--restricted", "--strict-mcp-config", "--mcp-config", "--allowedTools",
                                "--permission-mode", "--no-session-persistence"]
    static let tooOld = L("이 Claude Code 버전은 비서가 행동하기에 필요한 기능이 없어요. 업데이트해 주세요.")

    init(system: String, tools: [AgentTool], host: ToolHost, limits: LoopLimits = .init(), model: String? = nil,
         onEvent: @escaping (LoopEvent) -> Void = { _ in }) {
        self.system = system
        self.tools = tools
        self.host = host
        self.limits = limits
        self.model = model
        self.onEvent = onEvent
    }

    /// nil when the help text lacks any required flag (fail closed). The prompt goes on stdin.
    static func arguments(help: String, system: String, mcpConfig: String, model: String?) -> [String]? {
        let has = { (flag: String) in help.range(of: "(?<![\\w-])" + flag + "(?![\\w-])", options: .regularExpression) != nil }
        guard requiredFlags.allSatisfy(has) else { return nil }
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--tools", "", "--restricted", "--strict-mcp-config",
                 "--mcp-config", mcpConfig, "--allowedTools", prefix + "*", "--permission-mode", "dontAsk",
                 "--no-session-persistence", "--system-prompt", system]
        if let model { a += ["--model", model] }
        return a
    }

    static func mcpConfig(executable: String, socketPath: String, token: String) -> Data {
        let server: [String: Any] = ["command": executable, "args": ["--agent-bridge", socketPath], "env": [AgentBridge.tokenEnv: token]]
        return (try? JSONSerialization.data(withJSONObject: ["mcpServers": ["chara": server]])) ?? Data()
    }

    enum StreamItem: Equatable {
        case event(LoopEvent)
        case result(String, isError: Bool)
    }

    /// One stream-json line: chara tool calls and text become events, the last line is the result.
    static func parse(_ line: String) -> [StreamItem] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return [] }
        switch o["type"] as? String {
        case "assistant":
            let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { b in
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : .event(.say(t))
                case "tool_use":
                    guard let name = b["name"] as? String, name.hasPrefix(prefix) else { return nil }
                    return .event(.tool(name: String(name.dropFirst(prefix.count)), note: note(b["input"] as? [String: Any] ?? [:])))
                default:
                    return nil
                }
            }
        case "result":
            return [.result(o["result"] as? String ?? "", isError: o["is_error"] as? Bool ?? false)]
        default:
            return []
        }
    }

    /// A short hint of what the call is about (the address, the search words) for the chat's progress line.
    static func note(_ input: [String: Any]) -> String {
        let key = ["url", "query", "text", "name", "value", "question", "reason", "say"].first { input[$0] is String }
        return key.map { String((input[$0] as! String).prefix(60)) } ?? ""
    }

    func run(prompt: String) async -> LoopStop {
        guard let bin = cli.path() else { return .failed(L("이 맥에서 claude 프로그램을 찾지 못했어요.")) }
        let env = cli.childEnvironment(bin)
        let help: String
        do {
            help = try await Task.detached {
                try BYOCLIClient.cachedHelp(bin) { ChatGPTCharacterClient.run([bin, "--help"], env: env, timeout: 15) }
            }.value
        } catch {
            return .failed((error as? ChatError)?.message ?? Self.tooOld)
        }
        if cancelled { return .cancelled }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chara-agent-\(UUID().uuidString)", isDirectory: true)
        let config = dir.appendingPathComponent("mcp.json")
        guard let args = Self.arguments(help: help, system: system, mcpConfig: config.path, model: model) else { return .failed(Self.tooOld) }
        let server = AgentBridgeServer(tools: tools, host: host)
        if let socketDirectory { server.directory = socketDirectory }
        server.maxSteps = limits.steps
        server.onStop = { [weak self] in self?.child?.stop() }
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil,
              let sock = try? server.start(),
              FileManager.default.createFile(atPath: config.path, contents: Self.mcpConfig(executable: executable, socketPath: sock.socketPath, token: sock.token),
                                             attributes: [.posixPermissions: 0o600]),
              case let (child, lines)? = Child.spawn([bin] + args, env: env, cwd: dir, input: Data(prompt.utf8))
        else { return .failed(L("비서 연결 통로를 열지 못했어요.")) }
        self.child = child
        if cancelled { child.stop() }
        let timer = Task { [weak self, seconds = limits.seconds] in
            guard (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil, let self else { return }
            self.timedOut = true
            self.child?.stop()
        }
        var result: (text: String, isError: Bool)?
        var out = ""
        for await line in lines {
            if out.utf8.count < 65536 { out += line + "\n" }
            for item in Self.parse(line) {
                switch item {
                case .event(let e): onEvent(e)
                case .result(let t, let isError): result = (t, isError)
                }
            }
        }
        timer.cancel()
        self.child = nil

        if cancelled { return .cancelled }
        if let stop = server.lastStop { return stop }
        if timedOut || server.steps > limits.steps { return .budget }
        if let result, !result.isError { return .finished(result.text) }
        return .failed(ClaudeCharacterClient.failure(out, token: false)?.message ?? L("Claude가 답하지 못했어요."))
    }

    func cancel() {
        cancelled = true
        child?.stop()
    }

    /// The claude process leads its own group (node, and the bridge it starts), so stop() ends the whole tree.
    private final class Child: @unchecked Sendable {
        let pid: pid_t
        private let lock = NSLock()
        private var exited = false

        init(pid: pid_t) { self.pid = pid }

        func ended() { lock.withLock { exited = true } }

        func stop() {
            guard lock.withLock({ !exited }) else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if lock.withLock({ !exited }) { kill(-pid, SIGKILL) }
            }
        }

        /// stdout and stderr as lines; the stream ends when the process has exited.
        static func spawn(_ argv: [String], env: [String: String], cwd: URL, input: Data) -> (Child, AsyncStream<String>)? {
            let out = Pipe(), stdin = Pipe()
            var actions: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attr)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
            posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, 0)
            posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 2)
            posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
            // Own group (pgid = pid), and no descriptor of the app (the bridge socket) leaks into claude.
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attr, 0)
            let cArgs = argv.map { strdup($0) } + [nil]
            let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { (cArgs + cEnv).forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
            try? out.fileHandleForWriting.close()
            try? stdin.fileHandleForReading.close()
            guard spawned == 0 else { try? stdin.fileHandleForWriting.close(); return nil }
            let child = Child(pid: pid)
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)   // claude may exit before reading the prompt
            DispatchQueue.global().async { try? writer.write(contentsOf: input); try? writer.close() }
            let reader = out.fileHandleForReading
            let lines = AsyncStream<String> { cont in
                Thread.detachNewThread {
                    var buf = Data()
                    while case let chunk = reader.availableData, !chunk.isEmpty {
                        buf.append(chunk)
                        while let i = buf.firstIndex(of: 10) {
                            cont.yield(String(decoding: buf[buf.startIndex..<i], as: UTF8.self))
                            buf.removeSubrange(buf.startIndex...i)
                        }
                    }
                    if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
                    var st: Int32 = 0
                    while waitpid(pid, &st, 0) == -1 && errno == EINTR {}
                    child.ended()
                    cont.finish()
                }
            }
            return (child, lines)
        }
    }
}
#endif
