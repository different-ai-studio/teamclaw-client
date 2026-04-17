import Testing
import SwiftUI
@testable import AMUXMacUI

@Suite("AppAppearance")
struct AppAppearanceTests {

    @Test("system maps to nil colorScheme (follows OS)")
    func systemIsNil() {
        #expect(AppAppearance.system.colorScheme == nil)
    }

    @Test("light maps to .light")
    func lightIsLight() {
        #expect(AppAppearance.light.colorScheme == .light)
    }

    @Test("dark maps to .dark")
    func darkIsDark() {
        #expect(AppAppearance.dark.colorScheme == .dark)
    }
}
