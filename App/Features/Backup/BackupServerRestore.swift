import Foundation
import SwiftData

/// Where a picked backup goes. `.replace` never writes the in-memory
/// store first: the document is POSTed as `v1/backup/import` (REPLACE)
/// and the online store reloads from the export. `.merge` restores into
/// memory and the engine pushes the diff — a large file can take a while.
enum BackupRestoreRoute: Equatable, Sendable {
    case replaceOnServer
    case mergeInMemory
}

enum BackupRestoreRouting {
    static func route(for mode: BackupRestoreMode) -> BackupRestoreRoute {
        switch mode {
        case .replace: return .replaceOnServer
        case .merge: return .mergeInMemory
        }
    }
}

/// Outcome of `BackupServerRestore.perform`. A server replace does not
/// report local insert counts — the reload replaces the store wholesale.
enum BackupServerRestoreOutcome: Equatable, Sendable {
    case replacedOnServer
    case merged(BackupRestoreResult)
}

/// A reload that did not leave the store ready.
struct BackupRestoreFailure: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// Routes a decoded backup. Tests inject the import and reload seams;
/// `BackupView` wires them to `OnlineStore`.
@MainActor
struct BackupServerRestore {
    var importReplace: (Data) async throws -> Void
    var reload: () async throws -> Void

    func perform(
        _ document: BackupDocument,
        mode: BackupRestoreMode,
        into context: ModelContext
    ) async throws -> BackupServerRestoreOutcome {
        switch BackupRestoreRouting.route(for: mode) {
        case .replaceOnServer:
            try await importReplace(try BackupCodec.encode(document))
            try await reload()
            return .replacedOnServer
        case .mergeInMemory:
            let result = try BackupRestorer.restore(
                document, mode: .merge, into: context)
            return .merged(result)
        }
    }
}
