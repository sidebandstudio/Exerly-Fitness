import ExerlyCore
import SwiftUI

/// Brings a recipe in from a web page's link or a recipe file shared from
/// Exerly, for the recipe editor to open for review. Nothing is saved here.
struct RecipeImportView: View {
    let store: NutritionStore
    let api: AccountAPI
    let unit: MassUnit
    let onImported: (RecipeImport) -> Void
    @State private var link = ""
    @State private var loading: Task<Void, Never>?
    @State private var error: String?
    @State private var choosingFile = false
    @FocusState private var linkFocused: Bool
    @AccessibilityFocusState private var errorFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExList {
                Section {
                    TextField("Recipe link", text: $link, prompt: Text("https://").foregroundColor(.exTextSecondary))
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).onSubmit(start).focused($linkFocused)
                        .accessibilityIdentifier("recipeImport.link")
                    // Pasting from the system's button needs no permission prompt, and imports at once.
                    PasteButton(payloadType: String.self) { texts in
                        guard let text = texts.first else { return }
                        Task { @MainActor in
                            link = text
                            start()
                        }
                    }.labelStyle(.titleAndIcon).tint(Color.exActionFill).accessibilityIdentifier("recipeImport.paste")
                } header: { Text("From a web page") } footer: {
                    Text("Exerly reads the ingredients, servings and steps the page lists for recipe apps, and matches each ingredient to a food. You check everything before saving.")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(Color.exError).accessibilityFocused($errorFocused)
                            .accessibilityIdentifier("recipeImport.error")
                    }
                }
                Section {
                    Button { choosingFile = true } label: {
                        Label("Choose a recipe file", systemImage: "doc.badge.plus").font(.exBodyMedium).foregroundStyle(Color.exPrimaryText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("recipeImport.file")
                } header: { Text("Shared from Exerly") } footer: {
                    Text("Recipes shared from Exerly arrive as .\(RecipeFile.fileExtension) files, with each ingredient's nutrition.")
                }
            }
            .disabled(loading != nil)
            .navigationTitle("Import a recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // A page still loading is dropped, not applied after the sheet has gone.
                    Button("Cancel") { loading?.cancel(); dismiss() }.accessibilityIdentifier("recipeImport.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if loading != nil {
                        ProgressView().accessibilityLabel("Reading the recipe")
                    } else {
                        Button("Import", action: start).fontWeight(.semibold)
                            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("recipeImport.import")
                    }
                }
            }
            .onChange(of: error) { _, error in errorFocused = error != nil }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.exerlyRecipe]) { result in
                do {
                    finish(try RecipeShareItem.read(try result.get()))
                } catch {
                    self.error = "That file isn't a recipe Exerly can read."
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                linkFocused = true
            }
        }
    }

    private func start() {
        guard loading == nil else { return }
        guard let url = Self.webLink(in: link) else {
            error = "Paste the link to a recipe page, starting with http:// or https://."
            return
        }
        linkFocused = false
        error = nil
        loading = Task {
            defer { loading = nil }
            do {
                let page = try await api.importRecipe(from: url)
                // Without matches every line is left to search for, which is still a start.
                let found = (try? await api.matchFoods(page.ingredients.map { IngredientLine($0).food })) ?? []
                guard !Task.isCancelled else { return }
                finish(RecipeImport(page: page, own: store.foods, database: found, unit: unit))
            } catch ExerlyCore.APIError.server(_, let message) {
                error = message
            } catch {
                self.error = "Exerly couldn't reach the server. Check your connection and try again."
            }
        }
    }

    private func finish(_ imported: RecipeImport) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onImported(imported)
        dismiss()
    }

    /// The web link in what was typed or pasted: an address alone as written,
    /// with https:// when it has no scheme, or the first web link in a message.
    static func webLink(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let web = { (url: URL) in ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil }
        if !trimmed.contains(where: \.isWhitespace), trimmed.contains(".") {
            let link = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            return URL(string: link).map(web) == true ? link : nil
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap(\.url)
            .first(where: web)?.absoluteString
    }
}
