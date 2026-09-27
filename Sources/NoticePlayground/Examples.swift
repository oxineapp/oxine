import AppKit
import NoticeBridge
import SwiftUI

/// Ready-made notices, grouped by what they show off: one-liners in an ear,
/// ones with more to read under the notch, live updates, urgency, collisions,
/// the list, forced spots, pictures, motion and sound.
@MainActor
enum Examples {
    struct Example: Identifiable {
        let id: String
        let name: String
        let icon: String
        let run: () -> Void
    }

    struct Group: Identifiable {
        let name: String
        /// What to look for.
        let note: String
        let examples: [Example]
        var id: String { name }
    }

    static var groups: [Group] {
        [
            Group(name: "Floating island", note: "Circles when a ring, an emoji or a short value is enough; pills for a line. Under the notch, as wide as it: a pill and two circles, or four circles, never two pills. A pill opens into its card; a circle only grows into a small capsule with a button or two.", examples: [
                Example(id: "ring", name: "Upload ring", icon: "circle.dashed", run: uploadRing),
                Example(id: "timercircle", name: "Timer circle", icon: "timer", run: timerCircle),
                Example(id: "recording", name: "Recording", icon: "record.circle", run: recording),
                Example(id: "streak", name: "Emoji circle", icon: "flame.fill", run: streak),
                Example(id: "calling", name: "Someone calling", icon: "phone.fill", run: calling),
                Example(id: "airpodsring", name: "AirPods ring", icon: "airpodspro", run: airpodsRing),
                Example(id: "pillcircle", name: "Pill and circle", icon: "capsule.lefthalf.filled", run: pillAndCircle),
                Example(id: "pilltwo", name: "Pill, two circles", icon: "circle.grid.2x1.fill", run: pillAndTwoCircles),
                Example(id: "fourcircles", name: "Four circles", icon: "circle.grid.2x2.fill", run: fourCircles),
                Example(id: "twopills", name: "Two pills (one waits)", icon: "capsule.fill", run: twoPills),
            ]),
            Group(name: "Personal", note: "From people: their picture or initials, their words in a bubble and emoji reactions. On the notch by default; floating, the reply field takes typing too.", examples: [
                Example(id: "reply", name: "Message, reply", icon: "arrowshape.turn.up.left.fill", run: messageReply),
                Example(id: "mom", name: "Mom", icon: "heart.fill", run: momMessage),
                Example(id: "groupchat", name: "Group chat", icon: "person.3.fill", run: groupChat),
                Example(id: "shared", name: "Shared a photo", icon: "photo.fill", run: picture),
                Example(id: "birthday", name: "Birthday", icon: "birthday.cake.fill", run: birthday),
                Example(id: "voicecall", name: "Incoming call", icon: "phone.arrow.down.left.fill", run: incomingCall),
                Example(id: "missedperson", name: "Missed call", icon: "phone.down.fill", run: missedCall),
            ]),
            Group(name: "Big values", note: "The one number that matters, big: a timer, a score, a battery, minutes away.", examples: [
                Example(id: "herotimer", name: "Timer", icon: "timer", run: countdown),
                Example(id: "heroscore", name: "Score", icon: "soccerball", run: score),
                Example(id: "herobattery", name: "Battery", icon: "battery.25", run: battery),
                Example(id: "heroride", name: "Ride", icon: "car.fill", run: ride),
                Example(id: "steps", name: "Steps goal", icon: "figure.walk", run: steps),
                Example(id: "oven", name: "Oven ready", icon: "flame", run: oven),
            ]),
            Group(name: "How they arrive", note: "Floating: knock-knock, a ringing halo, a shake for what failed, confetti for what's done. And a button you hold for what's hard to undo.", examples: [
                Example(id: "knockknock", name: "Knock knock", icon: "hand.raised.fill", run: knockKnock),
                Example(id: "bell", name: "Doorbell", icon: "bell.fill", run: doorbellRing),
                Example(id: "failed", name: "Build failed", icon: "hammer.fill", run: { post(floating(buildFailed), "Build") }),
                Example(id: "done", name: "Done!", icon: "checkmark.seal.fill", run: done),
                Example(id: "package2", name: "Package", icon: "shippingbox.fill", run: packageBounce),
                Example(id: "hold", name: "Hold to empty", icon: "trash.fill", run: emptyTrash),
            ]),
            Group(name: "In an ear", note: "For apps that ask for an ear. One line beside the notch; point at it and the icon turns into ×, the title into its buttons, the ear widening to fit them.", examples: [
                Example(id: "copied", name: "Copied", icon: "doc.on.doc.fill", run: copied),
                Example(id: "airpods", name: "AirPods", icon: "airpodspro", run: airpods),
                Example(id: "wifi", name: "Wi-Fi", icon: "wifi", run: wifi),
                Example(id: "doorbell", name: "Doorbell", icon: "bell.fill", run: doorbell),
                Example(id: "knock", name: "Someone's knocking", icon: "hand.raised.fill", run: knock),
                Example(id: "airdrop", name: "AirDrop", icon: "airplayaudio", run: airdrop),
                Example(id: "allow", name: "Allow or deny", icon: "mic.fill", run: allowMic),
                Example(id: "screenshot", name: "Screenshot", icon: "camera.viewfinder", run: screenshot),
                Example(id: "focus", name: "Focus on", icon: "moon.fill", run: focus),
                Example(id: "muted", name: "Muted", icon: "speaker.slash.fill", run: muted),
                Example(id: "mouse", name: "Mouse battery", icon: "magicmouse.fill", run: mouse),
                Example(id: "link", name: "Link copied", icon: "link", run: link),
                Example(id: "charging", name: "Charging", icon: "bolt.fill", run: charging),
                Example(id: "tea", name: "Timer done", icon: "cup.and.saucer.fill", run: teaReady),
            ]),
            Group(name: "Under the notch", note: "Detail to read or several buttons. Point at it and it opens downward, as wide as the notch.", examples: [
                Example(id: "message", name: "Message", icon: "message.fill", run: message),
                Example(id: "agent", name: "Agent needs you", icon: "terminal.fill", run: agent),
                Example(id: "meeting", name: "Meeting", icon: "calendar", run: meeting),
                Example(id: "build", name: "Build failed", icon: "hammer.fill", run: build),
                Example(id: "mail", name: "Email", icon: "envelope.fill", run: mail),
                Example(id: "invite", name: "Invite, 3 buttons", icon: "calendar.badge.plus", run: invite),
                Example(id: "package", name: "Package arrived", icon: "shippingbox.fill", run: package),
                Example(id: "update", name: "Update ready", icon: "arrow.triangle.2.circlepath", run: update),
                Example(id: "review", name: "Review requested", icon: "arrow.triangle.pull", run: review),
                Example(id: "long", name: "Long text", icon: "text.alignleft", run: longText),
            ]),
            Group(name: "Live", note: "Updated in place: they keep their spot and don't replay their entrance.", examples: [
                Example(id: "download", name: "Download", icon: "arrow.down.circle.fill", run: download),
                Example(id: "countdown", name: "Countdown", icon: "timer", run: countdown),
                Example(id: "export", name: "Export video", icon: "film.fill", run: export),
                Example(id: "ride", name: "Ride arriving", icon: "car.fill", run: ride),
                Example(id: "score", name: "Live score", icon: "soccerball", run: score),
                Example(id: "stopwatch", name: "Stopwatch", icon: "stopwatch.fill", run: stopwatch),
                Example(id: "fullcharge", name: "Charging to full", icon: "battery.100.bolt", run: chargeToFull),
                Example(id: "backup", name: "Backup (waits)", icon: "externaldrive.fill", run: backup),
                Example(id: "copying", name: "Copying files", icon: "doc.on.doc", run: copying),
            ]),
            Group(name: "Urgent", note: "Glows from the notch's edge, stays until answered, and takes the strip under the notch from anything there.", examples: [
                Example(id: "battery", name: "Low battery", icon: "battery.25", run: battery),
                Example(id: "smoke", name: "Smoke alarm", icon: "smoke.fill", run: smoke),
                Example(id: "disk", name: "Disk almost full", icon: "internaldrive.fill", run: disk),
                Example(id: "signin", name: "New sign-in", icon: "lock.shield.fill", run: signIn),
            ]),
            Group(name: "Several at once", note: "Smart spreads them out and stacks the rest; nothing lands on top of anything else.", examples: [
                Example(id: "three", name: "Three at once", icon: "square.stack.3d.up.fill", run: threeAtOnce),
                Example(id: "twolong", name: "Two long ones", icon: "rectangle.stack.fill", run: twoLong),
                Example(id: "storm", name: "Storm of eight", icon: "cloud.bolt.rain.fill", run: storm),
                Example(id: "bump", name: "Urgent bumps one", icon: "exclamationmark.triangle.fill", run: urgentBumps),
                Example(id: "queue", name: "Five long in a row", icon: "list.number", run: fiveLong),
                Example(id: "earsfull", name: "Ears full", icon: "ear.fill", run: earsFull),
            ]),
            Group(name: "The list", note: "One with buttons that times out waits behind the bell in the open notch (left of the pin).", examples: [
                Example(id: "missed", name: "Missed call", icon: "phone.down.fill", run: missedCall),
                Example(id: "unanswered", name: "Three unanswered", icon: "tray.full.fill", run: threeUnanswered),
                Example(id: "meds", name: "Sticky reminder", icon: "pills.fill", run: meds),
                Example(id: "fill", name: "Fill the list", icon: "list.bullet.rectangle.fill", run: fillList),
            ]),
            Group(name: "Spots", note: "Forced to one spot, ignoring Smart (your per-app setting still wins).", examples: [
                Example(id: "left", name: "Left ear", icon: "rectangle.lefthalf.filled", run: { forced("left", "Left ear") }),
                Example(id: "right", name: "Right ear", icon: "rectangle.righthalf.filled", run: { forced("right", "Right ear") }),
                Example(id: "below", name: "Under the notch", icon: "rectangle.bottomhalf.filled", run: { forced("below", "Under the notch") }),
                Example(id: "floating", name: "Floating", icon: "capsule.fill", run: { forced("floating", "Floating pill") }),
                Example(id: "floatopen", name: "Floats when open", icon: "arrow.down.to.line", run: floatsWhenOpen),
                Example(id: "waitopen", name: "Waits when open", icon: "pause.circle.fill", run: waitsWhenOpen),
            ]),
            Group(name: "Pictures, motion, sound", note: "Images, app icons, every icon motion, and the system sounds.", examples: [
                Example(id: "nowplaying", name: "Now playing", icon: "music.note", run: nowPlaying),
                Example(id: "photo", name: "A picture", icon: "photo.fill", run: picture),
                Example(id: "apps", name: "App icons", icon: "app.badge.fill", run: appIcons),
                Example(id: "motions", name: "Every motion", icon: "wand.and.rays", run: motions),
                Example(id: "sounds", name: "Sounds", icon: "speaker.wave.3.fill", run: sounds),
                Example(id: "colors", name: "Colors", icon: "paintpalette.fill", run: colors),
            ]),
        ]
    }

    static var all: [Example] { groups.flatMap(\.examples) }
    static func random() { all.randomElement()?.run() }

    // MARK: helpers

    private static var client: BridgeClient { .shared }
    private static func rgba(_ r: Double, _ g: Double, _ b: Double) -> NoticePayload.RGBA { .init(r: r, g: g, b: b) }
    private static let orange = rgba(1, 0.58, 0.2), red = rgba(1, 0.27, 0.23), green = rgba(0.2, 0.84, 0.35)
    private static let blue = rgba(0.25, 0.55, 1), mint = rgba(0.3, 0.9, 0.75), cyan = rgba(0.3, 0.8, 1)
    private static let purple = rgba(0.7, 0.45, 1), yellow = rgba(1, 0.85, 0.2), pink = rgba(1, 0.4, 0.6)

    @discardableResult
    private static func post(_ p: NoticePayload, _ name: String) -> UUID { client.post(p, name: name) }
    /// Asks for an ear (Smart otherwise puts everything under the notch first).
    @discardableResult
    private static func ear(_ p: NoticePayload, _ name: String) -> UUID {
        var p = p
        p.placement = "beside"
        return client.post(p, name: name)
    }

    private static func action(_ id: String, _ title: String, _ role: String = "normal",
                               icon: String? = nil) -> NoticePayload.Action {
        .init(id: id, title: title, role: role, icon: icon)
    }

    /// Runs `steps` one after another, `every` apart, while `id` is still up.
    private static func live(_ id: UUID, every: Duration, _ steps: [() -> Void]) {
        Task { @MainActor in
            for step in steps {
                try? await Task.sleep(for: every)
                guard client.stillShowing(id) else { return }
                step()
            }
        }
    }

    /// Several posts, `gap` apart.
    private static func staggered(_ gap: Duration, _ posts: [() -> Void]) {
        Task { @MainActor in
            for (i, post) in posts.enumerated() {
                if i > 0 { try? await Task.sleep(for: gap) }
                post()
            }
        }
    }

    // MARK: floating island

    /// A payload with a change or two, for the new fields.
    private static func with(_ p: NoticePayload, _ change: (inout NoticePayload) -> Void) -> NoticePayload {
        var p = p
        change(&p)
        return p
    }

    /// Floating, whatever Smart would do (your style in Oxine still wins).
    private static func floating(_ p: NoticePayload) -> NoticePayload { with(p) { $0.placement = "floating" } }

    static func uploadRing() {
        var p = floating(NoticePayload(icon: "icloud.and.arrow.up.fill", tint: cyan, title: "Uploading 24 photos",
                                       subtitle: "iCloud", progress: 0, sticky: true, group: "playground.upload"))
        let id = post(p, "Upload ring")
        live(id, every: .milliseconds(150), (1...30).map { step in
            {
                p.progress = Double(step) / 30
                if step == 30 {
                    p.progress = nil; p.sticky = false; p.duration = 4
                    p.title = "24 photos uploaded"; p.icon = "checkmark.icloud.fill"; p.iconMotion = "bounce"
                }
                client.post(p, name: "Upload ring")
            }
        })
    }

    static func timerCircle() {
        var p = floating(with(NoticePayload(icon: "timer", tint: orange, title: "Pasta", sticky: true,
                                            group: "playground.timercircle")) {
            $0.look = "hero"; $0.hero = "0:12"; $0.shape = "circle"
        })
        let id = post(p, "Timer circle")
        live(id, every: .seconds(1), (0...11).reversed().map { left in
            {
                p.hero = String(format: "0:%02d", left)
                if left == 0 {
                    p.hero = "Done"; p.title = "Pasta's ready"; p.icon = "fork.knife"; p.iconMotion = "wiggle"
                    p.actions = [action("more", "+1 min", "primary", icon: "plus"), action("stop", "Stop", icon: "stop.fill")]
                    p.sticky = false; p.duration = 10; p.sound = "Glass"; p.haptic = true
                }
                client.post(p, name: "Timer circle")
            }
        })
    }

    static func recording() {
        var p = floating(with(NoticePayload(icon: "record.circle", tint: red, title: "Recording", subtitle: "Screen",
                                            iconMotion: "pulse", sticky: true, group: "playground.recording")) {
            $0.look = "hero"; $0.hero = "0:00"
        })
        let id = post(p, "Recording")
        live(id, every: .seconds(1), (1...15).map { second in
            {
                p.hero = String(format: "0:%02d", second)
                if second == 15 {
                    p.actions = [action("stop", "Stop", "destructive", icon: "stop.fill")]
                }
                client.post(p, name: "Recording")
            }
        })
    }

    static func streak() {
        post(floating(with(NoticePayload(icon: "flame.fill", tint: orange, title: "30 day streak", subtitle: "Duolingo",
                                         duration: 5, sound: "Hero")) {
            $0.emoji = "🔥"; $0.entrance = "celebrate"
        }), "Emoji circle")
    }

    static func calling() {
        post(floating(with(NoticePayload(icon: "phone.fill", tint: green, title: "Ece", subtitle: "FaceTime Audio",
                                         actions: [action("accept", "Accept", "primary", icon: "phone.fill"),
                                                   action("decline", "Decline", "destructive", icon: "phone.down.fill")],
                                         duration: 20, sound: "Purr")) {
            $0.personName = "Ece Yılmaz"; $0.personImagePNG = portraitPNG(hue: 0.92, hair: .brown)
            $0.shape = "circle"; $0.entrance = "ring"
        }), "Someone calling")
    }

    static func airpodsRing() {
        post(floating(NoticePayload(icon: "airpodspro", tint: .init(r: 1, g: 1, b: 1), title: "AirPods Pro",
                                    subtitle: "82%", progress: 0.82, duration: 4, group: "playground.airpods")),
             "AirPods ring")
    }

    static func pillAndCircle() {
        staggered(.milliseconds(500), [
            { post(floating(eceMessage), "Message, floating") },
            { timerCircle() },
        ])
    }

    static func pillAndTwoCircles() {
        staggered(.milliseconds(450), [
            { post(floating(eceMessage), "Message, floating") },
            { timerCircle() },
            { recording() },
        ])
    }

    static func fourCircles() {
        staggered(.milliseconds(350), [
            { uploadRing() },
            { timerCircle() },
            { airpodsRing() },
            { calling() },
        ])
    }

    static func twoPills() {
        staggered(.milliseconds(400), [
            {
                post(floating(with(NoticePayload(icon: "message.fill", tint: green, title: "Deniz",
                                                 detail: "On my way, 10 minutes", duration: 10)) {
                    $0.look = "message"; $0.personName = "Deniz Kaya"; $0.reactions = ["👍", "❤️", "🏃"]
                }), "Deniz")
            },
            {
                post(floating(NoticePayload(icon: "calendar", tint: red, title: "Standup in 5 min", subtitle: "Zoom",
                                            actions: [action("join", "Join", "primary")], duration: 10)), "Standup")
            },
        ])
    }

    // MARK: personal

    static func messageReply() { post(eceMessage, "Message, reply") }

    private static var eceMessage: NoticePayload {
        with(NoticePayload(icon: "message.fill", tint: .init(r: 1, g: 1, b: 1), title: "Ece",
                           subtitle: "Messages · now",
                           detail: "Are you coming tonight? We saved you a seat by the window.",
                           duration: 14, sound: "Pop")) {
            $0.look = "message"; $0.personName = "Ece Yılmaz"; $0.personImagePNG = portraitPNG(hue: 0.92, hair: .brown)
            $0.reactions = ["❤️", "👍", "😂", "🙏"]; $0.reply = "Reply to Ece"
        }
    }

    static func momMessage() {
        post((with(NoticePayload(icon: "message.fill", tint: pink, title: "Mom", subtitle: "Messages",
                                         detail: "Did you eat? Call me when you're free.", duration: 12, sound: "Pop")) {
            $0.look = "message"; $0.personName = "Mom"; $0.reactions = ["❤️", "😘", "👍"]; $0.reply = "Reply to Mom"
        }), "Mom")
    }

    static func groupChat() {
        post((with(NoticePayload(icon: "person.3.fill", tint: purple, title: "Deniz",
                                         subtitle: "Weekend plan · 3 new",
                                         detail: "Saturday works for everyone? I'll book the place.", duration: 12)) {
            $0.look = "message"; $0.personName = "Deniz Kaya"; $0.personImagePNG = portraitPNG(hue: 0.55, hair: .black)
            $0.reactions = ["👍", "🎉", "🤔"]; $0.reply = "Reply to Weekend plan"
        }), "Group chat")
    }

    static func birthday() {
        post((with(NoticePayload(icon: "birthday.cake.fill", tint: pink, title: "Deniz turns 27 today",
                                         subtitle: "Birthdays", duration: 12, sound: "Hero")) {
            $0.emoji = "🎂"; $0.entrance = "celebrate"; $0.reply = "Write something nice"
            $0.reactions = ["🎉", "🥳", "❤️"]
        }), "Birthday")
    }

    static func incomingCall() {
        post((with(NoticePayload(icon: "phone.fill", tint: green, title: "Mom", subtitle: "Mobile",
                                         actions: [action("accept", "Accept", "primary"), action("decline", "Decline", "destructive")],
                                         duration: 20, sound: "Purr")) {
            $0.personName = "Mom"; $0.entrance = "ring"; $0.look = "message"
        }), "Incoming call")
    }

    // MARK: big values

    static func steps() {
        var p = (with(NoticePayload(icon: "figure.walk", tint: green, title: "Steps", sticky: true,
                                            group: "playground.steps")) {
            $0.look = "hero"; $0.hero = "9,940"
        })
        let id = post(p, "Steps")
        live(id, every: .seconds(1), [
            { p.hero = "9,970"; client.post(p, name: "Steps") },
            { p.hero = "9,990"; client.post(p, name: "Steps") },
            {
                // Done: a new notice in the same group, so it arrives (with confetti).
                client.dismiss(p.id)
                post((with(NoticePayload(icon: "figure.walk", tint: green, title: "Goal reached",
                                                 subtitle: "Steps", duration: 6, group: "playground.steps", sound: "Hero")) {
                    $0.look = "hero"; $0.hero = "10,000"; $0.entrance = "celebrate"
                }), "Steps goal")
            },
        ])
    }

    static func oven() {
        post((with(NoticePayload(icon: "flame", tint: orange, title: "Oven is ready", subtitle: "Home",
                                         actions: [action("timer", "Start 25 min", "primary")], duration: 10,
                                         sound: "Glass")) {
            $0.look = "hero"; $0.hero = "200°"; $0.entrance = "bounce"
        }), "Oven")
    }

    // MARK: how they arrive

    static func knockKnock() {
        post(floating(with(NoticePayload(icon: "hand.raised.fill", tint: yellow, title: "Someone's knocking",
                                         subtitle: "Ears On", actions: [action("resume", "Resume music", "primary")],
                                         duration: 8, group: "playground.knock", haptic: true)) {
            $0.entrance = "knock"; $0.emoji = "✊"
        }), "Knock knock")
    }

    static func doorbellRing() {
        post(floating(with(NoticePayload(icon: "bell.fill", tint: orange, title: "Doorbell", subtitle: "Front door",
                                         actions: [action("resume", "Resume music", "primary")],
                                         duration: 8, group: "playground.doorbell", sound: "Glass")) {
            $0.entrance = "ring"; $0.emoji = "🔔"
        }), "Doorbell")
    }

    static func done() {
        post(floating(with(NoticePayload(icon: "checkmark.seal.fill", tint: green, title: "Export finished",
                                         subtitle: "Trip.mov · 1.2 GB",
                                         actions: [action("open", "Open", "primary"), action("show", "Show")],
                                         duration: 8, sound: "Glass")) {
            $0.entrance = "celebrate"
        }), "Done")
    }

    static func packageBounce() {
        post(floating(with(NoticePayload(icon: "shippingbox.fill", tint: rgba(0.85, 0.65, 0.4), title: "Package delivered",
                                         subtitle: "Front door", detail: "Left with the doorman at 14:32.",
                                         actions: [action("track", "See photo", "primary")], duration: 8)) {
            $0.entrance = "bounce"; $0.emoji = "📦"; $0.look = "media"
        }), "Package")
    }

    static func emptyTrash() {
        post(floating(with(NoticePayload(icon: "trash.fill", tint: red, title: "Empty the Trash?",
                                         subtitle: "312 items · 4.2 GB", detail: "This can't be undone.",
                                         actions: [.init(id: "empty", title: "Hold to empty", role: "destructive", hold: true),
                                                   action("cancel", "Cancel")],
                                         duration: 15)) {
            $0.entrance = "pop"
        }), "Hold to empty")
    }

    /// A made-up person's picture: a face on a color, nobody in particular.
    private static func portraitPNG(hue: CGFloat, hair: NSColor) -> Data? {
        let image = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(starting: NSColor(hue: hue, saturation: 0.4, brightness: 0.98, alpha: 1),
                       ending: NSColor(hue: hue, saturation: 0.7, brightness: 0.7, alpha: 1))?.draw(in: rect, angle: -90)
            NSColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.45, brightness: 0.55, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: -34, width: 68, height: 62)).fill()
            NSColor(red: 0.96, green: 0.8, blue: 0.66, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 31, y: 30, width: 34, height: 40)).fill()
            hair.setFill()
            NSBezierPath(ovalIn: NSRect(x: 27, y: 54, width: 42, height: 26)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: in an ear

    static func copied() {
        ear(NoticePayload(icon: "doc.on.doc.fill", tint: cyan, title: "Copied", duration: 2,
                           group: "playground.copied"), "Copied")
    }

    static func airpods() {
        ear(NoticePayload(icon: "airpodspro", title: "AirPods Pro", subtitle: "82%",
                           duration: 4, group: "playground.airpods", haptic: true), "AirPods")
    }

    static func wifi() {
        ear(NoticePayload(icon: "wifi", tint: blue, title: "Joined Home 5G", iconMotion: "waves",
                           duration: 3, group: "playground.wifi"), "Wi-Fi")
    }

    static func doorbell() {
        ear(NoticePayload(icon: "bell.fill", tint: orange, title: "Doorbell", iconMotion: "bounce",
                           actions: [action("resume", "Resume music", "primary")],
                           duration: 8, group: "playground.doorbell"), "Doorbell")
    }

    static func knock() {
        ear(NoticePayload(icon: "hand.raised.fill", tint: yellow, title: "Someone's knocking", iconMotion: "wiggle",
                           actions: [action("resume", "Resume music", "primary")],
                           duration: 8, group: "playground.knock"), "Knocking")
    }

    static func airdrop() {
        ear(NoticePayload(icon: "airplayaudio", tint: blue, title: "AirDrop from Ece",
                           actions: [action("accept", "Accept", "primary"), action("decline", "Decline")],
                           duration: 10, haptic: true), "AirDrop")
    }

    static func allowMic() {
        ear(NoticePayload(icon: "mic.fill", tint: orange, title: "Zoom wants the mic",
                           actions: [action("allow", "Allow", "primary"), action("deny", "Deny", "destructive")],
                           duration: 10), "Allow mic")
    }

    static func screenshot() {
        ear(NoticePayload(icon: "camera.viewfinder", tint: rgba(0.85, 0.85, 0.9), title: "Screenshot saved",
                           actions: [action("show", "Show")], duration: 5, sound: "Tink"), "Screenshot")
    }

    static func focus() {
        ear(NoticePayload(icon: "moon.fill", tint: purple, title: "Focus on", subtitle: "Work",
                           iconMotion: "breathe", duration: 3, group: "playground.focus"), "Focus")
    }

    static func muted() {
        ear(NoticePayload(icon: "speaker.slash.fill", title: "Muted", duration: 2, group: "playground.volume"), "Muted")
    }

    static func mouse() {
        ear(NoticePayload(icon: "magicmouse.fill", tint: orange, title: "Magic Mouse", subtitle: "12%",
                           duration: 4), "Mouse battery")
    }

    static func link() {
        ear(NoticePayload(icon: "link", tint: cyan, title: "Link copied", subtitle: "github.com",
                           duration: 3, group: "playground.copied"), "Link copied")
    }

    static func charging() {
        ear(NoticePayload(icon: "bolt.fill", tint: green, title: "Charging", subtitle: "80%", progress: 0.8,
                           duration: 4, group: "playground.power"), "Charging")
    }

    static func teaReady() {
        ear(NoticePayload(icon: "cup.and.saucer.fill", tint: mint, title: "Tea's ready", iconMotion: "wiggle",
                           actions: [action("more", "+2 min", "primary"), action("stop", "Stop")],
                           duration: 8, group: "playground.countdown", sound: "Tink", haptic: true), "Timer done")
    }

    // MARK: under the notch

    static func message() {
        post(with(NoticePayload(icon: "message.fill", tint: green, title: "Mom", subtitle: "Messages",
                                detail: "Did you eat? Call me when you're free.",
                                actions: [action("read", "Mark as read")], duration: 8, sound: "Pop")) {
            $0.look = "message"; $0.personName = "Mom"; $0.reactions = ["❤️", "👍"]
        }, "Message")
    }

    static func agent() {
        post(NoticePayload(icon: "terminal.fill", tint: rgba(1, 0.45, 0.2), title: "Claude Code needs you",
                           subtitle: "oxine", detail: "Allow Bash: swift build 2>&1 | tail -20", iconMotion: "pulse",
                           actions: [action("allow", "Allow", "primary"), action("deny", "Deny", "destructive")],
                           sticky: true, haptic: true), "Agent")
    }

    static func meeting() {
        post(NoticePayload(icon: "calendar", tint: red, title: "Design review in 5 min", subtitle: "Zoom",
                           detail: "With Deniz, Ece and 3 others.",
                           actions: [action("join", "Join", "primary"), action("snooze", "In 5 min")],
                           duration: 12, group: "playground.meeting", haptic: true), "Meeting")
    }

    static func build() { post(buildFailed, "Build") }

    private static var buildFailed: NoticePayload {
        NoticePayload(icon: "hammer.fill", tint: red, title: "Build failed", subtitle: "3 errors",
                      detail: "NotchNotices.swift:212: cannot find 'metrics' in scope, and 2 more.",
                      actions: [action("log", "Open log", "primary"),
                                .init(id: "revert", title: "Revert", role: "destructive", hold: true)],
                      duration: 10).withEntrance("shake")
    }

    static func mail() {
        post(NoticePayload(icon: "envelope.fill", tint: blue, title: "Invoice from Studio", subtitle: "Mail",
                           detail: "Hi! Attached is the invoice for September. Let me know if anything looks off.",
                           appIcon: "com.apple.mail",
                           actions: [action("reply", "Reply", "primary"), action("archive", "Archive")],
                           duration: 10, sound: "Pop"), "Email")
    }

    static func invite() {
        post(NoticePayload(icon: "calendar.badge.plus", tint: red, title: "Lunch on Friday?",
                           detail: "Deniz invited you: Friday 12:30 at Karaköy Lokantası.",
                           actions: [action("yes", "Accept", "primary"), action("maybe", "Maybe"),
                                     action("no", "Decline", "destructive")],
                           duration: 12), "Invite")
    }

    static func package() {
        post(NoticePayload(icon: "shippingbox.fill", tint: rgba(0.8, 0.6, 0.4), title: "Your package arrived",
                           detail: "Left at the front door at 14:02. Photo attached in the app.",
                           duration: 8), "Package")
    }

    static func update() {
        post(NoticePayload(icon: "arrow.triangle.2.circlepath", tint: blue, title: "macOS 26.1 is ready",
                           detail: "Restart to finish installing. It takes about 20 minutes.",
                           actions: [action("tonight", "Tonight", "primary"), action("details", "Details")],
                           duration: 10), "Update")
    }

    static func review() {
        post(NoticePayload(icon: "arrow.triangle.pull", tint: purple, title: "Review requested", subtitle: "oxine#214",
                           detail: "Compact ear notices, the list behind the bell, and the floating pill that glides.",
                           actions: [action("open", "Open", "primary"), action("later", "Later")],
                           duration: 10), "Review")
    }

    static func longText() {
        post(NoticePayload(icon: "text.alignleft", tint: yellow,
                           title: "A title that's far too long for an ear",
                           detail: "Long notices go under the notch in Smart, and the full version wraps as many lines as it needs. This one keeps going so you can see the full version grow downward, keeping the notch's width.",
                           duration: 10), "Long text")
    }

    // MARK: live

    /// Fills over eight seconds, then turns into "Downloaded" with buttons.
    static func download() {
        var p = NoticePayload(icon: "arrow.down.circle.fill", tint: blue, title: "Xcode.xip", subtitle: "2.1 GB",
                              progress: 0, sticky: true, group: "playground.download")
        let id = post(p, "Download")
        live(id, every: .milliseconds(200), (1...40).map { step in
            {
                p.progress = Double(step) / 40
                if step == 40 {
                    // Done: a new notice in the same group, so it arrives, with confetti.
                    post(NoticePayload(icon: "checkmark.circle.fill", tint: green, title: "Downloaded",
                                       subtitle: "Xcode.xip", actions: [action("open", "Open", "primary"), action("reveal", "Show")],
                                       duration: 6, group: "playground.download", sound: "Glass").withEntrance("celebrate"),
                         "Downloaded")
                    return
                }
                client.post(p, name: "Download")
            }
        })
    }

    /// Counts down in its own title, then rings with buttons.
    static func countdown() {
        var p = NoticePayload(icon: "timer", tint: mint, title: "Tea", iconMotion: "rotate", sticky: true,
                              group: "playground.countdown")
        p.look = "hero"; p.hero = "0:10"
        let id = post(p, "Countdown")
        live(id, every: .seconds(1), (0...9).reversed().map { left in
            {
                if left > 0 {
                    p.hero = String(format: "0:%02d", left)
                } else {
                    p.hero = "Ready"
                    p.icon = "cup.and.saucer.fill"; p.title = "Tea"; p.iconMotion = "wiggle"
                    p.actions = [action("more", "+2 min", "primary"), action("stop", "Stop")]
                    p.sticky = false; p.duration = 8; p.haptic = true; p.sound = "Tink"
                }
                client.post(p, name: "Countdown")
            }
        })
    }

    /// Under the notch: point at it to watch the percentage.
    static func export() {
        var p = NoticePayload(icon: "film.fill", tint: pink, title: "Exporting Holiday.mov",
                              detail: "1080p, about 30 seconds left.", progress: 0, sticky: true,
                              group: "playground.export")
        let id = post(p, "Export")
        live(id, every: .milliseconds(250), (1...24).map { step in
            {
                p.progress = Double(step) / 24
                p.detail = step < 24 ? "1080p, about \(max(1, (24 - step) * 30 / 24)) seconds left." : "Saved to Movies."
                if step == 24 {
                    p.title = "Exported Holiday.mov"; p.progress = nil; p.sticky = false; p.duration = 6
                    p.actions = [action("play", "Play", "primary"), action("share", "Share")]
                }
                client.post(p, name: "Export")
            }
        })
    }

    static func ride() {
        var p = NoticePayload(icon: "car.fill", tint: rgba(0.9, 0.9, 0.9), title: "Your driver",
                              subtitle: "34 ABC 12", sticky: true, group: "playground.ride")
        p.look = "hero"; p.hero = "3 min"
        let id = post(p, "Ride")
        live(id, every: .seconds(2), [
            { p.hero = "2 min"; client.post(p, name: "Ride") },
            { p.hero = "1 min"; client.post(p, name: "Ride") },
            {
                p.hero = "Here"; p.iconMotion = "bounce"; p.haptic = true
                p.actions = [action("coming", "Coming", "primary")]; p.sticky = false; p.duration = 10
                client.post(p, name: "Ride")
            },
        ])
    }

    static func score() {
        var p = NoticePayload(icon: "soccerball", tint: yellow, title: "GS – FB", subtitle: "12'", sticky: true,
                              group: "playground.score")
        p.look = "hero"; p.hero = "0 – 0"
        let id = post(p, "Score")
        live(id, every: .seconds(2), [
            { p.subtitle = "38'"; client.post(p, name: "Score") },
            { p.hero = "1 – 0"; p.subtitle = "41'"; p.iconMotion = "bounce"; p.haptic = true; client.post(p, name: "Score") },
            { p.subtitle = "HT"; p.iconMotion = "none"; p.haptic = false; client.post(p, name: "Score") },
            { p.hero = "1 – 1"; p.subtitle = "67'"; p.iconMotion = "bounce"; client.post(p, name: "Score") },
            {
                p.hero = "2 – 1"; p.subtitle = "Full time"; p.iconMotion = "none"
                p.sticky = false; p.duration = 6; p.sound = "Hero"; client.post(p, name: "Score")
            },
        ])
    }

    static func stopwatch() {
        var p = NoticePayload(icon: "stopwatch.fill", tint: orange, title: "0:00",
                              actions: [action("stop", "Stop", "destructive")], sticky: true,
                              group: "playground.stopwatch")
        let id = post(p, "Stopwatch")
        live(id, every: .seconds(1), (1...30).map { s in
            { p.title = String(format: "%d:%02d", s / 60, s % 60); client.post(p, name: "Stopwatch") }
        })
    }

    static func chargeToFull() {
        var p = NoticePayload(icon: "battery.100.bolt", tint: green, title: "Charging", progress: 0.9, sticky: true,
                              group: "playground.power")
        let id = post(p, "Charging")
        live(id, every: .milliseconds(400), (91...100).map { level in
            {
                p.progress = Double(level) / 100
                if level == 100 {
                    p.title = "Fully charged"; p.progress = nil; p.iconMotion = "bounce"
                    p.sticky = false; p.duration = 4; p.sound = "Glass"
                }
                client.post(p, name: "Charging")
            }
        })
    }

    /// Quiet progress: open the notch while it runs and it steps aside.
    static func backup() {
        var p = NoticePayload(icon: "externaldrive.fill", tint: cyan, title: "Backing up", progress: 0, sticky: true,
                              group: "playground.backup")
        let id = post(p, "Backup")
        live(id, every: .milliseconds(500), (1...30).map { step in
            {
                p.progress = Double(step) / 30
                if step == 30 { p.title = "Backed up"; p.progress = nil; p.sticky = false; p.duration = 4 }
                client.post(p, name: "Backup")
            }
        })
    }

    /// The same group, replaced: one notice that changes its mind.
    static func copying() {
        staggered(.milliseconds(900), [
            { post(NoticePayload(icon: "doc.on.doc", tint: cyan, title: "Copying 1 file", duration: 6, group: "playground.copying"), "Copying") },
            { post(NoticePayload(icon: "doc.on.doc", tint: cyan, title: "Copying 2 files", duration: 6, group: "playground.copying"), "Copying") },
            { post(NoticePayload(icon: "checkmark.circle.fill", tint: green, title: "Copied 3 files", iconMotion: "bounce", duration: 3, group: "playground.copying"), "Copied") },
        ])
    }

    // MARK: urgent

    static func battery() {
        post(with(NoticePayload(icon: "battery.25", tint: red, title: "Battery low",
                                detail: "About 25 minutes left at this rate. Plug in soon, or save some power.",
                                iconMotion: "wiggle",
                                actions: [action("lowpower", "Low Power Mode", "primary"), action("later", "Later")],
                                emphasis: "urgent", group: "playground.battery", sound: "Basso")) {
            $0.look = "hero"; $0.hero = "10%"
        }, "Battery")
    }

    static func smoke() {
        post(NoticePayload(icon: "smoke.fill", tint: red, title: "Smoke alarm",
                           detail: "Heard through your Mac's microphone. Your music is paused.",
                           iconMotion: "wiggle", actions: [action("ok", "I'm OK", "primary")],
                           emphasis: "urgent", group: "playground.smoke", sound: "Sosumi"), "Smoke alarm")
    }

    static func disk() {
        post(NoticePayload(icon: "internaldrive.fill", tint: orange, title: "Disk almost full",
                           detail: "2.1 GB left. Downloads and caches are the biggest.",
                           actions: [action("manage", "Manage", "primary"), action("later", "Later")],
                           emphasis: "urgent", group: "playground.disk"), "Disk")
    }

    static func signIn() {
        post(NoticePayload(icon: "lock.shield.fill", tint: red, title: "New sign-in", subtitle: "Istanbul",
                           detail: "Your account was used on a new Mac just now.", iconMotion: "pulse",
                           actions: [action("me", "It was me", "primary"), action("notme", "Not me", "destructive")],
                           emphasis: "urgent", haptic: true), "Sign-in")
    }

    // MARK: several at once

    /// Smart spreads them across the right, left and below.
    static func threeAtOnce() {
        copied()
        airpods()
        message()
    }

    /// The first goes under the notch; the second floats under it, never on top.
    static func twoLong() {
        post(NoticePayload(icon: "flame.fill", tint: orange, title: "You're on fire!",
                           subtitle: "You have reached a streak of 30 days", duration: 8), "Streak")
        post(NoticePayload(icon: "trophy.fill", tint: yellow, title: "New personal best",
                           subtitle: "5 km in 24:10, a minute faster", duration: 8), "Personal best")
    }

    /// Eight at once: the spots fill, the rest wait their turn.
    static func storm() {
        for i in 0..<8 {
            let c = NSColor(hue: CGFloat(i) / 8, saturation: 0.7, brightness: 1, alpha: 1)
            post(NoticePayload(icon: "\(i + 1).circle.fill",
                               tint: rgba(c.redComponent, c.greenComponent, c.blueComponent),
                               title: "Notice \(i + 1)", duration: 3), "Storm \(i + 1)")
        }
    }

    static func urgentBumps() {
        staggered(.seconds(1.5), [
            { package() },
            { battery() },
        ])
    }

    static func fiveLong() {
        for i in 1...5 {
            post(NoticePayload(icon: "\(i).square.fill", tint: purple, title: "Long notice number \(i) of five",
                               detail: "Under the notch, then floating, then the ears, then a queue.",
                               duration: 4), "Long \(i)")
        }
    }

    static func earsFull() {
        staggered(.milliseconds(300), [
            { copied() }, { focus() }, { wifi() },
        ])
    }

    // MARK: the list

    static func missedCall() {
        post(with(NoticePayload(icon: "phone.down.fill", tint: red, title: "Missed call", subtitle: "Deniz",
                                actions: [action("call", "Call back", "primary")], duration: 3)) {
            $0.personName = "Deniz Kaya"; $0.personImagePNG = portraitPNG(hue: 0.55, hair: .black)
        }, "Missed call")
    }

    static func threeUnanswered() {
        staggered(.milliseconds(400), [
            { post(NoticePayload(icon: "phone.down.fill", tint: red, title: "Missed call", subtitle: "Ece",
                                 actions: [action("call", "Call back", "primary")], duration: 2), "Missed call") },
            { post(NoticePayload(icon: "message.fill", tint: green, title: "Deniz", subtitle: "Messages",
                                 detail: "Are we still on for tonight?", appIcon: "com.apple.MobileSMS",
                                 actions: [action("reply", "Reply", "primary")], duration: 2), "Message") },
            { post(NoticePayload(icon: "calendar", tint: red, title: "Standup now",
                                 actions: [action("join", "Join", "primary")], duration: 2), "Standup") },
        ])
    }

    static func meds() {
        post(NoticePayload(icon: "pills.fill", tint: pink, title: "Take your vitamins",
                           actions: [action("done", "Done", "primary")], sticky: true,
                           group: "playground.meds"), "Reminder")
    }

    static func fillList() {
        let items: [(String, String, NoticePayload.RGBA, String)] = [
            ("envelope.fill", "3 new emails", blue, "Read"), ("cart.fill", "Order shipped", orange, "Track"),
            ("person.crop.circle.badge.plus", "Ece followed you", purple, "View"),
            ("dollarsign.circle.fill", "Payment received", green, "Open"),
            ("exclamationmark.bubble.fill", "Comment on your post", yellow, "Reply"),
            ("star.fill", "Rate your ride", yellow, "Rate"),
        ]
        staggered(.milliseconds(700), items.map { icon, title, tint, button in
            { post(NoticePayload(icon: icon, tint: tint, title: title,
                                 actions: [action(button.lowercased(), button, "primary")], duration: 1.5), title) }
        })
    }

    // MARK: spots

    static func forced(_ spot: String, _ title: String) {
        post(NoticePayload(icon: "scope", tint: purple, title: title,
                           actions: [action("ok", "OK", "primary")], placement: spot, duration: 6), title)
    }

    /// Open the notch after sending: it floats under the open notch, then goes
    /// back onto the notch when it closes.
    static func floatsWhenOpen() {
        post(NoticePayload(icon: "arrow.down.to.line", tint: cyan, title: "Open the notch now",
                           actions: [action("ok", "OK", "primary")], whenOpen: "float", duration: 12), "Floats when open")
    }

    /// Open the notch after sending: it hides, its time paused, until it closes.
    static func waitsWhenOpen() {
        post(NoticePayload(icon: "pause.circle.fill", tint: yellow, title: "Open the notch now",
                           whenOpen: "wait", duration: 8), "Waits when open")
    }

    // MARK: pictures, motion, sound

    /// Oxine fills in the cover, title and artist of what the notch is playing.
    static func nowPlaying() {
        post(with(NoticePayload(icon: "music.note", title: "", useNowPlayingArt: true,
                                duration: 4, group: "playground.nowplaying")) { $0.look = "media" }, "Now playing")
    }

    static func picture() {
        post(with(NoticePayload(icon: "photo.fill", title: "Ece shared a photo", subtitle: "Photos",
                                detail: "Sunset from the ferry.", imagePNG: sunsetPNG(),
                                actions: [action("view", "View", "primary")], duration: 8)) {
            $0.look = "media"; $0.reactions = ["😍", "🔥", "👏"]
        }, "Picture")
    }

    static func appIcons() {
        let apps = [("com.apple.Safari", "Safari"), ("com.apple.finder", "Finder"), ("com.apple.Music", "Music"),
                    ("com.apple.Notes", "Notes"), ("com.apple.dt.Xcode", "Xcode")]
        staggered(.milliseconds(900), apps.map { id, name in
            { post(NoticePayload(icon: "app", title: name, appIcon: id, duration: 2.5, group: "playground.apps"), name) }
        })
    }

    static func motions() {
        let all = [("bounce", "arrow.up.circle.fill"), ("pulse", "heart.fill"), ("wiggle", "bell.fill"),
                   ("breathe", "leaf.fill"), ("rotate", "gearshape.fill"), ("waves", "wifi")]
        staggered(.milliseconds(1400), all.map { motion, icon in
            { post(NoticePayload(icon: icon, tint: mint, title: motion.capitalized, iconMotion: motion,
                                 duration: 2, group: "playground.motion"), motion) }
        })
    }

    static func sounds() {
        let names = ["Glass", "Ping", "Pop", "Purr", "Tink", "Hero", "Funk", "Submarine"]
        staggered(.milliseconds(1100), names.map { name in
            { post(NoticePayload(icon: "speaker.wave.2.fill", tint: blue, title: name, duration: 1.5,
                                 group: "playground.sound", sound: name), name) }
        })
    }

    static func colors() {
        let tints: [(String, NoticePayload.RGBA)] = [("Red", red), ("Orange", orange), ("Yellow", yellow),
                                                     ("Green", green), ("Blue", blue), ("Purple", purple)]
        staggered(.milliseconds(700), tints.map { name, tint in
            { post(NoticePayload(icon: "circle.fill", tint: tint, title: name, duration: 2,
                                 group: "playground.color"), name) }
        })
    }

    /// A small made-up photo: a sunset gradient with a sun.
    private static func sunsetPNG() -> Data? {
        let size = NSSize(width: 96, height: 96)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.25, green: 0.2, blue: 0.5, alpha: 1),
                                NSColor(red: 1, green: 0.45, blue: 0.35, alpha: 1),
                                NSColor(red: 1, green: 0.8, blue: 0.4, alpha: 1)])?.draw(in: rect, angle: -90)
            NSColor(red: 1, green: 0.95, blue: 0.7, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 34, y: 22, width: 28, height: 28)).fill()
            NSColor(red: 0.15, green: 0.15, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 96, height: 26)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension NoticePayload {
    /// The same notice arriving another way.
    func withEntrance(_ entrance: String) -> NoticePayload {
        var p = self
        p.entrance = entrance
        return p
    }
}
