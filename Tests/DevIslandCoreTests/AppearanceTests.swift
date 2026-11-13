import XCTest
@testable import DevIslandCore

final class AppearanceTests: XCTestCase {
    func testOldDefaultMigratesWhileExistingCustomAccentAndSettingsSurvive() throws {
        for (old, expected) in [("168E96", "D97757"), ("A11EF0", "A11EF0")] {
            let data = Data("{\"accentHex\":\"\(old)\",\"theme\":\"dark\",\"quiet\":true,\"volume\":0.17,\"preferredTerminal\":\"com.apple.Terminal\"}".utf8)
            let p = try JSONDecoder().decode(Preferences.self, from: data)
            XCTAssertEqual(p.accentHex, expected); XCTAssertTrue(p.quiet); XCTAssertEqual(p.volume, 0.17)
            XCTAssertEqual(p.preferredTerminal, "com.apple.Terminal"); XCTAssertEqual(p.theme, .dark)
            XCTAssertEqual(p.mascot, .clawd); XCTAssertEqual(p.selectedMascotColor.mode, .accent)
        }
    }
    func testNewExplicitTealIsNotMigratedOnSubsequentLaunch() throws {
        var p = Preferences(); p.accentHex = "168E96"
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.accentHex, "168E96")
    }
    func testPerCharacterColorsRoundTripAndFollowAccent() throws {
        var p = Preferences(); p.accentHex = "B65742"
        p.mascotColors["cat"] = .init(mode: .custom, hex: "7EB4DA")
        p.mascotColors["robot"] = .init(mode: .custom, hex: "B1AD6D")
        p.mascot = .cat
        var restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.mascot, .cat); XCTAssertEqual(restored.mascotHex, "7EB4DA")
        restored.mascot = .robot; XCTAssertEqual(restored.mascotHex, "B1AD6D")
        restored.mascot = .clawd; XCTAssertEqual(restored.mascotHex, "B65742")
        restored.accentHex = "FFFFFF"; XCTAssertEqual(restored.mascotHex, "FFFFFF")
        restored.mascot = .cat; XCTAssertEqual(restored.mascotHex, "7EB4DA")
    }
    func testBlackThemeRoundTripsAndUsesTrueBlackCanvas() throws {
        var p = Preferences(); p.theme = .black
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.theme, .black); XCTAssertTrue(restored.theme.isBlack)
        let colors = ThemeColors(dark: false, black: true, accentHex: "D97757")
        XCTAssertEqual(colors.canvas, .black); XCTAssertEqual(colors.primary.hex, "F2F2F2")
    }
    func testUnknownCharacterDoesNotEraseOtherPreferences() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"mascot":"future","quiet":true,"accentHex":"AB0123"}"#.utf8))
        XCTAssertEqual(p.mascot, .clawd); XCTAssertTrue(p.quiet); XCTAssertEqual(p.accentHex, "AB0123")
    }
    func testThemeTextAndArbitraryAccentMeetWCAGContrastOnBothContentSurfaces() {
        for (dark, black) in [(false, false), (true, false), (false, true), (true, true)] {
            for hex in ["D97757", "FFFFFF", "000000", "FFFF00", "168E96", "AB12D4", "777777", "00FF00"] {
                let colors = ThemeColors(dark: dark, black: black, accentHex: hex)
                for background in [colors.canvas, colors.content] {
                    XCTAssertGreaterThanOrEqual(colors.primary.contrast(with: background), 4.5)
                    XCTAssertGreaterThanOrEqual(colors.secondary.contrast(with: background), 4.5)
                    XCTAssertGreaterThanOrEqual(colors.accent.contrast(with: background), 4.5 - 0.00001)
                }
                XCTAssertGreaterThanOrEqual(colors.accentFill.contrast(with: colors.onAccent), 4.5)
                XCTAssertGreaterThanOrEqual(SRGBColor(hex: hex).contrast(with: SRGBColor(hex: hex).ink), 4.5)
            }
        }
    }
    func testExactSilhouettesHaveDifferentEarsAndAntennaAndTransparentGaps() {
        let size = CGSize(width: 32, height: 32)
        func hit(_ kind: MascotKind, _ x: Double, _ y: Double, _ pose: ClawdPose = .idle) -> Bool {
            MascotSilhouette.contains(point: CGPoint(x: x, y: y), size: size, kind: kind, pose: pose)
        }
        XCTAssertTrue(hit(.cat, 9, 6)); XCTAssertFalse(hit(.clawd, 9, 6)); XCTAssertFalse(hit(.robot, 9, 6))
        XCTAssertTrue(hit(.robot, 16, 4)); XCTAssertFalse(hit(.cat, 16, 4)); XCTAssertFalse(hit(.clawd, 16, 4))
        for kind in MascotKind.allCases {
            for pose in ClawdPose.allCases {
                XCTAssertFalse(hit(kind, 0, 31, pose)); XCTAssertFalse(hit(kind, 31, 31, pose))
                XCTAssertTrue(hit(kind, 16, 16, pose))
            }
            XCTAssertTrue(hit(kind, 25, 4, .question)); XCTAssertTrue(hit(kind, 8, 29, .working))
        }
        XCTAssertFalse(hit(.cat, 16, 7)); XCTAssertFalse(hit(.robot, 8.5, 24))
    }
    func testExtendedGamutPickerConversionProducesValidSixDigitSRGB() {
        XCTAssertEqual(SRGBColor(r: 1.2, g: -0.1, b: 0.5).hex, "FF0080")
        XCTAssertEqual(SRGBColor(hex: "#D97757").hex, "D97757")
    }
    func testInvalidAndZeroSizeMaskCannotInterceptInput() {
        XCTAssertFalse(MascotSilhouette.contains(point: .zero, size: .zero, kind: .robot, pose: .working))
    }
}
