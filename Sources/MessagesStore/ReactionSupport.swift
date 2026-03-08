import Foundation

enum ChatReactionType: Sendable, Equatable, Hashable {
  case love
  case like
  case dislike
  case laugh
  case emphasis
  case question
  case custom(String)

  init?(rawValue: Int, customEmoji: String? = nil) {
    switch rawValue {
    case 2000: self = .love
    case 2001: self = .like
    case 2002: self = .dislike
    case 2003: self = .laugh
    case 2004: self = .emphasis
    case 2005: self = .question
    case 2006:
      guard let customEmoji else {
        return nil
      }
      self = .custom(customEmoji)
    default:
      return nil
    }
  }

  static func fromRemoval(_ value: Int, customEmoji: String? = nil) -> ChatReactionType? {
    ChatReactionType(rawValue: value - 1000, customEmoji: customEmoji)
  }

  static func isAdd(_ value: Int) -> Bool {
    value >= 2000 && value <= 2006
  }

  static func isRemove(_ value: Int) -> Bool {
    value >= 3000 && value <= 3006
  }

  static func isReaction(_ value: Int) -> Bool {
    isAdd(value) || isRemove(value)
  }

  var name: String {
    switch self {
    case .love: return "love"
    case .like: return "like"
    case .dislike: return "dislike"
    case .laugh: return "laugh"
    case .emphasis: return "emphasis"
    case .question: return "question"
    case .custom: return "custom"
    }
  }

  var emoji: String {
    switch self {
    case .love: return "❤️"
    case .like: return "👍"
    case .dislike: return "👎"
    case .laugh: return "😂"
    case .emphasis: return "‼️"
    case .question: return "❓"
    case .custom(let emoji): return emoji
    }
  }

  var isCustom: Bool {
    if case .custom = self {
      return true
    }
    return false
  }
}

func normalizedAssociatedGUID(_ guid: String) -> String {
  guard !guid.isEmpty else {
    return ""
  }
  guard let slash = guid.lastIndex(of: "/") else {
    return guid
  }
  let nextIndex = guid.index(after: slash)
  guard nextIndex < guid.endIndex else {
    return guid
  }
  return String(guid[nextIndex...])
}

func replyToGUID(associatedGUID: String, associatedType: Int?) -> String? {
  let normalized = normalizedAssociatedGUID(associatedGUID)
  guard !normalized.isEmpty else {
    return nil
  }
  if let associatedType, ChatReactionType.isReaction(associatedType) {
    return nil
  }
  return normalized
}

func extractCustomEmoji(from text: String) -> String? {
  guard
    let reactedRange = text.range(of: "Reacted "),
    let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
  else {
    return extractFirstEmoji(from: text)
  }

  let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
  return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
}

private func extractFirstEmoji(from text: String) -> String? {
  for character in text {
    if character.unicodeScalars.contains(where: {
      $0.properties.isEmojiPresentation || $0.properties.isEmoji
    }) {
      return String(character)
    }
  }
  return nil
}
