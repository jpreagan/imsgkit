import Foundation
import Testing

@testable import imsgd

@Test
func replicaPublisherPublishesAttachmentsBeforeReplicaAndPrunesAfterSuccess() throws {
  let tempDirectory = try makeTempDirectory()
  let logURL = tempDirectory.appendingPathComponent("commands.log")
  let sqliteScriptURL = tempDirectory.appendingPathComponent("sqlite3_rsync")
  let rsyncScriptURL = tempDirectory.appendingPathComponent("rsync")
  try writeLoggingScript(
    at: sqliteScriptURL,
    toolName: "sqlite3_rsync",
    logURL: logURL
  )
  try writeLoggingScript(
    at: rsyncScriptURL,
    toolName: "rsync",
    logURL: logURL
  )

  let publisher = try ReplicaPublisher(
    sqliteRsyncPath: sqliteScriptURL.path,
    rsyncPath: rsyncScriptURL.path,
    publishTarget: "user@remote:/var/lib/imsgkit/replica.db",
    remoteExecutable: "/opt/homebrew/bin/sqlite3_rsync"
  )

  let replicaDBPath = tempDirectory
    .appendingPathComponent("state", isDirectory: true)
    .appendingPathComponent("replica.db")
    .path
  try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: replicaDBPath).deletingLastPathComponent(),
    withIntermediateDirectories: true
  )

  try publisher.publish(replicaDBPath: replicaDBPath)

  let attachmentRoot = ReplicaAttachmentMirror.attachmentRoot(forReplicaDBPath: replicaDBPath)
  #expect(
    try loggedCommands(at: logURL) == [
      "rsync|-a|\(attachmentRoot)/|user@remote:/var/lib/imsgkit/attachments/",
      "sqlite3_rsync|\(replicaDBPath)|user@remote:/var/lib/imsgkit/replica.db|--exe|/opt/homebrew/bin/sqlite3_rsync",
      "rsync|-a|--delete|\(attachmentRoot)/|user@remote:/var/lib/imsgkit/attachments/",
    ]
  )
}

@Test
func replicaPublisherEscapesSpacesInReplicaAndAttachmentTargets() throws {
  let tempDirectory = try makeTempDirectory()
  let logURL = tempDirectory.appendingPathComponent("commands.log")
  let sqliteScriptURL = tempDirectory.appendingPathComponent("sqlite3_rsync")
  let rsyncScriptURL = tempDirectory.appendingPathComponent("rsync")
  try writeLoggingScript(
    at: sqliteScriptURL,
    toolName: "sqlite3_rsync",
    logURL: logURL
  )
  try writeLoggingScript(
    at: rsyncScriptURL,
    toolName: "rsync",
    logURL: logURL
  )

  let publisher = try ReplicaPublisher(
    sqliteRsyncPath: sqliteScriptURL.path,
    rsyncPath: rsyncScriptURL.path,
    publishTarget: "user@remote:~/Library/Application Support/imsgkit/replica.db",
    remoteExecutable: nil
  )

  let replicaDBPath = tempDirectory.appendingPathComponent("replica.db").path
  try publisher.publish(replicaDBPath: replicaDBPath)

  let attachmentRoot = ReplicaAttachmentMirror.attachmentRoot(forReplicaDBPath: replicaDBPath)
  #expect(
    try loggedCommands(at: logURL) == [
      #"rsync|-a|\#(attachmentRoot)/|user@remote:~/Library/Application\ Support/imsgkit/attachments/"#,
      #"sqlite3_rsync|\#(replicaDBPath)|user@remote:~/Library/Application\ Support/imsgkit/replica.db"#,
      #"rsync|-a|--delete|\#(attachmentRoot)/|user@remote:~/Library/Application\ Support/imsgkit/attachments/"#,
    ]
  )
}

@Test
func replicaPublisherRejectsHostOnlyPublishTarget() throws {
  do {
    _ = try ReplicaPublisher(
      sqliteRsyncPath: "/tmp/sqlite3_rsync",
      rsyncPath: "/tmp/rsync",
      publishTarget: "user@remote",
      remoteExecutable: nil
    )
    Issue.record("expected invalid publish target to throw")
  } catch let error as CustomStringConvertible {
    #expect(
      error.description
        == "invalid replica publish target: user@remote (expected USER@HOST:PATH)"
    )
  }
}

@Test
func replicaPublisherRejectsShellMetacharactersInRemotePath() throws {
  do {
    _ = try ReplicaPublisher(
      sqliteRsyncPath: "/tmp/sqlite3_rsync",
      rsyncPath: "/tmp/rsync",
      publishTarget: "user@remote:/Users/remote/replica.db;rm -rf /",
      remoteExecutable: nil
    )
    Issue.record("expected invalid publish path to throw")
  } catch let error as CustomStringConvertible {
    #expect(
      error.description
        == "invalid replica publish path: /Users/remote/replica.db;rm -rf / (allowed characters: letters, numbers, /, ., _, -, ~, and spaces)"
    )
  }
}

private func makeTempDirectory() throws -> URL {
  let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  return tempDirectory
}

private func writeLoggingScript(at scriptURL: URL, toolName: String, logURL: URL) throws {
  try """
    #!/bin/sh
    {
      printf '%s' "\(toolName)"
      for arg in "$@"; do
        printf '|%s' "$arg"
      done
      printf '\n'
    } >> "\(logURL.path)"
    """
    .write(to: scriptURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
}

private func loggedCommands(at logURL: URL) throws -> [String] {
  try String(contentsOf: logURL, encoding: .utf8)
    .split(whereSeparator: \.isNewline)
    .map(String.init)
}
