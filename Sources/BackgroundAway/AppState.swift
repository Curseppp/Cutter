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

    enum LayerKind: Equatable {
        case object
        case background

        var title: String {
            switch self {
            case .object: "Объект"
            case .background: "Фон"
            }
        }
    }

    enum CanvasAnchor: String, CaseIterable, Identifiable {
        case topLeft
        case topCenter
        case topRight
        case centerLeft
        case center
        case centerRight
        case bottomLeft
        case bottomCenter
        case bottomRight

        var id: Self { self }

        var title: String {
            switch self {
            case .topLeft: "Сверху слева"
            case .topCenter: "Сверху по центру"
            case .topRight: "Сверху справа"
            case .centerLeft: "По центру слева"
            case .center: "По центру холста"
            case .centerRight: "По центру справа"
            case .bottomLeft: "Снизу слева"
            case .bottomCenter: "Снизу по центру"
            case .bottomRight: "Снизу справа"
            }
        }

        var symbolName: String {
            switch self {
            case .topLeft: "arrow.up.left"
            case .topCenter: "arrow.up"
            case .topRight: "arrow.up.right"
            case .centerLeft: "arrow.left"
            case .center: "scope"
            case .centerRight: "arrow.right"
            case .bottomLeft: "arrow.down.left"
            case .bottomCenter: "arrow.down"
            case .bottomRight: "arrow.down.right"
            }
        }

        var normalizedPoint: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .topCenter: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .centerLeft: CGPoint(x: 0, y: 0.5)
            case .center: CGPoint(x: 0.5, y: 0.5)
            case .centerRight: CGPoint(x: 1, y: 0.5)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .bottomCenter: CGPoint(x: 0.5, y: 1)
            case .bottomRight: CGPoint(x: 1, y: 1)
            }
        }
    }

    struct EdgeSettings: Equatable {
        var isAutomatic = true
        var feather: Double = 0.8
        var shift: Double = -0.25
        var haloCleanup: Double = 0.9

        static let standard = EdgeSettings()
    }

    struct ImageLayer: Identifiable {
        fileprivate struct HistoryEntry {
            let image: CGImage
            let hasManualMaskEdits: Bool
            let sequence: UInt64

            var estimatedByteCount: Int {
                image.bytesPerRow * image.height
            }
        }

        let id: UUID
        var name: String
        var sourceURL: URL?
        var originalImage: NSImage
        var resultImage: NSImage
        var automaticResultImage: CGImage
        var maskResultImage: CGImage
        var edgeSettings: EdgeSettings
        var offset: CGSize
        var scale: CGFloat
        var isVisible: Bool
        var isProcessing: Bool
        var isRefining: Bool
        var hasManualMaskEdits: Bool
        var kind: LayerKind
        fileprivate var undoHistory: [HistoryEntry]
        fileprivate var redoHistory: [HistoryEntry]
    }

    @Published private(set) var layers: [ImageLayer] = []
    @Published private(set) var selectedLayerID: UUID?
    @Published private(set) var canvasSize: CGSize = .zero
    @Published private(set) var initialCanvasSize: CGSize = .zero
    @Published private(set) var documentID = UUID()
    @Published var errorMessage: String?
    @Published var previewMode: PreviewMode = .result {
        didSet {
            if previewMode == .original, maskTool != .pan {
                maskTool = .pan
            }
        }
    }
    @Published var previewBackground: PreviewBackground = .checkerboard
    @Published var maskTool: MaskTool = .pan {
        didSet {
            if maskTool != .pan, previewMode == .original {
                previewMode = .result
            }
        }
    }
    @Published var brushDiameter: Double = 56

    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var processingTokens: [UUID: UUID] = [:]
    private var edgeTasks: [UUID: Task<Void, Never>] = [:]
    private var edgeTokens: [UUID: UUID] = [:]
    private var nextHistorySequence: UInt64 = 0

    private let maximumMaskHistoryStepsPerLayer = 24
    private let maximumMaskHistoryBytes = 256 * 1_024 * 1_024
    private let maximumCanvasDimension: CGFloat = 32_768

    static let minimumLayerScale: CGFloat = 0.05
    static let maximumLayerScale: CGFloat = 8

    var originalImage: NSImage? { selectedLayer?.originalImage }
    var resultImage: NSImage? { selectedLayer?.resultImage }
    var sourceURL: URL? { selectedLayer?.sourceURL }
    var isProcessing: Bool {
        layers.contains { $0.isProcessing || $0.isRefining }
    }
    var isSelectedLayerProcessing: Bool { selectedLayer?.isProcessing ?? false }
    var hasManualMaskEdits: Bool { selectedLayer?.hasManualMaskEdits ?? false }
    var canUndoMaskEdit: Bool { selectedLayer?.undoHistory.isEmpty == false }
    var canRedoMaskEdit: Bool { selectedLayer?.redoHistory.isEmpty == false }

    var sourceName: String {
        selectedLayer?.name ?? "Изображение"
    }

    var sourceDetails: String? {
        guard let image = selectedLayer?.originalImage.pixelCGImage else { return nil }
        return "\(image.width) × \(image.height) px"
    }

    private var selectedLayerIndex: Int? {
        guard let selectedLayerID else { return nil }
        return layers.firstIndex(where: { $0.id == selectedLayerID })
    }

    private var selectedLayer: ImageLayer? {
        guard let selectedLayerIndex else { return nil }
        return layers[selectedLayerIndex]
    }

    func openImagePicker() {
        let panel = makeImagePanel(
            title: "Выберите изображение",
            prompt: "Открыть",
            allowsMultipleSelection: false
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(from: url)
    }

    func addObjectLayerPicker() {
        addLayerPicker(kind: .object)
    }

    func addBackgroundLayerPicker() {
        addLayerPicker(kind: .background)
    }

    private func addLayerPicker(kind: LayerKind) {
        let panel = makeImagePanel(
            title: kind == .object ? "Добавить объект" : "Добавить фон",
            prompt: "Добавить",
            allowsMultipleSelection: true
        )
        guard panel.runModal() == .OK else { return }

        addLayers(from: panel.urls, kind: kind)
    }

    func addLayers(from urls: [URL], kind: LayerKind = .object) {
        let images = urls.compactMap { url -> (NSImage, URL)? in
            guard let image = NSImage(contentsOf: url), image.pixelCGImage != nil else { return nil }
            return (image, url)
        }

        guard !images.isEmpty else {
            errorMessage = "Не удалось открыть выбранные изображения."
            return
        }

        for (image, url) in images {
            if layers.isEmpty {
                replaceDocument(with: image, sourceURL: url, initialKind: kind)
            } else {
                appendLayer(image: image, sourceURL: url, kind: kind)
            }
        }
    }

    func addLayer(_ image: NSImage, kind: LayerKind = .object) {
        guard image.pixelCGImage != nil else {
            errorMessage = "В буфере обмена нет подходящего изображения."
            return
        }

        if layers.isEmpty {
            replaceDocument(with: image, sourceURL: nil, initialKind: kind)
        } else {
            appendLayer(image: image, sourceURL: nil, kind: kind)
        }
    }

    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url), image.pixelCGImage != nil else {
            errorMessage = "Не удалось открыть это изображение. Попробуйте PNG, JPEG, HEIC, WebP или TIFF."
            return
        }
        replaceDocument(with: image, sourceURL: url, initialKind: .object)
    }

    func loadImage(_ image: NSImage) {
        guard image.pixelCGImage != nil else {
            errorMessage = "В буфере обмена нет подходящего изображения."
            return
        }
        replaceDocument(with: image, sourceURL: nil, initialKind: .object)
    }

    func pasteImage() {
        let pasteboard = NSPasteboard.general

        if let url = NSURL(from: pasteboard) as URL?,
           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            if layers.isEmpty {
                loadImage(from: url)
            } else {
                addLayers(from: [url], kind: .object)
            }
            return
        }

        guard let image = NSImage(pasteboard: pasteboard) else {
            errorMessage = "Скопируйте изображение или файл изображения и попробуйте снова."
            return
        }
        if layers.isEmpty {
            loadImage(image)
        } else {
            addLayer(image, kind: .object)
        }
    }

    private func replaceDocument(
        with image: NSImage,
        sourceURL: URL?,
        initialKind: LayerKind
    ) {
        cancelAllProcessing()
        guard let source = image.pixelCGImage else { return }

        canvasSize = CGSize(width: source.width, height: source.height)
        initialCanvasSize = canvasSize
        layers.removeAll(keepingCapacity: false)
        selectedLayerID = nil
        documentID = UUID()
        nextHistorySequence = 0
        errorMessage = nil
        previewMode = .result
        maskTool = .pan

        appendLayer(image: image, sourceURL: sourceURL, kind: initialKind, isInitialLayer: true)
    }

    private func appendLayer(
        image: NSImage,
        sourceURL: URL?,
        kind: LayerKind,
        isInitialLayer: Bool = false
    ) {
        guard let source = image.pixelCGImage else { return }

        if layers.isEmpty {
            canvasSize = CGSize(width: source.width, height: source.height)
        }

        let initialScale: CGFloat
        if isInitialLayer {
            initialScale = 1
        } else if kind == .background {
            initialScale = max(
                canvasSize.width / CGFloat(source.width),
                canvasSize.height / CGFloat(source.height)
            )
        } else {
            initialScale = min(
                min(
                    canvasSize.width / CGFloat(source.width),
                    canvasSize.height / CGFloat(source.height)
                ) * 0.8,
                1
            )
        }

        let layer = ImageLayer(
            id: UUID(),
            name: sourceURL?.lastPathComponent ?? "Изображение",
            sourceURL: sourceURL,
            originalImage: image,
            resultImage: image,
            automaticResultImage: source,
            maskResultImage: source,
            edgeSettings: .standard,
            offset: .zero,
            scale: max(initialScale, 0.01),
            isVisible: true,
            isProcessing: false,
            isRefining: false,
            hasManualMaskEdits: false,
            kind: kind,
            undoHistory: [],
            redoHistory: []
        )

        if kind == .background, !layers.isEmpty {
            layers.insert(layer, at: 0)
        } else {
            layers.append(layer)
        }
        selectedLayerID = layer.id
        maskTool = .pan

        if kind == .object {
            processLayer(id: layer.id)
        }
    }

    func selectLayer(_ id: UUID) {
        guard layers.contains(where: { $0.id == id }) else { return }
        selectedLayerID = id
        maskTool = .pan
    }

    func deselectLayer() {
        guard selectedLayerID != nil else { return }
        selectedLayerID = nil
        maskTool = .pan
    }

    func removeBackground() {
        guard let selectedLayerID,
              selectedLayer?.kind == .object else { return }
        processLayer(id: selectedLayerID)
    }

    private func processLayer(id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }),
              let source = layers[index].originalImage.pixelCGImage else {
            return
        }

        cancelEdgeRefinement(id: id)
        processingTasks[id]?.cancel()
        let token = UUID()
        processingTokens[id] = token

        var layer = layers[index]
        layer.isProcessing = true
        layers[index] = layer
        errorMessage = nil

        processingTasks[id] = Task {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try BackgroundRemovalService.removeBackground(from: source)
                }.value

                guard !Task.isCancelled,
                      processingTokens[id] == token,
                      let currentIndex = layers.firstIndex(where: { $0.id == id }) else {
                    return
                }

                var currentLayer = layers[currentIndex]
                setResultImage(output, on: &currentLayer)
                currentLayer.automaticResultImage = output
                currentLayer.maskResultImage = output
                currentLayer.undoHistory.removeAll(keepingCapacity: false)
                currentLayer.redoHistory.removeAll(keepingCapacity: false)
                currentLayer.hasManualMaskEdits = false
                currentLayer.isProcessing = false
                layers[currentIndex] = currentLayer
                finishProcessingLayer(id: id, token: token)
                scheduleEdgeRefinement(id: id, debounceNanoseconds: 0)
            } catch is CancellationError {
                finishProcessingLayer(id: id, token: token)
            } catch {
                guard processingTokens[id] == token else { return }
                if let currentIndex = layers.firstIndex(where: { $0.id == id }) {
                    var currentLayer = layers[currentIndex]
                    currentLayer.isProcessing = false
                    layers[currentIndex] = currentLayer
                }
                finishProcessingLayer(id: id, token: token)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishProcessingLayer(id: UUID, token: UUID) {
        guard processingTokens[id] == token else { return }
        if let index = layers.firstIndex(where: { $0.id == id }) {
            var layer = layers[index]
            layer.isProcessing = false
            layers[index] = layer
        }
        processingTokens[id] = nil
        processingTasks[id] = nil
    }

    func applyMaskStroke(normalizedPoints: [CGPoint], radius: CGFloat) {
        guard maskTool != .pan,
              !normalizedPoints.isEmpty,
              let index = selectedLayerIndex,
              !layers[index].isProcessing,
              let source = layers[index].originalImage.pixelCGImage else {
            return
        }
        let currentResult = layers[index].maskResultImage

        do {
            let edited = try BackgroundRemovalService.applyingMaskStroke(
                to: currentResult,
                restoringFrom: source,
                normalizedPoints: normalizedPoints,
                radius: radius,
                restoresPixels: maskTool == .restore
            )

            var layer = layers[index]
            recordUndoState(currentResult, on: &layer)
            layer.maskResultImage = edited
            setResultImage(edited, on: &layer)
            layer.hasManualMaskEdits = true
            layers[index] = layer
            trimMaskHistoryIfNeeded()
            scheduleEdgeRefinement(id: layer.id)
        } catch {
            errorMessage = "Не удалось применить кисть: \(error.localizedDescription)"
        }
    }

    func resetMaskEdits() {
        guard let index = selectedLayerIndex,
              layers[index].hasManualMaskEdits else {
            return
        }
        let currentResult = layers[index].maskResultImage

        var layer = layers[index]
        recordUndoState(currentResult, on: &layer)
        layer.maskResultImage = layer.automaticResultImage
        setResultImage(layer.automaticResultImage, on: &layer)
        layer.hasManualMaskEdits = false
        layers[index] = layer
        trimMaskHistoryIfNeeded()
        scheduleEdgeRefinement(id: layer.id)
    }

    func undoLastMaskEdit() {
        guard let index = selectedLayerIndex,
              let target = layers[index].undoHistory.last else {
            return
        }
        let currentResult = layers[index].maskResultImage

        var layer = layers[index]
        layer.undoHistory.removeLast()
        layer.redoHistory.append(makeHistoryEntry(
            image: currentResult,
            hasManualMaskEdits: layer.hasManualMaskEdits
        ))
        layer.maskResultImage = target.image
        setResultImage(target.image, on: &layer)
        layer.hasManualMaskEdits = target.hasManualMaskEdits
        layers[index] = layer
        trimMaskHistoryIfNeeded()
        scheduleEdgeRefinement(id: layer.id)
    }

    func redoLastMaskEdit() {
        guard let index = selectedLayerIndex,
              let target = layers[index].redoHistory.last else {
            return
        }
        let currentResult = layers[index].maskResultImage

        var layer = layers[index]
        layer.redoHistory.removeLast()
        layer.undoHistory.append(makeHistoryEntry(
            image: currentResult,
            hasManualMaskEdits: layer.hasManualMaskEdits
        ))
        layer.maskResultImage = target.image
        setResultImage(target.image, on: &layer)
        layer.hasManualMaskEdits = target.hasManualMaskEdits
        layers[index] = layer
        trimMaskHistoryIfNeeded()
        scheduleEdgeRefinement(id: layer.id)
    }

    func setLayerEdgeAutomatic(_ id: UUID, isAutomatic: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        var layer = layers[index]
        guard layer.edgeSettings.isAutomatic != isAutomatic else { return }
        layer.edgeSettings.isAutomatic = isAutomatic
        layers[index] = layer
        scheduleEdgeRefinement(id: id)
    }

    func setLayerEdgeFeather(_ id: UUID, feather: Double) {
        guard feather.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        var layer = layers[index]
        let clampedFeather = min(max(feather, 0), 3)
        guard layer.edgeSettings.feather != clampedFeather else { return }
        layer.edgeSettings.feather = clampedFeather
        layer.edgeSettings.isAutomatic = false
        layers[index] = layer
        scheduleEdgeRefinement(id: id)
    }

    func setLayerEdgeShift(_ id: UUID, shift: Double) {
        guard shift.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        var layer = layers[index]
        let clampedShift = min(max(shift, -2), 2)
        guard layer.edgeSettings.shift != clampedShift else { return }
        layer.edgeSettings.shift = clampedShift
        layer.edgeSettings.isAutomatic = false
        layers[index] = layer
        scheduleEdgeRefinement(id: id)
    }

    func setLayerHaloCleanup(_ id: UUID, cleanup: Double) {
        guard cleanup.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        var layer = layers[index]
        let clampedCleanup = min(max(cleanup, 0), 1)
        guard layer.edgeSettings.haloCleanup != clampedCleanup else { return }
        layer.edgeSettings.haloCleanup = clampedCleanup
        layer.edgeSettings.isAutomatic = false
        layers[index] = layer
        scheduleEdgeRefinement(id: id)
    }

    func resetLayerEdgeSettings(_ id: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        var layer = layers[index]
        guard layer.edgeSettings != .standard else { return }
        layer.edgeSettings = .standard
        layers[index] = layer
        scheduleEdgeRefinement(id: id)
    }

    func setLayerVisibility(_ id: UUID, isVisible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        var layer = layers[index]
        layer.isVisible = isVisible
        layers[index] = layer
    }

    func moveLayer(_ id: UUID, to offset: CGSize) {
        guard offset.width.isFinite,
              offset.height.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        var layer = layers[index]
        layer.offset = offset
        layers[index] = layer
    }

    func setLayerScale(_ id: UUID, scale: CGFloat) {
        guard scale.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        var layer = layers[index]
        layer.scale = min(max(scale, Self.minimumLayerScale), Self.maximumLayerScale)
        layers[index] = layer
    }

    func setLayerTransform(_ id: UUID, offset: CGSize, scale: CGFloat) {
        guard offset.width.isFinite,
              offset.height.isFinite,
              scale.isFinite,
              let index = layers.firstIndex(where: { $0.id == id }) else {
            return
        }

        var layer = layers[index]
        layer.offset = offset
        layer.scale = min(max(scale, Self.minimumLayerScale), Self.maximumLayerScale)
        layers[index] = layer
    }

    func alignLayer(_ id: UUID, to anchor: CanvasAnchor) {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              let index = layers.firstIndex(where: { $0.id == id }),
              let image = layers[index].originalImage.pixelCGImage else {
            return
        }

        var layer = layers[index]
        let renderedWidth = CGFloat(image.width) * layer.scale
        let renderedHeight = CGFloat(image.height) * layer.scale
        let point = anchor.normalizedPoint

        layer.offset = CGSize(
            width: (canvasSize.width - renderedWidth) * (point.x - 0.5),
            height: (canvasSize.height - renderedHeight) * (point.y - 0.5)
        )
        layers[index] = layer
    }

    func renameLayer(_ id: UUID, to proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = layers.firstIndex(where: { $0.id == id }) else {
            return
        }

        var layer = layers[index]
        layer.name = name
        layers[index] = layer
    }

    func resizeCanvas(to requestedSize: CGSize) {
        guard !layers.isEmpty,
              requestedSize.width.isFinite,
              requestedSize.height.isFinite else {
            return
        }

        let newSize = CGSize(
            width: max(requestedSize.width.rounded(), 1),
            height: max(requestedSize.height.rounded(), 1)
        )
        guard newSize.width <= maximumCanvasDimension,
              newSize.height <= maximumCanvasDimension else {
            errorMessage = "Максимальный размер холста — 32 768 × 32 768 px."
            return
        }
        guard newSize != canvasSize else { return }

        canvasSize = newSize
        documentID = UUID()
    }

    func resetCanvasSize() {
        guard initialCanvasSize.width > 0, initialCanvasSize.height > 0 else { return }
        resizeCanvas(to: initialCanvasSize)
    }

    func fitCanvasToVisibleLayers(padding: CGFloat) {
        let visibleLayers = layers.filter(\.isVisible)
        guard !visibleLayers.isEmpty else { return }

        var contentBounds: CGRect?
        for layer in visibleLayers {
            guard let image = layer.resultImage.pixelCGImage else { continue }
            let layerSize = CGSize(
                width: CGFloat(image.width) * layer.scale,
                height: CGFloat(image.height) * layer.scale
            )
            let layerBounds = CGRect(
                x: layer.offset.width - layerSize.width / 2,
                y: layer.offset.height - layerSize.height / 2,
                width: layerSize.width,
                height: layerSize.height
            )
            contentBounds = contentBounds?.union(layerBounds) ?? layerBounds
        }

        guard let contentBounds else { return }
        let safePadding = padding.isFinite ? max(padding.rounded(), 0) : 0
        let minimumX = floor(contentBounds.minX - safePadding)
        let maximumX = ceil(contentBounds.maxX + safePadding)
        let minimumY = floor(contentBounds.minY - safePadding)
        let maximumY = ceil(contentBounds.maxY + safePadding)
        let newSize = CGSize(
            width: max(maximumX - minimumX, 1),
            height: max(maximumY - minimumY, 1)
        )
        guard newSize.width <= maximumCanvasDimension,
              newSize.height <= maximumCanvasDimension else {
            errorMessage = "Слои не помещаются в холст размером до 32 768 × 32 768 px."
            return
        }

        let contentCenter = CGPoint(
            x: (minimumX + maximumX) / 2,
            y: (minimumY + maximumY) / 2
        )

        var updatedLayers = layers
        for index in updatedLayers.indices {
            var layer = updatedLayers[index]
            layer.offset = CGSize(
                width: layer.offset.width - contentCenter.x,
                height: layer.offset.height - contentCenter.y
            )
            updatedLayers[index] = layer
        }

        layers = updatedLayers
        canvasSize = newSize
        documentID = UUID()
    }

    func moveSelectedLayerUp() {
        guard let index = selectedLayerIndex, index < layers.count - 1 else { return }
        layers.swapAt(index, index + 1)
    }

    func moveSelectedLayerDown() {
        guard let index = selectedLayerIndex, index > 0 else { return }
        layers.swapAt(index, index - 1)
    }

    func duplicateSelectedLayer() {
        guard let index = selectedLayerIndex else { return }
        let sourceLayer = layers[index]
        let duplicate = ImageLayer(
            id: UUID(),
            name: "\(sourceLayer.name) — копия",
            sourceURL: sourceLayer.sourceURL,
            originalImage: sourceLayer.originalImage,
            resultImage: sourceLayer.resultImage,
            automaticResultImage: sourceLayer.automaticResultImage,
            maskResultImage: sourceLayer.maskResultImage,
            edgeSettings: sourceLayer.edgeSettings,
            offset: CGSize(
                width: sourceLayer.offset.width + 24,
                height: sourceLayer.offset.height + 24
            ),
            scale: sourceLayer.scale,
            isVisible: true,
            isProcessing: false,
            isRefining: false,
            hasManualMaskEdits: sourceLayer.hasManualMaskEdits,
            kind: sourceLayer.kind,
            undoHistory: [],
            redoHistory: []
        )
        layers.insert(duplicate, at: index + 1)
        selectedLayerID = duplicate.id
        maskTool = .pan

        if duplicate.kind == .object {
            scheduleEdgeRefinement(id: duplicate.id, debounceNanoseconds: 0)
        }
    }

    func removeSelectedLayer() {
        guard let index = selectedLayerIndex else { return }
        let removedID = layers[index].id
        cancelEdgeRefinement(id: removedID)
        processingTasks[removedID]?.cancel()
        processingTasks[removedID] = nil
        processingTokens[removedID] = nil
        layers.remove(at: index)

        if layers.isEmpty {
            clear()
        } else {
            selectedLayerID = layers[min(index, layers.count - 1)].id
            maskTool = .pan
        }
    }

    func exportResult() {
        guard !layers.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Сохранить композицию"
        panel.prompt = "Экспортировать"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedExportName

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let image = try renderedComposition(useOriginals: false)
            try Self.pngData(from: image).write(to: destination, options: .atomic)
        } catch {
            errorMessage = "Не удалось сохранить PNG: \(error.localizedDescription)"
        }
    }

    func copyResult() {
        do {
            let image = try renderedComposition(useOriginals: false)
            let nsImage = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([nsImage])
        } catch {
            errorMessage = "Не удалось скопировать композицию: \(error.localizedDescription)"
        }
    }

    func renderedComposition(useOriginals: Bool) throws -> CGImage {
        let compositionLayers = layers.compactMap { layer -> BackgroundRemovalService.CompositionLayer? in
            guard layer.isVisible,
                  let image = (useOriginals ? layer.originalImage : layer.resultImage).pixelCGImage else {
                return nil
            }
            return BackgroundRemovalService.CompositionLayer(
                image: image,
                offset: layer.offset,
                scale: layer.scale
            )
        }
        return try BackgroundRemovalService.compose(
            layers: compositionLayers,
            canvasSize: canvasSize
        )
    }

    func clear() {
        cancelAllProcessing()
        layers.removeAll(keepingCapacity: false)
        selectedLayerID = nil
        canvasSize = .zero
        initialCanvasSize = .zero
        documentID = UUID()
        nextHistorySequence = 0
        maskTool = .pan
        previewMode = .result
        errorMessage = nil
    }

    private func cancelAllProcessing() {
        for task in processingTasks.values {
            task.cancel()
        }
        for task in edgeTasks.values {
            task.cancel()
        }
        processingTasks.removeAll(keepingCapacity: false)
        processingTokens.removeAll(keepingCapacity: false)
        edgeTasks.removeAll(keepingCapacity: false)
        edgeTokens.removeAll(keepingCapacity: false)
    }

    private func scheduleEdgeRefinement(
        id: UUID,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        guard let index = layers.firstIndex(where: { $0.id == id }),
              layers[index].kind == .object,
              !layers[index].isProcessing else {
            return
        }

        edgeTasks[id]?.cancel()
        let token = UUID()
        edgeTokens[id] = token

        var layer = layers[index]
        let base = layer.maskResultImage
        let parameters = resolvedEdgeParameters(for: layer)

        if !layer.edgeSettings.isAutomatic,
           parameters.feather < 0.01,
           abs(parameters.shift) < 0.01,
           parameters.cleanup < 0.01 {
            setResultImage(base, on: &layer)
            layer.isRefining = false
            layers[index] = layer
            edgeTokens[id] = nil
            edgeTasks[id] = nil
            return
        }

        layer.isRefining = true
        layers[index] = layer

        edgeTasks[id] = Task {
            do {
                if debounceNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                }

                let refinementTask = Task.detached(priority: .userInitiated) {
                    try BackgroundRemovalService.refiningEdges(
                        of: base,
                        featherRadius: parameters.feather,
                        edgeShift: parameters.shift,
                        haloCleanup: parameters.cleanup
                    )
                }
                let refined = try await withTaskCancellationHandler {
                    try await refinementTask.value
                } onCancel: {
                    refinementTask.cancel()
                }

                guard !Task.isCancelled,
                      edgeTokens[id] == token,
                      let currentIndex = layers.firstIndex(where: { $0.id == id }) else {
                    return
                }

                var currentLayer = layers[currentIndex]
                setResultImage(refined, on: &currentLayer)
                currentLayer.isRefining = false
                layers[currentIndex] = currentLayer
                finishEdgeRefinement(id: id, token: token)
            } catch is CancellationError {
                finishEdgeRefinement(id: id, token: token)
            } catch {
                guard edgeTokens[id] == token else { return }
                if let currentIndex = layers.firstIndex(where: { $0.id == id }) {
                    var currentLayer = layers[currentIndex]
                    currentLayer.edgeSettings.isAutomatic = false
                    currentLayer.edgeSettings.feather = 0
                    currentLayer.edgeSettings.shift = 0
                    currentLayer.edgeSettings.haloCleanup = 0
                    setResultImage(currentLayer.maskResultImage, on: &currentLayer)
                    currentLayer.isRefining = false
                    layers[currentIndex] = currentLayer
                }
                finishEdgeRefinement(id: id, token: token)
                errorMessage = "Не удалось сгладить край: \(error.localizedDescription)"
            }
        }
    }

    private func resolvedEdgeParameters(
        for layer: ImageLayer
    ) -> (feather: CGFloat, shift: CGFloat, cleanup: CGFloat) {
        let settings = layer.edgeSettings
        guard settings.isAutomatic else {
            return (
                CGFloat(settings.feather),
                CGFloat(settings.shift),
                CGFloat(settings.haloCleanup)
            )
        }

        let maximumDimension = CGFloat(max(
            layer.maskResultImage.width,
            layer.maskResultImage.height
        ))
        let resolutionFactor = min(max(maximumDimension / 1_440, 0.65), 2)
        return (
            feather: 0.8 * resolutionFactor,
            shift: -0.25 * resolutionFactor,
            cleanup: 0.9
        )
    }

    private func finishEdgeRefinement(id: UUID, token: UUID) {
        guard edgeTokens[id] == token else { return }
        if let index = layers.firstIndex(where: { $0.id == id }) {
            var layer = layers[index]
            layer.isRefining = false
            layers[index] = layer
        }
        edgeTokens[id] = nil
        edgeTasks[id] = nil
    }

    private func cancelEdgeRefinement(id: UUID) {
        edgeTasks[id]?.cancel()
        edgeTasks[id] = nil
        edgeTokens[id] = nil
        if let index = layers.firstIndex(where: { $0.id == id }) {
            var layer = layers[index]
            layer.isRefining = false
            layers[index] = layer
        }
    }

    private func makeImagePanel(
        title: String,
        prompt: String,
        allowsMultipleSelection: Bool
    ) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        return panel
    }

    private func recordUndoState(_ image: CGImage, on layer: inout ImageLayer) {
        layer.undoHistory.append(makeHistoryEntry(
            image: image,
            hasManualMaskEdits: layer.hasManualMaskEdits
        ))
        layer.redoHistory.removeAll(keepingCapacity: true)

        while layer.undoHistory.count > maximumMaskHistoryStepsPerLayer {
            layer.undoHistory.removeFirst()
        }
    }

    private func makeHistoryEntry(
        image: CGImage,
        hasManualMaskEdits: Bool
    ) -> ImageLayer.HistoryEntry {
        nextHistorySequence &+= 1
        return ImageLayer.HistoryEntry(
            image: image,
            hasManualMaskEdits: hasManualMaskEdits,
            sequence: nextHistorySequence
        )
    }

    private func trimMaskHistoryIfNeeded() {
        func totalBytes() -> Int {
            layers.reduce(0) { total, layer in
                total + layer.undoHistory.reduce(0) { $0 + $1.estimatedByteCount } +
                    layer.redoHistory.reduce(0) { $0 + $1.estimatedByteCount }
            }
        }

        while totalBytes() > maximumMaskHistoryBytes {
            var candidate: (layerIndex: Int, isUndo: Bool, sequence: UInt64)?

            for index in layers.indices {
                if let entry = layers[index].undoHistory.first,
                   candidate == nil || entry.sequence < candidate!.sequence {
                    candidate = (index, true, entry.sequence)
                }
                if let entry = layers[index].redoHistory.first,
                   candidate == nil || entry.sequence < candidate!.sequence {
                    candidate = (index, false, entry.sequence)
                }
            }

            guard let candidate else { break }
            if candidate.isUndo {
                layers[candidate.layerIndex].undoHistory.removeFirst()
            } else {
                layers[candidate.layerIndex].redoHistory.removeFirst()
            }
        }
    }

    private func setResultImage(_ image: CGImage, on layer: inout ImageLayer) {
        layer.resultImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }

    private var suggestedExportName: String {
        let baseName = layers.first?.sourceURL?.deletingPathExtension().lastPathComponent ?? "composition"
        return "\(baseName)-композиция.png"
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
