import Foundation

enum ReplicaPublishError: Error, CustomStringConvertible {
  case sqliteRsyncNotFound
  case rsyncNotFound
  case invalidPublishTarget(String)
  case invalidPublishPath(String)
  case runFailed(String)

  var description: String {
    switch self {
    case .sqliteRsyncNotFound:
      return "sqlite3_rsync not found"
    case .rsyncNotFound:
      return "rsync not found"
    case .invalidPublishTarget(let target):
      return "invalid replica publish target: \(target) (expected USER@HOST:PATH)"
    case .invalidPublishPath(let path):
      return
        "invalid replica publish path: \(path) (allowed characters: letters, numbers, /, ., _, -, ~, and spaces)"
    case .runFailed(let message):
      return message
    }
  }
}

struct PublishTarget {
  let host: String
  let path: String

  var replicaTarget: String {
    "\(host):\(ReplicaPublisher.escapeRemotePath(path))"
  }

  var attachmentPath: String {
    let directory = (path as NSString).deletingLastPathComponent
    let baseDirectory = directory.isEmpty ? "." : directory
    return (baseDirectory as NSString).appendingPathComponent(ReplicaAttachmentMirror.directoryName)
  }

  var attachmentTarget: String {
    "\(host):\(ReplicaPublisher.escapeRemotePath(attachmentPath))"
  }
}

struct ReplicaPublisher {
  let sqliteRsyncPath: String
  let rsyncPath: String
  let publishTarget: PublishTarget
  let remoteExecutable: String?

  init(configuration: SyncConfiguration) throws {
    try self.init(
      sqliteRsyncPath: Self.resolveSQLiteRsyncPath(),
      rsyncPath: Self.resolveRsyncPath(),
      publishTarget: configuration.publishTarget,
      remoteExecutable: configuration.remoteExecutable
    )
  }

  init(
    sqliteRsyncPath: String,
    rsyncPath: String,
    publishTarget: String,
    remoteExecutable: String?
  ) throws {
    let trimmedTarget = publishTarget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let normalizedTarget = try Self.normalizePublishTarget(trimmedTarget) else {
      throw ReplicaPublishError.invalidPublishTarget(publishTarget)
    }

    self.sqliteRsyncPath = (sqliteRsyncPath as NSString).expandingTildeInPath
    self.rsyncPath = (rsyncPath as NSString).expandingTildeInPath
    self.publishTarget = normalizedTarget
    self.remoteExecutable = remoteExecutable.map { ($0 as NSString).expandingTildeInPath }
  }

  func publish(replicaDBPath: String) throws {
    let localAttachmentRoot = ReplicaAttachmentMirror.attachmentRoot(
      forReplicaDBPath: replicaDBPath
    )
    try publishAttachments(localAttachmentRoot: localAttachmentRoot, delete: false)
    try publishReplicaDB(replicaDBPath: replicaDBPath)
    try publishAttachments(localAttachmentRoot: localAttachmentRoot, delete: true)
  }

  private func publishReplicaDB(replicaDBPath: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: sqliteRsyncPath)

    var arguments = [
      ((replicaDBPath as NSString).expandingTildeInPath),
      publishTarget.replicaTarget,
    ]
    if let remoteExecutable, !remoteExecutable.isEmpty {
      arguments.append(contentsOf: ["--exe", remoteExecutable])
    }
    process.arguments = arguments
    try run(process: process, name: "sqlite3_rsync")
  }

  private func publishAttachments(localAttachmentRoot: String, delete: Bool) throws {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: localAttachmentRoot, isDirectory: true),
      withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: rsyncPath)

    var arguments = ["-a"]
    if delete {
      arguments.append("--delete")
    }
    arguments.append(contentsOf: [
      localAttachmentRoot + "/",
      publishTarget.attachmentTarget + "/",
    ])
    process.arguments = arguments
    try run(process: process, name: "rsync")
  }

  private func run(process: Process, name: String) throws {
    let stderrURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("imsgd-\(name)-\(UUID().uuidString).stderr", isDirectory: false)
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
      throw ReplicaPublishError.runFailed("start \(name): \(error.localizedDescription)")
    }

    process.waitUntilExit()

    try? stderrHandle.close()
    let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
    let stderrText = String(data: stderrData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard process.terminationStatus == 0 else {
      if let stderrText, !stderrText.isEmpty {
        throw ReplicaPublishError.runFailed("\(name) failed: \(stderrText)")
      }
      throw ReplicaPublishError.runFailed(
        "\(name) failed with exit status \(process.terminationStatus)"
      )
    }
  }

  static func resolveSQLiteRsyncPath() throws -> String {
    try resolveExecutable(
      named: "sqlite3_rsync",
      defaults: [
        "/opt/homebrew/bin/sqlite3_rsync",
        "/usr/local/bin/sqlite3_rsync",
      ],
      notFoundError: .sqliteRsyncNotFound
    )
  }

  static func resolveRsyncPath() throws -> String {
    try resolveExecutable(
      named: "rsync",
      defaults: [
        "/usr/bin/rsync",
        "/opt/homebrew/bin/rsync",
        "/usr/local/bin/rsync",
      ],
      notFoundError: .rsyncNotFound
    )
  }

  private static func resolveExecutable(
    named name: String,
    defaults: [String],
    notFoundError: ReplicaPublishError
  ) throws -> String {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment

    var candidates = [String]()
    if let path = environment["PATH"] {
      let pathCandidates =
        path
        .split(separator: ":")
        .map { String($0) }
        .filter { !$0.isEmpty }
        .map { ($0 as NSString).appendingPathComponent(name) }
      candidates.append(contentsOf: pathCandidates)
    }
    candidates.append(contentsOf: defaults)

    for candidate in candidates {
      if fileManager.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }

    throw notFoundError
  }

  private static func normalizePublishTarget(_ target: String) throws -> PublishTarget? {
    let parts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return nil
    }

    let host = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, !path.isEmpty else {
      return nil
    }
    guard isSafeRemotePath(path) else {
      throw ReplicaPublishError.invalidPublishPath(path)
    }

    return PublishTarget(host: host, path: path)
  }

  private static func isSafeRemotePath(_ path: String) -> Bool {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-~ "
    )
    for scalar in path.unicodeScalars {
      if !allowed.contains(scalar) {
        return false
      }
    }
    return true
  }

  static func escapeRemotePath(_ path: String) -> String {
    path.replacingOccurrences(of: " ", with: "\\ ")
  }
}
