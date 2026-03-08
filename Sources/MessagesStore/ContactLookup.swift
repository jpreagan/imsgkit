public struct ResolvedChatContact: Sendable, Equatable {
  public let name: String
  public let label: String

  public init(name: String, label: String) {
    self.name = name
    self.label = label
  }
}

public typealias ContactLookup = @Sendable (String) -> ResolvedChatContact?
