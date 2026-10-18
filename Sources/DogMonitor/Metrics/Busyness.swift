import Foundation

/// What is keeping the Mac (and the dog) busy.
enum LoadCause: Equatable {
    case cpu, memory, heat

    /// Short Korean reason when something other than the CPU is the busiest part.
    var reason: String? {
        switch self {
        case .cpu: return nil
        case .memory: return L("메모리가 빠듯해요")
        case .heat: return L("맥이 뜨거워요")
        }
    }
}

/// How hard the Mac is working, 0...1, on the same scale as CPU usage so DogPose.forCPU applies.
/// The busiest of CPU, memory pressure and heat wins, so an idle Mac still lets the dog sleep.
enum Busyness {
    static func score(cpu: Double, memory: MemoryStats?, thermal: ProcessInfo.ThermalState) -> (load: Double, cause: LoadCause) {
        var best = (load: min(1, max(0, cpu)), cause: LoadCause.cpu)
        if let memory, case let m = memoryScore(memory), m > best.load { best = (m, .memory) }
        if case let h = heatScore(thermal), h > best.load { best = (h, .heat) }
        return best
    }

    /// Normal pressure below 50% (a typical Mac sits at 30 to 45%) adds nothing; above it the dog
    /// walks, then runs. Activity Monitor's yellow (warning) means sprint, red (critical) means panting.
    static func memoryScore(_ m: MemoryStats) -> Double {
        switch m.pressureLevel {
        case .critical: return 0.9
        case .warning: return 0.7
        case .normal: return min(0.6, max(0, (m.pressure - 0.5) * 1.2))
        }
    }

    static func heatScore(_ t: ProcessInfo.ThermalState) -> Double {
        switch t {
        case .serious: return 0.7
        case .critical: return 0.9
        default: return 0   // nominal and fair are everyday temperatures
        }
    }
}
