import Foundation

/// Torso and leg sizes in art pixels. Builds differ in proportion more than in size,
/// so every dog stays readable in the menu bar.
struct BuildMetrics {
    let bodyLen: Int
    let legLen: Int
    let legW: Int
    /// Torso rows from the back line down: pixels cut off at the rump end and at the chest end.
    let rows: [(rump: Int, chest: Int)]
    /// Where the head anchor lands, relative to the chest's top front corner.
    let headOffset: (x: Int, y: Int)
    var bodyH: Int { rows.count }

    init(_ build: BodyBuild, fluffy: Bool) {
        switch build {
        case .small:
            bodyLen = 12; legLen = 4
            rows = [(1, 2), (0, 0), (0, 0), (0, 0), (1, 1)]
            headOffset = (2, 1)
        case .medium:
            bodyLen = 14; legLen = 5
            rows = [(1, 2), (0, 0), (0, 0), (1, 0), (3, 1)]
            headOffset = (2, fluffy ? 2 : 1)   // the taller fluffy head sits lower so ears keep headroom
        case .large:
            bodyLen = 15; legLen = 5
            rows = [(1, 2), (0, 0), (0, 0), (0, 0), (2, 0), (5, 1)]
            headOffset = (2, fluffy ? 3 : 2)
        case .long:
            bodyLen = 16; legLen = 2
            rows = [(1, 2), (0, 0), (0, 0), (0, 0), (1, 1)]
            headOffset = (2, 1)
        }
        legW = fluffy ? 3 : 2
    }
}

/// One leg for one frame, relative to a standing leg under the hip.
struct LegPose {
    var dx = 0      // paw offset from the hip, + is forward; scaled by leg length
    var lift = 0    // paw height above the ground
    var knee = 0    // middle joint pushed forward (+) or back (-)
}

enum TailPose { case rest, wag, flow, down }
enum EarPose { case rest, flow }

/// Everything that moves between frames.
struct FrameRig {
    var frame = 0               // index inside the pose, drives effect phases
    var bob = 0                 // torso offset, negative is up
    var headDX = 0, headDY = 0
    var frontNear = LegPose(), frontFar = LegPose(), backNear = LegPose(), backFar = LegPose()
    var tail = TailPose.rest
    var ears = EarPose.rest
    var earDY = 0               // teddy ear puffs: extra drop below their spot on the head
    var lying = false
    var breath = 0              // lying: chest rise in px
    var tongue = false
    var tired = false           // half-closed eyes
    var sweat = false
}

extension DogPose {
    /// Keyframes. Counts: lying 3, the three walks 4, run 4, sprint 6, exhausted 6.
    var rigs: [FrameRig] {
        let raw: [FrameRig]
        switch self {
        case .lying:
            raw = (0..<3).map { FrameRig(tail: .down, lying: true, breath: $0 == 1 ? 1 : 0) }
        case .slowWalk:   // nose down, sniffing along
            raw = Self.walk(stride: 1, lift: 1, bob: 0, headDY: 2, headDX: 1)
        case .walk:
            raw = Self.walk(stride: 2, lift: 1, bob: 1, headDY: 0)
        case .fastWalk:   // head pushed forward, long bouncy strides
            raw = Self.walk(stride: 3, lift: 2, bob: 1, headDY: 0, headDX: 1)
        case .run:
            raw = Self.earLag(Self.gallop4)
        case .sprint:
            raw = Self.earLag(Self.gallop6)
        case .exhausted:
            raw = Self.earLag(Self.gallop6.map { r in
                var r = r
                r.tongue = true
                r.tired = true
                r.sweat = true
                r.headDY += 1
                return r
            })
        }
        return raw.enumerated().map { i, r in
            var r = r
            r.frame = i
            return r
        }
    }

    /// Diagonal pairs move together: front near with back far, front far with back near.
    private static func walk(stride s: Int, lift: Int, bob: Int, headDY: Int, headDX: Int = 0) -> [FrameRig] {
        let reach = LegPose(dx: s), push = LegPose(dx: -s), plant = LegPose()
        let swingFront = LegPose(dx: 0, lift: lift, knee: 1)
        let swingBack = LegPose(dx: 0, lift: lift, knee: -1)
        // Teddy ears hang at least 1 px past the neck line, so they read as ears and not a bump on the back.
        func rig(_ fn: LegPose, _ ff: LegPose, _ bn: LegPose, _ bf: LegPose, up: Int, tail: TailPose) -> FrameRig {
            FrameRig(bob: -up, headDX: headDX, headDY: headDY, frontNear: fn, frontFar: ff, backNear: bn, backFar: bf,
                     tail: tail, earDY: max(0, 1 - headDY))
        }
        return [
            rig(reach, push, push, reach, up: 0, tail: .rest),
            rig(plant, swingFront, swingBack, plant, up: bob, tail: .wag),
            rig(push, reach, reach, push, up: 0, tail: .rest),
            rig(swingFront, plant, plant, swingBack, up: bob, tail: .wag),
        ]
    }

    private static func gallop(_ bob: Int, _ fn: LegPose, _ ff: LegPose, _ bn: LegPose, _ bf: LegPose,
                               headDX: Int = 1, headDY: Int = 1) -> FrameRig {
        FrameRig(bob: bob, headDX: headDX, headDY: headDY, frontNear: fn, frontFar: ff, backNear: bn, backFar: bf,
                 tail: .flow, ears: .flow)
    }

    /// Floppy teddy ears lag the head: 1 px lower while the head is up, back in place when it drops,
    /// so they bounce against the bob instead of riding along with it.
    private static func earLag(_ rigs: [FrameRig]) -> [FrameRig] {
        let heights = rigs.map { $0.bob + $0.headDY }
        let mid = Double(heights.reduce(0, +)) / Double(heights.count)
        return zip(rigs, heights).map { r, h in
            var r = r
            r.earDY = Double(h) < mid ? 1 : 0
            return r
        }
    }

    /// Stretch, front plant, gather, back push.
    private static let gallop4: [FrameRig] = [
        gallop(-1, LegPose(dx: 3, lift: 2), LegPose(dx: 2, lift: 2), LegPose(dx: -3, lift: 2), LegPose(dx: -2, lift: 1)),
        gallop(0, LegPose(dx: 0), LegPose(dx: -1, lift: 1, knee: 1), LegPose(dx: 1, lift: 2, knee: -1), LegPose(dx: 0, lift: 2, knee: -1)),
        gallop(-1, LegPose(dx: -2, lift: 2, knee: 1), LegPose(dx: -1, lift: 2, knee: 1), LegPose(dx: 2), LegPose(dx: 3, lift: 1)),
        gallop(0, LegPose(dx: 1, lift: 2, knee: 1), LegPose(dx: 0, lift: 2, knee: 1), LegPose(dx: -2), LegPose(dx: -1)),
    ]

    /// The same cycle with longer reach and a higher flight, in six steps.
    private static let gallop6: [FrameRig] = [
        gallop(-2, LegPose(dx: 4, lift: 2), LegPose(dx: 3, lift: 2), LegPose(dx: -4, lift: 2), LegPose(dx: -3, lift: 2), headDX: 2),
        gallop(-1, LegPose(dx: 2, lift: 0), LegPose(dx: 3, lift: 1), LegPose(dx: -2, lift: 2, knee: -1), LegPose(dx: -3, lift: 2), headDX: 2, headDY: 2),
        gallop(0, LegPose(dx: -1), LegPose(dx: 0), LegPose(dx: 1, lift: 2, knee: -1), LegPose(dx: 0, lift: 2, knee: -1), headDY: 2),
        gallop(-1, LegPose(dx: -3, lift: 2, knee: 1), LegPose(dx: -2, lift: 2, knee: 1), LegPose(dx: 3, lift: 1), LegPose(dx: 2, lift: 2)),
        gallop(0, LegPose(dx: -1, lift: 2, knee: 2), LegPose(dx: -2, lift: 1, knee: 1), LegPose(dx: 1), LegPose(dx: 2)),
        gallop(-1, LegPose(dx: 2, lift: 2, knee: 1), LegPose(dx: 1, lift: 2, knee: 1), LegPose(dx: -3), LegPose(dx: -2, lift: 1), headDX: 2),
    ]
}
