import FocusGuard

// Strážce Soustředění – pomocník na pozadí (viz FocusGuard/GuardRunner).
MainActor.assumeIsolated { GuardRunner.main() }
