import SwiftUI
import AMUXMacUI

@main
struct AMUXMacApp: App {
    var body: some Scene {
        WindowGroup {
            Text("AMUX \(AMUXMacUI.buildVersion)")
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
