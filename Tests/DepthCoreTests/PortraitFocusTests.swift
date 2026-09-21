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
    private func narrowCorePortrait() throws -> PortraitAnalysis {
        let side = 1024
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes[103 * side + 101] = 255
        let mask = try GrayMask(width: side, height: side, bytes: Data(bytes))
        return try PortraitAnalysis(segmentation: .init(
            labels: .init(width: side, height: side, bytes: Data(bytes.map { $0 > 0 ? 1 : 0 })),
            subjects: [.init(id: 1, mask: mask)]), sourceSHA256: String(repeating: "a", count: 64),
            imageSize: .init(width: side, height: side))
    }
    func testAnchorFindsNarrowCoreBetweenCoarseSamplePoints() throws {
        let people = try narrowCorePortrait()
        let anchor = try XCTUnwrap(people.anchor(for: 1))
        XCTAssertEqual(anchor.x, 101.0 / 1023, accuracy: 0.000001)
        XCTAssertEqual(anchor.y, 103.0 / 1023, accuracy: 0.000001)
        XCTAssertEqual(people.person(id: 1)?.mask.value(at: anchor), 255)
    }
    func testFocusDepthMapsNarrowMaskCoreToDepthInsteadOfSamplingOutsidePerson() throws {
        let people = try narrowCorePortrait()
        let side = 257
        var values = [Float](repeating: 0.1, count: side * side)
        values[26 * side + 25] = 0.8
        let depth = try DepthField(width: side, height: side, values: values)
        XCTAssertEqual(depth.sample(at: .center), 0.1, accuracy: 0.001)
        XCTAssertEqual(people.focusDepth(depth: depth, selectedID: 1, point: .center), 0.8, accuracy: 0.001,
                       "深度采样网格未命中窄人物时，必须将人物可靠核心映射到深度图，不能取背景焦深")
    }
    func testPortraitCacheRequiresPhotoSizeAndSegmentationVersion() throws {
        let p = try portrait()
        XCTAssertTrue(p.matches(sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:500,height:100)))
        XCTAssertFalse(p.matches(sourceSHA256:String(repeating:"b",count:64),imageSize:.init(width:500,height:100)))
        XCTAssertFalse(p.matches(sourceSHA256:String(repeating:"a",count:64),imageSize:.init(width:100,height:500)))
        var stale = p; stale.segmentationID = "old"
        XCTAssertFalse(stale.matches(sourceSHA256:p.sourceSHA256,imageSize:p.imageSize))
    }
    func testUnrefinedPersonMaskCacheIsNotReusedAfterRefinementUpdate() throws {
        var old = try portrait()
        for version in ["vision-person-instance-r1-2048-v1", "vision-person-instance-r1-2048-core230-band32-v2"] {
            old.segmentationID = version
            XCTAssertFalse(old.matches(sourceSHA256: old.sourceSHA256, imageSize: old.imageSize),
                           "旧整图缓存可能漏掉背景小人，必须执行多尺度识别后再缓存")
        }
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
    func testNewSegmentationUsesSavedPointInsteadOfReassignedID() throws {
        let people = try portrait()
        var old = EditRecipe(); old.selectedPersonID = 1; old.focusPoint = .init(x: 0.9, y: 0.5)
        XCTAssertEqual(people.restoringSelection(in: old, cacheReused: false).selectedPersonID, 2)
        let cached = people.restoringSelection(in: old, cacheReused: true)
        XCTAssertEqual(cached.selectedPersonID, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(people.person(id: 1)).mask.value(at: cached.focusPoint), 64)
        var local = old; local.focusMode = .local
        XCTAssertEqual(people.restoringSelection(in: local, cacheReused: false).focusPoint, local.focusPoint)
        XCTAssertEqual(people.restoringSelection(in: local, cacheReused: false).selectedPersonID, 2)
        let fresh = people.restoringSelection(in: EditRecipe(), cacheReused: false)
        XCTAssertNotNil(fresh.selectedPersonID)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(people.person(id: fresh.selectedPersonID)).mask.value(at: fresh.focusPoint), 64)
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
