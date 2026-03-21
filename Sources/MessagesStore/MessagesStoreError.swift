enum MessagesStoreError: Error, CustomStringConvertible {
  case invalidLimit(Int)
  case invalidChatID(Int64)
  case unsupportedSchema(String)
  case openDatabase(String)
  case prepareStatement(String)
  case executeStatement(String)
  case stepStatement(String)

  var description: String {
    switch self {
    case .invalidLimit:
      return "limit must be zero or greater"
    case .invalidChatID:
      return "chat_id must be greater than zero"
    case .unsupportedSchema(let message):
      return message
    case .openDatabase(let message),
      .prepareStatement(let message),
      .executeStatement(let message),
      .stepStatement(let message):
      return message
    }
  }
}
