import AppKit
import SpaceNamerCore
import SwiftUI

struct SpacesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingReset = false

    var body: some View {
        Form {
            ForEach(model.snapshot.displays) { display in
                Section(model.snapshot.displays.count > 1 ? model.displayName(for: display.id) : "Spaces") {
                    ForEach(display.spaces) { space in
                        SpaceRow(model: model, space: space, isCurrent: space.managedID == display.currentManagedID)
                    }
                }
            }

            let orphans = model.store.orphanedRecords(in: model.snapshot).filter { $0.record.name != nil || $0.record.hotKey != nil }
            if !orphans.isEmpty {
                Section {
                    ForEach(orphans, id: \.key) { orphan in
                        HStack {
                            Text(orphan.record.name ?? "Unnamed Space")
                            if let hotKey = orphan.record.hotKey {
                                Text(hotKey.displayString).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Last seen \(orphan.record.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Forget") { model.store.forget(orphan.key) }
                        }
                    }
                } header: {
                    Text("Waiting for Their Display")
                } footer: {
                    Text("These Spaces belong to a display that isn't connected. Their names come back when it is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(alignment: .top) {
                    Text("Names follow each Space when you reorder Spaces in Mission Control, and are removed when you close the Space. Leave a name empty to use the macOS name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset All…") { confirmingReset = true }
                        .disabled(model.store.records.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
        .onAppear {
            model.refresh()
            model.refreshApps()
        }
        .confirmationDialog("Remove all names and per-Space shortcuts?", isPresented: $confirmingReset) {
            Button("Reset All", role: .destructive) { model.store.forgetAll() }
        } message: {
            Text("Spaces go back to their macOS names. This can't be undone.")
        }
    }
}

private struct SpaceRow: View {
    @ObservedObject var model: AppModel
    let space: Space
    let isCurrent: Bool
    @State private var name = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 10) {
            PositionBadge(space: space, isCurrent: isCurrent)

            TextField("Name", text: $name, prompt: Text(model.systemName(for: space)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .onSubmit { commit() }
                .onChange(of: editing) { focused in if !focused { commit() } }
                .onChange(of: name) { _ in commit() }

            AppIcons(apps: model.appsBySpace[space.managedID] ?? [])

            if space.kind == .desktop {
                ShortcutRecorder(hotKey: Binding(
                    get: { model.store.hotKey(for: space.key) },
                    set: { model.setHotKey($0, for: space) }
                ), model: model)
            }

            Button {
                model.jump(to: space)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help(isCurrent ? "This is the current Space" : "Go to this Space")
            .disabled(isCurrent)
        }
        .onAppear { name = model.store.name(for: space.key) ?? "" }
        .onReceive(model.$namesRevision) { _ in
            // Pick up renames made elsewhere, but never fight the user's typing.
            guard !editing else { return }
            let stored = model.store.name(for: space.key) ?? ""
            if stored != name { name = stored }
        }
    }

    private func commit() {
        model.rename(space, to: name)
    }
}

private struct PositionBadge: View {
    let space: Space
    let isCurrent: Bool

    var body: some View {
        Group {
            if let position = space.position {
                Text("\(position)").font(.system(size: 12, weight: .semibold).monospacedDigit())
            } else {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
            }
        }
        .frame(width: 26, height: 22)
        .foregroundStyle(isCurrent ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.18))
        )
        .help(isCurrent ? "Current Space" : "")
    }
}

private struct AppIcons: View {
    let apps: [NSRunningApplication]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(apps.prefix(4).enumerated()), id: \.offset) { _, app in
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .help(app.localizedName ?? "")
                }
            }
        }
        .frame(width: 70, alignment: .trailing)
    }
}
