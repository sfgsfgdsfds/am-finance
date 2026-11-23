import Testing
import Foundation
@testable import AMFinance

/// The label and ordering contracts the unified Agent screen and the
/// "Quyền của Agent" settings section rely on: the picker's options are
/// `allCases` order, each level has a settings label plus a short
/// chat-mode caption, and the persisted raw values round-trip.
struct AIAgentScreenTests {

    /// The settings picker binds tags to raw values in `allCases` order —
    /// "Tắt" / "Chỉ đọc sổ" / "Đọc và thao tác" must stay in lockstep.
    @Test func accessPickerOrderAndLabels() {
        #expect(AIAgentAccess.allCases
            == [.off, .scopedRead, .scopedReadAndProposeCategoryEdits])
        #expect(AIAgentAccess.allCases.map(\.settingsTitle)
            == ["Tắt", "Chỉ đọc sổ", "Đọc và thao tác"])
    }

    /// The unobtrusive mode caption on the Agent screen.
    @Test func agentModeTitles() {
        #expect(AIAgentAccess.off.agentModeTitle == "Tắt")
        #expect(AIAgentAccess.scopedRead.agentModeTitle == "Chỉ đọc")
        #expect(
            AIAgentAccess.scopedReadAndProposeCategoryEdits.agentModeTitle
                == "Đọc và thao tác")
    }

    /// Both screens persist the same AppStorage strings — a stored
    /// level must decode back to itself, and anything unknown falls
    /// back to `.off` via the view's `?? .off`.
    @Test func accessRawValueRoundTrips() {
        for access in AIAgentAccess.allCases {
            #expect(AIAgentAccess(rawValue: access.rawValue) == access)
        }
        #expect(AIAgentAccess(rawValue: "bogus") == nil)
        #expect(AIAgentAccess.off.rawValue == "off")
    }

    /// `AIAgentView.accessValue` — the live reader behind the session's
    /// `accessProvider` — honours stored values and treats a missing or
    /// unreadable one as the real default, `.off`.
    @Test func accessValueReadsDefaults() {
        let suiteName = "AIAgentScreenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AIAgentView.accessValue(in: defaults) == .off)
        defaults.set(
            AIAgentAccess.scopedReadAndProposeCategoryEdits.rawValue,
            forKey: AIAgentView.accessDefaultsKey)
        #expect(AIAgentView.accessValue(in: defaults)
            == .scopedReadAndProposeCategoryEdits)
        defaults.set("bogus", forKey: AIAgentView.accessDefaultsKey)
        #expect(AIAgentView.accessValue(in: defaults) == .off)
    }
}
