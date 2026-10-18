import Foundation

/// A small hand-drawn pixel block. `anchor` is the stamp pixel that lands on the attach point.
/// '.' is transparent; other letters are read by the painter.
struct Stamp {
    let rows: [[Character]]
    let anchor: (x: Int, y: Int)

    init(_ anchor: (Int, Int), _ rows: [String]) {
        self.rows = rows.map(Array.init)
        self.anchor = (anchor.0, anchor.1)
    }
}

/// Head facing right. Anchor lands on the torso's top front corner.
/// h skull, f face (around the eye), m muzzle, k chin, e/g eye top (g = glint), E eye bottom, n nose.
struct HeadStamp {
    let stamp: Stamp
    let topEar: (x: Int, y: Int)    // pointy and folded ears stand here
    let sideEar: (x: Int, y: Int)   // floppy and long ears hang from here
    let mouth: (x: Int, y: Int)     // where the tongue hangs
    /// Top-left corners of the teddy ear puffs (DogStamps.puffNear / puffFar). Only the teddy head uses them.
    var puffNear = (x: 0, y: 0), puffFar = (x: 0, y: 0)
}

enum DogStamps {
    static func head(_ snout: SnoutStyle, fluffy: Bool) -> HeadStamp {
        switch (snout, fluffy) {
        case (.short, false):
            return HeadStamp(stamp: Stamp((4, 6), [
                "..hhhh....",
                ".hhhhhhh..",
                "hhhhhhhhh.",
                "hhhhhfeghh",
                "hhhhhfEEmn",
                "hhhhhhhmmm",
                ".hhhhhkkk.",
            ]), topEar: (2, 0), sideEar: (1, 1), mouth: (8, 6))
        case (.medium, false):
            return HeadStamp(stamp: Stamp((4, 6), [
                "..hhhh......",
                ".hhhhhhh....",
                "hhhhhhhhh...",
                "hhhhhfeghh..",
                "hhhhhfEEmmmn",
                "hhhhhhhmmmmm",
                ".hhhhhkkkk..",
            ]), topEar: (2, 0), sideEar: (1, 1), mouth: (9, 6))
        case (.long, false):
            return HeadStamp(stamp: Stamp((4, 6), [
                "..hhhh.......",
                ".hhhhhhh.....",
                "hhhhhhhhh....",
                "hhhhhfeghhh..",
                "hhhhhfEEmmmmn",
                "hhhhhhhmmmmm.",
                ".hhhhhkkkk...",
            ]), topEar: (2, 0), sideEar: (1, 1), mouth: (10, 6))
        case (.short, true):
            // Round teddy head: domed crown, full forehead, short round muzzle.
            return HeadStamp(stamp: Stamp((5, 7), [
                "...hhhhh....",
                ".hhhhhhhhh..",
                "hhhhhhhhhhh.",
                "hhhhhhfeghh.",
                "hhhhhhfEEhmn",
                "hhhhhhhffmmn",
                ".hhhhhhhmmm.",
                "..hhhhhkkk..",
            ]), topEar: (3, 0), sideEar: (2, 2), mouth: (9, 7))
        case (.medium, true):
            return HeadStamp(stamp: Stamp((5, 7), [
                "...hhhhh.....",
                "..hhhhhhh....",
                ".hhhhhhhhh...",
                ".hhhhhfeghh..",
                ".hhhhhfEEmmmn",
                ".hhhhhhhmmmmm",
                ".hhhhhhhmmmm.",
                "..hhhhhhkk...",
            ]), topEar: (3, 0), sideEar: (2, 2), mouth: (10, 7))
        case (.long, true):
            return HeadStamp(stamp: Stamp((5, 7), [
                "...hhhhh......",
                "..hhhhhhh.....",
                ".hhhhhhhhh....",
                ".hhhhhfeghhh..",
                ".hhhhhfEEmmmmn",
                ".hhhhhhhmmmmmm",
                ".hhhhhhhmmmm..",
                "..hhhhhhkk....",
            ]), topEar: (3, 0), sideEar: (2, 2), mouth: (11, 7))
        }
    }

    /// Ears: x fur. Anchor lands on the head's ear point.
    static func ear(_ style: EarStyle, fluffy: Bool, flowing: Bool) -> Stamp {
        switch (style, fluffy, flowing) {
        case (.pointy, false, false): return Stamp((0, 2), [".x", "xx", "xx"])
        case (.pointy, false, true): return Stamp((1, 2), ["x..", "xx.", ".xx"])
        case (.pointy, true, false): return Stamp((0, 2), [".x.", "xxx", "xxx"])
        case (.pointy, true, true): return Stamp((1, 2), ["xx..", "xxx.", ".xxx"])
        case (.floppy, false, false): return Stamp((1, 0), ["xxx", "xxx", "xxx", ".xx"])
        case (.floppy, false, true): return Stamp((3, 0), ["xxxx", ".xxx"])
        case (.floppy, true, false): return Stamp((3, 0), ["..xxx.", ".xxxxx", "xxxxxx", "xxxxxx", "xxxxxx", ".xxxxx", "..xxx."])
        case (.floppy, true, true): return Stamp((4, 0), ["xxxxx.", "xxxxxx", ".xxxx."])
        case (.long, false, false): return Stamp((1, 0), ["xxx", "xxx", "xxx", "xxx", "xxx", ".x."])
        case (.long, false, true): return Stamp((4, 0), ["xxxxx", "..xxx"])
        // Silky and narrow, hanging down past the jaw to the chest: clearly longer than floppy.
        case (.long, true, false): return Stamp((2, 0), [".xxx", "xxxx", "xxxx", "xxxx", "xxxx", "xxxx", "xxxx", "xxxx", ".xx."])
        case (.long, true, true): return Stamp((6, 0), ["xxxxxxx", "xxxxxxx", "...xxxx"])
        case (.folded, false, _): return Stamp((0, 1), ["xxx", "xx."])
        case (.folded, true, _): return Stamp((0, 1), ["xxxx", "xxx."])
        }
    }

    /// Teddy look (DogProfile.isTeddy, like 젤리): a round face turned a little toward the viewer, both eyes
    /// showing, and round ears that puff out on both sides so head and ears are wider than tall.
    static let teddyHead = HeadStamp(stamp: Stamp((5, 7), [
        "....hhhh....",
        "..hhhhhhhh..",
        ".hhhhhhhhhh.",
        "hhhhhegfhegh",
        "hhhhhEEfhEEh",
        "hhhhhhhmnnmh",
        ".hhhhhmmnnm.",
        "..hhhhhkkk..",
    ]), topEar: (3, 0), sideEar: (2, 2), mouth: (8, 7), puffNear: (-4, 2), puffFar: (10, 0))

    /// Teddy ears, anchored at their top-left. The near puff overlaps the cheek and bulges out past it;
    /// the far one sits behind the head and peeks out past its top front corner, above the eyes,
    /// so it never sits where a snout would be.
    static let puffNear = Stamp((0, 0), ["..xxxx.", ".xxxxxx", "xxxxxxx", "xxxxxxx", ".xxxxxx", "..xxxx."])
    static let puffFar = Stamp((0, 0), [".xx.", "xxxx", "xxxx", "xxxx", ".xx."])

    /// Tails: t fur. Anchor is the root, placed on the rump.
    static func tail(_ style: TailStyle, pose: TailPose) -> Stamp {
        switch (style, pose) {
        case (.straight, .rest): return Stamp((3, 3), ["t...", "tt..", ".tt.", "..tt"])
        case (.straight, .wag): return Stamp((2, 3), ["t..", "t..", "tt.", ".tt"])
        case (.straight, .flow): return Stamp((4, 2), ["tt...", ".ttt.", "...tt"])
        case (.straight, .down): return Stamp((4, 0), ["...tt", "ttt.."])
        case (.short, .flow), (.short, .down): return Stamp((2, 0), ["ttt"])
        case (.short, _): return Stamp((1, 1), ["t.", "tt"])
        case (.curly, .rest), (.curly, .down): return Stamp((2, 3), [".tt.", "t..t", "t..t", ".ttt"])
        case (.curly, .wag): return Stamp((2, 4), [".tt.", "t..t", "t..t", ".tt.", "..t."])
        case (.curly, .flow): return Stamp((3, 3), [".tt.", "t..t", "t..t", ".ttt"])
        // A soft plume, fluffy all the way from a broad root: round top, no steps or notches in the edge,
        // so it never reads as a stick, a ball on a stick, or a fork.
        case (.fluffy, .rest): return Stamp((4, 4), [".tt..", "tttt.", "tttt.", ".tttt", "..ttt"])
        case (.fluffy, .wag): return Stamp((3, 4), [".tt.", "tttt", "tttt", ".ttt", ".tt."])
        case (.fluffy, .flow): return Stamp((5, 2), [".ttt..", "tttttt", ".ttttt"])
        case (.fluffy, .down): return Stamp((4, 1), [".tttt.", "tttttt"])
        }
    }

    /// Sleeping z, small and big.
    static let zSmall = Stamp((0, 0), ["zzz", "..z", ".z.", "zzz"])
    static let zBig = Stamp((0, 0), ["zzzz", "..z.", ".z..", "zzzz"])
}

extension DogProfile {
    /// Floppy + fluffy + short snout (젤리, 말티푸, 비숑) gets the teddy head and puffed-out round ears.
    /// Other floppy dogs keep side-view heads with hanging ears.
    var isTeddy: Bool { ears == .floppy && fluffy && snout == .short }
}
