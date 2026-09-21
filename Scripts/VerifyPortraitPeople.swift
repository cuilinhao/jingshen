import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// Invoked by VerifyPortraitPeople.sh; compiles against the real Core + Imaging sources.
/// No sample coordinates, image paths or model paths are embedded in this probe.
@main struct VerifyPortraitPeople {
    private struct VerificationFailure: Error { let message: String }
    private struct Arguments {
        let image: URL
        let models: URL
        let output: URL
        let expectedCount: Int
        let clicks: [UnitPoint2D]

        init(_ values: [String]) throws {
            guard values.count >= 5, let count = Int(values[3]), (1...4).contains(count),
                  values.count - 4 == count, !values[0].isEmpty, !values[1].isEmpty, !values[2].isEmpty else {
                throw VerificationFailure(message: "Expected IMAGE MODELS.bundle OUTPUT_DIR COUNT and one X,Y click per person; COUNT must be 1–4.")
            }
            image = URL(fileURLWithPath: values[0]).standardizedFileURL.resolvingSymlinksInPath()
            models = URL(fileURLWithPath: values[1]).standardizedFileURL
            output = URL(fileURLWithPath: values[2], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            expectedCount = count
            clicks = try values.dropFirst(4).map { value in
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
                      x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                    throw VerificationFailure(message: "Click coordinates must be finite X,Y values in [0,1].")
                }
                return UnitPoint2D(x: x, y: y)
            }
        }
    }
    private struct ClickResult: Codable {
        let clickIndex: Int
        let point: UnitPoint2D
        let selectedID: UInt8
        let coverage: UInt8
    }
    private struct Report: Codable {
        let expectedCount: Int
        let actualCount: Int
        let processedWidth: Int
        let processedHeight: Int
        let segmentationID: String
        let preparationSeconds: Double
        let aperture: Double
        let clicks: [ClickResult]
        let files: [String]
    }

    static func main() async {
        do {
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            try await verify(args)
        } catch let failure as VerificationFailure {
            fputs("FAIL \(failure.message)\n", stderr)
            exit(2)
        } catch {
            // File errors can contain the private input path. Report only their domain/code.
            let failure = error as NSError
            fputs("FAIL verification aborted (\(failure.domain), code \(failure.code)); no result was accepted.\n", stderr)
            exit(1)
        }
    }

    private static func verify(_ args: Arguments) async throws {
        guard let bundle = Bundle(url: args.models),
              bundle.url(forResource: DepthModelChoice.v3.resourceName, withExtension: "mlmodelc") != nil else {
            throw VerificationFailure(message: "The supplied bundle must contain the compiled V3 Base 504 model.")
        }
        let context = CIContext(options: [.workingColorSpace: ImageSupport.linearColorSpace,
                                          .outputColorSpace: ImageSupport.colorSpace])
        let pipeline = PhotoPipeline(depthEstimator: OfflineDepthEstimator(context: context, bundle: bundle, modelChoice: .v3))
        let data = try await pipeline.readFile(args.image)
        let started = Date()
        let photo = try await pipeline.prepare(data: data, title: "portrait-people-verification", modelChoice: .v3)
        let preparationSeconds = Date().timeIntervalSince(started)
        guard let people = photo.portrait else {
            throw VerificationFailure(message: "No independently selectable portrait analysis was returned.")
        }
        let actualCount = people.segmentation.subjects.count
        print("PREPARED count=\(actualCount) expected=\(args.expectedCount) seconds=\(preparationSeconds)")
        guard actualCount == args.expectedCount else {
            throw VerificationFailure(message: "Independent person count does not match the expectation.")
        }

        var selectedIDs = Set<UInt8>()
        var clicks: [ClickResult] = []
        for (index, point) in args.clicks.enumerated() {
            guard let id = people.selectedPerson(at: point, currentID: nil),
                  let person = people.person(id: id) else {
                throw VerificationFailure(message: "Click \(index + 1) did not hit an independently selectable person.")
            }
            guard selectedIDs.insert(id).inserted else {
                throw VerificationFailure(message: "Click \(index + 1) selected a duplicate person ID.")
            }
            let result = ClickResult(clickIndex: index + 1, point: point, selectedID: id, coverage: person.mask.value(at: point))
            clicks.append(result)
            print("CLICK \(result.clickIndex) id=\(id) coverage=\(result.coverage)")
        }
        guard selectedIDs == Set(people.segmentation.subjects.map(\.id)) else {
            throw VerificationFailure(message: "The click set did not cover every independent person.")
        }

        let ids = selectedIDs.sorted()
        let files = ids.flatMap { ["focus-id-\($0).png", "mask-id-\($0).png"] } + ["verification.json"]
        let manager = FileManager.default
        for name in files {
            let destination = args.output.appendingPathComponent(name).resolvingSymlinksInPath()
            guard destination != args.image, !manager.fileExists(atPath: destination.path) else {
                throw VerificationFailure(message: "An output file already exists or overlaps the input image; choose a fresh output directory.")
            }
        }
        try manager.createDirectory(at: args.output, withIntermediateDirectories: true)

        for id in ids {
            guard let click = clicks.first(where: { $0.selectedID == id }), let person = people.person(id: id) else {
                throw VerificationFailure(message: "Selection changed unexpectedly during export.")
            }
            var recipe = EditRecipe()
            recipe.selectedPersonID = id
            recipe.focusPoint = click.point
            recipe.aperture = 1.8
            let result = try await pipeline.export(photo: photo, recipe: recipe)
            try savePNG(result.image, to: args.output.appendingPathComponent("focus-id-\(id).png"))
            let mask = try ImageSupport.grayImage(width: person.mask.width, height: person.mask.height, bytes: Array(person.mask.bytes))
            try savePNG(mask, to: args.output.appendingPathComponent("mask-id-\(id).png"))
            print("EXPORTED focus-id-\(id).png mask-id-\(id).png")
        }
        let report = Report(expectedCount: args.expectedCount, actualCount: actualCount,
                            processedWidth: photo.original.width, processedHeight: photo.original.height,
                            segmentationID: people.segmentationID, preparationSeconds: preparationSeconds,
                            aperture: 1.8, clicks: clicks, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: args.output.appendingPathComponent("verification.json"), options: .atomic)
        print("PASS all \(actualCount) click targets are distinct; exported every selection and mask using the current project pipeline")
    }

    private static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VerificationFailure(message: "Could not create an output PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VerificationFailure(message: "Could not finalize an output PNG.")
        }
    }
}
