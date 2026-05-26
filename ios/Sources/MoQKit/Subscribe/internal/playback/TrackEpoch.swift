typealias TrackEpoch = UInt64

extension TrackEpoch {
    func next() -> TrackEpoch {
        self &+ 1
    }
}
