//
//  Waiter.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Lets a task sleep until something happens or a deadline passes.
@MainActor
final class Waiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var timer: Task<Void, Never>?

    /// Returns when ``wake()`` is called, when `deadline` passes, or when the task is
    /// cancelled, whichever comes first.
    func wait(until deadline: ContinuousClock.Instant) async {
        guard !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                timer = Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    self?.wake()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.wake()
            }
        }
    }

    func wake() {
        timer?.cancel()
        timer = nil
        continuation?.resume()
        continuation = nil
    }
}
