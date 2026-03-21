import Foundation
import MessagesStore
import SQLite3
import Testing

@Test
func replicaBuildMaterializesChatsMessagesAndWatchEvents() throws {
  let sourceDBURL = try makeReplicaSourceDatabase()
  let replicaDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: replicaDirectory, withIntermediateDirectories: true)
  let replicaDBURL = replicaDirectory.appendingPathComponent("replica.db")

  let result = try ReplicaStore.build(
    sourceDBPath: sourceDBURL.path,
    replicaDBPath: replicaDBURL.path,
    builderVersion: "test"
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

  #expect(result.chatCount == 2)
  #expect(result.messageCount == 3)
  #expect(result.watchEventCount == 4)

  var database: OpaquePointer?
  #expect(sqlite3_open_v2(replicaDBURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
  defer {
    sqlite3_close(database)
  }

  #expect(try scalar(database, sql: "SELECT COUNT(*) FROM chats") == 2)
  #expect(try scalar(database, sql: "SELECT COUNT(*) FROM messages") == 3)
  #expect(try scalar(database, sql: "SELECT COUNT(*) FROM watch_events") == 4)
  #expect(
    try stringScalar(database, sql: "SELECT label FROM chats WHERE chat_id = 10")
      == "Jane Doe (+12125550100)"
  )
  #expect(
    try stringScalar(database, sql: "SELECT sender_label FROM messages WHERE message_id = 101")
      == "Local User (+12125559999)"
  )
}

private func makeReplicaSourceDatabase() throws -> URL {
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
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL
      );
      CREATE TABLE chat_handle_join (
        chat_id INTEGER NOT NULL,
        handle_id INTEGER NOT NULL
      );
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
      CREATE TABLE chat_message_join (
        chat_id INTEGER NOT NULL,
        message_id INTEGER NOT NULL,
        message_date INTEGER DEFAULT 0
      );
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
      INSERT INTO handle (ROWID, id) VALUES
        (1, '+12125550100'),
        (2, '+12125550199');
      INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
        (10, 1),
        (11, 2);
      INSERT INTO message (
        ROWID, guid, text, attributedBody, service, destination_caller_id, handle_id, date, is_from_me, is_system_message, item_type, associated_message_guid, associated_message_type, thread_originator_guid
      ) VALUES
        (100, 'message-100', 'first from jane', NULL, 'iMessage', '+12125559999', 1, 1000000000, 0, 0, 0, NULL, NULL, NULL),
        (101, 'message-101', 'reply from me', NULL, 'iMessage', '+12125559999', 1, 2000000000, 1, 0, 0, NULL, NULL, NULL),
        (102, 'message-102', 'Loved “reply from me”', NULL, 'iMessage', '+12125559999', 1, 2500000000, 0, 0, 0, 'p:0/message-101', 2000, NULL),
        (103, 'message-103', 'other chat message', NULL, 'iMessage', '+12125558888', 2, 3000000000, 0, 0, 0, NULL, NULL, NULL);
      INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES
        (10, 100, 1000000000),
        (10, 101, 2000000000),
        (10, 102, 2500000000),
        (11, 103, 3000000000);
      """
  )

  return dbURL
}

private func scalar(_ database: OpaquePointer?, sql: String) throws -> Int {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }
  defer {
    sqlite3_finalize(statement)
  }

  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }

  return Int(sqlite3_column_int64(statement, 0))
}

private func stringScalar(_ database: OpaquePointer?, sql: String) throws -> String {
  var statement: OpaquePointer?
  guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }
  defer {
    sqlite3_finalize(statement)
  }

  guard sqlite3_step(statement) == SQLITE_ROW else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }

  guard let text = sqlite3_column_text(statement, 0) else {
    return ""
  }
  return String(cString: text)
}

private func execute(_ database: OpaquePointer?, sql: String) throws {
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw DatabaseError.statement(String(cString: sqlite3_errmsg(database)))
  }
}

private enum DatabaseError: Error {
  case statement(String)
}
