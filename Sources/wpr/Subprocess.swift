import Foundation

enum Subprocess {
  struct Result { let status: Int32; let stdout: String; let stderr: String }

  static func run(executable: String, arguments: [String], cwd: URL? = nil) throws -> Result {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    if let cwd { p.currentDirectoryURL = cwd }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    try p.run()
    // drain both pipes before waiting so a chatty child can't fill a buffer and deadlock
    var errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      errData = errPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return Result(status: p.terminationStatus,
                  stdout: String(decoding: outData, as: UTF8.self),
                  stderr: String(decoding: errData, as: UTF8.self))
  }
}
