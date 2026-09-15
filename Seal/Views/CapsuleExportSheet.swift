import SwiftUI

/// Placeholder at the phase 8 boundary. The capsule export lands in phase 9.
struct CapsuleExportSheet: View {
    let estateID: String
    @Bindable var estateEngine: EstateEngine
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                SealTheme.ink.ignoresSafeArea()
                Text("The capsule export is not built yet.").foregroundStyle(.white)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
        .preferredColorScheme(.dark)
    }
}
