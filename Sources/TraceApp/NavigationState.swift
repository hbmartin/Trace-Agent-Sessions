import Foundation

enum SearchDatePreset: String, CaseIterable, Identifiable {
    case anyTime
    case sevenDays
    case thirtyDays
    case yearToDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTime: "Any time"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .yearToDate: "Year to date"
        }
    }

    func bounds(now: Date) -> (from: Int64?, to: Int64?) {
        let calendar = Calendar.current
        let start: Date?
        switch self {
        case .anyTime:
            return (nil, nil)
        case .sevenDays:
            start = calendar.date(byAdding: .day, value: -7, to: now)
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -30, to: now)
        case .yearToDate:
            start = calendar.date(from: calendar.dateComponents([.year], from: now))
        }
        return (
            start.map { Int64($0.timeIntervalSince1970 * 1_000) },
            Int64(now.timeIntervalSince1970 * 1_000)
        )
    }
}

struct SearchResultAnchor {
    let id: Int64?
    let offset: CGFloat
    let oldOrder: [Int64]
}

extension Int64 {
    var traceDate: String {
        Date(timeIntervalSince1970: Double(self) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}

struct TranscriptBookmark {
    let messageID: Int64
    let offset: CGFloat
    let index: Int
}
