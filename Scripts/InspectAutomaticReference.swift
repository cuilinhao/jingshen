import Foundation

/// Development-only validation. Compile with the production Core files; never part of App target.
/// Input is the CPU reference evaluator's real model output, not a hand-painted depth map.
@main
struct InspectAutomaticReference {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: inspect-reference <AutomaticReference.f32> <output-directory>")
            return
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard raw.count == 518*392*4 else { throw DepthDataError.invalidDimensions }
        let values: [Float] = raw.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        let depth = try DepthField.normalizing(width: 518, height: 392, values: values)
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let near = try ContinuousFocusMasks.make(depth: depth, point: .init(x: 0.4845360824742268, y: 0.7854381443298968), tolerance: 0.22)
        let far = try ContinuousFocusMasks.make(depth: depth, point: .init(x: 0.8393470790378006, y: 0.5483247422680413), tolerance: 0.22)
        for (name, bytes) in [("depth", Data(depth.bytes())), ("near-focus-blur", near.blur.bytes), ("far-focus-blur", far.blur.bytes)] {
            var file = Data("P5\n518 392\n255\n".utf8); file.append(bytes)
            try file.write(to: folder.appendingPathComponent(name + ".pgm"))
        }
        print("INDEPENDENT CPU MODEL REFERENCE + PRODUCTION SWIFT MASKS; NOT APPLE CORE ML OR iOS RENDER")
        print("Complete dense normalized field: \(depth.width)×\(depth.height), \(depth.values.count) finite samples")
        let taps: [UnitPoint2D] = [
            .init(x: 0.8393470790378006,y: 0.5483247422680413), .init(x: 0.7250859106529209,y: 0.5393041237113402),
            .init(x: 0.47079037800687284,y: 0.8537371134020618), .init(x: 0.49140893470790376,y: 0.7712628865979381),
            .init(x: 0.4845360824742268,y: 0.7854381443298968), .init(x: 0.7414089347079037,y: 0.5747422680412371),
            .init(x: 0.4845360824742268,y: 0.8698453608247421), .init(x: 0.49742268041237114,y: 0.8524484536082474)]
        print("Tap,x,y,normalized_depth,near_focus_blur_0_255,far_focus_blur_0_255")
        for (i, point) in taps.enumerated() {
            print("\(i+1),\(point.x),\(point.y),\(depth.sample(at: point)),\(near.blur.value(at: point)),\(far.blur.value(at: point))")
        }
        print("Region,x,y,normalized_depth,near_focus_blur_0_255,far_focus_blur_0_255")
        let regions: [(String, UnitPoint2D)] = [("monitor",.init(x: 0.15,y: 0.52)),("bottle",taps[4]),("yellow toy",.init(x: 0.21,y: 0.90)),("cabinet",taps[0])]
        for (name, point) in regions {
            print("\(name),\(point.x),\(point.y),\(depth.sample(at: point)),\(near.blur.value(at: point)),\(far.blur.value(at: point))")
        }
        print("Mask difference pixel count: \(zip(near.blur.bytes, far.blur.bytes).filter { $0 != $1 }.count)")
    }
}
