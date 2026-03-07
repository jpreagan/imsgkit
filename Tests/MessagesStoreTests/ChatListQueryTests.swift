import Foundation
import MessagesStore
import SQLite3
import Testing

@Test
func listReturnsRawChatsSortedByNewestMessage() throws {
  let dbURL = try makeChatListTestDatabase()
  let chats = try ChatListQuery.list(dbPath: dbURL.path, limit: 10)

  #expect(chats.count == 3)

  #expect(
    chats[0]
      == ChatSummary(
        id: "chat_id:11",
        chatID: 11,
        chatGUID: "group-guid",
        service: "iMessage",
        identifier: "chat123",
        label: "+12125550101, +12125550102",
        participantCount: 2,
        participants: ["+12125550101", "+12125550102"],
        lastMessageAt: "2001-01-01T00:00:03.000Z",
        messageCount: 2
      )
  )

  #expect(
    chats[1]
      == ChatSummary(
        id: "chat_id:10",
        chatID: 10,
        chatGUID: "direct-guid",
        service: "iMessage",
        identifier: "+12125550100",
        label: "+12125550100",
        participantCount: 1,
        participants: ["+12125550100"],
        lastMessageAt: "2001-01-01T00:00:02.000Z",
        messageCount: 1
      )
  )

  #expect(
    chats[2]
      == ChatSummary(
        id: "chat_id:12",
        chatID: 12,
        chatGUID: "named-group-guid",
        service: "iMessage",
        identifier: "chat456",
        label: "Project Thread",
        participantCount: 1,
        participants: ["chat456"],
        lastMessageAt: nil,
        messageCount: 0
      )
  )
}

@Test
func listRespectsLimit() throws {
  let dbURL = try makeChatListTestDatabase()
  let chats = try ChatListQuery.list(dbPath: dbURL.path, limit: 2)
  #expect(chats.map(\.chatID) == [11, 10])
}

@Test
func listReturnsEmptyForZeroLimit() throws {
  let dbURL = try makeChatListTestDatabase()
  let chats = try ChatListQuery.list(dbPath: dbURL.path, limit: 0)
  #expect(chats.isEmpty)
}

@Test
func listRejectsNegativeLimit() throws {
  let dbURL = try makeChatListTestDatabase()

  do {
    _ = try ChatListQuery.list(dbPath: dbURL.path, limit: -1)
    Issue.record("expected negative limit to throw")
  } catch let error as CustomStringConvertible {
    #expect(error.description == "limit must be zero or greater")
  }
}

private func makeChatListTestDatabase() throws -> URL {
  let tempDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

  let dbURL = tempDirectory.appendingPathComponent("chat.db")
  var database: OpaquePointer?
  #expect(sqlite3_open(dbURL.path, &database) == SQLITE_OK)
  defer {
    sqlite3_close(database)
  }

  try execute(
    database,
    sql: """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT NOT NULL,
        chat_identifier TEXT,
        service_name TEXT,
        display_name TEXT,
        room_name TEXT
      );
      """
  )
  try execute(
    database,
    sql: """
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL
      );
      """
  )
  try execute(
    database,
    sql: """
      CREATE TABLE chat_handle_join (
        chat_id INTEGER NOT NULL,
        handle_id INTEGER NOT NULL
      );
      """
  )
  try execute(
    database,
    sql: """
      CREATE TABLE chat_message_join (
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        message_date INTEGER DEFAULT 0
      );
      """
  )

  try execute(
    database,
    sql: """
      INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, room_name) VALUES
        (10, 'direct-guid', '+12125550100', 'iMessage', '', ''),
        (11, 'group-guid', 'chat123', 'iMessage', '', ''),
        (12, 'named-group-guid', 'chat456', 'iMessage', 'Project Thread', 'chat456');
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO handle (ROWID, id) VALUES
        (1, '+12125550100'),
        (2, '+12125550101'),
        (3, '+12125550102');
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
        (10, 1),
        (11, 2),
        (11, 3);
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
        (10, 100, 2000000000),
        (11, 101, 1000000000),
        (11, 102, 3000000000);
      """
  )

  return dbURL
}

private func execute(_ database: OpaquePointer?, sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }
}

private enum DatabaseError: Error {
  case statement(String)
}
