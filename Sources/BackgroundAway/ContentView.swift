import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if appState.layers.isEmpty {
                EmptyDropView(isTargeted: isDropTargeted) {
                    appState.openImagePicker()
                }
            } else {
                PreviewWorkspace(appState: appState)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imageURLs = urls.filter {
                UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
            }
            guard !imageURLs.isEmpty else { return false }

            if appState.layers.isEmpty, let first = imageURLs.first {
                appState.loadImage(from: first)
                let additionalImages = Array(imageURLs.dropFirst())
                if !additionalImages.isEmpty {
                    appState.addLayers(from: additionalImages, kind: .object)
                }
            } else {
                appState.addLayers(from: imageURLs, kind: .object)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .overlay {
            if isDropTargeted, !appState.layers.isEmpty {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 8]))
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    .padding(14)
                    .allowsHitTesting(false)
            }
        }
        .background {
            if !appState.layers.isEmpty {
                WorkspaceKeyboardShortcutCapture(
                    canEditMask: canEditSelectedMask,
                    canUndoMaskEdit: appState.canUndoMaskEdit,
                    canRedoMaskEdit: appState.canRedoMaskEdit,
                    selectTool: { appState.maskTool = $0 },
                    selectPreview: { appState.previewMode = $0 },
                    undoMaskEdit: { appState.undoLastMaskEdit() },
                    redoMaskEdit: { appState.redoLastMaskEdit() },
                    deselectLayer: { appState.deselectLayer() }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .onOpenURL { url in
            appState.loadImage(from: url)
        }
        .alert("Что-то пошло не так", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
            if selectedLayer?.kind == .object {
                Button("Попробовать ещё раз") {
                    appState.removeBackground()
                }
            }
        } message: {
            Text(appState.errorMessage ?? "Неизвестная ошибка")
        }
    }

    private var selectedLayer: AppState.ImageLayer? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.first(where: { $0.id == selectedLayerID })
    }

    private var canEditSelectedMask: Bool {
        guard let selectedLayer else { return false }
        return selectedLayer.isVisible && !selectedLayer.isProcessing
    }
}

private struct EmptyDropView: View {
    let isTargeted: Bool
    let openAction: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
            }

            VStack(spacing: 7) {
                Text(isTargeted ? "Отпустите изображение" : "Удалите фон за несколько секунд")
                    .font(.title2.weight(.semibold))
                Text("Перетащите сюда PNG, JPEG, HEIC, WebP или TIFF")
                    .foregroundStyle(.secondary)
            }

            Button("Выбрать изображение…", action: openAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(50)
        .frame(maxWidth: 620, maxHeight: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isTargeted ? 3 : 1, dash: [9, 7])
                )
        }
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.snappy, value: isTargeted)
    }
}

private enum ComparisonPane {
    case original
    case result
}

private struct SurfaceViewport: Equatable {
    var zoomScale: CGFloat = 1
    var centerOffset: CGSize = .zero
}

private struct PreviewWorkspace: View {
    @ObservedObject var appState: AppState
    @State private var originalViewport = SurfaceViewport()
    @State private var resultViewport = SurfaceViewport()
    @State private var comparisonViewportsLinked = false
    @State private var lastInteractedPane: ComparisonPane = .result

    var body: some View {
        VStack(spacing: 12) {
            WorkspaceTopBar(
                appState: appState,
                comparisonViewportsLinked: comparisonViewportsLinked,
                onToggleComparisonViewports: toggleComparisonViewports
            )

            HStack(spacing: 12) {
                MaskToolPalette(appState: appState)

                previewContent
                    .overlay(alignment: .top) {
                        if appState.isSelectedLayerProcessing {
                            HStack(spacing: 9) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Обрабатываем выбранный слой…")
                                    .font(.callout.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.ultraThickMaterial, in: Capsule())
                            .padding(12)
                            .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if appState.previewMode != .original,
                           let selectedLayerID = appState.selectedLayerID {
                            SelectedLayerInspector(
                                appState: appState,
                                layerID: selectedLayerID
                            )
                            .id(selectedLayerID)
                            .padding(12)
                        }
                    }
            }
        }
        .padding(14)
        .onChange(of: appState.documentID) { _, _ in
            originalViewport = SurfaceViewport()
            resultViewport = SurfaceViewport()
            lastInteractedPane = .result
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch appState.previewMode {
        case .result:
            CompositionSurface(
                appState: appState,
                background: appState.previewBackground,
                useOriginals: false,
                allowsLayerEditing: true,
                allowsMaskPainting: true,
                label: "",
                viewport: viewportBinding(for: .result),
                onInteraction: { markInteraction(.result) }
            )
        case .original:
            CompositionSurface(
                appState: appState,
                background: .white,
                useOriginals: true,
                allowsLayerEditing: false,
                allowsMaskPainting: false,
                label: "",
                viewport: viewportBinding(for: .original),
                onInteraction: { markInteraction(.original) }
            )
        case .comparison:
            HStack(spacing: 12) {
                CompositionSurface(
                    appState: appState,
                    background: .white,
                    useOriginals: true,
                    allowsLayerEditing: true,
                    allowsMaskPainting: false,
                    label: "Оригинал",
                    viewport: viewportBinding(for: .original),
                    onInteraction: { markInteraction(.original) }
                )
                CompositionSurface(
                    appState: appState,
                    background: appState.previewBackground,
                    useOriginals: false,
                    allowsLayerEditing: true,
                    allowsMaskPainting: true,
                    label: "Результат",
                    viewport: viewportBinding(for: .result),
                    onInteraction: { markInteraction(.result) }
                )
            }
        }
    }

    private func viewportBinding(for pane: ComparisonPane) -> Binding<SurfaceViewport> {
        Binding(
            get: {
                pane == .original ? originalViewport : resultViewport
            },
            set: { newViewport in
                lastInteractedPane = pane
                if comparisonViewportsLinked {
                    originalViewport = newViewport
                    resultViewport = newViewport
                } else if pane == .original {
                    originalViewport = newViewport
                } else {
                    resultViewport = newViewport
                }
            }
        )
    }

    private func markInteraction(_ pane: ComparisonPane) {
        lastInteractedPane = pane
    }

    private func toggleComparisonViewports() {
        if comparisonViewportsLinked {
            comparisonViewportsLinked = false
            return
        }

        let sourceViewport = lastInteractedPane == .original
            ? originalViewport
            : resultViewport
        originalViewport = sourceViewport
        resultViewport = sourceViewport
        comparisonViewportsLinked = true
    }
}

private struct WorkspaceTopBar: View {
    @ObservedObject var appState: AppState
    let comparisonViewportsLinked: Bool
    let onToggleComparisonViewports: () -> Void
    @State private var showsLayers = false
    @State private var showsCanvasSize = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    appState.addObjectLayerPicker()
                } label: {
                    Label("Добавить объект…", systemImage: "photo.badge.plus")
                }

                Button {
                    appState.addBackgroundLayerPicker()
                } label: {
                    Label("Добавить фон…", systemImage: "rectangle.inset.filled")
                }
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .help("Добавить изображение в композицию")

            Button {
                showsLayers.toggle()
            } label: {
                Label("Слои \(appState.layers.count)", systemImage: "square.3.layers.3d")
            }
            .popover(isPresented: $showsLayers, arrowEdge: .top) {
                LayerListPopover(appState: appState)
            }
            .help("Слои композиции")

            Button {
                showsCanvasSize.toggle()
            } label: {
                Label("Холст", systemImage: "aspectratio")
            }
            .popover(isPresented: $showsCanvasSize, arrowEdge: .top) {
                CanvasSizePopover(appState: appState)
            }
            .help("Размер холста: \(canvasSizeTitle) px")

            Menu {
                previewButton(.original, shortcut: "Tab+1")
                previewButton(.result, shortcut: "Tab+2")
                previewButton(.comparison, shortcut: "Tab+3")
            } label: {
                Label(appState.previewMode.title, systemImage: previewSymbol)
            }
            .help("Режим просмотра")

            if appState.previewMode == .comparison {
                Button(action: onToggleComparisonViewports) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            comparisonViewportsLinked ? Color.white : Color.primary
                        )
                        .frame(width: 28, height: 28)
                        .background(
                            comparisonViewportsLinked ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(
                    comparisonViewportsLinked
                        ? "Отключить синхронизацию масштаба и положения"
                        : "Синхронизировать масштаб и положение"
                )
                .accessibilityLabel(
                    comparisonViewportsLinked
                        ? "Отключить синхронизацию"
                        : "Включить синхронизацию"
                )
            }

            Menu {
                ForEach(AppState.PreviewBackground.allCases) { background in
                    Button {
                        appState.previewBackground = background
                    } label: {
                        Label(
                            background.title,
                            systemImage: appState.previewBackground == background
                                ? "checkmark"
                                : backgroundSymbol(background)
                        )
                    }
                }
            } label: {
                Label(appState.previewBackground.title, systemImage: "circle.lefthalf.filled")
            }
            .help("Фон предпросмотра")

            Spacer(minLength: 12)

            if appState.isProcessing {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                appState.exportResult()
            } label: {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }
            .disabled(appState.layers.isEmpty || appState.isProcessing)
            .help("Сохранить композицию в PNG (⌘S)")

            Button {
                appState.clear()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 18)
            }
            .help("Закрыть композицию")

            Button {
                appState.removeBackground()
            } label: {
                Label("Обработать снова", systemImage: "arrow.clockwise")
            }
            .disabled(selectedLayer?.kind != .object || appState.isSelectedLayerProcessing)
        }
        .controlSize(.large)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.secondary.opacity(0.18))
        }
    }

    private var selectedLayer: AppState.ImageLayer? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.first(where: { $0.id == selectedLayerID })
    }

    private var previewSymbol: String {
        switch appState.previewMode {
        case .original: "photo"
        case .result: "wand.and.stars"
        case .comparison: "rectangle.split.2x1"
        }
    }

    private var canvasSizeTitle: String {
        "\(Int(appState.canvasSize.width)) × \(Int(appState.canvasSize.height))"
    }

    private func previewButton(_ mode: AppState.PreviewMode, shortcut: String) -> some View {
        Button {
            appState.previewMode = mode
        } label: {
            HStack {
                if appState.previewMode == mode {
                    Image(systemName: "checkmark")
                }
                Text(mode.title)
                Spacer()
                Text(shortcut)
            }
        }
    }

    private func backgroundSymbol(_ background: AppState.PreviewBackground) -> String {
        switch background {
        case .checkerboard: "checkerboard.rectangle"
        case .white: "circle"
        case .black: "circle.fill"
        }
    }
}

private struct CanvasSizePopover: View {
    @ObservedObject var appState: AppState
    @State private var widthText: String
    @State private var heightText: String
    @State private var padding: Double = 48

    init(appState: AppState) {
        self.appState = appState
        _widthText = State(initialValue: String(Int(appState.canvasSize.width)))
        _heightText = State(initialValue: String(Int(appState.canvasSize.height)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Размер холста")
                    .font(.headline)
                Text("Он определяет размер итогового PNG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                dimensionField(title: "Ширина", text: $widthText)
                Image(systemName: "multiply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                dimensionField(title: "Высота", text: $heightText)
                Text("px")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    applyCustomSize()
                } label: {
                    Text("Применить")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApplyCustomSize)

                Menu {
                    presetButton("Квадрат", width: 1_080, height: 1_080)
                    presetButton("Альбомный", width: 1_920, height: 1_080)
                    presetButton("Портрет", width: 1_080, height: 1_350)
                    presetButton("История / обои", width: 1_080, height: 1_920)
                    presetButton("Горизонтальный пост", width: 1_200, height: 628)
                    Divider()
                    presetButton("4K", width: 3_840, height: 2_160)
                } label: {
                    Label("Форматы", systemImage: "rectangle.3.group")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Поля при автоподгонке")
                        .font(.callout)
                    Spacer()
                    Text("\(Int(padding)) px")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(value: $padding, in: 0...512, step: 1)

                Button {
                    appState.fitCanvasToVisibleLayers(padding: CGFloat(padding))
                } label: {
                    Label(
                        "По всем видимым слоям",
                        systemImage: "arrow.up.left.and.arrow.down.right"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Расширить или уменьшить холст под видимые слои")
            }

            Button {
                appState.resetCanvasSize()
            } label: {
                Label(
                    "Вернуть исходный — \(initialSizeTitle)",
                    systemImage: "arrow.counterclockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.canvasSize == appState.initialCanvasSize)

            Text("При ручном изменении холст расширяется или обрезается относительно центра.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            synchronizeFields()
        }
        .onChange(of: appState.documentID) { _, _ in
            synchronizeFields()
        }
    }

    private var parsedWidth: Int? {
        Int(widthText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var parsedHeight: Int? {
        Int(heightText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canApplyCustomSize: Bool {
        guard let parsedWidth, let parsedHeight else { return false }
        return (1...32_768).contains(parsedWidth) &&
            (1...32_768).contains(parsedHeight)
    }

    private var initialSizeTitle: String {
        "\(Int(appState.initialCanvasSize.width)) × \(Int(appState.initialCanvasSize.height))"
    }

    private func dimensionField(
        title: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 108)
                .onSubmit {
                    applyCustomSize()
                }
        }
    }

    private func presetButton(
        _ title: String,
        width: Int,
        height: Int
    ) -> some View {
        Button("\(title) — \(width) × \(height)") {
            appState.resizeCanvas(to: CGSize(width: width, height: height))
        }
    }

    private func applyCustomSize() {
        guard canApplyCustomSize,
              let parsedWidth,
              let parsedHeight else {
            return
        }
        appState.resizeCanvas(to: CGSize(width: parsedWidth, height: parsedHeight))
    }

    private func synchronizeFields() {
        widthText = String(Int(appState.canvasSize.width))
        heightText = String(Int(appState.canvasSize.height))
    }
}

private struct LayerListPopover: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Слои")
                    .font(.headline)
                Spacer()
                Text("\(appState.layers.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(Array(appState.layers.reversed())) { layer in
                        layerRow(layer)
                    }
                }
                .padding(8)
            }
            .frame(height: min(CGFloat(appState.layers.count) * 62 + 16, 330))

            Divider()

            if let selectedLayer {
                VStack(spacing: 9) {
                    HStack {
                        Text("Масштаб")
                            .foregroundStyle(.secondary)
                        Slider(
                            value: scaleBinding(for: selectedLayer.id),
                            in: Double(AppState.minimumLayerScale)...Double(AppState.maximumLayerScale)
                        )
                        Text("\(Int(selectedLayer.scale * 100))%")
                            .frame(width: 46, alignment: .trailing)
                            .monospacedDigit()
                    }

                    HStack(spacing: 6) {
                        layerAction(
                            symbol: "arrow.down",
                            help: "Опустить слой",
                            isDisabled: selectedIndex == 0
                        ) {
                            appState.moveSelectedLayerDown()
                        }

                        layerAction(
                            symbol: "arrow.up",
                            help: "Поднять слой",
                            isDisabled: selectedIndex == appState.layers.count - 1
                        ) {
                            appState.moveSelectedLayerUp()
                        }

                        layerAction(
                            symbol: "plus.square.on.square",
                            help: "Дублировать слой"
                        ) {
                            appState.duplicateSelectedLayer()
                        }

                        Spacer()

                        layerAction(
                            symbol: "trash",
                            help: "Удалить слой",
                            role: .destructive
                        ) {
                            appState.removeSelectedLayer()
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 330)
    }

    private var selectedLayer: AppState.ImageLayer? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.first(where: { $0.id == selectedLayerID })
    }

    private var selectedIndex: Int? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.firstIndex(where: { $0.id == selectedLayerID })
    }

    private func layerRow(_ layer: AppState.ImageLayer) -> some View {
        HStack(spacing: 9) {
            Button {
                appState.setLayerVisibility(layer.id, isVisible: !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .frame(width: 18)
                    .foregroundStyle(layer.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Скрыть слой" : "Показать слой")

            ZStack {
                CheckerboardView(squareSize: 6)
                Image(nsImage: layer.resultImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(2)
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.18))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(layer.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(layer.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if layer.isProcessing || layer.isRefining {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            layer.id == appState.selectedLayerID
                ? Color.accentColor.opacity(0.16)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectLayer(layer.id)
        }
        .opacity(layer.isVisible ? 1 : 0.58)
    }

    private func scaleBinding(for id: UUID) -> Binding<Double> {
        Binding(
            get: {
                Double(appState.layers.first(where: { $0.id == id })?.scale ?? 1)
            },
            set: {
                appState.setLayerScale(id, scale: CGFloat($0))
            }
        )
    }

    private func layerAction(
        symbol: String,
        help: String,
        isDisabled: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(help)
    }
}

private struct MaskToolPalette: View {
    @ObservedObject var appState: AppState
    @State private var showsBrushSize = false

    var body: some View {
        VStack(spacing: 6) {
            Button {
                appState.maskTool = .pan
            } label: {
                paletteIcon("hand.draw", selected: appState.maskTool == .pan)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit)
            .help("Выбор и перемещение слоя (V)")

            Menu {
                Button {
                    appState.maskTool = .erase
                } label: {
                    Label("Удалить — X", systemImage: "eraser")
                }

                Button {
                    appState.maskTool = .restore
                } label: {
                    Label("Вернуть — B", systemImage: "paintbrush")
                }
            } label: {
                paletteIcon("rectangle.dashed", selected: maskToolIsSelected)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!canEdit)
            .help("Коррекция маски")

            if maskToolIsSelected {
                Button {
                    showsBrushSize.toggle()
                } label: {
                    paletteIcon("circle.dotted", selected: showsBrushSize)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsBrushSize, arrowEdge: .leading) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Размер кисти")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(appState.brushDiameter.rounded())) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            Image(systemName: "circle")
                                .font(.system(size: 7))
                            Slider(value: $appState.brushDiameter, in: 8...180)
                            Image(systemName: "circle.fill")
                                .font(.system(size: 15))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(width: 250)
                }
                .help("Размер кисти")
            }

            Divider()
                .padding(.vertical, 2)

            Button {
                appState.undoLastMaskEdit()
            } label: {
                paletteIcon("arrow.uturn.backward", selected: false)
            }
            .buttonStyle(.plain)
            .disabled(!appState.canUndoMaskEdit)
            .help("Отменить изменение выбранного слоя (⌘Z)")

            Button {
                appState.redoLastMaskEdit()
            } label: {
                paletteIcon("arrow.uturn.forward", selected: false)
            }
            .buttonStyle(.plain)
            .disabled(!appState.canRedoMaskEdit)
            .help("Повторить изменение выбранного слоя (⇧⌘Z)")

            Button {
                appState.resetMaskEdits()
            } label: {
                paletteIcon("arrow.counterclockwise", selected: false)
            }
            .buttonStyle(.plain)
            .disabled(!appState.hasManualMaskEdits)
            .help("Сбросить правки маски выбранного слоя")

            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.secondary.opacity(0.18))
        }
    }

    private var selectedLayer: AppState.ImageLayer? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.first(where: { $0.id == selectedLayerID })
    }

    private var canEdit: Bool {
        guard let selectedLayer else { return false }
        return selectedLayer.isVisible && !selectedLayer.isProcessing
    }

    private var maskToolIsSelected: Bool {
        appState.maskTool == .erase || appState.maskTool == .restore
    }

    private func paletteIcon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 34, height: 34)
            .background(
                selected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

private struct SelectedLayerInspector: View {
    @ObservedObject var appState: AppState
    let layerID: UUID
    @State private var showsCanvasAnchors = false
    @State private var showsEdgeSettings = false

    var body: some View {
        if let layer = currentLayer,
           let pixelImage = layer.originalImage.pixelCGImage {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: layer.kind == .object ? "photo" : "rectangle.inset.filled")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(layer.sourceURL?.lastPathComponent ?? layer.name)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(layer.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        appState.deselectLayer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Снять выделение (Esc)")
                }

                Divider()

                HStack {
                    Text("Размер")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Пропорции сохраняются")
                }

                HStack(spacing: 6) {
                    numericField(
                        title: "Ш",
                        value: layerWidthBinding(baseWidth: CGFloat(pixelImage.width)),
                        suffix: "px"
                    )
                    Text("×")
                        .foregroundStyle(.secondary)
                    numericField(
                        title: "В",
                        value: layerHeightBinding(baseHeight: CGFloat(pixelImage.height)),
                        suffix: "px"
                    )
                }

                HStack(spacing: 8) {
                    Text("Положение центра")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    Button {
                        showsCanvasAnchors.toggle()
                    } label: {
                        Image(systemName: "square.grid.3x3")
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Выровнять слой относительно холста")
                    .popover(isPresented: $showsCanvasAnchors, arrowEdge: .trailing) {
                        CanvasAnchorPopover(
                            appState: appState,
                            layerID: layerID
                        )
                    }
                }

                HStack(spacing: 6) {
                    numericField(
                        title: "X",
                        value: layerPositionXBinding,
                        suffix: "px"
                    )
                    numericField(
                        title: "Y",
                        value: layerPositionYBinding,
                        suffix: "px"
                    )
                }

                HStack(spacing: 8) {
                    Text("Масштаб")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField(
                        "",
                        value: layerScaleBinding,
                        format: .number.precision(.fractionLength(0))
                    )
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    Text("%")
                        .foregroundStyle(.secondary)
                }

                if layer.kind == .object {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("Край")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        if layer.isRefining {
                            ProgressView()
                                .controlSize(.mini)
                                .help("Обновляем край")
                        }

                        Text(layer.edgeSettings.isAutomatic ? "Авто" : "Вручную")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            showsEdgeSettings.toggle()
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Настроить край")
                        .popover(isPresented: $showsEdgeSettings, arrowEdge: .trailing) {
                            EdgeSettingsPopover(
                                appState: appState,
                                layerID: layerID
                            )
                        }
                    }
                }
            }
            .controlSize(.small)
            .padding(12)
            .frame(width: 286)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.secondary.opacity(0.22))
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    private var currentLayer: AppState.ImageLayer? {
        appState.layers.first(where: { $0.id == layerID })
    }

    private var layerScaleBinding: Binding<Double> {
        Binding(
            get: {
                Double((currentLayer?.scale ?? 1) * 100)
            },
            set: { percentage in
                guard percentage.isFinite else { return }
                appState.setLayerScale(layerID, scale: CGFloat(percentage / 100))
            }
        )
    }

    private var layerPositionXBinding: Binding<Double> {
        Binding(
            get: {
                Double(appState.canvasSize.width / 2 + (currentLayer?.offset.width ?? 0))
            },
            set: { position in
                guard position.isFinite, let layer = currentLayer else { return }
                appState.moveLayer(
                    layerID,
                    to: CGSize(
                        width: CGFloat(position) - appState.canvasSize.width / 2,
                        height: layer.offset.height
                    )
                )
            }
        )
    }

    private var layerPositionYBinding: Binding<Double> {
        Binding(
            get: {
                Double(appState.canvasSize.height / 2 + (currentLayer?.offset.height ?? 0))
            },
            set: { position in
                guard position.isFinite, let layer = currentLayer else { return }
                appState.moveLayer(
                    layerID,
                    to: CGSize(
                        width: layer.offset.width,
                        height: CGFloat(position) - appState.canvasSize.height / 2
                    )
                )
            }
        )
    }

    private func layerWidthBinding(baseWidth: CGFloat) -> Binding<Double> {
        Binding(
            get: {
                Double(baseWidth * (currentLayer?.scale ?? 1))
            },
            set: { width in
                guard width.isFinite, width > 0, baseWidth > 0 else { return }
                appState.setLayerScale(layerID, scale: CGFloat(width) / baseWidth)
            }
        )
    }

    private func layerHeightBinding(baseHeight: CGFloat) -> Binding<Double> {
        Binding(
            get: {
                Double(baseHeight * (currentLayer?.scale ?? 1))
            },
            set: { height in
                guard height.isFinite, height > 0, baseHeight > 0 else { return }
                appState.setLayerScale(layerID, scale: CGFloat(height) / baseHeight)
            }
        )
    }

    private func numericField(
        title: String,
        value: Binding<Double>,
        suffix: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                "",
                value: value,
                format: .number.precision(.fractionLength(0))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 66)
            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CanvasAnchorPopover: View {
    @ObservedObject var appState: AppState
    let layerID: UUID
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(
        repeating: GridItem(.fixed(42), spacing: 8),
        count: 3
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Выровнять по холсту")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AppState.CanvasAnchor.allCases) { anchor in
                    Button {
                        appState.alignLayer(layerID, to: anchor)
                        dismiss()
                    } label: {
                        Image(systemName: anchor.symbolName)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .help(anchor.title)
                    .accessibilityLabel(anchor.title)
                }
            }

            Text("X и Y показывают координаты центра слоя от левого верхнего угла холста.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(canvasSizeTitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 210)
    }

    private var canvasSizeTitle: String {
        "Холст: \(Int(appState.canvasSize.width.rounded())) × \(Int(appState.canvasSize.height.rounded())) px"
    }
}

private struct EdgeSettingsPopover: View {
    @ObservedObject var appState: AppState
    let layerID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Обработка края")
                    .font(.headline)

                Spacer()

                if currentLayer?.isRefining == true {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle("Подбирать автоматически", isOn: automaticBinding)
                .toggleStyle(.switch)

            if let layer = currentLayer {
                if layer.edgeSettings.isAutomatic {
                    Text("Сглаживание и очистка цветного ореола подбираются под разрешение изображения.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    edgeSlider(
                        title: "Сглаживание",
                        value: featherBinding,
                        range: 0...3,
                        step: 0.1,
                        valueText: String(format: "%.1f px", layer.edgeSettings.feather)
                    )

                    edgeSlider(
                        title: "Сдвиг края",
                        value: shiftBinding,
                        range: -2...2,
                        step: 0.1,
                        valueText: String(format: "%+.1f px", layer.edgeSettings.shift)
                    )

                    edgeSlider(
                        title: "Очистка ореола",
                        value: cleanupBinding,
                        range: 0...1,
                        step: 0.05,
                        valueText: "\(Int((layer.edgeSettings.haloCleanup * 100).rounded()))%"
                    )
                }

                Divider()

                Button {
                    appState.resetLayerEdgeSettings(layerID)
                } label: {
                    Label("Вернуть автоматические настройки", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.plain)
                .disabled(layer.edgeSettings == .standard || layer.isProcessing)
            }
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 300)
        .disabled(currentLayer?.isProcessing == true)
    }

    private var currentLayer: AppState.ImageLayer? {
        appState.layers.first(where: { $0.id == layerID })
    }

    private var automaticBinding: Binding<Bool> {
        Binding(
            get: { currentLayer?.edgeSettings.isAutomatic ?? true },
            set: { appState.setLayerEdgeAutomatic(layerID, isAutomatic: $0) }
        )
    }

    private var featherBinding: Binding<Double> {
        Binding(
            get: { currentLayer?.edgeSettings.feather ?? 0.8 },
            set: { appState.setLayerEdgeFeather(layerID, feather: $0) }
        )
    }

    private var shiftBinding: Binding<Double> {
        Binding(
            get: { currentLayer?.edgeSettings.shift ?? -0.25 },
            set: { appState.setLayerEdgeShift(layerID, shift: $0) }
        )
    }

    private var cleanupBinding: Binding<Double> {
        Binding(
            get: { currentLayer?.edgeSettings.haloCleanup ?? 0.9 },
            set: { appState.setLayerHaloCleanup(layerID, cleanup: $0) }
        )
    }

    private func edgeSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range, step: step)
        }
    }
}

private struct CompositionSurface: View {
    @ObservedObject var appState: AppState
    let background: AppState.PreviewBackground
    let useOriginals: Bool
    let allowsLayerEditing: Bool
    let allowsMaskPainting: Bool
    let label: String
    @Binding var viewport: SurfaceViewport
    let onInteraction: () -> Void

    @State private var pinchStartZoom: CGFloat?
    @State private var draggingLayerID: UUID?
    @State private var draggingLayerStartOffset: CGSize?
    @State private var activeResize: LayerResizeState?
    @State private var activeStrokeLocations: [CGPoint] = []
    @State private var activeStrokePoints: [CGPoint] = []
    @State private var brushCursorLocation: CGPoint?

    private let minimumZoom: CGFloat = 0.1
    private let maximumZoom: CGFloat = 8
    private let canvasOverscrollRatio: CGFloat = 0.35
    private let minimumCanvasOverscroll: CGFloat = 100
    private let maximumCanvasOverscroll: CGFloat = 700

    var body: some View {
        GeometryReader { geometry in
            let layout = makeLayout(in: geometry.size)

            ZStack {
                Color(nsColor: .controlBackgroundColor)

                compositionCanvas(layout: layout)

                if allowsLayerEditing {
                    selectionOverlay(layout: layout)
                        .allowsHitTesting(false)
                }

                if isPaintingMask {
                    brushOverlay
                        .allowsHitTesting(false)
                }

                if !label.isEmpty {
                    VStack {
                        HStack {
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThickMaterial, in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .allowsHitTesting(false)
                }

                zoomControls

                TrackpadPanCapture { translation in
                    onInteraction()
                    let proposed = CGSize(
                        width: layout.canvasOffset.width + translation.width,
                        height: layout.canvasOffset.height + translation.height
                    )
                    let constrainedOffset = constrainedCameraOffset(
                        proposed,
                        renderedCanvasSize: layout.renderedCanvasSize,
                        viewportSize: layout.viewportSize
                    )
                    guard layout.projection > 0 else { return }
                    var updatedViewport = viewport
                    updatedViewport.centerOffset = CGSize(
                        width: constrainedOffset.width / layout.projection,
                        height: constrainedOffset.height / layout.projection
                    )
                    viewport = updatedViewport
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(surfaceDragGesture(layout: layout))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        onInteraction()
                        if pinchStartZoom == nil {
                            pinchStartZoom = viewport.zoomScale
                        }
                        var updatedViewport = viewport
                        updatedViewport.zoomScale = clampedZoom(
                            (pinchStartZoom ?? viewport.zoomScale) * value
                        )
                        viewport = updatedViewport
                    }
                    .onEnded { _ in
                        pinchStartZoom = nil
                    }
            )
            .onTapGesture(count: 2) {
                guard appState.maskTool == .pan else { return }
                onInteraction()
                resetViewport()
            }
            .onContinuousHover { phase in
                updateBrushCursor(for: phase, layout: layout)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.secondary.opacity(0.18))
        }
    }

    private var visibleZoomScale: CGFloat {
        clampedZoom(viewport.zoomScale)
    }

    private var selectedLayer: AppState.ImageLayer? {
        guard let selectedLayerID = appState.selectedLayerID else { return nil }
        return appState.layers.first(where: { $0.id == selectedLayerID })
    }

    private var isPaintingMask: Bool {
        guard allowsMaskPainting,
              !useOriginals,
              appState.maskTool != .pan,
              let selectedLayer else {
            return false
        }
        return selectedLayer.isVisible && !selectedLayer.isProcessing
    }

    private var canTransformLayer: Bool {
        allowsLayerEditing && (appState.maskTool == .pan || !allowsMaskPainting)
    }

    private var brushColor: Color {
        appState.maskTool == .restore ? .green : .red
    }

    private func compositionCanvas(layout: SurfaceLayout) -> some View {
        ZStack {
            PreviewBackgroundView(style: background)

            ForEach(appState.layers) { layer in
                layerContent(layer, layout: layout)
            }
        }
        .frame(
            width: layout.renderedCanvasSize.width,
            height: layout.renderedCanvasSize.height
        )
        .clipped()
        .position(
            x: layout.canvasRect.midX,
            y: layout.canvasRect.midY
        )
    }

    @ViewBuilder
    private func layerContent(_ layer: AppState.ImageLayer, layout: SurfaceLayout) -> some View {
        if layer.isVisible,
           let pixelImage = (useOriginals ? layer.originalImage : layer.resultImage).pixelCGImage {
            let renderedSize = CGSize(
                width: CGFloat(pixelImage.width) * layer.scale * layout.projection,
                height: CGFloat(pixelImage.height) * layer.scale * layout.projection
            )
            let position = CGPoint(
                x: layout.renderedCanvasSize.width / 2 + layer.offset.width * layout.projection,
                y: layout.renderedCanvasSize.height / 2 + layer.offset.height * layout.projection
            )

            if isPaintingMask,
               appState.maskTool == .restore,
               layer.id == appState.selectedLayerID {
                Image(nsImage: layer.originalImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: renderedSize.width, height: renderedSize.height)
                    .position(position)
                    .opacity(0.22)
            }

            Image(nsImage: useOriginals ? layer.originalImage : layer.resultImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: renderedSize.width, height: renderedSize.height)
                .position(position)

        }
    }

    @ViewBuilder
    private func selectionOverlay(layout: SurfaceLayout) -> some View {
        if let selectedLayer,
           selectedLayer.isVisible,
           let selectionRect = layerRect(for: selectedLayer, layout: layout) {
            Rectangle()
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .frame(width: selectionRect.width, height: selectionRect.height)
                .position(x: selectionRect.midX, y: selectionRect.midY)

            if canTransformLayer, !selectedLayer.isProcessing {
                ForEach(ResizeCorner.allCases, id: \.self) { corner in
                    let point = corner.point(in: selectionRect)
                    Circle()
                        .fill(.background)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                        .frame(width: 11, height: 11)
                        .position(point)
                }
            }
        }
    }

    private var brushOverlay: some View {
        Canvas { context, _ in
            let diameter = CGFloat(appState.brushDiameter)

            if let cursor = brushCursorLocation {
                let cursorRect = CGRect(
                    x: cursor.x - diameter / 2,
                    y: cursor.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.stroke(
                    Path(ellipseIn: cursorRect),
                    with: .color(brushColor.opacity(0.95)),
                    lineWidth: 1.5
                )
            }

            guard !activeStrokeLocations.isEmpty else { return }

            if activeStrokeLocations.count == 1, let point = activeStrokeLocations.first {
                let dabRect = CGRect(
                    x: point.x - diameter / 2,
                    y: point.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: dabRect),
                    with: .color(brushColor.opacity(0.3))
                )
            } else {
                var path = Path()
                if let first = activeStrokeLocations.first {
                    path.move(to: first)
                    for point in activeStrokeLocations.dropFirst() {
                        path.addLine(to: point)
                    }
                    context.stroke(
                        path,
                        with: .color(brushColor.opacity(0.3)),
                        style: StrokeStyle(
                            lineWidth: diameter,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
    }

    private var zoomControls: some View {
        VStack {
            Spacer()
            HStack {
                HStack(spacing: 3) {
                    Button {
                        changeZoom(by: 0.8)
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Отдалить")

                    Text("\(Int((visibleZoomScale * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48)

                    Button {
                        changeZoom(by: 1.25)
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Приблизить")

                    Button {
                        resetViewport()
                    } label: {
                        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Вписать холст")
                }
                .padding(5)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.secondary.opacity(0.2))
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private func surfaceDragGesture(layout: SurfaceLayout) -> some Gesture {
        DragGesture(minimumDistance: isPaintingMask ? 0 : 1)
            .onChanged { value in
                if isPaintingMask {
                    onInteraction()
                    appendBrushPoint(value.location, layout: layout)
                    return
                }

                guard canTransformLayer else { return }
                onInteraction()

                if activeResize == nil,
                   draggingLayerID == nil,
                   let resizeCorner = resizeCorner(
                       at: value.startLocation,
                       layout: layout
                   ),
                   let resizeState = makeResizeState(for: resizeCorner) {
                    activeResize = resizeState
                }

                if let activeResize {
                    applyResize(
                        activeResize,
                        translation: value.translation,
                        projection: layout.projection
                    )
                    return
                }

                if draggingLayerID == nil {
                    guard let hitLayerID = hitTestLayer(
                        at: value.startLocation,
                        layout: layout
                    ),
                    let layer = appState.layers.first(where: { $0.id == hitLayerID }) else {
                        appState.deselectLayer()
                        return
                    }
                    appState.selectLayer(hitLayerID)
                    draggingLayerID = hitLayerID
                    draggingLayerStartOffset = layer.offset
                }

                guard let draggingLayerID,
                      let draggingLayerStartOffset,
                      layout.projection > 0 else {
                    return
                }

                appState.moveLayer(
                    draggingLayerID,
                    to: CGSize(
                        width: draggingLayerStartOffset.width + value.translation.width / layout.projection,
                        height: draggingLayerStartOffset.height + value.translation.height / layout.projection
                    )
                )
            }
            .onEnded { value in
                if isPaintingMask {
                    appendBrushPoint(value.location, layout: layout)
                    finishBrushStroke(layout: layout)
                }
                draggingLayerID = nil
                draggingLayerStartOffset = nil
                activeResize = nil
            }
    }

    private func resizeCorner(
        at location: CGPoint,
        layout: SurfaceLayout
    ) -> ResizeCorner? {
        guard canTransformLayer,
              let selectedLayer,
              selectedLayer.isVisible,
              !selectedLayer.isProcessing,
              let selectionRect = layerRect(for: selectedLayer, layout: layout) else {
            return nil
        }

        let hitRadius: CGFloat = 14
        for corner in ResizeCorner.allCases {
            let point = corner.point(in: selectionRect)
            if abs(location.x - point.x) <= hitRadius,
               abs(location.y - point.y) <= hitRadius {
                return corner
            }
        }
        return nil
    }

    private func makeResizeState(for corner: ResizeCorner) -> LayerResizeState? {
        guard let selectedLayer,
              let image = selectedLayer.originalImage.pixelCGImage else {
            return nil
        }

        let signs = corner.signs
        let scaledWidth = CGFloat(image.width) * selectedLayer.scale
        let scaledHeight = CGFloat(image.height) * selectedLayer.scale
        let halfWidth = scaledWidth / 2
        let halfHeight = scaledHeight / 2
        let anchor = CGPoint(
            x: selectedLayer.offset.width - signs.x * halfWidth,
            y: selectedLayer.offset.height - signs.y * halfHeight
        )
        let initialVector = CGSize(
            width: signs.x * scaledWidth,
            height: signs.y * scaledHeight
        )

        return LayerResizeState(
            layerID: selectedLayer.id,
            initialScale: selectedLayer.scale,
            anchor: anchor,
            initialVector: initialVector
        )
    }

    private func applyResize(
        _ resize: LayerResizeState,
        translation: CGSize,
        projection: CGFloat
    ) {
        guard projection > 0, resize.initialScale > 0 else { return }

        let canvasTranslation = CGSize(
            width: translation.width / projection,
            height: translation.height / projection
        )
        let candidateVector = CGSize(
            width: resize.initialVector.width + canvasTranslation.width,
            height: resize.initialVector.height + canvasTranslation.height
        )
        let denominator =
            resize.initialVector.width * resize.initialVector.width +
            resize.initialVector.height * resize.initialVector.height
        guard denominator > 0 else { return }

        let ratio = (
            candidateVector.width * resize.initialVector.width +
            candidateVector.height * resize.initialVector.height
        ) / denominator
        guard ratio.isFinite else { return }

        let newScale = min(
            max(
                resize.initialScale * ratio,
                AppState.minimumLayerScale
            ),
            AppState.maximumLayerScale
        )
        let appliedRatio = newScale / resize.initialScale
        let newOffset = CGSize(
            width: resize.anchor.x + resize.initialVector.width * appliedRatio / 2,
            height: resize.anchor.y + resize.initialVector.height * appliedRatio / 2
        )
        appState.setLayerTransform(
            resize.layerID,
            offset: newOffset,
            scale: newScale
        )
    }

    private func hitTestLayer(at location: CGPoint, layout: SurfaceLayout) -> UUID? {
        guard layout.canvasRect.contains(location) else { return nil }

        for layer in appState.layers.reversed() where layer.isVisible {
            if let rect = layerRect(for: layer, layout: layout),
               rect.contains(location) {
                return layer.id
            }
        }
        return nil
    }

    private func appendBrushPoint(_ location: CGPoint, layout: SurfaceLayout) {
        guard let selectedLayer,
              let imageRect = layerRect(for: selectedLayer, layout: layout),
              imageRect.width > 0,
              imageRect.height > 0,
              imageRect.contains(location),
              layout.canvasRect.contains(location) else {
            return
        }

        if let previous = activeStrokeLocations.last {
            let deltaX = location.x - previous.x
            let deltaY = location.y - previous.y
            guard deltaX * deltaX + deltaY * deltaY >= 1 else { return }
        }

        activeStrokeLocations.append(location)
        activeStrokePoints.append(CGPoint(
            x: (location.x - imageRect.minX) / imageRect.width,
            y: (location.y - imageRect.minY) / imageRect.height
        ))
    }

    private func finishBrushStroke(layout: SurfaceLayout) {
        defer { cancelActiveStroke() }

        guard let selectedLayer,
              !activeStrokePoints.isEmpty,
              let imageRect = layerRect(for: selectedLayer, layout: layout),
              imageRect.width > 0,
              let pixelImage = selectedLayer.resultImage.pixelCGImage else {
            return
        }

        let radius = CGFloat(appState.brushDiameter) *
            CGFloat(pixelImage.width) / imageRect.width / 2
        appState.applyMaskStroke(
            normalizedPoints: activeStrokePoints,
            radius: radius
        )
    }

    private func cancelActiveStroke() {
        activeStrokeLocations.removeAll(keepingCapacity: true)
        activeStrokePoints.removeAll(keepingCapacity: true)
        brushCursorLocation = nil
    }

    private func updateBrushCursor(
        for phase: HoverPhase,
        layout: SurfaceLayout
    ) {
        guard isPaintingMask,
              let selectedLayer,
              let imageRect = layerRect(for: selectedLayer, layout: layout) else {
            brushCursorLocation = nil
            return
        }

        switch phase {
        case .active(let location):
            brushCursorLocation = imageRect.contains(location) &&
                layout.canvasRect.contains(location) ? location : nil
        case .ended:
            brushCursorLocation = nil
        }
    }

    private func layerRect(
        for layer: AppState.ImageLayer,
        layout: SurfaceLayout
    ) -> CGRect? {
        let image = useOriginals ? layer.originalImage : layer.resultImage
        guard let pixelImage = image.pixelCGImage else { return nil }

        let width = CGFloat(pixelImage.width) * layer.scale * layout.projection
        let height = CGFloat(pixelImage.height) * layer.scale * layout.projection
        return CGRect(
            x: layout.canvasRect.midX + layer.offset.width * layout.projection - width / 2,
            y: layout.canvasRect.midY + layer.offset.height * layout.projection - height / 2,
            width: width,
            height: height
        )
    }

    private func makeLayout(in size: CGSize) -> SurfaceLayout {
        let viewportSize = CGSize(
            width: max(size.width - 48, 1),
            height: max(size.height - 48, 1)
        )
        let width = max(appState.canvasSize.width, 1)
        let height = max(appState.canvasSize.height, 1)
        let fitScale = min(
            viewportSize.width / width,
            viewportSize.height / height
        )
        let projection = max(fitScale * visibleZoomScale, 0.0001)
        let renderedCanvasSize = CGSize(
            width: width * projection,
            height: height * projection
        )
        let desiredOffset = CGSize(
            width: viewport.centerOffset.width * projection,
            height: viewport.centerOffset.height * projection
        )
        let displayedOffset = constrainedCameraOffset(
            desiredOffset,
            renderedCanvasSize: renderedCanvasSize,
            viewportSize: viewportSize
        )
        let canvasRect = CGRect(
            x: size.width / 2 + displayedOffset.width - renderedCanvasSize.width / 2,
            y: size.height / 2 + displayedOffset.height - renderedCanvasSize.height / 2,
            width: renderedCanvasSize.width,
            height: renderedCanvasSize.height
        )

        return SurfaceLayout(
            viewportSize: viewportSize,
            projection: projection,
            renderedCanvasSize: renderedCanvasSize,
            canvasOffset: displayedOffset,
            canvasRect: canvasRect
        )
    }

    private func constrainedCameraOffset(
        _ proposed: CGSize,
        renderedCanvasSize: CGSize,
        viewportSize: CGSize
    ) -> CGSize {
        let horizontalCanvasSpace = min(
            max(viewportSize.width * canvasOverscrollRatio, minimumCanvasOverscroll),
            maximumCanvasOverscroll
        )
        let verticalCanvasSpace = min(
            max(viewportSize.height * canvasOverscrollRatio, minimumCanvasOverscroll),
            maximumCanvasOverscroll
        )
        let maximumX = abs(viewportSize.width - renderedCanvasSize.width) / 2 +
            horizontalCanvasSpace
        let maximumY = abs(viewportSize.height - renderedCanvasSize.height) / 2 +
            verticalCanvasSpace

        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

    private func changeZoom(by multiplier: CGFloat) {
        onInteraction()
        withAnimation(.snappy(duration: 0.2)) {
            var updatedViewport = viewport
            updatedViewport.zoomScale = clampedZoom(
                viewport.zoomScale * multiplier
            )
            viewport = updatedViewport
        }
    }

    private func resetViewport(animated: Bool = true) {
        let changes = {
            onInteraction()
            viewport = SurfaceViewport()
        }

        if animated {
            withAnimation(.snappy(duration: 0.2)) {
                changes()
            }
        } else {
            changes()
        }
    }

    private enum ResizeCorner: CaseIterable, Hashable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var signs: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: -1, y: -1)
            case .topRight: CGPoint(x: 1, y: -1)
            case .bottomLeft: CGPoint(x: -1, y: 1)
            case .bottomRight: CGPoint(x: 1, y: 1)
            }
        }

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft:
                CGPoint(x: rect.minX, y: rect.minY)
            case .topRight:
                CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft:
                CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight:
                CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    private struct LayerResizeState {
        let layerID: UUID
        let initialScale: CGFloat
        let anchor: CGPoint
        let initialVector: CGSize
    }

    private struct SurfaceLayout {
        let viewportSize: CGSize
        let projection: CGFloat
        let renderedCanvasSize: CGSize
        let canvasOffset: CGSize
        let canvasRect: CGRect
    }
}

private struct TrackpadPanCapture: NSViewRepresentable {
    let onPan: (CGSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPan: onPan)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onPan = onPan
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onPan: (CGSize) -> Void

        private var eventMonitor: Any?

        init(onPan: @escaping (CGSize) -> Void) {
            self.onPan = onPan
        }

        func installMonitor() {
            guard eventMonitor == nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.hasPreciseScrollingDeltas,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }

                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else { return event }

                self.onPan(CGSize(
                    width: event.scrollingDeltaX,
                    height: event.scrollingDeltaY
                ))
                return nil
            }
        }

        func removeMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private struct WorkspaceKeyboardShortcutCapture: NSViewRepresentable {
    let canEditMask: Bool
    let canUndoMaskEdit: Bool
    let canRedoMaskEdit: Bool
    let selectTool: (AppState.MaskTool) -> Void
    let selectPreview: (AppState.PreviewMode) -> Void
    let undoMaskEdit: () -> Void
    let redoMaskEdit: () -> Void
    let deselectLayer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canEditMask: canEditMask,
            canUndoMaskEdit: canUndoMaskEdit,
            canRedoMaskEdit: canRedoMaskEdit,
            selectTool: selectTool,
            selectPreview: selectPreview,
            undoMaskEdit: undoMaskEdit,
            redoMaskEdit: redoMaskEdit,
            deselectLayer: deselectLayer
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.canEditMask = canEditMask
        context.coordinator.canUndoMaskEdit = canUndoMaskEdit
        context.coordinator.canRedoMaskEdit = canRedoMaskEdit
        context.coordinator.selectTool = selectTool
        context.coordinator.selectPreview = selectPreview
        context.coordinator.undoMaskEdit = undoMaskEdit
        context.coordinator.redoMaskEdit = redoMaskEdit
        context.coordinator.deselectLayer = deselectLayer
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var canEditMask: Bool
        var canUndoMaskEdit: Bool
        var canRedoMaskEdit: Bool
        var selectTool: (AppState.MaskTool) -> Void
        var selectPreview: (AppState.PreviewMode) -> Void
        var undoMaskEdit: () -> Void
        var redoMaskEdit: () -> Void
        var deselectLayer: () -> Void

        private var eventMonitor: Any?
        private var tabIsHeld = false

        init(
            canEditMask: Bool,
            canUndoMaskEdit: Bool,
            canRedoMaskEdit: Bool,
            selectTool: @escaping (AppState.MaskTool) -> Void,
            selectPreview: @escaping (AppState.PreviewMode) -> Void,
            undoMaskEdit: @escaping () -> Void,
            redoMaskEdit: @escaping () -> Void,
            deselectLayer: @escaping () -> Void
        ) {
            self.canEditMask = canEditMask
            self.canUndoMaskEdit = canUndoMaskEdit
            self.canRedoMaskEdit = canRedoMaskEdit
            self.selectTool = selectTool
            self.selectPreview = selectPreview
            self.undoMaskEdit = undoMaskEdit
            self.redoMaskEdit = redoMaskEdit
            self.deselectLayer = deselectLayer
        }

        func installMonitor() {
            guard eventMonitor == nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }

                if event.keyCode == 48 {
                    tabIsHeld = event.type == .keyDown
                    return nil
                }

                guard event.type == .keyDown, !event.isARepeat else { return event }

                if tabIsHeld {
                    switch event.keyCode {
                    case 18:
                        selectPreview(.original)
                        return nil
                    case 19:
                        selectPreview(.result)
                        return nil
                    case 20:
                        selectPreview(.comparison)
                        return nil
                    default:
                        break
                    }
                }

                let modifiers = event.modifierFlags.intersection([
                    .command,
                    .control,
                    .option,
                    .shift
                ])
                if event.keyCode == 53,
                   modifiers.isEmpty,
                   !(window.firstResponder is NSTextView) {
                    deselectLayer()
                    return nil
                }
                if event.keyCode == 6,
                   modifiers == .command,
                   canUndoMaskEdit {
                    undoMaskEdit()
                    return nil
                }
                if event.keyCode == 6,
                   modifiers == [.command, .shift],
                   canRedoMaskEdit {
                    redoMaskEdit()
                    return nil
                }

                guard modifiers.isEmpty, canEditMask else { return event }
                switch event.keyCode {
                case 9:
                    selectTool(.pan)
                    return nil
                case 7:
                    selectTool(.erase)
                    return nil
                case 11:
                    selectTool(.restore)
                    return nil
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

private struct PreviewBackgroundView: View {
    let style: AppState.PreviewBackground

    var body: some View {
        switch style {
        case .checkerboard:
            CheckerboardView()
        case .white:
            Color.white
        case .black:
            Color.black
        }
    }
}

private struct CheckerboardView: View {
    var squareSize: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white)
            )

            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(Color.gray.opacity(0.28))
                    )
                }
            }
        }
    }
}
