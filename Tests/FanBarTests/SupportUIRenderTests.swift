import AppKit
import FanBarShared
import SwiftUI
import XCTest
@testable import FanBar

/// Renders the 1.1.7 surfaces that have no other way to be reviewed: the menu
/// bar "Temperature logic" row, the tip window (both channels), and the red
/// alert-threshold value. Writes PNGs only when `FANBAR_SUPPORT_RENDER_DIR` is
/// set, so CI stays silent while a local run can be eyeballed.
final class SupportUIRenderTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
        UserDefaults.standard.removeObject(forKey: MenuBarTemperatureSource.preferenceKey)
        super.tearDown()
    }

    @MainActor
    func testRenderTipWindowBothChannels() throws {
        guard let directory = ProcessInfo.processInfo.environment["FANBAR_SUPPORT_RENDER_DIR"] else {
            throw XCTSkip("set FANBAR_SUPPORT_RENDER_DIR to write review images")
        }
        for language in [FanBarLanguage.chinese, .english] {
            UserDefaults.standard.set(language.rawValue, forKey: FanBarLanguage.preferenceKey)
            let view = SupportTipView(onClose: {})
                .background(Color(NSColor.windowBackgroundColor))
            try write(view, to: directory, name: "tip-\(language.rawValue)")
        }
    }

    @MainActor
    func testRenderTemperatureLogicRow() throws {
        guard let directory = ProcessInfo.processInfo.environment["FANBAR_SUPPORT_RENDER_DIR"] else {
            throw XCTSkip("set FANBAR_SUPPORT_RENDER_DIR to write review images")
        }
        for language in [FanBarLanguage.chinese, .english] {
            UserDefaults.standard.set(language.rawValue, forKey: FanBarLanguage.preferenceKey)
            for source in MenuBarTemperatureSource.allCases {
                UserDefaults.standard.set(source.rawValue, forKey: MenuBarTemperatureSource.preferenceKey)
                let row = MenuBarTemperatureLogicPicker()
                    .frame(width: SettingsChrome.contentWidth - 48)
                    .background(Color(NSColor.windowBackgroundColor))
                try write(row, to: directory, name: "templogic-\(language.rawValue)-\(source.rawValue)")
            }
        }
        UserDefaults.standard.removeObject(forKey: MenuBarTemperatureSource.preferenceKey)
    }

    /// `ImageRenderer` is the supported SwiftUI-to-image path: unlike an
    /// NSHostingView snapshot it lays the view out at the size it is given, so
    /// the capture never shows a clipped fragment.
    @MainActor
    private func write<Content: View>(
        _ view: Content,
        to directory: String,
        name: String
    ) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage, "renderer produced no image for \(name)")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("could not encode \(name)")
        }
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
