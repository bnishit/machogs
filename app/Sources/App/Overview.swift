import MachogsCore
import SwiftUI

enum MachogsPalette {
    static let rose = Color(red: 0.72, green: 0.25, blue: 0.39)
    static let calm = Color(red: 0.20, green: 0.49, blue: 0.44)
}

struct NowPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("THE DAILY CHECK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                    Spacer()
                    Label("On your Mac. For your eyes.", systemImage: "lock")
                        .font(.caption)
                }.foregroundStyle(.secondary)
                StatusHero(model: model)
                evidenceStrip
                if !model.groups.isEmpty { findings }
                if model.scanPresentation.protectedCount > 0 {
                    ProtectedWork(presentation: model.scanPresentation)
                }
                if let report = model.report {
                    DisclosureGroup {
                        HStack(spacing: 12) {
                            MetricCard(title: "Work level", value: String(format: "%.1f", report.host.load), detail: "across \(report.host.cores) CPU cores", symbol: "cpu")
                            MetricCard(title: "Disk-backed memory", value: "\(report.host.swapPercent)%", detail: "of allocated swap in use", symbol: "memorychip")
                            MetricCard(title: "Since restart", value: "\(report.host.uptimeDays)d", detail: "days", symbol: "clock")
                        }.padding(.top, 12)
                    } label: {
                        Label("Under the hood", systemImage: "slider.horizontal.3")
                            .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1050)
            .frame(maxWidth: .infinity)
        }
    }

    private var evidenceStrip: some View {
        HStack(spacing: 0) {
            evidence(value: model.report == nil ? "—" : String(model.scanPresentation.actionableCount), label: "TO REVIEW", symbol: "tray", tint: MachogsPalette.rose)
            Divider().frame(height: 36).padding(.horizontal, 22)
            evidence(value: model.report == nil ? "—" : String(model.scanPresentation.protectedCount), label: "LEFT ALONE", symbol: "lock.shield", tint: MachogsPalette.calm)
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 7) {
                Text(model.isStale ? "LAST GOOD CHECK" : "LAST CHECK")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    .foregroundStyle(.secondary)
                Text(model.lastSuccessfulScan?.formatted(date: .omitted, time: .shortened) ?? "Not checked")
                    .font(.callout.weight(.medium)).monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func evidence(value: String, label: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 27, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            }
        }
    }

    private var findings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Worth a look", systemImage: "magnifyingglass").font(.title3.weight(.semibold))
                Spacer()
                if model.groups.count > 1 {
                    Button("Review all \(model.scanPresentation.actionableCount)") {
                        Task { await model.requestProcessReview(model.groups) }
                    }.disabled(model.isStale || model.isScanning || model.isActing || model.isReviewing)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider() }
                    FindingRow(group: group, disabled: model.isStale || model.isScanning || model.isActing || model.isReviewing) {
                        Task { await model.requestProcessReview([group]) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct StatusHero: View {
    @ObservedObject var model: AppModel
    private var presentation: ScanPresentation { model.scanPresentation }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Label(statusLabel, systemImage: statusSymbol)
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                        .foregroundStyle(tint)
                    Text(presentation.title)
                        .font(.system(size: 35, weight: .semibold, design: .rounded))
                        .tracking(-1).fixedSize(horizontal: false, vertical: true)
                    Text(presentation.detail)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                }.frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().strokeBorder(tint.opacity(0.13), lineWidth: 1).frame(width: 128, height: 128)
                    Circle().fill(tint.opacity(0.045)).frame(width: 108, height: 108)
                    PigMascot(mood: mood, size: 86)
                }.accessibilityHidden(true)
            }
            HStack(spacing: 12) {
                Button { Task { await model.scan() } } label: {
                    HStack(spacing: 8) {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(model.isScanning ? "Checking…" : "Check my Mac")
                    }.padding(.vertical, 4).padding(.horizontal, 5)
                }
                .buttonStyle(.borderedProminent).tint(tint)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanning || model.isActing)
                Text("Nothing closes during a check.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }

    private var tint: Color {
        switch presentation.state {
        case .unavailable, .stale, .memoryPressure: return .orange
        case .actionable: return model.hasHotFinding ? .red : MachogsPalette.rose
        case .protectedWork: return presentation.protectedIsBusy ? .orange : MachogsPalette.rose
        default: return MachogsPalette.calm
        }
    }
    private var statusLabel: String {
        switch presentation.state {
        case .initial, .checking, .refreshing: return "LOOKING, NOT TOUCHING"
        case .unavailable, .stale: return "CHECK NEEDED"
        case .memoryPressure: return "MEMORY NEEDS ATTENTION"
        case .actionable: return "SOMETHING TO REVIEW"
        case .protectedWork: return "YOUR WORK COMES FIRST"
        case .quiet: return "CHECK COMPLETE"
        }
    }
    private var statusSymbol: String {
        switch presentation.state {
        case .unavailable, .stale, .memoryPressure: return "exclamationmark.circle"
        case .initial, .checking, .refreshing: return "viewfinder"
        case .actionable: return "magnifyingglass"
        case .protectedWork: return "lock.shield"
        case .quiet: return "checkmark.circle"
        }
    }
    private var mood: PigMood {
        if model.isScanning || model.report == nil { return .sniffing }
        if model.scanError != nil || model.hasSwapPressure || model.hasHotFinding || presentation.protectedIsBusy { return .concerned }
        return model.groups.isEmpty ? .pleased : .curious
    }
}

struct ProtectedWork: View {
    let presentation: ScanPresentation
    private var owners: [(name: String, count: Int, cpu: Double)] {
        Dictionary(grouping: presentation.protectedFindings, by: { $0.owner.isEmpty ? "Protected work" : $0.owner })
            .map { (name: $0.key, count: $0.value.count, cpu: $0.value.reduce(0) { $0 + $1.cpu }) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(owners, id: \.name) { owner in
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill").foregroundStyle(MachogsPalette.calm)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(owner.name).font(.callout.weight(.semibold))
                            Text("\(owner.count) background item\(owner.count == 1 ? "" : "s") kept running")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f%% CPU", owner.cpu))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Text("These findings belong to protected work. Machogs does not offer to close them. CPU is a snapshot, not a verdict that something is wrong.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").font(.title3).foregroundStyle(MachogsPalette.calm)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Work we’re leaving alone").font(.headline)
                    Text("\(presentation.protectedCount) protected item\(presentation.protectedCount == 1 ? "" : "s") · View by app")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
