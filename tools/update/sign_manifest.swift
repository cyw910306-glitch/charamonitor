// 캐릭모니터 업데이트 안내 파일 서명 도구 (배포자 전용, 오프라인).
//
//   swift tools/update/sign_manifest.swift web/update.json    web/update.json.sig 를 만든다
//
// 배포 서명 개인키로 update.json 의 바이트 그대로에 Ed25519 서명을 하고 base64 한 줄로 쓴다.
// 개인키: ~/Library/Application Support/JellyMonitorSeller/license-signing.key. 개인키는 절대 출력하지 않는다.
// 앱 쪽 검증: Sources/DogMonitor/App/Updater.swift (UpdateCheck.verify, UpdateCheck.publicKey).
import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/JellyMonitorSeller/license-signing.key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1 else { fail("사용법: swift tools/update/sign_manifest.swift <update.json>") }
let manifestURL = URL(fileURLWithPath: args[0])
guard let data = try? Data(contentsOf: manifestURL), !data.isEmpty else { fail("파일을 읽지 못했어요: \(manifestURL.path)") }
guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
      let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("개인키를 읽지 못했어요: \(keyURL.path)")
}
guard let signature = try? key.signature(for: data), key.publicKey.isValidSignature(signature, for: data) else {
    fail("서명하지 못했어요")
}
let sigURL = manifestURL.appendingPathExtension("sig")
do { try Data((signature.base64EncodedString() + "\n").utf8).write(to: sigURL, options: .atomic) } catch {
    fail("서명 파일을 쓰지 못했어요: \(error)")
}
let fingerprint = key.publicKey.rawRepresentation.prefix(4).map { String(format: "%02X", $0) }.joined()
print("서명했어요: \(sigURL.path) (공개키 앞부분 \(fingerprint), 앱의 UpdateCheck.publicKey 와 같아야 해요)")
