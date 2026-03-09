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
    try handleFrame(frame, dbPath: dbPath, output: output)
  }
}

private func handleFrame(_ frame: Data, dbPath: String, output: FileHandle) throws {
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
      try writeEnvelope(makeSuccessEnvelope(id: id, result: handleHandshake()), to: output)
    case ProtocolConstants.healthMethod:
      try writeEnvelope(
        makeSuccessEnvelope(id: id, result: handleHealth(dbPath: dbPath)),
        to: output
      )
    case ProtocolConstants.listChatsMethod:
      let limit =
        ((request["params"] as? [String: Any])?["limit"] as? Int)
        ?? ChatListQuery.defaultLimit
      try writeEnvelope(
        makeSuccessEnvelope(id: id, result: try handleListChats(dbPath: dbPath, limit: limit)),
        to: output
      )
    case ProtocolConstants.getHistoryMethod:
      let params = (request["params"] as? [String: Any]) ?? [:]
      let chatID = try requiredInt64Param(params["chat_id"], name: "chat_id")
      let limit = optionalIntParam(params["limit"]) ?? ChatHistoryQuery.defaultLimit
      let start = optionalStringParam(params["start"])
      let end = optionalStringParam(params["end"])
      try writeEnvelope(
        makeSuccessEnvelope(
          id: id,
          result: try handleGetHistory(
            dbPath: dbPath,
            chatID: chatID,
            limit: limit,
            start: start,
            end: end
          )
        ),
        to: output
      )
    case ProtocolConstants.watchMethod:
      let params = (request["params"] as? [String: Any]) ?? [:]
      let debounceMilliseconds = optionalIntParam(params["debounce_milliseconds"]) ?? 250
      try handleWatch(
        id: id,
        dbPath: dbPath,
        output: output,
        chatID: optionalInt64Param(params["chat_id"]),
        debounceMilliseconds: debounceMilliseconds,
        start: optionalStringParam(params["start"]),
        end: optionalStringParam(params["end"]),
        includeReactions: optionalBoolParam(params["include_reactions"]) ?? false
      )
    default:
      try writeEnvelope(
        makeErrorEnvelope(id: id, code: "not_implemented", message: "method not implemented"),
        to: output
      )
    }
  } catch {
    try writeEnvelope(
      makeErrorEnvelope(id: id, code: "internal", message: "\(error)"),
      to: output
    )
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
      "watch",
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
  start: String?,
  end: String?
) throws -> [[String: Any]] {
  let contactLookup = makeContactLookup()
  return try ChatHistoryQuery.list(
    dbPath: dbPath,
    chatID: chatID,
    limit: limit,
    startDate: try parseISO8601Date(start, name: "start"),
    endDate: try parseISO8601Date(end, name: "end"),
    contactLookup: contactLookup
  ).map(\.jsonObject)
}

private func handleWatch(
  id: String,
  dbPath: String,
  output: FileHandle,
  chatID: Int64?,
  debounceMilliseconds: Int,
  start: String?,
  end: String?,
  includeReactions: Bool
) throws {
  if let chatID, chatID <= 0 {
    throw ImsgdError.invalidArguments("chat_id must be greater than zero")
  }
  if debounceMilliseconds < 0 {
    throw ImsgdError.invalidArguments("debounce_milliseconds must be zero or greater")
  }

  let watcher = MessageWatcher(
    dbPath: dbPath,
    contactLookup: makeContactLookup()
  )
  let configuration = MessageWatcherConfiguration(
    debounceInterval: Double(debounceMilliseconds) / 1000,
    startDate: try parseISO8601Date(start, name: "start"),
    endDate: try parseISO8601Date(end, name: "end"),
    includeReactions: includeReactions
  )

  try writeEnvelope(makeSuccessEnvelope(id: id, result: [:]), to: output)

  let writer = WatchStreamWriter(output: output, requestID: id)
  let streamState = WatchStreamState()
  let semaphore = DispatchSemaphore(value: 0)
  let stream = watcher.stream(chatID: chatID, configuration: configuration)
  let iteratorTask = Task { @Sendable in
    do {
      for try await event in stream {
        try writer.write(event: event)
      }
    } catch {
      streamState.error = error
    }
    semaphore.signal()
  }

  semaphore.wait()
  iteratorTask.cancel()

  if let streamError = streamState.error {
    throw streamError
  }
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

private func optionalBoolParam(_ value: Any?) -> Bool? {
  switch value {
  case let boolValue as Bool:
    return boolValue
  case let number as NSNumber:
    return number.boolValue
  default:
    return nil
  }
}

private func optionalStringParam(_ value: Any?) -> String? {
  guard let string = value as? String else {
    return nil
  }

  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func parseISO8601Date(_ value: String?, name: String) throws -> Date? {
  guard let value else {
    return nil
  }

  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: value) {
    return date
  }

  let standard = ISO8601DateFormatter()
  standard.formatOptions = [.withInternetDateTime]
  if let date = standard.date(from: value) {
    return date
  }

  throw ImsgdError.invalidArguments("\(name) must be a valid ISO8601 timestamp")
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

private func makeEventEnvelope(requestID: String, payload: Any) -> [String: Any] {
  [
    "kind": ProtocolConstants.eventKind,
    "event": [
      "request_id": requestID,
      "payload": payload,
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

private func writeEnvelope(_ envelope: [String: Any], to output: FileHandle) throws {
  let payload = try JSONSerialization.data(withJSONObject: envelope, options: [])
  try FrameIO.writeFrame(to: output, payload: payload)
}

private final class WatchStreamWriter: @unchecked Sendable {
  private let output: FileHandle
  private let requestID: String

  init(output: FileHandle, requestID: String) {
    self.output = output
    self.requestID = requestID
  }

  func write(event: WatchEvent) throws {
    try writeEnvelope(
      makeEventEnvelope(requestID: requestID, payload: event.jsonObject),
      to: output
    )
  }
}

private final class WatchStreamState: @unchecked Sendable {
  var error: Error?
}
