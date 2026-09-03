import Foundation

/// Great-circle distance, shared by everything here that measures how far the
/// device went. The twin of `Distance.kt`.
enum Distance {
    private static let earthRadiusMeters = 6_371_000.0

    /// Haversine. Exact enough at the distances a person covers.
    static func meters(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double
    ) -> Double {
        let phi1 = lat1 * .pi / 180
        let phi2 = lat2 * .pi / 180
        let deltaPhi = (lat2 - lat1) * .pi / 180
        let deltaLambda = (lon2 - lon1) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2)
            * sin(deltaLambda / 2) * sin(deltaLambda / 2)

        return earthRadiusMeters * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}
