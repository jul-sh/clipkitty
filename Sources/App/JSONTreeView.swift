import SwiftUI
import Foundation

struct JSONTreeView: View {
    let jsonString: String

    private var rootNode: JSONNode? {
        JSONNode.from(jsonString: jsonString)
    }

    var body: some View {
        if let rootNode {
            ScrollView(.vertical, showsIndicators: true) {
                OutlineGroup([rootNode], children: \.children) { node in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(node.name)
                            .font(.custom(FontManager.mono, size: 14))
                        if let value = node.valueDescription {
                            Text(value)
                                .font(.custom(FontManager.mono, size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .modifier(IBeamCursorOnHover())
                }
                .padding(16)
            }
        } else {
            Text("Invalid JSON")
                .font(.custom(FontManager.mono, size: 14))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct JSONNode: Identifiable {
    let id = UUID()
    let name: String
    let valueDescription: String?
    let children: [JSONNode]?

    static func from(jsonString: String) -> JSONNode? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return buildNode(name: "JSON", value: value)
    }

    private static func buildNode(name: String, value: Any) -> JSONNode {
        if let dict = value as? [String: Any] {
            let children = dict.keys.sorted().map { key in
                buildNode(name: key, value: dict[key] as Any)
            }
            return JSONNode(name: name, valueDescription: "{\(children.count)}", children: children)
        }

        if let array = value as? [Any] {
            let children = array.enumerated().map { index, element in
                buildNode(name: "[\(index)]", value: element)
            }
            return JSONNode(name: name, valueDescription: "[\(children.count)]", children: children)
        }

        if value is NSNull {
            return JSONNode(name: name, valueDescription: "null", children: nil)
        }

        if let stringValue = value as? String {
            return JSONNode(name: name, valueDescription: "\"\(stringValue)\"", children: nil)
        }

        if let numberValue = value as? NSNumber {
            let description: String
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                description = numberValue.boolValue ? "true" : "false"
            } else {
                description = numberValue.stringValue
            }
            return JSONNode(name: name, valueDescription: description, children: nil)
        }

        return JSONNode(name: name, valueDescription: String(describing: value), children: nil)
    }
}
