import XCTest
@testable import DogMonitor

final class BusynessTests: XCTestCase {
    private func mem(_ pressure: Double, _ level: MemoryPressureLevel = .normal) -> MemoryStats {
        MemoryStats(total: 16 << 30, app: 0, wired: 0, compressed: 0, cachedFiles: 0, free: 0, swapUsed: 0,
                    pressure: pressure, pressureLevel: level)
    }

    func testIdleMacLetsTheDogSleep() {
        let b = Busyness.score(cpu: 0.02, memory: mem(0.40), thermal: .nominal)
        XCTAssertEqual(DogPose.forCPU(b.load), .lying)
        XCTAssertEqual(b.cause, .cpu)
    }

    func testMemoryPressureWakesTheDogEvenWhenCPUIsIdle() {
        XCTAssertEqual(DogPose.forCPU(Busyness.score(cpu: 0.02, memory: mem(0.80), thermal: .nominal).load), .fastWalk)
        let warn = Busyness.score(cpu: 0.02, memory: mem(0.85, .warning), thermal: .nominal)
        XCTAssertEqual(DogPose.forCPU(warn.load), .sprint)
        XCTAssertEqual(warn.cause, .memory)
        XCTAssertEqual(DogPose.forCPU(Busyness.score(cpu: 0.02, memory: mem(0.95, .critical), thermal: .nominal).load), .exhausted)
    }

    func testHeatAndBusiestWins() {
        let hot = Busyness.score(cpu: 0.1, memory: mem(0.4), thermal: .critical)
        XCTAssertEqual(DogPose.forCPU(hot.load), .exhausted)
        XCTAssertEqual(hot.cause, .heat)
        let cpu = Busyness.score(cpu: 0.95, memory: mem(0.85, .warning), thermal: .serious)
        XCTAssertEqual(cpu.cause, .cpu)
        XCTAssertEqual(DogPose.forCPU(cpu.load), .exhausted)
    }

    func testSpeedTestParsesNetworkQualityJSON() {
        let json = #"{"dl_throughput": 312000000, "ul_throughput": 45000000, "responsiveness": 66.9}"#
        let r = SpeedTest.parse(Data(json.utf8), date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(r?.downMbps, 312)
        XCTAssertEqual(r?.upMbps, 45)
        XCTAssertNil(SpeedTest.parse(Data("not json".utf8), date: Date()))
        XCTAssertNil(SpeedTest.parse(Data(#"{"dl_throughput": 0, "ul_throughput": 0}"#.utf8), date: Date()))
    }
}
