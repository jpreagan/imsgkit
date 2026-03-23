import Foundation

enum ReplicaPublishError: Error, CustomStringConvertible {
  case sqliteRsyncNotFound
  case invalidPublishTarget(String)
  case runFailed(String)

  var description: String {
    switch self {
    case .sqliteRsyncNotFound:
      return "sqlite3_rsync not found"
    case .invalidPublishTarget(let target):
      return "invalid replica publish target: \(target) (expected USER@HOST:PATH)"
    case .runFailed(let message):
      return message
    }
  }
}

struct ReplicaPublisher {
  let sqliteRsyncPath: String
  let publishTarget: String
  let remoteExecutable: String?

  init(configuration: SyncConfiguration) throws {
    try self.init(
      sqliteRsyncPath: Self.resolveSQLiteRsyncPath(),
      publishTarget: configuration.publishTarget,
      remoteExecutable: configuration.remoteExecutable
    )
  }

  init(
    sqliteRsyncPath: String,
    publishTarget: String,
    remoteExecutable: String?
  ) throws {
    let trimmedTarget = publishTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isRemotePublishTarget(trimmedTarget) else {
      throw ReplicaPublishError.invalidPublishTarget(publishTarget)
    }

    self.sqliteRsyncPath = (sqliteRsyncPath as NSString).expandingTildeInPath
    self.publishTarget = trimmedTarget
    self.remoteExecutable = remoteExecutable.map { ($0 as NSString).expandingTildeInPath }
  }

  func publish(replicaDBPath: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sqliteRsyncPath)

    var arguments = [((replicaDBPath as NSString).expandingTildeInPath), publishTarget]
    if let remoteExecutable, !remoteExecutable.isEmpty {
      arguments.append(contentsOf: ["--exe", remoteExecutable])
    }
    process.arguments = arguments

    let stderrURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("imsgd-sqlite3_rsync-\(UUID().uuidString).stderr", isDirectory: false)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stderrHandle.close()
      try? FileManager.default.removeItem(at: stderrURL)
    }

    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrHandle

    do {
      try process.run()
    } catch {
      throw ReplicaPublishError.runFailed("start sqlite3_rsync: \(error.localizedDescription)")
    }

    process.waitUntilExit()

    try? stderrHandle.close()
    let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
    let stderrText = String(data: stderrData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard process.terminationStatus == 0 else {
      if let stderrText, !stderrText.isEmpty {
        throw ReplicaPublishError.runFailed("sqlite3_rsync failed: \(stderrText)")
      }
      throw ReplicaPublishError.runFailed(
        "sqlite3_rsync failed with exit status \(process.terminationStatus)"
      )
    }
  }

  static func resolveSQLiteRsyncPath() throws -> String {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment

    var candidates = [String]()
    if let path = environment["PATH"] {
      let pathCandidates =
        path
        .split(separator: ":")
        .map { String($0) }
        .filter { !$0.isEmpty }
        .map { ($0 as NSString).appendingPathComponent("sqlite3_rsync") }
      candidates.append(contentsOf: pathCandidates)
    }
    candidates.append("/opt/homebrew/bin/sqlite3_rsync")
    candidates.append("/usr/local/bin/sqlite3_rsync")

    for candidate in candidates {
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    throw ReplicaPublishError.sqliteRsyncNotFound
  }

  private static func isRemotePublishTarget(_ target: String) -> Bool {
    let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return false
    }

    let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    return !host.isEmpty && !path.isEmpty
  }
}
