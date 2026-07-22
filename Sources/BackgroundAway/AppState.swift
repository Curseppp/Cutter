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

    enum MaskTool: String, CaseIterable, Identifiable {
        case pan
        case erase
        case restore

        var id: Self { self }

        var title: String {
            switch self {
            case .pan: "Двигать"
            case .erase: "Удалить"
            case .restore: "Вернуть"
            }
        }

        var symbolName: String {
            switch self {
            case .pan: "hand.draw"
            case .erase: "eraser"
            case .restore: "paintbrush"
            }
        }
    }

    @Published private(set) var originalImage: NSImage?
    @Published private(set) var resultImage: NSImage?
    @Published private(set) var resultPreviewImage: NSImage?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isProcessing = false
    @Published private(set) var hasManualMaskEdits = false
    @Published var errorMessage: String?
    @Published var previewMode: PreviewMode = .result {
        didSet {
            if previewMode != .result, maskTool != .pan {
                maskTool = .pan
            }
        }
    }
    @Published var previewBackground: PreviewBackground = .checkerboard
    @Published var maskTool: MaskTool = .pan {
        didSet {
            if maskTool != .pan {
                previewMode = .result
            }
        }
    }
    @Published var brushDiameter: Double = 56

    private var processingTask: Task<Void, Never>?
    private var operationID = UUID()
    private var automaticResultImage: CGImage?

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
        automaticResultImage = nil
        hasManualMaskEdits = false
        maskTool = .pan
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
        automaticResultImage = nil
        hasManualMaskEdits = false
        maskTool = .pan
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
        automaticResultImage = nil
        hasManualMaskEdits = false
        maskTool = .pan
        errorMessage = nil

        processingTask = Task {
            do {
                let images = try await Task.detached(priority: .userInitiated) {
                    let output = try BackgroundRemovalService.removeBackground(from: source)
                    let preview = BackgroundRemovalService.centeredPreviewCrop(from: output)
                    return (output, preview)
                }.value

                guard !Task.isCancelled, operationID == currentOperationID else { return }
                automaticResultImage = images.0
                setResultImage(images.0, preview: images.1)
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

    func applyMaskStroke(normalizedPoints: [CGPoint], radius: CGFloat) {
        guard maskTool != .pan,
              !normalizedPoints.isEmpty,
              let currentResult = resultImage?.pixelCGImage,
              let source = originalImage?.pixelCGImage else {
            return
        }

        do {
            let edited = try BackgroundRemovalService.applyingMaskStroke(
                to: currentResult,
                restoringFrom: source,
                normalizedPoints: normalizedPoints,
                radius: radius,
                restoresPixels: maskTool == .restore
            )
            setResultImage(edited)
            hasManualMaskEdits = true
        } catch {
            errorMessage = "Не удалось применить кисть: \(error.localizedDescription)"
        }
    }

    func resetMaskEdits() {
        guard let automaticResultImage else { return }
        setResultImage(automaticResultImage)
        hasManualMaskEdits = false
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
        automaticResultImage = nil
        sourceURL = nil
        isProcessing = false
        hasManualMaskEdits = false
        maskTool = .pan
        errorMessage = nil
    }

    private func setResultImage(_ image: CGImage, preview: CGImage? = nil) {
        let previewImage = preview ?? BackgroundRemovalService.centeredPreviewCrop(from: image)
        resultImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        resultPreviewImage = NSImage(
            cgImage: previewImage,
            size: NSSize(width: previewImage.width, height: previewImage.height)
        )
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
