import SwiftUI
import TermCore

/// The bar both chats share: which chat is open, how full its context is, and what it is talking to.
struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        GlassGroup(spacing: 4) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    ModeSwitch(palette: palette)
                    Spacer(minLength: 0)
                    ContextChip(palette: palette)
                    Button {
                        model.sheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.text)
                            .frame(width: 36, height: 36)
                            .glass(in: Circle(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }

                HStack(spacing: 10) {
                    ModelMenu(palette: palette)
                    Spacer(minLength: 4)
                    if model.mode == .cowork {
                        FolderButton(palette: palette)
                    } else {
                        HostMenu(palette: palette)
                    }
                }
                .font(palette.small)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .glass(in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
    }
}

// MARK: Chat switch

private struct ModeSwitch: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        HStack(spacing: 2) {
            segment("Terminal", icon: "terminal", chat: model.terminal)
            segment("Cowork", icon: "sparkles", chat: model.cowork)
        }
        .padding(3)
        .glass(in: Capsule())
    }

    private func segment(_ title: String, icon: String, chat: ChatState) -> some View {
        let selected = model.mode == chat.kind
        return Button {
            withAnimation(.snappy(duration: 0.25)) { model.switchMode(chat.kind) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
                // A run keeps going in the chat that is not on screen; the dot says so.
                if chat.isRunning, !selected {
                    Circle().fill(palette.accent).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected ? palette.background : palette.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(selected ? palette.accent : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Context meter

private struct ContextChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let usage = model.contextUsage
        Button {
            model.sheet = .context
        } label: {
            HStack(spacing: 6) {
                ContextRing(fraction: usage.fraction, color: palette.meter(usage.fraction), track: palette.dim.opacity(0.35))
                    .frame(width: 14, height: 14)
                Text("\(usage.percent)%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .glass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context, \(usage.percent) percent of the limit")
    }
}

struct ContextRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

extension Palette {
    /// Green while there is room, the accent as it fills, red once compaction is due.
    func meter(_ fraction: Double) -> Color {
        if fraction > Compaction.threshold { return error }
        return fraction > 0.6 ? accent : success
    }
}

// MARK: Model, host and folder

private struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Section(profile.name) {
                    ForEach(profile.models, id: \.self) { id in
                        Button {
                            model.select(model: id, in: profile.id)
                        } label: {
                            if profile.id == model.activeProfile?.id, id == model.activeModel {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                }
            }
            Button("Settings…") { model.sheet = .settings }
        } label: {
            HStack(spacing: 6) {
                Text("●").foregroundStyle(model.chat.isRunning ? palette.accent : palette.success)
                Text(profileLabel).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var profileLabel: String {
        guard let profile = model.activeProfile else { return "no profile · /setup" }
        let name = model.activeModel ?? "no model"
        // Cowork shares the row with a folder name, so the profile gives way to it.
        return model.mode == .cowork ? name : "\(profile.name) · \(name)"
    }
}

private struct HostMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            ForEach(model.hosts) { host in
                Button {
                    model.selectHost(host.id)
                } label: {
                    if host.id == model.activeHost?.id {
                        Label("\(host.name)  \(host.address)", systemImage: "checkmark")
                    } else {
                        Text("\(host.name)  \(host.address)")
                    }
                }
            }
            Button("No SSH host") { model.selectHost(nil) }
        } label: {
            Text(model.activeHost.map { "⇄ \($0.name)" } ?? "⇄ off")
                .foregroundStyle(model.activeHost == nil ? palette.dim : palette.accent)
                .lineLimit(1)
        }
    }
}

/// One tap opens the Files browser; holding it offers the way back to the app's own folder.
private struct FolderButton: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Button {
            model.showFolderPicker = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                Text(model.coworkFolderName).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Choose folder…") { model.showFolderPicker = true }
            if model.pickedFolder != nil {
                Button("Use the TermAI folder") { model.clearFolder() }
            }
        }
        .accessibilityLabel("Cowork folder: \(model.coworkFolderName). Opens Files to choose another")
    }
}
