import Foundation
import MessagesStore
import SQLite3
import Testing

@Test
func historyListReturnsNewestMessagesFirst() throws {
  let dbURL = try makeChatHistoryTestDatabase()
  let messages = try ChatHistoryQuery.list(dbPath: dbURL.path, chatID: 10, limit: 10)

  #expect(messages.count == 3)
  #expect(messages.map(\.id) == [103, 101, 100])

  #expect(
    messages[0]
      == ChatMessage(
        id: 103,
        chatID: 10,
        guid: "message-103",
        sender: "+12125550100",
        senderName: nil,
        senderLabel: "+12125550100",
        fromMe: false,
        text: "latest from jane",
        createdAt: "2001-01-01T00:00:03.000Z",
        service: "iMessage",
        destinationCallerID: "+12125559999"
      )
  )

  #expect(
    messages[1]
      == ChatMessage(
        id: 101,
        chatID: 10,
        guid: "message-101",
        sender: "+12125550100",
        senderName: nil,
        senderLabel: nil,
        fromMe: true,
        text: "reply from me",
        createdAt: "2001-01-01T00:00:02.000Z",
        service: "iMessage",
        destinationCallerID: "+12125559999",
        attachments: [
          ChatMessage.Attachment(
            filename: "~/Library/Messages/Attachments/test/photo.heic",
            transferName: "photo.heic",
            uti: "public.heic",
            mimeType: "image/heic",
            totalBytes: 1234,
            isSticker: false,
            originalPath: (NSString(string: "~/Library/Messages/Attachments/test/photo.heic"))
              .expandingTildeInPath,
            missing: true
          )
        ],
        reactions: [
          ChatMessage.Reaction(
            id: 102,
            type: "love",
            emoji: "❤️",
            sender: "+12125550100",
            isFromMe: false,
            createdAt: "2001-01-01T00:00:02.500Z"
          )
        ]
      )
  )

  #expect(
    messages[2]
      == ChatMessage(
        id: 100,
        chatID: 10,
        guid: "message-100",
        sender: "+12125550100",
        senderName: nil,
        senderLabel: "+12125550100",
        fromMe: false,
        text: "first from jane",
        createdAt: "2001-01-01T00:00:01.000Z",
        service: "iMessage",
        destinationCallerID: "+12125559999"
      )
  )
}

@Test
func historyListUsesContactLabelsForIncomingMessages() throws {
  let dbURL = try makeChatHistoryTestDatabase()
  let messages = try ChatHistoryQuery.list(
    dbPath: dbURL.path,
    chatID: 10,
    limit: 10
  ) { identifier in
    if identifier == "+12125550100" {
      return ResolvedChatContact(name: "Jane Doe", label: "Jane Doe (+12125550100)")
    }
    return nil
  }

  #expect(messages[0].senderName == "Jane Doe")
  #expect(messages[0].senderLabel == "Jane Doe (+12125550100)")
  #expect(messages[1].senderName == nil)
  #expect(messages[1].senderLabel == nil)
  #expect(messages[2].senderName == "Jane Doe")
  #expect(messages[2].senderLabel == "Jane Doe (+12125550100)")
}

@Test
func historyListUsesDestinationCallerContactForOutboundMessages() throws {
  let dbURL = try makeChatHistoryTestDatabase()
  let messages = try ChatHistoryQuery.list(
    dbPath: dbURL.path,
    chatID: 10,
    limit: 10
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

  #expect(messages[1].fromMe)
  #expect(messages[1].sender == "+12125550100")
  #expect(messages[1].senderName == "Local User")
  #expect(messages[1].senderLabel == "Local User (+12125559999)")
}

@Test
func historyListRespectsBeforeCursor() throws {
  let dbURL = try makeChatHistoryTestDatabase()
  let messages = try ChatHistoryQuery.list(
    dbPath: dbURL.path,
    chatID: 10,
    limit: 2,
    beforeMessageID: 103
  )

  #expect(messages.map(\.id) == [101, 100])
}

@Test
func historyListReturnsEmptyForZeroLimit() throws {
  let dbURL = try makeChatHistoryTestDatabase()
  let messages = try ChatHistoryQuery.list(dbPath: dbURL.path, chatID: 10, limit: 0)
  #expect(messages.isEmpty)
}

@Test
func historyListRejectsNegativeLimit() throws {
  let dbURL = try makeChatHistoryTestDatabase()

  do {
    _ = try ChatHistoryQuery.list(dbPath: dbURL.path, chatID: 10, limit: -1)
    Issue.record("expected negative limit to throw")
  } catch let error as CustomStringConvertible {
    #expect(error.description == "limit must be zero or greater")
  }
}

@Test
func historyListRejectsInvalidChatID() throws {
  let dbURL = try makeChatHistoryTestDatabase()

  do {
    _ = try ChatHistoryQuery.list(dbPath: dbURL.path, chatID: 0, limit: 10)
    Issue.record("expected invalid chat_id to throw")
  } catch let error as CustomStringConvertible {
    #expect(error.description == "chat_id must be greater than zero")
  }
}

private func makeChatHistoryTestDatabase() throws -> URL {
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
        associated_message_type INTEGER
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
        ROWID, guid, text, attributedBody, service, destination_caller_id, handle_id, date, is_from_me, is_system_message, item_type, associated_message_guid, associated_message_type
      ) VALUES
        (100, 'message-100', 'first from jane', NULL, 'iMessage', '+12125559999', 1, 1000000000, 0, 0, 0, NULL, NULL),
        (101, 'message-101', NULL, X'012B0D7265706C792066726F6D206D658684', 'iMessage', '+12125559999', 1, 2000000000, 1, 0, 0, NULL, NULL),
        (102, 'message-102', 'tapback should hide', NULL, 'iMessage', '+12125559999', 1, 2500000000, 0, 0, 0, 'p:0/message-101', 2000),
        (103, 'message-103', 'latest from jane', NULL, 'iMessage', '+12125559999', 1, 3000000000, 0, 0, 0, NULL, NULL),
        (104, 'message-104', 'system should hide', NULL, 'iMessage', '+12125559999', 1, 3500000000, 0, 1, 0, NULL, NULL),
        (200, 'message-200', 'other chat message', NULL, 'iMessage', '+12125558888', 2, 4000000000, 0, 0, 0, NULL, NULL);
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
        (10, 104, 3500000000),
        (11, 200, 4000000000);
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO attachment (
        ROWID, guid, filename, uti, mime_type, transfer_name, total_bytes, is_sticker
      ) VALUES
        (1, 'attachment-1', '~/Library/Messages/Attachments/test/photo.heic', 'public.heic', 'image/heic', 'photo.heic', 1234, 0);
      """
  )
  try execute(
    database,
    sql: """
      INSERT INTO message_attachment_join (message_id, attachment_id) VALUES
        (101, 1);
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
