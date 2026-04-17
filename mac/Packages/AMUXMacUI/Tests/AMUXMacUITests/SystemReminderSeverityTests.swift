import Testing
@testable import AMUXMacUI

@Suite("SystemReminderSeverity")
struct SystemReminderSeverityTests {

    @Test("default plain content is info")
    func defaultIsInfo() {
        #expect(SystemReminderSeverity.from(content: "Alice joined the session") == .info)
    }

    @Test("permission/approval phrasing returns urgent")
    func urgentForPermission() {
        #expect(SystemReminderSeverity.from(content: "Permission requested: cargo test") == .urgent)
        #expect(SystemReminderSeverity.from(content: "Approval required for shell command") == .urgent)
    }

    @Test("warning phrasing returns warn")
    func warnForWarning() {
        #expect(SystemReminderSeverity.from(content: "Warning: rate limit nearing") == .warn)
        #expect(SystemReminderSeverity.from(content: "Caution: long-running operation") == .warn)
    }

    @Test("title-cased label matches each severity")
    func labels() {
        #expect(SystemReminderSeverity.info.label == "Info")
        #expect(SystemReminderSeverity.warn.label == "Warning")
        #expect(SystemReminderSeverity.urgent.label == "Urgent")
    }
}
