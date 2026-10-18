/// Pose hysteresis: a new pose must hold for 2 consecutive ticks,
/// except jumps of 2+ levels which switch at once. Stops flicker at thresholds.
struct PoseFilter {
    private(set) var pose: DogPose
    private var pending: DogPose?

    init(pose: DogPose = .lying) { self.pose = pose }

    /// Feed one monitor tick. Returns the new pose when it changes, else nil.
    mutating func feed(_ load: Double) -> DogPose? {
        let target = DogPose.forCPU(load)
        guard target != pose else { pending = nil; return nil }
        if abs(target.rawValue - pose.rawValue) >= 2 || pending == target {
            pose = target
            pending = nil
            return target
        }
        pending = target
        return nil
    }
}
