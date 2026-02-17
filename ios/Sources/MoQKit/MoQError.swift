import Foundation

public struct MoQError: Error, CustomStringConvertible {
    public let code: Int32

    public init(code: Int32) {
        self.code = code
    }

    public var description: String {
        "MoQError(code: \(code))"
    }
}

extension Int32 {
    /// Interpret a positive result as a handle, or throw on negative.
    func asHandle() throws -> UInt32 {
        guard self > 0 else { throw MoQError(code: self) }
        return UInt32(self)
    }

    /// Interpret a zero result as success, or throw on negative.
    func asSuccess() throws {
        guard self >= 0 else { throw MoQError(code: self) }
    }
}
