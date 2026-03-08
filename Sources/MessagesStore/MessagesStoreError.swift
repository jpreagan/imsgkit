enum MessagesStoreError: Error, CustomStringConvertible {
  case invalidLimit(Int)
  case invalidChatID(Int64)
  case invalidBeforeMessageID(Int64)
  case openDatabase(String)
  case prepareStatement(String)
  case stepStatement(String)

  var description: String {
    switch self {
    case .invalidLimit:
      return "limit must be zero or greater"
    case .invalidChatID:
      return "chat_id must be greater than zero"
    case .invalidBeforeMessageID:
      return "before must be greater than zero"
    case .openDatabase(let message),
      .prepareStatement(let message),
      .stepStatement(let message):
      return message
    }
  }
}
