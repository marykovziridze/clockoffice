import Foundation
import ClockOfficeCore

/// Sample sessions for design renders. Invented; never shown in the running app.
enum Fixtures {
    static func sessions(now: Date = Date()) -> [Session] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        return [
            Session(id: "a", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/client-website",
                    project: "Client website", title: "Homepage from Figma", state: .asking, since: ago(51),
                    question: "The homepage is built from the Figma file and passes the checks. Do you want me to put it on the preview link so the client can look?",
                    headline: "Homepage is built. Put it on the preview link?",
                    options: ["yes", "not yet"].map { ReplyOption(label: $0, send: $0) },
                    inShort: "Homepage built from the Figma file. Asks whether to put it on the preview link.",
                    lastDid: "Built the homepage and ran the checks.",
                    remoteURL: URL(string: "https://claude.ai/code")),
            Session(id: "b", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/clockwork",
                    project: "Clockwork", title: "Updating the release notes", state: .asking, since: ago(12),
                    question: "The release notes are written. One of the changes needs people to run the installer again. Should that one go at the top, or stay in the list in date order?",
                    headline: "Installer change: at the top, or in date order?",
                    options: ["at the top", "date order"].map { ReplyOption(label: $0, send: $0) },
                    inShort: "Release notes written. Asks where the one change that needs the installer should go.",
                    lastDid: "Listed what changed since the last release and wrote the notes."),
            Session(id: "c", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/ClockOffice",
                    project: "ClockOffice", title: "Drawing the menu-bar icon", state: .working, since: ago(0.2),
                    inShort: "Redrawing the menu-bar icon.",
                    lastDid: "Drew the dial from the Clockwork proportions."),
            Session(id: "d", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/design-system",
                    project: "Design system", title: "Syncing colour tokens from Figma", state: .working, since: ago(2),
                    inShort: "Syncing the colour tokens from Figma.",
                    lastDid: "Read the variables from the Figma file."),
            Session(id: "e", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/seo-audit",
                    project: "SEO audit", title: "Redirects for 240 old pages", state: .done, since: ago(34),
                    inShort: "Redirect list written and checked.",
                    lastDid: "Checked every old address against the new site."),
            Session(id: "f", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/launch-video",
                    project: "Launch video", title: "Second cut with sound", state: .done, since: ago(4 * 24 * 60),
                    inShort: "Second cut rendered.",
                    lastDid: "Rendered the second cut."),
        ]
    }

    /// A short sample conversation per session, for renders.
    static func turns() -> [String: [Turn]] {
        [
            "a": [
                Turn(id: "1", who: .you, text: "Build the homepage from the Figma file and tell me when it passes the checks."),
                Turn(id: "2", who: .assistant, text: "The homepage is built from the Figma file and passes the checks: **6 sections**, the layout holds at phone, tablet and desktop width, and every picture has its description.\n\nOne thing differs from the file: on a phone the headline runs to three lines where the file shows two. I kept the file's type size and did not shrink it.\n\nDo you want me to put it on the preview link so the client can look?"),
            ],
            "b": [
                Turn(id: "1", who: .you, text: "write the release notes for this version"),
                Turn(id: "2", who: .assistant, text: "The release notes are written, newest change first. One of the changes needs people to run the installer again. Should that one go at the top, or stay in the list in date order?"),
            ],
            "long": [
                Turn(id: "0", who: .you, text: "the dial in the app icon is not centered imo [screenshot]"),
                Turn(id: "1", who: .assistant, text: "You were right: the dial was off-centre, and it's fixed in the build running now (`80e247f`).\n\nThe icon had its tile sitting off-centre and larger than the standard size, so macOS re-fitted it and pushed the dial low and to the side. I rebuilt the icon on the standard layout and checked the dial against a centred guide circle; its ticks sit on the circle all the way round.\n\nThe new icon has its own file name, so macOS picks it up without a restart. I can't see your Dock, so tell me if it still looks off."),
            ],
            "c": [
                Turn(id: "1", who: .you, text: "[screenshot] the hand looks too thick at this size"),
                Turn(id: "2", who: .assistant, text: "Redrawing it now: a thinner hand, and five marks instead of twelve."),
            ],
            "e": [
                Turn(id: "1", who: .you, text: "make the redirect list for the old site"),
                Turn(id: "2", who: .assistant, text: "The redirect list is written: 240 old addresses, each one pointing at its new page. I checked every one against the new site."),
            ],
        ]
    }
}
