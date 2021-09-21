import AsyncHTTPClient
import Foundation
import IkigaJSON
import NIO
import NIOHTTP1

let dataPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + "/IzbirkomData/"

let decoder = IkigaJSONDecoder()

struct Element: Codable {
    let id: Int
    let text, href, prver: String
    let isUik, selected, loadOnDemand: Bool
    //    let children: [JSONAny]

    enum CodingKeys: String, CodingKey {
        case id, text, href, prver, isUik, selected
        case loadOnDemand = "load_on_demand"
        //        case children
    }
}

let configuration = HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(connect: .seconds(5), read:  .seconds(60)), connectionPool: HTTPClient.Configuration.ConnectionPool(idleTimeout: .seconds(60)), proxy: nil, ignoreUncleanSSLShutdown: false, decompression: .enabled(limit: .none))
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: configuration)

enum HTTPError: Error {
    case noBody
    case status(HTTPResponseStatus)
}

var dict: [Int: [Element]] = [:]

func get(id: Int) -> EventLoopFuture<[Element]> {
    httpClient.get(url: "http://www.izbirkom.ru/region/izbirkom?action=tvdTree&tvdchildren=true&vrn=100100225883172&tvd=\(id)")
        .flatMapThrowing { response in
            if response.status == .ok {
                if let buffer = response.body {
                    let string = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes, encoding: .windowsCP1251)!
                    return try decoder.decode([Element].self, from: string)
                } else {
                    throw HTTPError.noBody
                }
            } else {
                throw HTTPError.status(response.status)
            }
        }
}

func load(id: Int) {
    let future = get(id: id)
    future.whenSuccess { elements in
        DispatchQueue.main.async {
            dict[id] = elements
            for element in elements where element.loadOnDemand {
                load(id: element.id)
            }
        }
    }
    future.whenFailure {
        print("error", id, $0)
    }
}

let rootId = 100100225883177

let encoder = IkigaJSONEncoder()
let jsonURL = URL(fileURLWithPath: dataPath + "root.json")

func checkAndSave() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: {
        print(dict.count)
        do {
            try encoder.encode(dict).write(to: jsonURL)
        } catch {
            print(error)
        }
        checkAndSave()
    })
}

load(id: rootId)
checkAndSave()
