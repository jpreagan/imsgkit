import Foundation
import MessagesStore
import SQLite3
import Testing

@Test
func probeRecognizesReadableSQLiteFile() throws {
  let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

  let dbURL = tempDirectory.appendingPathComponent("chat.db")
  var handle: OpaquePointer?
  let openResult = sqlite3_open(dbURL.path, &handle)
  #expect(openResult == SQLITE_OK)
  sqlite3_close(handle)

  let health = MessagesHealthProbe.probe(dbPath: dbURL.path)
  #expect(health.dbExists)
  #expect(health.canReadDB)
  #expect(health.sqliteOpenOK)
  #expect(health.ok)
}
