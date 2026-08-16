import SwiftUI
import UIKit

extension BriefStore {
    /// The connect step as the views need it.
    ///
    /// `BriefStore.connect()` asks iOS while iOS is still willing to ask. Once
    /// the question has been answered — granted or denied — `EventKit` returns
    /// the stored answer immediately and shows nothing, so a button wired
    /// straight to it would sit there doing nothing visible. Settings is the
    /// only place a decision already made can be changed, so that is where the
    /// second path goes.
    func connect(openURL: OpenURLAction) async {
        if await connect() { return }
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
