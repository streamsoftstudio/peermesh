//
//  Turnstile.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Lets tasks take turns, first come, first served.
@MainActor
final class Turnstile {

    private struct Waiting {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
        let timer: Task<Void, Never>
    }

    private var isTaken = false
    private var queue: [Waiting] = []
    private var nextID = 0

    /// Waits for the caller's turn.
    ///
    /// Throws ``MeshError/timedOut`` if the turn doesn't come by `deadline`, and
    /// `CancellationError` if the task is cancelled first.
    func enter(before deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        guard isTaken else {
            isTaken = true
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self?.remove(id, throwing: MeshError.timedOut)
                }
                queue.append(Waiting(id: id, continuation: continuation, timer: timer))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.remove(id, throwing: CancellationError())
            }
        }
    }

    /// Ends the current turn and gives the next one to the task that has waited longest.
    func leave() {
        guard !queue.isEmpty else {
            isTaken = false
            return
        }
        let next = queue.removeFirst()
        next.timer.cancel()
        next.continuation.resume()
    }

    private func remove(_ id: Int, throwing error: any Error) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiting = queue.remove(at: index)
        waiting.timer.cancel()
        waiting.continuation.resume(throwing: error)
    }
}
