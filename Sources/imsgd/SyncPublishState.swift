import Foundation

struct SyncPublishState {
  private(set) var pending = false
  private(set) var lastAttemptAt: Date?

  mutating func recordChange() {
    pending = true
  }

  func shouldAttemptPublish(now: Date, interval: TimeInterval) -> Bool {
    guard pending else {
      return false
    }

    guard let lastAttemptAt else {
      return true
    }

    return now.timeIntervalSince(lastAttemptAt) >= interval
  }

  mutating func recordPublishAttempt(at time: Date, succeeded: Bool) {
    lastAttemptAt = time
    if succeeded {
      pending = false
    }
  }
}
