import Foundation

struct ResolvedAttachmentPath {
  let path: String
  let missing: Bool
  let replicaRelativePath: String?
}

enum AttachmentResolver {
  private static let defaultAttachmentsRoot = "~/Library/Messages/Attachments"

  static func resolve(_ path: String) -> ResolvedAttachmentPath {
    guard !path.isEmpty else {
      return ResolvedAttachmentPath(
        path: "",
        missing: true,
        replicaRelativePath: nil
      )
    }

    let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
    return ResolvedAttachmentPath(
      path: expanded,
      missing: !(exists && !isDirectory.boolValue),
      replicaRelativePath: replicaRelativePath(forResolvedPath: expanded)
    )
  }

  private static func replicaRelativePath(forResolvedPath path: String) -> String? {
    guard !path.isEmpty else {
      return nil
    }

    let root = ((defaultAttachmentsRoot as NSString).expandingTildeInPath as NSString)
      .standardizingPath
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else {
      return nil
    }

    let relative = String(path.dropFirst(prefix.count))
    return relative.isEmpty ? nil : relative
  }
}
