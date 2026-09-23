import AppKit

extension NSEvent.ModifierFlags {
  @MainActor
  static var currentModifierFlags: Self {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }
}
