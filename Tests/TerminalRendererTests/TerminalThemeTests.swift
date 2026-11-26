import Testing
import TerminalCore
@testable import TerminalRenderer

@Test func nearWhiteTextOnTheDefaultBackgroundTakesTheInk() {
    let theme = TerminalTheme.light
    let white = Cell(content: 65, fg: TerminalColor.rgb(255, 255, 255).rawValue, bg: 0)
    #expect(theme.colors(of: white).fg == theme.foreground)
    // On a fill of its own, white stays white.
    let onFill = Cell(content: 65, fg: TerminalColor.rgb(255, 255, 255).rawValue, bg: TerminalColor.rgb(20, 20, 20).rawValue)
    #expect(theme.colors(of: onFill).fg == TerminalTheme.rgb(255, 255, 255))
    let blue = Cell(content: 65, fg: TerminalColor.rgb(52, 99, 201).rawValue, bg: 0)
    #expect(theme.colors(of: blue).fg == TerminalTheme.rgb(52, 99, 201))
}

@Test func nearBlackTextOnTheDarkDefaultBackgroundTakesTheInk() {
    let theme = TerminalTheme.dark
    let black = Cell(content: 65, fg: TerminalColor.rgb(0, 0, 0).rawValue, bg: 0)
    #expect(theme.colors(of: black).fg == theme.foreground)
    // White, a dark terminal's own kind of text, stays white.
    let white = Cell(content: 65, fg: TerminalColor.rgb(255, 255, 255).rawValue, bg: 0)
    #expect(theme.colors(of: white).fg == TerminalTheme.rgb(255, 255, 255))
}
