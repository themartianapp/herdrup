import Foundation
import Combine
import SwiftUI

/// A reusable prompt the user can save and fire into an agent's reply bar with one tap.
/// Just a nickname (the "surname") plus the prompt text — no secret — so it lives entirely
/// in UserDefaults as JSON, mirroring `SavedHostsStore` minus the Keychain machinery.
struct SavedPrompt: Codable, Identifiable, Hashable {
    let id: UUID
    var nickname: String
    var text: String

    init(id: UUID = UUID(), nickname: String, text: String) {
        self.id = id
        self.nickname = nickname
        self.text = text
    }

    /// The display label: the nickname if set, else the prompt text itself
    /// (mirrors `SavedHost.label`).
    var label: String {
        let n = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? text : n
    }
}

/// Persists the user's saved prompts as JSON in UserDefaults. Device-local and secret-free,
/// so it needs none of `SavedHostsStore`'s Keychain half. A singleton `ObservableObject` so
/// the reply bar's saved-prompts menu updates live as prompts are added or removed.
final class SavedPromptsStore: ObservableObject {
    static let shared = SavedPromptsStore()

    private let defaultsKey = "dev.herdr.savedPrompts.v1"
    @Published private(set) var prompts: [SavedPrompt]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            prompts = decoded
        } else {
            prompts = []
        }
    }

    /// Adds a new saved prompt. A blank text is refused (a promptless prompt is useless);
    /// a blank nickname is allowed — `label` then falls back to the text.
    func add(nickname: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        prompts.append(SavedPrompt(nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines), text: t))
        persist()
    }

    func delete(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        persist()
    }

    /// The list after a HerdrUp account sync (App/AccountSync.swift): the account's prompts
    /// merged with this device's. Mock runs keep it in memory, like `SavedHostsStore`.
    func applySynced(_ merged: [SavedPrompt]) {
        prompts = merged
        #if DEBUG
        if ScreenshotMock.mode != nil { return }
        #endif
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct SavedPromptsMenu: View {
    let onSelect: (SavedPrompt) -> Void
    @ObservedObject private var store = SavedPromptsStore.shared
    @State private var showingEditor = false

    var body: some View {
        Menu {
            ForEach(store.prompts) { prompt in
                Button { onSelect(prompt) } label: {
                    Label(prompt.label, systemImage: "text.quote")
                }
            }
            if !store.prompts.isEmpty { Divider() }
            Button { showingEditor = true } label: {
                Label("Save new prompt…", systemImage: "plus")
            }
            if !store.prompts.isEmpty {
                Menu {
                    ForEach(store.prompts) { prompt in
                        Button(role: .destructive) { store.delete(prompt.id) } label: {
                            Text(prompt.label)
                        }
                    }
                } label: {
                    Label("Delete a prompt", systemImage: "trash")
                }
            }
        } label: {
            ComposerActionIcon(image: Image("ComposerBookmark"))
        }
        .accessibilityLabel("Saved prompts")
        .sheet(isPresented: $showingEditor) {
            SavePromptSheet { nickname, text in store.add(nickname: nickname, text: text) }
        }
    }
}

/// A small form to save a new prompt: a nickname (the "surname") + the prompt text.
/// Styled to match `HostEditor` — dark ground, surface fields, Geist app voice + Plex Mono
/// for the prompt body. Owns its own state, so it opens blank each time.
struct SavePromptSheet: View {
    var onSave: (String, String) -> Void

    @State private var nickname = ""
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.ground.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("NICKNAME").font(Typography.microLabel).foregroundStyle(Palette.textFaint)
                            .padding(.leading, 4)
                        TextField("e.g. daily standup", text: $nickname)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(Typography.app(15)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))

                        Text("PROMPT").font(Typography.microLabel).foregroundStyle(Palette.textFaint)
                            .padding(.leading, 4).padding(.top, 6)
                        TextField("what to send the agent…", text: $text, axis: .vertical)
                            .lineLimit(3...10)
                            .font(Typography.machine(14)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12))

                        Button {
                            onSave(nickname, text); dismiss()
                        } label: {
                            Text("Save prompt").font(Typography.app(16, .semibold)).foregroundStyle(Palette.ground)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.text))
                        }
                        .disabled(!canSave).opacity(canSave ? 1 : 0.5).padding(.top, 6)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Save prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Palette.textDim)
                }
            }
        }
    }
}
