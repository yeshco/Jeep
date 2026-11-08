import SwiftUI

@main
struct JeepApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model: SwitcherModel

    init() {
        let model = SwitcherModel()
        _model = StateObject(wrappedValue: model)
        AppLifecycleDelegate.model = model
        SettingsWindowController.shared.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(model: model)
        } label: {
            Image(nsImage: AppBrand.menuBarImage())
                .renderingMode(.template)
                .accessibilityLabel(Text(AppBrand.runningDescription))
        }
        .menuBarExtraStyle(.menu)
    }
}
