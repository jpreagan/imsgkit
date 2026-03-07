import Foundation
import ImsgProtocol
import Testing

@Test
func frameRoundTrip() throws {
  let pipe = Pipe()
  let payload = Data(#"{"kind":"request"}"#.utf8)

  try FrameIO.writeFrame(to: pipe.fileHandleForWriting, payload: payload)
  try pipe.fileHandleForWriting.close()

  let decoded = try #require(try FrameIO.readFrame(from: pipe.fileHandleForReading))
  #expect(decoded == payload)
}
