import SwiftUI
import UniformTypeIdentifiers

/// A YAML file of presets, for the save and open panels.
struct PresetsDocument: FileDocument {
    static let readableContentTypes = [PresetCodec.contentType]

    var text: String

    init(text: String) {
        self.text = text
    }

    /// The text of a file's contents. A file that is not a regular file, or is larger than a
    /// presets file can be, is refused.
    init(contents: Data?) throws {
        guard let contents, contents.count <= PresetCodec.maximumBytes else {
            throw PresetCodec.Failure.tooLarge
        }
        text = String(decoding: contents, as: UTF8.self)
    }

    /// What is written to a file.
    var contents: Data { Data(text.utf8) }

    // coverage:off Only SwiftUI can make a ReadConfiguration or a WriteConfiguration.
    init(configuration: ReadConfiguration) throws {
        try self.init(contents: configuration.file.regularFileContents)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: contents)
    }
    // coverage:on
}

/// The state of importing and exporting, which the window turns into panels and an alert.
struct PresetTransfer {
    var isImporting = false
    var isExporting = false
    var export: PresetsDocument?
    var exportName = "AirFlow Presets"
    /// What went wrong, for an alert.
    var message: String?
}
