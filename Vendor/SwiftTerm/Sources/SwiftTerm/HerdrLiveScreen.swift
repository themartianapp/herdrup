//
//  HerdrLiveScreen.swift
//  SwiftTerm
//
//  herdr: the text of the live screen, which the app keeps so the next cold start can
//  draw the pane's last screen before the stream answers.
//

extension Terminal {
    /// herdr: the live screen's rows as text, top first, each trimmed on the right: the
    /// rows the program draws on (`lines [yBase..<yBase+rows]`), not the viewport, so a
    /// reader scrolled into history does not change them. Blank rows are kept, an erased
    /// screen included: it is all blank rows.
    ///
    /// Read through `getCharacter (for:)`: a cell holding a character outside the Basic
    /// Multilingual Plane, or a grapheme cluster (an emoji, a letter with a combining
    /// mark), stores a terminal-local index that only this terminal can turn back into its
    /// text. The empty cell after a wide character is skipped, not read as a NUL.
    public func liveScreenRows () -> [String] {
        let lines = buffer.lines
        let start = min (buffer.yBase, lines.count)
        let end = min (buffer.yBase + buffer.rows, lines.count)
        return (start..<end).map {
            lines [$0].translateToString (trimRight: true, skipNullCellsFollowingWide: true,
                                          characterProvider: { self.getCharacter (for: $0) })
        }
    }
}
