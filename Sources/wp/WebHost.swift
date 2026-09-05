import Foundation

enum WebHost {
  static func render(module: Module, width: Int, height: Int, seed: UInt32, params: [String], to out: URL, verbose: Bool) throws {
    let root = try Root.url()
    let rootPath = root.standardizedFileURL.path
    let entry = module.entryURL.standardizedFileURL.path
    guard entry.hasPrefix(rootPath + "/") else { throw WPError("web module must live inside the repo: \(entry)") }
    let page = String(entry.dropFirst(rootPath.count + 1))

    var args = [
      root.appendingPathComponent("hosts/web/host.ts").path,
      "--root", rootPath, "--page", page,
      "--width", "\(width)", "--height", "\(height)", "--seed", "\(seed)",
      "--out", out.path,
    ]
    for p in params { args += ["--param", p] }

    let log = try Subprocess.run(executable: try bunPath(), arguments: args)
    if verbose || log.status != 0 {
      FileHandle.standardError.write(log.stderr.data(using: .utf8)!)
    }
    if log.status != 0 { throw WPError("web host exited \(log.status)") }
  }

  static func bunPath() throws -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for c in ["\(home)/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"] {
      if FileManager.default.isExecutableFile(atPath: c) { return c }
    }
    throw WPError("bun not found (looked in ~/.bun/bin, /opt/homebrew/bin, /usr/local/bin)")
  }
}

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
