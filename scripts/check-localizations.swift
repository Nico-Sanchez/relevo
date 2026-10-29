import Foundation

let stringsData = URL(fileURLWithPath: CommandLine.arguments[1])
let localizations = URL(fileURLWithPath: CommandLine.arguments[2])
let files = FileManager.default

var keys = Set<String>()
for file in try files.contentsOfDirectory(at: stringsData, includingPropertiesForKeys: nil) where file.pathExtension == "stringsdata" {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let tables = object?["tables"] as? [String: [[String: Any]]] ?? [:]
    keys.formUnion((tables["Localizable"] ?? []).compactMap { $0["key"] as? String })
}

var complete = true
for folder in try files.contentsOfDirectory(at: localizations, includingPropertiesForKeys: nil)
where folder.pathExtension == "lproj" && folder.lastPathComponent != "en.lproj" {
    let table = NSDictionary(contentsOf: folder.appending(path: "Localizable.strings")) as? [String: String] ?? [:]
    let language = folder.deletingPathExtension().lastPathComponent
    for key in keys.subtracting(table.keys).sorted() {
        print("\(language): missing \"\(key)\"")
        complete = false
    }
    for key in Set(table.keys).subtracting(keys).sorted() {
        print("\(language): unused \"\(key)\"")
        complete = false
    }
}
print("\(keys.count) keys")
exit(complete ? 0 : 1)
