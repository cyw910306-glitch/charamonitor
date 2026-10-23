import Network
import XCTest
@testable import DogMonitor

/// 가상 오피스 auto status and the 원격 지원 vnc:// address (the ask limit is in SocialTests).
final class OfficeTests: XCTestCase {
    private func auto(_ current: OfficeStatus, autoSet: Bool = true, idle: TimeInterval = 0, focus: Bool = false, meeting: Bool = false) -> OfficeStatus? {
        OfficeRules.auto(current: current, autoSet: autoSet, idle: idle, focusing: focus, inMeeting: meeting)
    }

    func testAutoFollowsTheMac() {
        XCTAssertEqual(auto(.working), .working)
        XCTAssertEqual(auto(.working, idle: 299), .working)
        XCTAssertEqual(auto(.working, idle: 300), .away)
        XCTAssertEqual(auto(.away, idle: 10), .working)          // back at the keyboard
        XCTAssertEqual(auto(.working, focus: true), .focus)
        XCTAssertEqual(auto(.working, meeting: true), .meeting)
        XCTAssertEqual(auto(.working, idle: 900, focus: true, meeting: true), .meeting)   // a call wins, then 집중, then idle
        XCTAssertEqual(auto(.working, idle: 900, focus: true), .focus)
    }

    func testPickedStatusesStayUntilChanged() {
        for s in [OfficeStatus.away, .meal, .restroom, .meeting, .focus, .off] {
            XCTAssertNil(auto(s, autoSet: false, idle: 900), "\(s)")
            XCTAssertNil(auto(s, autoSet: false, meeting: true), "\(s)")
        }
        XCTAssertEqual(auto(.working, autoSet: false, idle: 900), .away)   // a picked 근무 중 still follows the Mac
    }

    func testEmptySeats() {
        XCTAssertEqual(OfficeStatus.allCases.filter(OfficeRules.atDesk), [.working, .meeting, .focus])
    }

    func testVNCAddress() {
        XCTAssertEqual(RemoteHelp.vncURL(.ipv4(IPv4Address("192.168.0.12")!))?.absoluteString, "vnc://192.168.0.12")
        let mapped = NWEndpoint.Host.ipv6(IPv6Address("::ffff:10.0.0.7")!)
        XCTAssertEqual(RemoteHelp.vncURL(mapped)?.absoluteString, "vnc://10.0.0.7")
        let global = NWEndpoint.Host.ipv6(IPv6Address("2001:db8::5")!)
        XCTAssertEqual(RemoteHelp.vncURL(global)?.absoluteString, "vnc://[2001:db8::5]")
        let link = NWEndpoint.Host.ipv6(IPv6Address("fe80::1%lo0")!)
        XCTAssertEqual(RemoteHelp.vncURL(link)?.absoluteString, "vnc://[fe80::1%25lo0]")
        // A name could say anything: only the connection's own address opens.
        XCTAssertNil(RemoteHelp.vncURL(.name("evil.example", nil)))
    }
}
