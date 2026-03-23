import Foundation
import Testing

@testable import imsgd

@Test
func syncPublishStateThrottlesRetriesAfterFailure() {
  var state = SyncPublishState()
  let startedAt = Date(timeIntervalSince1970: 1_000)

  state.recordChange()
  #expect(state.shouldAttemptPublish(now: startedAt, interval: 5))

  state.recordPublishAttempt(at: startedAt, succeeded: false)

  #expect(state.pending)
  #expect(!state.shouldAttemptPublish(now: startedAt.addingTimeInterval(1), interval: 5))
  #expect(state.shouldAttemptPublish(now: startedAt.addingTimeInterval(5), interval: 5))
}

@Test
func syncPublishStateClearsPendingAfterSuccess() {
  var state = SyncPublishState()
  let startedAt = Date(timeIntervalSince1970: 2_000)

  state.recordChange()
  state.recordPublishAttempt(at: startedAt, succeeded: true)

  #expect(!state.pending)
  #expect(!state.shouldAttemptPublish(now: startedAt.addingTimeInterval(10), interval: 5))
}
