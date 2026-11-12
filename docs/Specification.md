# Specification

What PeerMesh does, in terms an app can rely on and a test can check. It covers
the behavior apps can see; the wire format and routing are internal.

## Platform and transport

- iOS and iPadOS 17.0 or later.
- Bluetooth Low Energy only. Every phone advertises and scans at the same time,
  so any two phones in range can connect. No Wi-Fi network, internet connection,
  accounts or system pairing are used.
- Bluetooth must be on. Airplane mode is fine once Bluetooth is turned back on.
- On the Simulator, and on devices without Bluetooth Low Energy, `state` is
  `.unsupported`.

## Services

- A mesh is identified by its service name. A phone only connects to phones
  whose app created a `Mesh` with exactly the same service name.
- Apps that use the same service name share a mesh, so service names should be
  unique, for example reverse-DNS names.

## Mesh

- Phones connect to phones in Bluetooth range that use the same service, without
  any action from the app. Each phone opens at most 6 connections itself, and
  accepts the ones other phones open to it.
- When two phones connect to each other at the same moment, both keep the
  connection opened by the phone with the smaller ID and drop the other one.
- A connection the other phone sends nothing over for three of its announcement
  intervals is closed. The phones connect again if they're still in range.
- A message crosses at most 7 links (`Mesh.maximumHops`), so it passes through
  at most 6 other phones.
- When a phone in between leaves or moves out of range, messages take another
  route if there is one.
- Only phones whose app has started a `Mesh` with the same service name take
  part, including as relays.
- The design target is up to about 50 phones in one mesh.

## Peers

- `peers` lists every phone that can be reached right now, in Bluetooth range or
  through other phones. It doesn't include this phone, and it's sorted by name,
  then by ID.
- `Peer.hops` is the number of links on the current route. `1` means the phone
  is in Bluetooth range.
- A phone in range disappears from `peers` as soon as Bluetooth reports that the
  connection dropped. A phone reached through others disappears within about 10
  seconds of becoming unreachable, or about 15 in a mesh of 50 phones, where
  phones announce themselves less often.
- `peerUpdates` yields the current list straight away, then the new list after
  every change. Each access returns a new stream, so several parts of an app can
  follow it.
- `Peer.name` is the name the other app passed to `Mesh(service:name:)`,
  shortened to at most 64 bytes of UTF-8. Names aren't unique or verified; IDs
  are.

## Messages

- A message is up to 16 KB of data (`Mesh.maximumMessageSize`). `send` rejects
  larger messages with `messageTooLarge`.
- `send` returns once the recipient's phone has received the message and
  confirmed it. Received means the message is in the recipient's `messages`
  stream, whether or not the app has read it yet.
- If the recipient can't be reached, `send` keeps trying until it can be or the
  timeout passes (30 seconds by default), then throws `timedOut`.
- While the mesh is starting or Bluetooth is off, `send` waits the same way. It
  throws `notRunning` only when the mesh is stopped, or is stopped before the
  message is confirmed.
- After `timedOut`, or when the calling task is cancelled, the recipient may or
  may not have received the message.
- Messages from one phone to another arrive in the order `send` was called. A
  message whose `send` failed never arrives after a message sent later.
- Each message arrives at most once, including across app restarts.
- `messages` keeps incoming messages until the app reads them. It's a single
  stream, meant to be read in one place.

## Identity

- On first use, PeerMesh creates a key pair for the phone and stores it in the
  keychain. It stays on this device: it isn't synced through iCloud Keychain or
  moved to a new phone.
- `PeerID` is derived from the public key: 16 bytes, written as 32 lowercase
  hexadecimal characters. It can be stored as that string or with `Codable`.
- The identity stays the same across app launches and app updates.
- All meshes created by one app share the app's identity.

## Security

- Each message is encrypted for its recipient and authenticated end to end.
  Phones that relay it can't read it, and the recipient rejects it if it was
  changed on the way.
- A phone can't send messages as another phone, or connect under another
  phone's `PeerID`. Each ID is tied to a key that only its own phone holds, and
  phones prove they hold their key when they connect.
- A message only opens in the service it was sent in.
- A relay that records a message and sends it again can't make it arrive twice.

Not protected:

- Who talks to whom. Anyone nearby can see sender and recipient IDs, message
  sizes and timing.
- Names. Peer names are visible to anyone nearby, and a phone that passes an
  announcement on could change the name in it.
- Routes. A phone in the mesh can pass on false announcements about who is
  reachable and how far away, and can drop messages it should pass on. Sends
  then time out. The messages themselves stay unreadable and unchanged.
- Messages recorded before a key is stolen. Someone who copies a phone's key can
  decrypt earlier messages to that phone that they recorded.
- New identities. Anyone can create a new identity under any name. Apps that need
  to know who someone is should remember their `PeerID`.

## Background

With `bluetooth-central` and `bluetooth-peripheral` in the app's
`UIBackgroundModes`:

- Connections stay up while the app is in the background or the screen is
  locked. Messages keep being sent, relayed and delivered.
- Finding new phones is slower. Two phones that both have the app in the
  background may not find each other until one of them opens it.
- Phones keep routes through other phones fresh by announcing themselves, which
  they only do while their app is awake. Incoming frames wake the app, so while
  at least one phone in the mesh has the app open, routes through phones in the
  background keep working. When every phone has the app in the background,
  connections between phones in range stay up, but routes through other phones
  are rebuilt only once someone opens the app.

Without those modes, a phone stops taking part shortly after its app leaves the
screen, and rejoins when the app is opened again.

Either way, a phone leaves the mesh when the user force-quits the app or iOS
ends it, until the app is opened again.

## App requirements

- `NSBluetoothAlwaysUsageDescription` in Info.plist. Without it, iOS stops the
  app when the mesh starts.
- `UIBackgroundModes` with `bluetooth-central` and `bluetooth-peripheral`, for
  the background behavior above.

## Numbers

| Limit | Value |
| --- | --- |
| Message size | up to 16 KB |
| Links per message | up to 7 |
| Default `send` timeout | 30 seconds |
| Unreachable phone removed from `peers` | within about 10 seconds (15 with 50 phones) |
| Connections a phone opens itself | up to 6 |
| Quiet connection closed after | three announcement intervals (about 12 seconds) |
| Name length | up to 64 bytes of UTF-8 |
| Phones per mesh | about 50 (design target) |
| Range per link | roughly 10 to 30 m |
| Throughput | tens of KB/s |

## Not included

- Internet, server or Wi-Fi fallback.
- Android and other non-Apple devices.
- macOS.
- Files, photos, audio or video.
- Broadcasting to everyone, groups or rooms.
- Holding messages for phones that stay out of reach past the timeout.
- Message storage or history.
- Game or session logic, such as invitations and turns.
- User interface.
