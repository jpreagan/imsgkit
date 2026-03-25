import Foundation

public enum ProtocolConstants {
  public static let protocolVersion = "0.2.0"
  public static let serverName = "imsgd"

  public static let requestKind = "request"
  public static let responseKind = "response"
  public static let eventKind = "event"

  public static let handshakeMethod = "Handshake"
  public static let healthMethod = "Health"
  public static let listChatsMethod = "ListChats"
  public static let getHistoryMethod = "GetHistory"
  public static let watchMethod = "Watch"
}
