import Foundation
import SQLite3

public struct MessagesHealth: Sendable, Equatable {
  public let dbPath: String
  public let dbExists: Bool
  public let canReadDB: Bool
  public let sqliteOpenOK: Bool

  public var ok: Bool {
    dbExists && canReadDB && sqliteOpenOK
  }
}

public enum MessagesHealthProbe {
  public static let defaultChatDBPath = "~/Library/Messages/chat.db"

  public static func probe(dbPath: String = defaultChatDBPath) -> MessagesHealth {
    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    let fileManager = FileManager.default
    let dbExists = fileManager.fileExists(atPath: resolvedPath)
    let canReadDB = fileManager.isReadableFile(atPath: resolvedPath)
    let sqliteOpenOK = openReadOnlySQLite(at: resolvedPath)

    return MessagesHealth(
      dbPath: resolvedPath,
      dbExists: dbExists,
      canReadDB: canReadDB,
      sqliteOpenOK: sqliteOpenOK
    )
  }

  private static func openReadOnlySQLite(at path: String) -> Bool {
    var handle: OpaquePointer?
    let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
    defer {
      if handle != nil {
        sqlite3_close(handle)
      }
    }
    return result == SQLITE_OK
  }
}
