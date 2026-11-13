import SwiftUI
import HarnessCore

struct ReviewSheet: View {
    @Bindable var model: AppModel
    let content: SheetContent
    @State private var confirmation = ""
    @FocusState private var confirmationFocused: Bool
    private var required: String? {
        switch content {
        case .removal(let items, _, _): "UNINSTALL \(items.count)"
        case .package(let package, _): package.name
        default: nil
        }
    }
    private var title: String {
        switch content {
        case .removal(let items, _, _): "Uninstall \(items.count == 1 ? "installation" : "\(items.count) installations")"
        case .package: "Uninstall package"
        case .restore: "Restore backup"
        case .warnings: "Scan notices"
        }
    }
    private var actionTitle: String {
        switch content { case .removal: "Uninstall"; case .package: "Uninstall package"; case .restore: "Restore"; case .warnings: "Done" }
    }
    private var destructive: Bool {
        switch content { case .removal, .package: true; default: false }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 28, weight: .regular))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Rule()
            details
            if let required {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Type \(required) to confirm").font(.system(size: 13, weight: .medium))
                    TextField("Confirmation", text: $confirmation).font(TypeStyle.mono).textFieldStyle(.roundedBorder)
                        .focused($confirmationFocused).disabled(model.isMutating).accessibilityLabel("Confirmation: type \(required)")
                }
            }
            if let error = model.sheetError {
                Text(error).font(.system(size: 13)).foregroundStyle(Ink.danger).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Change refused: \(error)")
            }
            Rule()
            HStack(spacing: 12) {
                if model.isMutating { ProgressView().controlSize(.small); Text("Saving a recoverable change").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                Spacer()
                Button(isWarnings ? "Close" : "Cancel") { model.sheet = nil; model.sheetError = nil }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction).disabled(model.isMutating)
                if !isWarnings {
                    Button(actionTitle) { Task { await model.apply(content, confirmation: confirmation) } }
                        .buttonStyle(QuietButtonStyle(primary: true, destructive: destructive))
                        .keyboardShortcut(.defaultAction).disabled(model.busy || required.map { confirmation != $0 } == true)
                }
            }
        }.padding(32).frame(width: 600).background(Ink.canvas).foregroundStyle(Ink.primary).tint(Ink.accent)
            .interactiveDismissDisabled(model.isMutating)
            .onAppear { if required != nil { confirmationFocused = true } }
    }
    private var isWarnings: Bool { if case .warnings = content { return true }; return false }
    private var subtitle: String {
        switch content {
        case .removal(_, _, let scope): "Review the exact installations and paths in \(scope)"
        case .package(_, let scope): "Remove the entire Pi bundle registration from \(scope)"
        case .restore: "Return the saved files to their original location"
        case .warnings: "Unreadable or unsupported sources were left untouched"
        }
    }
    @ViewBuilder private var details: some View {
        switch content {
        case .removal(let items, let scope, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(.system(size: 14, weight: .medium))
                            Text(item.sourcePath).font(TypeStyle.mono).foregroundStyle(Ink.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text("\(model.harnessName[item.harnessID] ?? item.harnessID) · \(item.kind == .skill ? "Skill" : "MCP server")")
                                .font(TypeStyle.small).foregroundStyle(Ink.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: CGFloat(min(items.count * 88, 264)))
            VStack(alignment: .leading, spacing: 8) {
                Text("A private recovery backup is created before each change").font(.system(size: 13, weight: .medium))
                if scope == "global" { Text("A shared physical installation can be used by other harnesses and repositories").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                if items.contains(where: { $0.sourceType == .symlink }) { Text("Only the symbolic link is removed; its target stays in place").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                Text("Batch changes stop at the first error; earlier changes remain recoverable in Backups").font(TypeStyle.small).foregroundStyle(Ink.secondary)
            }
        case .package(let package, _):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                Text(package.name).font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                Text(package.settingsPath).font(TypeStyle.mono).foregroundStyle(Ink.secondary).textSelection(.enabled)
                ForEach(["skills", "extensions", "prompts", "themes"], id: \.self) { kind in
                    let resource = package.resources[kind] ?? .init()
                    DisclosureGroup("\(resource.installed) \(kind) · \(resource.enabled) enabled") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(resource.names, id: \.self) { name in Text(name).font(TypeStyle.mono).foregroundStyle(Ink.secondary) }
                            if resource.names.isEmpty { Text("None recorded").font(TypeStyle.small).foregroundStyle(Ink.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }.font(.system(size: 13))
                }
                Text("Downloaded files, dependencies, and generated data stay on disk. Other settings and scopes are preserved. Reload Pi to apply the change.")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                if !package.otherScopes.isEmpty { Text("This bundle is also registered in \(package.otherScopes.count) other scope\(package.otherScopes.count == 1 ? "" : "s")").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                if !package.cachePresent || !package.inventoryComplete {
                    Text("The cache is missing or incomplete. Restoring the registration does not restore its download.").font(TypeStyle.small).foregroundStyle(Ink.secondary)
                }
                }
            }.frame(maxHeight: 320)
        case .restore(let backup):
            VStack(alignment: .leading, spacing: 16) {
                Text(backup.title).font(.system(size: 18, weight: .medium))
                Text(backup.sourcePath).font(TypeStyle.mono).foregroundStyle(Ink.secondary).textSelection(.enabled)
                Text(backup.scopeName + " · " + backup.createdAt.formatted(date: .abbreviated, time: .shortened)).font(TypeStyle.small).foregroundStyle(Ink.muted)
                Text(backup.kind == .skill ? "An existing installation will never be overwritten" : "Restore is refused if the configuration has been edited since uninstall")
                    .font(.system(size: 13)).foregroundStyle(Ink.secondary)
                if backup.kind == .package { Text("This restores registration only, not downloaded package files").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
            }
        case .warnings:
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.snapshot.warnings) { warning in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(warning.path).font(TypeStyle.mono).foregroundStyle(Ink.primary).textSelection(.enabled)
                            Text(warning.message).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(height: 300)
        }
    }
}
