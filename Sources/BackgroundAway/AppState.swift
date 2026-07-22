import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum PreviewMode: String, CaseIterable, Identifiable {
        case result
        case original
        case comparison

        var id: Self { self }

        var title: String {
            switch self {
            case .result: "Результат"
            case .original: "Оригинал"
            case .comparison: "Рядом"
            }
        }
    }

    enum PreviewBackground: String, CaseIterable, Identifiable {
        case checkerboard
        case white
        case black

        var id: Self { self }

        var title: String {
            switch self {
            case .checkerboard: "Прозрачность"
            case .white: "Белый"
            case .black: "Чёрный"
            }
        }
    }

    @Published private(set) var originalImage: NSImage?
    @Published private(set) var resultImage: NSImage?
    @Published private(set) var resultPreviewImage: NSImage?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?
    @Published var previewMode: PreviewMode = .result
    @Published var previewBackground: PreviewBackground = .checkerboard

    private var processingTask: Task<Void, Never>?
    private var operationID = UUID()

    var sourceName: String {
        sourceURL?.lastPathComponent ?? "Изображение из буфера"
    }

    var sourceDetails: String? {
        guard let cgImage = originalImage?.pixelCGImage else { return nil }
        return "\(cgImage.width) × \(cgImage.height) px"
    }

    func openImagePicker() {
        let panel = NSOpenPanel()
        panel.title = "Выберите изображение"
        panel.prompt = "Открыть"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(from: url)
    }

    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url), image.pixelCGImage != nil else {
            errorMessage = "Не удалось открыть это изображение. Попробуйте PNG, JPEG, HEIC, WebP или TIFF."
            return
        }

        sourceURL = url
        originalImage = image
        resultImage = nil
        resultPreviewImage = nil
        previewMode = .result
        errorMessage = nil
        removeBackground()
    }

    func loadImage(_ image: NSImage) {
        guard image.pixelCGImage != nil else {
            errorMessage = "В буфере обмена нет подходящего изображения."
            return
        }

        sourceURL = nil
        originalImage = image
        resultImage = nil
        resultPreviewImage = nil
        previewMode = .result
        errorMessage = nil
        removeBackground()
    }

    func pasteImage() {
        let pasteboard = NSPasteboard.general

        if let url = NSURL(from: pasteboard) as URL?,
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            loadImage(from: url)
            return
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            errorMessage = "Скопируйте изображение или файл изображения и попробуйте снова."
            return
        }
        loadImage(image)
    }

    func removeBackground() {
        guard let source = originalImage?.pixelCGImage else { return }

        processingTask?.cancel()
        let currentOperationID = UUID()
        operationID = currentOperationID
        isProcessing = true
        resultImage = nil
        resultPreviewImage = nil
        errorMessage = nil

        processingTask = Task {
            do {
                let images = try await Task.detached(priority: .userInitiated) {
                    let output = try BackgroundRemovalService.removeBackground(from: source)
                    let preview = BackgroundRemovalService.centeredPreviewCrop(from: output)
                    return (output, preview)
                }.value

                guard !Task.isCancelled, operationID == currentOperationID else { return }
                resultImage = NSImage(
                    cgImage: images.0,
                    size: NSSize(width: images.0.width, height: images.0.height)
                )
                resultPreviewImage = NSImage(
                    cgImage: images.1,
                    size: NSSize(width: images.1.width, height: images.1.height)
                )
                isProcessing = false
            } catch is CancellationError {
                if operationID == currentOperationID {
                    isProcessing = false
                }
            } catch {
                guard operationID == currentOperationID else { return }
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func exportResult() {
        guard let cgImage = resultImage?.pixelCGImage else { return }

        let panel = NSSavePanel()
        panel.title = "Сохранить изображение без фона"
        panel.prompt = "Экспортировать"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedExportName

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try Self.pngData(from: cgImage).write(to: destination, options: .atomic)
        } catch {
            errorMessage = "Не удалось сохранить PNG: \(error.localizedDescription)"
        }
    }

    func copyResult() {
        guard let resultImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([resultImage])
    }

    func clear() {
        processingTask?.cancel()
        operationID = UUID()
        originalImage = nil
        resultImage = nil
        resultPreviewImage = nil
        sourceURL = nil
        isProcessing = false
        errorMessage = nil
    }

    private var suggestedExportName: String {
        let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? "image"
        return "\(baseName)-без-фона.png"
    }

    private static func pngData(from cgImage: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw BackgroundRemovalError.cannotEncodePNG
        }
        return data
    }
}

extension NSImage {
    var pixelCGImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
