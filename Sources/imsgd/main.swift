import Foundation

private let version = "dev"

enum ImsgdError: Error, CustomStringConvertible {
  case invalidArguments(String)

  var description: String {
    switch self {
    case .invalidArguments(let message):
      return message
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
        throw ImsgdError.invalidArguments(
          """
          usage:
            imsgd version
          """
        )
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
          imsgd version
        """)
    default:
      throw ImsgdError.invalidArguments("unknown argument: \(argument)")
    }
  }

  return Options(showVersion: showVersion)
}
