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
    /// Every picked food asks for its amount, starting from the usual one,
    /// unless it was typed with the food. Recipes ask: an ingredient's amount
    /// is rarely what one serving of it was.
    let confirmsAmounts: Bool
    /// Returns to the search tab from another one: it starts again, with an
    /// empty search and the meal for now. Run 6 came back to the last search.
    let entered: Int
    @StateObject private var search: NutritionSearchModel
    @State private var meal: String
    @State private var query = ""
    @State private var scope = FoodListScope.recent
    @State private var shelf = FoodShelf()
    @State private var selectedFood: PortionRequest?
    /// A picked food whose amount is being asked, and how that step ended:
    /// nil while it's open or once swiped away.
    @State private var asking: PortionRequest?
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
         pickError: @escaping () -> String? = { nil }, presentation: FoodPickerPresentation = .sheet, pickingInto: String = "meal",
         confirmsAmounts: Bool = false, entered: Int = 0) {
        self.workspace = workspace
        self.entered = entered
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
        self.confirmsAmounts = confirmsAmounts
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
            .exFooter {
                if picking {
                    Button(pickedCount == 0 ? "Back to \(pickingInto)" : "Review \(pickingInto) · \(pickedCount) \(pickedCount == 1 ? "food" : "foods")") { dismiss() }
                        .buttonStyle(ExActionStyle()).accessibilityIdentifier("nutrition.reviewPlate")
                        .padding(ExSpacing.page).background(Color.exBackground)
                }
            }
            .navigationTitle(picking ? "Choose foods" : "Add food").navigationBarTitleDisplayMode(.inline)
            .modifier(FoodSearchField(text: $query, presentation: presentation, unit: unit))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { Task { await search.search(searchText) } }
            .onChange(of: query) { _, text in search.type(FoodSearch.amount(in: text).food) }
            .onChange(of: entered) {
                query = ""
                meal = store.suggestedMeal(at: .now, timeZone: timeZone)
            }
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
            .sheet(item: $selectedFood, onDismiss: finishSheet) { request in
                // A suggested or recent food can be hidden from its sheet's menu too.
                let shelved = (shelf.suggested + shelf.recent).first { $0.id == request.food.id }
                NutritionEntryEditor(workspace: workspace, food: request.food, date: date, meal: meal,
                                     timeZone: timeZone, unit: unit, actions: actions, start: request.start,
                                     onHide: shelved.map { item in { hide(item) } }) {
                    sheetLogged = (sheetLogged ?? []) + [$0]
                }.environment(\.foodSearchQuery, query)
            }
            .sheet(item: $asking, onDismiss: finishAsking) { request in
                FoodPortionStep(store: store, food: request.food, start: request.start, unit: unit, title: "Add to \(pickingInto)",
                                confirm: "Add", asking: true, identifier: "nutrition.pickPortion", onCancel: { askOutcome = .cancelled },
                                onConfirm: { amount, snapshot in
                                    askOutcome = .added
                                    pick(request.food, .chosen(amount, snapshot))
                                }).environment(\.foodSearchQuery, query)
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
    /// The query without an amount typed with it ("200 g chicken" searches "chicken").
    private var searchText: String { FoodSearch.amount(in: query).food }
    private var store: NutritionStore { workspace.nutrition }

    @ViewBuilder private var header: some View {
        if picking {
            VStack(alignment: .leading, spacing: ExSpacing.small) {
                Text(FoodSearch.amount(in: query).amount != nil ? "Foods come in at the amount you typed. Others ask for one."
                     : confirmsAmounts ? "Each asks for its amount, starting from your usual. Type one first, as in 80 g oats, to skip that."
                     : "Foods you've had come in at your usual amount. Others ask for one.")
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
                if !shelf.recent.isEmpty { group("Recent", shelf.recent, id: "recent", hideable: true) }
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
        let local = atTypedAmount(localMatches)
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
        let items = atTypedAmount(foods.compactMap { food in
            store.quickPortion(for: food, unit: unit).map { FoodPickerItem(portion: $0, food: food) }
        })
        VStack(alignment: .leading, spacing: ExSpacing.small) {
            HStack(spacing: ExSpacing.small) {
                ExEyebrow("Food database")
                if search.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Searching the food database") }
                Spacer(minLength: 0)
            }
            if let error = search.error {
                ExCard {
                    Text(error).font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    Button("Try again") { Task { await search.search(searchText) } }.font(.exLabel).frame(minHeight: 44)
                        .accessibilityIdentifier("nutrition.retrySearch")
                }
            } else if !items.isEmpty {
                ExCard { rows(items) }.accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.databaseResults")
                if let attribution = search.result?.attribution {
                    Text(attribution).font(.exSmall).foregroundStyle(Color.exTextMuted)
                }
                Link("Open Food Facts · Open Database License", destination: URL(string: "https://world.openfoodfacts.org/data")!)
                    .font(.exSmall)
            } else if search.shownQuery == searchText, !search.isLoading {
                Text("No database foods matched “\(searchText)”. Try another name, or scan the package.")
                    .font(.exCaption).foregroundStyle(Color.exTextSecondary)
            } else if searchText.count < NutritionSearchModel.typeAheadMinimum, !search.isLoading {
                Text("Keep typing to search the food database.").font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }
        }
    }

    /// Foods under a heading. Suggested and recent ones (`hideable`) have a
    /// menu on a long press and Hide on a swipe left. Run 6 long-pressed and
    /// swiped a recent food, which had neither, and got its portion sheet.
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
                        .contextMenu { menu(item) }
                        .exSwipeAction("Hide", systemImage: "eye.slash", identifier: "nutrition.swipeHide.\(item.id)") { hide(item) }
                        .accessibilityAction(named: "Don't suggest this") { hide(item) }
                } else { row(item) }
                if item.id != items.last?.id { Divider().overlay(Color.exBorder.opacity(0.35)) }
            }
        }.padding(.vertical, -6)
    }

    private func row(_ item: FoodPickerItem) -> some View {
        // A typed amount the food has no unit for asks for one instead.
        let choosing = item.typed != nil && item.typed != .exact
        let portion = choosing ? "Choose amount" : FoodFormat.portion(item.portion, unit: unit)
        let detail = [portion, FoodFormat.origin(of: item.portion.food)].compactMap { $0 }.joined(separator: " · ")
        let logged = !picking && justLogged[item.id] != nil
        let name = item.portion.food.name
        return FoodQuickRow(name: name, detail: detail, amounts: choosing ? nil : item.portion.nutrients,
                            openHint: picking ? "Adds it to the \(pickingInto)" : "Opens the portion to adjust it",
                            openIdentifier: "nutrition.\(picking ? "platePick" : "food").\(item.id)",
                            open: { hideKeyboard(); if picking { select(item) } else { selectedFood = PortionRequest(item) } },
                            add: FoodAddButton(done: picking ? addedIDs.contains(item.id) : logged,
                                               label: choosing ? "Choose an amount of \(name)" : picking ? "Add \(portion) of \(name) to the \(pickingInto)"
                                                   : logged ? "Logged \(name). Undo" : "Log \(portion) of \(name) to \(meal)",
                                               identifier: "nutrition.\(picking ? "plateAdd" : "quickLog").\(item.id)") {
                                if picking { select(item) } else if logged { unlog(item) } else if choosing {
                                    hideKeyboard()
                                    selectedFood = PortionRequest(item)
                                } else { quickLog(item) }
                            })
    }

    /// What the row's buttons do, then Don't suggest this.
    @ViewBuilder private func menu(_ item: FoodPickerItem) -> some View {
        if picking {
            Button("Add to the \(pickingInto)", systemImage: "plus") { select(item) }
        } else if justLogged[item.id] != nil {
            Button("Undo", systemImage: "arrow.uturn.backward") { unlog(item) }
        } else {
            Button("Log \(FoodFormat.portion(item.portion, unit: unit))", systemImage: "plus") { quickLog(item) }
        }
        Button("Details", systemImage: "info.circle") {
            hideKeyboard()
            if picking { ask(PortionRequest(item)) } else { selectedFood = PortionRequest(item) }
        }
        Button("Don't suggest this", systemImage: "eye.slash") { hide(item) }
            .accessibilityIdentifier("nutrition.hideSuggestion")
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
        // A food the person asked not to be suggested leaves Recent too; search still finds it.
        let recent = store.recentPortions(limit: 30)
            .filter { !suggestedIDs.contains($0.id) && !store.isHiddenSuggestion($0.id) }.map(item)
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
        if !searchText.isEmpty { search.type(searchText) }
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
        return FoodSearch.matching(foods, query: searchText) { [$0.portion.food.name, $0.portion.food.brand].compactMap { $0 }.joined(separator: ", ") }
            .prefix(12).map { $0 }
    }

    /// Each food at the amount typed with the search ("500 g ground beef"),
    /// those it fits exactly first. See `Food.portion(_:)`.
    private func atTypedAmount(_ items: [FoodPickerItem]) -> [FoodPickerItem] {
        guard let amount = FoodSearch.amount(in: query).amount else { return items }
        let typed = items.map { item in
            var item = item
            switch item.food.portion(amount) {
            case let (logged, true)?:
                item.portion = QuickPortion(food: item.portion.food, grams: logged.grams, serving: logged.serving,
                                            quantity: logged.quantity, repeated: false)
                item.typed = .exact
            case let (logged, false)?: item.typed = .check(logged)
            case nil: item.typed = .choose
            }
            return item
        }
        return typed.filter { $0.typed == .exact } + typed.filter { $0.typed != .exact }
    }

    // MARK: Actions

    private func quickLog(_ item: FoodPickerItem) {
        logError = nil
        do {
            let entry = try store.log(item.portion, on: date, meal: meal)
            confirm([entry])
            onLogged()
            if item.typed != nil { readyForNext() }
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
        // As the ring says it: what's left, or how far over.
        let day = store.progress(on: first.date).energy
        if day.target != nil {
            let left = TodayNutritionCard.left(day)
            detail += " · \(left.amount) \(left.words)"
        }
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
        let added = store.recentPortions(limit: 30)
            .filter { logged.contains($0.id) && !listed.contains($0.id) && !store.isHiddenSuggestion($0.id) }.map(item)
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

    /// "Don't suggest this": the row goes from usual foods or Recent, and
    /// Undo brings it back where it was.
    private func hide(_ item: FoodPickerItem) {
        let usual = shelf.suggested.firstIndex { $0.id == item.id }
        guard let index = usual ?? shelf.recent.firstIndex(where: { $0.id == item.id }) else { return }
        logError = nil
        do {
            try store.hideSuggestion(item.portion.food)
            let title = "Won't suggest \(item.portion.food.name)"
            withAnimation(.snappy) {
                if usual == nil { shelf.recent.remove(at: index) } else { shelf.suggested.remove(at: index) }
                confirmation = LoggedConfirmation(entries: [], title: title, detail: "Food library can suggest it again",
                                                  hidden: (item, index, usual == nil))
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
                if !(shelf.suggested + shelf.recent).contains(where: { $0.id == hidden.item.id }) {
                    if hidden.recent {
                        shelf.recent.insert(hidden.item, at: min(hidden.index, shelf.recent.count))
                    } else {
                        shelf.suggested.insert(hidden.item, at: min(hidden.index, shelf.suggested.count))
                    }
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
    /// other asks for its amount first, as every food does when amounts are
    /// confirmed, starting from its usual one.
    private func select(_ food: ExerlyCore.Food) {
        guard onPick != nil else { selectedFood = PortionRequest(food: food); return }
        let usual = store.quickPortion(for: food, unit: unit)
        if usual?.repeated == false {
            ask(PortionRequest(food: food))
        } else if confirmsAmounts {
            ask(PortionRequest(food: food, start: usual.flatMap { FoodPickerItem(portion: $0, food: food).amount }))
        } else { pick(food, .usual) }
    }

    /// A food at the amount typed with it joins in one tap; one the amount
    /// doesn't fit asks for its amount, starting from a count to check.
    private func select(_ item: FoodPickerItem) {
        switch item.typed {
        case nil: select(item.food)
        case .exact?:
            guard let amount = item.amount else { return }
            if pick(item.food, .chosen(amount, item.portion.food)) { readyForNext() }
        case .check?, .choose?: ask(PortionRequest(item))
        }
    }

    private func ask(_ request: PortionRequest) {
        hideKeyboard()
        askOutcome = nil
        askedFood = request.food
        asking = request
    }

    /// After a food at a typed amount, the search clears for the next one.
    private func readyForNext() {
        query = ""
        searchFocused = true
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

    @discardableResult private func pick(_ food: ExerlyCore.Food, _ amount: FoodPickAmount) -> Bool {
        guard let onPick else { return false }
        if let count = onPick(food, amount) {
            pickedCount = count
            addedIDs.insert(food.id)
            selectionError = nil
            UISelectionFeedbackGenerator().selectionChanged()
            return true
        }
        selectionError = pickError() ?? "This food could not be added. Review its saved label and try again."
        return false
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
    var portion: QuickPortion
    /// The food the portion sheet opens with.
    let food: ExerlyCore.Food
    /// How an amount typed with the search fits this food, when one was.
    var typed: TypedFit?
    var id: String { portion.id }

    /// The portion as an amount to log or add.
    var amount: LoggedAmount? {
        try? NutritionStore.preview(food, grams: portion.serving == nil ? portion.grams : nil, serving: portion.serving,
                                    quantity: portion.quantity)
    }

    enum TypedFit: Equatable {
        /// `portion` is the typed amount.
        case exact
        /// A count to check in the portion step, such as "2 × 1 cup".
        case check(LoggedAmount)
        /// Nothing it can be measured in; the portion step starts at its default.
        case choose
    }
}

/// A food whose portion step opens, at `start` when given.
private struct PortionRequest: Identifiable {
    let food: ExerlyCore.Food
    var start: LoggedAmount?
    var id: String { food.id }

    init(food: ExerlyCore.Food, start: LoggedAmount? = nil) {
        self.food = food
        self.start = start
    }

    /// At the typed amount, or the count to check.
    init(_ item: FoodPickerItem) {
        switch item.typed {
        case .check(let amount)?: self.init(food: item.food, start: amount)
        case .exact?: self.init(food: item.food, start: item.amount)
        default: self.init(food: item.food)
        }
    }
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
    var hidden: (item: FoodPickerItem, index: Int, recent: Bool)?
}

/// As a sheet the search field stays under the title, which stays while
/// typing so Done is one tap away; in the search tab, iOS places it in the
/// tab bar.
private struct FoodSearchField: ViewModifier {
    @Binding var text: String
    let presentation: FoodPickerPresentation
    let unit: MassUnit

    /// It says once that an amount can lead the food.
    private var prompt: String { "Search foods, or type \(unit == .pounds ? "8 oz" : "200 g") chicken" }

    func body(content: Content) -> some View {
        switch presentation {
        case .sheet:
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
                .searchPresentationToolbarBehavior(.avoidHidingContent)
        case .tab:
            content.searchable(text: $text, prompt: prompt)
        }
    }
}
