import Foundation

struct SavedDraft: Sendable {
    let sourceData: Data
    let title: String
    let recipe: EditRecipe
    /// Nil means reanalyze the original. This is how legacy/external-model caches are migrated.
    let analysis: PhotoAnalysis?
    let imageSize: PixelSize?
    let portrait: PortraitAnalysis?
    init(sourceData: Data, title: String, recipe: EditRecipe, analysis: PhotoAnalysis?,
         imageSize: PixelSize?, portrait: PortraitAnalysis? = nil) {
        self.sourceData = sourceData; self.title = title; self.recipe = recipe
        self.analysis = analysis; self.imageSize = imageSize; self.portrait = portrait
    }
}

enum DraftDataError: Error, LocalizedError {
    case incompatible, invalidSource
    var errorDescription: String? {
        switch self {
        case .incompatible: return "草稿版本或数据不兼容，请重新导入原图。"
        case .invalidSource: return "草稿原始照片为空、已损坏或超过 100 MB。"
        }
    }
}

/// Foundation-only persistence, also compiled and tested on Linux.
/// original + typed analysis + recipe are committed together by replacing a small pointer last.
actor DraftStore {
    private struct Metadata: Codable {
        var version: Int
        var title: String
        var recipe: EditRecipe
        var sourceByteCount: Int?
        var imageSize: PixelSize?
    }
    private let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PGYDepthDraft", isDirectory: true)
    }

    func load() throws -> SavedDraft? {
        try Task.checkCancellation()
        let pointer = root.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let id = try JSONDecoder().decode(String.self, from: read(pointer, maximumBytes: 1024))
        guard UUID(uuidString: id) != nil else { throw DraftDataError.incompatible }
        let folder = root.appendingPathComponent(id, isDirectory: true)
        let metadata = try JSONDecoder().decode(Metadata.self, from: read(folder.appendingPathComponent("recipe.json"), maximumBytes: 1024 * 1024))
        guard (1...5).contains(metadata.version) else { throw DraftDataError.incompatible }
        let source = try read(folder.appendingPathComponent("source.data"), maximumBytes: 100 * 1024 * 1024)
        guard !source.isEmpty, metadata.sourceByteCount == nil || metadata.sourceByteCount == source.count else {
            throw DraftDataError.invalidSource
        }
        var analysis: PhotoAnalysis?
        if metadata.version >= 2 {
            do {
                analysis = try PropertyListDecoder().decode(PhotoAnalysis.self,
                    from: read(folder.appendingPathComponent("analysis.plist"), maximumBytes: 80 * 1024 * 1024))
            } catch {
                print("[Draft] 分析缓存不可用，将根据原图重新识别：\(error.localizedDescription)")
            }
        } else {
            // v1's origin=ai depth.json is NOT a native depth map. Discard it and run the bundled estimator.
            print("[Draft] 迁移旧版草稿：保留原图和参数，不复用旧外部模型的深度缓存")
        }
        var portrait: PortraitAnalysis?
        if metadata.version >= 5 {
            portrait = try? PropertyListDecoder().decode(PortraitAnalysis.self,
                from: read(folder.appendingPathComponent("portrait.plist"), maximumBytes: 32 * 1024 * 1024))
        }
        return SavedDraft(sourceData: source, title: metadata.title, recipe: metadata.recipe,
                          analysis: analysis, imageSize: metadata.imageSize, portrait: portrait)
    }

    func save(_ draft: SavedDraft) throws {
        try Task.checkCancellation()
        guard !draft.sourceData.isEmpty, draft.sourceData.count <= 100 * 1024 * 1024 else { throw DraftDataError.invalidSource }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString, folder = root.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var recipe = draft.recipe; recipe.sanitize()
            let metadata = Metadata(version: 5, title: draft.title, recipe: recipe,
                                    sourceByteCount: draft.sourceData.count, imageSize: draft.imageSize)
            let json = JSONEncoder(); json.outputFormatting = [.prettyPrinted, .sortedKeys]
            try draft.sourceData.write(to: folder.appendingPathComponent("source.data"), options: .atomic)
            if let analysis = draft.analysis {
                let plist = PropertyListEncoder(); plist.outputFormat = .binary
                try plist.encode(analysis).write(to: folder.appendingPathComponent("analysis.plist"), options: .atomic)
            }
            if let portrait = draft.portrait {
                let plist = PropertyListEncoder(); plist.outputFormat = .binary
                try plist.encode(portrait).write(to: folder.appendingPathComponent("portrait.plist"), options: .atomic)
            }
            try json.encode(metadata).write(to: folder.appendingPathComponent("recipe.json"), options: .atomic)
            try Task.checkCancellation()
            try json.encode(id).write(to: root.appendingPathComponent("current.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        if let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for child in children where child.lastPathComponent != id && UUID(uuidString: child.lastPathComponent) != nil {
                try? fm.removeItem(at: child)
            }
        }
        let source = draft.analysis?.sourceDescription ?? "无可用分析缓存，下次重新计算"
        let depthInfo = draft.analysis?.continuousDepth.map { "，深度 \($0.width)×\($0.height)" } ?? ""
        print("[Draft] v5 已保存原图及编辑参数；分析来源=\(source)\(depthInfo)")
    }

    private func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes), size.int64Value >= 0 else {
            throw DraftDataError.incompatible
        }
        return try Data(contentsOf: url)
    }
}
