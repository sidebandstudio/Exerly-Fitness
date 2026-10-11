import ExerlyCore
import SwiftUI

enum ProgressTab: String, CaseIterable {
    case measurements = "Measurements"
    case nutrition = "Nutrition"
    case training = "Training"
    case photos = "Photos"

    var title: String {
        switch self {
        case .measurements: "Body"
        case .nutrition: "Nutrition"
        case .training: "Training"
        case .photos: "Photos"
        }
    }
}

struct ProgressView_: View {
    let initialDate: CalendarDay
    @State private var selectedTab: ProgressTab = .measurements
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    /// The signed-in account's ExerlyCore data, where weigh-ins live.
    private var workspace: TrainingWorkspace? {
        guard let workspace = account.training, workspace.accountID == auth.currentUser?.id else { return nil }
        return workspace
    }
    private var unit: MassUnit { auth.currentUser?.unitSystem == "metric" ? .kilograms : .pounds }
    private var timeZone: TimeZone { TimeZone(identifier: auth.currentUser?.timezone ?? "UTC") ?? .gmt }

    var body: some View {
        // A bar, not a row above the content: each tab scrolls under it, inset
        // to start below it, instead of being cut off at its edge.
        tabContent
            // A hard edge, so text scrolling under the picker doesn't show through blurred.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .safeAreaBar(edge: .top) { tabPicker }
            .background(Color.exBackground)
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var tabPicker: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Menu {
                    Picker("Progress view", selection: $selectedTab) {
                        ForEach(ProgressTab.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack {
                        Text(selectedTab.title).font(.exBodyMedium)
                        Spacer()
                        Image(systemName: "chevron.down").font(.exCaption)
                    }.foregroundStyle(Color.exTextPrimary).padding(ExSpacing.item)
                        .background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                }.accessibilityLabel("Progress view, \(selectedTab.title)").accessibilityIdentifier("progress.section")
            } else {
                ExSegmentedControl(values: ProgressTab.allCases, selection: $selectedTab) { $0.title }
            }
        }.padding(.horizontal, ExSpacing.page).padding(.vertical, ExSpacing.small)
            .accessibilityElement(children: .contain).accessibilityIdentifier("progress.sections")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .measurements:
            MeasurementsTab(initialDate: initialDate, workspace: workspace, unit: unit, timeZone: timeZone,
                            openingError: account.openingError)
        case .nutrition: NutritionInsightsView(workspace: workspace, unit: unit, timeZone: timeZone)
        case .training: TrainingInsightsView(workspace: workspace, unit: unit, timeZone: timeZone)
        case .photos: PhotosTab(workspace: workspace, unit: unit, timeZone: timeZone)
        }
    }
}
