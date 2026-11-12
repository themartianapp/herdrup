import XCTest

/// Every path the README's layout NAMES must exist. It deliberately does not
/// check the reverse — see the test's own comment for why that claim was
/// dropped after four rounds of trying to make it correct.
///
/// WHY THIS IS A TEST AND NOT A SCRIPT: I described that block as "generated
/// from `ls`, and the generator fails if a file has no description" — and then
/// committed only its OUTPUT. The generator existed for one invocation in a
/// shell. Review added an undescribed source file, the warnings-as-errors build
/// compiled it, and nothing noticed: the safeguard I had claimed did not exist
/// in the repository at all.
///
/// A guard that lives in someone's terminal history is not a guard. This one
/// runs with `swift test`.
///
/// It checks ONE DIRECTION ONLY: every path the README names must exist. Adding
/// a source file without a README entry does NOT fail — that completeness claim
/// was dropped deliberately, because enforcing it meant maintaining a second,
/// worse copy of the package manifest and would have false-failed the iOS app
/// target. This sentence previously said the opposite, which is the fourth time
/// tonight a comment outlived the guard it described.
final class ReadmeLayoutTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HerdrKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
    }

    /// Every file the README NAMES must exist. It does not claim the reverse.
    ///
    /// THIS IS A DELIBERATE REVERSAL, and worth explaining because the previous
    /// direction cost four review rounds. I had the layout assert COMPLETENESS —
    /// every source file must appear — which meant the guard had to model
    /// SwiftPM's source graph to be correct: nested sources, targets with custom
    /// paths, and more than one Swift target. It could not, and each round found
    /// another way it was wrong. Worse, it would have FALSE-FAILED the moment
    /// the iOS app target lands, which is the next piece of work.
    ///
    /// Review offered this option in round four and I took the harder path. The
    /// README is a guide, not an inventory; making it claim exhaustiveness meant
    /// maintaining a second, worse copy of the package manifest. So the claim is
    /// dropped and the block says so, leaving the one property that is cheap,
    /// true, and useful: A NAME IN THE DOCS POINTS AT SOMETHING REAL. That is
    /// what actually rots — files get renamed and the prose does not follow.
    func testEveryFileTheReadmeNamesExists() throws {
        // The layout block moved from README.md to docs/DESIGN.md with the README
        // redesign (#657); the README itself only names `Sources/HerdrKit` in prose.
        let root = repoRoot()
        let readme = try String(
            contentsOf: root.appendingPathComponent("docs/DESIGN.md"), encoding: .utf8)
        guard let open = readme.range(of: "Sources/"),
              let close = readme.range(of: "```", range: open.lowerBound..<readme.endIndex)
        else { return XCTFail("no layout block found in docs/DESIGN.md") }
        let block = String(readme[open.lowerBound..<close.lowerBound])

        // A STRICT GRAMMAR, AND NO NORMALISATION AT ALL.
        //
        // The previous version stripped a set of decoration characters before
        // matching. `trimmingCharacters(in:)` removes each listed character
        // INDEPENDENTLY from both ends rather than recognising balanced
        // formatting, so `HerdrClient.swift*` — a path that does not exist —
        // had its stray `*` stripped and silently checked the real file
        // instead. Failing closed on rows it cannot read was right; being
        // generous about what it CAN read reintroduced the same defect
        // pointing the other way, and I named that exact risk in a review
        // dispatch before shipping it.
        //
        // The block is a bare code fence, so decoration is not expected and
        // rejecting it is correct. Three shapes are legal and nothing else is:
        //     <name>.swift        a file under Sources/HerdrKit
        //     Sources/<name>/     a source directory
        //     Tests/<name>/       a test directory
        //
        // `Tests/` was added because the README legitimately names
        // `Tests/HerdrKitTests/` and the grammar had no way to express it, so the
        // guard failed closed on a row that was CORRECT. That is the right failure
        // mode — it is why this was noticed at all — but the fix belongs in the
        // grammar, not in the README: the row points at something real, which is
        // the exact property this test exists to protect. The prefix list is
        // explicit rather than "any directory" so an unknown shape still fails.
        var named: [String] = []
        var unparsed: [String] = []
        for line in block.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let token = String(text.split(separator: " ").first ?? "")
            let isFile = token.hasSuffix(".swift")
                && token.dropLast(6).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
                && !token.dropLast(6).isEmpty
            let dirPrefix = ["Sources/", "Tests/"].first { token.hasPrefix($0) }
            let isDir: Bool = {
                guard let dirPrefix, token.hasSuffix("/") else { return false }
                let name = token.dropFirst(dirPrefix.count).dropLast()
                return !name.isEmpty
                    && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }()
            if isFile { named.append("Sources/HerdrKit/" + token) }
            else if isDir { named.append(String(token.dropLast())) }
            else { unparsed.append(text) }
        }
        XCTAssertTrue(unparsed.isEmpty,
                      "layout rows that do not match the grammar, so the guard cannot check them: "
                      + unparsed.joined(separator: " | "))
        XCTAssertFalse(named.isEmpty, "no entries parsed from the layout; the check is vacuous")

        let missing = named.filter { !FileManager.default.fileExists(
            atPath: root.appendingPathComponent($0).path) }
        XCTAssertTrue(missing.isEmpty,
                      "the README names paths that do not exist: \(missing.joined(separator: ", "))")
    }
}
