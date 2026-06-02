import Foundation

/// Pure salience/forgetting math. Human-like: exponential decay + reinforcement.
/// No I/O, no dependencies — fully unit-testable.
public enum Decay {
    /// Effective salience now, given base salience, decay rate and elapsed seconds.
    public static func effectiveSalience(base: Double, decayRate: Double, elapsedSeconds: Double) -> Double {
        base * exp(-decayRate * max(0, elapsedSeconds))
    }

    /// Reinforcement on re-mention: bump salience (capped) and return the new base.
    public static func reinforce(current: Double, bump: Double = 0.5, cap: Double = 10) -> Double {
        min(cap, current + bump)
    }

    /// EMA decay factor (β) per layer = memory timescale. Larger β = slower/longer memory
    /// (effective horizon ≈ 1/(1−β)): live changes fast, identity is near-stable. This is the
    /// Adam-moment analogy `m ← β·m + (1−β)·signal` applied to a node's salience.
    public static func beta(for layer: MemoryLayer) -> Double {
        switch layer {
        case .live: return 0.5        // horizon ~2
        case .episodic: return 0.8    // ~5
        case .daily: return 0.9       // ~10
        case .identity: return 0.99   // ~100
        }
    }

    /// Reinforcement on re-mention via EMA toward a full-strength signal (default = cap).
    /// Moves salience a (1−β) fraction toward `signal` each mention: frequent mentions climb
    /// toward `cap`, and a larger β makes the climb slower/steadier (more stable memory).
    public static func reinforceEMA(current: Double, signal: Double = 10, beta: Double, cap: Double = 10) -> Double {
        min(cap, beta * current + (1 - beta) * signal)
    }

    /// Whether a node should be promoted L2(daily) → L4(identity).
    public static func shouldPromote(mentionCount: Int, origin: Origin, permanent: Bool, threshold: Int = 3) -> Bool {
        permanent || origin == .explicit || mentionCount >= threshold
    }

    /// Whether a node is eligible for forgetting (soft-delete). Identity never forgets.
    public static func shouldForget(layer: MemoryLayer, effectiveSalience: Double, ttlExpiresAt: Double?, now: Double, floor: Double = 0.05) -> Bool {
        if layer == .identity { return false }
        if let ttl = ttlExpiresAt, now > ttl { return true }
        return effectiveSalience < floor
    }

    /// Default decay rate per layer (per second; tuned so live fades over minutes, daily over days).
    public static func defaultDecayRate(for layer: MemoryLayer) -> Double {
        switch layer {
        case .live: return 1.0 / (30 * 60)            // ~30 min
        case .daily: return 1.0 / (5 * 24 * 3600)     // ~5 days
        case .identity: return 1.0 / (365 * 24 * 3600) // ~1 year (near-permanent)
        case .episodic: return 1.0 / (90 * 24 * 3600)  // ~90 days (reserved, S11)
        }
    }
}
