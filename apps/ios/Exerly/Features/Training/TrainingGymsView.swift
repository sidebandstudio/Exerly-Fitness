import ExerlyCore
import SwiftUI

struct TrainingGymsView: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    @EnvironmentObject private var auth: AuthViewModel
    @State private var creating = false
    @State private var editing: GymProfile?
    @State private var error: String?
    @State private var showArchived = false

    var body: some View {
        ExScreen {
            if let current = workspace.gyms.active {
                ExCard(accent: true) {
                    ExEyebrow("Training here", color: .exPrimaryText)
                    Text(current.name).font(.exH1).accessibilityIdentifier("gyms.currentName")
                    Text(summary(current)).font(.exBody).foregroundStyle(Color.exTextSecondary)
                    Text("Workout targets use this gym's equipment settings. Your existing programs and logged sets stay saved.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    Button("Edit current gym") { editing = current }
                        .buttonStyle(ExActionStyle(secondary: true)).accessibilityIdentifier("gyms.editCurrent")
                    archiveButton(current)
                }
            } else {
                ExEmptyState(icon: "building.2", title: "Make workouts fit your gym",
                             message: "Save the equipment and weights you have. Choose a gym when you're ready to use it.",
                             action: "Add a gym", actionID: "gyms.addFirst") { creating = true }
            }
            let visible = workspace.gyms.gyms.filter {
                showArchived ? $0.archivedAt != nil : $0.archivedAt == nil && $0.id != workspace.gyms.active?.id
            }
            if !visible.isEmpty {
                ExSectionHeading(showArchived ? "Archived gyms" : "Your places", detail: "\(visible.count)")
                ForEach(visible) { gym in
                    ExCard {
                        Text(gym.name).font(.exH2)
                        Text(summary(gym)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        Button(gym.archivedAt == nil ? "Use this gym" : "Restore & use") { activate(gym) }
                            .buttonStyle(ExActionStyle(secondary: true))
                            .accessibilityIdentifier("gyms.use.\(gym.id.uuidString)")
                        Button("Edit equipment & weights") { editing = gym }
                            .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("gyms.edit.\(gym.id.uuidString)")
                        if gym.archivedAt == nil {
                            archiveButton(gym)
                        }
                    }
                }
            }
            if showArchived || workspace.gyms.gyms.contains(where: { $0.archivedAt != nil }) {
                Toggle("Show archived gyms", isOn: $showArchived).tint(Color.exPrimary)
                    .accessibilityIdentifier("gyms.showArchived")
            }
            if let error { Text(error).font(.exBody).foregroundStyle(Color.exError) }
            Text("Weights you haven't listed use standard increments. Archiving keeps the profile so you can restore it later.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .navigationTitle("Gyms & equipment").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") { creating = true }
                    .accessibilityLabel("Add gym").accessibilityIdentifier("gyms.add")
            }
        }
        .sheet(isPresented: $creating) { NavigationStack { GymEditorView(workspace: workspace, unit: unit, ownerIsActive: ownerCheck()) } }
        .sheet(item: $editing) { gym in NavigationStack { GymEditorView(workspace: workspace, unit: unit, gym: gym, ownerIsActive: ownerCheck()) } }
    }

    private func summary(_ gym: GymProfile) -> String {
        let count = gym.equipment.filter { $0 != .bodyweight }.count
        let loads = gym.loads.filter { gym.equipment.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        let barsAndPlates = gym.equipment.contains(.barbell) ? gym.bars.count + gym.plates.count : 0
        return count == 0 ? "Bodyweight training" : "\(count) equipment types · \(loads + barsAndPlates) listed weights"
    }
    private func archiveButton(_ gym: GymProfile) -> some View {
        Button("Archive gym") { archive(gym) }
            .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("gyms.archive.\(gym.id.uuidString)")
    }
    private func activate(_ gym: GymProfile) {
        guard ownerCheck()() else { return }
        do { try workspace.gyms.activate(gym.id); error = nil; Task { await workspace.synchronize() } } catch { self.error = "The gym could not be selected. Try again." }
    }
    private func archive(_ gym: GymProfile) {
        guard ownerCheck()() else { return }
        do { try workspace.gyms.archive(gym.id); error = nil; Task { await workspace.synchronize() } } catch { self.error = "The gym could not be archived. Try again." }
    }
    private func ownerCheck() -> () -> Bool {
        let sessionID = auth.sessionID
        let accountID = workspace.accountID
        return { [weak auth] in auth?.currentUser?.id == accountID && auth?.sessionID == sessionID }
    }
}

private struct GymEditorView: View {
    let workspace: TrainingWorkspace
    let unit: MassUnit
    @StateObject private var model: GymEditorModel
    @State private var weights: GymWeightDestination?
    @State private var moreEquipment = false
    @FocusState private var editingName: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, unit: MassUnit, gym: GymProfile? = nil, ownerIsActive: @escaping () -> Bool) {
        self.workspace = workspace
        self.unit = unit
        _model = StateObject(wrappedValue: GymEditorModel(store: workspace.gyms, unit: unit, gym: gym, ownerIsActive: ownerIsActive))
    }

    private let common: [ExerlyCore.Equipment] = [.dumbbell, .flatBench, .barbell, .rack, .cable, .machine, .pullUpBar, .resistanceBand]
    private let loadable: [ExerlyCore.Equipment] = [.dumbbell, .kettlebell, .cable, .machine, .smithMachine, .ezBar, .trapBar, .medicineBall, .weightPlate]

    var body: some View {
        ExScreen {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ExEyebrow("Your equipment", color: .exPrimaryText)
                Text("Where do you train?").font(.exH1)
                Text("Start with what you have. Add the exact weights whenever you're ready.")
                    .font(.exBody).foregroundStyle(Color.exTextSecondary)
            }
            ExCard {
                Text("Gym name").font(.exLabel)
                TextField("Home, campus, or your gym", text: $model.draft.name)
                    .focused($editingName).submitLabel(.done).onSubmit { editingName = false }
                    .font(.exBody).padding(ExSpacing.content).background(Color.exSurface2, in: RoundedRectangle(cornerRadius: ExRadius.control))
                    .accessibilityLabel("Gym name").accessibilityIdentifier("gym.name")
                Text("Bodyweight exercises are always available.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
            VStack(alignment: .leading, spacing: ExSpacing.item) {
                ExSectionHeading("Equipment you have")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: ExSpacing.small) {
                    ForEach(common, id: \.self) { equipmentButton($0) }
                }
                Button(moreEquipment ? "Hide more equipment" : "More equipment") { moreEquipment.toggle() }
                    .font(.exBodyMedium).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
                    .accessibilityIdentifier("gym.moreEquipment")
                if moreEquipment {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: ExSpacing.small) {
                        ForEach(ExerlyCore.Equipment.allCases.filter { !common.contains($0) && $0 != .bodyweight }, id: \.self) { equipmentButton($0) }
                    }
                }
            }
            if model.draft.equipment.contains(.barbell) || loadable.contains(where: model.draft.equipment.contains) {
                ExCard {
                    ExSectionHeading("Available weights", detail: "Optional")
                    Text("List the weights on your rack or stack. We use standard jumps until you add them.")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    if model.draft.equipment.contains(.barbell) {
                        inventoryLink(.bars, detail: model.draft.bars.map { $0.description }.joined(separator: ", "))
                        inventoryLink(.plates, detail: "\(model.draft.plates.count) plate sizes")
                    }
                    ForEach(loadable.filter(model.draft.equipment.contains), id: \.self) { equipment in
                        let count = model.draft.loads[equipment]?.count ?? 0
                        inventoryLink(.loads(equipment), detail: count == 0 ? "Standard increments" : "\(count) weights listed")
                    }
                }
            }
            Text("Saving keeps this profile. Choose Use this gym from your places to make it current.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .scrollDismissesKeyboard(.interactively)
        .exFooter {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                if let error = model.error {
                    Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("gym.error")
                }
                Button("Save gym") {
                    if model.save() { Task { await workspace.synchronize() }; dismiss() }
                }.buttonStyle(ExActionStyle()).accessibilityIdentifier("gym.save")
            }.padding(ExSpacing.page).background(Color.exBackground)
        }
        .navigationTitle("Gym details").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("gym.cancel") }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Hide keyboard") { editingName = false }
            }
        }
        .sheet(item: $weights) { destination in
            NavigationStack { GymWeightsView(model: model, destination: destination, initialUnit: unit) }
        }
    }

    private func equipmentButton(_ equipment: ExerlyCore.Equipment) -> some View {
        let selected = model.draft.equipment.contains(equipment)
        return Button {
            if selected { model.draft.equipment.removeAll { $0 == equipment } } else { model.draft.equipment.append(equipment) }
        } label: {
            HStack(alignment: .top, spacing: ExSpacing.small) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).accessibilityHidden(true)
                Text(TrainingFormat.words(equipment.rawValue)).font(.exLabel).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(ExSpacing.content).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .foregroundStyle(selected ? Color.exPrimaryText : Color.exTextPrimary)
                .background(selected ? Color.exPrimary.opacity(0.12) : Color.exSurface1, in: RoundedRectangle(cornerRadius: ExRadius.control))
                .overlay(RoundedRectangle(cornerRadius: ExRadius.control).stroke(selected ? Color.exPrimary.opacity(0.6) : Color.exBorder, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("gym.equipment.\(equipment.rawValue)")
    }

    private func inventoryLink(_ destination: GymWeightDestination, detail: String) -> some View {
        Button { model.clearError(); weights = destination } label: {
            ExNavigationLabel(title: destination.title, icon: destination == .plates ? "circle.circle" : "dumbbell", detail: detail)
        }.buttonStyle(.plain).accessibilityIdentifier("gym.weights.\(destination.id)")
    }
}

private struct GymWeightsView: View {
    @ObservedObject var model: GymEditorModel
    let destination: GymWeightDestination
    @State private var unit: MassUnit
    @State private var value = ""
    @State private var pairs = 1
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: GymEditorModel, destination: GymWeightDestination, initialUnit: MassUnit) {
        self.model = model
        self.destination = destination
        _unit = State(initialValue: initialUnit)
    }

    private var weights: [Mass] {
        switch destination {
        case .bars: model.draft.bars
        case .plates: model.draft.plates.map(\.weight)
        case .loads(let equipment): model.draft.loads[equipment] ?? []
        }
    }

    var body: some View {
        ExScreen {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                Text(destination == .plates ? "Count matching pairs" : "What weights do you have?").font(.exH1)
                Text(explanation).font(.exBody).foregroundStyle(Color.exTextSecondary)
            }
            ExCard {
                ExChoiceChips(values: Array(MassUnit.allCases.reversed()), selection: $unit) { $0.rawValue }
                    .accessibilityIdentifier("gym.weightUnit")
                NutritionNumberInput(title: "Weight (\(unit.rawValue))", text: $value, identifier: "gym.weightValue", placeholder: "Enter weight")
                if destination == .plates {
                    Stepper("\(pairs) \(pairs == 1 ? "pair" : "pairs")", value: $pairs, in: 1...50)
                        .font(.exBody).accessibilityIdentifier("gym.newPairs")
                }
                if let error = model.error { Text(error).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("gym.weightError") }
                Button("Add weight") {
                    if model.addWeight(value, unit: unit, to: destination, pairs: pairs) { value = "" }
                }.buttonStyle(ExActionStyle()).accessibilityIdentifier("gym.addWeight")
            }
            if weights.isEmpty {
                ExCard {
                    Text("No weights listed yet").font(.exH2)
                    Text("Add a weight above. Without a list, workout targets use standard increments.")
                        .font(.exBody).foregroundStyle(Color.exTextSecondary)
                }
            } else {
                ExSectionHeading("Your inventory", detail: "\(weights.count) listed")
                ExCard {
                    ForEach(Array(weights.enumerated()), id: \.offset) { index, weight in
                        if index > 0 { Divider().overlay(Color.exBorder.opacity(0.3)) }
                        HStack(alignment: .firstTextBaseline) {
                            Text(weight.description).font(.exBodyMedium).accessibilityIdentifier("gym.inventory.\(index)")
                            Spacer()
                            Button { remove(index) } label: { Image(systemName: "minus.circle").font(.exBody) }
                                .frame(minWidth: 44, minHeight: 44).foregroundStyle(Color.exPrimaryText)
                                .accessibilityLabel("Remove \(weight.description)").accessibilityIdentifier("gym.removeWeight.\(index)")
                        }
                        if destination == .plates {
                            Stepper("\(model.draft.plates[index].pairs) matching pairs", value: $model.draft.plates[index].pairs, in: 0...50)
                                .font(.exBody).accessibilityIdentifier("gym.pairs.\(index)")
                        }
                        if destination == .bars {
                            if index == 0 {
                                Label("Usual bar", systemImage: "checkmark.circle.fill").font(.exCaption).foregroundStyle(Color.exPrimaryText)
                            } else {
                                Button("Make usual bar") { model.draft.bars.insert(model.draft.bars.remove(at: index), at: 0) }
                                    .font(.exBodyMedium).frame(minHeight: 44).foregroundStyle(Color.exPrimaryText)
                            }
                        }
                    }
                }
            }
            Text("Changes are saved when you tap Save gym. Each weight keeps its own unit.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .navigationTitle(destination.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.clearError(); dismiss() }.accessibilityIdentifier("gym.weightsDone") } }
    }

    private var explanation: String {
        switch destination {
        case .plates: "One pair is two plates of the same weight, one on each side of the bar. Set a pair count to zero when those plates are unavailable."
        case .bars: "Put your usual bar first. It supplies the minimum weight for barbell targets."
        case .loads(.dumbbell): "Enter the weight of one dumbbell, as printed on it. List each size once."
        case .loads: "Enter each available weight as marked on your equipment. List each size once."
        }
    }

    private func remove(_ index: Int) {
        switch destination {
        case .bars: model.draft.bars.remove(at: index)
        case .plates: model.draft.plates.remove(at: index)
        case .loads(let equipment): model.draft.loads[equipment]?.remove(at: index)
        }
    }
}
