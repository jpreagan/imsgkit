import Foundation
import MessagesStore

enum SyncConfigurationError: Error, CustomStringConvertible {
  case missingConfig(String)
  case invalidConfig(String)

  var description: String {
    switch self {
    case .missingConfig(let path):
      return "missing sync config: \(path)"
    case .invalidConfig(let message):
      return message
    }
  }
}

struct SyncConfiguration: Equatable {
  static let defaultPublishIntervalSeconds: TimeInterval = 5

  let publishTarget: String
  let publishInterval: TimeInterval
  let remoteExecutable: String?

  static var defaultPath: String {
    let supportURL = URL(
      fileURLWithPath: ReplicaStore.defaultSupportDirectoryPath,
      isDirectory: true
    )
    return supportURL.appendingPathComponent("config.toml").path
  }

  static func load(at path: String = defaultPath) throws -> SyncConfiguration {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
      throw SyncConfigurationError.missingConfig(expandedPath)
    }

    let contents: String
    do {
      contents = try String(contentsOfFile: expandedPath, encoding: .utf8)
    } catch {
      throw SyncConfigurationError.invalidConfig(
        "read sync config \(expandedPath): \(error.localizedDescription)"
      )
    }

    return try parse(contents: contents, path: expandedPath)
  }

  static func parse(contents: String, path: String) throws -> SyncConfiguration {
    enum Section: Equatable {
      case none
      case replica
    }

    var section: Section = .none
    var publishTarget: String?
    var publishInterval = defaultPublishIntervalSeconds
    var remoteExecutable: String?

    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty {
        continue
      }

      if line.hasPrefix("[") {
        guard line.hasSuffix("]") else {
          throw SyncConfigurationError.invalidConfig("invalid config section in \(path): \(line)")
        }

        let name = String(line.dropFirst().dropLast())
          .trimmingCharacters(in: .whitespacesAndNewlines)
        section = name == "replica" ? .replica : .none
        continue
      }

      guard section == .replica else {
        continue
      }

      let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2 else {
        throw SyncConfigurationError.invalidConfig("invalid config line in \(path): \(line)")
      }

      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

      switch key {
      case "publish":
        publishTarget = try parseString(value, path: path, key: key)
      case "publish_interval_seconds":
        guard let seconds = TimeInterval(value), seconds > 0 else {
          throw SyncConfigurationError.invalidConfig(
            "invalid \(key) in \(path): expected positive number"
          )
        }
        publishInterval = seconds
      case "remote_executable":
        remoteExecutable = try parseString(value, path: path, key: key)
      default:
        throw SyncConfigurationError.invalidConfig("unknown replica config key in \(path): \(key)")
      }
    }

    guard let publishTarget, !publishTarget.isEmpty else {
      throw SyncConfigurationError.invalidConfig("missing replica publish target in \(path)")
    }

    return SyncConfiguration(
      publishTarget: publishTarget,
      publishInterval: publishInterval,
      remoteExecutable: remoteExecutable
    )
  }

  private static func stripComment(_ line: String) -> String {
    var result = ""
    var inString = false
    var isEscaping = false

    for character in line {
      if character == "\"" && !isEscaping {
        inString.toggle()
      }

      if character == "#" && !inString {
        break
      }

      result.append(character)
      isEscaping = character == "\\" && !isEscaping
    }

    return result
  }

  private static func parseString(_ value: String, path: String, key: String) throws -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\"") else {
      throw SyncConfigurationError.invalidConfig(
        "invalid \(key) in \(path): expected quoted string"
      )
    }

    let data = Data("{\"value\":\(value)}".utf8)
    do {
      guard
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let string = object["value"] as? String
      else {
        throw SyncConfigurationError.invalidConfig(
          "invalid \(key) in \(path): expected quoted string"
        )
      }
      return string
    } catch {
      throw SyncConfigurationError.invalidConfig(
        "invalid \(key) in \(path): expected quoted string"
      )
    }
  }
}
