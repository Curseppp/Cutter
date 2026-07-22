import SwiftUI

@main
struct BackgroundAwayApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 860, minHeight: 580)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Отменить изменение маски") {
                    appState.undoLastMaskEdit()
                }
                .keyboardShortcut("z")
                .disabled(!appState.canUndoMaskEdit)

                Button("Повторить изменение маски") {
                    appState.redoLastMaskEdit()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!appState.canRedoMaskEdit)
            }

            CommandGroup(replacing: .newItem) {
                Button("Открыть изображение…") {
                    appState.openImagePicker()
                }
                .keyboardShortcut("o")
            }

            CommandGroup(after: .pasteboard) {
                Button("Вставить изображение") {
                    appState.pasteImage()
                }
                .keyboardShortcut("v")

                Divider()

                Button("Добавить объект…") {
                    appState.addObjectLayerPicker()
                }

                Button("Добавить фон…") {
                    appState.addBackgroundLayerPicker()
                }
            }

            CommandGroup(replacing: .saveItem) {
                Button("Экспортировать PNG…") {
                    appState.exportResult()
                }
                .keyboardShortcut("s")
                .disabled(appState.layers.isEmpty || appState.isProcessing)
            }
        }
    }
}
