import CoreLocation
import SwiftUI

/// UI revamp (ADR-048): navigation truth for "The Gift, not the Map".
/// Tabs are destinations of purpose; the CAMERA is not a tab — it's a moment,
/// presented full-screen from the flows that need it (Playground, a received
/// drop, onboarding's fireworks demo, later the create wizard's placement).
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case home, explore, sent, you
    }

    enum OnboardingPhase {
        case none          // finished or not started
        case story         // beats 1 & 3 (the cover)
        case fireworksDemo // beat 2 — live camera moment
    }

    @Published var tab: Tab = .home
    @Published var showCamera = false
    @Published var onboardingPhase: OnboardingPhase = .none

    /// ADR-050: the create ritual (What → Where → Wrap), presented full-screen
    /// from the + orb, Home's hero, Explore's map tap, and "send one back".
    @Published var showCreate = false
    /// A map tap on Explore arrives with the spot already chosen.
    @Published var createPrefill: CLLocationCoordinate2D?

    func beginCreate(at coordinate: CLLocationCoordinate2D? = nil) {
        createPrefill = coordinate
        showCreate = true
    }

    @AppStorage("hasOnboarded") var hasOnboarded = false

    func startOnboardingIfNeeded() {
        if !hasOnboarded {
            onboardingPhase = .story
        }
    }

    /// Beat 2: hand off to the live camera for the fireworks moment.
    func beginFireworksDemo() {
        onboardingPhase = .fireworksDemo
        showCamera = true
    }

    /// Back from the demo into the story (beat 3 — name).
    func endFireworksDemo() {
        showCamera = false
        onboardingPhase = .story
    }

    func finishOnboarding() {
        hasOnboarded = true
        onboardingPhase = .none
    }
}
