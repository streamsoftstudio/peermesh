# PeerMesh Demo

A small app for trying PeerMesh on real phones. It lists the phones in reach and
lets you send messages to any of them.

## Running it

1. Open `PeerMeshDemo.xcodeproj` in Xcode.
2. In the PeerMeshDemo target's **Signing & Capabilities**, choose your team, and
   change the bundle identifier to one of yours if needed.
3. Run it on two or more iPhones or iPads with Bluetooth turned on. The Simulator
   has no Bluetooth.
4. Allow Bluetooth when asked. Allowing notifications lets the app show messages
   that arrive while it's in the background.

## What to try

- **Messages:** tap a phone in the list, then type and send a message. Each
  message you send shows when the other phone confirmed it, or why it didn't.
- **Ping:** sends a short message. The time it shows is the round trip to the
  other phone and back.
- **Screen locked:** lock one phone and send it a message from another. It
  arrives as a notification.
- **Relaying:** use three phones. Put the first and the last out of each other's
  range, with the middle one in range of both, for example at opposite ends of a
  building. The far phone shows up two hops away, and messages to it pass through
  the middle one.
- **Leaving:** force-quit the app on one phone, or walk out of range. The phone
  disappears from the others' lists.
- **Rename:** changes the name other phones see. The phone keeps its ID.
