import Foundation

// Based on https://www.craftappco.com/blog/2018/5/30/simple-throttling-in-swift.
@MainActor
class Throttler {
  var minimumDelay: TimeInterval

  private var workItem: DispatchWorkItem = DispatchWorkItem(block: {})
  private var previousRun: Date = Date.distantPast

  init(minimumDelay: TimeInterval) {
    self.minimumDelay = minimumDelay
  }

  func throttle(_ block: @escaping @MainActor () -> Void) {
    // Cancel any existing work item if it has not yet executed
    cancel()

    // Re-assign workItem with the new block task,
    // resetting the previousRun time when it executes
    workItem = DispatchWorkItem { [weak self] in
      // This work item is submitted exclusively to DispatchQueue.main below.
      MainActor.assumeIsolated {
        self?.previousRun = Date()
        block()
      }
    }

    // If the time since the previous run is more than the required minimum delay
    // => execute the workItem immediately
    // else
    // => delay the workItem execution by the minimum delay time
    let delay = previousRun.timeIntervalSinceNow > minimumDelay ? 0 : minimumDelay
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay), execute: workItem)
  }

  func cancel() {
    workItem.cancel()
  }
}
