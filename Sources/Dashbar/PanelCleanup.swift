import SwiftUI
import AppKit

// MARK: - Clean up

struct CleanupCard: View {
    @EnvironmentObject var store: Store
    var query = ""
    @State private var showAll = false

    private var matching: [CleanupItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let all = Cleanup.sorted(store.cleanup)   // largest first, whatever order the items arrived in
        return q.isEmpty ? all : all.filter { $0.project.lowercased().contains(q) || $0.kind.lowercased().contains(q) }
    }

    var body: some View {
        Card(title: "Clean-up", icon: "shippingbox", tint: .orange, count: nil,
             trailing: store.cleanupScanned ? Fmt.diskBytes(store.cleanupTotal) : nil) {
            if !store.cleanupScanned {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring cache folders…").font(.system(size: UI.Size.caption)).foregroundStyle(UI.textSecondary)
                }
            } else if store.cleanup.isEmpty && AppSettings.shared.scanRoots.isEmpty {
                // Nothing was scanned, so "nothing worth cleaning" wouldn't be true.
                EmptyRow(text: "No folders to scan. Add your projects' folders in Settings, under Folders.")
            } else if store.cleanup.isEmpty {
                EmptyRow(text: "Nothing worth cleaning")
            } else if matching.isEmpty {
                EmptyRow(text: "No folders match “\(query)”")
            } else {
                let items = showAll || !query.isEmpty ? matching : Array(matching.prefix(8))
                VStack(spacing: 1) { ForEach(items) { CleanupRow(item: $0) } }
                HStack {
                    Text(CleanupNote.text)
                        .font(.system(size: UI.Size.micro)).foregroundStyle(UI.textSecondary)
                    Spacer()
                    if query.isEmpty && store.cleanup.count > 8 {
                        Button(showAll ? "Show less" : "Show all \(store.cleanup.count)") { showAll.toggle() }
                            .buttonStyle(PressStyle()).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textInfo)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct CleanupRow: View {
    @EnvironmentObject var store: Store
    let item: CleanupItem
    @State private var hover = false
    @State private var confirm = debugConfirm
    @FocusState private var focusedAction: Int?

    @Environment(\.inWindow) private var inWindow
    /// The window always shows the Trash button; the panel shows it on hover or focus.
    private var revealed: Bool { inWindow || hover || confirm || focusedAction != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: UI.Size.caption, weight: .medium)).foregroundStyle(UI.textSecondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.project).font(.system(size: UI.Size.body, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
                Text(item.kind).font(.system(size: UI.Size.micro, design: .monospaced)).foregroundStyle(UI.textSecondary)
            }
            Spacer(minLength: 6)
            if confirm {
                ConfirmButton(title: "Move to Trash") { store.trash(item); confirm = false }
                    .focused($focusedAction, equals: 1)
                IconButton(symbol: "xmark", help: "Cancel") { confirm = false }
            } else {
                Text(Fmt.diskBytes(item.size)).font(.system(size: UI.Size.caption).monospacedDigit()).foregroundStyle(UI.textSecondary)
                IconButton(symbol: "trash", help: "Move \(item.kind) in \(item.project) to the Trash") { confirm = true }
                    .focused($focusedAction, equals: 0)
                    .opacity(revealed ? 1 : 0)
                    .allowsHitTesting(revealed)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: UI.innerRadius, style: .continuous)
            .fill(Color.primary.opacity(hover ? UI.rowHover : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0; if !$0 && focusedAction == nil { confirm = false } }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Divider()
            Button("Move to Trash…", role: .destructive) { confirm = true }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to Trash") { confirm = true }
    }

    private var icon: String {
        switch item.kind {
        case "node_modules": return "shippingbox"
        case "DerivedData", ".build": return "hammer"
        default: return "archivebox"
        }
    }
}

/// Under the clean-up list, in the panel and the window alike: packages come back by installing them again, build output
/// and DerivedData by building again.
enum CleanupNote {
    static let text = "Moves to the Trash. Reinstall packages or rebuild to get them back."
}
