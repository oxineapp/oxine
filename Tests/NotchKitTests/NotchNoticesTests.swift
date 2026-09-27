import Foundation
import Testing
@testable import NotchKit

private let metrics = NoticeMetrics()

/// Smart everywhere, whatever the person has chosen on this Mac.
@MainActor
private func freshNotices() -> NotchNotices {
    let notices = NotchNotices.shared
    notices.userPlacement = { _ in .automatic }
    notices.userOpenBehavior = { .automatic }
    notices.context = { NoticeContext() }
    notices.dismissAll()
    notices.setNotch(present: true, open: false)
    return notices
}
private func quick(_ title: String = "Copied", group: String? = nil) -> NotchNotice {
    NotchNotice(icon: "doc.on.doc", title: title, group: group)
}
private func asking(_ title: String = "Doorbell") -> NotchNotice {
    NotchNotice(icon: "bell", title: title, actions: [.init(id: "resume", title: "Resume")])
}
/// A short one from an app that asks for an ear.
private func beside(_ title: String = "Copied") -> NotchNotice {
    NotchNotice(icon: "doc.on.doc", title: title, placement: .beside)
}
/// A quiet one that rests as a circle when floating.
private func circle(_ emoji: String = "🔥") -> NotchNotice {
    NotchNotice(icon: "flame", title: "Streak", emoji: emoji)
}
private func reading(_ title: String = "Mom") -> NotchNotice {
    NotchNotice(icon: "message", title: title, detail: "Did you eat?", actions: [.init(id: "read", title: "Read")])
}

/// One at a time: they share the app's one `NotchNotices`, and the ones that
/// wait for a timer would otherwise see the others clear it.
@Suite(.serialized)
struct NotchNoticesTests {
    @Test
    func smartPutsEverythingUnderTheNotchFirstAndOneLinersInAnEarNext() {
        let free = NoticeContext()
        // The ears keep what they show; a one-liner takes one only when the
        // strip under the notch is taken.
        let ears: [NoticePlacement] = [.below, .right, .left, .floating, .floatingBeside, .floatingThird, .floatingFourth]
        #expect(NotchNotices.smartOrder(for: quick(), context: free, metrics: metrics) == ears)
        // A button or two with short titles fit an ear (they show when pointed at).
        #expect(NotchNotices.smartOrder(for: asking(), context: free, metrics: metrics) == ears)
        // Detail to read, urgency, length or too many buttons: under the notch,
        // then floating below it, and only then an ear.
        let under: [NoticePlacement] = [.below, .floating, .floatingBeside, .floatingThird, .floatingFourth, .right, .left]
        #expect(NotchNotices.smartOrder(for: reading(), context: free, metrics: metrics) == under)
        var urgent = quick("Battery at 10%")
        urgent.emphasis = .urgent
        #expect(NotchNotices.smartOrder(for: urgent, context: free, metrics: metrics) == under)
        // In the Smart style, urgent ones float first, on glass.
        #expect(NotchNotices.smartOrder(for: urgent, context: free, metrics: metrics, urgentFloats: true)
            == [.floating, .floatingBeside, .floatingThird, .floatingFourth, .below, .right, .left])
        let long = quick("A much longer title than an ear can hold")
        #expect(NotchNotices.smartOrder(for: long, context: free, metrics: metrics) == under)
        var three = quick()
        three.actions = ["a", "b", "c"].map { .init(id: $0, title: $0) }
        #expect(NotchNotices.smartOrder(for: three, context: free, metrics: metrics) == under)
    }

    @Test
    func aSecondLongNoticeFloatsUnderTheFirstInsteadOfTakingAnEar() {
        let long = quick("You're on fire! You have reached a streak")
        #expect(NotchNotices.slot(for: long, user: .automatic, notchUsable: true, context: NoticeContext(),
                                  taken: [.below], metrics: metrics) == .floating)
    }

    @Test
    func smartNeverCoversAWaitingAgentOrUsesTheEarsUnderTheVolumeDisplay() {
        var agentWaiting = NoticeContext()
        agentWaiting.right = .important
        #expect(NotchNotices.smartOrder(for: quick(), context: agentWaiting, metrics: metrics) == [.below, .left, .floating, .floatingBeside, .floatingThird, .floatingFourth])
        var music = NoticeContext()
        music.left = .ambient
        #expect(NotchNotices.sideOrder(music) == [.right, .left])
        music.right = .ambient
        music.sneakPeek = true
        #expect(NotchNotices.sideOrder(music) == [.left, .right])
        var hud = NoticeContext()
        hud.hudActive = true
        #expect(NotchNotices.smartOrder(for: quick(), context: hud, metrics: metrics) == [.below, .floating, .floatingBeside, .floatingThird, .floatingFourth])
    }

    @Test
    func aTakenSpotFallsToTheNextBestAndNothingFreeWaits() {
        let ctx = NoticeContext()
        #expect(NotchNotices.slot(for: quick(), user: .left, notchUsable: true, context: ctx,
                                  taken: [.left], metrics: metrics) == .below)
        // An app asking for an ear gets the best free one.
        #expect(NotchNotices.slot(for: beside(), user: .automatic, notchUsable: true, context: ctx,
                                  taken: [.right], metrics: metrics) == .left)
        #expect(NotchNotices.slot(for: quick(), user: .automatic, notchUsable: false, context: ctx,
                                  taken: [], metrics: metrics) == .floating)
        #expect(NotchNotices.slot(for: quick(), user: .automatic, notchUsable: true, context: ctx,
                                  taken: Set(NoticePlacement.slots), metrics: metrics) == nil)
        var hinted = quick()
        hinted.placement = .below
        #expect(NotchNotices.slot(for: hinted, user: .automatic, notchUsable: true, context: ctx,
                                  taken: [], metrics: metrics) == .below)
        #expect(NotchNotices.slot(for: hinted, user: .left, notchUsable: true, context: ctx,
                                  taken: [], metrics: metrics) == .left)
    }

    @Test
    func whileOpenQuietProgressWaitsAndTheRestStays() {
        var progress = quick("Downloading")
        progress.progress = 0.3
        #expect(NotchNotices.openBehavior(for: progress, user: .automatic) == .wait)
        // Smart floats below the open notch; On the notch (or a spot on it) docks.
        #expect(NotchNotices.openBehavior(for: asking(), user: .automatic) == .float)
        #expect(NotchNotices.openBehavior(for: asking(), user: .automatic, placement: .notch) == .attach)
        #expect(NotchNotices.openBehavior(for: asking(), user: .automatic, placement: .left) == .attach)
        #expect(NotchNotices.openBehavior(for: asking(), user: .float) == .float)
        var hinted = asking()
        hinted.whenOpen = .wait
        #expect(NotchNotices.openBehavior(for: hinted, user: .automatic) == .wait)
    }

    @MainActor @Test
    func severalNoticesSpreadAcrossTheNotchAndAGroupReplacesInPlace() {
        let notices = freshNotices()
        let first = notices.post(asking())
        let second = notices.post(quick("One", group: "copy"))
        notices.post(quick("Two"))
        #expect(notices.shown[.below]?.id == first)
        #expect(notices.shown[.right]?.id == second)
        #expect(notices.shown[.left]?.title == "Two")
        let again = notices.post(quick("One again", group: "copy"))
        #expect(notices.shown[.right]?.id == again)
        #expect(!notices.isActive(second))
        notices.update(again) { $0.progress = 0.5 }
        #expect(notices.shown[.right]?.progress == 0.5)
        notices.dismissAll()
    }

    @MainActor @Test
    func pointingOpensThePeekAndAButtonRunsTheAppsActionThenCloses() {
        let notices = freshNotices()
        var pressed: [String] = []
        let id = notices.post(reading()) { pressed.append($0) }
        #expect(notices.shown[.below]?.id == id)
        notices.pointerOnAttached(.below)
        #expect(notices.peekingID == id)
        notices.perform(id, "read")
        #expect(pressed == ["read"])
        #expect(!notices.isActive(id))
        #expect(notices.peekingID == nil)
        notices.pointerOnAttached(nil)
    }

    @MainActor @Test
    func pointingAtAnEarShowsItsButtonsThereWithoutOpeningAnything() {
        let notices = freshNotices()
        var doorbell = asking()
        doorbell.placement = .beside
        let id = notices.post(doorbell)
        #expect(notices.shown[.right]?.id == id)
        notices.pointerOnAttached(.right)
        #expect(notices.peekingID == id)
        #expect(notices.visible(.below) == nil)
        #expect(!notices.occupiesBelowNotch)
        notices.pointerOnAttached(nil)
        #expect(notices.peekingID == nil)
        notices.dismissAll()
    }

    @MainActor @Test
    func aFrameLeftByANoticeOnItsWayOutNeverCoversTheNextOne() {
        let notices = freshNotices()
        let old = notices.post(beside("Old"))
        notices.reportFrame(old, CGRect(x: 0, y: 0, width: 80, height: 24))
        notices.dismiss(old)
        let new = notices.post(beside("New"))
        notices.reportFrame(new, CGRect(x: 100, y: 0, width: 60, height: 24))
        // The old view reports once more while it fades out.
        notices.reportFrame(old, CGRect(x: 0, y: 30, width: 300, height: 90))
        #expect(notices.attachedRect(.right) == CGRect(x: 100, y: 0, width: 60, height: 24))
        notices.dismissAll()
    }

    @MainActor @Test
    func oneWithButtonsThatTimesOutWaitsInTheListAndAPlainOneGoes() async throws {
        let notices = freshNotices()
        var pressed: [String] = []
        var doorbell = asking()
        doorbell.duration = 0.05
        let asked = notices.post(doorbell) { pressed.append($0) }
        var copied = quick()
        copied.duration = 0.05
        let plain = notices.post(copied)
        #expect(notices.listed.map(\.id) == [asked])
        try await Task.sleep(for: .milliseconds(300))
        #expect(notices.held.map(\.id) == [asked])
        #expect(notices.shown.isEmpty)
        #expect(!notices.isActive(plain))
        // Answered from the list, the app still hears it.
        notices.perform(asked, "resume")
        #expect(pressed == ["resume"])
        #expect(notices.held.isEmpty && notices.listed.isEmpty)
        notices.dismissAll()
    }

    @MainActor @Test
    func aNewNoticeInTheSameGroupRetiresTheOneInTheList() async throws {
        let notices = freshNotices()
        var first = asking()
        first.group = "earson.doorbell"
        first.duration = 0.05
        let old = notices.post(first)
        try await Task.sleep(for: .milliseconds(300))
        #expect(notices.held.map(\.id) == [old])
        var second = asking()
        second.group = "earson.doorbell"
        let new = notices.post(second)
        #expect(notices.held.isEmpty)
        #expect(notices.listed.map(\.id) == [new])
        notices.dismissAll()
    }

    @MainActor @Test
    func oneThatFloatedBecauseTheNotchOpenedGoesBackOntoItWhenItCloses() {
        let notices = freshNotices()
        notices.userOpenBehavior = { .float }
        let id = notices.post(beside())
        #expect(notices.shown[.right]?.id == id)
        notices.setNotch(present: true, open: true)
        #expect(notices.shown[.floating]?.id == id)
        notices.setNotch(present: true, open: false)
        #expect(notices.shown[.floating] == nil)
        #expect(notices.shown[.right]?.id == id)
        notices.userOpenBehavior = { .automatic }
        notices.dismissAll()
    }

    @MainActor @Test
    func whenTheNotchIsRebuiltWhatFloatedOffGoesBackAndNothingStacksOnTop() {
        let notices = freshNotices()
        let first = notices.post(reading())
        #expect(notices.shown[.below]?.id == first)
        notices.setNotch(present: false, open: false)
        #expect(notices.shown[.floating]?.id == first)
        notices.setNotch(present: true, open: false)
        #expect(notices.shown[.below]?.id == first)
        #expect(notices.shown[.floating] == nil)
        notices.dismissAll()
    }

    @Test
    func theStylesDecideWhereUrgentOnesGo() {
        var urgent = quick("Battery at 10%")
        urgent.emphasis = .urgent
        let ctx = NoticeContext()
        #expect(NotchNotices.slot(for: urgent, user: .automatic, notchUsable: true, context: ctx,
                                  taken: [], metrics: metrics) == .floating)
        #expect(NotchNotices.slot(for: urgent, user: .notch, notchUsable: true, context: ctx,
                                  taken: [], metrics: metrics) == .below)
        // Floating fills the pill beside the first before touching the notch.
        #expect(NotchNotices.slot(for: quick(), user: .floating, notchUsable: true, context: ctx,
                                  taken: [.floating], metrics: metrics) == .floatingBeside)
        // On the notch: under it, then an ear.
        #expect(NotchNotices.slot(for: quick(), user: .notch, notchUsable: true, context: ctx,
                                  taken: [], metrics: metrics) == .below)
        #expect(NotchNotices.slot(for: quick(), user: .notch, notchUsable: true, context: ctx,
                                  taken: [.below], metrics: metrics) == .right)
    }

    @MainActor @Test
    func openingTheNotchFloatsOnePillWhileTheOtherWaitsAndBothGoBack() {
        let notices = freshNotices()
        let ear = notices.post(beside())
        let under = notices.post(reading())
        #expect(notices.shown[.right]?.id == ear)
        #expect(notices.shown[.below]?.id == under)
        notices.setNotch(present: true, open: true)
        // Two pills never share the row: one floats, the other waits.
        let floating = NoticePlacement.floats.compactMap { notices.shown[$0]?.id }
        #expect(floating.count == 1 && Set([ear, under]).contains(floating[0]))
        #expect(notices.isActive(ear) && notices.isActive(under))
        #expect(notices.openStrip.isEmpty)
        notices.setNotch(present: true, open: false)
        #expect(notices.shown[.right]?.id == ear)
        #expect(notices.shown[.below]?.id == under)
        #expect(NoticePlacement.floats.allSatisfy { notices.shown[$0] == nil })
        notices.dismissAll()
    }

    @Test
    func theFloatingRowHoldsAPillAndTwoCirclesOrFourCircles() {
        #expect(NotchNotices.floatRowFits(quick(), with: [circle(), circle()]))
        #expect(!NotchNotices.floatRowFits(circle(), with: [quick(), circle(), circle()]))
        #expect(NotchNotices.floatRowFits(circle(), with: [circle(), circle(), circle()]))
        #expect(!NotchNotices.floatRowFits(circle(), with: [circle(), circle(), circle(), circle()]))
        #expect(!NotchNotices.floatRowFits(quick("Two"), with: [quick("One")]))
    }

    @MainActor @Test
    func anUrgentPillSendsBackThePillInTheRowAndTheCirclesStay() {
        let notices = freshNotices()
        notices.userPlacement = { _ in .floating }
        let first = notices.post(quick("One"))
        let ring = notices.post(circle())
        let second = notices.post(quick("Two"))
        #expect(notices.shown[.floating]?.id == first)
        #expect(notices.shown[.floatingBeside]?.id == ring)
        // A second pill doesn't fit the row: it waits.
        #expect(!NoticePlacement.floats.contains { notices.shown[$0]?.id == second } && notices.isActive(second))
        var urgent = quick("Battery at 10%")
        urgent.emphasis = .urgent
        let alarm = notices.post(urgent)
        #expect(notices.shown[.floating]?.id == alarm)
        #expect(notices.shown[.floatingBeside]?.id == ring)
        #expect(notices.isActive(first))
        notices.userPlacement = { _ in .automatic }
        notices.dismissAll()
    }

    @MainActor @Test
    func openingTheNotchDocksWhatStaysAndHoldsWhatWaits() {
        let notices = freshNotices()
        notices.userPlacement = { _ in .notch }
        let doorbell = notices.post(asking())
        var download = quick("Downloading")
        download.progress = 0.2
        let downloadID = notices.post(download)
        notices.setNotch(present: true, open: true)
        #expect(notices.openStrip.map(\.id) == [doorbell])
        #expect(notices.isActive(downloadID))
        #expect(notices.visible(.right) == nil)
        notices.setNotch(present: true, open: false)
        #expect(notices.openStrip.isEmpty)
        #expect(notices.isActive(doorbell) && notices.isActive(downloadID))
        #expect(notices.shown.values.contains { $0.id == downloadID })
        notices.userPlacement = { _ in .automatic }
        notices.dismissAll()
    }

    @Test
    func aQuietRingEmojiOrShortValueRestsAsACircleAndPopsIn() {
        var ring = quick("Uploading")
        ring.progress = 0.3
        #expect(ring.restsAsCircle)
        var emoji = quick("Streak")
        emoji.emoji = "🔥"
        #expect(emoji.restsAsCircle)
        var value = quick("Pasta")
        value.look = .hero
        value.hero = "0:12"
        #expect(value.restsAsCircle)
        value.hero = "10,000"
        #expect(!value.restsAsCircle)
        // Buttons need a pill, unless the app asks for a circle.
        #expect(!asking().restsAsCircle)
        var calling = asking()
        calling.shape = .circle
        #expect(calling.restsAsCircle)
        #expect(ring.arrival == .pop)
        #expect(quick().arrival == .drop)
        calling.entrance = .ring
        #expect(calling.arrival == .ring)
    }

    @MainActor @Test
    func messagesFromOneAppStackUnderTheNotchWithACount() {
        let notices = freshNotices()
        func message(_ name: String, app: String = "chat", chat: String) -> NotchNotice {
            NotchNotice(icon: "message", title: name, detail: "hi", group: "\(app):\(chat)", source: app,
                        look: .message, person: .init(name: name), reply: "Reply")
        }
        let ece = notices.post(message("Ece", chat: "ece"))
        #expect(notices.shown[.below]?.id == ece)
        // Another chat from the same app joins it, on top, instead of floating.
        let selin = notices.post(message("Selin", chat: "climb"))
        #expect(notices.shown[.below]?.id == selin)
        #expect(notices.shown[.below]?.stack.map(\.id) == [ece])
        #expect(NoticePlacement.floats.allSatisfy { notices.shown[$0] == nil })
        #expect(notices.listed.count == 2)
        // Another app's message doesn't.
        let other = notices.post(message("Deniz", app: "mail", chat: "deniz"))
        #expect(notices.shown[.below]?.id == selin)
        #expect(notices.all.contains { $0.id == other })
        notices.dismiss(other)
        // Ece again: her older message is outdated, not counted twice.
        let eceAgain = notices.post(message("Ece", chat: "ece"))
        #expect(notices.shown[.below]?.id == eceAgain)
        #expect(notices.shown[.below]?.stack.map(\.id) == [selin])
        // Answering the top brings up the next where it was.
        notices.perform(eceAgain, "reply:yes")
        #expect(notices.shown[.below]?.id == selin)
        #expect(notices.shown[.below]?.stack.isEmpty == true)
        notices.dismissAll()
        #expect(notices.all.isEmpty)
    }

    @MainActor @Test
    func aCircleStaysACircleWhenAButtonArrivesLater() {
        let notices = freshNotices()
        notices.userPlacement = { _ in .floating }
        var recording = quick("Recording")
        recording.look = .hero
        recording.hero = "0:00"
        let id = notices.post(recording)
        #expect(notices.all.first { $0.id == id }?.restsAsCircle == true)
        // Its app re-posts it whole, now with Stop: still a circle, which
        // shows the button when it opens.
        recording.hero = "0:15"
        recording.actions = [.init(id: "stop", title: "Stop", role: .destructive, icon: "stop.fill")]
        notices.update(id) { $0 = recording }
        #expect(notices.all.first { $0.id == id }?.restsAsCircle == true)
        // A shape the app asks for still wins.
        notices.update(id) { $0.shape = .pill }
        #expect(notices.all.first { $0.id == id }?.restsAsCircle == false)
    }

    @MainActor @Test
    func typingAReplyKeepsItOpenAfterThePointerLeaves() {
        let notices = freshNotices()
        notices.userPlacement = { _ in .floating }
        var message = reading()
        message.reply = "Reply"
        let id = notices.post(message)
        notices.pointerOnFloating(id)
        #expect(notices.peekingID == id)
        notices.typing(id, true)
        notices.pointerOnFloating(nil)
        #expect(notices.peekingID == id)
        notices.typing(id, false)
        #expect(notices.peekingID == nil)
        notices.userPlacement = { _ in .automatic }
        notices.dismissAll()
    }

    @MainActor @Test
    func aClosedNoticeDoesntComeBackWhenItsAppPostsItAgain() {
        let notices = freshNotices()
        let download = quick("Downloading")
        let id = notices.post(download)
        notices.close(id)
        notices.post(download)
        #expect(!notices.isActive(id))
        notices.dismissAll()
    }

    @Test
    func metricsOverridesOnlyChangeTheFieldsGiven() throws {
        var m = NoticeMetrics()
        m.peekWidth = 340
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(NoticeMetrics.self, from: data)
        #expect(back.peekWidth == 340)
        #expect(back.sideMaxWidth == NoticeMetrics().sideMaxWidth)
    }
}
