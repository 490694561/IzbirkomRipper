import AsyncHTTPClient
import Foundation
import IkigaJSON
import NIO
import NIOHTTP1
import Vision

let dataPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + "/IzbirkomData/"

let lowercaseHexDigits = Array("0123456789abcdef".utf16)
public extension Collection where Element == UInt8 {
    func hexEncodedString() -> String {
        var chars: [UInt16] = []
        chars.reserveCapacity(2 * count)
        for byte in self {
            chars.append(lowercaseHexDigits[Int(byte / 16)])
            chars.append(lowercaseHexDigits[Int(byte % 16)])
        }
        return String(utf16CodeUnits: chars, count: chars.count)
    }
}

func randomFingerprint() -> String {
    var bytes = [UInt8]()
    for _ in 0..<16 {
        bytes.append(UInt8.random(in: 0...255))
    }
    return bytes.hexEncodedString()
}

let configuration = HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(connect: .seconds(5), read:  .seconds(60)), connectionPool: HTTPClient.Configuration.ConnectionPool(idleTimeout: .seconds(60)), proxy: nil, ignoreUncleanSSLShutdown: false, decompression: .enabled(limit: .none))
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: configuration)

let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
threadPool.start()
let fileIO = NonBlockingFileIO(threadPool: threadPool)

func htmlPath(id: Int) -> String {
    "\(dataPath)html/\(id).html"
}

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let eventLoop = eventLoopGroup.next()

enum CaptchaError: Error {
    case emptyValue
    case wrongLength
    case failedCheck
}

let digits = CharacterSet.decimalDigits
extension Data {
    func solveCaptcha(handler:@escaping (String?)->Void) {
        let requestHandler = VNImageRequestHandler(data: self, options: [:])
        let request = VNRecognizeTextRequest { (request, error) in
            let candidates = (request.results as? [VNRecognizedTextObservation])?.first?.topCandidates(10).map { String($0.string.lowercased().replacingOccurrences(of: " ", with: "o").unicodeScalars.filter { digits.contains($0) }) }
            handler(candidates?.first(where: { $0.count == 5 }))
        }
        try! requestHandler.perform([request])
    }
}

extension HTTPHeaders {
    var responseCookies: String {
        self["set-cookie"].map { $0.components(separatedBy: ";")[0] }.joined(separator: "; ")
    }
}

struct Session {
    let cookie: String
    let fingerprint: String
}

enum HTTPError: Error {
    case noBody
    case status(HTTPResponseStatus)
    case needCaptcha
}

func solveCaptcha(session: Session) -> EventLoopFuture<String> {
    let promise = eventLoop.makePromise(of: String.self)

    let imageRequest = try! HTTPClient.Request(url: "http://www.vybory.izbirkom.ru/captcha-service/image/", method: .GET, headers: [
        "Cookie": "izbFP=\(session.fingerprint); \(session.cookie)",
        "Accept": "*/*",
        "Host": "www.vybory.izbirkom.ru",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
        "Accept-Language": "ru",
        "Accept-Encoding": "gzip, deflate",
        "Referer": "http://www.vybory.izbirkom.ru/",
        "Connection": "keep-alive"
    ], body: nil)

    let future = httpClient.execute(request: imageRequest, deadline: .now() + .seconds(5))
        .flatMapThrowing { response -> (ByteBuffer, HTTPHeaders) in
            if response.status == .ok {
                if let buffer = response.body {
                    return (buffer, response.headers)
                } else {
                    throw HTTPError.noBody
                }
            } else {
                throw HTTPError.status(response.status)
            }
        }

    future.whenFailure {
        print($0)
        solveCaptcha(session: session).cascade(to: promise)
    }
    future.whenSuccess { buffer, headers in
        let captchaCookie = headers.responseCookies
        buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes)!.solveCaptcha(handler: { result in
            guard let result = result else {
                print(CaptchaError.emptyValue)
                solveCaptcha(session: session).cascade(to: promise)
                return
            }

            let request = try! HTTPClient.Request(url: "http://www.vybory.izbirkom.ru/captcha-service/validate/captcha/value/\(result)", method: .GET, headers: [
                "Cookie": "\(captchaCookie); izbFP=\(session.fingerprint); \(session.cookie)",
                "Accept": "*/*",
                "Host": "www.vybory.izbirkom.ru",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
                "Accept-Language": "ru",
                "Accept-Encoding": "gzip, deflate",
                "Referer": "http://www.vybory.izbirkom.ru/",
                "Connection": "keep-alive"
            ], body: nil)

            let checkFuture = httpClient.execute(request: request, deadline: .now() + .seconds(5))
                .flatMapThrowing { response -> String in
                    if response.status == .ok {
                        return captchaCookie
                    } else {
                        throw HTTPError.status(response.status)
                    }
                }
            checkFuture.cascadeSuccess(to: promise)
            checkFuture.whenFailure {
                print($0)
                solveCaptcha(session: session).cascade(to: promise)
            }
        })
    }
    return promise.futureResult
}

func createSession() -> EventLoopFuture<Session> {
    let request = try! HTTPClient.Request(url: "http://www.izbirkom.ru/", method: .HEAD, headers: [
        "Accept": "*/*",
        "Origin": "http://www.izbirkom.ru",
        "Host": "www.izbirkom.ru",
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
        "Accept-Language": "ru",
        "Accept-Encoding": "gzip, deflate",
        "Connection": "keep-alive"
    ], body: nil)

    return httpClient.execute(request: request, deadline: .now() + .seconds(5))
        .flatMapThrowing { response -> Session in
            if response.status == .ok {
                return Session(cookie: response.headers.responseCookies, fingerprint: randomFingerprint())
            } else {
                throw HTTPError.status(response.status)
            }
        }
}

func downloadHTML(id: Int, href: String, session: Session, captchaCookie: String?) -> EventLoopFuture<String?> {
    let originalCaptchaCookie = captchaCookie
    let href = href + "&type=242&report_mode=null"

//    func makeSendRequest(captchaCookie: String?) -> HTTPClient.Request {
//        let body = #"{"query_type":"action","time_on_page":0,"is_scroll":false,"is_mouse":true,"fingerprint":"# + session.fingerprint + #","is_open_local_storage":true,"is_open_cookie":true,"webdriver":false,"href":"http://www.izbirkom.ru/"# + href + "\"}"
//        var cookie = "izbFP=\(session.fingerprint); \(session.cookie)"
//        if let captchaCookie = captchaCookie {
//            cookie = "\(captchaCookie); \(cookie)"
//        }
//
//        return try! HTTPClient.Request(url: "http://www.izbirkom.ru/send", method: .POST, headers: [
//            "Cookie": cookie,
//            "Accept": "*/*",
//            "Content-Type": "application/json;charset=UTF-8",
//            "Origin": "http://www.izbirkom.ru",
//            "Content-Length": "\(body.utf8.count)",
//            "Host": "www.izbirkom.ru",
//            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
//            "Referer": "http://www.izbirkom.ru/\(href)",
//            "Accept-Language": "ru",
//            "Accept-Encoding": "gzip, deflate",
//            "Connection": "keep-alive"
//        ], body: .string(body))
//    }

    func makeRequest(captchaCookie: String?) -> HTTPClient.Request {
        var cookie = "izbFP=\(session.fingerprint); \(session.cookie)"
        if let captchaCookie = captchaCookie {
            cookie = "\(captchaCookie); \(cookie)"
        }

        return try! HTTPClient.Request(url: "http://www.izbirkom.ru/" + href, method: .GET, headers: [
            "Cookie": cookie,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Upgrade-Insecure-Requests": "1",
            "Host": "www.izbirkom.ru",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.2 Safari/605.1.15",
            "Accept-Language": "ru",
            "Accept-Encoding": "gzip, deflate",
            "Connection": "keep-alive"
        ], body: nil)
    }

    func getPage(captchaCookie: String?) -> EventLoopFuture<ByteBuffer> {
        return httpClient.execute(request: makeRequest(captchaCookie: captchaCookie), deadline: .now() + .seconds(5))
            .flatMapThrowing { response -> ByteBuffer in
                if response.status == .ok {
                    if let buffer = response.body {
                        if buffer.readableBytes == 303481 {
                            throw HTTPError.needCaptcha
                        }
                        return buffer
                    } else {
                        throw HTTPError.noBody
                    }
                } else {
                    throw HTTPError.status(response.status)
                }
            }
    }

    return getPage(captchaCookie: captchaCookie).map { ($0, Optional<String>.none) }
        .flatMapError { error -> EventLoopFuture<(ByteBuffer, String?)> in
            if let error = error as? HTTPError {
                switch error {
                case .needCaptcha:
                    return solveCaptcha(session: session).flatMap { captchaCookie in
                        return getPage(captchaCookie: captchaCookie).map { ($0, captchaCookie) }
                    }
                default:
                    return eventLoop.makeFailedFuture(error)
                }
            } else {
                return eventLoop.makeFailedFuture(error)
            }
        }
        .flatMap { buffer, captchaCookie in
            do {
                let fileHandle = try NIOFileHandle(path: htmlPath(id: id), mode: .write, flags: .allowFileCreation(posixMode: 0o600))
                return fileIO.write(fileHandle: fileHandle, buffer: buffer, eventLoop: eventLoop).flatMapThrowing { _ in
                    try fileHandle.close()
                    return captchaCookie
                }
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
        .map { captchaCookie in
            captchaCookie ?? originalCaptchaCookie
        }
//        .flatMap { captchaCookie in
//            httpClient.execute(request: makeSendRequest(captchaCookie: captchaCookie ?? originalCaptchaCookie), deadline: .now() + .seconds(5)).map { _ in captchaCookie ?? originalCaptchaCookie }
//        }
}

let simultaneousSessions = 10
let sessions = try! EventLoopFuture.reduce([Session](), (0..<simultaneousSessions).map { _ in createSession() }, on: eventLoop, { $0 + CollectionOfOne($1) }).wait()

struct SimpleElement: Codable {
    let id: Int
    let href: String
}

let fileManager = FileManager.default

let flatElements: [SimpleElement] = try! String(contentsOf: URL(fileURLWithPath: dataPath + "urls.csv"))
    .components(separatedBy: "\n").map {
        let comps = $0.components(separatedBy: ";")
        return SimpleElement(id: Int(comps[0])!, href: comps[1])
    }

print("count: ", flatElements.count)
var iterator = flatElements.makeIterator()

func downloadNextHtml(session: Session, captchaCookie: String? = nil) {
    DispatchQueue.main.async {
        guard let element = iterator.next() else { return }

        if !fileManager.fileExists(atPath: htmlPath(id: element.id)) {
            let future = downloadHTML(id: element.id, href: element.href, session: session, captchaCookie: captchaCookie)
            future.whenFailure {
                print("error", element.id, $0)
                downloadNextHtml(session: session, captchaCookie: captchaCookie)
            }
            future.whenSuccess { captchaCookie in
                downloadNextHtml(session: session, captchaCookie: captchaCookie)
            }
        } else {
            downloadNextHtml(session: session, captchaCookie: captchaCookie)
        }
    }
}
for session in sessions {
    downloadNextHtml(session: session)
}


RunLoop.main.run()
