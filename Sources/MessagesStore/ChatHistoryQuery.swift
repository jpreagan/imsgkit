import Foundation
import SQLite3

public struct ChatMessage: Sendable, Equatable {
  public struct Attachment: Sendable, Equatable {
    public let filename: String
    public let transferName: String
    public let uti: String
    public let mimeType: String
    public let totalBytes: Int64
    public let isSticker: Bool
    public let originalPath: String
    public let missing: Bool

    public init(
      filename: String,
      transferName: String,
      uti: String,
      mimeType: String,
      totalBytes: Int64,
      isSticker: Bool,
      originalPath: String,
      missing: Bool
    ) {
      self.filename = filename
      self.transferName = transferName
      self.uti = uti
      self.mimeType = mimeType
      self.totalBytes = totalBytes
      self.isSticker = isSticker
      self.originalPath = originalPath
      self.missing = missing
    }

    public var jsonObject: [String: Any] {
      [
        "filename": filename,
        "transfer_name": transferName,
        "uti": uti,
        "mime_type": mimeType,
        "total_bytes": totalBytes,
        "is_sticker": isSticker,
        "original_path": originalPath,
        "missing": missing,
      ]
    }
  }

  public struct Reaction: Sendable, Equatable {
    public let id: Int64
    public let type: String
    public let emoji: String
    public let sender: String
    public let isFromMe: Bool
    public let createdAt: String?

    public init(
      id: Int64,
      type: String,
      emoji: String,
      sender: String,
      isFromMe: Bool,
      createdAt: String?
    ) {
      self.id = id
      self.type = type
      self.emoji = emoji
      self.sender = sender
      self.isFromMe = isFromMe
      self.createdAt = createdAt
    }

    public var jsonObject: [String: Any] {
      [
        "id": id,
        "type": type,
        "emoji": emoji,
        "sender": sender,
        "is_from_me": isFromMe,
        "created_at": createdAt ?? NSNull(),
      ]
    }
  }

  public let id: Int64
  public let chatID: Int64
  public let guid: String
  public let replyToGUID: String?
  public let threadOriginatorGUID: String?
  public let sender: String
  public let senderName: String?
  public let senderLabel: String?
  public let fromMe: Bool
  public let text: String
  public let createdAt: String?
  public let service: String
  public let destinationCallerID: String?
  public let attachments: [Attachment]
  public let reactions: [Reaction]

  public init(
    id: Int64,
    chatID: Int64,
    guid: String,
    replyToGUID: String? = nil,
    threadOriginatorGUID: String? = nil,
    sender: String,
    senderName: String? = nil,
    senderLabel: String? = nil,
    fromMe: Bool,
    text: String,
    createdAt: String?,
    service: String,
    destinationCallerID: String? = nil,
    attachments: [Attachment] = [],
    reactions: [Reaction] = []
  ) {
    self.id = id
    self.chatID = chatID
    self.guid = guid
    self.replyToGUID = replyToGUID
    self.threadOriginatorGUID = threadOriginatorGUID
    self.sender = sender
    self.senderName = senderName
    self.senderLabel = senderLabel
    self.fromMe = fromMe
    self.text = text
    self.createdAt = createdAt
    self.service = service
    self.destinationCallerID = destinationCallerID
    self.attachments = attachments
    self.reactions = reactions
  }

  public var jsonObject: [String: Any] {
    [
      "id": id,
      "chat_id": chatID,
      "guid": guid,
      "reply_to_guid": replyToGUID ?? NSNull(),
      "thread_originator_guid": threadOriginatorGUID ?? NSNull(),
      "sender": sender,
      "sender_name": senderName ?? NSNull(),
      "sender_label": senderLabel ?? NSNull(),
      "from_me": fromMe,
      "text": text,
      "created_at": createdAt ?? NSNull(),
      "service": service,
      "destination_caller_id": destinationCallerID ?? NSNull(),
      "attachments": attachments.map(\.jsonObject),
      "reactions": reactions.map(\.jsonObject),
    ]
  }
}

public enum ChatHistoryQuery {
  public static let defaultLimit = 50

  public static func list(
    dbPath: String = MessagesHealthProbe.defaultChatDBPath,
    chatID: Int64,
    limit: Int = defaultLimit,
    beforeMessageID: Int64? = nil,
    contactLookup: ContactLookup = { _ in nil }
  ) throws -> [ChatMessage] {
    if chatID <= 0 {
      throw MessagesStoreError.invalidChatID(chatID)
    }
    if limit < 0 {
      throw MessagesStoreError.invalidLimit(limit)
    }
    if let beforeMessageID, beforeMessageID <= 0 {
      throw MessagesStoreError.invalidBeforeMessageID(beforeMessageID)
    }
    guard limit > 0 else {
      return []
    }

    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    return try withReadOnlyDatabase(at: resolvedPath) { database in
      let rows = try loadMessageRows(
        database: database,
        chatID: chatID,
        limit: limit,
        beforeMessageID: beforeMessageID
      )
      return rows.map {
        makeMessage(database: database, row: $0, contactLookup: contactLookup)
      }
    }
  }

  private struct MessageRow {
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
    let associatedMessageGUID: String
    let associatedMessageType: Int?
    let threadOriginatorGUID: String
  }

  private struct SenderIdentity {
    let identifier: String
    let name: String?
    let label: String?
  }

  private static func loadMessageRows(
    database: OpaquePointer,
    chatID: Int64,
    limit: Int,
    beforeMessageID: Int64?
  ) throws -> [MessageRow] {
    let hasAttributedBody = try databaseHasColumn(
      database: database,
      table: "message",
      column: "attributedBody"
    )
    let hasDestinationCallerID = try databaseHasColumn(
      database: database,
      table: "message",
      column: "destination_caller_id"
    )
    let hasAssociatedMessageType = try databaseHasColumn(
      database: database,
      table: "message",
      column: "associated_message_type"
    )
    let hasAssociatedMessageGUID = try databaseHasColumn(
      database: database,
      table: "message",
      column: "associated_message_guid"
    )
    let hasThreadOriginatorGUID = try databaseHasColumn(
      database: database,
      table: "message",
      column: "thread_originator_guid"
    )

    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let destinationCallerColumn =
      hasDestinationCallerID ? "COALESCE(m.destination_caller_id, '')" : "''"
    let associatedMessageGUIDColumn =
      hasAssociatedMessageGUID ? "COALESCE(m.associated_message_guid, '')" : "''"
    let associatedMessageTypeColumn =
      hasAssociatedMessageType ? "m.associated_message_type" : "NULL"
    let threadOriginatorGUIDColumn =
      hasThreadOriginatorGUID ? "COALESCE(m.thread_originator_guid, '')" : "''"
    let reactionFilter: String
    if hasAssociatedMessageType {
      reactionFilter =
        "AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
    } else {
      reactionFilter = "AND m.associated_message_guid IS NULL"
    }

    let sql = """
      SELECT
        m.ROWID,
        COALESCE(m.guid, ''),
        cmj.chat_id,
        COALESCE(m.service, ''),
        COALESCE(h.id, ''),
        \(destinationCallerColumn),
        COALESCE(m.is_from_me, 0),
        COALESCE(m.text, ''),
        \(bodyColumn),
        cmj.message_date,
        \(associatedMessageGUIDColumn),
        \(associatedMessageTypeColumn),
        \(threadOriginatorGUIDColumn)
      FROM chat_message_join cmj
      INNER JOIN message m ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON h.ROWID = m.handle_id
      WHERE cmj.chat_id = ?
        AND COALESCE(m.item_type, 0) = 0
        AND COALESCE(m.is_system_message, 0) = 0
        \(reactionFilter)
        AND (
          ? IS NULL
          OR cmj.message_date < (
            SELECT older.message_date
            FROM chat_message_join older
            WHERE older.chat_id = ? AND older.message_id = ?
          )
          OR (
            cmj.message_date = (
              SELECT older.message_date
              FROM chat_message_join older
              WHERE older.chat_id = ? AND older.message_id = ?
            )
            AND m.ROWID < ?
          )
        )
      ORDER BY cmj.message_date DESC, m.ROWID DESC
      LIMIT ?
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw MessagesStoreError.prepareStatement(lastSQLiteError(from: database))
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, chatID)
    bindNullableInt64(statement, index: 2, value: beforeMessageID)
    sqlite3_bind_int64(statement, 3, chatID)
    bindNullableInt64(statement, index: 4, value: beforeMessageID)
    sqlite3_bind_int64(statement, 5, chatID)
    bindNullableInt64(statement, index: 6, value: beforeMessageID)
    bindNullableInt64(statement, index: 7, value: beforeMessageID)
    sqlite3_bind_int64(statement, 8, Int64(limit))

    var rows: [MessageRow] = []
    while true {
      let stepResult = sqlite3_step(statement)
      switch stepResult {
      case SQLITE_ROW:
        rows.append(
          MessageRow(
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
            associatedMessageGUID: sqliteText(statement, column: 10),
            associatedMessageType: sqliteOptionalInt(statement, column: 11),
            threadOriginatorGUID: sqliteText(statement, column: 12)
          )
        )
      case SQLITE_DONE:
        return rows
      default:
        throw MessagesStoreError.stepStatement(lastSQLiteError(from: database))
      }
    }
  }

  private static func makeMessage(
    database: OpaquePointer,
    row: MessageRow,
    contactLookup: ContactLookup
  ) -> ChatMessage {
    let sender = resolveSender(row: row, contactLookup: contactLookup)
    let selfSender = resolveSelfSender(row: row, contactLookup: contactLookup)
    let attachments = loadAttachments(database: database, messageID: row.messageID)
    let reactions = loadReactions(database: database, row: row)

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
      attachments: attachments,
      reactions: reactions
    )
  }

  private static func resolveSender(
    row: MessageRow,
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
    row: MessageRow,
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

  private static func resolveText(row: MessageRow) -> String {
    if !row.text.isEmpty {
      return row.text
    }

    return AttributedBodyParser.parse(row.attributedBody)
  }

  private static func resolveParticipantIdentifier(row: MessageRow) -> String {
    let handleIdentifier = row.handleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if !handleIdentifier.isEmpty {
      return handleIdentifier
    }

    return row.destinationCallerID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func loadAttachments(
    database: OpaquePointer,
    messageID: Int64
  ) -> [ChatMessage.Attachment] {
    guard (try? databaseHasTable(database: database, table: "message_attachment_join")) == true,
      (try? databaseHasTable(database: database, table: "attachment")) == true
    else {
      return []
    }

    let sql = """
      SELECT
        COALESCE(a.filename, ''),
        COALESCE(a.transfer_name, ''),
        COALESCE(a.uti, ''),
        COALESCE(a.mime_type, ''),
        COALESCE(a.total_bytes, 0),
        COALESCE(a.is_sticker, 0)
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqlite3_bind_int64(statement, 1, messageID)

    var attachments: [ChatMessage.Attachment] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let filename = sqliteText(statement, column: 0)
      let resolved = AttachmentResolver.resolve(filename)
      attachments.append(
        ChatMessage.Attachment(
          filename: filename,
          transferName: sqliteText(statement, column: 1),
          uti: sqliteText(statement, column: 2),
          mimeType: sqliteText(statement, column: 3),
          totalBytes: sqlite3_column_int64(statement, 4),
          isSticker: sqlite3_column_int64(statement, 5) != 0,
          originalPath: resolved.resolved,
          missing: resolved.missing
        )
      )
    }

    return attachments
  }

  private static func loadReactions(
    database: OpaquePointer,
    row: MessageRow
  ) -> [ChatMessage.Reaction] {
    guard !row.messageGUID.isEmpty else {
      return []
    }
    guard
      (try? databaseHasColumn(
        database: database,
        table: "message",
        column: "associated_message_type"
      )) == true,
      (try? databaseHasColumn(
        database: database,
        table: "message",
        column: "associated_message_guid"
      )) == true
    else {
      return []
    }

    let hasAttributedBody =
      (try? databaseHasColumn(
        database: database,
        table: "message",
        column: "attributedBody"
      )) == true
    let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
    let sql = """
      SELECT
        r.ROWID,
        r.associated_message_type,
        COALESCE(h.id, ''),
        COALESCE(r.is_from_me, 0),
        r.date,
        COALESCE(r.text, ''),
        \(bodyColumn)
      FROM message r
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE (
          r.associated_message_guid = ?
          OR r.associated_message_guid LIKE '%/' || ?
        )
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      ORDER BY r.date ASC
      """

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      return []
    }
    defer {
      sqlite3_finalize(statement)
    }

    sqliteBindText(statement, index: 1, value: row.messageGUID)
    sqliteBindText(statement, index: 2, value: row.messageGUID)

    struct ReactionKey: Hashable {
      let sender: String
      let isFromMe: Bool
      let reactionType: ChatReactionType
    }

    var reactions: [ChatMessage.Reaction] = []
    var reactionIndex: [ReactionKey: Int] = [:]

    while sqlite3_step(statement) == SQLITE_ROW {
      let id = sqlite3_column_int64(statement, 0)
      let associatedType = Int(sqlite3_column_int64(statement, 1))
      let sender = sqliteText(statement, column: 2)
      let isFromMe = sqlite3_column_int64(statement, 3) != 0
      let createdAt = formatMessagesTimestamp(sqliteValue(statement, column: 4))
      let text = sqliteText(statement, column: 5)
      let body = sqliteBlobData(statement, column: 6)
      let resolvedText = text.isEmpty ? AttributedBodyParser.parse(body) : text

      if ChatReactionType.isRemove(associatedType) {
        let customEmoji = associatedType == 3006 ? extractCustomEmoji(from: resolvedText) : nil
        if let reactionType = ChatReactionType.fromRemoval(
          associatedType,
          customEmoji: customEmoji
        ) {
          let key = ReactionKey(
            sender: sender,
            isFromMe: isFromMe,
            reactionType: reactionType
          )
          if let index = reactionIndex.removeValue(forKey: key) {
            reactions.remove(at: index)
            reactionIndex = Dictionary(
              uniqueKeysWithValues: reactions.enumerated().compactMap { offset, reaction in
                guard let type = reactionKind(from: reaction) else {
                  return nil
                }
                return (
                  ReactionKey(
                    sender: reaction.sender,
                    isFromMe: reaction.isFromMe,
                    reactionType: type
                  ),
                  offset
                )
              }
            )
          }
          continue
        }
      }

      let customEmoji =
        associatedType == 2006 ? extractCustomEmoji(from: resolvedText) : nil
      guard
        let reactionType = ChatReactionType(
          rawValue: associatedType,
          customEmoji: customEmoji
        )
      else {
        continue
      }

      let reaction = ChatMessage.Reaction(
        id: id,
        type: reactionType.name,
        emoji: reactionType.emoji,
        sender: sender,
        isFromMe: isFromMe,
        createdAt: createdAt
      )

      let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
      if let index = reactionIndex[key] {
        reactions[index] = reaction
      } else {
        reactionIndex[key] = reactions.count
        reactions.append(reaction)
      }
    }

    return reactions
  }
}

private func reactionKind(from reaction: ChatMessage.Reaction) -> ChatReactionType? {
  switch reaction.type {
  case "love":
    return .love
  case "like":
    return .like
  case "dislike":
    return .dislike
  case "laugh":
    return .laugh
  case "emphasis":
    return .emphasis
  case "question":
    return .question
  case "custom":
    return .custom(reaction.emoji)
  default:
    return nil
  }
}

private func bindNullableInt64(_ statement: OpaquePointer?, index: Int32, value: Int64?) {
  guard let value else {
    sqlite3_bind_null(statement, index)
    return
  }

  sqlite3_bind_int64(statement, index, value)
}
