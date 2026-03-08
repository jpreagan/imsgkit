import Foundation

enum AttributedBodyParser {
  static func parse(_ data: Data) -> String {
    guard !data.isEmpty else {
      return ""
    }

    let bytes = [UInt8](data)
    let startMarker = [UInt8(0x01), UInt8(0x2b)]
    let endMarker = [UInt8(0x86), UInt8(0x84)]
    var bestCandidate = ""

    var index = 0
    while index + 1 < bytes.count {
      guard bytes[index] == startMarker[0], bytes[index + 1] == startMarker[1] else {
        index += 1
        continue
      }

      let contentStart = index + 2
      if let contentEnd = findSequence(endMarker, in: bytes, from: contentStart) {
        var segment = Array(bytes[contentStart..<contentEnd])
        if segment.count > 1, Int(segment[0]) == segment.count - 1 {
          segment.removeFirst()
        }

        let candidate = String(decoding: segment, as: UTF8.self)
          .trimmingLeadingControlCharacters()
        if candidate.count > bestCandidate.count {
          bestCandidate = candidate
        }
      }

      index += 1
    }

    if !bestCandidate.isEmpty {
      return bestCandidate
    }

    return String(decoding: bytes, as: UTF8.self).trimmingLeadingControlCharacters()
  }

  private static func findSequence(_ needle: [UInt8], in haystack: [UInt8], from start: Int)
    -> Int?
  {
    guard !needle.isEmpty else {
      return nil
    }
    guard start >= 0, start < haystack.count else {
      return nil
    }

    let limit = haystack.count - needle.count
    guard limit >= start else {
      return nil
    }

    var index = start
    while index <= limit {
      var matched = true
      for offset in 0..<needle.count {
        if haystack[index + offset] != needle[offset] {
          matched = false
          break
        }
      }

      if matched {
        return index
      }

      index += 1
    }

    return nil
  }
}

extension String {
  fileprivate func trimmingLeadingControlCharacters() -> String {
    var scalars = unicodeScalars
    while let first = scalars.first,
      CharacterSet.controlCharacters.contains(first) || first == "\n" || first == "\r"
    {
      scalars.removeFirst()
    }

    return String(String.UnicodeScalarView(scalars))
  }
}
