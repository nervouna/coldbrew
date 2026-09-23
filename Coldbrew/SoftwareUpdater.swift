import Sparkle

@Observable
@MainActor
class SoftwareUpdater {
  var isAvailable: Bool { updater != nil }

  var automaticallyChecksForUpdates: Bool {
    get { updateChecksEnabled }
    set {
      updater?.automaticallyChecksForUpdates = newValue
    }
  }

  private var updateChecksEnabled = false
  private var updater: SPUUpdater?
  private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?
  private var updaterController: SPUStandardUpdaterController?

  init() {
    // Coldbrew has no update feed until its own release channel is configured.
    guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
          !feedURL.isEmpty else { return }

    let updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    self.updaterController = updaterController
    let updater = updaterController.updater
    self.updater = updater
    automaticallyChecksForUpdatesObservation = updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new, .old]
    ) { [weak self] _, change in
      guard let enabled = change.newValue, enabled != change.oldValue else {
        return
      }

      Task { @MainActor in
        self?.updateChecksEnabled = enabled
      }
    }
  }

  func checkForUpdates() {
    updater?.checkForUpdates()
  }
}
