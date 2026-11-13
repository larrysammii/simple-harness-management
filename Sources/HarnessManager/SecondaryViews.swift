import SwiftUI
import HarnessCore

struct PackageListView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                SearchField(placeholder: "Search packages", text: $model.query)
                Text("\(model.scopedPackages.count) bundles").font(TypeStyle.mono).foregroundStyle(Ink.muted)
            }
            Rule()
            if model.isLoading && !model.hasLoaded {
                emptyState(symbol: nil, title: "Reading package registrations", description: "Package and extension code is never executed", loading: true)
            } else if model.scopedPackages.isEmpty {
                emptyState(symbol: "shippingbox", title: model.query.isEmpty ? "No Pi packages in this scope" : "No matching packages", description: "Configured bundles appear here without running their code")
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(model.scopedPackages) { package in PackageCard(model: model, package: package) }
                    }.padding(.vertical, 4)
                }
            }
        }.frame(maxHeight: .infinity)
    }
}

private struct PackageCard: View {
    @Bindable var model: AppModel
    let package: PackageInstallation
    @State private var expanded = false
    private let kinds = ["skills", "extensions", "prompts", "themes"]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(package.name + (package.inherited ? " (globally installed)" : ""))
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(package.inherited ? Ink.secondary : Ink.primary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text("Pi").foregroundStyle(Ink.secondary)
                        if let version = package.version { Text("/ " + version).font(TypeStyle.mono).foregroundStyle(Ink.muted) }
                        if let source = package.provenance.sourceLabel { Text("· " + source).foregroundStyle(Ink.muted).lineLimit(1) }
                    }.font(TypeStyle.small)
                }
                Spacer()
                Text(package.cachePresent ? (package.inventoryComplete ? "Cache present" : "Incomplete inventory") : "Cache missing")
                    .font(TypeStyle.mono).foregroundStyle(Ink.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(kinds, id: \.self) { kind in
                    let resource = package.resources[kind] ?? .init()
                    VStack(alignment: .leading, spacing: 6) {
                        Text(resource.installed.formatted()).font(.system(size: 24, weight: .regular)).monospacedDigit()
                        Text(kind.capitalized).font(TypeStyle.small).foregroundStyle(Ink.secondary)
                        Text("\(resource.enabled) enabled").font(TypeStyle.mono).foregroundStyle(Ink.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(kinds, id: \.self) { kind in
                        let names = package.resources[kind]?.names ?? []
                        if !names.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(kind.capitalized).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary)
                                ForEach(names, id: \.self) { name in Text(name).font(TypeStyle.mono).foregroundStyle(Ink.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                    Text("Installed and enabled counts describe configuration, not live execution")
                        .font(TypeStyle.small).foregroundStyle(Ink.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } label: { Text("Resource inventory").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
            Rule()
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(package.displayPath).font(TypeStyle.mono).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.middle)
                    if let reason = package.readOnlyReason { Text(reason).font(TypeStyle.small).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true) }
                    else { Text("Uninstall removes registration · downloaded files stay on disk").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                }
                Spacer(minLength: 0)
                if package.inherited {
                    Button("Global view") { model.scopeID = "global" }.buttonStyle(QuietButtonStyle())
                } else {
                    Button("Uninstall package…") { model.requestPackage(package) }
                        .buttonStyle(QuietButtonStyle(destructive: true)).disabled(!package.canUninstall || model.busy)
                }
            }
        }.padding(24).background(Ink.canvas, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.rule, lineWidth: 1))
    }
}

struct BackupListView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                SearchField(placeholder: "Search backups", text: $model.query)
                Text("\(model.snapshot.backups.filter { $0.canRestore }.count) recoverable").font(TypeStyle.mono).foregroundStyle(Ink.muted)
            }
            Rule()
            if model.shownBackups.isEmpty {
                emptyState(symbol: "clock.arrow.circlepath", title: model.query.isEmpty ? "No changes to recover" : "No matching backups", description: model.query.isEmpty ? "Backups appear here when you uninstall an installation or package" : "Try a different search")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.shownBackups) { backup in
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Text(backup.title).font(.system(size: 15, weight: .medium))
                                        Text(backup.kind == .skill ? "Skill" : backup.kind == .mcp ? "MCP" : "Package").font(TypeStyle.mono).foregroundStyle(Ink.muted)
                                    }
                                    Text(backup.sourcePath).font(TypeStyle.mono).foregroundStyle(Ink.secondary).lineLimit(2).truncationMode(.middle)
                                    HStack(spacing: 8) {
                                        Text(backup.scopeName)
                                        Text("·")
                                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    }.font(TypeStyle.small).foregroundStyle(Ink.muted)
                                    if let reason = backup.reason { Text(reason).font(TypeStyle.small).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                                Spacer(minLength: 0)
                                Button(backup.status == .restored ? "Restored" : backup.status == .pending && !backup.canRestore ? "Pending" : "Restore…") { model.requestRestore(backup) }
                                    .buttonStyle(QuietButtonStyle()).disabled(!backup.canRestore || model.busy)
                            }.padding(.vertical, 24)
                            Rule()
                        }
                    }
                }
            }
        }.frame(maxHeight: .infinity)
    }
}

struct InspectorView: View {
    @Bindable var model: AppModel
    let row: ResourceRow
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Installation details").font(.system(size: 13, weight: .medium))
                Spacer()
                Button { model.inspected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(PlainIconStyle()).accessibilityLabel("Close details")
            }.padding(.horizontal, 24).frame(height: 56)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(row.item.title).font(.system(size: 24, weight: .regular)).textSelection(.enabled)
                        Text(row.item.description).font(.system(size: 13)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Rule()
                    detail("Scope", value: row.item.inherited ? "Global · inherited here" : model.scopeName)
                    detail("State", value: row.state)
                    detail("Harnesses", value: row.harnessIDs.compactMap { model.harnessName[$0] }.joined(separator: "\n"))
                    detail("Creator", value: row.item.provenance.creator ?? "Unknown")
                    if let source = row.item.provenance.sourceLabel { detail("Source", value: source) }
                    if let transport = row.item.transport { detail("Transport", value: transport) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Installation path").font(TypeStyle.small).foregroundStyle(Ink.muted)
                        Text(row.item.displayPath).font(TypeStyle.mono).foregroundStyle(Ink.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Reveal") { model.reveal(row.item.sourcePath) }.buttonStyle(QuietButtonStyle())
                            Button("Copy path") { model.copyPath(row.item.sourcePath) }.buttonStyle(QuietButtonStyle())
                        }.padding(.top, 4)
                    }
                    if let package = row.item.packageName { detail("Managed by", value: package) }
                    if row.item.overridesGlobal { Text("This local copy overrides a same-name global installation").font(TypeStyle.small).foregroundStyle(Ink.secondary) }
                    if let reason = row.item.readOnlyReason {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Protected installation", systemImage: "lock").font(.system(size: 12, weight: .medium))
                            Text(reason).font(TypeStyle.small).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(16).background(Ink.raised, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if let source = row.item.provenance.sourceURL, let url = URL(string: source) {
                        Link(destination: url) { HStack(spacing: 8) { Text("View public source"); Image(systemName: "arrow.up.right") } }
                            .font(TypeStyle.small).foregroundStyle(Ink.accent)
                    }
                }.padding(24)
            }
            Rule()
            VStack(alignment: .leading, spacing: 12) {
                if let item = row.removalItem {
                    Button("Uninstall…") { model.requestRemoval([item]) }.buttonStyle(QuietButtonStyle(destructive: true)).disabled(model.busy)
                } else if let id = row.item.packageID, let package = model.snapshot.packages.first(where: { $0.id == id }), package.canUninstall && !row.item.inherited {
                    Button("Uninstall package…") { model.requestPackage(package) }.buttonStyle(QuietButtonStyle(destructive: true)).disabled(model.busy)
                } else if row.item.inherited {
                    Button("Manage in Global view") { model.scopeID = "global"; model.inspected = nil }.buttonStyle(QuietButtonStyle())
                }
                Text("Configuration only\nNo commands or credentials are shown").font(TypeStyle.small).foregroundStyle(Ink.muted).lineSpacing(4)
            }.padding(24)
        }
    }
    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(TypeStyle.small).foregroundStyle(Ink.muted)
            Text(value).font(.system(size: 13)).foregroundStyle(Ink.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
