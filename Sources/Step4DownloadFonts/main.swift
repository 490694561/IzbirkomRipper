import AsyncHTTPClient
import Foundation
import NIO
import NIOHTTP1

let dataPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + "/IzbirkomData/"
let htmlPath = dataPath + "html/"

extension String {
    func matches(for regex: String) -> [String] {
        do {
            let regex = try NSRegularExpression(pattern: regex)
            let results = regex.matches(in: self, range: NSRange(self.startIndex..., in: self))
            return results.map {
                String(self[Range($0.range, in: self)!])
            }
        } catch let error {
            print("invalid regex: \(error.localizedDescription)")
            return []
        }
    }
}

let enumerator = FileManager.default.enumerator(atPath: htmlPath)!

func getNextFont() throws -> String? {
    guard let name = enumerator.nextObject() as? String else {
        return nil
    }

    guard name.hasSuffix(".html") else {
        return try getNextFont()
    }

    let htmlFilePath = htmlPath + name
    let htmlData = try Data(contentsOf: URL(fileURLWithPath: htmlFilePath))
    let htmlString = String(data: htmlData, encoding: .windowsCP1251) ?? String(data: htmlData, encoding: .unicode)!
    let matches = htmlString.matches(for: #"fonts1/[^\.]+\.otf"#)
    assert(matches.count <= 1)
    if matches.isEmpty {
        print(htmlPath + name)
        return try getNextFont()
    }
    return matches.first
}

let fileManager = FileManager.default

let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
threadPool.start()
let fileIO = NonBlockingFileIO(threadPool: threadPool)

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let eventLoop = eventLoopGroup.next()

let configuration = HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(connect: .seconds(5), read:  .seconds(60)), connectionPool: HTTPClient.Configuration.ConnectionPool(idleTimeout: .seconds(60)), proxy: nil, ignoreUncleanSSLShutdown: false, decompression: .enabled(limit: .none))
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: configuration)


enum HTTPError: Error {
    case noBody
    case status(HTTPResponseStatus)
}

func downloadFont(font: String) -> EventLoopFuture<Void> {
    httpClient.get(url: "http://www.izbirkom.ru/" + font, deadline: .now() + .seconds(5))
        .flatMapThrowing { response -> ByteBuffer in
            if response.status == .ok {
                if let buffer = response.body {
                    return buffer
                } else {
                    throw HTTPError.noBody
                }
            } else {
                throw HTTPError.status(response.status)
            }
        }
        .flatMap { buffer in
            do {
                let fileHandle = try NIOFileHandle(path: htmlPath + font, mode: .write, flags: .allowFileCreation(posixMode: 0o600))
                return fileIO.write(fileHandle: fileHandle, buffer: buffer, eventLoop: eventLoop).flatMapThrowing { _ in
                    try fileHandle.close()
                    return ()
                }
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
}

func downloadNextFont() {
    DispatchQueue.main.async {
        guard let font = try! getNextFont() else {
            print("done")
            return
        }

        if !fileManager.fileExists(atPath: htmlPath + font) {
            let future = downloadFont(font: font)
            future.whenFailure {
                print("error", font, $0)
                downloadNextFont()
            }
            future.whenSuccess {
                downloadNextFont()
            }
        } else {
            downloadNextFont()
        }
    }
}

downloadNextFont()

RunLoop.main.run()
