import Foundation
import SQLite3
import Testing

@testable import imsgd

@Test
func replicaAttachmentMirrorMaterializesReferencedFilesAndPrunesStaleEntries() throws {
  let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

  let relativeDirectory = "Library/Messages/Attachments/imsgkit-tests-\(UUID().uuidString)/chat"
  let sourceDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(relativeDirectory, isDirectory: true)
  try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
  defer {
    try? FileManager.default.removeItem(at: sourceDirectory.deletingLastPathComponent())
  }
  let sourceFileURL = sourceDirectory.appendingPathComponent("photo.heic")
  try Data("heic".utf8).write(to: sourceFileURL)

  let replicaDirectory = tempDirectory.appendingPathComponent("state", isDirectory: true)
  try FileManager.default.createDirectory(at: replicaDirectory, withIntermediateDirectories: true)
  let replicaDBURL = replicaDirectory.appendingPathComponent("replica.db")

  var database: OpaquePointer?
  #expect(sqlite3_open(replicaDBURL.path, &database) == SQLITE_OK)

  try execute(
    database,
    sql: """
      CREATE TABLE message_attachments (
        message_id INTEGER NOT NULL,
        replica_relative_path TEXT NOT NULL,
        PRIMARY KEY (message_id, replica_relative_path)
      );
      INSERT INTO message_attachments (
        message_id,
        replica_relative_path
      ) VALUES
        (100, '\(sourceDirectory.deletingLastPathComponent().lastPathComponent)/chat/photo.heic');
      """
  )
  #expect(sqlite3_close(database) == SQLITE_OK)
  database = nil

  let mirrorRoot = URL(
    fileURLWithPath: ReplicaAttachmentMirror.attachmentRoot(forReplicaDBPath: replicaDBURL.path),
    isDirectory: true
  )
  let staleFileURL = mirrorRoot
    .appendingPathComponent("stale", isDirectory: true)
    .appendingPathComponent("old.heic")
  try FileManager.default.createDirectory(
    at: staleFileURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("stale".utf8).write(to: staleFileURL)

  try ReplicaAttachmentMirror.refresh(replicaDBPath: replicaDBURL.path)

  let mirroredFileURL = mirrorRoot
    .appendingPathComponent(sourceDirectory.deletingLastPathComponent().lastPathComponent, isDirectory: true)
    .appendingPathComponent("chat", isDirectory: true)
    .appendingPathComponent("photo.heic")
  #expect(FileManager.default.fileExists(atPath: mirroredFileURL.path))
  #expect((try Data(contentsOf: mirroredFileURL)) == Data("heic".utf8))
  #expect(!FileManager.default.fileExists(atPath: staleFileURL.path))
}

private func execute(_ database: OpaquePointer?, sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }
}

private enum DatabaseError: Error {
  case statement(String)
}
