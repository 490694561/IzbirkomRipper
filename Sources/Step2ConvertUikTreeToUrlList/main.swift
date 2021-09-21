import Foundation
import IkigaJSON

let dataPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path + "/IzbirkomData/"
let jsonURL = URL(fileURLWithPath: dataPath + "root.json")
let jsonData = try! Data(contentsOf: jsonURL)

struct SimpleElement: Codable {
    let id: Int
    let href: String
}

let decoder = IkigaJSONDecoder()
let list = try decoder.decode([String: [SimpleElement]].self, from: jsonData)

var lines = [String]()
for elements in list.values {
    lines.append(contentsOf: elements.map { "\($0.id);\($0.href)" })
}
try lines.joined(separator: "\n").write(toFile: dataPath + "urls.csv", atomically: true, encoding: .utf8)
print("done")
