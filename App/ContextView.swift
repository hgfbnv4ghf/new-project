import SwiftUI
import TermCore

/// Rows for a form: whether to compress without being asked, and the limit it is measured against.
struct ContextSettings: View {
    @Environment(AppModel.self) private var model

    private var limits: [Int] {
        // The standard steps, plus whatever was typed with /context.
        Set([8_000, 16_000, 32_000, 64_000, 128_000, 200_000, 400_000, 1_000_000, model.settings.contextLimit]).sorted()
    }

    var body: some View {
        Toggle("Compress automatically", isOn: Binding(
            get: { model.settings.autoCompact },
            set: { value in model.update { $0.autoCompact = value } }))
        Picker("Context limit", selection: Binding(
            get: { model.settings.contextLimit },
            set: { value in model.update { $0.contextLimit = value } })) {
            ForEach(limits, id: \.self) { limit in
                Text("\(Tokens.format(limit)) tokens").tag(limit)
            }
        }
    }
}

/// What the open chat's context is made of, and the button that shrinks it.
struct ContextView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let usage = model.contextUsage
        let chat = model.chat
        let palette = model.palette

        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(usage.percent)%").font(.system(size: 36, weight: .bold, design: .rounded))
                            Text("of \(Tokens.format(usage.limit)) tokens").foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(max(usage.fraction, 0), 1)).tint(palette.meter(usage.fraction))
                        Text("About \(Tokens.format(usage.total)) tokens go out with the next message.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let reported = chat.reportedInput {
                            Text("The last request was \(Tokens.format(reported)) tokens, as counted by the API.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("What fills it") {
                    LabeledContent("System prompt", value: Tokens.format(usage.system))
                    LabeledContent("Tool definitions", value: Tokens.format(usage.tools))
                    if usage.summary > 0 {
                        LabeledContent("Summary of the earlier chat", value: Tokens.format(usage.summary))
                    }
                    LabeledContent("Your messages", value: Tokens.format(usage.user))
                    LabeledContent("Assistant", value: Tokens.format(usage.assistant))
                    LabeledContent("Tool results", value: Tokens.format(usage.toolResults))
                    if model.mode == .cowork {
                        LabeledContent("Folder", value: model.coworkFolderName)
                    }
                }

                Section {
                    Button {
                        dismiss()
                        model.compactNow()
                    } label: {
                        Label("Compress now", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(!model.canCompact)
                } footer: {
                    Text("Swaps the conversation so far for a short summary written by the model. What is on screen stays; what is sent gets smaller.")
                }

                Section {
                    ContextSettings()
                } footer: {
                    Text("At \(Int(Compaction.threshold * 100))% of the limit, old tool output is trimmed during a run and the chat is summarised before your next message. A lower limit spends fewer tokens per request. Counts are estimates.")
                }
            }
            .navigationTitle(model.mode == .cowork ? "Cowork context" : "Terminal context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
