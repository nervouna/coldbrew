# iCloud and backups

Settings → Storage → iCloud 与备份 provides opt-in private iCloud sync and independent backup export/restore.
Sync uploads existing and new clipboard history, including pins, text, rich text, stored image bytes and file references.
File references contain paths, **not the referenced files**, and may be unusable on another Mac.
Appearance, search and paste preferences sync; capture exclusions, local history capacity, screen placement,
hotkeys and launch/system state remain local.

Explicit history deletion syncs across devices. Capacity eviction and clear-on-quit remove only local items;
iCloud retains them until explicit deletion. Newer remote copies may appear again. Use “删除同步历史…” to remove
all currently synchronized history, including cloud-retained items. Deletion markers remain to reconcile stale devices.
Offline concurrent changes resolve deterministically; copy counts merge without counting downloads as copies,
and conflicting pin shortcuts are reassigned consistently. Sync checks every 30 seconds and also supports manual refresh.

Turning sync off preserves existing cloud data. Re-enabling merges local and cloud history; edits/deletes made while
sync was off are not guaranteed to replace the retained cloud history. Account changes pause sync and require enabling
it again. Enabling a different account authorizes uploading the currently visible local history to that account.
Disabling sync or an account-change notification invalidates the current session, prevents its prepared payload from
starting a later upload and cancels its pending CloudKit save operation. Cancellation cannot undo a request already
accepted by the server. Results from an obsolete session are not applied locally, even if sync was enabled again.
Cloud errors, including lack of an account, connectivity or quota, appear in settings while local clipboard use continues.
Large image histories require additional bandwidth and memory because cloud sync exchanges a full snapshot.

“导出备份…” saves a versioned, checksummed document wherever you choose, including iCloud Drive. Backups contain
current local history and user preferences independently of sync; they do not include cloud-only evicted items.
Backups are not password-encrypted, so choose a destination appropriate for your clipboard contents.
Each export also saves a local copy in Application Support/Coldbrew/CloudArchive/Backups; the retention control keeps
1–30 copies (default 5) on the next export. User-managed exports are never automatically deleted.
“显示备份” opens the local backup folder. Restore validates the document before mutation, creates a recovery backup,
replaces local history/settings and pauses sync. Recovery copies are not pruned during restore; a later export applies
the selected retention. Re-enabling sync then merges restored and cloud history. Sync deletion never deletes backup files.

A signed build needs the `iCloud.io.damao.coldbrew` CloudKit container and matching provisioning entitlement.
The private database uses the `ClipboardLedger` record type and `payload` asset field. Production distribution needs
that schema in the production environment. An unsigned build or unit-test pass does not establish real iCloud availability.

### Preference boundaries

| Storage | Preference keys |
| --- | --- |
| Synced and backed up | `highlightMatch`, `imageMaxHeight`, `menuIcon`, `pasteByDefault`, `pinTo`, `openPreviewAutomatically`, `previewDelay`, `removeFormattingByDefault`, `searchMode`, `showFooter`, `showSearch`, `searchVisibility`, `showSpecialSymbols`, `showTitle`, `sortBy`, `showApplicationIcons`, `showHexColorSwatch`, `previewWidth` |
| Backed up, kept local during sync | `clearOnQuit`, `clearSystemClipboard`, `clipboardCheckInterval`, `enabledPasteboardTypes`, `ignoreAllAppsExceptListed`, `ignoreRegexp`, `ignoredApps`, `ignoredPasteboardTypes`, `historySize`, `popupPosition`, `popupScreen`, `showInStatusBar`, `showRecentCopyInMenuBar`, `suppressClearAlert`, `windowSize`, `windowPosition` |
| Neither | App migration flags, usage counters, review prompts, temporary capture pause, global hotkeys, login registration, sync account/device state and backup retention controls |

### Validation

`ColdbrewTests/CloudArchiveTests` uses in-memory SwiftData stores, temporary preferences/directories and fake CloudKit
transport. It exercises reconciliation, concurrent copy counters, content edits, pin conflicts, deletion, local eviction,
restart persistence, preference boundaries, image/reference round-trips, actual restore/recovery, malformed backup
rejection, account/disable fences, quota failure and local edits during an upload with a newer remote clock.
Real acceptance additionally requires two signed installations with the same Apple account, provisioned development
container/schema, isolated test clipboard data and offline/reconnect/account/quota checks. The tests never establish
those external prerequisites or authorize uploading real clipboard history.
