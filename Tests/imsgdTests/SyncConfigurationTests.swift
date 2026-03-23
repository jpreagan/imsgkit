import Foundation
import Testing

@testable import imsgd

@Test
func syncConfigurationParsesReplicaPublishSettings() throws {
  let configuration = try SyncConfiguration.parse(
    contents: """
      [replica]
      publish = "user@remote:/var/lib/imsgkit/replica.db"
      publish_interval_seconds = 15
      remote_executable = "/opt/homebrew/bin/sqlite3_rsync"
      """,
    path: "/tmp/config.toml"
  )

  #expect(configuration.publishTarget == "user@remote:/var/lib/imsgkit/replica.db")
  #expect(configuration.publishInterval == 15)
  #expect(configuration.remoteExecutable == "/opt/homebrew/bin/sqlite3_rsync")
}

@Test
func syncConfigurationRequiresPublishTarget() throws {
  do {
    _ = try SyncConfiguration.parse(
      contents: """
        [replica]
        publish_interval_seconds = 5
        """,
      path: "/tmp/config.toml"
    )
    Issue.record("expected missing publish target to throw")
  } catch let error as CustomStringConvertible {
    #expect(error.description == "missing replica publish target in /tmp/config.toml")
  }
}
