import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(appState: appState)
                .navigationSplitViewColumnWidth(min: 245, ideal: 275, max: 315)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()

                if appState.originalImage == nil {
                    EmptyDropView(isTargeted: isDropTargeted) {
                        appState.openImagePicker()
                    }
                } else {
                    PreviewWorkspace(appState: appState)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first,
                      UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                    return false
                }
                appState.loadImage(from: url)
                return true
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }
            .overlay {
                if isDropTargeted, appState.originalImage != nil {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 4, dash: [10, 8]))
                        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onOpenURL { url in
            appState.loadImage(from: url)
        }
        .alert("Что-то пошло не так", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
            if appState.originalImage != nil {
                Button("Попробовать ещё раз") {
                    appState.removeBackground()
                }
            }
        } message: {
            Text(appState.errorMessage ?? "Неизвестная ошибка")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.openImagePicker()
                } label: {
                    Label("Открыть", systemImage: "photo.badge.plus")
                }

                Button {
                    appState.exportResult()
                } label: {
                    Label("Экспортировать", systemImage: "square.and.arrow.down")
                }
                .disabled(appState.resultImage == nil || appState.isProcessing)
            }
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Фон — долой!", systemImage: "wand.and.sparkles")
                .font(.title2.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 22)

            Divider()

            if appState.originalImage != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ИЗОБРАЖЕНИЕ")
                                .sectionLabelStyle()
                            Text(appState.sourceName)
                                .font(.callout.weight(.medium))
                                .lineLimit(2)
                            if let details = appState.sourceDetails {
                                Text(details)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("ПРОСМОТР")
                                .sectionLabelStyle()
                            Picker("Режим просмотра", selection: $appState.previewMode) {
                                ForEach(AppState.PreviewMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("ФОН ПРЕДПРОСМОТРА")
                                .sectionLabelStyle()
                            Picker("Фон предпросмотра", selection: $appState.previewBackground) {
                                ForEach(AppState.PreviewBackground.allCases) { background in
                                    Text(background.title).tag(background)
                                }
                            }
                            .labelsHidden()
                        }

                        if appState.resultImage != nil, !appState.isProcessing {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("КОРРЕКЦИЯ МАСКИ")
                                    .sectionLabelStyle()

                                Picker("Инструмент", selection: $appState.maskTool) {
                                    ForEach(AppState.MaskTool.allCases) { tool in
                                        Label(tool.title, systemImage: tool.symbolName)
                                            .tag(tool)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)

                                if appState.maskTool != .pan {
                                    HStack(spacing: 10) {
                                        Image(systemName: "circle")
                                            .font(.system(size: 7))

                                        Slider(value: $appState.brushDiameter, in: 8...180)

                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 15))
                                    }
                                    .foregroundStyle(.secondary)

                                    HStack {
                                        Text("Кисть")
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("\(Int(appState.brushDiameter.rounded())) pt")
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.caption)
                                }

                                Button {
                                    appState.resetMaskEdits()
                                } label: {
                                    Label("Сбросить правки", systemImage: "arrow.uturn.backward")
                                        .frame(maxWidth: .infinity)
                                }
                                .disabled(!appState.hasManualMaskEdits)
                            }
                        }

                        VStack(spacing: 10) {
                            Button {
                                appState.exportResult()
                            } label: {
                                Label("Сохранить PNG", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(appState.resultImage == nil || appState.isProcessing)

                            HStack(spacing: 8) {
                                Button {
                                    appState.copyResult()
                                } label: {
                                    Label("Копировать", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .disabled(appState.resultImage == nil || appState.isProcessing)

                                Button {
                                    appState.clear()
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .help("Закрыть изображение")
                            }
                            .controlSize(.large)
                        }
                    }
                    .padding(18)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Перетащите фото в окно", systemImage: "arrow.down.doc")
                    Label("Или нажмите ⌘O", systemImage: "command")
                    Label("Можно вставить через ⌘V", systemImage: "doc.on.clipboard")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(18)

                Spacer()
            }

            Spacer(minLength: 0)
        }
        .background(.regularMaterial)
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

private struct PreviewWorkspace: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.isProcessing ? "Отделяем объект от фона…" : "Готово")
                        .font(.headline)
                    Text(appState.isProcessing ? "Apple Vision анализирует изображение на этом Mac" : "Экспорт сохраняет прозрачность в PNG")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !appState.isProcessing {
                    Button {
                        appState.removeBackground()
                    } label: {
                        Label("Обработать снова", systemImage: "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 4)

            Group {
                switch appState.previewMode {
                case .result:
                    PreviewSurface(
                        image: isMaskPainting
                            ? appState.resultImage
                            : appState.resultPreviewImage ?? appState.resultImage ?? appState.originalImage,
                        background: appState.previewBackground,
                        label: "Результат",
                        viewportIdentity: sourceIdentity,
                        maskEditing: maskEditingConfiguration
                    )
                case .original:
                    PreviewSurface(
                        image: appState.originalImage,
                        background: .white,
                        label: "Оригинал",
                        viewportIdentity: sourceIdentity
                    )
                case .comparison:
                    HStack(spacing: 12) {
                        PreviewSurface(
                            image: appState.originalImage,
                            background: .white,
                            label: "До",
                            viewportIdentity: sourceIdentity
                        )
                        PreviewSurface(
                            image: appState.resultImage ?? appState.originalImage,
                            background: appState.previewBackground,
                            label: "После",
                            viewportIdentity: sourceIdentity
                        )
                    }
                }
            }
            .overlay {
                if appState.isProcessing {
                    ZStack {
                        Rectangle()
                            .fill(.black.opacity(0.18))
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Удаляем фон…")
                                .font(.headline)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(18)
    }

    private var sourceIdentity: ObjectIdentifier? {
        appState.originalImage.map(ObjectIdentifier.init)
    }

    private var isMaskPainting: Bool {
        appState.resultImage != nil && appState.maskTool != .pan
    }

    private var maskEditingConfiguration: MaskEditingConfiguration? {
        guard appState.resultImage != nil else { return nil }
        return MaskEditingConfiguration(
            tool: appState.maskTool,
            brushDiameter: CGFloat(appState.brushDiameter),
            originalImage: appState.originalImage
        ) { points, radius in
            appState.applyMaskStroke(normalizedPoints: points, radius: radius)
        }
    }
}

private struct MaskEditingConfiguration {
    let tool: AppState.MaskTool
    let brushDiameter: CGFloat
    let originalImage: NSImage?
    let applyStroke: ([CGPoint], CGFloat) -> Void
}

private struct PreviewSurface: View {
    let image: NSImage?
    let background: AppState.PreviewBackground
    let label: String
    let viewportIdentity: ObjectIdentifier?
    let maskEditing: MaskEditingConfiguration?

    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var activeStrokeLocations: [CGPoint] = []
    @State private var activeStrokePoints: [CGPoint] = []
    @State private var brushCursorLocation: CGPoint?
    @GestureState private var gestureMagnification: CGFloat = 1
    @GestureState private var gestureTranslation: CGSize = .zero

    private let minimumZoom: CGFloat = 0.25
    private let maximumZoom: CGFloat = 8

    init(
        image: NSImage?,
        background: AppState.PreviewBackground,
        label: String,
        viewportIdentity: ObjectIdentifier? = nil,
        maskEditing: MaskEditingConfiguration? = nil
    ) {
        self.image = image
        self.background = background
        self.label = label
        self.viewportIdentity = viewportIdentity
        self.maskEditing = maskEditing
    }

    var body: some View {
        ZStack {
            PreviewBackgroundView(style: background)

            if let image {
                interactiveImage(image)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if image != nil {
                zoomControls
                    .padding(12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2))
        }
        .onChange(of: viewportIdentity) { _, _ in
            resetViewport()
        }
        .onChange(of: isPaintingMask) { _, _ in
            cancelActiveStroke()
            resetViewport()
        }
    }

    private var visibleZoomScale: CGFloat {
        clampedZoom(zoomScale * gestureMagnification)
    }

    private var isPaintingMask: Bool {
        guard let tool = maskEditing?.tool else { return false }
        return tool == .erase || tool == .restore
    }

    private var brushColor: Color {
        maskEditing?.tool == .restore ? .green : .red
    }

    private var zoomControls: some View {
        HStack(spacing: 3) {
            Button {
                changeZoom(by: 1 / 1.25)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .help("Уменьшить")

            Button {
                resetViewport()
            } label: {
                Text("\(Int((zoomScale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 46)
            }
            .help("Вписать изображение")

            Button {
                changeZoom(by: 1.25)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .help("Увеличить")

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 3)

            Button {
                resetViewport()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 24, height: 24)
            }
            .help("Вернуть по центру")
        }
        .padding(5)
        .buttonStyle(.plain)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2))
        }
    }

    private func interactiveImage(_ image: NSImage) -> some View {
        GeometryReader { geometry in
            let viewportSize = CGSize(
                width: max(geometry.size.width - 48, 1),
                height: max(geometry.size.height - 48, 1)
            )
            let fittedSize = aspectFitSize(image.size, in: viewportSize)
            let proposedOffset = CGSize(
                width: panOffset.width + gestureTranslation.width,
                height: panOffset.height + gestureTranslation.height
            )
            let displayedOffset = constrainedOffset(
                proposedOffset,
                fittedSize: fittedSize,
                viewportSize: viewportSize,
                scale: visibleZoomScale
            )
            let renderedSize = CGSize(
                width: fittedSize.width * visibleZoomScale,
                height: fittedSize.height * visibleZoomScale
            )
            let imageRect = CGRect(
                x: geometry.size.width / 2 + displayedOffset.width - renderedSize.width / 2,
                y: geometry.size.height / 2 + displayedOffset.height - renderedSize.height / 2,
                width: renderedSize.width,
                height: renderedSize.height
            )

            ZStack {
                if maskEditing?.tool == .restore,
                   let originalImage = maskEditing?.originalImage {
                    positionedImage(
                        originalImage,
                        fittedSize: fittedSize,
                        displayedOffset: displayedOffset,
                        geometrySize: geometry.size
                    )
                    .opacity(0.22)
                }

                positionedImage(
                    image,
                    fittedSize: fittedSize,
                    displayedOffset: displayedOffset,
                    geometrySize: geometry.size
                )

                if isPaintingMask {
                    brushOverlay
                        .allowsHitTesting(false)
                }

                TrackpadPanCapture { translation in
                    let proposed = CGSize(
                        width: panOffset.width + translation.width,
                        height: panOffset.height + translation.height
                    )
                    panOffset = constrainedOffset(
                        proposed,
                        fittedSize: fittedSize,
                        viewportSize: viewportSize,
                        scale: zoomScale
                    )
                }
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: isPaintingMask ? 0 : 1)
                        .updating($gestureTranslation) { value, state, _ in
                            if !isPaintingMask {
                                state = value.translation
                            }
                        }
                        .onChanged { value in
                            if isPaintingMask {
                                appendBrushPoint(value.location, in: imageRect)
                            }
                        }
                        .onEnded { value in
                            if isPaintingMask {
                                appendBrushPoint(value.location, in: imageRect)
                                finishBrushStroke(on: image, imageRect: imageRect)
                            } else {
                                let proposed = CGSize(
                                    width: panOffset.width + value.translation.width,
                                    height: panOffset.height + value.translation.height
                                )
                                panOffset = constrainedOffset(
                                    proposed,
                                    fittedSize: fittedSize,
                                    viewportSize: viewportSize,
                                    scale: zoomScale
                                )
                            }
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($gestureMagnification) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            let newScale = clampedZoom(zoomScale * value)
                            zoomScale = newScale
                            panOffset = constrainedOffset(
                                panOffset,
                                fittedSize: fittedSize,
                                viewportSize: viewportSize,
                                scale: newScale
                            )
                        }
                )
                .onTapGesture(count: 2) {
                    if !isPaintingMask {
                        resetViewport()
                    }
                }
                .onContinuousHover { phase in
                    guard isPaintingMask else {
                        brushCursorLocation = nil
                        return
                    }

                    switch phase {
                    case .active(let location):
                        brushCursorLocation = imageRect.contains(location) ? location : nil
                    case .ended:
                        brushCursorLocation = nil
                    }
                }
                .animation(.snappy(duration: 0.2), value: zoomScale)
                .animation(.snappy(duration: 0.2), value: panOffset)
        }
        .clipped()
    }

    private func positionedImage(
        _ image: NSImage,
        fittedSize: CGSize,
        displayedOffset: CGSize,
        geometrySize: CGSize
    ) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: fittedSize.width, height: fittedSize.height)
            .scaleEffect(visibleZoomScale)
            .position(
                x: geometrySize.width / 2 + displayedOffset.width,
                y: geometrySize.height / 2 + displayedOffset.height
            )
    }

    private var brushOverlay: some View {
        Canvas { context, _ in
            if let cursor = brushCursorLocation,
               let diameter = maskEditing?.brushDiameter {
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

            guard !activeStrokeLocations.isEmpty,
                  let diameter = maskEditing?.brushDiameter else {
                return
            }

            if activeStrokeLocations.count == 1, let point = activeStrokeLocations.first {
                let dabRect = CGRect(
                    x: point.x - diameter / 2,
                    y: point.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(Path(ellipseIn: dabRect), with: .color(brushColor.opacity(0.3)))
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
                        style: StrokeStyle(lineWidth: diameter, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
    }

    private func appendBrushPoint(_ location: CGPoint, in imageRect: CGRect) {
        guard imageRect.width > 0,
              imageRect.height > 0,
              imageRect.contains(location) else {
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

    private func finishBrushStroke(on image: NSImage, imageRect: CGRect) {
        defer { cancelActiveStroke() }

        guard let maskEditing,
              !activeStrokePoints.isEmpty,
              imageRect.width > 0 else {
            return
        }

        let pixelWidth = CGFloat(image.pixelCGImage?.width ?? max(Int(image.size.width), 1))
        let radius = maskEditing.brushDiameter * pixelWidth / imageRect.width / 2
        maskEditing.applyStroke(activeStrokePoints, radius)
    }

    private func cancelActiveStroke() {
        activeStrokeLocations.removeAll(keepingCapacity: true)
        activeStrokePoints.removeAll(keepingCapacity: true)
        brushCursorLocation = nil
    }

    private func aspectFitSize(_ imageSize: CGSize, in viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return viewportSize }
        let scale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func constrainedOffset(
        _ proposed: CGSize,
        fittedSize: CGSize,
        viewportSize: CGSize,
        scale: CGFloat
    ) -> CGSize {
        let scaledWidth = fittedSize.width * scale
        let scaledHeight = fittedSize.height * scale
        let maximumX = abs(viewportSize.width - scaledWidth) / 2
        let maximumY = abs(viewportSize.height - scaledHeight) / 2

        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumZoom), maximumZoom)
    }

    private func changeZoom(by multiplier: CGFloat) {
        withAnimation(.snappy(duration: 0.2)) {
            zoomScale = clampedZoom(zoomScale * multiplier)
        }
    }

    private func resetViewport() {
        withAnimation(.snappy(duration: 0.2)) {
            zoomScale = 1
            panOffset = .zero
        }
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
    private let squareSize: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

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
                    context.fill(Path(rect), with: .color(Color.gray.opacity(0.28)))
                }
            }
        }
    }
}

private extension View {
    func sectionLabelStyle() -> some View {
        font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }
}
