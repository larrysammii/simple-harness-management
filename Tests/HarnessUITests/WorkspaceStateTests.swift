import Foundation
import XCTest
import HarnessCore
@testable import HarnessManager

final class WorkspaceStateTests: XCTestCase, @unchecked Sendable {
    @MainActor func testNativeScopeProjectionAndProtectedSelection() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let model = AppModel(options: fixture.options, demo: fixture)
        await model.refresh(); XCTAssertNil(model.errorMessage); XCTAssertTrue(model.hasLoaded)
        let protected = try XCTUnwrap(model.rows.first { $0.isProtected })
        model.toggle(protected); XCTAssertTrue(model.selectedIDs.isEmpty)
        model.selectAllMatching()
        XCTAssertEqual(model.selectedIDs.count, model.removableRows.count)
        XCTAssertTrue(model.selectedRows.allSatisfy { !$0.isProtected })
        let repo = try XCTUnwrap(model.snapshot.repositories.first)
        model.scopeID = repo.id
        XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertEqual(model.page, 0)
        XCTAssertTrue(model.rows.contains { $0.item.inherited })
        XCTAssertTrue(model.rows.filter { $0.item.inherited }.allSatisfy(\.isProtected))
    }
    @MainActor func testFiltersClearSelectionButPaginationRetainsIt() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        for index in 0..<35 {
            let folder = FS.join(fixture.options.home, ".claude/skills/page-\(index)")
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try FS.atomicWrite(FS.join(folder, "SKILL.md"), text: "---\nname: page-\(index)\ndescription: Synthetic pagination fixture\n---\n")
        }
        let model = AppModel(options: fixture.options, demo: fixture); await model.refresh()
        XCTAssertGreaterThan(model.pageCount, 1)
        let row = try XCTUnwrap(model.pageRows.first { !$0.isProtected })
        model.toggle(row); model.page = 1
        XCTAssertTrue(model.selectedIDs.contains(row.id))
        model.query = "page-"; XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertEqual(model.page, 0)
        model.selectAllMatching(); XCTAssertEqual(model.selectedIDs.count, 35)
        model.harnessFilter = "claude"; XCTAssertTrue(model.selectedIDs.isEmpty)
        model.selectPage(); XCTAssertFalse(model.selectedIDs.isEmpty)
        model.creatorFilter = "Unknown"; XCTAssertTrue(model.selectedIDs.isEmpty)
        model.kind = .mcp; XCTAssertTrue(model.selectedIDs.isEmpty)
    }
    @MainActor func testCancelDoesNotCreateBackupsOrChangeInstallations() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let model = AppModel(options: fixture.options, demo: fixture); await model.refresh()
        let row = try XCTUnwrap(model.rows.first { !$0.isProtected }), item = try XCTUnwrap(row.removalItem)
        model.requestRemoval([item]); XCTAssertNotNil(model.sheet)
        model.sheet = nil
        XCTAssertTrue(FS.exists(item.sourcePath))
        let backups = try await model.manager.listBackups(); XCTAssertTrue(backups.isEmpty)
    }
    @MainActor func testConfirmedRemovalRefreshesSelectionAndCanRestore() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let model = AppModel(options: fixture.options, demo: fixture); await model.refresh()
        let row = try XCTUnwrap(model.rows.first { $0.item.name == "project-planning" }), item = try XCTUnwrap(row.removalItem)
        model.toggle(row); model.requestSelectedRemoval()
        let sheet = try XCTUnwrap(model.sheet)
        await model.apply(sheet.content, confirmation: "wrong")
        XCTAssertNotNil(model.sheetError); XCTAssertNotNil(model.sheet); XCTAssertTrue(FS.exists(item.sourcePath))
        await model.apply(sheet.content, confirmation: "UNINSTALL 1")
        XCTAssertNil(model.sheet); XCTAssertTrue(model.selectedIDs.isEmpty); XCTAssertFalse(FS.exists(item.sourcePath))
        let backup = try XCTUnwrap(model.snapshot.backups.first { $0.canRestore })
        model.requestRestore(backup)
        await model.apply(try XCTUnwrap(model.sheet).content, confirmation: "")
        XCTAssertTrue(FS.exists(item.sourcePath))
    }
    @MainActor func testSectionChangeClearsSearchAndSelection() async throws {
        let fixture = try DemoEnvironment.create(); defer { try? fixture.cleanUp() }
        let model = AppModel(options: fixture.options, demo: fixture); await model.refresh()
        model.query = "review"; model.selectAllMatching(); model.section = .packages
        XCTAssertEqual(model.query, ""); XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertFalse(model.scopedPackages.isEmpty)
        let repo = try XCTUnwrap(model.snapshot.repositories.first { $0.name == "design-system" })
        model.scopeID = repo.id
        XCTAssertTrue(model.scopedPackages.contains { $0.inherited && !$0.canUninstall })
    }
}
