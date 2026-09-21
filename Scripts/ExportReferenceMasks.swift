import Foundation

/// Command-line validation of the SAME production mask code (does not use Core Image).
/// swiftc PGYDepthDemo/Core/*.swift Scripts/ExportReferenceMasks.swift -o /tmp/export-masks
/// /tmp/export-masks PGYDepthDemo/Resources/ReferenceLayers.json /tmp/reference-masks
@main
struct ExportReferenceMasks {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: export-masks ReferenceLayers.json OUTPUT_DIRECTORY"); return
        }
        let fixture = try JSONDecoder().decode(ReferenceLayerFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let map = try fixture.makeMap()
        let folder = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ mask: GrayMask, _ name: String) throws {
            var data = Data("P5\n\(mask.width) \(mask.height)\n255\n".utf8); data.append(mask.bytes)
            try data.write(to: folder.appendingPathComponent(name))
        }
        try write(map.labels,"labels.pgm")
        try write(map.focusMasks(at:.init(x:0.47,y:0.77),tolerance:0.035).blur,"near-focus.pgm")
        try write(map.focusMasks(at:.init(x:0.79,y:0.58),tolerance:0.035).blur,"far-focus.pgm")
        print("Exported production masks: \(map.labels.width)×\(map.labels.height), \(map.provenance.title), known=\(map.knownLayers.map(\.title))")
    }
}
