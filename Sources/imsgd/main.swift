import ContactsResolver
import Foundation
import ImsgProtocol
import MessagesStore

private let version = "dev"

enum ImsgdError: Error, CustomStringConvertible {
  case invalidArguments(String)
  case invalidEnvelope

  var description: String {
    switch self {
    case .invalidArguments(let message):
      return message
    case .invalidEnvelope:
      return "invalid envelope"
    }
  }
}

struct Options {
  let dbPath: String
  let showVersion: Bool
}

@main
struct ImsgdMain {
  static func main() throws {
    do {
      let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.showVersion {
        FileHandle.standardOutput.write(Data("\(version)\n".utf8))
      } else {
        try serve(dbPath: options.dbPath)
      }
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      Foundation.exit(1)
    }
  }
}

private func parseOptions(arguments: [String]) throws -> Options {
  var dbPath = MessagesHealthProbe.defaultChatDBPath
  var showVersion = false
  var index = 0

  while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "version", "--version":
      showVersion = true
      index += 1
    case "--db":
      guard index + 1 < arguments.count else {
        throw ImsgdError.invalidArguments("missing value for --db")
      }
      dbPath = arguments[index + 1]
      index += 2
    case "--help", "-h":
      throw ImsgdError.invalidArguments(
        """
        usage:
          imsgd [--db PATH]
          imsgd version
        """)
    default:
      throw ImsgdError.invalidArguments("unknown argument: \(argument)")
    }
  }

  return Options(dbPath: dbPath, showVersion: showVersion)
}

private func serve(dbPath: String) throws {
  let input = FileHandle.standardInput
  let output = FileHandle.standardOutput

  while let frame = try FrameIO.readFrame(from: input) {
    let responseEnvelope = try handleFrame(frame, dbPath: dbPath)
    let payload = try JSONSerialization.data(withJSONObject: responseEnvelope, options: [])
    try FrameIO.writeFrame(to: output, payload: payload)
  }
}

private func handleFrame(_ frame: Data, dbPath: String) throws -> [String: Any] {
  guard
    let object = try JSONSerialization.jsonObject(with: frame, options: []) as? [String: Any],
    let kind = object["kind"] as? String,
    kind == ProtocolConstants.requestKind,
    let request = object["request"] as? [String: Any],
    let id = request["id"] as? String,
    let method = request["method"] as? String
  else {
    throw ImsgdError.invalidEnvelope
  }

  do {
    switch method {
    case ProtocolConstants.handshakeMethod:
      return makeSuccessEnvelope(id: id, result: handleHandshake())
    case ProtocolConstants.healthMethod:
      return makeSuccessEnvelope(id: id, result: handleHealth(dbPath: dbPath))
    case ProtocolConstants.listChatsMethod:
      let limit =
        ((request["params"] as? [String: Any])?["limit"] as? Int)
        ?? ChatListQuery.defaultLimit
      return makeSuccessEnvelope(id: id, result: try handleListChats(dbPath: dbPath, limit: limit))
    case ProtocolConstants.getHistoryMethod:
      let params = (request["params"] as? [String: Any]) ?? [:]
      let chatID = try requiredInt64Param(params["chat_id"], name: "chat_id")
      let limit = optionalIntParam(params["limit"]) ?? ChatHistoryQuery.defaultLimit
      let beforeMessageID = optionalInt64Param(params["before"])
      return makeSuccessEnvelope(
        id: id,
        result: try handleGetHistory(
          dbPath: dbPath,
          chatID: chatID,
          limit: limit,
          beforeMessageID: beforeMessageID
        )
      )
    default:
      return makeErrorEnvelope(id: id, code: "not_implemented", message: "method not implemented")
    }
  } catch {
    return makeErrorEnvelope(id: id, code: "internal", message: "\(error)")
  }
}

private func handleHandshake() -> [String: Any] {
  [
    "protocol_version": ProtocolConstants.protocolVersion,
    "server_name": ProtocolConstants.serverName,
    "server_version": version,
    "read_only": true,
    "capabilities": [
      "read_only",
      "json_envelope",
      "length_prefixed_frames",
      "local_transport",
      "health",
      "chats",
      "history",
    ],
  ]
}

private func handleHealth(dbPath: String) -> [String: Any] {
  let messagesHealth = MessagesHealthProbe.probe(dbPath: dbPath)

  return [
    "ok": messagesHealth.ok,
    "read_only": true,
    "db_path": messagesHealth.dbPath,
    "db_exists": messagesHealth.dbExists,
    "can_read_db": messagesHealth.canReadDB,
    "sqlite_open_ok": messagesHealth.sqliteOpenOK,
    "protocol_version": ProtocolConstants.protocolVersion,
    "server_version": version,
  ]
}

private func handleListChats(dbPath: String, limit: Int) throws -> [[String: Any]] {
  let contactLookup = makeContactLookup()
  return try ChatListQuery.list(
    dbPath: dbPath,
    limit: limit,
    contactLookup: contactLookup
  ).map(\.jsonObject)
}

private func handleGetHistory(
  dbPath: String,
  chatID: Int64,
  limit: Int,
  beforeMessageID: Int64?
) throws -> [[String: Any]] {
  let contactLookup = makeContactLookup()
  return try ChatHistoryQuery.list(
    dbPath: dbPath,
    chatID: chatID,
    limit: limit,
    beforeMessageID: beforeMessageID,
    contactLookup: contactLookup
  ).map(\.jsonObject)
}

private func makeContactLookup() -> ContactLookup {
  let resolveContact = ContactLookupResolver.make()
  return { identifier in
    resolveContact(identifier).map {
      ResolvedChatContact(name: $0.name, label: $0.label)
    }
  }
}

private func requiredInt64Param(_ value: Any?, name: String) throws -> Int64 {
  guard let parsed = optionalInt64Param(value) else {
    throw ImsgdError.invalidArguments("missing value for \(name)")
  }
  return parsed
}

private func optionalInt64Param(_ value: Any?) -> Int64? {
  switch value {
  case let intValue as Int:
    return Int64(intValue)
  case let int64Value as Int64:
    return int64Value
  case let number as NSNumber:
    return number.int64Value
  default:
    return nil
  }
}

private func optionalIntParam(_ value: Any?) -> Int? {
  switch value {
  case let intValue as Int:
    return intValue
  case let int64Value as Int64:
    return Int(int64Value)
  case let number as NSNumber:
    return number.intValue
  default:
    return nil
  }
}

private func makeSuccessEnvelope(id: String, result: Any) -> [String: Any] {
  [
    "kind": ProtocolConstants.responseKind,
    "response": [
      "id": id,
      "result": result,
    ],
  ]
}

private func makeErrorEnvelope(id: String, code: String, message: String) -> [String: Any] {
  [
    "kind": ProtocolConstants.responseKind,
    "response": [
      "id": id,
      "error": [
        "code": code,
        "message": message,
      ],
    ],
  ]
}
