# PeerMesh

Send messages between nearby iPhones and iPads over Bluetooth, with no Wi-Fi
network, internet connection or pairing. Phones that are out of range of each
other can still reach each other: other phones running the same app pass the
messages along.

It's meant for apps like a chess game played with someone a few rows away on a
plane.

**Status:** in development. It's implemented and covered by tests that simulate
phones in memory, but it hasn't been tried on real devices yet.

## Features

- **Nearby phones find each other.** Each app picks a service name, and phones
  only connect to phones that use the same one. No network, accounts or pairing
  are involved.
- **The mesh forms by itself.** Phones connect to whoever is in Bluetooth range.
  A message for a phone that's out of range travels through other phones, across
  up to 7 links, and takes another route when a phone in between leaves.
- **A live list of who you can reach**, with each person's name and how many
  links away they are.
- **Small messages to one peer at a time.** `send` returns once the recipient's
  phone confirms the message, and throws if that doesn't happen in time.
  Messages to the same peer arrive in order and at most once.
- **Incoming messages as an async stream**, each with its sender.
- **A stable identity.** A phone keeps the same `PeerID` across app launches, so
  an app can recognize someone it has played with before.
- **End-to-end encryption.** Only the recipient can read a message. Phones that
  pass it along can't read or change it, and no phone can use another phone's
  identity.
- **Works with the screen locked.** With Bluetooth background modes enabled,
  connections stay up while the app is in the background, and messages keep
  arriving.

## Not included

- Internet, server or Wi-Fi fallback.
- Android and other non-Apple devices.
- Files, photos, audio or video. A message is at most 16 KB.
- Broadcasting to everyone, groups or rooms.
- Holding a message for someone who stays out of reach past the timeout.
- Message storage or history.
- Invitations, turns or any other game or session logic. Apps build these from
  messages.
- User interface.
- Large crowds. A mesh is designed for up to about 50 phones.

## Requirements

- iOS or iPadOS 17.0+
- Swift 6.0+
- Real devices. The Simulator has no Bluetooth, so testing takes two phones, or
  three to see a message relayed.

## Installation

### Swift Package Manager

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/streamsoftstudio/peermesh.git", from: "0.1.0")
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL.

### Info.plist

- `NSBluetoothAlwaysUsageDescription`: why your app uses Bluetooth. iOS shows it
  in the permission prompt, and an app without it is stopped by iOS when the mesh
  starts.
- `UIBackgroundModes` with `bluetooth-central` and `bluetooth-peripheral`, to keep
  working in the background and with the screen locked. App Review checks that
  your app needs them.

## Usage

```swift
import PeerMesh

let mesh = try Mesh(service: "com.example.chess", name: "Andrija")
mesh.start()
```

Pick a service name that other apps won't use by accident; a reverse-DNS name
works well. Phones only connect to phones that use exactly the same one.

Everyone you can reach, in Bluetooth range or through other phones:

```swift
for await peers in mesh.peerUpdates {
    // The current list first, then the new list after every change.
    // Each peer has an id, a name and hops.
}
```

Send a message. `send` returns once the other phone confirms it:

```swift
try await mesh.send(moveData, to: opponent.id)
```

Receive messages:

```swift
for await message in mesh.messages {
    // message.sender, message.data
}
```

`mesh.state` and `mesh.stateUpdates` tell you whether the mesh is running, or why
it isn't: Bluetooth is off, the user denied access, or the device has no
Bluetooth.

## Limits

- Range is roughly 10 to 30 meters per link, and less through walls, seats and
  people.
- Throughput is tens of kilobytes per second: enough for moves, chat and game
  state.
- Only phones where an app with the same service name is running take part,
  including as relays.
- In the background, finding new phones is slower. Two phones that both have the
  app in the background may not find each other until one of them opens it.
- Force-quitting the app takes the phone out of the mesh until the app is opened
  again.

[docs/Specification.md](docs/Specification.md) describes the behavior in full.

## Demo

[Examples/PeerMeshDemo](Examples/PeerMeshDemo) is a small app for trying PeerMesh
on real phones. It lists the phones in reach, sends messages and pings, and shows
messages that arrive while the screen is locked.

## License

PeerMesh is available under the Apache License 2.0. See [LICENSE](LICENSE) for
details.
