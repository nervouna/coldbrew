import Sparkle

@Observable
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
    ) { [unowned self] updater, change in
      guard change.newValue != change.oldValue else {
        return
      }

      self.updateChecksEnabled = updater.automaticallyChecksForUpdates
    }
  }

  func checkForUpdates() {
    updater?.checkForUpdates()
  }
}
