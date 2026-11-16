import Testing
@testable import AgentBoard

@Test func pathsInAProjectReadAsTheProjectAndTheRest() {
    let base = "/Users/me/code/storefront"
    #expect(DisplayPath.short("/Users/me/code/storefront-worktrees/fix-login", base: base, home: "/Users/me") == "storefront worktrees › fix-login")
    #expect(DisplayPath.short("/Users/me/code/storefront/web/app", base: base, home: "/Users/me") == "storefront › web/app")
    #expect(DisplayPath.short(base, base: base, home: "/Users/me") == "storefront")
    // A sibling whose name only starts like the project isn't inside it.
    #expect(DisplayPath.short("/Users/me/code/storefront2/x", base: base, home: "/Users/me") == "~/code/storefront2/x")
}

@Test func pathsInHomeUseATilde() {
    #expect(DisplayPath.short("/Users/me/agentboard/projects", home: "/Users/me") == "~/agentboard/projects")
    #expect(DisplayPath.short("/Users/me", home: "/Users/me/") == "~")
    #expect(DisplayPath.short("/opt/tools", home: "/Users/me") == "/opt/tools")
}

@Test func longPathsKeepTheStartAndTheLastFolder() {
    let long = "/Users/me/very/deep/folder/structure/that/goes/on/and/on/fix-login"
    #expect(DisplayPath.short(long, home: "/Users/me") == "~/…/fix-login")
    #expect(DisplayPath.short("/Volumes/External/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r", home: "/Users/me") == "/Volumes/…/r")
}
