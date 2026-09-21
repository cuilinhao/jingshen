import XCTest
#if canImport(DepthCore)
@testable import DepthCore
#else
@testable import PGYDepthDemo
#endif

final class PortraitFocusTests: XCTestCase {
    private func portrait() throws -> PortraitAnalysis {
        let labels = try GrayMask(width: 5, height: 1, bytes: Data([1,1,0,2,2]))
        let a = try GrayMask(width: 5, height: 1, bytes: Data([255,255,0,0,0]))
        let b = try GrayMask(width: 5, height: 1, bytes: Data([0,0,0,255,255]))
        return try PortraitAnalysis(segmentation: SubjectSegmentation(labels: labels,
            subjects: [.init(id: 1, mask: a), .init(id: 2, mask: b)]),
            sourceSHA256: String(repeating: "a", count: 64), imageSize: .init(width: 500, height: 100))
    }
    func testSameDepthPeopleCanBeIndependentlyFocused() throws {
        let people = try portrait()
        let depth = try DepthField(width: 5, height: 1, values: [0.5,0.5,0.5,0.5,0.5])
        for id: UInt8 in [1,2] {
            let layers = people.layers(depth: depth, selectedID: id, focusPoint: .center)
            XCTAssertEqual(layers.first(where: { $0.subject.id == id })?.blurAmount, 0)
            XCTAssertGreaterThan(try XCTUnwrap(layers.first(where: { $0.subject.id != id })?.blurAmount), 0.5)
        }
        XCTAssertEqual(depth.values, [0.5,0.5,0.5,0.5,0.5], "人物选择不能改写真实深度")
    }
    func testBlankTapKeepsCurrentPersonAndClickSwitches() throws {
        let p = try portrait()
        XCTAssertEqual(p.selectedPerson(at: .center, currentID: 1), 1)
        XCTAssertEqual(p.selectedPerson(at: .init(x: 0.9,y: 0.5), currentID: 1), 2)
        XCTAssertNil(p.selectedPerson(at: .center, currentID: nil))
    }
    func testSoftEdgeCanBeSelectedWithoutSelectingDistantPerson() throws {
        let mask = try GrayMask(width: 5, height: 1, bytes: Data([0,80,255,0,0]))
        let p = try PortraitAnalysis(segmentation: .init(labels: .init(width:5,height:1,bytes:Data([0,1,1,0,0])),
            subjects:[.init(id:1,mask:mask)]), sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:500,height:100))
        XCTAssertEqual(p.selectedPerson(at:.init(x:0.25,y:0.5),currentID:nil),1)
        XCTAssertNil(p.selectedPerson(at:.init(x:1,y:0.5),currentID:nil))
        XCTAssertEqual(p.segmentation.subjects[0].mask.bytes[1],80)
    }
    func testLayerOrderKeepsDefocusedForegroundInFrontOfSelectedBackground() throws {
        let p = try portrait()
        let depth = try DepthField(width:5,height:1,values:[0.9,0.9,0.5,0.2,0.2])
        let layers = p.layers(depth:depth,selectedID:2,focusPoint:.init(x:0.9,y:0.5))
        XCTAssertEqual(layers.map { $0.subject.id },[2,1])
        XCTAssertGreaterThan(layers[1].blurAmount,0.5)
    }
    func testFocusDepthIgnoresBackgroundAtSoftBoundary() throws {
        let p = try portrait()
        let depth = try DepthField(width:5,height:1,values:[0.8,0.8,0.1,0.2,0.2])
        XCTAssertEqual(p.focusDepth(depth:depth,selectedID:1,point:.center),0.8,accuracy:0.001)
    }
    func testPortraitCacheRequiresPhotoSizeAndSegmentationVersion() throws {
        let p = try portrait()
        XCTAssertTrue(p.matches(sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:500,height:100)))
        XCTAssertFalse(p.matches(sourceSHA256:String(repeating:"b",count:64),imageSize:.init(width:500,height:100)))
        XCTAssertFalse(p.matches(sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:100,height:500)))
        var stale = p; stale.segmentationID = "old"
        XCTAssertFalse(stale.matches(sourceSHA256:p.sourceSHA256,imageSize:p.imageSize))
    }
    func testV4RecipeLoadsWithoutAStalePersonAndV5SelectionRoundTrips() throws {
        let legacy = Data("{\"schemaVersion\":4,\"focusPoint\":{\"x\":0.2,\"y\":0.3}}".utf8)
        let old = try JSONDecoder().decode(EditRecipe.self,from:legacy)
        XCTAssertNil(old.selectedPersonID)
        var recipe = EditRecipe(); recipe.selectedPersonID = 2
        let restored = try JSONDecoder().decode(EditRecipe.self,from:JSONEncoder().encode(recipe))
        XCTAssertEqual(restored.selectedPersonID,2)
        XCTAssertEqual(restored.schemaVersion,5)
    }
    func testCrowdedGroupsAreNotPresentedAsIndividualPeople() throws {
        let p = try portrait()
        let grouped = try SubjectSegmentation(labels:p.segmentation.labels,subjects:p.segmentation.subjects,groupedSubjectCount:2)
        XCTAssertThrowsError(try PortraitAnalysis(segmentation:grouped,sourceSHA256:p.sourceSHA256,imageSize:p.imageSize))
    }
    func testDraftRestoresPeopleAndSelectionTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = DraftStore(root:root), people = try portrait()
        var recipe = EditRecipe(); recipe.selectedPersonID = 2
        let draft = SavedDraft(sourceData:Data([1,2,3]),title:"people",recipe:recipe,analysis:nil,
            imageSize:people.imageSize,portrait:people)
        try await store.save(draft)
        let loaded = try await store.load()
        XCTAssertEqual(loaded?.portrait,people)
        XCTAssertEqual(loaded?.recipe.selectedPersonID,2)
    }
}
