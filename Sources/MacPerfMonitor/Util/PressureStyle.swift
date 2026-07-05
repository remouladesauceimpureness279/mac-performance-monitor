import MacPerfMonitorCore
import SwiftUI

/// UI styling for pressure levels. Kept in the app target because `MacPerfMonitorCore`
/// is intentionally free of any SwiftUI dependency.
extension PressureLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "flame.fill"
        }
    }
}

/// UI styling for the memory taxonomy categories. Colours are chosen so the
/// reclaimable, benign categories (cached files, free) read as cool/calm and the
/// pressure-relevant ones (compressed) stand out.
extension TaxonomyCategory {
    var color: Color {
        switch self {
        case .wired: return .purple
        case .appMemory: return .blue
        case .compressed: return .orange
        case .cachedFiles: return .teal
        case .free: return Color(nsColor: .quaternaryLabelColor)
        }
    }
}

extension Verdict.Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .caution: return .orange
        case .alert: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .alert: return "flame.fill"
        }
    }
}
