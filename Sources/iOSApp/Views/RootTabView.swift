import SwiftUI

struct RootTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedTab) {
            Tab(String(localized: "Library"), systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", value: .library) {
                HomeFeedView()
            }

            Tab(String(localized: "Settings"), systemImage: "gearshape", value: .settings) {
                SettingsScreen()
            }
        }
    }
}
