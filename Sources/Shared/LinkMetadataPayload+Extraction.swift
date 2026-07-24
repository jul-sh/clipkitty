import ClipKittyRust
import Foundation

public extension LinkMetadataPayload {
    var title: String? {
        switch self {
        case let .titleOnly(title, _), let .titleAndImage(title, _, _):
            return title
        case .imageOnly:
            return nil
        }
    }

    var description: String? {
        switch self {
        case let .titleOnly(_, description),
             let .imageOnly(_, description),
             let .titleAndImage(_, _, description):
            return description
        }
    }

    var imageData: Data? {
        switch self {
        case let .imageOnly(data, _), let .titleAndImage(_, data, _):
            return data
        case .titleOnly:
            return nil
        }
    }
}
