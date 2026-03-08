import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(
  -1,
  to: sqlite3_destructor_type.self
)

func withReadOnlyDatabase<T>(
  at path: String,
  body: (OpaquePointer) throws -> T
) throws -> T {
  var database: OpaquePointer?
  guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
    throw MessagesStoreError.openDatabase(lastSQLiteError(from: database))
  }
  defer {
    sqlite3_close(database)
  }

  return try body(database!)
}

func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String {
  guard let pointer = sqlite3_column_text(statement, column) else {
    return ""
  }
  return String(cString: pointer)
}

func sqliteBlobData(_ statement: OpaquePointer?, column: Int32) -> Data {
  guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
    return Data()
  }
  guard let bytes = sqlite3_column_blob(statement, column) else {
    return Data()
  }

  return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
}

func sqliteValue(_ statement: OpaquePointer?, column: Int32) -> Int64? {
  guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
    return nil
  }
  return sqlite3_column_int64(statement, column)
}

func sqliteOptionalInt(_ statement: OpaquePointer?, column: Int32) -> Int? {
  guard let value = sqliteValue(statement, column: column) else {
    return nil
  }
  return Int(value)
}

func databaseColumns(database: OpaquePointer, table: String) throws -> Set<String> {
  let sql = "PRAGMA table_info(\(table));"

  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
    throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
  }
  defer {
    sqlite3_finalize(statement)
  }

  var columns = Set<String>()
  while sqlite3_step(statement) == SQLITE_ROW {
    columns.insert(sqliteText(statement, column: 1))
  }

  return columns
}

func databaseTables(database: OpaquePointer) throws -> Set<String> {
  let sql = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
    """

  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
    throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
  }
  defer {
    sqlite3_finalize(statement)
  }

  var tables = Set<String>()
  while sqlite3_step(statement) == SQLITE_ROW {
    tables.insert(sqliteText(statement, column: 0))
  }

  return tables
}

func sqliteBindText(_ statement: OpaquePointer?, index: Int32, value: String) {
  sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor)
}

func formatMessagesTimestamp(_ timestamp: Int64?) -> String? {
  guard let timestamp else {
    return nil
  }

  let date = Date(timeIntervalSinceReferenceDate: Double(timestamp) / 1_000_000_000)
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

func lastSQLiteError(from database: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(database) else {
    return "sqlite error"
  }
  return String(cString: message)
}
