import ExerlyCore
import SwiftUI

struct NutritionLibraryHostView: View {
    let accountID: String
    let timeZone: TimeZone
    let unit: MassUnit
    @EnvironmentObject private var account: AppAccountWorkspace
    @EnvironmentObject private var auth: AuthViewModel

    var body: some View {
        Group {
            if let workspace = account.training, workspace.accountID == accountID {
                NutritionLibraryView(workspace: workspace, timeZone: timeZone, unit: unit).id(workspace.identity)
            } else if account.openingError != nil {
                ContentUnavailableView {
                    Label("Food library could not open", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Your saved data is still on this device. Keep Exerly installed and try again.")
                } actions: {
                    Button("Try again") { Task { await account.configure(auth.accountAPI) } }.buttonStyle(.borderedProminent).tint(Color.exActionFill)
                }
            } else { ProgressView("Opening food library…") }
        }
    }
}

struct NutritionLibraryView: View {
    @ObservedObject var workspace: TrainingWorkspace
    let timeZone: TimeZone
    let unit: MassUnit
    @State private var query = ""
    @State private var creating = false
    @State private var creatingRecipe = false
    @State private var showArchived = false
    @EnvironmentObject private var auth: AuthViewModel

    init(workspace: TrainingWorkspace, timeZone: TimeZone, unit: MassUnit) {
        self.workspace = workspace
        self.timeZone = timeZone
        self.unit = unit
    }

    var body: some View {
        ExScreen {
            ExSearchField(text: $query, label: "Search saved foods")
                .accessibilityIdentifier("nutrition.librarySearch")
            ExChoiceChips(values: [false, true], selection: $showArchived) { $0 ? "Archived" : "Saved" }
                .accessibilityIdentifier("nutrition.libraryFilter")
            if visibleFoods.isEmpty {
                ExEmptyState(icon: showArchived ? "archivebox" : "book.closed",
                             title: query.isEmpty ? (showArchived ? "No archived foods" : "Keep your go-to foods here") : "No matches",
                             message: query.isEmpty ? "Create a label or a recipe, or favorite a food from your diary to find it here." : "Try a different name, or create a food label.",
                             action: "Create food") { creating = true }
            } else {
                VStack(alignment: .leading, spacing: ExSpacing.item) {
                    ExSectionHeading(showArchived ? "Archived" : "Saved foods", detail: "\(visibleFoods.count)")
                    ExCard {
                        ForEach(visibleFoods) { food in
                            NavigationLink {
                                NutritionLibraryDetail(workspace: workspace, foodID: food.id, timeZone: timeZone, unit: unit)
                            } label: { NutritionFoodRow(food: food) }
                                .accessibilityIdentifier("nutrition.libraryFood.\(food.id)")
                            if food.id != visibleFoods.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                        }
                    }
                }
            }
            if !showArchived && query.isEmpty && !workspace.nutrition.hiddenSuggestions.isEmpty { hiddenSuggestions }
            Label("Available offline", systemImage: "checkmark.icloud").font(.exCaption).foregroundStyle(Color.exTextSecondary)
        }
        .navigationTitle("Food library").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Create", systemImage: "plus") {
                    Button("New food", systemImage: "square.and.pencil") { creating = true }
                        .accessibilityIdentifier("nutrition.libraryNewFood")
                    Button("New recipe", systemImage: "frying.pan") { creatingRecipe = true }
                        .accessibilityIdentifier("nutrition.libraryNewRecipe")
                }.accessibilityIdentifier("nutrition.libraryCreate")
            }
        }
        .sheet(isPresented: $creating) { NutritionFoodEditor(workspace: workspace) { _ in } }
        .sheet(isPresented: $creatingRecipe) {
            if let api = auth.accountAPI { RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit) }
        }
    }

    /// Foods hidden with "Don't suggest this", each one tap from being suggested again.
    private var hiddenSuggestions: some View {
        let hidden = workspace.nutrition.hiddenSuggestions
        return VStack(alignment: .leading, spacing: ExSpacing.item) {
            ExSectionHeading("Not suggested", detail: "\(hidden.count)")
            Text("Kept out of Log again and usual foods. Search still finds them.")
                .font(.exCaption).foregroundStyle(Color.exTextSecondary).fixedSize(horizontal: false, vertical: true)
            ExCard {
                ForEach(hidden) { food in
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: ExSpacing.item) {
                            Text(food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                            Spacer(minLength: ExSpacing.small)
                            suggestAgain(food)
                        }
                        VStack(alignment: .leading, spacing: ExSpacing.tight) {
                            Text(food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                            suggestAgain(food)
                        }
                    }.frame(minHeight: 52)
                    if food.id != hidden.last?.id { Divider().overlay(Color.exBorder.opacity(0.3)) }
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("nutrition.hiddenSuggestions")
        }
    }

    private func suggestAgain(_ food: HiddenSuggestion) -> some View {
        Button("Suggest again") {
            if (try? workspace.nutrition.restoreSuggestion(food.id)) != nil { Task { await workspace.synchronize() } }
        }
        .font(.exLabel).foregroundStyle(Color.exPrimaryText).frame(minHeight: 44)
        .accessibilityLabel("Suggest \(food.name) again")
        .accessibilityIdentifier("nutrition.suggestAgain.\(food.id)")
    }

    private var visibleFoods: [ExerlyCore.Food] {
        workspace.nutrition.foods.filter {
            ($0.archivedAt != nil) == showArchived &&
                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || ($0.brand?.localizedCaseInsensitiveContains(query) ?? false))
        }.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct NutritionFoodRow: View {
    let food: ExerlyCore.Food
    var showsIcon = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: ExSpacing.small))
            : AnyLayout(HStackLayout(spacing: ExSpacing.item))
        layout {
            if showsIcon && !typeSize.isAccessibilitySize {
            Image(systemName: food.favorite ? "star.fill" : food.source == .recipe ? "frying.pan" : "fork.knife")
                .foregroundStyle(food.favorite ? Color.exAccent : Color.exPrimary)
                .frame(width: 42, height: 48).background(Color.exPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: ExRadius.control))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(food.name).font(.exBodyMedium).foregroundStyle(Color.exTextPrimary)
                Text(food.brand ?? NutritionFormat.source(food.source)).font(.exCaption).foregroundStyle(Color.exTextSecondary)
            }.fixedSize(horizontal: false, vertical: true)
            if typeSize.isAccessibilitySize {
                Text("\(energy) kcal / 100 g").font(.exCaption).foregroundStyle(Color.exTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(energy).font(.exStatSmall).foregroundStyle(Color.exTextPrimary)
                Text("kcal / 100 g").font(.exSmall).foregroundStyle(Color.exTextSecondary)
            }
            }
        }.frame(minHeight: 52).contentShape(Rectangle()).multilineTextAlignment(.leading)
    }

    private var energy: String {
        food.per100g[.energy].map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }
}

private struct NutritionLibraryDetail: View {
    @ObservedObject var workspace: TrainingWorkspace
    let foodID: String
    let timeZone: TimeZone
    let unit: MassUnit
    @StateObject private var actions: NutritionLibraryActions
    @StateObject private var diaryActions: NutritionDiaryActions
    @State private var destination: Destination?
    @State private var logged: FoodEntry?
    @AccessibilityFocusState private var errorFocused: Bool
    @EnvironmentObject private var auth: AuthViewModel

    private enum Destination: Identifiable {
        case edit(ExerlyCore.Food), duplicate(ExerlyCore.Food), log(ExerlyCore.Food), archive(ExerlyCore.Food)
        var id: String {
            switch self {
            case .edit(let food): "edit-\(food.id)"
            case .duplicate(let food): "duplicate-\(food.id)"
            case .log(let food): "log-\(food.id)"
            case .archive(let food): "archive-\(food.id)"
            }
        }
    }

    init(workspace: TrainingWorkspace, foodID: String, timeZone: TimeZone, unit: MassUnit) {
        self.workspace = workspace
        self.foodID = foodID
        self.timeZone = timeZone
        self.unit = unit
        _actions = StateObject(wrappedValue: NutritionLibraryActions(store: workspace.nutrition))
        _diaryActions = StateObject(wrappedValue: NutritionDiaryActions(store: workspace.nutrition))
    }

    var body: some View {
        ExScreen {
            if let food = workspace.nutrition.food(foodID) {
                ExCard(accent: true) {
                    ExEyebrow(food.archivedAt == nil ? NutritionFormat.source(food.source) : "Archived", color: .exPrimaryText)
                    Text(food.name).font(.exH2)
                    if let brand = food.brand { Text(brand).font(.exCaption).foregroundStyle(Color.exTextSecondary) }
                    ExEyebrow(food.recipeServing.map { "Per serving · \(FoodFormat.weight($0.grams, unit: unit))" } ?? "Per 100 g")
                    NutritionDailySummary(amounts: food.perRecipeServing ?? food.per100g, targets: nil, showHeading: false)
                    if food.archivedAt == nil {
                        Button("Log this food", systemImage: "plus") { destination = .log(food) }
                            .buttonStyle(ExActionStyle()).accessibilityIdentifier("nutrition.libraryLog")
                    } else {
                        Button("Restore food", systemImage: "arrow.uturn.backward") { destination = .archive(food) }
                            .buttonStyle(ExActionStyle()).accessibilityIdentifier("nutrition.libraryArchive")
                    }
                }
                if let error = actions.error {
                    Text(error).foregroundStyle(Color.exError).accessibilityFocused($errorFocused)
                }
                if let logged {
                    Label("Logged \(NutritionFormat.portion(logged, unit: unit)) to \(logged.meal), \(NutritionFormat.day(logged.date, timeZone: timeZone)).", systemImage: "checkmark.circle")
                        .font(.exCaption).foregroundStyle(Color.exTextSecondary)
                        .accessibilityIdentifier("nutrition.libraryLogged")
                }
                if food.ingredients?.isEmpty == false { RecipeDetails(recipe: food, unit: unit) }
                ExCard {
                    ExSectionHeading("Nutrition label", detail: "Per 100 g")
                    NutritionAmountsView(amounts: food.per100g)
                }
                if !food.servings.isEmpty {
                    ExCard {
                        ExSectionHeading("Named servings")
                        ForEach(food.servings, id: \.self) { Text("\($0.name) · \(TrainingFormat.number($0.grams)) g") }
                    }
                }
                if let volume = food.volume {
                    ExCard {
                        ExSectionHeading("Volume label")
                        Text("Density: \(TrainingFormat.number(volume.density)) g/ml\(volume.assumed ? " (estimated)" : "")")
                        if let note = volume.note { Text(note).foregroundStyle(Color.exTextSecondary) }
                    }
                }
                if food.source == .openFoodFacts {
                    Link("Open Food Facts · Open Database License", destination: URL(string: "https://world.openfoodfacts.org/data")!).font(.exCaption)
                } else if food.source == .usda {
                    Link("USDA FoodData Central · Public domain", destination: URL(string: "https://fdc.nal.usda.gov/")!).font(.exCaption)
                }
            } else {
                Text("This food is no longer available.").font(.exH2)
            }
        }
        .navigationTitle("Saved food").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let food = workspace.nutrition.food(foodID), food.archivedAt == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(food.favorite ? "Remove from favorites" : "Add to favorites", systemImage: food.favorite ? "star.fill" : "star") {
                        if actions.setFavorite(!food.favorite, reviewed: food) { sync() }
                    }.accessibilityIdentifier("nutrition.libraryFavorite")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Food actions", systemImage: "ellipsis") {
                        if food.source == .custom || food.source == .imported {
                            Button("Edit food label", systemImage: "square.and.pencil") { destination = .edit(food) }
                                .accessibilityIdentifier("nutrition.libraryEdit")
                            Button("Duplicate food", systemImage: "plus.square.on.square") { destination = .duplicate(food.duplicated()) }
                                .accessibilityIdentifier("nutrition.libraryDuplicate")
                        } else if food.source == .recipe {
                            Button("Edit recipe", systemImage: "square.and.pencil") { destination = .edit(food) }
                                .accessibilityIdentifier("recipe.edit")
                            Button("Duplicate recipe", systemImage: "plus.square.on.square") { destination = .duplicate(food.duplicated()) }
                                .accessibilityIdentifier("recipe.duplicate")
                        }
                        Button("Archive food", systemImage: "archivebox") {
                            actions.clearError(); destination = .archive(food)
                        }.accessibilityIdentifier("nutrition.libraryArchive")
                    }.accessibilityIdentifier("nutrition.libraryActions")
                }
            }
        }
        .onChange(of: actions.error) { _, error in errorFocused = error != nil }
        .sheet(item: $destination) { destination in
            switch destination {
            case .edit(let food) where food.source == .recipe:
                if let api = auth.accountAPI { RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit, editing: food) }
            case .edit(let food): NutritionFoodEditor(workspace: workspace, editing: food) { _ in }
            case .duplicate(let copy) where copy.source == .recipe:
                if let api = auth.accountAPI { RecipeEditor(workspace: workspace, api: api, timeZone: timeZone, unit: unit, start: copy) }
            case .duplicate(let copy): NutritionFoodEditor(workspace: workspace, start: copy) { _ in }
            case .log(let food):
                NutritionEntryEditor(workspace: workspace, food: food, date: LocalDate(Date(), in: timeZone),
                                     meal: workspace.nutrition.suggestedMeal(at: .now, timeZone: timeZone), timeZone: timeZone, unit: unit,
                                     actions: diaryActions) { logged = $0 }
            case .archive(let food):
                let restoring = food.archivedAt != nil
                NutritionConfirmation(title: "\(restoring ? "Restore" : "Archive") \(food.name)?",
                    message: restoring ? "This food will return to your saved foods. Existing diary entries stay unchanged." :
                        "This food will be hidden from your saved foods and diary picker. Existing diary entries stay unchanged. You can restore it later.",
                    confirm: restoring ? "Restore food" : "Archive food") {
                    self.destination = nil
                    if restoring ? actions.restore(reviewed: food) : actions.archive(reviewed: food) { sync() }
                } cancel: { self.destination = nil }
            }
        }
    }

    private func sync() { Task { await workspace.synchronize() } }
}
