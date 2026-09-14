import SwiftUI
import TraceCore

struct CostsView: View {
    @ObservedObject var model: TraceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Estimated equivalent API spend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(totalDisplay)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    if unavailableModels > 0 {
                        Text("\(unavailableModels) model \(unavailableModels == 1 ? "rate is" : "rates are") unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Picker("Range", selection: $model.settings.costRange) {
                        ForEach(CostRange.allCases) { range in Text(range.title).tag(range) }
                    }
                    .frame(width: 170)
                    Toggle("Include sidechains", isOn: $model.settings.includeSidechains)
                }
            }
            .padding(20)
            .onChange(of: model.settings.costRange) { _, _ in model.reloadCosts() }
            .onChange(of: model.settings.includeSidechains) { _, _ in model.reloadCosts() }

            if model.settings.costRange == .custom {
                HStack {
                    DatePicker("From", selection: $model.customCostStart, displayedComponents: .date)
                    DatePicker("Through", selection: $model.customCostEnd, displayedComponents: .date)
                    Button("Apply") { model.reloadCosts() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            }

            if let pricingError = model.pricingError {
                Label(pricingError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()
            Table(model.usage) {
                TableColumn("Date", value: \.day).width(90)
                TableColumn("Project", value: \.projectName)
                TableColumn("Model", value: \.model)
                TableColumn("Input") { row in Text(row.inputTokens.formatted()).monospacedDigit() }.width(90)
                TableColumn("Output") { row in Text(row.outputTokens.formatted()).monospacedDigit() }.width(90)
                TableColumn("Estimated equivalent API spend") { row in
                    Text(costDisplay(row)).monospacedDigit()
                }.width(190)
            }
        }
        .onAppear { model.reloadCosts() }
    }

    private var estimates: [CostAvailability] {
        guard let pricing = model.pricing else { return model.usage.map { _ in .rateUnavailable } }
        return model.usage.map(pricing.estimate)
    }

    private var totalDisplay: String {
        let total = estimates.reduce(Decimal.zero) { partial, availability in
            if case .estimated(let amount) = availability { return partial + amount }
            return partial
        }
        return currency(total)
    }

    private var unavailableModels: Int {
        Set(zip(model.usage, estimates).compactMap { usage, estimate in
            estimate == .rateUnavailable ? usage.model : nil
        }).count
    }

    private func costDisplay(_ row: UsageRollup) -> String {
        guard let pricing = model.pricing else { return "Rate unavailable" }
        return switch pricing.estimate(row) {
        case .estimated(let amount): currency(amount)
        case .unmetered: "Unmetered"
        case .rateUnavailable: "Rate unavailable"
        }
    }

    private func currency(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).doubleValue.formatted(.currency(code: "USD"))
    }
}

private extension CostRange {
    var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .yearToDate: "Year to date"
        case .allTime: "All time"
        case .custom: "Custom"
        }
    }
}
