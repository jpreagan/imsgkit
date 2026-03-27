import Foundation
import SQLite3

func validateModernMessageSchema(
  database: OpaquePointer,
  operation: String
) throws {
  let messageColumns = try databaseColumns(database: database, table: "message")
  let requiredMessageColumns: Set<String> = [
    "attributedBody",
    "destination_caller_id",
    "associated_message_guid",
    "associated_message_type",
    "thread_originator_guid",
  ]
  let missingMessageColumns = requiredMessageColumns.subtracting(messageColumns).sorted()
  guard missingMessageColumns.isEmpty else {
    throw MessagesStoreError.unsupportedSchema(
      "\(operation) requires a modern Messages chat.db schema; missing message columns: \(missingMessageColumns.joined(separator: ", "))"
    )
  }

  let tables = try databaseTables(database: database)
  let requiredTables: Set<String> = ["attachment", "message_attachment_join"]
  let missingTables = requiredTables.subtracting(tables).sorted()
  guard missingTables.isEmpty else {
    throw MessagesStoreError.unsupportedSchema(
      "\(operation) requires a modern Messages chat.db schema; missing tables: \(missingTables.joined(separator: ", "))"
    )
  }
}

func loadChatAttachments(
  database: OpaquePointer,
  messageID: Int64
) -> [ChatMessage.Attachment] {
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
        path: resolved.path,
        missing: resolved.missing,
        replicaRelativePath: resolved.replicaRelativePath
      )
    )
  }

  return attachments
}

func loadChatReactions(
  database: OpaquePointer,
  messageGUID: String
) -> [ChatMessage.Reaction] {
  guard !messageGUID.isEmpty else {
    return []
  }

  let sql = """
    SELECT
      r.ROWID,
      r.associated_message_type,
      COALESCE(h.id, ''),
      COALESCE(r.is_from_me, 0),
      r.date,
      COALESCE(r.text, ''),
      r.attributedBody
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

  sqliteBindText(statement, index: 1, value: messageGUID)
  sqliteBindText(statement, index: 2, value: messageGUID)

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
              guard let type = chatReactionKind(from: reaction) else {
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

func chatReactionKind(from reaction: ChatMessage.Reaction) -> ChatReactionType? {
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

func bindNullableInt64Value(_ statement: OpaquePointer?, index: Int32, value: Int64?) {
  guard let value else {
    sqlite3_bind_null(statement, index)
    return
  }

  sqlite3_bind_int64(statement, index, value)
}
