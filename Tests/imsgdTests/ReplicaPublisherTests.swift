import Foundation
import Testing

@testable import imsgd

@Test
func replicaPublisherInvokesSQLiteRsyncWithRemoteExecutableOverride() throws {
  let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

  let logURL = tempDirectory.appendingPathComponent("args.txt")
  let scriptURL = tempDirectory.appendingPathComponent("sqlite3_rsync")
  try """
    #!/bin/sh
    printf '%s\n' "$@" > "\(logURL.path)"
    """
    .write(to: scriptURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

  let publisher = try ReplicaPublisher(
    sqliteRsyncPath: scriptURL.path,
    publishTarget: "user@remote:/var/lib/imsgkit/replica.db",
    remoteExecutable: "/opt/homebrew/bin/sqlite3_rsync"
  )

  try publisher.publish(replicaDBPath: "/tmp/source replica.db")

  let arguments = try String(contentsOf: logURL, encoding: .utf8)
    .split(whereSeparator: \.isNewline)
    .map(String.init)

  #expect(
    arguments == [
      "/tmp/source replica.db",
      "user@remote:/var/lib/imsgkit/replica.db",
      "--exe",
      "/opt/homebrew/bin/sqlite3_rsync",
    ]
  )
}

@Test
func replicaPublisherRejectsHostOnlyPublishTarget() throws {
  do {
    _ = try ReplicaPublisher(
      sqliteRsyncPath: "/tmp/sqlite3_rsync",
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
