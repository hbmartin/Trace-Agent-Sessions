import Foundation

public struct PricingRate: Codable, Equatable, Sendable {
    public let modelPattern: String
    public let inputPerMillion: Decimal?
    public let outputPerMillion: Decimal?
    public let cacheWritePerMillion: Decimal?
    public let cacheReadPerMillion: Decimal?
    public let additionalReasoningPerMillion: Decimal?
    public let inputIncludesCacheReads: Bool
    public let unmetered: Bool
    public let note: String?

    public init(
        modelPattern: String,
        inputPerMillion: Decimal? = nil,
        outputPerMillion: Decimal? = nil,
        cacheWritePerMillion: Decimal? = nil,
        cacheReadPerMillion: Decimal? = nil,
        additionalReasoningPerMillion: Decimal? = nil,
        inputIncludesCacheReads: Bool = false,
        unmetered: Bool = false,
        note: String? = nil
    ) {
        self.modelPattern = modelPattern
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.additionalReasoningPerMillion = additionalReasoningPerMillion
        self.inputIncludesCacheReads = inputIncludesCacheReads
        self.unmetered = unmetered
        self.note = note
    }
}

public struct PricingFile: Codable, Sendable {
    public let formatVersion: Int
    public let effectiveDate: String
    public let currency: String
    public let rates: [PricingRate]

    public init(formatVersion: Int, effectiveDate: String, currency: String, rates: [PricingRate]) {
        self.formatVersion = formatVersion
        self.effectiveDate = effectiveDate
        self.currency = currency
        self.rates = rates
    }
}

public enum CostAvailability: Equatable, Sendable {
    case estimated(Decimal)
    case unmetered
    case rateUnavailable
}

public struct PricingLoadResult: Sendable {
    public let catalog: PricingCatalog
    public let overrideError: String?
}

public enum PricingError: LocalizedError {
    case invalidFormat(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail): "Invalid pricing file: \(detail)"
        }
    }
}

public struct PricingCatalog: Sendable {
    public let effectiveDate: String
    public let rates: [PricingRate]

    public init(file: PricingFile) throws {
        guard file.formatVersion == 1 else {
            throw PricingError.invalidFormat("formatVersion must be 1")
        }
        guard file.currency == "USD" else {
            throw PricingError.invalidFormat("currency must be USD")
        }
        guard !file.effectiveDate.isEmpty else {
            throw PricingError.invalidFormat("effectiveDate is required")
        }
        var patterns = Set<String>()
        for rate in file.rates {
            guard !rate.modelPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PricingError.invalidFormat("modelPattern must not be empty")
            }
            guard patterns.insert(rate.modelPattern).inserted else {
                throw PricingError.invalidFormat("duplicate modelPattern \(rate.modelPattern)")
            }
            for value in [rate.inputPerMillion, rate.outputPerMillion, rate.cacheWritePerMillion,
                          rate.cacheReadPerMillion, rate.additionalReasoningPerMillion].compactMap({ $0 }) {
                guard value >= 0 else {
                    throw PricingError.invalidFormat("rates must not be negative")
                }
            }
            if rate.unmetered,
               [rate.inputPerMillion, rate.outputPerMillion, rate.cacheWritePerMillion,
                rate.cacheReadPerMillion, rate.additionalReasoningPerMillion].contains(where: { $0 != nil }) {
                throw PricingError.invalidFormat("unmetered rates cannot include token prices")
            }
        }
        effectiveDate = file.effectiveDate
        rates = file.rates
    }

    public static func load(
        bundledURL: URL,
        overrideURL: URL = defaultOverrideURL()
    ) throws -> PricingLoadResult {
        let bundledFile = try decode(url: bundledURL)
        let bundled = try PricingCatalog(file: bundledFile)
        guard FileManager.default.fileExists(atPath: overrideURL.path) else {
            return .init(catalog: bundled, overrideError: nil)
        }
        do {
            let custom = try PricingCatalog(file: decode(url: overrideURL))
            return .init(catalog: custom, overrideError: nil)
        } catch {
            return .init(
                catalog: bundled,
                overrideError: "Could not load \(overrideURL.path): \(error.localizedDescription) Bundled rates are being used."
            )
        }
    }

    public static func defaultOverrideURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trace", isDirectory: true)
            .appendingPathComponent("pricing.json")
    }

    public func rate(for model: String) -> PricingRate? {
        let normalized = model.lowercased()
        return rates
            .filter { matches(pattern: $0.modelPattern.lowercased(), model: normalized) }
            .max { specificity($0.modelPattern) < specificity($1.modelPattern) }
    }

    public func estimate(_ usage: UsageRollup) -> CostAvailability {
        guard let rate = rate(for: usage.model) else { return .rateUnavailable }
        if rate.unmetered { return .unmetered }

        let cachedRead = max(0, usage.cacheReadTokens)
        let ordinaryInput = rate.inputIncludesCacheReads
            ? max(0, usage.inputTokens - cachedRead)
            : max(0, usage.inputTokens)
        var components: [(Int64, Decimal?)] = [
            (ordinaryInput, rate.inputPerMillion),
            (max(0, usage.outputTokens), rate.outputPerMillion),
            (max(0, usage.cacheWriteTokens), rate.cacheWritePerMillion),
            (cachedRead, rate.cacheReadPerMillion),
        ]
        if let reasoningRate = rate.additionalReasoningPerMillion {
            components.append((max(0, usage.reasoningTokens), reasoningRate))
        }
        guard components.allSatisfy({ $0.0 == 0 || $0.1 != nil }) else {
            return .rateUnavailable
        }
        let million = Decimal(1_000_000)
        let total = components.reduce(Decimal.zero) { partial, component in
            guard let price = component.1 else { return partial }
            return partial + (Decimal(component.0) / million * price)
        }
        return .estimated(total)
    }

    private static func decode(url: URL) throws -> PricingFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PricingFile.self, from: data)
    }
}

private func matches(pattern: String, model: String) -> Bool {
    if pattern.hasSuffix("*") {
        return model.hasPrefix(String(pattern.dropLast()))
    }
    return pattern == model
}

private func specificity(_ pattern: String) -> Int {
    pattern.hasSuffix("*") ? pattern.count - 1 : pattern.count + 10_000
}
