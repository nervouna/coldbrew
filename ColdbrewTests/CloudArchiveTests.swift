import XCTest
import CloudKit
import SwiftData
import Defaults
@testable import Coldbrew

@MainActor
final class CloudArchiveTests: XCTestCase {
  private var containers: [ModelContainer] = []
  private var suites: [String] = []
  private var directories: [URL] = []

  override func tearDown() {
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    containers = []
    super.tearDown()
  }

  private func device(transport: (any CloudTransporting)? = nil) throws -> (CloudArchive, ModelContext, UserDefaults) {
    let container = try ModelContainer(for: HistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    containers.append(container)
    let suite = "io.damao.coldbrew.cloud-tests.\(UUID().uuidString)"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: "cloudSyncEnabled")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(directory)
    return (CloudArchive(context: container.mainContext, defaults: defaults, directory: directory, transport: transport, defaultsDomain: suite), container.mainContext, defaults)
  }

  private func item(_ text: String, context: ModelContext) -> HistoryItem {
    let item = HistoryItem(contents: [HistoryItemContent(type: "public.utf8-plain-text", value: Data(text.utf8))])
    item.title = text
    context.insert(item)
    return item
  }

  func testConcurrentCopiesConvergeWithoutInflation() throws {
    let (a, ac, _) = try device()
    let (b, bc, _) = try device()
    _ = item("same", context: ac)
    _ = item("same", context: bc)
    let av = try a.reconcileForTesting(SyncLedger())
    let bv = try b.reconcileForTesting(SyncLedger())
    let mergedA = try a.reconcileForTesting(bv)
    let mergedB = try b.reconcileForTesting(av)
    XCTAssertEqual(mergedA, mergedB)
    let again = try a.reconcileForTesting(mergedB)
    XCTAssertEqual(again.items.values.first?.value.numberOfCopies, 2)
    XCTAssertEqual(try ac.fetch(FetchDescriptor<HistoryItem>()).count, 1)
  }

  func testTransientMarkersDoNotChangeIdentity() throws {
    let (_, context, _) = try device()
    let first = item("same", context: context)
    let second = item("same", context: context)
    second.contents.append(HistoryItemContent(type: "io.damao.coldbrew", value: Data("marker".utf8)))
    XCTAssertEqual(ArchiveItem(first).id, ArchiveItem(second).id)
  }

  func testEditKeepsIdentityAndUpdatesRemoteBytes() throws {
    let (a, ac, _) = try device()
    let (b, bc, _) = try device()
    let original = item("before", context: ac)
    let initial = try a.reconcileForTesting(SyncLedger())
    _ = try b.reconcileForTesting(initial)
    original.contents[0].value = Data("after".utf8)
    let changed = try a.reconcileForTesting(SyncLedger())
    _ = try b.reconcileForTesting(changed)
    let records = try bc.fetch(FetchDescriptor<HistoryItem>())
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.text, "after")
    XCTAssertEqual(initial.items.keys.sorted(), changed.items.keys.sorted())
  }

  func testExplicitDeletePropagatesAndRedactsTombstone() throws {
    let (a, ac, _) = try device()
    let (b, bc, _) = try device()
    let original = item("secret", context: ac)
    let initial = try a.reconcileForTesting(SyncLedger())
    _ = try b.reconcileForTesting(initial)
    a.removing([original], userInitiated: true)
    ac.delete(original)
    try ac.save()
    let deleted = try a.reconcileForTesting(SyncLedger())
    _ = try b.reconcileForTesting(deleted)
    XCTAssertTrue(deleted.items.values.first!.deleted)
    XCTAssertTrue(deleted.items.values.first!.value.contents.isEmpty)
    XCTAssertEqual(deleted.items.values.first!.value.title, "")
    XCTAssertTrue(try bc.fetch(FetchDescriptor<HistoryItem>()).isEmpty)
  }

  func testEvictionStaysLocalAndRecopyIsCounted() throws {
    let (a, ac, _) = try device()
    let (b, bc, _) = try device()
    let original = item("retained", context: ac)
    let initial = try a.reconcileForTesting(SyncLedger())
    a.removing([original], userInitiated: false)
    ac.delete(original)
    try ac.save()
    let evicted = try a.reconcileForTesting(initial)
    XCTAssertTrue(try ac.fetch(FetchDescriptor<HistoryItem>()).isEmpty)
    _ = try b.reconcileForTesting(evicted)
    XCTAssertEqual(try bc.fetch(FetchDescriptor<HistoryItem>()).count, 1)
    _ = item("retained", context: ac)
    let recopied = try a.reconcileForTesting(evicted)
    XCTAssertEqual(recopied.items.values.first?.value.numberOfCopies, 2)
  }

  func testLocalDuplicateRowsCollapse() throws {
    let (archive, context, _) = try device()
    _ = item("same", context: context)
    _ = item("same", context: context)
    _ = try archive.reconcileForTesting(SyncLedger())
    XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).count, 1)
  }

  func testPinsResolveDeterministically() throws {
    let (a, ac, _) = try device()
    let (b, bc, _) = try device()
    item("one", context: ac).pin = "b"
    item("two", context: bc).pin = "b"
    let av = try a.reconcileForTesting(SyncLedger())
    let bv = try b.reconcileForTesting(SyncLedger())
    _ = try a.reconcileForTesting(bv)
    _ = try b.reconcileForTesting(av)
    let ap = try ac.fetch(FetchDescriptor<HistoryItem>()).map { ($0.text!, $0.pin!) }.sorted { $0.0 < $1.0 }
    let bp = try bc.fetch(FetchDescriptor<HistoryItem>()).map { ($0.text!, $0.pin!) }.sorted { $0.0 < $1.0 }
    XCTAssertEqual(ap.map(\.1), bp.map(\.1))
    XCTAssertEqual(Set(ap.map(\.1)).count, 2)
  }

  func testPreferenceWhitelistAndBidirectionalUpdate() throws {
    let (a, _, ad) = try device()
    let (b, _, bd) = try device()
    ad.set(false, forKey: "showTitle")
    ad.set(500, forKey: "historySize")
    ad.set(["private.app"], forKey: "ignoredApps")
    let initial = try a.reconcileForTesting(SyncLedger())
    _ = try b.reconcileForTesting(initial)
    XCTAssertEqual(bd.object(forKey: "showTitle") as? Bool, false)
    XCTAssertNotEqual(bd.integer(forKey: "historySize"), 500)
    XCTAssertNotEqual(bd.stringArray(forKey: "ignoredApps"), ["private.app"])
    bd.set(true, forKey: "showTitle")
    let changed = try b.reconcileForTesting(SyncLedger())
    _ = try a.reconcileForTesting(changed)
    XCTAssertTrue(ad.bool(forKey: "showTitle"))
  }

  func testBackupRoundTripsImageAndReferenceWithoutReadingFile() throws {
    let (_, context, _) = try device()
    let original = item("backup", context: context)
    original.contents.append(HistoryItemContent(type: "public.png", value: Data([0, 1, 2, 255])))
    original.contents.append(HistoryItemContent(type: "public.file-url", value: Data("file:///missing/example".utf8)))
    let snapshot = ClipboardBackup(items: [ArchiveItem(original)], preferences: [:])
    let data = try ArchiveCodec.encode(snapshot)
    let decoded = try ArchiveCodec.decode(ClipboardBackup.self, from: data)
    try decoded.validate()
    XCTAssertEqual(decoded.items, snapshot.items)
    XCTAssertEqual(decoded.items[0].model().contents.map(\.value), original.contents.map(\.value))
  }

  func testCorruptBackupRejectedBeforeMutation() throws {
    let (_, context, _) = try device()
    let original = item("keep", context: context)
    let snapshot = ClipboardBackup(items: [ArchiveItem(original)], preferences: [:])
    var envelope = try JSONDecoder().decode(ArchiveCodec.Envelope.self, from: ArchiveCodec.encode(snapshot))
    envelope.payload.append(0)
    let corrupt = try ArchiveCodec.encoder.encode(envelope)
    XCTAssertThrowsError(try ArchiveCodec.decode(ClipboardBackup.self, from: corrupt))
    XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).first?.text, "keep")
    envelope.version = 99
    XCTAssertThrowsError(try ArchiveCodec.decode(ClipboardBackup.self, from: ArchiveCodec.encoder.encode(envelope)))
  }
func testRestoreReplacesDataAndCreatesRecoverableCheckpoint() throws {
  let (archive, context, defaults) = try device()
  let old = item("old", context: context)
  let replacement = ArchiveItem(old)
  var backup = ClipboardBackup(items: [replacement], preferences: [:])
  backup.items[0].contents[0].value = Data("restored".utf8)
  defaults.set(false, forKey: "showTitle")
  let recovery = try archive.restore(backup)
  XCTAssertFalse(archive.enabled)
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).map(\.text), ["restored"])
  let checkpoint = try ArchiveCodec.decode(ClipboardBackup.self, from: Data(contentsOf: recovery))
  XCTAssertEqual(checkpoint.items.first?.contents[0].value, Data("old".utf8))
  _ = try archive.restore(checkpoint)
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).map(\.text), ["old"])
  XCTAssertFalse(defaults.bool(forKey: "showTitle"))
}

func testInvalidRestoreDoesNotChangeDataOrPreferences() throws {
  let (archive, context, defaults) = try device()
  let original = item("keep", context: context)
  defaults.set(false, forKey: "showTitle")
  let backup = ClipboardBackup(items: [ArchiveItem(original)], preferences: ["showTitle": Data([0, 1])])
  XCTAssertThrowsError(try archive.restore(backup))
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).first?.text, "keep")
  XCTAssertFalse(defaults.bool(forKey: "showTitle"))
  XCTAssertTrue(archive.enabled)
}

func testDisableDuringFetchFencesUploadAndRemoteApplication() async throws {
  let transport = FakeCloudTransport()
  let (archive, context, _) = try device(transport: transport)
  _ = item("local", context: context)
  transport.onFetch = { archive.setEnabled(false) }
  await archive.sync()
  XCTAssertEqual(transport.saves, 0)
  XCTAssertFalse(archive.enabled)
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).first?.text, "local")
}

func testAccountChangeDuringFetchPausesSync() async throws {
  let transport = FakeCloudTransport()
  let (archive, context, _) = try device(transport: transport)
  _ = item("local", context: context)
  transport.onFetch = { transport.accountID = "different-account" }
  await archive.sync()
  XCTAssertEqual(transport.saves, 0)
  XCTAssertFalse(archive.enabled)
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).first?.text, "local")
}

func testCloudFailureKeepsLocalClipboardAvailable() async throws {
  let transport = FakeCloudTransport()
  transport.failure = CKError(.quotaExceeded)
  let (archive, context, _) = try device(transport: transport)
  _ = item("local", context: context)
  await archive.sync()
  XCTAssertEqual(transport.saves, 0)
  XCTAssertTrue(archive.status.contains("paused"))
  XCTAssertEqual(try context.fetch(FetchDescriptor<HistoryItem>()).first?.text, "local")
}

func testLocalEditDuringUploadUsesObservedRemoteClock() async throws {
  let transport = FakeCloudTransport()
  let (archive, context, _) = try device(transport: transport)
  let local = item("same", context: context)
  var remote = try archive.reconcileForTesting(SyncLedger())
  let id = remote.items.keys.first!
  remote.items[id]!.stamp = ArchiveStamp(counter: 1_000, device: "remote")
  remote.items[id]!.value.title = "remote title"
  transport.remote = remote
  transport.onSave = {
    local.title = "local edit during upload"
    archive.capture()
  }
  await archive.sync()
  XCTAssertEqual(local.title, "local edit during upload")
  let result = try archive.reconcileForTesting(remote)
  XCTAssertGreaterThan(result.items[id]!.stamp.counter, 1_000)
  XCTAssertEqual(result.items[id]!.value.title, "local edit during upload")
}

func testRestartPreservesLedgerIdentityCountsAndLocalSuppression() throws {
  let (archive, context, defaults) = try device()
  let original = item("retained", context: context)
  _ = try archive.reconcileForTesting(SyncLedger())
  archive.removing([original], userInitiated: false)
  context.delete(original)
  try context.save()
  let before = try archive.reconcileForTesting(SyncLedger())
  let restarted = CloudArchive(context: context, defaults: defaults, directory: directories.last!, defaultsDomain: suites.last!)
  let after = try restarted.reconcileForTesting(before)
  XCTAssertEqual(before, after)
  XCTAssertTrue(try context.fetch(FetchDescriptor<HistoryItem>()).isEmpty)
  _ = item("retained", context: context)
  let copied = try restarted.reconcileForTesting(after)
  XCTAssertEqual(copied.items.values.first?.value.numberOfCopies, 2)
}

func testDisableWhilePreparingUploadPreventsRequestAndCancelsTransport() async throws {
  let transport = FakeCloudTransport()
  let gate = CloudTestGate()
  let (archive, context, _) = try device(transport: transport)
  _ = item("local", context: context)
  transport.prepareUpload = { await gate.suspend() }
  let sync = Task { await archive.sync() }
  await gate.waitUntilEntered()
  archive.setEnabled(false)
  gate.release()
  await sync.value
  XCTAssertEqual(transport.saves, 0)
  XCTAssertEqual(transport.cancellations, 1)
  XCTAssertFalse(archive.enabled)
}

func testDisabledThenEnabledSessionCannotCommitOldPreparedPayload() async throws {
  let gate = CloudTestGate()
  var generation = 1
  var enabled = true
  var committed = false
  let originalGeneration = generation
  let pending = Task {
    try await CloudSaveBoundary.run(prepare: {
      await gate.suspend()
      return Data()
    }, isCurrent: { enabled && generation == originalGeneration }) { _ in
      committed = true
    }
  }
  await gate.waitUntilEntered()
  enabled = false
  generation += 1
  enabled = true
  generation += 1
  gate.release()
  do { try await pending.value; XCTFail("Expected the obsolete session to be rejected") }
  catch { XCTAssertTrue(error is CancellationError) }
  XCTAssertFalse(committed)
}

func testDisableDuringPostSaveAccountQueryPreventsRemoteApplication() async throws {
  let transport = FakeCloudTransport()
  let gate = CloudTestGate()
  let (archive, context, _) = try device(transport: transport)
  let local = item("local", context: context)
  var remote = try archive.reconcileForTesting(SyncLedger())
  let id = remote.items.keys.first!
  remote.items[id]!.stamp = ArchiveStamp(counter: 1_000, device: "remote")
  remote.items[id]!.value.title = "remote title"
  transport.remote = remote
  transport.onAccount = { query in if query == 3 { await gate.suspend() } }
  let sync = Task { await archive.sync() }
  await gate.waitUntilEntered()
  archive.setEnabled(false)
  gate.release()
  await sync.value
  XCTAssertEqual(transport.saves, 1)
  XCTAssertEqual(local.title, "local")
  XCTAssertFalse(archive.enabled)
  XCTAssertEqual(transport.cancellations, 1)
}

func testRecordConflictSurvivesOperationErrorWrapping() {
  let error = CKError(.partialFailure, userInfo: [
    CKPartialErrorsByItemIDKey: [CKRecord.ID(recordName: "ledger"): CKError(.serverRecordChanged)]
  ])
  XCTAssertEqual((CloudSaveBoundary.recordError(error) as? CKError)?.code, .serverRecordChanged)
}

func testFirstAccountBindingPreservesOfflineEvictionAcrossRestart() async throws {
  let transport = FakeCloudTransport()
  transport.accountFailure = CKError(.networkUnavailable)
  let (archive, context, defaults) = try device(transport: transport)
  await archive.sync()
  XCTAssertEqual(transport.saves, 0)

  let local = item("copied before first connection", context: context)
  local.numberOfCopies = 3
  archive.capture()
  let id = ArchiveItem(local).id
  archive.removing([local], userInitiated: false)
  context.delete(local)
  try context.save()

  let restarted = CloudArchive(
    context: context, defaults: defaults, directory: directories.last!,
    transport: transport, defaultsDomain: suites.last!
  )
  transport.accountFailure = nil
  await restarted.sync()
  XCTAssertEqual(transport.saves, 1)
  let uploaded = try XCTUnwrap(transport.savedLedgers.last?.items[id])
  XCTAssertEqual(uploaded.value.numberOfCopies, 3)
  XCTAssertEqual(uploaded.copies.values.reduce(0, +), 3)
  XCTAssertFalse(uploaded.deleted)
  XCTAssertTrue(try context.fetch(FetchDescriptor<HistoryItem>()).isEmpty)
}

func testApprovedDifferentAccountExcludesPreviousAccountRetainedHistory() async throws {
  let transport = FakeCloudTransport()
  let (archive, context, _) = try device(transport: transport)
  let retained = item("previous account only", context: context)
  await archive.sync()
  let retainedID = ArchiveItem(retained).id
  archive.removing([retained], userInitiated: false)
  context.delete(retained)
  try context.save()
  let visible = item("visible local history", context: context)
  archive.capture()
  let visibleID = ArchiveItem(visible).id

  transport.accountID = "approved-second-account"
  await archive.sync(approveAccount: true)
  let uploaded = try XCTUnwrap(transport.savedLedgers.last)
  XCTAssertNil(uploaded.items[retainedID])
  XCTAssertNotNil(uploaded.items[visibleID])
  XCTAssertEqual(uploaded.items.count, 1)
}

}

@MainActor
private final class FakeCloudTransport: CloudTransporting {
  var accountID = "test-account"
  var onFetch: (() -> Void)?
  var saves = 0
  var failure: Error?
  var accountFailure: Error?
  var savedLedgers: [SyncLedger] = []
  var remote = SyncLedger()
  var onSave: (() -> Void)?
  var prepareUpload: (() async -> Void)?
  var onAccount: ((Int) async -> Void)?
  var accountQueries = 0
  var cancellations = 0
  func account() async throws -> String {
    if let accountFailure { throw accountFailure }
    accountQueries += 1
    if let onAccount { await onAccount(accountQueries) }
    return accountID
  }
  func fetch() async throws -> (SyncLedger, CKRecord) {
    if let failure { throw failure }
    onFetch?()
    return (remote, CKRecord(recordType: "Test", recordID: CKRecord.ID(recordName: "test")))
  }
  func save(_ ledger: SyncLedger, record: CKRecord, isCurrent: @escaping @MainActor () -> Bool) async throws {
    try await CloudSaveBoundary.run(prepare: {
      if let prepareUpload { await prepareUpload() }
      return Data()
    }, isCurrent: isCurrent) { _ in
      saves += 1
      savedLedgers.append(ledger)
      onSave?()
    }
  }
  func cancel() { cancellations += 1 }
}

@MainActor
private final class CloudTestGate {
  private var entered = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var suspended: CheckedContinuation<Void, Never>?
  func suspend() async {
    await withCheckedContinuation { continuation in
      suspended = continuation
      entered = true
      arrival?.resume()
      arrival = nil
    }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func release() {
    suspended?.resume()
    suspended = nil
  }
}
