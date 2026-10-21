import Observation

/// Sleduje hodnoty, které `read` čte, a po každé jejich změně zavolá `react` (na hlavním vlákně, až po
/// dokončení změny). Sledování se samo obnovuje; skončí, až `read` nic nesledovaného nepřečte
/// (vlastník zanikl – `read` drží jen slabý odkaz).
@MainActor
func observeChanges(_ read: @escaping @MainActor () -> Void, react: @escaping @MainActor () -> Void) {
    withObservationTracking(read) {
        Task { @MainActor in
            react()
            observeChanges(read, react: react)
        }
    }
}
