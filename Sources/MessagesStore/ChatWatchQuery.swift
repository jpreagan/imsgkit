import Foundation
import SQLite3

public struct WatchReactionEvent: Sendable, Equatable {
  public let id: Int64
  public let guid: String
  public let chatID: Int64
  public let targetGUID: String
  public let sender: String
  public let senderName: String?
  public let senderLabel: String?
  public let fromMe: Bool
  public let type: String
  public let emoji: String
  public let action: String
  public let createdAt: String?
  public let service: String
  public let destinationCallerID: String?

  public init(
    id: Int64,
    guid: String,
    chatID: Int64,
    targetGUID: String,
    sender: String,
    senderName: String? = nil,
    senderLabel: String? = nil,
    fromMe: Bool,
    type: String,
    emoji: String,
    action: String,
    createdAt: String?,
    service: String,
    destinationCallerID: String? = nil
  ) {
    self.id = id
    self.guid = guid
    self.chatID = chatID
    self.targetGUID = targetGUID
    self.sender = sender
    self.senderName = senderName
    self.senderLabel = senderLabel
    self.fromMe = fromMe
    self.type = type
    self.emoji = emoji
    self.action = action
    self.createdAt = createdAt
    self.service = service
    self.destinationCallerID = destinationCallerID
  }

  public var jsonObject: [String: Any] {
    [
      "id": id,
      "guid": guid,
      "chat_id": chatID,
      "target_guid": targetGUID,
      "sender": sender,
      "sender_name": senderName ?? NSNull(),
      "sender_label": senderLabel ?? NSNull(),
      "from_me": fromMe,
      "type": type,
      "emoji": emoji,
      "action": action,
      "created_at": createdAt ?? NSNull(),
      "service": service,
      "destination_caller_id": destinationCallerID ?? NSNull(),
    ]
  }
}

public struct WatchEvent: Sendable, Equatable {
  public let event: String
  public let message: ChatMessage?
  public let reaction: WatchReactionEvent?

  public init(
    event: String,
    message: ChatMessage? = nil,
    reaction: WatchReactionEvent? = nil
  ) {
    self.event = event
    self.message = message
    self.reaction = reaction
  }

  public var rowID: Int64 {
    if let message {
      return message.id
    }
    return reaction?.id ?? 0
  }

  public var jsonObject: [String: Any] {
    [
      "event": event,
      "message": message?.jsonObject ?? NSNull(),
      "reaction": reaction?.jsonObject ?? NSNull(),
    ]
  }
}

public struct WatchBatch: Sendable, Equatable {
  public let events: [WatchEvent]
  public let lastSeenRowID: Int64

  public init(events: [WatchEvent], lastSeenRowID: Int64) {
    self.events = events
    self.lastSeenRowID = lastSeenRowID
  }
}

public enum ChatWatchQuery {
  public static let defaultBatchLimit = 100

  public static func maxRowID(
    dbPath: String = MessagesHealthProbe.defaultChatDBPath
  ) throws -> Int64 {
    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    return try withReadOnlyDatabase(at: resolvedPath) { database in
      let sql = "SELECT COALESCE(MAX(ROWID), 0) FROM message"

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

      return sqlite3_column_int64(statement, 0)
    }
  }

  public static func loadBatch(
    dbPath: String = MessagesHealthProbe.defaultChatDBPath,
    afterRowID: Int64,
    throughRowID: Int64? = nil,
    limit: Int = defaultBatchLimit,
    chatID: Int64? = nil,
    startDate: Date? = nil,
    endDate: Date? = nil,
    includeReactions: Bool = false,
    includeMessageReactions: Bool = true,
    contactLookup: ContactLookup = { _ in nil }
  ) throws -> WatchBatch {
    if afterRowID < 0 {
      throw MessagesStoreError.invalidChatID(afterRowID)
    }
    if let chatID, chatID <= 0 {
      throw MessagesStoreError.invalidChatID(chatID)
    }
    if limit <= 0 {
      throw MessagesStoreError.invalidLimit(limit)
    }

    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    return try withReadOnlyDatabase(at: resolvedPath) { database in
      try validateModernMessageSchema(database: database, operation: "watch")
      let rows = try loadEventRows(
        database: database,
        afterRowID: afterRowID,
        throughRowID: throughRowID,
        limit: limit,
        startDate: startDate,
        endDate: endDate
      )

      var events: [WatchEvent] = []
      var reactionTargetCache: [String: ReactionTargetContext?] = [:]
      for row in rows {
        let resolvedRow = try resolveReactionContext(
          database: database,
          row: row,
          cache: &reactionTargetCache
        )
        if let event = makeEvent(
          database: database,
          row: resolvedRow,
          chatID: chatID,
          startDate: startDate,
          endDate: endDate,
          includeReactions: includeReactions,
          includeMessageReactions: includeMessageReactions,
          contactLookup: contactLookup
        ) {
          events.append(event)
        }
      }

      let lastSeenRowID = rows.last?.messageID ?? afterRowID
      return WatchBatch(events: events, lastSeenRowID: lastSeenRowID)
    }
  }

  private struct EventRow {
    let messageID: Int64
    let messageGUID: String
    let chatID: Int64
    let service: String
    let handleIdentifier: String
    let destinationCallerID: String
    let fromMe: Bool
    let text: String
    let attributedBody: Data
    let messageDate: Int64?
    let isSystemMessage: Bool
    let itemType: Int
    let associatedMessageGUID: String
    let associatedMessageType: Int?
    let threadOriginatorGUID: String
  }

  private struct SenderIdentity {
    let identifier: String
    let name: String?
    let label: String?
  }

  private struct ReactionTargetContext {
    let chatID: Int64
    let destinationCallerID: String
    let messageDate: Int64?
  }

  private static func loadEventRows(
    database: OpaquePointer,
    afterRowID: Int64,
    throughRowID: Int64?,
    limit: Int,
    startDate: Date?,
    endDate: Date?
  ) throws -> [EventRow] {
    let startTimestamp = startDate.map(messagesTimestamp(from:))
    let endTimestamp = endDate.map(messagesTimestamp(from:))
    let sql = """
      SELECT
        m.ROWID,
        COALESCE(m.guid, ''),
        COALESCE(cmj.chat_id, 0),
        COALESCE(m.service, ''),
        COALESCE(h.id, ''),
        COALESCE(m.destination_caller_id, ''),
        COALESCE(m.is_from_me, 0),
        COALESCE(m.text, ''),
        m.attributedBody,
        COALESCE(cmj.message_date, m.date),
        COALESCE(m.is_system_message, 0),
        COALESCE(m.item_type, 0),
        COALESCE(m.associated_message_guid, ''),
        m.associated_message_type,
        COALESCE(m.thread_originator_guid, '')
      FROM message m
      LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE m.ROWID > ?
        AND (? IS NULL OR m.ROWID <= ?)
        AND (? IS NULL OR COALESCE(cmj.message_date, m.date) >= ?)
        AND (? IS NULL OR COALESCE(cmj.message_date, m.date) < ?)
      ORDER BY m.ROWID ASC
      LIMIT ?
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, afterRowID)
    bindNullableInt64Value(statement, index: 2, value: throughRowID)
    bindNullableInt64Value(statement, index: 3, value: throughRowID)
    bindNullableInt64Value(statement, index: 4, value: startTimestamp)
    bindNullableInt64Value(statement, index: 5, value: startTimestamp)
    bindNullableInt64Value(statement, index: 6, value: endTimestamp)
    bindNullableInt64Value(statement, index: 7, value: endTimestamp)
    sqlite3_bind_int64(statement, 8, Int64(limit))

    var rows: [EventRow] = []
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        rows.append(
          EventRow(
            messageID: sqlite3_column_int64(statement, 0),
            messageGUID: sqliteText(statement, column: 1),
            chatID: sqlite3_column_int64(statement, 2),
            service: sqliteText(statement, column: 3),
            handleIdentifier: sqliteText(statement, column: 4),
            destinationCallerID: sqliteText(statement, column: 5),
            fromMe: sqlite3_column_int64(statement, 6) != 0,
            text: sqliteText(statement, column: 7),
            attributedBody: sqliteBlobData(statement, column: 8),
            messageDate: sqliteValue(statement, column: 9),
            isSystemMessage: sqlite3_column_int64(statement, 10) != 0,
            itemType: Int(sqlite3_column_int64(statement, 11)),
            associatedMessageGUID: sqliteText(statement, column: 12),
            associatedMessageType: sqliteOptionalInt(statement, column: 13),
            threadOriginatorGUID: sqliteText(statement, column: 14)
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func resolveReactionContext(
    database: OpaquePointer,
    row: EventRow,
    cache: inout [String: ReactionTargetContext?]
  ) throws -> EventRow {
    guard
      let associatedType = row.associatedMessageType,
      ChatReactionType.isReaction(associatedType)
    else {
      return row
    }

    let targetGUID = normalizedAssociatedGUID(row.associatedMessageGUID)
    guard !targetGUID.isEmpty else {
      return row
    }

    let target: ReactionTargetContext?
    if let cachedTarget = cache[targetGUID] {
      target = cachedTarget
    } else {
      let loadedTarget = try loadReactionTargetContext(database: database, targetGUID: targetGUID)
      cache[targetGUID] = loadedTarget
      target = loadedTarget
    }

    guard let target else {
      return row
    }

    return EventRow(
      messageID: row.messageID,
      messageGUID: row.messageGUID,
      chatID: target.chatID,
      service: row.service,
      handleIdentifier: row.handleIdentifier,
      destinationCallerID: target.destinationCallerID,
      fromMe: row.fromMe,
      text: row.text,
      attributedBody: row.attributedBody,
      messageDate: target.messageDate,
      isSystemMessage: row.isSystemMessage,
      itemType: row.itemType,
      associatedMessageGUID: row.associatedMessageGUID,
      associatedMessageType: row.associatedMessageType,
      threadOriginatorGUID: row.threadOriginatorGUID
    )
  }

  private static func loadReactionTargetContext(
    database: OpaquePointer,
    targetGUID: String
  ) throws -> ReactionTargetContext? {
    let sql = """
      SELECT
        COALESCE(cmj.chat_id, 0),
        COALESCE(m.destination_caller_id, ''),
        COALESCE(cmj.message_date, m.date)
      FROM message m
      LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE m.guid = ?
      LIMIT 1
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqliteBindText(statement, index: 1, value: targetGUID)

    let stepResult = sqlite3_step(statement)
    switch stepResult {
    case SQLITE_ROW:
      return ReactionTargetContext(
        chatID: sqlite3_column_int64(statement, 0),
        destinationCallerID: sqliteText(statement, column: 1),
        messageDate: sqliteValue(statement, column: 2)
      )
    case SQLITE_DONE:
      return nil
    default:
      throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
    }
  }

  private static func makeEvent(
    database: OpaquePointer,
    row: EventRow,
    chatID: Int64?,
    startDate: Date?,
    endDate: Date?,
    includeReactions: Bool,
    includeMessageReactions: Bool,
    contactLookup: ContactLookup
  ) -> WatchEvent? {
    guard row.itemType == 0, row.isSystemMessage == false else {
      return nil
    }
    if let chatID, row.chatID != chatID {
      return nil
    }

    let eventDate = row.messageDate.map {
      Date(timeIntervalSinceReferenceDate: Double($0) / 1_000_000_000)
    }
    if let startDate, let eventDate, eventDate < startDate {
      return nil
    }
    if let endDate, let eventDate, eventDate >= endDate {
      return nil
    }

    if let associatedType = row.associatedMessageType, ChatReactionType.isReaction(associatedType) {
      guard includeReactions else {
        return nil
      }
      return makeReactionEvent(row: row, contactLookup: contactLookup)
    }

    return WatchEvent(
      event: "message",
      message: makeMessage(
        database: database,
        row: row,
        includeReactions: includeMessageReactions,
        contactLookup: contactLookup
      )
    )
  }

  private static func makeMessage(
    database: OpaquePointer,
    row: EventRow,
    includeReactions: Bool,
    contactLookup: ContactLookup
  ) -> ChatMessage {
    let sender = resolveSender(row: row, contactLookup: contactLookup)
    let selfSender = resolveSelfSender(row: row, contactLookup: contactLookup)

    return ChatMessage(
      id: row.messageID,
      chatID: row.chatID,
      guid: row.messageGUID,
      replyToGUID: replyToGUID(
        associatedGUID: row.associatedMessageGUID,
        associatedType: row.associatedMessageType
      ),
      threadOriginatorGUID: row.threadOriginatorGUID.isEmpty ? nil : row.threadOriginatorGUID,
      sender: sender.identifier,
      senderName: row.fromMe ? selfSender?.name : sender.name,
      senderLabel: row.fromMe ? selfSender?.label : sender.label,
      fromMe: row.fromMe,
      text: resolveText(row: row),
      createdAt: formatMessagesTimestamp(row.messageDate),
      service: row.service,
      destinationCallerID: row.destinationCallerID.isEmpty ? nil : row.destinationCallerID,
      attachments: loadChatAttachments(database: database, messageID: row.messageID),
      reactions:
        includeReactions
        ? loadChatReactions(database: database, messageGUID: row.messageGUID)
        : []
    )
  }

  private static func makeReactionEvent(
    row: EventRow,
    contactLookup: ContactLookup
  ) -> WatchEvent? {
    guard let associatedType = row.associatedMessageType else {
      return nil
    }

    let sender = resolveSender(row: row, contactLookup: contactLookup)
    let selfSender = resolveSelfSender(row: row, contactLookup: contactLookup)
    let text = resolveText(row: row)
    let targetGUID = normalizedAssociatedGUID(row.associatedMessageGUID)

    let reactionType: ChatReactionType?
    let action: String
    if ChatReactionType.isRemove(associatedType) {
      let customEmoji = associatedType == 3006 ? extractCustomEmoji(from: text) : nil
      reactionType = ChatReactionType.fromRemoval(associatedType, customEmoji: customEmoji)
      action = "removed"
    } else {
      let customEmoji = associatedType == 2006 ? extractCustomEmoji(from: text) : nil
      reactionType = ChatReactionType(rawValue: associatedType, customEmoji: customEmoji)
      action = "added"
    }

    guard let reactionType else {
      return nil
    }

    return WatchEvent(
      event: "reaction",
      reaction: WatchReactionEvent(
        id: row.messageID,
        guid: row.messageGUID,
        chatID: row.chatID,
        targetGUID: targetGUID,
        sender: sender.identifier,
        senderName: row.fromMe ? selfSender?.name : sender.name,
        senderLabel: row.fromMe ? selfSender?.label : sender.label,
        fromMe: row.fromMe,
        type: reactionType.name,
        emoji: reactionType.emoji,
        action: action,
        createdAt: formatMessagesTimestamp(row.messageDate),
        service: row.service,
        destinationCallerID: row.destinationCallerID.isEmpty ? nil : row.destinationCallerID
      )
    )
  }

  private static func resolveSender(
    row: EventRow,
    contactLookup: ContactLookup
  ) -> SenderIdentity {
    let identifier = resolveParticipantIdentifier(row: row)
    guard !identifier.isEmpty else {
      return SenderIdentity(identifier: "", name: nil, label: nil)
    }

    if let contact = contactLookup(identifier) {
      return SenderIdentity(identifier: identifier, name: contact.name, label: contact.label)
    }

    return SenderIdentity(identifier: identifier, name: nil, label: identifier)
  }

  private static func resolveSelfSender(
    row: EventRow,
    contactLookup: ContactLookup
  ) -> SenderIdentity? {
    guard row.fromMe else {
      return nil
    }

    let identifier = row.destinationCallerID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !identifier.isEmpty else {
      return nil
    }

    if let contact = contactLookup(identifier) {
      return SenderIdentity(identifier: identifier, name: contact.name, label: contact.label)
    }

    return nil
  }

  private static func resolveParticipantIdentifier(row: EventRow) -> String {
    let handleIdentifier = row.handleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !handleIdentifier.isEmpty {
      return handleIdentifier
    }

    return row.destinationCallerID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func resolveText(row: EventRow) -> String {
    if !row.text.isEmpty {
      return row.text
    }

    return AttributedBodyParser.parse(row.attributedBody)
  }
}
