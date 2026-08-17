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

    /// Wave D (counsel SWE-7): ONE full-screen destination. The old shape —
    /// three stacked `.fullScreenCover` modifiers plus a `.sheet` on one view,
    /// with flows mutating two bindings in the same update — is a presentation
    /// pattern SwiftUI does not support: the onboarding→camera hand-off (the
    /// designed magic moment) could silently drop its cover, and a deep link
    /// tapped while the camera was up was silently lost. A single enum
    /// destination makes every transition ONE state change that SwiftUI
    /// serializes.
    enum Destination: String, Identifiable {
        case camera
        case create
        case onboardingStory
        case memory
        var id: String { rawValue }
    }

    @Published var tab: Tab = .home
    @Published var destination: Destination?
    @Published var onboardingPhase: OnboardingPhase = .none

    /// Wave D (counsel SWE-7): a magic link tapped while a cover is up is
    /// QUEUED here and presented when the stage clears — never dropped.
    @Published var pendingReceiveDropID: UUID?

    /// Compatibility surface — call sites read/write "the camera moment"
    /// without knowing the presentation representation.
    var showCamera: Bool {
        get { destination == .camera }
        set {
            if newValue {
                destination = .camera
            } else if destination == .camera {
                // Leaving the demo camera returns to the story cover in the
                // SAME transaction (one state change — the SWE-7 fix).
                destination = onboardingPhase == .fireworksDemo ? .onboardingStory : nil
                if onboardingPhase == .fireworksDemo { onboardingPhase = .story }
            }
        }
    }

    var showCreate: Bool {
        get { destination == .create }
        set {
            if newValue {
                destination = .create
            } else if destination == .create {
                destination = nil
            }
        }
    }

    /// A map tap on Explore arrives with the spot already chosen.
    @Published var createPrefill: CLLocationCoordinate2D?

    func beginCreate(at coordinate: CLLocationCoordinate2D? = nil) {
        createPrefill = coordinate
        destination = .create
    }

    @AppStorage("hasOnboarded") var hasOnboarded = false

    func startOnboardingIfNeeded() {
        if !hasOnboarded {
            onboardingPhase = .story
            destination = .onboardingStory
        }
    }

    /// Beat 2: hand off to the live camera for the fireworks moment — a single
    /// destination change, never a dismiss+present pair (counsel SWE-7).
    func beginFireworksDemo() {
        onboardingPhase = .fireworksDemo
        destination = .camera
    }

    /// Back from the demo into the story (beat 3 — name).
    func endFireworksDemo() {
        onboardingPhase = .story
        destination = .onboardingStory
    }

    func finishOnboarding() {
        hasOnboarded = true
        onboardingPhase = .none
        if destination == .onboardingStory { destination = nil }
    }
}
