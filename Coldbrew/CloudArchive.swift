import AppKit
import CloudKit
import CryptoKit
import Defaults
import Observation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// Versioned value types deliberately keep SwiftData objects on the main actor.
struct ArchiveContent: Codable, Equatable, Sendable {
  var type: String
  var value: Data?
}

struct ArchiveItem: Codable, Equatable, Sendable {
  var syncID: String?
  var contents: [ArchiveContent]
  var title: String
  var application: String?
  var firstCopiedAt: Date
  var lastCopiedAt: Date
  var numberOfCopies: Int
  var pin: String?

  var id: String {
    if let syncID { return syncID }
    let supported = Set(["public.utf8-plain-text", "public.html", "public.rtf", "public.png", "public.tiff", "public.jpeg", "public.heic", "public.file-url"])
    let canonical = contents.filter { supported.contains($0.type) }
    let sorted = (canonical.isEmpty ? contents : canonical).sorted {
      $0.type == $1.type ? ($0.value ?? Data()).lexicographicallyPrecedes($1.value ?? Data()) : $0.type < $1.type
    }
    return ArchiveCodec.digest((try? ArchiveCodec.encoder.encode(sorted)) ?? Data())
  }

  @MainActor init(_ item: HistoryItem) {
    syncID = item.syncID
    contents = item.contents.map { ArchiveContent(type: $0.type, value: $0.value) }
    title = item.title
    application = item.application
    firstCopiedAt = item.firstCopiedAt
    lastCopiedAt = item.lastCopiedAt
    numberOfCopies = item.numberOfCopies
    pin = item.pin
  }

  @MainActor func model() -> HistoryItem {
    let item = HistoryItem(contents: contents.map { HistoryItemContent(type: $0.type, value: $0.value) })
    apply(to: item)
    return item
  }

  @MainActor func apply(to item: HistoryItem) {
    if item.contents.map({ ArchiveContent(type: $0.type, value: $0.value) }) != contents {
      if let context = item.modelContext { item.contents.forEach(context.delete) }
      item.contents = contents.map { HistoryItemContent(type: $0.type, value: $0.value) }
      item.clearDecodedImageCache()
    }
    item.syncID = id
    item.title = title.removingScalarsUnsafeForTitleLayout()
    item.application = application
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = numberOfCopies
    item.pin = pin
  }
}

struct ArchiveStamp: Codable, Comparable, Sendable {
  var counter: Int64
  var device: String
  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
  }
}

struct SyncedItem: Codable, Equatable, Sendable {
  var value: ArchiveItem
  var stamp: ArchiveStamp
  var deleted = false
  // G-counter components merge with max, never by summing downloaded totals.
  var copies: [String: Int]

  mutating func tombstone(at stamp: ArchiveStamp) {
    self.stamp = stamp
    deleted = true
    value.syncID = value.id
    value.contents = []
    value.title = ""
    value.application = nil
    value.pin = nil
  }

  func merging(_ other: Self) -> Self {
    var result = stamp < other.stamp ? other : self
    for (device, count) in other.copies.merging(copies, uniquingKeysWith: max) { result.copies[device] = count }
    result.value.numberOfCopies = result.copies.values.reduce(0, +)
    result.value.firstCopiedAt = min(value.firstCopiedAt, other.value.firstCopiedAt)
    result.value.lastCopiedAt = max(value.lastCopiedAt, other.value.lastCopiedAt)
    return result
  }
}

struct SyncedPreference: Codable, Equatable, Sendable {
  var value: Data?
  var stamp: ArchiveStamp
}

struct SyncLedger: Codable, Equatable, Sendable {
  var version = 1
  var items: [String: SyncedItem] = [:]
  var preferences: [String: SyncedPreference] = [:]

  mutating func merge(_ other: Self) throws {
    guard other.version == 1 else { throw ArchiveError.unsupportedVersion }
    for (id, item) in other.items {
      guard item.deleted || id == item.value.id else { throw ArchiveError.corrupt }
      items[id] = items[id].map { $0.merging(item) } ?? item
    }
    for (key, value) in other.preferences where preferences[key] == nil || preferences[key]!.stamp < value.stamp {
      preferences[key] = value
    }
  }

  var maxCounter: Int64 {
    max(items.values.map(\.stamp.counter).max() ?? 0, preferences.values.map(\.stamp.counter).max() ?? 0)
  }
}

enum ArchiveError: LocalizedError {
  case corrupt, unsupportedVersion, accountChanged, unavailable
  var errorDescription: String? {
    switch self {
    case .corrupt: "The archive is damaged or contains invalid data. Nothing was restored."
    case .unsupportedVersion: "This archive requires a newer version of Coldbrew."
    case .accountChanged: "The iCloud account changed. Sync is paused; enable it again to approve this account."
    case .unavailable: "iCloud is unavailable. Local clipboard history continues to work."
    }
  }
}

enum ArchiveCodec {
  struct Envelope: Codable { var version = 1; var checksum: String; var payload: Data }
  static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
  static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let payload = try encoder.encode(value)
    return try encoder.encode(Envelope(checksum: digest(payload), payload: payload))
  }
  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1 else { throw ArchiveError.unsupportedVersion }
    guard digest(envelope.payload) == envelope.checksum else { throw ArchiveError.corrupt }
    return try JSONDecoder().decode(type, from: envelope.payload)
  }
}

struct ClipboardBackup: Codable, Sendable {
  var createdAt = Date()
  var items: [ArchiveItem]
  var preferences: [String: Data]

  func validate() throws {
    guard items.count < 100_000,
          items.allSatisfy({ $0.numberOfCopies >= 0 && !$0.contents.isEmpty }),
          Set(items.map(\.id)).count == items.count else { throw ArchiveError.corrupt }
    for (key, data) in preferences {
      guard CloudPreferences.backupKeys.contains(key) else { throw ArchiveError.corrupt }
      _ = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
  }
}

enum CloudPreferences {
  // Capture exclusions, capacity, launch behavior, hotkeys and screen geometry remain local.
  static let portableKeys: Set<String> = [
    "highlightMatch", "imageMaxHeight", "menuIcon", "pasteByDefault", "pinTo", "openPreviewAutomatically",
    "previewDelay", "removeFormattingByDefault", "searchMode", "showFooter", "showSearch", "searchVisibility",
    "showSpecialSymbols", "showTitle", "sortBy", "showApplicationIcons", "showHexColorSwatch", "previewWidth"
  ]
  static let backupKeys = portableKeys.union([
    "clearOnQuit", "clearSystemClipboard", "clipboardCheckInterval", "enabledPasteboardTypes",
    "ignoreAllAppsExceptListed", "ignoreRegexp", "ignoredApps", "ignoredPasteboardTypes", "historySize",
    "popupPosition", "popupScreen", "showInStatusBar", "showRecentCopyInMenuBar", "suppressClearAlert",
    "windowSize", "windowPosition"
  ])
  static func read(_ keys: Set<String>, from defaults: UserDefaults) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for key in keys {
      if let value = defaults.object(forKey: key) {
        result[key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
      }
    }
    return result
  }
  static func apply(_ values: [String: Data], keys: Set<String>, to defaults: UserDefaults) throws {
    var decoded: [String: Any] = [:]
    for key in keys {
      if let data = values[key] {
        guard let wrapper = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let value = wrapper["value"] else { throw ArchiveError.corrupt }
        decoded[key] = value
      }
    }
    for key in keys {
      if let value = decoded[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
  }
}

@MainActor
protocol CloudTransporting {
  func account() async throws -> String
  func fetch() async throws -> (SyncLedger, CKRecord)
  func save(_ ledger: SyncLedger, record: CKRecord, isCurrent: @escaping @MainActor () -> Bool) async throws
  func cancel()
}

@MainActor
final class CloudTransport: CloudTransporting {
  private let container = CKContainer(identifier: "iCloud.io.damao.coldbrew")
  private var database: CKDatabase { container.privateCloudDatabase }
  private let id = CKRecord.ID(recordName: "clipboard-ledger-v1")
  private var activeSave: CKModifyRecordsOperation?

  func cancel() { activeSave?.cancel() }

  func account() async throws -> String {
    guard try await container.accountStatus() == .available else { throw ArchiveError.unavailable }
    return try await container.userRecordID().recordName
  }

  func fetch() async throws -> (SyncLedger, CKRecord) {
    do {
      let record = try await database.record(for: id)
      guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw ArchiveError.corrupt }
      let ledger = try await Task.detached(priority: .utility) {
        try ArchiveCodec.decode(SyncLedger.self, from: Data(contentsOf: url))
      }.value
      guard ledger.version == 1 else { throw ArchiveError.unsupportedVersion }
      return (ledger, record)
    } catch let error as CKError where error.code == .unknownItem {
      return (SyncLedger(), CKRecord(recordType: "ClipboardLedger", recordID: id))
    }
  }

  func save(_ ledger: SyncLedger, record: CKRecord, isCurrent: @escaping @MainActor () -> Bool) async throws {
    defer { activeSave = nil }
    try await CloudSaveBoundary.run(
      prepare: { try await Task.detached(priority: .utility) { try ArchiveCodec.encode(ledger) }.value },
      isCurrent: isCurrent
    ) { data in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try data.write(to: url, options: .atomic)
      defer { try? FileManager.default.removeItem(at: url) }
      record["payload"] = CKAsset(fileURL: url)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        // No suspension is permitted between this fence and submitting the CloudKit operation.
        guard isCurrent() else { continuation.resume(throwing: CancellationError()); return }
        let operation = CKModifyRecordsOperation(recordsToSave: [record])
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        operation.modifyRecordsResultBlock = { result in
          continuation.resume(with: result.mapError(CloudSaveBoundary.recordError))
        }
        activeSave = operation
        database.add(operation)
      }
      activeSave = nil
    }
  }

}

// Shared by the real transport and deterministic tests of suspended preparation.
@MainActor
enum CloudSaveBoundary {
  nonisolated static func recordError(_ error: Error) -> Error {
    // A single-record operation can wrap its conflict in partialFailure.
    if let cloudError = error as? CKError, cloudError.code == .partialFailure,
       let recordError = cloudError.partialErrorsByItemID?.values.first { return recordError }
    return error
  }
  static func run(
    prepare: () async throws -> Data,
    isCurrent: @MainActor () -> Bool,
    commit: (Data) async throws -> Void
  ) async throws {
    let data = try await prepare()
    guard isCurrent() else { throw CancellationError() }
    try await commit(data)
  }
}

@Observable
@MainActor

final class CloudArchive {
  static let shared = CloudArchive()
  var status = "Sync is off. Backups work independently."
  var busy = false
  private var lastSyncSucceeded = false
  var enabled: Bool { defaults.bool(forKey: "cloudSyncEnabled") }
  var backupRetention: Int {
    get { max(1, defaults.integer(forKey: "cloudBackupRetention") == 0 ? 5 : defaults.integer(forKey: "cloudBackupRetention")) }
    set { defaults.set(max(1, min(30, newValue)), forKey: "cloudBackupRetention") }
  }
  private struct LocalState: Codable, Equatable {
    var storedFiles: [String: String]?
    var device = UUID().uuidString
    var clock: Int64 = 0
    var account: String?
    var ledger = SyncLedger()
    var observed: [String: ArchiveItem] = [:]
    var suppressed: [String: ArchiveStamp] = [:]
    var observedPreferences: [String: Data] = [:]
  }
  private var state = LocalState()
  private var loaded = false
  private var persistedState: LocalState?
  private var persistedRecords: [String: SyncedItem] = [:]
  private var generation = UUID()
  private var activeTransport: (any CloudTransporting)?
  private var task: Task<Void, Never>?
  private var accountObserver: NSObjectProtocol?
  private let directory: URL
  private let defaults: UserDefaults
  private let injectedContext: ModelContext?
  private let injectedTransport: (any CloudTransporting)?
  private let defaultsDomain: String
  private var context: ModelContext { injectedContext ?? Storage.shared.context }

  init(context: ModelContext? = nil, defaults: UserDefaults = .standard, directory: URL? = nil, transport: (any CloudTransporting)? = nil, defaultsDomain: String? = nil) {
    self.injectedContext = context
    self.injectedTransport = transport
    self.defaultsDomain = defaultsDomain ?? Bundle.main.bundleIdentifier ?? "io.damao.coldbrew"
    self.defaults = defaults
    self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Coldbrew/CloudArchive", directoryHint: .isDirectory)
  }

  // Isolated integration tests exercise the same capture/apply paths without a CloudKit container.
  func reconcileForTesting(_ remote: SyncLedger) throws -> SyncLedger {
    precondition(injectedContext != nil)
    try loadState()
    try captureChanges()
    try state.ledger.merge(remote)
    state.clock = max(state.clock, remote.maxCounter)
    try applyLedger()
    try persist()
    return state.ledger
  }

  private var stateURL: URL { directory.appendingPathComponent("state.json") }
  private var backupsURL: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
  private var testing: Bool {
    #if DEBUG
    injectedContext == nil && AppDelegate.isTesting
    #else
    false
    #endif
  }

  func start() {
    guard !testing, injectedContext == nil, task == nil else { return }
    do { try loadState() } catch { status = error.localizedDescription; return }
    accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
      Task { @MainActor in CloudArchive.shared.pauseForAccountChange() }
    }
    task = Task { [weak self] in
      while !Task.isCancelled {
        if let self, self.enabled { await self.sync() }
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }

  private func loadState() throws {
    guard !loaded else { return }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: stateURL.path) {
      state = try ArchiveCodec.decode(LocalState.self, from: Data(contentsOf: stateURL))
      for (id, file) in state.storedFiles ?? [:] {
        guard file.count == 64, file.allSatisfy({ $0.isHexDigit }) else { throw ArchiveError.corrupt }
        let url = directory.appendingPathComponent("Records").appendingPathComponent(file)
        state.ledger.items[id] = try ArchiveCodec.decode(SyncedItem.self, from: Data(contentsOf: url))
      }
      for id in state.observed.keys {
        state.observed[id]?.contents = state.ledger.items[id]?.value.contents ?? []
      }
      persistedRecords = state.ledger.items
      persistedState = state
    }
    loaded = true
  }

  private func persist() throws {
    guard state != persistedState else { return }
    let recordsDirectory = directory.appendingPathComponent("Records", isDirectory: true)
    try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
    let oldFiles = Set((persistedState?.storedFiles ?? state.storedFiles)?.values.map { $0 } ?? [])
    var references = state.storedFiles ?? [:]
    for (id, record) in state.ledger.items where persistedRecords[id] != record || references[id] == nil {
      let data = try ArchiveCodec.encode(record)
      let digest = ArchiveCodec.digest(data)
      try data.write(to: recordsDirectory.appendingPathComponent(digest), options: .atomic)
      references[id] = digest
    }
    references = references.filter { state.ledger.items[$0.key] != nil }
    state.storedFiles = references
    var index = state
    index.ledger.items = [:]
    for id in index.observed.keys { index.observed[id]?.contents = [] }
    // Immutable content files first, atomic index last: a crash cannot expose half a ledger.
    try ArchiveCodec.encode(index).write(to: stateURL, options: .atomic)
    persistedRecords = state.ledger.items
    persistedState = state
    for file in oldFiles.subtracting(Set(references.values)) {
      try? FileManager.default.removeItem(at: recordsDirectory.appendingPathComponent(file))
    }
  }

  func setEnabled(_ value: Bool) {
    guard !testing else { return }
    activeTransport?.cancel()
    generation = UUID()
    defaults.set(value, forKey: "cloudSyncEnabled")
    if value {
      status = "Connecting to iCloud…"
      Task { await sync(approveAccount: true) }
    } else { status = "Sync is off. Existing iCloud data is retained; local history remains available." }
  }

  private func pauseForAccountChange() {
    activeTransport?.cancel()
    generation = UUID()
    defaults.set(false, forKey: "cloudSyncEnabled")
    status = ArchiveError.accountChanged.localizedDescription
  }

  private func stamp() -> ArchiveStamp {
    state.clock = max(state.clock, state.ledger.maxCounter) + 1
    return ArchiveStamp(counter: state.clock, device: state.device)
  }

  // Called before local eviction/quit clearing, and after copy/pin edits, even between polls.
  func capture() {
    guard !testing, enabled else { return }
    do { try loadState(); try captureChanges(); try persist() } catch { status = error.localizedDescription }
  }

  private func captureChanges() throws {
    let models = try context.fetch(FetchDescriptor<HistoryItem>())
    for item in models where item.syncID == nil { item.syncID = ArchiveItem(item).id }
    let local = models.map(ArchiveItem.init)
    for value in local {
      let id = value.id
      let prior = state.observed[id]
      guard prior != value else { continue }
      let old = state.ledger.items[id]
      var copies = old?.copies ?? [:]
      let delta = prior.map { max(0, value.numberOfCopies - $0.numberOfCopies) } ?? value.numberOfCopies
      copies[state.device, default: 0] += delta
      state.ledger.items[id] = SyncedItem(value: value, stamp: stamp(), copies: copies)
      state.observed[id] = value
      state.suppressed.removeValue(forKey: id)
    }
    let explicit = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
    var preferences: [String: Data] = [:]
    for key in CloudPreferences.portableKeys {
      if let value = explicit[key] {
        preferences[key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
      }
    }
    for key in CloudPreferences.portableKeys where preferences[key] != state.observedPreferences[key] {
      state.ledger.preferences[key] = SyncedPreference(value: preferences[key], stamp: stamp())
    }
    state.observedPreferences = preferences
    try context.save()
  }

  func removing(_ items: [HistoryItem], userInitiated: Bool) {
    guard !testing, enabled else { return }
    capture()
    for item in items {
      let id = ArchiveItem(item).id
      guard var entry = state.ledger.items[id] else { continue }
      if userInitiated {
        entry.tombstone(at: stamp())
        state.ledger.items[id] = entry
      }
      state.suppressed[id] = entry.stamp
      state.observed.removeValue(forKey: id)
    }
    do { try persist() } catch { status = error.localizedDescription }
  }

  func sync(approveAccount: Bool = false) async {
    guard enabled, !testing, (injectedContext == nil || injectedTransport != nil), !busy else { return }
    busy = true
    lastSyncSucceeded = false
    let fence = generation
    defer { busy = false; activeTransport = nil }
    do {
      try loadState()
      let transport: any CloudTransporting = injectedTransport ?? CloudTransport()
      activeTransport = transport
      let account = try await transport.account()
      guard enabled, fence == generation else { return }
      if state.account == nil {
        // First connection binds the durable offline journal, including local eviction suppression.
        state.account = account
        try persist()
      } else if state.account != account {
        guard approveAccount else { pauseForAccountChange(); return }
        // A different account receives visible local data, never the previous account's retained ledger.
        state = LocalState(account: account)
        try persist()
      }
      try captureChanges()
      try persist()
      for attempt in 0..<4 {
        let (remote, record) = try await transport.fetch()
        guard enabled, fence == generation else { return }
        let currentAccount = try await transport.account()
        guard enabled, fence == generation else { return }
        guard currentAccount == account else { throw ArchiveError.accountChanged }
        try captureChanges()
        var merged = state.ledger
        try merged.merge(remote)
        state.clock = max(state.clock, remote.maxCounter)
        guard enabled, fence == generation else { return }
        do {
          try await transport.save(merged, record: record) { [weak self] in
            guard let self else { return false }
            return self.enabled && self.generation == fence
          }
        } catch let error as CKError where error.code == .serverRecordChanged && attempt < 3 {
          continue // Refetch: conflict error records do not contain downloadable asset URLs.
        }
        guard enabled, fence == generation else { return }
        let accountAfterSave = try await transport.account()
        guard enabled, fence == generation else { return }
        guard accountAfterSave == account else { throw ArchiveError.accountChanged }
        // Preserve changes made while the save was suspended.
        try captureChanges()
        try merged.merge(state.ledger)
        state.ledger = merged
        try applyLedger()
        try persist()
        if injectedContext == nil {
          try await History.shared.load()
          History.shared.searchQuery = History.shared.searchQuery
        }
        guard enabled, fence == generation else { return }
        lastSyncSucceeded = true
        status = "Synced at \(Date.now.formatted(date: .omitted, time: .shortened)). Cloud retains history until explicitly deleted."
        return
      }
    } catch {
      guard enabled, fence == generation else { return }
      if case ArchiveError.accountChanged = error { pauseForAccountChange() }
      else { status = "Sync paused: \(error.localizedDescription) Local history is available. Retry when ready." }
    }
  }

  private func applyLedger() throws {
    let context = self.context
    let local = try context.fetch(FetchDescriptor<HistoryItem>())
    var byID = Dictionary(local.map { (ArchiveItem($0).id, $0) }, uniquingKeysWith: { first, _ in first })
    let allowed = state.ledger.items.filter { id, record in
      !record.deleted && (state.suppressed[id].map { $0 < record.stamp } ?? true)
    }
    var usedPins: Set<String> = []
    let ordered = allowed.sorted {
      if ($0.value.value.pin != nil) != ($1.value.value.pin != nil) { return $0.value.value.pin != nil }
      if $0.value.value.lastCopiedAt != $1.value.value.lastCopiedAt { return $0.value.value.lastCopiedAt > $1.value.value.lastCopiedAt }
      return $0.key < $1.key
    }
    var unpinned = 0
    var selected: Set<String> = []
    for (id, record) in ordered {
      var value = record.value
      if let pin = value.pin {
        if !HistoryItem.supportedPins.contains(pin) || usedPins.contains(pin) {
          value.pin = HistoryItem.supportedPins.subtracting(usedPins).sorted().first ?? ""
        }
        if let pin = value.pin { usedPins.insert(pin) }
      } else {
        unpinned += 1
        guard unpinned <= max(1, Defaults[.size]) else { continue }
      }
      selected.insert(id)
      value.numberOfCopies = record.copies.values.reduce(0, +)
      if let item = byID.removeValue(forKey: id) { value.apply(to: item) }
      else { context.insert(value.model()) }
      state.observed[id] = value
      state.suppressed.removeValue(forKey: id)
    }
    var seen: Set<String> = []
    for item in local {
      let id = ArchiveItem(item).id
      if !seen.insert(id).inserted { context.delete(item); continue }
      if state.ledger.items[id] != nil && !selected.contains(id) { context.delete(item); state.observed.removeValue(forKey: id) }
    }
    var preferences = state.observedPreferences
    for (key, value) in state.ledger.preferences where CloudPreferences.portableKeys.contains(key) {
      preferences[key] = value.value
    }
    try CloudPreferences.apply(preferences, keys: CloudPreferences.portableKeys, to: defaults)
    state.observedPreferences = preferences
    try context.save()
  }

  private func snapshot() throws -> ClipboardBackup {
    let items = try context.fetch(FetchDescriptor<HistoryItem>()).map(ArchiveItem.init)
    let unique = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ClipboardBackup(items: Array(unique.values), preferences: try CloudPreferences.read(CloudPreferences.backupKeys, from: defaults))
  }

  @discardableResult
  private func checkpoint() throws -> URL {
    try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
    let url = backupsURL.appendingPathComponent("\(Date.now.timeIntervalSince1970)-\(UUID().uuidString).coldbrewbackup")
    try ArchiveCodec.encode(snapshot()).write(to: url, options: .atomic)
    return url
  }

  func exportBackup() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Coldbrew-\(Date.now.formatted(.iso8601.year().month().day())).coldbrewbackup"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try ArchiveCodec.encode(snapshot())
      try data.write(to: url, options: .atomic)
      _ = try checkpoint()
      try pruneBackups()
      status = "Backup saved. File references include paths only, not the referenced files."
    } catch { status = error.localizedDescription }
  }

  private func pruneBackups() throws {
    let files = try FileManager.default.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "coldbrewbackup" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    for file in files.dropFirst(backupRetention) { try FileManager.default.removeItem(at: file) }
  }

  func clearCloudHistory() {
    guard enabled, !busy else { return }
    let alert = NSAlert()
    alert.messageText = "删除所有同步历史？"
    alert.informativeText = "删除本机及云端保留的剪贴板历史（含固定项），并同步到其他设备。独立备份不受影响。离线设备上尚未同步的新增或编辑可能再次出现。"
    alert.addButton(withTitle: "删除同步历史")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      await sync()
      guard enabled, !busy, lastSyncSucceeded else { return }
      for id in state.ledger.items.keys {
        state.ledger.items[id]?.tombstone(at: stamp())
      }
      do {
        try persist()
        try applyLedger()
        try await History.shared.load()
        await sync()
      } catch { status = error.localizedDescription }
    }
  }

  func showBackups() {

    do {
      try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true)
      NSWorkspace.shared.open(backupsURL)
    } catch { status = error.localizedDescription }
  }

  @discardableResult
  func restore(_ backup: ClipboardBackup) throws -> URL {
    try backup.validate()
    let validationSuite = "io.damao.coldbrew.validate.\(UUID().uuidString)"
    let validation = UserDefaults(suiteName: validationSuite)!
    defer { validation.removePersistentDomain(forName: validationSuite) }
    try CloudPreferences.apply(backup.preferences, keys: CloudPreferences.backupKeys, to: validation)
    let recovery = try checkpoint()
    setEnabled(false)
    let context = self.context
    do {
      try context.transaction {
        for item in try context.fetch(FetchDescriptor<HistoryItem>()) { context.delete(item) }
        for value in backup.items { context.insert(value.model()) }
        try context.save()
      }
    } catch { context.rollback(); throw error }
    try CloudPreferences.apply(backup.preferences, keys: CloudPreferences.backupKeys, to: defaults)
    try loadState()
    state.observed = [:]
    state.suppressed = [:]
    for value in backup.items {
      let oldCopies = state.ledger.items[value.id]?.copies
      state.ledger.items[value.id] = SyncedItem(value: value, stamp: stamp(), copies: oldCopies ?? [state.device: value.numberOfCopies])
      state.observed[value.id] = value
    }
    state.observedPreferences = [:]
    try persist()
    return recovery
  }

  func importBackup() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let backup = try ArchiveCodec.decode(ClipboardBackup.self, from: Data(contentsOf: url))
      try backup.validate()
      // Validate preferences fully before any database or preference mutation.
      let validationSuite = "io.damao.coldbrew.validate.\(UUID().uuidString)"
      let validation = UserDefaults(suiteName: validationSuite)!
      defer { validation.removePersistentDomain(forName: validationSuite) }
      try CloudPreferences.apply(backup.preferences, keys: CloudPreferences.backupKeys, to: validation)
      let alert = NSAlert()
      alert.messageText = "Restore \(backup.items.count) clipboard items and settings?"
      alert.informativeText = "This replaces local history and pauses sync. A recovery backup is saved first. Existing iCloud history is unchanged. Enabling sync later merges restored and cloud history."
      alert.addButton(withTitle: "Restore")
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      let recovery = try restore(backup)
      Task { try? await History.shared.load() }
      status = "Restored. Sync is off. Recovery backup: \(recovery.lastPathComponent)."
      // Do not prune on restore: the immediate pre-restore checkpoint must survive.
    } catch { status = error.localizedDescription }
  }
}

struct CloudArchiveSettings: View {
  @State private var archive = CloudArchive.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("同步到私人 iCloud", isOn: Binding(get: { archive.enabled }, set: { archive.setEnabled($0) }))
      Text("启用后上传现有与新增剪贴板内容及通用偏好。含文字、富文本、图片与文件路径，不含路径所指文件。")
      Text("手动删除会同步；本机容量淘汰与退出清理不会删除云端历史。关闭同步保留云端数据。")
      HStack {
        Button("删除同步历史…") { archive.clearCloudHistory() }.disabled(!archive.enabled || archive.busy)
        Button("立即同步") { Task { await archive.sync() } }.disabled(!archive.enabled || archive.busy)
        Button("导出备份…") { archive.exportBackup() }
        Button("恢复备份…") { archive.importBackup() }.disabled(archive.busy)
      }
      HStack {
        Stepper("保留 \(archive.backupRetention) 份本机备份", value: $archive.backupRetention, in: 1...30)
        Button("显示备份") { archive.showBackups() }
      }
      Text("备份独立于同步，包含当前本机历史与设置。导出时保留本机副本；恢复前另存保护副本。导出文件由你保管，可存入 iCloud Drive。")
      Text(archive.status).textSelection(.enabled)
    }
    .font(.caption)
    .fixedSize(horizontal: false, vertical: true)
  }
}
