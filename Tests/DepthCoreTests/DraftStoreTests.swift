import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class DraftStoreTests: XCTestCase {
    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDraftTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sample() -> SavedDraft {
        SavedDraft(sourceData: Data([1,2,3,4]), title: "sample", recipe: EditRecipe(),
                   analysis: .localFallback(reason: "test"), imageSize: PixelSize(width: 100, height: 200))
    }
    func testEmptyStoreHasNoDraft() async throws {
        let store = DraftStore(root: try location())
        let value = try await store.load()
        XCTAssertNil(value)
    }
    func testCurrentDraftRoundTripStoresTypedAnalysisAndRecipe() async throws {
        let root = try location(), store = DraftStore(root: root), input = sample()
        try await store.save(input)
        let result = try await store.load()
        let value = try XCTUnwrap(result)
        XCTAssertEqual(value.sourceData, input.sourceData)
        XCTAssertEqual(value.analysis, input.analysis)
        XCTAssertEqual(value.imageSize, input.imageSize)
        XCTAssertEqual(value.recipe, input.recipe)
    }
    func testPreviousCompleteDraftSurvivesRejectedSave() async throws {
        let root = try location(), store = DraftStore(root: root)
        try await store.save(sample())
        let broken = SavedDraft(sourceData: Data(), title: "bad", recipe: EditRecipe(), analysis: nil, imageSize: nil)
        do { try await store.save(broken); XCTFail("Expected invalid source rejection") } catch { }
        let result = try await store.load()
        XCTAssertEqual(result?.title, "sample")
    }
    func testLegacyAIDepthIsDiscardedNotMislabeledAsNative() async throws {
        let root = try location(), id = UUID().uuidString
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(id).write(to: root.appendingPathComponent("current.json"))
        try Data([1,2,3]).write(to: folder.appendingPathComponent("source.data"))
        let metadata = #"{"version":1,"title":"legacy","origin":"ai","recipe":{"schemaVersion":1,"aperture":5.6,"focusPoint":{"x":0.2,"y":0.6}}}"#
        try Data(metadata.utf8).write(to: folder.appendingPathComponent("recipe.json"))
        // Even a valid v1 depth cache MUST NOT be reused as native or subject data.
        let field = try DepthField(width: 2, height: 2, values: [0,1,0,1])
        try JSONEncoder().encode(field).write(to: folder.appendingPathComponent("depth.json"))
        let loaded = try await DraftStore(root: root).load()
        let result = try XCTUnwrap(loaded)
        XCTAssertNil(result.analysis)
        XCTAssertEqual(result.recipe.aperture, 5.6)
        XCTAssertEqual(result.recipe.focusPoint, UnitPoint2D(x: 0.2, y: 0.6))
    }
    func testCorruptAnalysisIsRecoverableWithoutLosingOriginalAndEdits() async throws {
        let root = try location(), store = DraftStore(root: root)
        try await store.save(sample())
        let id = try JSONDecoder().decode(String.self, from: Data(contentsOf: root.appendingPathComponent("current.json")))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(id).appendingPathComponent("analysis.plist"))
        let loaded = try await store.load()
        XCTAssertNil(loaded?.analysis)
        XCTAssertEqual(loaded?.sourceData, sample().sourceData)
        XCTAssertEqual(loaded?.recipe, sample().recipe)
    }
    func testPointerCannotEscapeDraftDirectory() async throws {
        let root = try location()
        try JSONEncoder().encode("../../anything").write(to: root.appendingPathComponent("current.json"))
        do { _ = try await DraftStore(root: root).load(); XCTFail("Expected invalid pointer rejection") } catch { }
    }
    func testNewSnapshotCleansOnlyOwnUUIDDirectories() async throws {
        let root = try location(), store = DraftStore(root: root)
        let unrelated = root.appendingPathComponent("keep-me.txt")
        try Data([1]).write(to: unrelated)
        try await store.save(sample())
        try await store.save(sample())
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(contents.contains("keep-me.txt"))
        XCTAssertEqual(contents.filter { UUID(uuidString: $0) != nil }.count, 1)
    }
    func testV3DraftPersistsEditedLayersUnknownAndFocusTogether() async throws {
        let root = try location(),store = DraftStore(root:root)
        let labels = try GrayMask(width:4,height:1,bytes:Data([3,3,1,0]))
        let scene = LayeredScene(map:try SceneLayerMap(labels:labels,provenance:.user),subjects:nil,notice:nil)
        var recipe = EditRecipe();recipe.focusPoint = .init(x:1.0/3,y:0)
        let input = SavedDraft(sourceData:Data([1,2,3]),title:"edited",recipe:recipe,analysis:.layered(scene),imageSize:.init(width:400,height:100))
        try await store.save(input)
        let loaded = try await store.load()
        let output = try XCTUnwrap(loaded)
        XCTAssertEqual(output.recipe.schemaVersion,4)
        XCTAssertEqual(output.analysis,input.analysis)
        let masks = try FocusMaskBuilder.make(analysis:try XCTUnwrap(output.analysis),recipe:output.recipe,imageSize:.init(width:400,height:100))
        XCTAssertEqual(Array(masks.blur.bytes),[0,0,255,0])
    }

}
