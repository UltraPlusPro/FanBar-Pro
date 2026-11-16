import AppKit
import FanBarShared
import SwiftUI
import XCTest
@testable import FanBar

/// The 1.1.7 support footer: the "Star on GitHub" row is gone and the primary
/// action opens the local tip window. 1.1.7 also dropped the tip window's
/// secondary "open the web checkout in a browser" row, so the payment codes are
/// the only tip path the app offers.
final class SupportFooterLayoutTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
        super.tearDown()
    }

    /// The URL is no longer reachable from the UI, but it stays a documented
    /// constant so a future "pay by card" row needs no new address. Its shape is
    /// asserted here to keep a typo from silently surviving.
    func testDonationConstantIsStillTheHostedCheckout() {
        let url = FanBarLinks.donation
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "checkout.dodopayments.com")
        XCTAssertTrue(url.path.hasPrefix("/buy/pdt_"))
    }

    /// The browser-checkout row was removed in 1.1.7: neither its title nor its
    /// help string may survive in source, or the catalogs would keep translating
    /// copy no view shows.
    func testTheBrowserCheckoutRowIsGoneFromSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let retired = ["Open the web checkout", "用浏览器打开网页打赏", "在浏览器中打开网页打赏"]
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in retired {
                XCTAssertFalse(
                    text.contains(needle),
                    "\(file.lastPathComponent) still mentions \"\(needle)\""
                )
            }
        }
    }

    /// The tip codes must be reachable from the app bundle without a network
    /// call; a missing PNG is a blank panel.
    func testBothPaymentCodesAreBundled() {
        for channel in SupportTipAssets.Channel.allCases {
            XCTAssertNotNil(
                SupportTipAssets.url(for: channel),
                "\(channel.rawValue) payment code is not in the app or resource bundle"
            )
            XCTAssertNotNil(
                SupportTipAssets.image(for: channel),
                "\(channel.rawValue) payment code could not be decoded"
            )
        }
        XCTAssertEqual(SupportTipAssets.Channel.allCases.count, 3)
    }

    /// A code with no hint would leave the panel ambiguous.
    func testEachChannelHasATitleHintAndExportName() {
        for channel in SupportTipAssets.Channel.allCases {
            XCTAssertFalse(channel.title.isEmpty, channel.rawValue)
            XCTAssertFalse(channel.hint.isEmpty, channel.rawValue)
            XCTAssertFalse(channel.exportName.isEmpty, channel.rawValue)
            XCTAssertTrue(channel.exportName.hasSuffix(".png"), channel.rawValue)
        }
    }

    /// The channel switch is a two-segment control whose labels come from the
    /// catalog, so both channel names must exist in every shipped language.
    /// (The rendered style itself is verified manually: `ImageRenderer` draws a
    /// placeholder for `.segmented`, and driving an AppKit window from inside a
    /// test run segfaults, so this asserts the data that control is built from.)
    func testChannelPickerHasBothLabelsInEveryLanguage() {
        let saved = UserDefaults.standard.object(forKey: FanBarLanguage.preferenceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: FanBarLanguage.preferenceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: FanBarLanguage.preferenceKey)
            }
        }
        for language in FanBarLanguage.allCases where language != .system {
            UserDefaults.standard.set(language.rawValue, forKey: FanBarLanguage.preferenceKey)
            for channel in SupportTipAssets.Channel.allCases {
                XCTAssertFalse(channel.title.isEmpty, "\(language.rawValue)/\(channel.rawValue)")
            }
            // The two names must stay distinguishable, or the switch would read
            // as one option twice.
            XCTAssertNotEqual(
                SupportTipAssets.Channel.wechat.title,
                SupportTipAssets.Channel.alipay.title,
                language.rawValue
            )
        }
    }

    /// The tip window itself must lay out at its fixed width with a QR area,
    /// so it does not open collapsed.
    @MainActor
    func testTipViewLaysOutAtItsContentWidth() {
        let host = NSHostingView(rootView: SupportTipView(onClose: {}))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        XCTAssertEqual(size.width, SupportTipLayout.windowWidth, accuracy: 1)
        XCTAssertGreaterThan(size.height, 300, "the QR area must be visible")
    }

    /// Removing the browser row must not collapse the stack: the header, the
    /// 300pt code box, the hint and the button row each keep their 16pt channel,
    /// so the panel only gives up the one row that went away.
    @MainActor
    func testTipViewKeepsItsRowsAfterTheBrowserLinkWasRemoved() throws {
        let host = NSHostingView(rootView: SupportTipView(onClose: {}))
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        // Measured: 528pt here and 541pt in English (the render directory PNGs
        // are 1056 and 1082 tall at scale 2). The removed row was one caption
        // line plus its 16pt channel, and the new paragraph adds a wrapped line
        // back. A VStack that lost its channels lands near 400.
        XCTAssertGreaterThan(height, 500, "the rows above and below the code box collapsed")
        XCTAssertLessThan(height, 620, "the panel grew an unexpected extra row")
    }
}
