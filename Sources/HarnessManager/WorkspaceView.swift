import SwiftUI
import HarnessCore

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "light"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240)
            RuleVertical()
            VStack(spacing: 0) {
                topBar
                Rule()
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader.padding(.top, 28).padding(.bottom, 28)
                    if let error = model.errorMessage {
                        message(error, isError: true).padding(.bottom, 16)
                    } else if let notice = model.notice {
                        message(notice, isError: false).padding(.bottom, 16)
                    }
                    switch model.section {
                    case .inventory: inventory
                    case .packages: PackageListView(model: model)
                    case .backups: BackupListView(model: model)
                    }
                    footer.padding(.top, 20).padding(.bottom, 20)
                }.padding(.horizontal, 32)
            }.background(Ink.canvas)
            if let row = model.inspected, model.section == .inventory {
                RuleVertical()
                InspectorView(model: model, row: row).frame(width: 296).background(Ink.sidebar)
            }
        }
        .font(TypeStyle.body).foregroundStyle(Ink.primary).background(Ink.canvas).tint(Ink.accent)
        .frame(minWidth: 1000, minHeight: 680)
        .sheet(item: $model.sheet) { sheet in ReviewSheet(model: model, content: sheet.content) }
        .onReceive(NotificationCenter.default.publisher(for: .refreshInventory)) { _ in Task { await model.refresh() } }
        .task { if !model.hasLoaded { await model.refresh() } }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                HarnessMark().padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Harness Manager").font(.system(size: 16, weight: .medium))
                    Text("Local inventory").font(TypeStyle.small).foregroundStyle(Ink.secondary)
                }
            }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 40)

            VStack(spacing: 4) {
                navigationRow("Global installations", symbol: "square.stack.3d.up", selected: model.scopeID == "global" && model.section == .inventory) {
                    model.scopeID = "global"; model.section = .inventory
                }
            }.padding(.horizontal, 12)

            HStack {
                Text("Repositories").font(TypeStyle.small).foregroundStyle(Ink.secondary)
                Spacer()
                Button { model.addRepository() } label: { Image(systemName: "plus") }
                    .buttonStyle(PlainIconStyle()).help("Add repository · ⌘N").accessibilityLabel("Add repository").disabled(model.busy)
            }.padding(.leading, 24).padding(.trailing, 12).padding(.top, 24).padding(.bottom, 4)
            SearchField(placeholder: "Find repository", text: $model.repositoryQuery, compact: true)
                .padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.shownRepositories) { repo in
                        navigationRow(repo.name, symbol: "folder", selected: model.scopeID == repo.id && model.section == .inventory) {
                            model.scopeID = repo.id; model.section = .inventory
                        }.help(repo.displayPath)
                    }
                    if model.shownRepositories.isEmpty {
                        Text(model.isLoading ? "Scanning folders" : model.repositoryQuery.isEmpty ? "No repositories found" : "No matching repositories")
                            .font(TypeStyle.small).foregroundStyle(Ink.muted).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 12)
            }.frame(maxHeight: min(280, CGFloat(max(1, model.shownRepositories.count)) * 40))

            Rule().padding(.horizontal, 24).padding(.vertical, 24)
            VStack(spacing: 4) {
                navigationRow("Packages", symbol: "shippingbox", selected: model.section == .packages,
                              count: model.snapshot.packages(in: model.scopeID).count) { model.section = .packages }
                navigationRow("Backups", symbol: "clock.arrow.circlepath", selected: model.section == .backups,
                              count: model.snapshot.backups.filter { $0.canRestore }.count) { model.section = .backups }
            }.padding(.horizontal, 12)
            Spacer(minLength: 32)
            VStack(alignment: .leading, spacing: 12) {
                Rule()
                HStack(spacing: 8) {
                    Circle().fill(Ink.accent).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(model.isDemo ? "Synthetic demo" : "On this Mac").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Image(systemName: "lock.shield").font(.system(size: 14)).foregroundStyle(Ink.secondary).accessibilityHidden(true)
                }
                Text(model.isDemo ? "Disposable files only\nYour installations are untouched" : "No connections or uploads\nChanges are backed up locally")
                    .font(TypeStyle.small).foregroundStyle(Ink.secondary).lineSpacing(4)
                HStack {
                    Text("Native · SwiftUI").font(TypeStyle.mono).foregroundStyle(Ink.muted)
                    Spacer()
                    Text("0.1").font(TypeStyle.mono).foregroundStyle(Ink.muted)
                }.padding(.top, 8)
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(maxHeight: .infinity).background(Ink.sidebar)
    }

    private func navigationRow(_ title: String, symbol: String, selected: Bool, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 20).foregroundStyle(selected ? Ink.primary : Ink.secondary)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 { Text(count.formatted()).font(TypeStyle.mono).foregroundStyle(Ink.secondary) }
            }.padding(.horizontal, 12).frame(height: 36)
                .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                .background(selected ? Ink.canvas : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Ink.rule : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("Workspace").foregroundStyle(Ink.secondary)
            Text("/").foregroundStyle(Ink.muted)
            Text(model.scopeID == "global" ? "Global" : model.scopeName).lineLimit(1)
            if model.section != .inventory {
                Text("/").foregroundStyle(Ink.muted)
                Text(model.section == .packages ? "Packages" : "Backups")
            }
            Spacer()
            Button {
                appearance = colorScheme == .dark ? "light" : "dark"
            } label: { Image(systemName: colorScheme == .dark ? "sun.max" : "moon") }
                .buttonStyle(PlainIconStyle()).accessibilityLabel("Switch to \(colorScheme == .dark ? "light" : "dark") appearance")
                .help("Switch appearance")
            Button { Task { await model.refresh() } } label: {
                HStack(spacing: 8) { Image(systemName: "arrow.clockwise").font(.system(size: 14)); Text("Refresh") }
            }.buttonStyle(QuietButtonStyle()).disabled(model.busy).help("Refresh inventory · ⌘R")
        }.font(.system(size: 12)).padding(.horizontal, 32).frame(height: 56)
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.section == .inventory ? model.scopeName : model.section == .packages ? "Packages" : "Backups")
                        .font(.system(size: 40, weight: .regular)).tracking(-0.8).lineLimit(1).minimumScaleFactor(0.8)
                    Text(model.section == .backups ? "Recoverable changes across your installations" : model.section == .packages ? "Installed bundles · \(model.scopeName)" : model.scopePath)
                        .font(.system(size: 13)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(model.section == .backups ? "Recovery / 03" : model.section == .packages ? "Bundles / 02" : "Inventory / 01")
                        .font(TypeStyle.mono).foregroundStyle(Ink.muted)
                    Text(model.section == .backups ? "All scopes" : model.scopeID == "global" ? "~/" : "Repository scope")
                        .font(TypeStyle.mono).foregroundStyle(Ink.secondary)
                }.padding(.top, 8)
            }
            if model.section == .inventory {
                HStack(alignment: .top, spacing: 0) {
                    metric("Skills", value: model.skillsCount)
                    metric("MCP servers", value: model.mcpCount)
                    metric("Harnesses", value: model.activeHarnessCount)
                }.padding(.top, 4)
            }
        }
    }
    private func metric(_ label: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isLoading && !model.hasLoaded ? "—" : value.formatted())
                .font(.system(size: 36, weight: .regular)).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inventory: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                resourceTab("Skills", kind: .skill, count: model.skillsCount)
                resourceTab("MCP servers", kind: .mcp, count: model.mcpCount)
                Spacer()
                Text("\(model.filteredRows.count.formatted()) resources").font(TypeStyle.mono).foregroundStyle(Ink.muted)
            }.frame(height: 44)
            Rule()
            HStack(spacing: 12) {
                SearchField(placeholder: "Search \(model.kind == .skill ? "skills" : "MCP servers")", text: $model.query).frame(minWidth: 160)
                filterMenu("All harnesses", selection: $model.harnessFilter,
                           values: model.snapshot.harnesses.map { ($0.id, $0.name) }).frame(width: 156)
                if model.kind == .skill {
                    filterMenu("All creators", selection: $model.creatorFilter,
                               values: model.creators.map { ($0, $0) }).frame(width: 144)
                }
            }.padding(.vertical, 16)
            HStack(spacing: 12) {
                Text(model.selectedIDs.isEmpty ? "Select installations to manage" : "\(model.selectedIDs.count) selected")
                    .font(TypeStyle.small).foregroundStyle(model.selectedIDs.isEmpty ? Ink.muted : Ink.primary)
                Spacer()
                if !model.selectedIDs.isEmpty {
                    Button("Clear") { model.selectedIDs = [] }.buttonStyle(.plain).font(TypeStyle.small).foregroundStyle(Ink.secondary)
                }
                Button("Select all matching (\(model.removableRows.count))") { model.selectAllMatching() }
                    .buttonStyle(.plain).font(TypeStyle.small).foregroundStyle(Ink.secondary).disabled(model.busy || model.removableRows.isEmpty)
                if !model.selectedIDs.isEmpty {
                    Button("Uninstall selected") { model.requestSelectedRemoval() }
                        .buttonStyle(QuietButtonStyle(destructive: true)).disabled(model.busy)
                }
            }.frame(height: 36).padding(.bottom, 8)
            Rule()
            if model.isLoading && !model.hasLoaded {
                emptyState(symbol: nil, title: "Reading local configuration", description: "No harnesses or servers are started", loading: true)
            } else if model.filteredRows.isEmpty {
                emptyState(symbol: "line.3.horizontal.decrease", title: model.query.isEmpty && model.harnessFilter == "all" && model.creatorFilter == "all" ? "No \(model.kind == .skill ? "skills" : "MCP servers") in this scope" : "No matching resources",
                           description: model.query.isEmpty && model.harnessFilter == "all" && model.creatorFilter == "all" ? "Add a repository or refresh after an installation" : "Try a different search or clear the filters")
            } else {
                GeometryReader { proxy in
                    ResourceTable(model: model, showSource: proxy.size.width > 760)
                }
            }
            Rule()
            HStack(spacing: 12) {
                let total = model.filteredRows.count
                Text(total == 0 ? "0 resources" : "\(model.page * model.pageSize + 1)–\(min(total, (model.page + 1) * model.pageSize)) of \(total)")
                    .font(TypeStyle.mono).foregroundStyle(Ink.secondary)
                Spacer()
                Text("Page \(model.page + 1) of \(model.pageCount)").font(TypeStyle.small).foregroundStyle(Ink.muted)
                Button { model.page = max(0, model.page - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(PlainIconStyle()).disabled(model.page == 0).accessibilityLabel("Previous page")
                Button { model.page = min(model.pageCount - 1, model.page + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(PlainIconStyle()).disabled(model.page + 1 >= model.pageCount).accessibilityLabel("Next page")
            }.frame(height: 48)
        }.frame(maxHeight: .infinity)
    }
    private func resourceTab(_ title: String, kind: ResourceKind, count: Int) -> some View {
        Button { model.kind = kind } label: {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: model.kind == kind ? .medium : .regular))
                    Text(count.formatted()).font(TypeStyle.mono).foregroundStyle(Ink.muted)
                }.foregroundStyle(model.kind == kind ? Ink.primary : Ink.secondary).frame(height: 42)
                Rectangle().fill(model.kind == kind ? Ink.primary : Color.clear).frame(height: 2)
            }
        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false).accessibilityAddTraits(model.kind == kind ? .isSelected : [])
    }
    private func filterMenu(_ title: String, selection: Binding<String>, values: [(String, String)]) -> some View {
        Menu {
            Picker(title, selection: selection) {
                Text(title).tag("all")
                ForEach(values, id: \.0) { value in Text(value.1).tag(value.0) }
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(values.first { $0.0 == selection.wrappedValue }?.1 ?? title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10))
            }.foregroundStyle(Ink.secondary).padding(.horizontal, 12).frame(height: 36)
                .background(Ink.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.rule, lineWidth: 1))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel(title)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            if !model.snapshot.warnings.isEmpty {
                Button {
                    model.sheetError = nil; model.sheet = .init(content: .warnings)
                } label: {
                    HStack(spacing: 6) { Image(systemName: "exclamationmark.triangle"); Text("\(model.snapshot.warnings.count) scan notices") }
                }.buttonStyle(.plain).font(TypeStyle.small).foregroundStyle(Ink.secondary)
            } else {
                Text("Configured, not connected").font(TypeStyle.small).foregroundStyle(Ink.muted)
            }
            Spacer()
            Text(model.isLoading ? "Refreshing" : model.hasLoaded ? "Updated \(model.snapshot.scannedAt.formatted(date: .omitted, time: .shortened))" : "Local files only")
                .font(TypeStyle.mono).foregroundStyle(Ink.muted)
        }
    }
    private func message(_ text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 16))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { model.errorMessage = nil; model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.foregroundStyle(isError ? Ink.danger : Ink.secondary).padding(12).background(Ink.raised, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
    }
}

@MainActor func emptyState(symbol: String?, title: String, description: String, loading: Bool = false) -> some View {
    VStack(spacing: 16) {
        if loading { ProgressView().controlSize(.small) }
        else if let symbol { Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(Ink.muted) }
        VStack(spacing: 8) {
            Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Ink.primary)
            Text(description).font(.system(size: 13)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
        }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
}

private struct ResourceTable: View {
    @Bindable var model: AppModel
    let showSource: Bool
    var body: some View {
        Table(model.pageRows, selection: $model.focusedRowID) {
            TableColumn("") { row in
                Toggle("Select \(row.item.title)", isOn: Binding(get: { model.selectedIDs.contains(row.id) }, set: { _ in model.toggle(row) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(row.isProtected || model.busy)
                    .help(row.isProtected ? row.item.readOnlyReason ?? "Protected installation" : "Select installation")
            }.width(24)
            TableColumn("Resource") { row in
                VStack(alignment: .leading, spacing: 6) {
                    (Text(row.item.title).foregroundColor(row.item.inherited ? Ink.secondary : Ink.primary)
                     + Text(row.item.inherited ? " (globally installed)" : "").foregroundColor(Ink.muted))
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(row.item.description).font(.system(size: 12)).foregroundStyle(Ink.muted).lineLimit(1)
                }.frame(height: 56, alignment: .leading).help(row.item.description)
            }.width(min: 220, ideal: 300)
            if showSource {
                TableColumn("Creator / source") { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.item.provenance.creator ?? "Unknown").font(.system(size: 12)).foregroundStyle(Ink.secondary).lineLimit(1)
                        Text(row.item.provenance.sourceLabel ?? row.item.displayPath).font(TypeStyle.mono).foregroundStyle(Ink.muted).lineLimit(1).truncationMode(.middle)
                    }.help(row.item.provenance.sourceLabel ?? row.item.displayPath)
                }.width(min: 140, ideal: 180, max: 220)
            }
            TableColumn("Harness") { row in
                HStack(spacing: 4) {
                    Text(model.harnessName[row.harnessIDs.first ?? ""] ?? "Shared").lineLimit(1)
                    if row.harnessIDs.count > 1 { Text("+\(row.harnessIDs.count - 1)").font(TypeStyle.mono).foregroundStyle(Ink.muted) }
                }.font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .help(row.harnessIDs.compactMap { model.harnessName[$0] }.joined(separator: ", "))
            }.width(min: 90, ideal: 100, max: 128)
            TableColumn("State") { row in
                Text(row.state).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }.width(76)
            TableColumn("") { row in
                Button { model.inspected = row } label: { Image(systemName: "info.circle") }
                    .buttonStyle(PlainIconStyle()).accessibilityLabel("Details for \(row.item.title)").help("Show details")
            }.width(32)
        }.tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = model.pageRows.first(where: { $0.id == id }) {
                    Button("Show details") { model.inspected = row }
                    Button("Reveal in Finder") { model.reveal(row.item.sourcePath) }
                    if let item = row.removalItem { Divider(); Button("Uninstall…", role: .destructive) { model.requestRemoval([item]) }.disabled(model.busy) }
                }
            } primaryAction: { ids in
                if let id = ids.first { model.inspected = model.pageRows.first { $0.id == id } }
            }
    }
}
