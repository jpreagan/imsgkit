import Foundation

enum AttachmentResolver {
  static func resolve(_ path: String) -> (resolved: String, missing: Bool) {
    guard !path.isEmpty else {
      return ("", true)
    }

    let expanded = (path as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
    return (expanded, !(exists && !isDirectory.boolValue))
  }
}
