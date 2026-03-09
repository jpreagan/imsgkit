import Foundation
import MessagesStore
import SQLite3
import Testing

@Test
func watchBatchReturnsMessageAndReactionEventsInRowOrder() throws {
  let dbURL = try makeChatWatchTestDatabase()

  let batch = try ChatWatchQuery.loadBatch(
    dbPath: dbURL.path,
    afterRowID: 0,
    throughRowID: 103,
    limit: 10,
    includeReactions: true
  ) { identifier in
    switch identifier {
    case "+12125550100":
      return ResolvedChatContact(name: "Jane Doe", label: "Jane Doe (+12125550100)")
    case "+12125559999":
      return ResolvedChatContact(name: "Local User", label: "Local User (+12125559999)")
    default:
      return nil
    }
  }

  #expect(batch.lastSeenRowID == 103)
  #expect(batch.events.count == 4)
  #expect(batch.events.map(\.event) == ["message", "message", "reaction", "message"])
  #expect(batch.events.compactMap(\.message?.id) == [100, 101, 103])
  #expect(batch.events[0].message?.senderLabel == "Jane Doe (+12125550100)")
  #expect(batch.events[1].message?.senderLabel == "Local User (+12125559999)")
  #expect(batch.events[2].reaction?.action == "added")
  #expect(batch.events[2].reaction?.emoji == "❤️")
  #expect(batch.events[2].reaction?.targetGUID == "message-101")
  #expect(batch.events[2].reaction?.senderLabel == "Jane Doe (+12125550100)")
}

@Test
func watchBatchFiltersEventsWithinRequestedTimeWindow() throws {
  let dbURL = try makeChatWatchTestDatabase()

  let batch = try ChatWatchQuery.loadBatch(
    dbPath: dbURL.path,
    afterRowID: 101,
    throughRowID: 104,
    limit: 10,
    chatID: 10,
    startDate: Date(timeIntervalSinceReferenceDate: 3),
    endDate: Date(timeIntervalSinceReferenceDate: 4),
    includeReactions: false
  )

  #expect(batch.lastSeenRowID == 103)
  #expect(batch.events.count == 1)
  #expect(batch.events[0].event == "message")
  #expect(batch.events[0].message?.id == 103)
}

@Test
func watchBatchRejectsInvalidChatID() throws {
  let dbURL = try makeChatWatchTestDatabase()

  do {
    _ = try ChatWatchQuery.loadBatch(
      dbPath: dbURL.path,
      afterRowID: 0,
      limit: 10,
      chatID: 0
    )
    Issue.record("expected invalid chat id to throw")
  } catch let error as CustomStringConvertible {
    #expect(error.description == "chat_id must be greater than zero")
  }
}

@Test
func watchBatchUsesTargetMessageCallerIDForOutboundReactionLabels() throws {
  let dbURL = try makeChatWatchTestDatabase()
  var database: OpaquePointer?
  #expect(sqlite3_open(dbURL.path, &database) == SQLITE_OK)
  defer {
    sqlite3_close(database)
  }

  try execute(
    database,
    sql: """
      INSERT INTO message (
        ROWID, guid, text, attributedBody, service, destination_caller_id, handle_id, date, is_from_me, is_system_message, item_type, associated_message_guid, associated_message_type, thread_originator_guid
      ) VALUES
        (105, 'message-105', 'Liked “reply from me”', NULL, 'iMessage', NULL, 0, 3500000000, 1, 0, 0, 'p:0/message-101', 2001, NULL);
      """
  )

  let batch = try ChatWatchQuery.loadBatch(
    dbPath: dbURL.path,
    afterRowID: 104,
    throughRowID: 105,
    limit: 10,
    includeReactions: true
  ) { identifier in
    if identifier == "+12125559999" {
      return ResolvedChatContact(name: "Local User", label: "Local User (+12125559999)")
    }
    return nil
  }

  #expect(batch.events.count == 1)
  #expect(batch.events[0].event == "reaction")
  #expect(batch.events[0].reaction?.senderLabel == "Local User (+12125559999)")
}

private func makeChatWatchTestDatabase() throws -> URL {
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
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT NOT NULL,
        text TEXT,
        attributedBody BLOB,
        service TEXT,
        destination_caller_id TEXT,
        handle_id INTEGER DEFAULT 0,
        date INTEGER,
        is_from_me INTEGER DEFAULT 0,
        is_system_message INTEGER DEFAULT 0,
        item_type INTEGER DEFAULT 0,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        thread_originator_guid TEXT
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
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT NOT NULL,
        filename TEXT,
        uti TEXT,
        mime_type TEXT,
        transfer_name TEXT,
        total_bytes INTEGER DEFAULT 0,
        is_sticker INTEGER DEFAULT 0
      );
      """
  )
  try execute(
    database,
    sql: """
      CREATE TABLE message_attachment_join (
        message_id INTEGER NOT NULL,
        attachment_id INTEGER NOT NULL
      );
      """
  )

  try execute(
    database,
    sql: """
      INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, room_name) VALUES
        (10, 'direct-guid', '+12125550100', 'iMessage', '', ''),
        (11, 'other-guid', '+12125550199', 'iMessage', '', '');
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO handle (ROWID, id) VALUES
        (1, '+12125550100'),
        (2, '+12125550199');
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO message (
        ROWID, guid, text, attributedBody, service, destination_caller_id, handle_id, date, is_from_me, is_system_message, item_type, associated_message_guid, associated_message_type, thread_originator_guid
      ) VALUES
        (100, 'message-100', 'first from jane', NULL, 'iMessage', '+12125559999', 1, 1000000000, 0, 0, 0, NULL, NULL, NULL),
        (101, 'message-101', 'reply from me', NULL, 'iMessage', '+12125559999', 1, 2000000000, 1, 0, 0, NULL, NULL, NULL),
        (102, 'message-102', 'Loved “reply from me”', NULL, 'iMessage', '+12125559999', 1, 2500000000, 0, 0, 0, 'p:0/message-101', 2000, NULL),
        (103, 'message-103', 'latest from jane', NULL, 'iMessage', '+12125559999', 1, 3000000000, 0, 0, 0, NULL, NULL, NULL),
        (104, 'message-104', 'other chat message', NULL, 'iMessage', '+12125558888', 2, 4000000000, 0, 0, 0, NULL, NULL, NULL);
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
        (10, 100, 1000000000),
        (10, 101, 2000000000),
        (10, 102, 2500000000),
        (10, 103, 3000000000),
        (11, 104, 4000000000);
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
