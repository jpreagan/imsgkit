import Foundation
import SQLite3

private struct ReplicaAttachmentReference: Sendable {
  let replicaRelativePath: String
}

enum ReplicaAttachmentMirrorError: Error, CustomStringConvertible {
  case openReplica(String)
  case prepare(String)
  case iterate(String)

  var description: String {
    switch self {
    case .openReplica(let message),
      .prepare(let message),
      .iterate(let message):
      return message
    }
  }
}

enum ReplicaAttachmentMirror {
  static let directoryName = "attachments"

  static func attachmentRoot(forReplicaDBPath replicaDBPath: String) -> String {
    let replicaURL = URL(fileURLWithPath: (replicaDBPath as NSString).expandingTildeInPath)
    return replicaURL.deletingLastPathComponent()
      .appendingPathComponent(directoryName, isDirectory: true)
      .path
  }

  static func refresh(replicaDBPath: String) throws {
    let mirrorRoot = attachmentRoot(forReplicaDBPath: replicaDBPath)
    let mirrorRootURL = URL(fileURLWithPath: mirrorRoot, isDirectory: true)
    let fileManager = FileManager.default

    try fileManager.createDirectory(at: mirrorRootURL, withIntermediateDirectories: true)
    try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mirrorRoot)

    let references = try loadReferences(replicaDBPath: replicaDBPath)
    var desiredPaths = Set<String>()
    for reference in references {
      guard isSafeRelativePath(reference.replicaRelativePath) else {
        continue
      }

      desiredPaths.insert(reference.replicaRelativePath)
      let destinationURL = mirrorRootURL.appendingPathComponent(
        reference.replicaRelativePath,
        isDirectory: false
      )
      let sourceURL = sourceURL(forReplicaRelativePath: reference.replicaRelativePath)
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try materialize(
        sourceURL: sourceURL,
        destinationURL: destinationURL
      )
    }

    try pruneStaleFiles(
      from: mirrorRootURL,
      keepingRelativePaths: desiredPaths,
      fileManager: fileManager
    )
  }

  private static func loadReferences(replicaDBPath: String) throws -> [ReplicaAttachmentReference] {
    var database: OpaquePointer?
    let path = (replicaDBPath as NSString).expandingTildeInPath
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw ReplicaAttachmentMirrorError.openReplica(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_close(database)
    }

    let sql = """
      SELECT DISTINCT
        replica_relative_path
      FROM message_attachments
      ORDER BY replica_relative_path ASC
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw ReplicaAttachmentMirrorError.prepare(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    var references: [ReplicaAttachmentReference] = []
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        references.append(
          ReplicaAttachmentReference(
            replicaRelativePath: sqliteText(statement, column: 0)
          )
        )
      case SQLITE_DONE:
        return references
      default:
        throw ReplicaAttachmentMirrorError.iterate(lastSQLiteError(from: database))
      }
    }
  }

  private static func materialize(
    sourceURL: URL,
    destinationURL: URL
  ) throws {
    let fileManager = FileManager.default
    var sourceIsDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory),
      sourceIsDirectory.boolValue == false
    else {
      return
    }

    var destinationIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory) {
      if destinationIsDirectory.boolValue {
        try fileManager.removeItem(at: destinationURL)
      } else {
        return
      }
    }
    do {
      try fileManager.linkItem(at: sourceURL, to: destinationURL)
      return
    } catch {
      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: destinationURL)
      }
    }

    try fileManager.copyItem(at: sourceURL, to: destinationURL)
  }

  private static func pruneStaleFiles(
    from rootURL: URL,
    keepingRelativePaths desiredPaths: Set<String>,
    fileManager: FileManager
  ) throws {
    let normalizedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let normalizedRootComponents = normalizedRootURL.pathComponents

    guard
      let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    var directoryURLs: [URL] = []
    for case let itemURL as URL in enumerator {
      let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true {
        directoryURLs.append(itemURL)
        continue
      }

      let normalizedItemURL = itemURL.resolvingSymlinksInPath().standardizedFileURL
      let relativeComponents = normalizedItemURL.pathComponents.dropFirst(
        normalizedRootComponents.count
      )
      let relativePath = relativeComponents.joined(separator: "/")
      if desiredPaths.contains(relativePath) == false {
        try fileManager.removeItem(at: itemURL)
      }
    }

    for directoryURL in directoryURLs.sorted(by: { $0.path.count > $1.path.count }) {
      if directoryURL == rootURL {
        continue
      }
      let contents = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
      if contents.isEmpty {
        try fileManager.removeItem(at: directoryURL)
      }
    }
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, path.hasPrefix("/") == false else {
      return false
    }
    return path.split(separator: "/").allSatisfy { component in
      component.isEmpty == false && component != "." && component != ".."
    }
  }

  private static func sourceURL(forReplicaRelativePath replicaRelativePath: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Messages/Attachments", isDirectory: true)
      .appendingPathComponent(replicaRelativePath, isDirectory: false)
  }
}

private func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String {
  guard let pointer = sqlite3_column_text(statement, column) else {
    return ""
  }
  return String(cString: pointer)
}

private func lastSQLiteError(from database: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(database) else {
    return "sqlite error"
  }
  return String(cString: message)
}
