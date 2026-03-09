import Darwin
import Foundation

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var batchLimit: Int
  public var startDate: Date?
  public var endDate: Date?
  public var includeReactions: Bool

  public init(
    debounceInterval: TimeInterval = 0.25,
    batchLimit: Int = ChatWatchQuery.defaultBatchLimit,
    startDate: Date? = nil,
    endDate: Date? = nil,
    includeReactions: Bool = false
  ) {
    self.debounceInterval = debounceInterval
    self.batchLimit = batchLimit
    self.startDate = startDate
    self.endDate = endDate
    self.includeReactions = includeReactions
  }
}

public final class MessageWatcher: @unchecked Sendable {
  private let dbPath: String
  private let contactLookup: ContactLookup

  public init(
    dbPath: String = MessagesHealthProbe.defaultChatDBPath,
    contactLookup: @escaping ContactLookup = { _ in nil }
  ) {
    self.dbPath = dbPath
    self.contactLookup = contactLookup
  }

  public func stream(
    chatID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<WatchEvent, Error> {
    AsyncThrowingStream { continuation in
      let state = WatchState(
        dbPath: dbPath,
        chatID: chatID,
        configuration: configuration,
        contactLookup: contactLookup,
        continuation: continuation
      )
      state.start()
      continuation.onTermination = { _ in
        state.stop()
      }
    }
  }
}

private final class WatchState: @unchecked Sendable {
  private let dbPath: String
  private let chatID: Int64?
  private let configuration: MessageWatcherConfiguration
  private let contactLookup: ContactLookup
  private let continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation
  private let queue = DispatchQueue(label: "imsgkit.watch", qos: .userInitiated)

  private var cursor: Int64 = 0
  private var pending = false
  private var finished = false
  private var sources: [DispatchSourceFileSystemObject] = []

  init(
    dbPath: String,
    chatID: Int64?,
    configuration: MessageWatcherConfiguration,
    contactLookup: @escaping ContactLookup,
    continuation: AsyncThrowingStream<WatchEvent, Error>.Continuation
  ) {
    self.dbPath = dbPath
    self.chatID = chatID
    self.configuration = configuration
    self.contactLookup = contactLookup
    self.continuation = continuation
  }

  func start() {
    let resolvedPath = (dbPath as NSString).expandingTildeInPath
    let paths = [resolvedPath, resolvedPath + "-wal", resolvedPath + "-shm"]
    for path in paths {
      if let source = makeSource(path: path) {
        sources.append(source)
      }
    }

    queue.async {
      self.bootstrap()
    }
  }

  func stop() {
    queue.async {
      self.finish(nil)
    }
  }

  private func bootstrap() {
    do {
      let snapshotRowID = try ChatWatchQuery.maxRowID(dbPath: dbPath)
      if configuration.startDate != nil || configuration.endDate != nil {
        try replayHistory(throughRowID: snapshotRowID)
      }
      cursor = snapshotRowID
      poll()
    } catch {
      finish(error)
    }
  }

  private func replayHistory(throughRowID: Int64) throws {
    var historyCursor: Int64 = 0

    while historyCursor < throughRowID {
      let batch = try ChatWatchQuery.loadBatch(
        dbPath: dbPath,
        afterRowID: historyCursor,
        throughRowID: throughRowID,
        limit: configuration.batchLimit,
        chatID: chatID,
        startDate: configuration.startDate,
        endDate: configuration.endDate,
        includeReactions: configuration.includeReactions,
        contactLookup: contactLookup
      )
      guard batch.lastSeenRowID > historyCursor else {
        break
      }
      historyCursor = batch.lastSeenRowID
      for event in batch.events {
        continuation.yield(event)
      }
    }
  }

  private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      return nil
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.schedulePoll()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    return source
  }

  private func schedulePoll() {
    guard finished == false, pending == false else {
      return
    }

    pending = true
    queue.asyncAfter(deadline: .now() + configuration.debounceInterval) {
      self.pending = false
      self.poll()
    }
  }

  private func poll() {
    guard finished == false else {
      return
    }

    do {
      while true {
        let upperRowID = try ChatWatchQuery.maxRowID(dbPath: dbPath)
        guard upperRowID > cursor else {
          return
        }

        let batch = try ChatWatchQuery.loadBatch(
          dbPath: dbPath,
          afterRowID: cursor,
          throughRowID: upperRowID,
          limit: configuration.batchLimit,
          chatID: chatID,
          startDate: configuration.startDate,
          endDate: configuration.endDate,
          includeReactions: configuration.includeReactions,
          contactLookup: contactLookup
        )
        guard batch.lastSeenRowID > cursor else {
          cursor = upperRowID
          return
        }

        cursor = batch.lastSeenRowID
        for event in batch.events {
          continuation.yield(event)
        }

        if cursor >= upperRowID {
          return
        }
      }
    } catch {
      finish(error)
    }
  }

  private func finish(_ error: Error?) {
    guard finished == false else {
      return
    }
    finished = true

    for source in sources {
      source.cancel()
    }
    sources.removeAll()

    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
  }
}
