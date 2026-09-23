import AppKit.NSEvent
import Defaults

@Observable
@MainActor
class ModifierFlags {
  var flags: NSEvent.ModifierFlags = []

  init() {
    NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      // AppKit invokes local event monitors on the main thread, synchronously.
      MainActor.assumeIsolated {
        self.flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      }
      return event
    }
  }
}
