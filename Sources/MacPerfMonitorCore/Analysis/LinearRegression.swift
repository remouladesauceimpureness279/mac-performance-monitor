import Foundation

/// Ordinary least-squares fit of `y = slope * x + intercept`, plus the
/// coefficient of determination (R squared). Used by the leak detector.
public struct LinearRegression: Sendable {
    public var slope: Double
    public var intercept: Double
    public var rSquared: Double

    /// Fit over paired samples. Returns nil when there are fewer than two points
    /// or x has no variance.
    public static func fit(_ points: [(x: Double, y: Double)]) -> LinearRegression? {
        let n = Double(points.count)
        guard points.count >= 2 else { return nil }

        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let meanX = sumX / n
        let meanY = sumY / n

        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let dx = p.x - meanX
            let dy = p.y - meanY
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
        }
        guard sxx > 0 else { return nil }

        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        // R^2 = (sxy^2) / (sxx * syy); 1.0 when syy is 0 (flat line fits exactly).
        let rSquared = syy > 0 ? (sxy * sxy) / (sxx * syy) : 1.0
        return LinearRegression(slope: slope, intercept: intercept, rSquared: rSquared)
    }
}
