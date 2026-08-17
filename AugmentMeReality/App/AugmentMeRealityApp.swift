import FirebaseCore
import SwiftUI

@main
struct AugmentMeRealityApp: App {
    @StateObject private var locationService = LocationService()
    @StateObject private var dropLibrary: DropLibrary
    @StateObject private var arSessionHolder = ARSessionHolder()
    @StateObject private var accountService = AccountService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // ADR-039: Firebase configures before any store/auth use; absent
        // config file = fully local app, exactly as before.
        if AppConfig.firebaseConfigured {
            FirebaseApp.configure()
        }
        _dropLibrary = StateObject(wrappedValue: DropLibrary())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(locationService)
                .environmentObject(dropLibrary)
                .environmentObject(arSessionHolder)
                .environmentObject(accountService)
                .task {
                    locationService.start()
                    accountService.start()
                    arSessionHolder.configure(
                        locationService: locationService, library: dropLibrary
                    )
                    await dropLibrary.refresh(near: locationService.location)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background:
                        arSessionHolder.appDidEnterBackground()
                    case .active:
                        arSessionHolder.configure(
                            locationService: locationService, library: dropLibrary
                        )
                        arSessionHolder.warmWithoutCamera()
                        // SWE-1: resume a session suspended by backgrounding
                        // while the camera cover is still presented.
                        arSessionHolder.appDidBecomeActive()
                        // Round 12 (counsel SURF-lens-1 tail): returning from
                        // background re-runs the sync pass so the evidence
                        // ladder reflects the world that may have changed
                        // while the app was suspended.
                        Task { await dropLibrary.refresh(near: locationService.location) }
                    default:
                        break
                    }
                }
        }
    }
}
