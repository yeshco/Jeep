import AppKit

enum AppBrand {
    static let name = "Jeep"
    static let menuBarImageName = "MenuBarJeepTemplate"
    static let menuBarFallbackSystemImage = "car.front.waves.down.fill"
    static let floatingBarImageName = "JeepArtwork"
    static let runningDescription = "Jeep is running"

    static func floatingBarImage(in bundle: Bundle = .main) -> NSImage {
        // build_app.sh packages AppIcon-master.png downsampled to 256px under
        // this name. Keep the Jeep and compass together; the menu-bar
        // template is a separate drawing.
        let sourceImage = bundle.url(forResource: floatingBarImageName, withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? bundle.image(forResource: NSImage.Name("AppIcon"))
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage(size: NSSize(width: 34, height: 34))
        let image = (sourceImage.copy() as? NSImage) ?? sourceImage
        image.isTemplate = false
        image.accessibilityDescription = "Jeep — Safari profiles"
        return image
    }

    static func menuBarImage(in bundle: Bundle = .main) -> NSImage {
        let sourceImage = bundle.image(
            forResource: NSImage.Name(menuBarImageName)
        ) ?? NSImage(
            systemSymbolName: menuBarFallbackSystemImage,
            accessibilityDescription: runningDescription
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        let image = (sourceImage.copy() as? NSImage) ?? sourceImage
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = runningDescription
        return image
    }
}
