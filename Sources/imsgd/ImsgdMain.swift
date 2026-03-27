import ContactsResolver
import Foundation
import ImsgProtocol
import MessagesStore

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

enum Command {
  case serve
  case sync
}

struct Options {
  let command: Command
  let dbPath: String
  let configPath: String
  let showVersion: Bool
}

private struct SyncPublishStatus {
  let target: String
  let attempted: Bool
  let pending: Bool
  let published: Bool?
  let error: String?
}

@main
struct ImsgdMain {
  static func main() throws {
    do {
      let options = try parseOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      if options.showVersion {
        FileHandle.standardOutput.write(Data("\(BuildInfo.version)\n".utf8))
      } else if options.command == .sync {
        try sync(sourceDBPath: options.dbPath, configPath: options.configPath)
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
  var configPath = SyncConfiguration.defaultPath
  var showVersion = false
  var command: Command = .serve
  var index = 0

  if let firstArgument = arguments.first, firstArgument == "sync" {
    command = .sync
    index = 1
  }

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
    case "--config":
      guard index + 1 < arguments.count else {
        throw ImsgdError.invalidArguments("missing value for --config")
      }
      configPath = arguments[index + 1]
      index += 2
    case "--help", "-h":
      throw ImsgdError.invalidArguments(
        """
        usage:
          imsgd [--db PATH]
          imsgd sync [--db PATH] [--config PATH]
          imsgd version
        """)
    default:
      throw ImsgdError.invalidArguments("unknown argument: \(argument)")
    }
  }

  return Options(
    command: command,
    dbPath: dbPath,
    configPath: configPath,
    showVersion: showVersion
  )
}

private let replicaSyncPollInterval: TimeInterval = 1.0

private func sync(sourceDBPath: String, configPath: String) throws {
  let configuration = try SyncConfiguration.load(at: configPath)
  let publisher = try ReplicaPublisher(configuration: configuration)
  let replicaDBPath = ReplicaStore.defaultWorkingReplicaDBPath
  let contactLookup = makeContactLookup()
  var isFirstPass = true
  var publishState = SyncPublishState()

  while true {
    let result = try ReplicaStore.syncOnce(
      sourceDBPath: sourceDBPath,
      replicaDBPath: replicaDBPath,
      builderVersion: BuildInfo.version,
      contactLookup: contactLookup
    )
    let replicaChanged = isFirstPass || result.rebuilt || result.appliedWatchEventCount > 0
    let attachmentsChanged = isFirstPass || result.rebuilt || result.appliedMessageCount > 0
    if attachmentsChanged {
      try ReplicaAttachmentMirror.refresh(replicaDBPath: result.replicaDBPath)
    }
    if replicaChanged {
      publishState.recordChange()
    }

    let now = Date()
    var publishStatus: SyncPublishStatus?
    if publishState.shouldAttemptPublish(now: now, interval: configuration.publishInterval) {
      do {
        try publisher.publish(replicaDBPath: result.replicaDBPath)
        publishState.recordPublishAttempt(at: now, succeeded: true)
        publishStatus = SyncPublishStatus(
          target: configuration.publishTarget,
          attempted: true,
          pending: false,
          published: true,
          error: nil
        )
      } catch {
        publishState.recordPublishAttempt(at: now, succeeded: false)
        publishStatus = SyncPublishStatus(
          target: configuration.publishTarget,
          attempted: true,
          pending: publishState.pending,
          published: false,
          error: String(describing: error)
        )
      }
    } else if replicaChanged || publishState.pending {
      publishStatus = SyncPublishStatus(
        target: configuration.publishTarget,
        attempted: false,
        pending: publishState.pending,
        published: nil,
        error: nil
      )
    }

    if isFirstPass || replicaChanged || publishStatus?.attempted == true {
      try writeSyncResult(result, publishStatus: publishStatus)
    }

    isFirstPass = false
    Thread.sleep(forTimeInterval: replicaSyncPollInterval)
  }
}

private func writeSyncResult(
  _ result: ReplicaSyncResult,
  publishStatus: SyncPublishStatus?
) throws {
  let payload: [String: Any] = [
    "source_db_path": result.sourceDBPath,
    "replica_db_path": result.replicaDBPath,
    "chat_count": result.chatCount,
    "message_count": result.messageCount,
    "watch_event_count": result.watchEventCount,
    "applied_message_count": result.appliedMessageCount,
    "applied_watch_event_count": result.appliedWatchEventCount,
    "source_max_rowid": result.sourceMaxRowID,
    "synced_at": result.syncedAt,
    "rebuilt": result.rebuilt,
  ]
  var mutablePayload = payload
  if let publishStatus {
    mutablePayload["publish_target"] = publishStatus.target
    mutablePayload["publish_attempted"] = publishStatus.attempted
    mutablePayload["publish_pending"] = publishStatus.pending
    if let published = publishStatus.published {
      mutablePayload["published"] = published
    }
    if let error = publishStatus.error {
      mutablePayload["publish_error"] = error
    }
  }
  let data = try JSONSerialization.data(
    withJSONObject: mutablePayload,
    options: [.sortedKeys]
  )
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
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
    "server_version": BuildInfo.version,
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
    "server_version": BuildInfo.version,
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
