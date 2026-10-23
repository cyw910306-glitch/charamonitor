// 캐릭모니터 플러그인 코드 해시 도구 (배포자 전용, 오프라인).
//
//   swift tools/update/plugin_code.swift <id> <코드>     web/plugins.json 의 "code" 에 넣을 해시를 쓴다
//
// 해시 = SHA256("charamonitor-plugin:" + id + ":" + 정규화한 코드), 소문자 hex. 정규화 = 대문자로, A-Z 0-9 만 남김.
// 앱 쪽: Sources/DogMonitor/App/Plugins.swift (PluginRules.hash). 코드 자체는 저장소에 넣지 않는다:
// ~/Library/Application Support/JellyMonitorSeller/plugin-codes.json 에만 둔다.
import CryptoKit
import Foundation

let ids = ["playMoves", "wardrobe", "nearby", "netPlay", "walkieTalkie", "office", "remoteHelp"]
let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, ids.contains(args[0]) else {
    FileHandle.standardError.write(Data("사용법: swift tools/update/plugin_code.swift <\(ids.joined(separator: "|"))> <코드>\n".utf8))
    exit(2)
}
let code = String(String.UnicodeScalarView(args[1].uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }))
guard !code.isEmpty else { FileHandle.standardError.write(Data("코드가 비었어요\n".utf8)); exit(2) }
print(SHA256.hash(data: Data("charamonitor-plugin:\(args[0]):\(code)".utf8)).map { String(format: "%02x", $0) }.joined())
