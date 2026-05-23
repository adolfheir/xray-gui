import Foundation

extension Int {
    /// Returns nil if the value is zero, otherwise returns self.
    var nonZero: Int? { self == 0 ? nil : self }
}
