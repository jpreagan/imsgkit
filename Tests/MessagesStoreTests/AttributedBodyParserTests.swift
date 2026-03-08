import Foundation
import Testing

@testable import MessagesStore

@Test
func attributedBodyParserExtractsInlineUTF8Text() {
  let data = Data([0x01, 0x2b] + Array("fallback text".utf8) + [0x86, 0x84])
  #expect(AttributedBodyParser.parse(data) == "fallback text")
}

@Test
func attributedBodyParserExtractsLengthPrefixedUTF8Text() {
  let text = "length prefixed"
  let data = Data([0x01, 0x2b, UInt8(text.utf8.count)] + Array(text.utf8) + [0x86, 0x84])
  #expect(AttributedBodyParser.parse(data) == text)
}
