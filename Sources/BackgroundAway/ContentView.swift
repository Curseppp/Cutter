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
                        image: appState.resultPreviewImage ?? appState.resultImage ?? appState.originalImage,
                        background: appState.previewBackground,
                        label: "Результат"
                    )
                case .original:
                    PreviewSurface(
                        image: appState.originalImage,
                        background: .white,
                        label: "Оригинал"
                    )
                case .comparison:
                    HStack(spacing: 12) {
                        PreviewSurface(
                            image: appState.originalImage,
                            background: .white,
                            label: "До"
                        )
                        PreviewSurface(
                            image: appState.resultImage ?? appState.originalImage,
                            background: appState.previewBackground,
                            label: "После"
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
}

private struct PreviewSurface: View {
    let image: NSImage?
    let background: AppState.PreviewBackground
    let label: String

    var body: some View {
        ZStack {
            PreviewBackgroundView(style: background)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
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
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2))
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
