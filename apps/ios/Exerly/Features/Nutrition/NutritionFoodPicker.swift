import ExerlyCore
import SwiftUI

/// How the food picker is shown. As a sheet it closes after a portion is
/// logged; as the root of the search tab it stays and confirms each log.
enum FoodPickerPresentation { case sheet, tab }

/// The amount a food picked for a recipe or a meal arrives at.
enum FoodPickAmount {
    /// The amount the person logs it at, or its default when they never have.
    case usual
    /// One they just chose in the portion step.
    case chosen(LoggedAmount, FoodSnapshot)
    /// Its default, which they left without choosing; it stays marked until checked.
    case unchecked
}

struct NutritionFoodPicker: View {
    let workspace: TrainingWorkspace
    let api: AccountAPI
    let date: LocalDate
    let timeZone: TimeZone
    let unit: MassUnit
    @ObservedObject var actions: NutritionDiaryActions
    let onLogged: () -> Void
    let onPick: ((ExerlyCore.Food, FoodPickAmount) -> Int?)?
    let pickError: () -> String?
    let presentation: FoodPickerPresentation
    /// What picked foods go into: a meal or a recipe.
    let pickingInto: String
    @StateObject private var search: NutritionSearchModel
    @State private var meal: String
    @State private var query = ""
    @State private var scope = FoodListScope.recent
    @State private var shelf = FoodShelf()
    @State private var selectedFood: ExerlyCore.Food?
    /// A picked food without a usual amount, whose amount is being asked,
    /// and how that step ended: nil while it's open or once swiped away.
    @State private var asking: ExerlyCore.Food?
    @State private var askedFood: ExerlyCore.Food?
    @State private var askOutcome: AskOutcome?
    @State private var createdFood: ExerlyCore.Food?
    @State private var creating = false
    @State private var creatingRecipe = false
    @State private var scanningLabel = false
    @State private var quickAdding = false
    @State private var buildingMeal = false
    @State private var showingBarcode: Bool
    @State private var pickedCount: Int
    @State private var addedIDs: Set<String>
    @State private var selectionError: String?
    @State private var sheetLogged: [FoodEntry]?
    @State private var confirmation: LoggedConfirmation?
    /// Entries logged from this screen, by the row that logged them. Their
    /// rows keep a check while the screen is open; tapping it removes them.
    @State private var justLogged: [String: [FoodEntry]] = [:]
    @State private var logError: String?
    @State private var loggedCount = 0
    @State private var openedOnce = false
    @FocusState private var searchFocused: Bool
    private let focusesSearch: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(workspace: TrainingWorkspace, api: AccountAPI, date: LocalDate, meal: String,
         timeZone: TimeZone, unit: MassUnit, actions: NutritionDiaryActions, onLogged: @escaping () -> Void,
         startsWithBarcode: Bool = false, pickedCount: Int = 0, pickedFoodIDs: Set<String> = [],
         onPick: ((ExerlyCore.Food, FoodPickAmount) -> Int?)? = nil,
         pickError: @escaping () -> String? = { nil }, presentation: FoodPickerPresentation = .sheet, pickingInto: String = "meal") {
        self.workspace = workspace
        self.api = api
        self.date = date
        self.timeZone = timeZone
        self.unit = unit
        self.actions = actions
        self.onLogged = onLogged
        self.onPick = onPick
        self.pickError = pickError
        self.presentation = presentation
        self.pickingInto = pickingInto
        // A sheet opened to search starts typing; one opened to scan doesn't.
        focusesSearch = presentation == .sheet && !startsWithBarcode
        _meal = State(initialValue: presentation == .tab ? workspace.nutrition.suggestedMeal(at: .now, timeZone: timeZone) : meal)
        _showingBarcode = State(initialValue: startsWithBarcode)
        _pickedCount = State(initialValue: pickedCount)
        _addedIDs = State(initialValue: pickedFoodIDs)
        _search = StateObject(wrappedValue: NutritionSearchModel(api: api))
    }

    var body: some View {
        NavigationStack {
            ExScreen {
                header
                if trimmedQuery.isEmpty { browsing } else { searching }
            }
            .scrollDismissesKeyboard(.immediately)
            .overlay(alignment: .bottom) { toast }
            .safeAreaInset(edge: .bottom) {
                if picking {
                    Button(pickedCount == 0 ? "Back to \(pickingInto)" : "Review \(pickingInto) · \(pickedCount) \(pickedCount == 1 ? "food" : "foods")") { dismiss() }
                        .buttonStyle(ExActionStyle()).accessibilityIdentifier("nutrition.reviewPlate")
                        .padding(ExSpacing.page).background(Color.exBackground)
                }
            }
            .navigationTitle(picking ? "Choose foods" : "Add food").navigationBarTitleDisplayMode(.inline)
            .modifier(FoodSearchField(text: $query, presentation: presentation))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { Task { await search.search(query) } }
            .onChange(of: query) { _, text in search.type(text) }
            .toolbar { toolbar }
            .sensoryFeedback(.success, trigger: loggedCount)
            .navigationDestination(isPresented: $showingBarcode) {
                NutritionBarcodeView(workspace: workspace, api: api, date: date, meal: meal,
                                     timeZone: timeZone, unit: unit, actions: actions,
                                     onPicked: picking ? { select($0) } : nil) { entry in
                    showingBarcode = false
                    finish([entry])
                }
            }
            .sheet(isPresented: $creating, onDismiss: openCreatedFood) {
                NutritionFoodEditor(workspace: workspace) { createdFood = $0 }
            }
            .sheet(isPresented: $creatingRecipe, onDismiss: openCreatedFood) {
                RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit) { createdFood = $0 }
            }
            .sheet(isPresented: $scanningLabel, onDismiss: openCreatedFood) {
                NutritionLabelCaptureView(workspace: workspace) { createdFood = $0 }
            }
            .sheet(isPresented: $buildingMeal, onDismiss: finishSheet) {
                NutritionPlateView(workspace: workspace, api: api, date: date, meal: meal,
                                   timeZone: timeZone, unit: unit, actions: actions, onLogged: {}) { sheetLogged = $0 }
            }
            .sheet(isPresented: $quickAdding, onDismiss: finishSheet) {
                NutritionQuickAddView(workspace: workspace, date: date, meal: meal, timeZone: timeZone, onLogged: {}) {
                    sheetLogged = [$0]
                }
            }
            .sheet(item: $selectedFood, onDismiss: finishSheet) { food in
                NutritionEntryEditor(workspace: workspace, food: food, date: date, meal: meal,
                                     timeZone: timeZone, unit: unit, actions: actions) { sheetLogged = (sheetLogged ?? []) + [$0] }
            }
            .sheet(item: $asking, onDismiss: finishAsking) { food in
                FoodPortionStep(store: store, food: food, unit: unit, title: "Add to \(pickingInto)", confirm: "Add", asking: true,
                                identifier: "nutrition.pickPortion", onCancel: { askOutcome = .cancelled },
                                onConfirm: { amount, snapshot in
                                    askOutcome = .added
                                    pick(food, .chosen(amount, snapshot))
                                })
            }
        }
        .onAppear(perform: refresh)
        .task {
            guard focusesSearch else { return }
            // Once the sheet has settled, so the field accepts focus.
            try? await Task.sleep(for: .milliseconds(350))
            searchFocused = true
        }
        .onDisappear { search.clear() }
    }

    // MARK: Layout

    private var picking: Bool { onPick != nil }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var store: NutritionStore { workspace.nutrition }

    @ViewBuilder private var header: some View {
        if picking {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                Text("Foods you've had come in at your usual amount. Others ask for one.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                if let selectionError { Text(selectionError).font(.exCaption).foregroundStyle(Color.exError) }
            }
        } else {
            VStack(alignment: .leading, spacing: ExSpacing.tight) {
                if date != LocalDate(.now, in: timeZone) {
                    Label("Logging to \(NutritionFormat.day(date, timeZone: timeZone))", systemImage: "calendar")
                        .font(.exCaption.weight(.medium)).foregroundStyle(Color.exPrimaryText)
                        .accessibilityIdentifier("nutrition.pickerDate")
                }
                FoodMealSelector(meals: meals, selection: $meal)
            }
        }
        if let logError {
            Text(logError).font(.exCaption).foregroundStyle(Color.exError).accessibilityIdentifier("nutrition.logError")
        }
    }

    @ViewBuilder private var browsing: some View {
        if typeSize.isAccessibilitySize {
            // At the largest sizes the foods come first: Barcode and a compact
            // list choice above them, the other tools below.
            barcodeButton
            scopeMenu
        } else {
            HStack(spacing: ExSpacing.small) { toolButtons }
            ExSegmentedControl(values: FoodListScope.allCases, selection: $scope) { $0.title }
                .accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.listScope")
        }
        scopeContent
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                ExEyebrow("More ways to log")
                otherTools
            }.padding(.top, ExSpacing.small)
        }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Show", selection: $scope) {
                ForEach(FoodListScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            HStack {
                Text("Showing \(scope.title)").font(.exBodyMedium).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.exCaption)
            }.foregroundStyle(Color.exPrimaryText).frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("nutrition.listScope")
    }

    @ViewBuilder private var scopeContent: some View {
        switch scope {
        case .recent:
            if shelf.suggested.isEmpty && shelf.recent.isEmpty {
                emptyMessage("Your foods come back here", "Search, scan or quick add your first food. Next time it's one tap away, with the amount you had.")
            } else {
                if !shelf.suggested.isEmpty {
                    group(shelf.hasRecipes ? "Usual for \(meal.lowercased())" : suggestedTitle, shelf.suggested, id: "suggested",
                          hideable: true)
                }
                if !shelf.recent.isEmpty { group("Recent", shelf.recent, id: "recent") }
            }
        case .favorites:
            let favorites = savedItems { $0.favorite }
            if favorites.isEmpty {
                emptyMessage("No favorites yet", "Open any food and tap the star to keep it here.")
            } else { group("Favorites", favorites, id: "favorites") }
        case .mine:
            let mine = savedItems { _ in true }
            Button { creating = true } label: {
                Label("Create a food", systemImage: "plus").font(.exLabel)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.exPrimaryText).accessibilityIdentifier("nutrition.createFoodRow")
            if !picking {
                Button { creatingRecipe = true } label: {
                    Label("Create a recipe", systemImage: "plus").font(.exLabel)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(Color.exPrimaryText).accessibilityIdentifier("nutrition.createRecipeRow")
                    .padding(.top, -ExSpacing.page) // One group with "Create a food", without the screen's spacing.
            }
            if mine.isEmpty {
                emptyMessage("Nothing saved yet", "Foods you create, recipes, and foods you star are kept here, ready offline.")
            } else { group("Saved foods", mine, id: "mine") }
        }
    }

    @ViewBuilder private var searching: some View {
        let local = localMatches
        if !local.isEmpty { group("Your foods", local, id: "local") }
        databaseSection(excluding: Set(local.map(\.id)))
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            ExEyebrow("Can't find it?")
            if typeSize.isAccessibilitySize {
                barcodeButton
                otherTools
            } else {
                HStack(spacing: ExSpacing.small) { toolButtons }
            }
        }.padding(.top, ExSpacing.small)
    }

    @ViewBuilder private var toolButtons: some View {
        barcodeButton
        otherTools
    }

    private var barcodeButton: some View {
        FoodToolButton(title: typeSize.isAccessibilitySize ? "Scan barcode" : "Barcode", icon: "barcode.viewfinder",
                       identifier: picking ? "nutrition.plateBarcode" : "nutrition.barcode") {
            hideKeyboard(); showingBarcode = true
        }.accessibilityLabel("Scan barcode")
    }

    @ViewBuilder private var otherTools: some View {
        FoodToolButton(title: "Label", icon: "text.viewfinder", identifier: "nutrition.scanLabel") {
            hideKeyboard(); scanningLabel = true
        }.accessibilityLabel("Scan nutrition label")
        if !picking {
            FoodToolButton(title: "Quick add", icon: "bolt.fill", identifier: "nutrition.quickAdd") {
                hideKeyboard(); quickAdding = true
            }.accessibilityLabel("Quick add calories and macros")
        }
        FoodToolButton(title: "New food", icon: "square.and.pencil", identifier: "nutrition.createFood") {
            hideKeyboard(); creating = true
        }.accessibilityLabel("Enter a food manually")
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if presentation == .sheet {
            ToolbarItem(placement: .cancellationAction) {
                Button(confirmation != nil || loggedCount > 0 ? "Done" : "Cancel") { search.close(); dismiss() }
                    .accessibilityIdentifier("nutrition.closePicker")
            }
        }
        if !picking {
            ToolbarItem(placement: .primaryAction) {
                Menu("More ways to log", systemImage: "ellipsis") {
                    // A meal is logged once; a recipe is kept to log again.
                    Button { buildingMeal = true } label: {
                        Label("Log a meal", systemImage: "plus.rectangle.on.rectangle")
                        Text("Several foods at once, logged now")
                    }.accessibilityIdentifier("nutrition.buildMeal")
                    Button { creatingRecipe = true } label: {
                        Label("Create a recipe", systemImage: "frying.pan")
                        Text("Kept to log by serving or weight")
                    }.accessibilityIdentifier("nutrition.newRecipe")
                }.accessibilityIdentifier("nutrition.moreFoodOptions")
            }
        }
    }

    @ViewBuilder private func databaseSection(excluding local: Set<String>) -> some View {
        let foods = (search.result?.foods ?? []).filter { !local.contains($0.id) }
        let items = foods.compactMap { food in store.quickPortion(for: food, unit: unit).map { FoodPickerItem(portion: $0, food: food) } }
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            HStack(spacing: ExSpacing.small) {
                ExEyebrow("Food database")
                if search.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Searching the food database") }
                Spacer(minLength: 0)
            }
            if let error = search.error {
                ExCard {
                    Text(error).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    Button("Try again") { Task { await search.search(query) } }.font(.exLabel).frame(minHeight: 44)
                        .accessibilityIdentifier("nutrition.retrySearch")
                }
            } else if !items.isEmpty {
                ExCard { rows(items) }.accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.databaseResults")
                if let attribution = search.result?.attribution {
                    Text(attribution).font(.exSmall).foregroundStyle(Color.exTextMuted)
                }
                Link("Open Food Facts · Open Database License", destination: URL(string: "https://world.openfoodfacts.org/data")!)
                    .font(.exSmall)
            } else if search.shownQuery == trimmedQuery, !search.isLoading {
                Text("No database foods matched “\(trimmedQuery)”. Try another name, or scan the package.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            } else if trimmedQuery.count < NutritionSearchModel.typeAheadMinimum, !search.isLoading {
                Text("Keep typing to search the food database.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    /// Foods under a heading. Suggested ones (`hideable`) can be hidden from
    /// suggestions with a long press.
    private func group(_ title: String, _ items: [FoodPickerItem], id: String, hideable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            ExEyebrow(title).accessibilityAddTraits(.isHeader)
            ExCard { rows(items, hideable: hideable) }.accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.group.\(id)")
        }
    }

    @ViewBuilder private func rows(_ items: [FoodPickerItem], hideable: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                if hideable {
                    row(item)
                        .background(Color.exSurface1)
                        .contextMenu {
                            Button("Don't suggest this", systemImage: "eye.slash") { hide(item) }
                                .accessibilityIdentifier("nutrition.hideSuggestion")
                        }
                        .accessibilityAction(named: "Don't suggest this") { hide(item) }
                } else { row(item) }
                if item.id != items.last?.id { Divider().overlay(Color.exBorder.opacity(0.35)) }
            }
        }.padding(.vertical, -6)
    }

    private func row(_ item: FoodPickerItem) -> some View {
        let portion = FoodFormat.portion(item.portion, unit: unit)
        let detail = [portion, FoodFormat.origin(of: item.portion.food)].compactMap { $0 }.joined(separator: " · ")
        let logged = !picking && justLogged[item.id] != nil
        let name = item.portion.food.name
        return FoodQuickRow(name: name, detail: detail, amounts: item.portion.nutrients,
                            openHint: picking ? "Adds it to the \(pickingInto)" : "Opens the portion to adjust it",
                            openIdentifier: "nutrition.\(picking ? "platePick" : "food").\(item.id)",
                            open: { hideKeyboard(); if picking { select(item.food) } else { selectedFood = item.food } },
                            add: FoodAddButton(done: picking ? addedIDs.contains(item.id) : logged,
                                               label: picking ? "Add \(name) to the \(pickingInto)" : logged ? "Logged \(name). Undo" : "Log \(portion) of \(name) to \(meal)",
                                               identifier: "nutrition.\(picking ? "plateAdd" : "quickLog").\(item.id)") {
                                if picking { select(item.food) } else if logged { unlog(item) } else { quickLog(item) }
                            })
    }

    private func emptyMessage(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            Text(title).font(.exH3).foregroundStyle(Color.exTextPrimary)
            Text(message).font(.exBody).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, ExSpacing.small).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var toast: some View {
        if let confirmation {
            FoodLoggedToast(title: confirmation.title, detail: confirmation.detail) { undo(confirmation) }
                // In the search tab the field floats above the keyboard,
                // outside the safe area; the confirmation sits above it.
                .padding(.bottom, presentation == .tab && searchFocused ? FoodLoggedToast.searchFieldClearance : ExSpacing.small)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(confirmation.id)
                .task(id: confirmation.id) {
                    // Long enough to reach Undo, longer still with VoiceOver.
                    try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 12 : 6))
                    guard !Task.isCancelled else { return }
                    withAnimation(.snappy) { if self.confirmation?.id == confirmation.id { self.confirmation = nil } }
                }
        }
    }

    // MARK: Lists

    private var meals: [String] {
        NutritionStore.defaultMeals.contains(meal) ? NutritionStore.defaultMeals : NutritionStore.defaultMeals + [meal]
    }

    /// "Usual around 7 AM"; late at night, when an hour reads oddly, "Usual around now".
    private var suggestedTitle: String {
        NutritionStore.isLateNight(.now, timeZone: timeZone) ? "Usual around now"
            : "Usual around \(Date.now.formatted(Date.FormatStyle(timeZone: timeZone).hour()))"
    }

    /// Recent and suggested foods are fixed when the screen opens, so rows
    /// don't move under a finger as foods are logged.
    private func refresh() {
        if presentation == .tab { meal = store.suggestedMeal(at: .now, timeZone: timeZone) }
        let suggested = store.suggestions(at: .now, timeZone: timeZone, limit: 5)
            .filter { $0.food.unweighed != true }
            .map { suggestion in
                FoodPickerItem(portion: QuickPortion(suggestion),
                               food: store.food(suggestion.food.foodID) ?? suggestion.food.foodForLogging(serving: suggestion.serving))
            }
        // Recipes made from this meal, such as one saved from it, come first.
        let recipes = store.recipes(for: meal, through: date).compactMap { food in
            store.quickPortion(for: food, unit: unit).map { FoodPickerItem(portion: $0, food: food) }
        }
        let shelved = recipes + suggested.filter { item in !recipes.contains { $0.id == item.id } }
        let suggestedIDs = Set(shelved.map(\.id))
        let recent = store.recentPortions(limit: 30).filter { !suggestedIDs.contains($0.id) }.map(item)
        shelf = FoodShelf(suggested: shelved, recent: recent, hasRecipes: !recipes.isEmpty)
        // Checks stay only for entries still logged on this day.
        justLogged = justLogged.compactMapValues { entries in
            let kept = entries.filter { entry in entry.date == date && store.entries.contains { $0.id == entry.id } }
            return kept.isEmpty ? nil : kept
        }
        // With nothing logged yet, open on the foods already saved.
        if !openedOnce {
            openedOnce = true
            if suggested.isEmpty && recent.isEmpty && store.foods.contains(where: { $0.archivedAt == nil }) { scope = .mine }
        }
        // Results are dropped while the screen is away; bring back the ones
        // for a search still typed (from the cache when they were fetched).
        if !trimmedQuery.isEmpty { search.type(query) }
    }

    private func item(_ portion: QuickPortion) -> FoodPickerItem {
        FoodPickerItem(portion: portion, food: store.food(portion.id) ?? portion.food.foodForLogging(serving: portion.serving))
    }

    private func savedItems(_ include: (ExerlyCore.Food) -> Bool) -> [FoodPickerItem] {
        store.foods.filter { $0.archivedAt == nil && include($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .compactMap { food in store.quickPortion(for: food, unit: unit).map { FoodPickerItem(portion: $0, food: food) } }
    }

    /// Foods already on this device that match the search (see
    /// `FoodSearch`): history first, then saved foods. They need no connection.
    private var localMatches: [FoodPickerItem] {
        var seen = Set<String>()
        let foods = (store.recentPortions(limit: 200).map(item) + savedItems { _ in true }).filter { seen.insert($0.id).inserted }
        return FoodSearch.matching(foods, query: trimmedQuery) { "\($0.portion.food.name) \($0.portion.food.brand ?? "")" }
            .prefix(12).map { $0 }
    }

    // MARK: Actions

    private func quickLog(_ item: FoodPickerItem) {
        logError = nil
        do {
            let entry = try store.log(item.portion, on: date, meal: meal)
            confirm([entry])
            onLogged()
            Task { await workspace.synchronize() }
        } catch {
            logError = "Couldn't log \(item.portion.food.name). Nothing was saved. Open it to check the portion."
        }
    }

    /// Shows "Logged · Undo". The haptic is skipped when the sheet that
    /// logged the food already gave one.
    private func confirm(_ entries: [FoodEntry], haptic: Bool = true) {
        guard let first = entries.first else { return }
        let energy = entries.reduce(0) { $0 + $1.nutrients.energy }
        var detail = "\(FoodFormat.kcal(energy)) kcal · \(first.meal)"
        if first.date != LocalDate(.now, in: timeZone) { detail += ", \(NutritionFormat.day(first.date, timeZone: timeZone))" }
        if let left = store.progress(on: first.date).energy.remaining { detail += " · \(FoodFormat.kcal(left)) left" }
        let title = entries.count == 1 ? "Logged \(first.food.name)" : "Logged \(entries.count) foods"
        if haptic { loggedCount += 1 }
        withAnimation(.snappy) {
            confirmation = LoggedConfirmation(entries: entries, title: title, detail: detail)
            for entry in entries { justLogged[entry.food.foodID, default: []].append(entry) }
        }
        showInRecent(entries)
        UIAccessibility.post(notification: .announcement, argument: "\(title). \(detail)")
    }

    /// A food logged from search joins Recent at once. Foods already listed
    /// keep their place, so rows don't move under a finger.
    private func showInRecent(_ entries: [FoodEntry]) {
        let listed = Set((shelf.suggested + shelf.recent).map(\.id))
        let logged = Set(entries.map(\.food.foodID))
        let added = store.recentPortions(limit: 30).filter { logged.contains($0.id) && !listed.contains($0.id) }.map(item)
        shelf.recent.insert(contentsOf: added, at: 0)
    }

    /// A second tap on a logged row removes what it logged.
    private func unlog(_ item: FoodPickerItem) {
        guard let entries = justLogged[item.id] else { return }
        logError = nil
        let removed = remove(entries)
        withAnimation(.snappy) {
            justLogged[item.id] = nil
            if let confirmation, confirmation.entries.allSatisfy({ entries.contains($0) }) { self.confirmation = nil }
        }
        if removed {
            UISelectionFeedbackGenerator().selectionChanged()
            UIAccessibility.post(notification: .announcement, argument: "Removed \(item.portion.food.name)")
        }
        Task { await workspace.synchronize() }
    }

    /// Deletes entries as they were logged; one changed since is left alone.
    @discardableResult private func remove(_ entries: [FoodEntry]) -> Bool {
        let current = entries.filter { entry in store.entries.first { $0.id == entry.id } == entry }
        do {
            for entry in current { try store.deleteEntry(entry.id) }
            if current.count < entries.count {
                logError = "Some of these entries changed after logging. Review them in today's log."
            }
            return !current.isEmpty
        } catch {
            logError = "Couldn't undo. The food is still logged; remove it from today's log."
            return false
        }
    }

    /// "Don't suggest this": the row goes, and Undo brings it back.
    private func hide(_ item: FoodPickerItem) {
        guard let index = shelf.suggested.firstIndex(where: { $0.id == item.id }) else { return }
        logError = nil
        do {
            try store.hideSuggestion(item.portion.food)
            let title = "Won't suggest \(item.portion.food.name)"
            withAnimation(.snappy) {
                shelf.suggested.remove(at: index)
                confirmation = LoggedConfirmation(entries: [], title: title, detail: "Food library can suggest it again",
                                                  hidden: (item, index))
            }
            UIAccessibility.post(notification: .announcement, argument: title)
            Task { await workspace.synchronize() }
        } catch { logError = "Couldn't hide \(item.portion.food.name). Try again." }
    }

    private func undo(_ logged: LoggedConfirmation) {
        logError = nil
        if let hidden = logged.hidden {
            if store.isHiddenSuggestion(hidden.item.id) { try? store.restoreSuggestion(hidden.item.id) }
            withAnimation(.snappy) {
                confirmation = nil
                if !shelf.suggested.contains(where: { $0.id == hidden.item.id }) {
                    shelf.suggested.insert(hidden.item, at: min(hidden.index, shelf.suggested.count))
                }
            }
            Task { await workspace.synchronize() }
            return
        }
        remove(logged.entries)
        withAnimation(.snappy) {
            confirmation = nil
            for entry in logged.entries {
                justLogged[entry.food.foodID]?.removeAll { $0.id == entry.id }
                if justLogged[entry.food.foodID]?.isEmpty == true { justLogged[entry.food.foodID] = nil }
            }
        }
        Task { await workspace.synchronize() }
    }

    /// A portion, quick add or meal was logged in a sheet: a sheet picker
    /// closes, the search tab stays and confirms.
    private func finishSheet() {
        guard let entries = sheetLogged else { return }
        sheetLogged = nil
        finish(entries)
    }

    private func finish(_ entries: [FoodEntry]) {
        onLogged()
        if presentation == .sheet {
            search.close()
            dismiss()
        } else {
            confirm(entries, haptic: false)
        }
    }

    private func openCreatedFood() {
        guard let createdFood else { return }
        self.createdFood = nil
        select(createdFood)
    }

    /// A food with an amount the person logs it at joins in one tap; any
    /// other asks for its amount first.
    private func select(_ food: ExerlyCore.Food) {
        guard onPick != nil else { selectedFood = food; return }
        if store.quickPortion(for: food, unit: unit)?.repeated == false {
            hideKeyboard()
            askOutcome = nil
            askedFood = food
            asking = food
        } else { pick(food, .usual) }
    }

    /// The portion step closed. Swiped away, the food still joins at its
    /// default, marked to check. Once it's in, the search clears for the next food.
    private func finishAsking() {
        guard let food = askedFood else { return }
        askedFood = nil
        if askOutcome == nil { pick(food, .unchecked) }
        if askOutcome != .cancelled {
            query = ""
            searchFocused = true
        }
    }

    private func pick(_ food: ExerlyCore.Food, _ amount: FoodPickAmount) {
        guard let onPick else { return }
        if let count = onPick(food, amount) {
            pickedCount = count
            addedIDs.insert(food.id)
            selectionError = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } else { selectionError = pickError() ?? "This food could not be added. Review its saved label and try again." }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

enum FoodListScope: String, CaseIterable, Hashable {
    case recent, favorites, mine
    var title: String {
        switch self {
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .mine: "My foods"
        }
    }
}

struct FoodPickerItem: Identifiable {
    let portion: QuickPortion
    /// The food the portion sheet opens with.
    let food: ExerlyCore.Food
    var id: String { portion.id }
}

private enum AskOutcome { case added, cancelled }

private struct FoodShelf {
    var suggested: [FoodPickerItem] = []
    var recent: [FoodPickerItem] = []
    var hasRecipes = false
}

private struct LoggedConfirmation: Identifiable {
    let id = UUID()
    let entries: [FoodEntry]
    let title: String
    let detail: String
    /// A suggestion just hidden, and where it was, for Undo.
    var hidden: (item: FoodPickerItem, index: Int)?
}

/// As a sheet the search field stays under the title, which stays while
/// typing so Done is one tap away; in the search tab, iOS places it in the
/// tab bar.
private struct FoodSearchField: ViewModifier {
    @Binding var text: String
    let presentation: FoodPickerPresentation

    func body(content: Content) -> some View {
        switch presentation {
        case .sheet:
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search foods")
                .searchPresentationToolbarBehavior(.avoidHidingContent)
        case .tab:
            content.searchable(text: $text, prompt: "Search foods")
        }
    }
}
