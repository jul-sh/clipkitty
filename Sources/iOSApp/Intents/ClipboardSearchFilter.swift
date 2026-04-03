import AppIntents

enum ClipboardSearchFilter: String, AppEnum {
    case all
    case bookmarks
    case text
    case images
    case links
    case colors

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Clipboard Filter"
    }

    static var caseDisplayRepresentations: [ClipboardSearchFilter: DisplayRepresentation] {
        [
            .all: "All Items",
            .bookmarks: "Bookmarks",
            .text: "Text",
            .images: "Images",
            .links: "Links",
            .colors: "Colors",
        ]
    }
}
