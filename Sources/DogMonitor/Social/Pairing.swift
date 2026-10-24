import AppKit
import Combine
import Network

// 근처 친구: the friend store, 친구 추가 with a 6-digit code, and what SocialBus does with each message.
// Keys: social.on (OFF), social.nickname, social.installID, social.friends. None of them go into the setup file.

extension FriendLook {
    /// How I look to a friend: my built-in character by id with its 꾸미기. A custom or photo character goes out as
    /// the plain dog with my DogProfile; no art crosses the network.
    static func mine(_ settings: AppSettings = .shared) -> FriendLook {
        var l = drawn(settings)
        l.seat = ChairCenter.shared.seat
        return l
    }

    private static func drawn(_ settings: AppSettings) -> FriendLook {
        let look = SpriteLook(settings)
        var profile = settings.profile
        profile.name = ""
        switch look.character {
        case .cat, .original:
            return FriendLook(character: look.character, id: look.readyID, profile: profile, colors: look.colors, cat: look.cat, outfit: look.outfit)
        case .dog:
            return FriendLook(character: .dog, id: nil, profile: profile, colors: nil, cat: nil, outfit: look.outfit)
        case .custom:
            return FriendLook(character: .dog, id: nil, profile: profile, colors: nil, cat: nil, outfit: nil)
        }
    }
}

extension SocialBus {
    /// 2: `.emote`, and a message of a case this build does not know is skipped instead of closing the link. 3: `.photo`.
    static let version = 3

    /// A random id made once for this install; nothing from the Mac.
    var installID: String {
        if let id = defaults.string(forKey: "social.installID"), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "social.installID")
        return id
    }

    /// What friends see me as (16 characters): the one typed in 설정, else the character's name.
    var nickname: String {
        let typed = defaults.string(forKey: "social.nickname") ?? ""
        return SocialText.nickname(typed.isEmpty ? AppSettings.shared.characterName : typed)
    }

    var wanted: Bool { defaults.bool(forKey: "social.on") && PluginGate.isOpen(.nearby) }

    func loadFriends() -> [SocialFriend] {
        defaults.data(forKey: "social.friends").flatMap { SocialWire.decode([SocialFriend].self, $0) } ?? []
    }

    private func saveFriends(_ f: [SocialFriend]) {
        setFriends(f)
        if let d = SocialWire.encode(f) { defaults.set(d, forKey: "social.friends") }
    }

    func friend(_ id: String) -> SocialFriend? { friends.first { $0.id == id } }

    /// 근처 친구 on or off as 설정 says. Off: listener, browser and links all go, nothing ticks.
    func refresh() {
        let want = wanted
        guard want != isOn else { return }
        if want { up() } else { down() }
    }

    private func up() {
        let n = SocialNode(myID: installID, keys: keys)
        n.friendIDs = { [weak self] in self?.friends.map(\.id) ?? [] }
        n.me = { [weak self] in (self?.nickname ?? L("친구"), FriendLook.mine()) }
        n.onOnline = { [weak self] id, on in self?.linkChanged(id, on) }
        n.onMessage = { [weak self] id, m in self?.received(m, from: id) }
        n.onPairRequest = { hello, check, answer in
            DispatchQueue.main.async { answer(SocialAlerts.confirmPair(SocialText.nickname(hello.nickname), check: check)) }
        }
        n.onPaired = { [weak self] f in self?.added(f) }
        n.onPairFailed = { SpeechBubbleCenter.shared.say(text: L("친구 맺기가 안 됐어요. 코드를 확인하고 다시 해 주세요."), source: .system, aloud: false, repeats: true) }
        n.onPairGuessed = {
            SpeechBubbleCenter.shared.say(text: L("다른 맥이 코드를 맞추려 했어요. 친구 추가를 멈췄어요."), source: .system, aloud: false, repeats: true)
        }
        n.onNearby = { [weak self] in self?.nearby = $0 }
        n.onCode = { [weak self] in self?.code = $0 }
        node = n
        setOn(true)
        n.start()
        $myStatus.dropFirst().removeDuplicates().sink { [weak self] s in self?.broadcast(.status(s.wire)) }.store(in: &bag)
        // A changed character, colour or outfit goes out 2 s later (only when it really changed).
        AppSettings.shared.objectWillChange.debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sendLookIfChanged() }.store(in: &bag)
    }

    private func down() {
        bag.removeAll()
        VoiceTalk.shared.end()
        node?.stop()
        node = nil
        nearby = []
        code = nil
        setOnline([])
        setOn(false)
    }

    /// Also called by ChairCenter when I sit or get up.
    func sendLookIfChanged() {
        let look = FriendLook.mine()
        guard look != lastLook else { return }
        lastLook = look
        broadcast(.look(look))
    }

    private func linkChanged(_ id: String, _ on: Bool) {
        var o = online
        if on { o.insert(id) } else { o.remove(id) }
        setOnline(o)
        guard on else {
            versions[id] = nil
            photoParts.drop(id)
            VoicePlayer.shared.gone(id)
            if VoiceTalk.shared.live == id { VoiceTalk.shared.end() }
            return
        }
        let look = FriendLook.mine()
        lastLook = look
        send(.hello(nickname: nickname, look: look, status: myStatus.wire, version: Self.version), to: id)
    }

    private func update(_ id: String, _ change: (inout SocialFriend) -> Void) {
        var all = friends
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        if all != friends { saveFriends(all) }
    }

    /// Everything a friend says, after the link's rate limit. Then the inbox, for NetPlay and the 가상 오피스.
    func received(_ m: SocialMessage, from id: String) {
        guard friend(id) != nil else { return }
        switch m {
        case let .hello(nick, look, status, version):
            // A first hello (or a newer build) from a friend that reads notes: my card goes back.
            if versions[id] != version, RoomRules.canEmote(version: version) { send(.note(myNote()), to: id) }
            versions[id] = version
            update(id) { $0.nickname = SocialText.nickname(nick); $0.look = FriendLook.received(look); $0.status = status.wire }
        case .look(let look):
            update(id) { $0.look = FriendLook.received(look) }
        case .status(let s):
            update(id) { $0.status = s.wire }
        case .chat(let raw):
            let text = SocialText.clean(raw)
            guard !text.isEmpty else { break }
            SocialChat.shared.append(id, text, mine: false)
            if !FriendWindow.isOpen(id), !FriendVisit.shared.show(id, line: text) { unread.insert(id) }
        case .voice, .voiceEnd:
            VoicePlayer.shared.receive(m, from: id)
        case .remoteAsk, .remoteAnswer:
            RemoteHelp.shared.receive(m, from: id)
        case .bye:
            forget(id, tell: false)
        case .emote(let kind):
            FriendRoom.shared.received(kind, from: id)
            SeasonCenter.shared.emoted()
        case .note(let n):
            notes[id] = FriendNote.received(n)
        case .doodle(let d):
            guard let d = Doodle.received(d) else { break }
            DoodleCenter.received(d, from: friend(id)?.nickname ?? L("친구"), seat: id)
        case .draw(let s):
            GroupDraw.shared.received(s, from: friend(id)?.nickname ?? L("친구"), sender: "f:" + id, bubble: true)
        case .hit(let item):
            ThrowCenter.shared.hit(item, by: friend(id)?.nickname ?? L("친구"))
        case .ko(let seconds):
            FriendRoom.shared.knockedOut(id, seconds: seconds)
        case .photo(let part):
            receivedPhoto(part, from: id)
        default:
            break
        }
        inbox.send((from: id, message: m))
    }

    /// Sends a chat line (cleaned, 200 characters) and keeps it in the window's history.
    @discardableResult
    func chat(_ text: String, to id: String) -> Bool {
        let t = SocialText.clean(text)
        guard !t.isEmpty, online.contains(id) else { return false }
        send(.chat(t), to: id)
        SocialChat.shared.append(id, t, mine: true)
        return true
    }

    // MARK: 친구 추가

    func showCode() { node?.showCode() }
    func hideCode() { node?.endPairing() }
    func join(_ mac: NearbyMac, code: String) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        guard friend(mac.id) == nil else {
            SpeechBubbleCenter.shared.say(text: L("이미 친구인 맥이에요. 다시 맺으려면 친구 목록에서 먼저 삭제해 주세요."), source: .system, aloud: false, repeats: true)
            return
        }
        node?.join(mac.endpoint, id: mac.id, code: digits)
    }

    private func added(_ f: SocialFriend) {
        saveFriends(friends.filter { $0.id != f.id } + [f])
        SpeechBubbleCenter.shared.say(text: L("\(f.nickname)와 친구가 됐어요"), source: .system, aloud: false, repeats: true)
    }

    /// 친구 삭제: says bye, drops the key and the record. `tell` false when they said bye first.
    func forget(_ id: String, tell: Bool = true) {
        if tell { send(.bye, to: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (tell ? 0.5 : 0)) { [weak self] in
            guard let self else { return }
            self.keys.delete(id)
            self.saveFriends(self.friends.filter { $0.id != id })
            self.unread.remove(id)
            SocialChat.shared.clear(id)
            self.node?.drop(id)
            self.node?.relisten()
        }
    }

    func markRead(_ id: String) { unread.remove(id) }

    /// The live connection's address, for 원격 지원 (never a payload string).
    func remoteHost(_ id: String) -> NWEndpoint.Host? { node?.remoteHost(id) }

    // MARK: Menu

    func friendMenu() -> [NSMenuItem] {
        var items: [NSMenuItem] = friends.map { f in
            let title = (unread.contains(f.id) ? "• " : "") + f.nickname + (f.isOnline ? " ●" : "")
            var sub = [FriendMenu.item(L("대화하기")) { FriendWindow.open(f.id) },
                       FriendMenu.item(L("프로필 카드")) { [weak self] in self?.card(f.id).map(FriendCardPanel.show) }]
            if f.isOnline, RoomRules.canEmote(version: versions[f.id]) {
                sub.append(FriendMenu.item(L("낙서 쪽지 보내기…")) { DoodleCenter.open(.friend(f.id), name: f.nickname) })
            }
            if f.isOnline, NetPlay.ready, PluginGate.isOpen(.netPlay) {
                sub.append(FriendMenu.item(L("같이 뛰기")) { NetPlay.shared.invite(f.id, .play) })
                sub.append(FriendMenu.item(L("별 대결")) { NetPlay.shared.invite(f.id, .starDuel) })
            }
            if f.isOnline, PluginGate.isOpen(.remoteHelp) {
                sub.append(FriendMenu.item(L("원격 지원 요청")) { RemoteHelp.shared.ask(f.id) })
            }
            if FriendRoom.shared.seatIDs.contains(f.id) {
                sub.append(FriendMenu.item(L("던지기")) { FriendRoom.shared.toss(f.id) })
            }
            return FriendMenu.submenu(title, sub)
        }
        if !items.isEmpty { items.append(.separator()) }
        items += FriendRoom.shared.groupItems()
        items.append(GroupDraw.menuItem())
        items.append(FriendMenu.item(L("오늘 한마디…")) { [weak self] in self?.askLine() })
        items.append(FriendMenu.item(L("친구 추가…")) { NearbyWindow.open() })
        return [.separator(), FriendMenu.submenu((unread.isEmpty ? "" : "• ") + L("친구"), items)]
    }
}

/// The few yes/no questions 근처 친구 asks (the app is in the background, so it comes forward first).
enum SocialAlerts {
    /// Both Macs ask this with the same 확인 숫자; a different number means another Mac sits in between.
    static func confirmPair(_ nickname: String, check: String) -> Bool {
        #if !MAS
        if SocialQA.active { SocialQA.log("check \(check)"); return true }
        #endif
        return ask(L("\(nickname)와 친구가 될까요?"),
                   L("확인 숫자 \(check)\n친구 맥에도 같은 숫자가 보일 때만 친구 하기를 눌러 주세요. 다르면 다른 맥이 끼어든 거예요."),
                   [L("친구 하기"), L("거절")], timeout: SocialNode.pairSeconds, safe: 1) == .alertFirstButtonReturn
    }

    /// An alert that answers the last button by itself after `timeout` seconds. `safe`: the button Return presses (a
    /// key hit in another app as the alert comes forward must never say yes); nil keeps the first.
    static func ask(_ title: String, _ text: String, _ buttons: [String], timeout: TimeInterval, safe: Int? = nil) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        if let safe, alert.buttons.indices.contains(safe) {
            alert.buttons.forEach { $0.keyEquivalent = "" }
            alert.buttons[safe].keyEquivalent = "\r"
        }
        NSApp.activate(ignoringOtherApps: true)
        let last = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + buttons.count - 1)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            if alert.window.isVisible { NSApp.stopModal(withCode: last) }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        return alert.runModal()
    }
}
