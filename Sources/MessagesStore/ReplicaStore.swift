import Foundation
import SQLite3

public struct ReplicaBuildResult: Sendable, Equatable {
  public let sourceDBPath: String
  public let replicaDBPath: String
  public let chatCount: Int
  public let messageCount: Int
  public let watchEventCount: Int
  public let sourceMaxRowID: Int64
  public let generatedAt: String

  public init(
    sourceDBPath: String,
    replicaDBPath: String,
    chatCount: Int,
    messageCount: Int,
    watchEventCount: Int,
    sourceMaxRowID: Int64,
    generatedAt: String
  ) {
    self.sourceDBPath = sourceDBPath
    self.replicaDBPath = replicaDBPath
    self.chatCount = chatCount
    self.messageCount = messageCount
    self.watchEventCount = watchEventCount
    self.sourceMaxRowID = sourceMaxRowID
    self.generatedAt = generatedAt
  }
}

public struct ReplicaSyncResult: Sendable, Equatable {
  public let sourceDBPath: String
  public let replicaDBPath: String
  public let chatCount: Int
  public let messageCount: Int
  public let watchEventCount: Int
  public let appliedMessageCount: Int
  public let appliedWatchEventCount: Int
  public let sourceMaxRowID: Int64
  public let syncedAt: String
  public let rebuilt: Bool

  public init(
    sourceDBPath: String,
    replicaDBPath: String,
    chatCount: Int,
    messageCount: Int,
    watchEventCount: Int,
    appliedMessageCount: Int,
    appliedWatchEventCount: Int,
    sourceMaxRowID: Int64,
    syncedAt: String,
    rebuilt: Bool
  ) {
    self.sourceDBPath = sourceDBPath
    self.replicaDBPath = replicaDBPath
    self.chatCount = chatCount
    self.messageCount = messageCount
    self.watchEventCount = watchEventCount
    self.appliedMessageCount = appliedMessageCount
    self.appliedWatchEventCount = appliedWatchEventCount
    self.sourceMaxRowID = sourceMaxRowID
    self.syncedAt = syncedAt
    self.rebuilt = rebuilt
  }
}

public enum ReplicaStore {
  public static let schemaVersion = "1"
  private static let batchLimit = 500
  private static let requiredTables: Set<String> = [
    "metadata",
    "chats",
    "messages",
    "watch_events",
  ]

  public static var defaultSupportDirectoryPath: String {
    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    return homeDirectory.appendingPathComponent(
      "Library/Application Support/imsgkit",
      isDirectory: true
    )
    .path
  }

  public static var defaultReplicaDBPath: String {
    let applicationSupport = URL(fileURLWithPath: defaultSupportDirectoryPath, isDirectory: true)
    return applicationSupport.appendingPathComponent("replica.db").path
  }

  public static var defaultWorkingReplicaDBPath: String {
    let applicationSupport = URL(fileURLWithPath: defaultSupportDirectoryPath, isDirectory: true)
    return applicationSupport
      .appendingPathComponent("state", isDirectory: true)
      .appendingPathComponent("replica.db")
      .path
  }

  public static func build(
    sourceDBPath: String = MessagesHealthProbe.defaultChatDBPath,
    replicaDBPath: String = defaultReplicaDBPath,
    builderVersion: String = "dev",
    contactLookup: ContactLookup = { _ in nil }
  ) throws -> ReplicaBuildResult {
    let sourcePath = (sourceDBPath as NSString).expandingTildeInPath
    let outputPath = (replicaDBPath as NSString).expandingTildeInPath
    return try buildReplica(
      sourcePath: sourcePath,
      outputPath: outputPath,
      builderVersion: builderVersion,
      contactLookup: contactLookup
    )
  }

  public static func syncOnce(
    sourceDBPath: String = MessagesHealthProbe.defaultChatDBPath,
    replicaDBPath: String = defaultWorkingReplicaDBPath,
    builderVersion: String = "dev",
    contactLookup: ContactLookup = { _ in nil }
  ) throws -> ReplicaSyncResult {
    let sourcePath = (sourceDBPath as NSString).expandingTildeInPath
    let outputPath = (replicaDBPath as NSString).expandingTildeInPath

    guard
      let state = try loadReplicaState(
        replicaDBPath: outputPath,
        sourceDBPath: sourcePath
      )
    else {
      let buildResult = try buildReplica(
        sourcePath: sourcePath,
        outputPath: outputPath,
        builderVersion: builderVersion,
        contactLookup: contactLookup
      )
      return ReplicaSyncResult(
        sourceDBPath: buildResult.sourceDBPath,
        replicaDBPath: buildResult.replicaDBPath,
        chatCount: buildResult.chatCount,
        messageCount: buildResult.messageCount,
        watchEventCount: buildResult.watchEventCount,
        appliedMessageCount: buildResult.messageCount,
        appliedWatchEventCount: buildResult.watchEventCount,
        sourceMaxRowID: buildResult.sourceMaxRowID,
        syncedAt: buildResult.generatedAt,
        rebuilt: true
      )
    }

    let sourceMaxRowID = try ChatWatchQuery.maxRowID(dbPath: sourcePath)
    if sourceMaxRowID < state.sourceMaxRowID {
      let buildResult = try buildReplica(
        sourcePath: sourcePath,
        outputPath: outputPath,
        builderVersion: builderVersion,
        contactLookup: contactLookup
      )
      return ReplicaSyncResult(
        sourceDBPath: buildResult.sourceDBPath,
        replicaDBPath: buildResult.replicaDBPath,
        chatCount: buildResult.chatCount,
        messageCount: buildResult.messageCount,
        watchEventCount: buildResult.watchEventCount,
        appliedMessageCount: buildResult.messageCount,
        appliedWatchEventCount: buildResult.watchEventCount,
        sourceMaxRowID: buildResult.sourceMaxRowID,
        syncedAt: buildResult.generatedAt,
        rebuilt: true
      )
    }

    let syncedAt = iso8601Timestamp(from: Date())
    var appliedMessageCount = 0
    var appliedWatchEventCount = 0
    var updatedChatIDs = Set<Int64>()
    var refreshedMessageGUIDs = Set<String>()

    try withReadWriteDatabase(at: outputPath, create: false) { replicaDatabase in
      try withTransaction(database: replicaDatabase) {
        var cursor = state.sourceMaxRowID
        while cursor < sourceMaxRowID {
          let batch = try ChatWatchQuery.loadBatch(
            dbPath: sourcePath,
            afterRowID: cursor,
            throughRowID: sourceMaxRowID,
            limit: batchLimit,
            includeReactions: true,
            includeMessageReactions: false,
            contactLookup: contactLookup
          )
          guard batch.lastSeenRowID > cursor else {
            break
          }

          cursor = batch.lastSeenRowID
          for event in batch.events {
            appliedWatchEventCount += 1
            try insertWatchEvent(event, into: replicaDatabase)

            if let message = event.message {
              appliedMessageCount += 1
              updatedChatIDs.insert(message.chatID)
              try upsertMessage(message, into: replicaDatabase)
              try updateMessageWatchEvent(message, in: replicaDatabase)
            }

            if let reaction = event.reaction {
              updatedChatIDs.insert(reaction.chatID)
              if !reaction.targetGUID.isEmpty {
                refreshedMessageGUIDs.insert(reaction.targetGUID)
              }
            }
          }
        }

        for messageGUID in refreshedMessageGUIDs.sorted() {
          guard
            let message = try ChatHistoryQuery.message(
              dbPath: sourcePath,
              guid: messageGUID,
              contactLookup: contactLookup
            )
          else {
            continue
          }

          updatedChatIDs.insert(message.chatID)
          try upsertMessage(message, into: replicaDatabase)
          try updateMessageWatchEvent(message, in: replicaDatabase)
        }

        for chatID in updatedChatIDs.sorted() {
          guard
            let chat = try ChatListQuery.get(
              dbPath: sourcePath,
              chatID: chatID,
              contactLookup: contactLookup
            )
          else {
            continue
          }

          try upsertChat(chat, into: replicaDatabase)
        }

        try upsertMetadata(
          database: replicaDatabase,
          values: [
            "schema_version": schemaVersion,
            "builder_version": builderVersion,
            "generated_at": syncedAt,
            "source_db_path": sourcePath,
            "source_max_rowid": String(sourceMaxRowID),
          ]
        )
      }
    }

    let counts = try loadReplicaCounts(replicaDBPath: outputPath)
    return ReplicaSyncResult(
      sourceDBPath: sourcePath,
      replicaDBPath: outputPath,
      chatCount: counts.chatCount,
      messageCount: counts.messageCount,
      watchEventCount: counts.watchEventCount,
      appliedMessageCount: appliedMessageCount,
      appliedWatchEventCount: appliedWatchEventCount,
      sourceMaxRowID: sourceMaxRowID,
      syncedAt: syncedAt,
      rebuilt: false
    )
  }

  private struct ReplicaState {
    let sourceMaxRowID: Int64
  }

  private struct ReplicaCounts {
    let chatCount: Int
    let messageCount: Int
    let watchEventCount: Int
  }

  private static func buildReplica(
    sourcePath: String,
    outputPath: String,
    builderVersion: String,
    contactLookup: ContactLookup
  ) throws -> ReplicaBuildResult {
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDirectory = outputURL.deletingLastPathComponent()
    let fileManager = FileManager.default

    try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outputDirectory.path)

    let temporaryURL = outputDirectory.appendingPathComponent(
      ".replica-\(UUID().uuidString).db",
      isDirectory: false
    )
    if fileManager.fileExists(atPath: temporaryURL.path) {
      try fileManager.removeItem(at: temporaryURL)
    }

    let generatedAt = iso8601Timestamp(from: Date())
    let sourceMaxRowID = try ChatWatchQuery.maxRowID(dbPath: sourcePath)
    let chats = try ChatListQuery.list(
      dbPath: sourcePath,
      limit: Int.max,
      contactLookup: contactLookup
    )

    var messageCount = 0
    var watchEventCount = 0
    var refreshedMessageGUIDs = Set<String>()
    try withReadWriteDatabase(at: temporaryURL.path) { replicaDatabase in
      try executeStatements(
        database: replicaDatabase,
        sql: """
          PRAGMA journal_mode=DELETE;
          PRAGMA synchronous=NORMAL;
          """
      )
      try withTransaction(database: replicaDatabase) {
        try createSchema(database: replicaDatabase)
        try upsertMetadata(
          database: replicaDatabase,
          values: [
            "schema_version": schemaVersion,
            "builder_version": builderVersion,
            "generated_at": generatedAt,
            "source_db_path": sourcePath,
            "source_max_rowid": String(sourceMaxRowID),
          ]
        )

        for chat in chats {
          try upsertChat(chat, into: replicaDatabase)
        }

        var cursor: Int64 = 0
        while cursor < sourceMaxRowID {
          let batch = try ChatWatchQuery.loadBatch(
            dbPath: sourcePath,
            afterRowID: cursor,
            throughRowID: sourceMaxRowID,
            limit: batchLimit,
            includeReactions: true,
            includeMessageReactions: false,
            contactLookup: contactLookup
          )
          guard batch.lastSeenRowID > cursor else {
            break
          }

          cursor = batch.lastSeenRowID
          for event in batch.events {
            watchEventCount += 1
            try insertWatchEvent(event, into: replicaDatabase)
            if let message = event.message {
              messageCount += 1
              try upsertMessage(message, into: replicaDatabase)
            } else if let reaction = event.reaction, !reaction.targetGUID.isEmpty {
              refreshedMessageGUIDs.insert(reaction.targetGUID)
            }
          }
        }

        for messageGUID in refreshedMessageGUIDs.sorted() {
          guard
            let message = try ChatHistoryQuery.message(
              dbPath: sourcePath,
              guid: messageGUID,
              contactLookup: contactLookup
            )
          else {
            continue
          }

          try upsertMessage(message, into: replicaDatabase)
          try updateMessageWatchEvent(message, in: replicaDatabase)
        }
      }
    }

    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
    if fileManager.fileExists(atPath: outputURL.path) {
      _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
      try fileManager.moveItem(at: temporaryURL, to: outputURL)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)

    return ReplicaBuildResult(
      sourceDBPath: sourcePath,
      replicaDBPath: outputURL.path,
      chatCount: chats.count,
      messageCount: messageCount,
      watchEventCount: watchEventCount,
      sourceMaxRowID: sourceMaxRowID,
      generatedAt: generatedAt
    )
  }

  private static func loadReplicaState(
    replicaDBPath: String,
    sourceDBPath: String
  ) throws -> ReplicaState? {
    guard FileManager.default.fileExists(atPath: replicaDBPath) else {
      return nil
    }

    return try? withReadOnlyDatabase(at: replicaDBPath) { database in
      let tables = try databaseTables(database: database)
      guard requiredTables.isSubset(of: tables) else {
        throw MessagesStoreError.unsupportedSchema("replica database schema mismatch")
      }

      let metadata = try loadMetadata(database: database)
      guard metadata["schema_version"] == schemaVersion else {
        throw MessagesStoreError.unsupportedSchema("replica schema version mismatch")
      }
      guard metadata["source_db_path"] == sourceDBPath else {
        throw MessagesStoreError.unsupportedSchema("replica source path mismatch")
      }
      guard
        let sourceMaxRowIDValue = metadata["source_max_rowid"],
        let sourceMaxRowID = Int64(sourceMaxRowIDValue)
      else {
        throw MessagesStoreError.unsupportedSchema("replica source watermark missing")
      }

      return ReplicaState(sourceMaxRowID: sourceMaxRowID)
    }
  }

  private static func loadReplicaCounts(replicaDBPath: String) throws -> ReplicaCounts {
    try withReadOnlyDatabase(at: replicaDBPath) { database in
      ReplicaCounts(
        chatCount: try countRows(database: database, table: "chats"),
        messageCount: try countRows(database: database, table: "messages"),
        watchEventCount: try countRows(database: database, table: "watch_events")
      )
    }
  }

  private static func createSchema(database: OpaquePointer) throws {
    try executeStatements(
      database: database,
      sql: """
        CREATE TABLE metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE chats (
          chat_id INTEGER PRIMARY KEY,
          service TEXT NOT NULL,
          identifier TEXT NOT NULL,
          label TEXT NOT NULL,
          contact_name TEXT,
          participant_count INTEGER NOT NULL,
          participants_json TEXT NOT NULL,
          last_message_at TEXT,
          message_count INTEGER NOT NULL
        );
        CREATE TABLE messages (
          message_id INTEGER PRIMARY KEY,
          chat_id INTEGER NOT NULL,
          guid TEXT NOT NULL,
          reply_to_guid TEXT,
          thread_originator_guid TEXT,
          sender TEXT NOT NULL,
          sender_name TEXT,
          sender_label TEXT,
          from_me INTEGER NOT NULL,
          text TEXT NOT NULL,
          created_at TEXT,
          service TEXT NOT NULL,
          destination_caller_id TEXT,
          attachments_json TEXT NOT NULL,
          reactions_json TEXT NOT NULL
        );
        CREATE TABLE watch_events (
          source_rowid INTEGER PRIMARY KEY,
          event_type TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          chat_id INTEGER NOT NULL,
          created_at TEXT
        );
        CREATE INDEX idx_chats_last_message ON chats(last_message_at DESC, chat_id DESC);
        CREATE INDEX idx_messages_chat_order ON messages(chat_id, created_at DESC, message_id DESC);
        CREATE INDEX idx_watch_events_chat_rowid ON watch_events(chat_id, source_rowid);
        """
    )
  }

  private static func loadMetadata(database: OpaquePointer) throws -> [String: String] {
    let sql = "SELECT key, value FROM metadata;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    var metadata: [String: String] = [:]
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        metadata[sqliteText(statement, column: 0)] = sqliteText(statement, column: 1)
      case SQLITE_DONE:
        return metadata
      default:
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func countRows(database: OpaquePointer, table: String) throws -> Int {
    let sql = "SELECT COUNT(*) FROM \(table);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }

    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func upsertMetadata(
    database: OpaquePointer,
    values: [String: String]
  ) throws {
    let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    for key in values.keys.sorted() {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqliteBindText(statement, index: 1, value: key)
      sqliteBindText(statement, index: 2, value: values[key] ?? "")
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func upsertChat(_ chat: ChatSummary, into database: OpaquePointer) throws {
    let sql = """
      INSERT OR REPLACE INTO chats (
        chat_id,
        service,
        identifier,
        label,
        contact_name,
        participant_count,
        participants_json,
        last_message_at,
        message_count
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, chat.id)
    sqliteBindText(statement, index: 2, value: chat.service)
    sqliteBindText(statement, index: 3, value: chat.identifier)
    sqliteBindText(statement, index: 4, value: chat.label)
    sqliteBindOptionalText(statement, index: 5, value: chat.contactName)
    sqlite3_bind_int64(statement, 6, Int64(chat.participantCount))
    sqliteBindText(statement, index: 7, value: jsonString(from: chat.participants))
    sqliteBindOptionalText(statement, index: 8, value: chat.lastMessageAt)
    sqlite3_bind_int64(statement, 9, Int64(chat.messageCount))

    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }
  }

  private static func upsertMessage(_ message: ChatMessage, into database: OpaquePointer) throws {
    let sql = """
      INSERT OR REPLACE INTO messages (
        message_id,
        chat_id,
        guid,
        reply_to_guid,
        thread_originator_guid,
        sender,
        sender_name,
        sender_label,
        from_me,
        text,
        created_at,
        service,
        destination_caller_id,
        attachments_json,
        reactions_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, message.id)
    sqlite3_bind_int64(statement, 2, message.chatID)
    sqliteBindText(statement, index: 3, value: message.guid)
    sqliteBindOptionalText(statement, index: 4, value: message.replyToGUID)
    sqliteBindOptionalText(statement, index: 5, value: message.threadOriginatorGUID)
    sqliteBindText(statement, index: 6, value: message.sender)
    sqliteBindOptionalText(statement, index: 7, value: message.senderName)
    sqliteBindOptionalText(statement, index: 8, value: message.senderLabel)
    sqliteBindBool(statement, index: 9, value: message.fromMe)
    sqliteBindText(statement, index: 10, value: message.text)
    sqliteBindOptionalText(statement, index: 11, value: message.createdAt)
    sqliteBindText(statement, index: 12, value: message.service)
    sqliteBindOptionalText(statement, index: 13, value: message.destinationCallerID)
    sqliteBindText(
      statement,
      index: 14,
      value: jsonString(from: message.attachments.map(\.jsonObject))
    )
    sqliteBindText(
      statement,
      index: 15,
      value: jsonString(from: message.reactions.map(\.jsonObject))
    )

    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }
  }

  private static func insertWatchEvent(_ event: WatchEvent, into database: OpaquePointer) throws {
    let sql = """
      INSERT OR IGNORE INTO watch_events (
        source_rowid,
        event_type,
        payload_json,
        chat_id,
        created_at
      ) VALUES (?, ?, ?, ?, ?);
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, event.rowID)
    sqliteBindText(statement, index: 2, value: event.event)
    sqliteBindText(statement, index: 3, value: jsonString(from: event.jsonObject))
    sqlite3_bind_int64(statement, 4, event.message?.chatID ?? event.reaction?.chatID ?? 0)
    sqliteBindOptionalText(
      statement,
      index: 5,
      value: event.message?.createdAt ?? event.reaction?.createdAt
    )

    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }
  }

  private static func updateMessageWatchEvent(
    _ message: ChatMessage,
    in database: OpaquePointer
  ) throws {
    let sql = """
      UPDATE watch_events
      SET payload_json = ?, chat_id = ?, created_at = ?
      WHERE source_rowid = ? AND event_type = 'message';
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqliteBindText(
      statement,
      index: 1,
      value: jsonString(from: WatchEvent(event: "message", message: message).jsonObject)
    )
    sqlite3_bind_int64(statement, 2, message.chatID)
    sqliteBindOptionalText(statement, index: 3, value: message.createdAt)
    sqlite3_bind_int64(statement, 4, message.id)

    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }
  }
}

private func jsonString(from object: Any) -> String {
  guard JSONSerialization.isValidJSONObject(object) else {
    return "null"
  }

  guard let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
    return "null"
  }

  return String(decoding: data, as: UTF8.self)
}

private func iso8601Timestamp(from date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}
