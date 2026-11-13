import AppKit
import Foundation
import HarnessCore
import Observation

struct ResourceRow: Identifiable, Hashable {
    let id: String
    let entries: [InventoryItem]
    var item: InventoryItem { entries.first! }
    var removalItem: InventoryItem? { entries.first { $0.canUninstall && !$0.inherited } }
    var isProtected: Bool { removalItem == nil }
    var harnessIDs: [String] { Array(Set(entries.map(\.harnessID))).sorted() }
    var state: String {
        if item.inherited { return "Inherited" }
        if item.packageName != nil { return entries.contains(where: \.enabled) ? "Package" : "Disabled" }
        if Set(entries.map(\.enabled)).count > 1 { return "Mixed" }
        if !item.enabled { return "Disabled" }
        return isProtected ? "Read-only" : "Installed"
    }
}

enum WorkspaceSection: String, CaseIterable { case inventory, packages, backups }
enum SheetContent {
    case removal(items: [InventoryItem], scopeID: String, scopeName: String)
    case package(PackageInstallation, scopeName: String)
    case restore(BackupInfo)
    case warnings
}
struct AppSheet: Identifiable {
    let id = UUID()
    let content: SheetContent
}

@MainActor @Observable
final class AppModel {
    let manager: InventoryManager
    let options: ManagerOptions
    let demo: DemoEnvironment?
    var snapshot = InventorySnapshot()
    var isLoading = true
    var isMutating = false
    var hasLoaded = false
    var errorMessage: String?
    var notice: String?
    var sheetError: String?
    var sheet: AppSheet?
    var inspected: ResourceRow?
    var scopeID = "global" { didSet { resetSelection(); inspected = nil } }
    var section = WorkspaceSection.inventory { didSet { resetSelection(); inspected = nil; query = "" } }
    var kind = ResourceKind.skill { didSet { resetSelection(); inspected = nil; creatorFilter = "all" } }
    var query = "" { didSet { resetSelection() } }
    var harnessFilter = "all" { didSet { resetSelection() } }
    var creatorFilter = "all" { didSet { resetSelection() } }
    var repositoryQuery = ""
    var selectedIDs: Set<String> = []
    var focusedRowID: String?
    var page = 0
    let pageSize = 25

    init(options supplied: ManagerOptions? = nil, demo suppliedDemo: DemoEnvironment? = nil) {
        if let supplied {
            options = supplied; demo = suppliedDemo
        } else if CommandLine.arguments.contains("--demo") {
            do {
                let fixture = try DemoEnvironment.create(); demo = fixture; options = fixture.options
            } catch {
                // A failed demo never falls back to the real home directory.
                let temporary = FS.join(FileManager.default.temporaryDirectory.path, "harness-manager-unavailable-" + UUID().uuidString)
                demo = nil; options = .init(home: temporary, scanRoots: [], stateDir: temporary + "/state")
                errorMessage = "Synthetic demo could not be prepared; real installations were not accessed"
            }
        } else { demo = nil; options = .live() }
        manager = InventoryManager(options: options)
        if let index = CommandLine.arguments.firstIndex(of: "--section"), CommandLine.arguments.indices.contains(index + 1) {
            switch CommandLine.arguments[index + 1] {
            case "mcp": kind = .mcp
            case "packages": section = .packages
            case "backups": section = .backups
            default: break
            }
        }
    }
    var isDemo: Bool { demo != nil || CommandLine.arguments.contains("--demo") }
    var busy: Bool { isLoading || isMutating }
    var scopeName: String { scopeID == "global" ? "Global installations" : snapshot.repositories.first { $0.id == scopeID }?.name ?? "Repository" }
    var scopePath: String { scopeID == "global" ? "Across configured harness locations" : snapshot.repositories.first { $0.id == scopeID }?.displayPath ?? "" }
    var harnessName: [String: String] { Dictionary(uniqueKeysWithValues: snapshot.harnesses.map { ($0.id, $0.name) }) }
    var scopedItems: [InventoryItem] { snapshot.items(in: scopeID) }
    var rows: [ResourceRow] {
        let items = scopedItems.filter { $0.kind == kind }
        let groups = Dictionary(grouping: items) { item in
            FS.id(item.kind.rawValue, item.sourcePath, item.name, String(item.inherited))
        }
        return groups.map { ResourceRow(id: $0.key, entries: $0.value.sorted { $0.harnessID < $1.harnessID }) }.sorted {
            if $0.item.inherited != $1.item.inherited { return !$0.item.inherited }
            let result = $0.item.title.localizedStandardCompare($1.item.title)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
    }
    var filteredRows: [ResourceRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { row in
            if harnessFilter != "all" && !row.harnessIDs.contains(harnessFilter) { return false }
            if creatorFilter != "all" && (row.item.provenance.creator ?? "Unknown") != creatorFilter { return false }
            guard !needle.isEmpty else { return true }
            return [row.item.title, row.item.description, row.item.displayPath, row.item.provenance.creator ?? "",
                    row.item.provenance.sourceLabel ?? "", row.harnessIDs.compactMap { harnessName[$0] }.joined(separator: " ")]
                .contains { $0.localizedStandardContains(needle) }
        }
    }
    var pageRows: [ResourceRow] { Array(filteredRows.dropFirst(page * pageSize).prefix(pageSize)) }
    var pageCount: Int { max(1, (filteredRows.count + pageSize - 1) / pageSize) }
    var selectedRows: [ResourceRow] { filteredRows.filter { selectedIDs.contains($0.id) } }
    var removableRows: [ResourceRow] { filteredRows.filter { !$0.isProtected } }
    var creators: [String] { Array(Set(rows.map { $0.item.provenance.creator ?? "Unknown" })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var shownRepositories: [Repository] {
        snapshot.repositories.filter { repositoryQuery.isEmpty || $0.name.localizedStandardContains(repositoryQuery) || $0.displayPath.localizedStandardContains(repositoryQuery) }
    }
    var skillsCount: Int { uniqueCount(kind: .skill) }
    var mcpCount: Int { uniqueCount(kind: .mcp) }
    var activeHarnessCount: Int { Set(scopedItems.map(\.harnessID).filter { $0 != "shared" }).count }
    var scopedPackages: [PackageInstallation] {
        snapshot.packages(in: scopeID).filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.provenance.creator ?? "").localizedStandardContains(query) }
    }
    var shownBackups: [BackupInfo] {
        snapshot.backups.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.sourcePath.localizedStandardContains(query) }
    }
    func uniqueCount(kind: ResourceKind) -> Int {
        Set(scopedItems.filter { $0.kind == kind }.map { "\($0.sourcePath):\($0.name):\($0.inherited)" }).count
    }
    func resetSelection() { selectedIDs = []; page = 0 }
    func toggle(_ row: ResourceRow) {
        guard !busy, !row.isProtected else { return }
        if selectedIDs.contains(row.id) { selectedIDs.remove(row.id) }
        else if selectedIDs.count < 1000 { selectedIDs.insert(row.id) }
        else { errorMessage = "Select at most 1,000 installations per operation" }
    }
    func selectPage() {
        let ids = Set(pageRows.filter { !$0.isProtected }.map(\.id))
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) }
        else if selectedIDs.union(ids).count <= 1000 { selectedIDs.formUnion(ids) }
        else { errorMessage = "Select at most 1,000 installations per operation" }
    }
    func selectAllMatching() {
        guard removableRows.count <= 1000 else { errorMessage = "Narrow the filters to at most 1,000 removable installations"; return }
        selectedIDs = Set(removableRows.map(\.id))
    }
    func requestRemoval(_ items: [InventoryItem]) {
        guard !busy, !items.isEmpty else { return }; sheetError = nil
        sheet = .init(content: .removal(items: items, scopeID: scopeID, scopeName: scopeName))
    }
    func requestSelectedRemoval() { requestRemoval(selectedRows.compactMap(\.removalItem)) }
    func requestPackage(_ package: PackageInstallation) {
        guard !busy, package.canUninstall else { return }; sheetError = nil
        sheet = .init(content: .package(package, scopeName: scopeName))
    }
    func requestRestore(_ backup: BackupInfo) {
        guard !busy, backup.canRestore else { return }; sheetError = nil
        sheet = .init(content: .restore(backup))
    }
    func refresh() async {
        guard !isMutating else { return }; isLoading = true; resetSelection()
        defer { isLoading = false; hasLoaded = true }
        do {
            snapshot = try await manager.snapshot()
            if scopeID != "global", !snapshot.repositories.contains(where: { $0.id == scopeID }) { scopeID = "global" }
            if let old = inspected { inspected = rows.first { $0.id == old.id } }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func apply(_ content: SheetContent, confirmation: String) async {
        guard !busy else { return }; isMutating = true; sheetError = nil
        defer { isMutating = false }
        do {
            let report: MutationReport
            switch content {
            case .removal(let items, let scopeID, _):
                report = try await manager.remove(requests: items.map(RemovalRequest.init), scopeID: scopeID, confirmation: confirmation)
            case .package(let package, _):
                report = try await manager.removePackage(id: package.id, fingerprint: package.fingerprint, scopeID: package.scopeID, confirmation: confirmation)
            case .restore(let backup): report = try await manager.restore(id: backup.id)
            case .warnings: return
            }
            notice = report.message; errorMessage = report.error
            sheet = nil; inspected = nil; resetSelection()
            snapshot = try await manager.snapshot()
        } catch { sheetError = error.localizedDescription }
    }
    func addRepository() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Add repository"; panel.prompt = "Add repository"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let path = panel.url?.path else { return }
            Task { @MainActor in
                guard let self else { return }; self.isMutating = true
                do { try await self.manager.addRepository(path: path); self.isMutating = false; await self.refresh() }
                catch { self.errorMessage = error.localizedDescription; self.isMutating = false }
            }
        }
    }
    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    func copyPath(_ path: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
}
