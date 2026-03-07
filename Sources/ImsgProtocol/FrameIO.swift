import Foundation

public enum FrameIOError: Error, Equatable {
  case invalidEmptyFrame
  case frameTooLarge(Int)
  case unexpectedEOF
}

public enum FrameIO {
  public static let maxFrameSize = 16 << 20

  public static func writeFrame(to handle: FileHandle, payload: Data) throws {
    guard !payload.isEmpty else {
      throw FrameIOError.invalidEmptyFrame
    }
    guard payload.count <= maxFrameSize else {
      throw FrameIOError.frameTooLarge(payload.count)
    }

    var size = UInt32(payload.count).bigEndian
    let header = Data(bytes: &size, count: MemoryLayout<UInt32>.size)
    try handle.write(contentsOf: header)
    try handle.write(contentsOf: payload)
  }

  public static func readFrame(from handle: FileHandle) throws -> Data? {
    guard let header = try readExactly(from: handle, count: MemoryLayout<UInt32>.size) else {
      return nil
    }

    let size = header.withUnsafeBytes { rawBuffer -> Int in
      Int(UInt32(bigEndian: rawBuffer.load(as: UInt32.self)))
    }

    guard size > 0 else {
      throw FrameIOError.invalidEmptyFrame
    }
    guard size <= maxFrameSize else {
      throw FrameIOError.frameTooLarge(size)
    }

    guard let payload = try readExactly(from: handle, count: size) else {
      throw FrameIOError.unexpectedEOF
    }

    return payload
  }

  private static func readExactly(from handle: FileHandle, count: Int) throws -> Data? {
    var buffer = Data()
    buffer.reserveCapacity(count)

    while buffer.count < count {
      guard let chunk = try handle.read(upToCount: count - buffer.count) else {
        if buffer.isEmpty {
          return nil
        }
        throw FrameIOError.unexpectedEOF
      }

      if chunk.isEmpty {
        if buffer.isEmpty {
          return nil
        }
        throw FrameIOError.unexpectedEOF
      }

      buffer.append(chunk)
    }

    return buffer
  }
}
