import Foundation
import SQLite3

public struct ChatSummary: Sendable, Equatable {
  public let id: String
  public let chatID: Int64
  public let chatGUID: String
  public let service: String
  public let identifier: String
  public let label: String
  public let participantCount: Int
  public let participants: [String]
  public let lastMessageAt: String?
  public let messageCount: Int

  public init(
    id: String,
    chatID: Int64,
    chatGUID: String,
    service: String,
    identifier: String,
    label: String,
    participantCount: Int,
    participants: [String],
    lastMessageAt: String?,
    messageCount: Int
  ) {
    self.id = id
    self.chatID = chatID
    self.chatGUID = chatGUID
    self.service = service
    self.identifier = identifier
    self.label = label
    self.participantCount = participantCount
    self.participants = participants
    self.lastMessageAt = lastMessageAt
    self.messageCount = messageCount
  }

  public var jsonObject: [String: Any] {
    [
      "id": id,
      "chat_id": chatID,
      "chat_guid": chatGUID,
      "service": service,
      "identifier": identifier,
      "label": label,
      "participant_count": participantCount,
      "participants": participants,
      "last_message_at": lastMessageAt ?? NSNull(),
      "message_count": messageCount,
    ]
  }
}

enum MessagesStoreError: Error, CustomStringConvertible {
  case invalidLimit(Int)
  case openDatabase(String)
  case prepareStatement(String)
  case stepStatement(String)

  var description: String {
    switch self {
    case .invalidLimit:
      return "limit must be zero or greater"
    case .openDatabase(let message),
      .prepareStatement(let message),
      .stepStatement(let message):
      return message
    }
  }
}

public enum ChatListQuery {
  public static let defaultLimit = 20

  public static func list(
    dbPath: String = MessagesHealthProbe.defaultChatDBPath,
    limit: Int = defaultLimit
  ) throws -> [ChatSummary] {
    if limit < 0 {
      throw MessagesStoreError.invalidLimit(limit)
    }

    guard limit > 0 else {
      return []
    }

    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    return try withReadOnlyDatabase(at: resolvedPath) { database in
      let rows = try loadChatRows(database: database, limit: limit)
      return try rows.map { row in
        let participants = try loadParticipants(database: database, chatID: row.chatID)
        return makeSummary(row: row, participants: participants)
      }
    }
  }

  private struct ChatRow {
    let chatID: Int64
    let chatGUID: String
    let identifier: String
    let service: String
    let displayName: String
    let roomName: String
    let messageCount: Int
    let lastMessageDate: Int64?
  }

  private static func loadChatRows(database: OpaquePointer, limit: Int) throws -> [ChatRow] {
    let sql = """
      SELECT
        c.ROWID,
        c.guid,
        COALESCE(c.chat_identifier, ''),
        COALESCE(c.service_name, ''),
        COALESCE(c.display_name, ''),
        COALESCE(c.room_name, ''),
        COUNT(cmj.message_id),
        MAX(cmj.message_date)
      FROM chat c
      LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
      GROUP BY c.ROWID, c.guid, c.chat_identifier, c.service_name, c.display_name, c.room_name
      ORDER BY
        CASE WHEN MAX(cmj.message_date) IS NULL THEN 1 ELSE 0 END,
        MAX(cmj.message_date) DESC,
        c.ROWID DESC
      LIMIT ?
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, Int64(limit))

    var rows: [ChatRow] = []
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        rows.append(
          ChatRow(
            chatID: sqlite3_column_int64(statement, 0),
            chatGUID: sqliteText(statement, column: 1),
            identifier: sqliteText(statement, column: 2),
            service: sqliteText(statement, column: 3),
            displayName: sqliteText(statement, column: 4),
            roomName: sqliteText(statement, column: 5),
            messageCount: Int(sqlite3_column_int64(statement, 6)),
            lastMessageDate: sqliteValue(statement, column: 7)
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func loadParticipants(database: OpaquePointer, chatID: Int64) throws -> [String] {
    let sql = """
      SELECT h.id
      FROM chat_handle_join chj
      INNER JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ?
      ORDER BY h.id ASC
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, chatID)

    var participants: [String] = []
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        participants.append(sqliteText(statement, column: 0))
      case SQLITE_DONE:
        return participants
      default:
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func makeSummary(row: ChatRow, participants: [String]) -> ChatSummary {
    let displayName = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let roomName = row.roomName.trimmingCharacters(in: .whitespacesAndNewlines)
    let canonicalParticipants =
      participants.isEmpty && !row.identifier.isEmpty
      ? [row.identifier]
      : participants

    let label: String
    if !displayName.isEmpty {
      label = displayName
    } else if !roomName.isEmpty && roomName != row.identifier {
      label = roomName
    } else if !canonicalParticipants.isEmpty {
      label = canonicalParticipants.joined(separator: ", ")
    } else if !row.identifier.isEmpty {
      label = row.identifier
    } else {
      label = "chat_id:\(row.chatID)"
    }

    return ChatSummary(
      id: "chat_id:\(row.chatID)",
      chatID: row.chatID,
      chatGUID: row.chatGUID,
      service: row.service,
      identifier: row.identifier,
      label: label,
      participantCount: canonicalParticipants.count,
      participants: canonicalParticipants,
      lastMessageAt: formatMessagesTimestamp(row.lastMessageDate),
      messageCount: row.messageCount
    )
  }

  private static func formatMessagesTimestamp(_ timestamp: Int64?) -> String? {
    guard let timestamp else {
      return nil
    }

    let date = Date(timeIntervalSinceReferenceDate: Double(timestamp) / 1_000_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }
}

private func withReadOnlyDatabase<T>(
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

private func sqliteText(_ statement: OpaquePointer?, column: Int32) -> String {
  guard let pointer = sqlite3_column_text(statement, column) else {
    return ""
  }
  return String(cString: pointer)
}

private func sqliteValue(_ statement: OpaquePointer?, column: Int32) -> Int64? {
  guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
    return nil
  }
  return sqlite3_column_int64(statement, column)
}

private func lastSQLiteError(from database: OpaquePointer?) -> String {
  guard let message = sqlite3_errmsg(database) else {
    return "sqlite error"
  }
  return String(cString: message)
}
