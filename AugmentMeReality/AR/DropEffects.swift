import RealityKit
import UIKit

/// ADR-046: the "alive" layer — particles + idle motion applied at runtime.
/// This is how lightweight (even static) models read as premium animated
/// content at ZERO file-size cost: a sparkle aura, a reveal burst when you get
/// close, and gentle idle motion. All effects are code, tinted per drop.
enum DropEffects {
    // MARK: Particles (iOS 18+; older devices simply skip them)

    /// Gentle ambient sparkles around the content — the "magic is here" cue.
    @available(iOS 18.0, *)
    static func sparkleAura(color: UIColor, radius: Float) -> Entity {
        let entity = Entity()
        entity.name = "fx-aura"
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = SIMD3(repeating: max(radius, 0.3))
        emitter.birthLocation = .surface
        emitter.speed = 0.02
        emitter.speedVariation = 0.02
        emitter.mainEmitter.birthRate = 18
        emitter.mainEmitter.birthRateVariation = 6
        emitter.mainEmitter.size = 0.014
        emitter.mainEmitter.sizeVariation = 0.008
        emitter.mainEmitter.lifeSpan = 1.6
        emitter.mainEmitter.lifeSpanVariation = 0.5
        emitter.mainEmitter.acceleration = SIMD3(0, 0.05, 0)
        emitter.mainEmitter.color = .evolving(
            start: .single(color.withAlphaComponent(0.9)),
            end: .single(UIColor.white.withAlphaComponent(0))
        )
        emitter.mainEmitter.opacityCurve = .gradualFadeInOut
        entity.components.set(emitter)
        return entity
    }

    /// One celebratory burst — fired the first time a viewer gets close.
    /// Implemented as a short timed emission (robust across SDK versions).
    @available(iOS 18.0, *)
    static func revealBurst(color: UIColor) -> Entity {
        let entity = Entity()
        entity.name = "fx-burst"
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .point
        emitter.birthDirection = .local
        emitter.emissionDirection = SIMD3(0, 1, 0)
        emitter.speed = 1.9
        emitter.speedVariation = 0.9
        emitter.mainEmitter.birthRate = 900
        emitter.mainEmitter.spreadingAngle = .pi
        emitter.mainEmitter.size = 0.02
        emitter.mainEmitter.sizeVariation = 0.012
        emitter.mainEmitter.lifeSpan = 1.1
        emitter.mainEmitter.lifeSpanVariation = 0.4
        emitter.mainEmitter.acceleration = SIMD3(0, -1.6, 0) // confetti falls
        emitter.mainEmitter.dampingFactor = 1.4
        emitter.mainEmitter.angleVariation = .pi
        emitter.mainEmitter.color = .evolving(
            start: .random(a: color, b: UIColor(hex: "#FFC857") ?? .yellow),
            end: .single(UIColor.white.withAlphaComponent(0))
        )
        emitter.mainEmitter.opacityCurve = .linearFadeOut
        entity.components.set(emitter)
        // Emit for a beat, then stop; caller removes the entity afterwards.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            if var component = entity.components[ParticleEmitterComponent.self] {
                component.mainEmitter.birthRate = 0
                entity.components.set(component)
            }
        }
        return entity
    }

    /// ADR-046 Tier-1 hero: a continuous fireworks show. Rockets rise on a
    /// sparse cadence; each one's death spawns a spherical bloom of colored
    /// sparks (SpawnOccasion.onDeath). Pure particles — zero file size.
    @available(iOS 18.0, *)
    static func fireworksShow(color: UIColor) -> Entity {
        let entity = Entity()
        entity.name = "fx-fireworks"

        var rockets = ParticleEmitterComponent()
        rockets.emitterShape = .point
        rockets.birthDirection = .local
        rockets.emissionDirection = SIMD3(0, 1, 0)
        rockets.speed = 5.2
        rockets.speedVariation = 1.2
        rockets.mainEmitter.birthRate = 0.9
        rockets.mainEmitter.birthRateVariation = 0.4
        rockets.mainEmitter.spreadingAngle = 0.22
        rockets.mainEmitter.size = 0.05
        rockets.mainEmitter.lifeSpan = 1.15
        rockets.mainEmitter.lifeSpanVariation = 0.25
        rockets.mainEmitter.acceleration = SIMD3(0, -1.2, 0)
        rockets.mainEmitter.color = .evolving(
            start: .single(UIColor(hex: "#FFC857") ?? .yellow),
            end: .single(UIColor.white)
        )
        rockets.mainEmitter.opacityCurve = .constant

        // The bloom: spawned where each rocket dies.
        var bloom = ParticleEmitterComponent.ParticleEmitter()
        bloom.birthRate = 0
        bloom.size = 0.03
        bloom.sizeVariation = 0.015
        bloom.lifeSpan = 1.5
        bloom.lifeSpanVariation = 0.4
        bloom.acceleration = SIMD3(0, -1.8, 0)
        bloom.dampingFactor = 1.8
        bloom.spreadingAngle = .pi
        bloom.color = .evolving(
            start: .random(a: color, b: UIColor(hex: "#5E5CE6") ?? .systemIndigo),
            end: .single(UIColor.white.withAlphaComponent(0))
        )
        bloom.opacityCurve = .linearFadeOut
        rockets.spawnOccasion = .onDeath
        rockets.spawnedEmitter = bloom
        rockets.spawnSpreadFactor = .pi
        rockets.spawnVelocityFactor = 2.6

        entity.components.set(rockets)
        return entity
    }

    // MARK: Idle motion (any iOS — pure animation resources)

    enum IdleMotion {
        case bob        // text: readable, alive
        case bobAndSpin // gifts/hearts/balloons: showcase turn
        case none       // rigged USDZ with its own animations
    }

    static func idleMotion(for drop: GeoDrop, contentHasAnimations: Bool) -> IdleMotion {
        if contentHasAnimations { return .none }
        switch drop.content {
        case .text3D: return .bob
        case .beacon, .fireworks: return .none // self-animating / static base
        default: return .bobAndSpin
        }
    }

    /// Gentle float + optional slow turn, applied to the content root.
    static func applyIdleMotion(_ motion: IdleMotion, to entity: Entity) {
        guard motion != .none else { return }
        var animations: [AnimationResource] = []
        let bob = FromToByAnimation<Transform>(
            by: Transform(translation: SIMD3(0, 0.05, 0)),
            duration: 1.8,
            timing: .easeInOut,
            isAdditive: true,
            repeatMode: .autoReverse
        )
        if let resource = try? AnimationResource.generate(with: bob) {
            animations.append(resource)
        }
        if motion == .bobAndSpin {
            let spin = FromToByAnimation<Transform>(
                by: Transform(rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0])),
                duration: 4.0,
                timing: .linear,
                isAdditive: true,
                repeatMode: .repeat
            )
            if let resource = try? AnimationResource.generate(with: spin) {
                animations.append(resource)
            }
        }
        for animation in animations {
            entity.playAnimation(animation.repeat())
        }
    }
}
