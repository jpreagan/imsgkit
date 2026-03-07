import Foundation
import ImsgProtocol

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
        try serve()
      }
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      Foundation.exit(1)
    }
  }
}

private func parseOptions(arguments: [String]) throws -> Options {
  var showVersion = false
  var index = 0

  while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "version", "--version":
      showVersion = true
      index += 1
    case "--help", "-h":
      throw ImsgdError.invalidArguments(
        """
        usage:
          imsgd
          imsgd version
        """)
    default:
      throw ImsgdError.invalidArguments("unknown argument: \(argument)")
    }
  }

  return Options(showVersion: showVersion)
}

private func serve() throws {
  let input = FileHandle.standardInput
  let output = FileHandle.standardOutput

  while let frame = try FrameIO.readFrame(from: input) {
    let responseEnvelope = try handleFrame(frame)
    let payload = try JSONSerialization.data(withJSONObject: responseEnvelope, options: [])
    try FrameIO.writeFrame(to: output, payload: payload)
  }
}

private func handleFrame(_ frame: Data) throws -> [String: Any] {
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

  switch method {
  case ProtocolConstants.handshakeMethod:
    return makeSuccessEnvelope(id: id, result: handleHandshake())
  default:
    return makeErrorEnvelope(id: id, code: "not_implemented", message: "method not implemented")
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
    ],
  ]
}

private func makeSuccessEnvelope(id: String, result: [String: Any]) -> [String: Any] {
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
