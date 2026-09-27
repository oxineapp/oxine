import Foundation
import OxineAppSDK

// Chat Demo: a pretend chat app that runs inside Oxine the way a store app
// does, speaking the app protocol (NDJSON over stdin/stdout). It uses the
// same vocabulary a real messenger companion would: a list of chats, a chat
// with grouped bubbles, reactions, replies and a composer in a tall notch tab
// on the right; message notices you can answer from the notch; and the
// notch's glow in the color of whoever's unread. Nothing leaves the Mac.
// `chatdemo.sh` builds it and installs it into Oxine's apps folder.

// MARK: - Chats

struct Message {
    let id: Int
    /// nil: me.
    let from: String?
    var text: String
    var time: String
    var reactions: [String] = []
    var pending = false
}

struct Chat {
    let id: String
    let name: String
    let color: String
    var members: [String] = []
    var pinned = false
    var messages: [Message]
    var unread = 0
    var typing: String?
    var draft = ""
    var replyingTo: Int?
    /// What they say back, in turn.
    var replies: [String]

    var isGroup: Bool { !members.isEmpty }
    var firstName: String { String(name.split(separator: " ").first ?? Substring(name)) }
}

var messageID = 100
@MainActor func newID() -> Int { messageID += 1; return messageID }

func clock(minutesAgo: Int = 0) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f.string(from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
}

var chats: [Chat] = [
    Chat(id: "ece", name: "Ece Yılmaz", color: "#FF6B8B", pinned: true, messages: [
        Message(id: 1, from: "Ece Yılmaz", text: "did you see the new place on Moda?", time: clock(minutesAgo: 52)),
        Message(id: 2, from: nil, text: "the one with the blue door?", time: clock(minutesAgo: 50)),
        Message(id: 3, from: "Ece Yılmaz", text: "yes!! they do breakfast all day", time: clock(minutesAgo: 49), reactions: ["😍"]),
        Message(id: 4, from: "Ece Yılmaz", text: "saturday?", time: clock(minutesAgo: 49)),
        Message(id: 5, from: nil, text: "saturday works", time: clock(minutesAgo: 41)),
    ], replies: ["perfect, 11?", "I'll book a table", "bring the camera 📷", "ok see you there"]),
    Chat(id: "deniz", name: "Deniz Kaya", color: "#4FC3F7", messages: [
        Message(id: 6, from: nil, text: "sending you the slides now", time: clock(minutesAgo: 180)),
        Message(id: 7, from: "Deniz Kaya", text: "got them, thanks", time: clock(minutesAgo: 175)),
        Message(id: 8, from: "Deniz Kaya", text: "slide 12 has a typo btw", time: clock(minutesAgo: 174)),
    ], replies: ["no worries", "looks good now", "see you at standup", "👍"]),
    Chat(id: "mom", name: "Mom", color: "#FFB74D", messages: [
        Message(id: 9, from: "Mom", text: "Did you eat?", time: clock(minutesAgo: 300)),
        Message(id: 10, from: nil, text: "yes mom", time: clock(minutesAgo: 290), reactions: ["❤️"]),
    ], replies: ["good. call me tonight", "❤️", "your aunt says hi", "don't stay up late"]),
    Chat(id: "climb", name: "Bouldering Thursday", color: "#81C784", members: ["Mert", "Selin", "Can"], messages: [
        Message(id: 11, from: "Mert", text: "who's in this week?", time: clock(minutesAgo: 90)),
        Message(id: 12, from: "Selin", text: "me", time: clock(minutesAgo: 88)),
        Message(id: 13, from: "Can", text: "me too, 7pm?", time: clock(minutesAgo: 87)),
        Message(id: 14, from: "Mert", text: "7 it is", time: clock(minutesAgo: 86), reactions: ["💪"]),
    ], replies: ["see you there", "I'll bring chalk", "the new blue route is up", "running 10 min late"]),
]

/// Surfaces on screen right now (the notch tab, the panel tab).
var visible: Set<String> = []
var openChat: String?

@MainActor func index(of id: String) -> Int? { chats.firstIndex { $0.id == id } }
@MainActor func isReading(_ id: String) -> Bool { openChat == id && !visible.isEmpty }

// MARK: - Views

@MainActor func render() {
    let body = openChat.flatMap(index(of:)).map { chatView(chats[$0]) } ?? listView()
    for surface in ["notchTab", "panelTab"] { OxineApp.send(["t": "view", "surface": surface, "body": body]) }
    OxineApp.send(["t": "attention", "colors": chats.filter { $0.unread > 0 }.map(\.color)])
}

@MainActor func listView() -> [[String: Any]] {
    let sorted = chats.sorted { a, b in
        if a.pinned != b.pinned { return a.pinned }
        return (a.messages.last?.id ?? 0) > (b.messages.last?.id ?? 0)
    }
    return [
        node("toolbar", nil, ["flat": true], [
            node("text", nil, ["text": "Chats", "style": "title"]),
            node("spacer"),
            node("plainIconButton", "arrive", ["symbol": "envelope.badge", "label": "Get a message"]),
        ]),
        node("vstack", nil, ["spacing": 0], sorted.map(chatRow)),
    ]
}

@MainActor func chatRow(_ chat: Chat) -> [String: Any] {
    let last = chat.messages.last
    var preview = last?.text ?? ""
    if let typing = chat.typing {
        preview = chat.isGroup ? "\(typing) is typing…" : "typing…"
    } else if let last {
        if last.from == nil { preview = "You: " + preview } else if chat.isGroup, let from = last.from { preview = "\(from): " + preview }
    }
    return node("chatRow", "open:\(chat.id)", [
        "title": chat.name, "subtitle": preview, "timestamp": last?.time ?? "",
        "unread": chat.unread, "indicatorColor": chat.color, "pinned": chat.pinned,
    ])
}

@MainActor func chatView(_ chat: Chat) -> [[String: Any]] {
    let status = chat.typing.map { chat.isGroup ? "\($0) is typing…" : "typing…" }
        ?? (chat.isGroup ? chat.members.joined(separator: ", ") : "online")
    let header = node("toolbar", nil, ["flat": true, "spacing": 8], [
        node("plainIconButton", "back", ["symbol": "chevron.left", "label": "Chats"]),
        node("vstack", nil, ["spacing": 0], [
            node("text", nil, ["text": chat.name, "style": "chatTitle", "maxLines": 1]),
            node("text", nil, ["text": status, "style": "caption", "maxLines": 1]),
        ]),
        node("spacer"),
        node("plainIconButton", "arrive", ["symbol": "envelope.badge", "label": "Get a message"]),
    ])

    var bubbles: [[String: Any]] = [node("dateSeparator", nil, ["text": "Today"])]
    let messages = chat.messages
    for (i, m) in messages.enumerated() {
        let above = i > 0 && messages[i - 1].from == m.from
        let below = i < messages.count - 1 && messages[i + 1].from == m.from
        let group = above && below ? "middle" : above ? "last" : below ? "first" : "single"
        var props: [String: Any] = [
            "text": m.text, "time": m.time, "outgoing": m.from == nil, "reactions": m.reactions,
            "groupPosition": group, "pending": m.pending, "reactionEnabled": true, "tint": chat.color,
        ]
        if chat.isGroup, let from = m.from { props["sender"] = from }
        bubbles.append(node("messageBubble", "msg:\(m.id)", props))
    }
    if chat.typing != nil {
        bubbles.append(node("messageBubble", nil, ["text": "•••", "dimmed": true, "tint": chat.color]))
    }

    var bottom: [[String: Any]] = []
    if let replying = chat.replyingTo, let m = messages.first(where: { $0.id == replying }) {
        bottom.append(node("replyPreview", "cancelReply", [
            "sender": m.from ?? "yourself", "text": m.text, "tint": chat.color,
        ]))
    }
    bottom.append(node("composer", nil, [:], [
        node("textField", "draft", ["placeholder": "Message \(chat.firstName)", "kind": "composer", "value": chat.draft]),
        node("iconButton", "send", ["symbol": "arrow.up", "label": "Send", "tint": chat.color,
                                    "disabled": chat.draft.trimmingCharacters(in: .whitespaces).isEmpty]),
    ]))

    return [node("chatLayout", nil, [
        "scrollContext": chat.id, "spacing": 6,
        "scrollKey": "\(messages.last?.id ?? 0)-\(chat.typing ?? "")",
    ], [
        header,
        node("vstack", nil, ["spacing": 2], bubbles),
        node("vstack", nil, ["spacing": 6], bottom),
    ])]
}

// MARK: - What happens

/// Someone writes. Read straight away if their chat is open on screen;
/// otherwise it's unread, the notch glows in their color, and a notice
/// comes down that can be answered where it is.
@MainActor func arrive(in id: String) {
    guard let i = index(of: id), !chats[i].replies.isEmpty else { return }
    let text = chats[i].replies.removeFirst()
    chats[i].replies.append(text)
    let from = chats[i].isGroup ? chats[i].members.randomElement()! : chats[i].name
    chats[i].typing = nil
    chats[i].messages.append(Message(id: newID(), from: from, text: text, time: clock()))
    if isReading(id) {
        render()
        return
    }
    chats[i].unread += 1
    render()
    let chat = chats[i]
    var args: [String: Any] = [
        "key": chat.id, "title": from, "body": text, "icon": "message.fill", "sound": "Pop",
        "person": ["name": from, "color": chat.color],
        "reactions": ["❤️", "👍", "😂"],
        "reply": "Reply to \(chat.isGroup ? chat.name : chat.firstName)",
        "actions": [["id": "open", "title": "Open", "icon": "bubble.left.and.bubble.right.fill"]],
    ]
    if chat.isGroup { args["subtitle"] = chat.name }
    OxineApp.call("notify.post", args)
}

/// They start typing, then answer.
@MainActor func answerSoon(in id: String) {
    OxineApp.after(1.2) {
        guard let i = index(of: id) else { return }
        chats[i].typing = chats[i].isGroup ? chats[i].members.randomElement() : chats[i].name
        render()
        OxineApp.after(2.4) { arrive(in: id) }
    }
}

@MainActor func markRead(_ id: String) {
    guard let i = index(of: id), chats[i].unread > 0 else { return }
    chats[i].unread = 0
    OxineApp.call("notify.end", ["key": id])
}

@MainActor func write(_ text: String, in id: String) {
    guard let i = index(of: id) else { return }
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let message = Message(id: newID(), from: nil, text: text, time: clock(), pending: true)
    chats[i].messages.append(message)
    chats[i].draft = ""
    chats[i].replyingTo = nil
    render()
    // Delivered a moment later.
    OxineApp.after(0.6) {
        guard let i = index(of: id), let m = chats[i].messages.firstIndex(where: { $0.id == message.id }) else { return }
        chats[i].messages[m].pending = false
        render()
    }
    answerSoon(in: id)
}

@MainActor func react(_ emoji: String, to messageID: Int, in id: String) {
    guard let i = index(of: id), let m = chats[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
    chats[i].messages[m].reactions = emoji.isEmpty ? [] : [emoji]
    render()
}

@MainActor func handleEvent(surface: String, ref: String?, kind: String, value: Any?) {
    let text = value as? String
    if surface == "notice" {
        // An answer from the notch notice; `ref` is the chat.
        guard let id = ref, let i = index(of: id) else { return }
        switch kind {
        case "reply":
            markRead(id)
            write(text ?? "", in: id)
        case "react":
            markRead(id)
            if let last = chats[i].messages.last(where: { $0.from != nil }) { react(text ?? "", to: last.id, in: id) }
        case "open":
            openChat = id
            markRead(id)
            render()
        default:
            break
        }
        return
    }
    guard let ref else { return }
    let current = openChat
    switch (ref, kind) {
    case ("arrive", _):
        // Someone writes in a moment: the open chat's person, or anyone.
        let id = current ?? chats.randomElement()!.id
        OxineApp.after(current == nil ? 0.4 : 0.1) { arrive(in: id) }
    case ("back", _):
        openChat = nil
        render()
    case ("draft", "change"):
        guard let id = current, let i = index(of: id) else { return }
        chats[i].draft = text ?? ""
        render()
    case ("draft", "submit"), ("send", _):
        guard let id = current, let i = index(of: id) else { return }
        write(text ?? chats[i].draft, in: id)
    case ("cancelReply", _):
        guard let id = current, let i = index(of: id) else { return }
        chats[i].replyingTo = nil
        render()
    default:
        if ref.hasPrefix("open:") {
            let id = String(ref.dropFirst(5))
            openChat = id
            markRead(id)
            render()
        } else if ref.hasPrefix("msg:"), let id = current, let messageID = Int(ref.dropFirst(4)),
                  let i = index(of: id) {
            if kind == "react" { react(text ?? "", to: messageID, in: id) }
            if kind == "reply" { chats[i].replyingTo = messageID; render() }
        }
    }
}

@MainActor func handle(_ message: [String: Any]) {
    guard let t = message["t"] as? String else { return }
    switch t {
    case "hello":
        OxineApp.send(["t": "ready"])
        render()
        // Someone writes shortly after it starts, so there's something to see.
        OxineApp.after(6) { arrive(in: "ece") }
    case "event":
        handleEvent(surface: message["surface"] as? String ?? "", ref: message["ref"] as? String,
                    kind: message["kind"] as? String ?? "", value: message["value"])
    case "lifecycle":
        let surface = message["surface"] as? String ?? ""
        switch message["phase"] as? String {
        case "activate": visible.insert(surface)
        case "deactivate": visible.remove(surface)
        default: return
        }
        // Opening the chat that has unread messages reads them.
        if let id = openChat, isReading(id) { markRead(id); render() }
    default:
        break
    }
}

// MARK: - Run

OxineApp.run { handle($0) }
