import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
let data = try JSONSerialization.data(withJSONObject: plist, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
