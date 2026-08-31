import AppKit
import Testing
@testable import NotchKit

@MainActor
private func lyricLabel(_ canvas: LyricCanvas) -> NSTextField {
    canvas.subviews.compactMap { $0 as? NSTextField }.first!
}

@Test @MainActor
func changingAnimationDurationDoesNotEraseCurrentLine() {
    let canvas = LyricCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    var style = LyricCanvas.Style()
    style.animation = "none"
    let text = "Keep the current line visible while adjusting settings"
    canvas.render(text: text, track: "Artist — Song", style: style)
    style.animation = "typewriter"
    style.animationDuration = 2
    canvas.render(text: text, track: "Artist — Song", style: style)
    #expect(lyricLabel(canvas).stringValue == text)
    for duration in [1.8, 1.6, 1.4, 1.2] {
        style.animationDuration = duration
        canvas.render(text: text, track: "Artist — Song", style: style)
        #expect(lyricLabel(canvas).stringValue == text)
    }
    canvas.cancelAnimation()
}

@Test @MainActor
func resizingDuringTypewriterFinishesCurrentLine() {
    let canvas = LyricCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    var style = LyricCanvas.Style()
    style.animation = "typewriter"
    style.animationDuration = 2
    let text = "The full current lyric remains readable after a live resize"
    canvas.render(text: text, track: "", style: style)
    canvas.setFrameSize(NSSize(width: 300, height: 200))
    style.fontSize = 28
    canvas.render(text: text, track: "", style: style)
    #expect(lyricLabel(canvas).stringValue == text)
    canvas.cancelAnimation()
}

@Test @MainActor
func wrappingDoesNotLoseItsLastLineAfterFontChanges() {
    let canvas = LyricCanvas(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
    var style = LyricCanvas.Style()
    style.animation = "none"
    for size in [18.0, 22, 28, 34, 40] {
        style.fontSize = size
        canvas.render(text: "First lyric line\nSecond lyric line", track: "", style: style)
        let label = lyricLabel(canvas)
        #expect(label.maximumNumberOfLines >= 2)
        #expect(label.frame.height >= NSLayoutManager().defaultLineHeight(for: label.font!) * 2 - 1)
    }
}

@Test @MainActor
func liveStyleEditsCancelOldEffectsButNextLineStillAnimates() {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    let canvas = LyricCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    var style = LyricCanvas.Style()
    style.animation = "slide"
    canvas.render(text: "Current line", track: "", style: style)
    #expect(lyricLabel(canvas).layer?.animation(forKey: "lyricAppearance") != nil)
    style.backgroundOpacity = 0.1
    canvas.render(text: "Current line", track: "", style: style)
    #expect(lyricLabel(canvas).layer?.animation(forKey: "lyricAppearance") == nil)
    #expect(lyricLabel(canvas).stringValue == "Current line")
    style.animation = "typewriter"
    canvas.render(text: "Current line", track: "", style: style)
    #expect(lyricLabel(canvas).stringValue == "Current line")
    canvas.render(text: "Next line", track: "", style: style)
    #expect(lyricLabel(canvas).stringValue == "")
    canvas.cancelAnimation()
    #expect(lyricLabel(canvas).stringValue == "Next line")
}

@Test @MainActor
func scrubbingLyricTimingShowsTheNewLineImmediately() {
    let canvas = LyricCanvas(frame: NSRect(x: 0, y: 0, width: 520, height: 160))
    var style = LyricCanvas.Style()
    style.animation = "typewriter"
    style.animationDuration = 2
    canvas.render(text: "Before adjustment", track: "", style: style)
    for text in ["Earlier lyric", "Even earlier lyric", "Later lyric"] {
        canvas.render(text: text, track: "", style: style, animateChanges: false)
        #expect(lyricLabel(canvas).stringValue == text)
    }
    canvas.cancelAnimation()
    #expect(lyricLabel(canvas).stringValue == "Later lyric")
}
