import SwiftUI
import UniformTypeIdentifiers

/// A YAML file of presets, for the save and open panels.
struct PresetsDocument: FileDocument {
    static let readableContentTypes = [PresetCodec.contentType]

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= PresetCodec.maximumBytes else {
            throw PresetCodec.Failure.tooLarge
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
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
