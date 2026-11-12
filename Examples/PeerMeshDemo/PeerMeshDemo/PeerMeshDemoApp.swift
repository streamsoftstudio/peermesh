//
//  PeerMeshDemoApp.swift
//  PeerMeshDemo
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import SwiftUI
import UserNotifications

@main
struct PeerMeshDemoApp: App {
    @State private var chat = Chat()

    var body: some Scene {
        WindowGroup {
            PeersView(chat: chat)
                .task {
                    // Messages that arrive while the app is in the background show up as
                    // notifications.
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
        }
    }
}
