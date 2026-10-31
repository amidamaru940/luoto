/*
 * Luoto — a fork of Atoll (DynamicIsland)
 * Copyright (C) 2026 amidamaru940 and Luoto contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation

/// HTML from the clipboard, handed to WebKit's importer with a content
/// security policy that forbids every network load: a copied page's pictures,
/// style sheets and fonts must never be fetched, which would tell a server
/// the Mac's address and that it copied (security audit, 30.10.2026).
///
/// The copied HTML itself is not changed: the policy is one `<meta>` put in
/// front of it, after a byte order mark, comments, an XML declaration and a
/// doctype (a doctype must stay the first thing the parser sees). On macOS 26
/// the importer loads nothing anyway and the RTF «Clipboard» keeps is
/// byte-for-byte the same with the policy; on releases whose importer did
/// load, the policy stops it. Two earlier attempts cut copied text (regexes)
/// or re-wrote the page (a parse and re-serialisation) and were dropped.
enum ClipboardHTML {
    /// Inline styles and inline `data:` pictures and fonts stay allowed: the
    /// copied formatting lives in them, and they are not the network.
    static let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">"#

    /// `data` with the policy in, or `data` as it came when it is UTF-16 or
    /// UTF-32 (an ASCII policy cannot go into those bytes as they are).
    /// Every ASCII-compatible encoding keeps its bytes: they are handled one
    /// byte per character (Latin-1), so nothing is re-encoded.
    static func withoutNetwork(_ data: Data) -> Data {
        guard !isWideEncoding(data),
              let bytes = String(data: data, encoding: .isoLatin1),
              let guarded = withoutNetwork(bytes).data(using: .isoLatin1)
        else { return data }
        return guarded
    }

    static func withoutNetwork(_ html: String) -> String {
        let insertAt = prologEnd(of: html)
        return String(html[..<insertAt]) + policy + String(html[insertAt...])
    }

    /// Where the policy goes: after a byte order mark, white space, comments
    /// and an XML declaration, and after a doctype if one follows them;
    /// otherwise at the very start.
    static func prologEnd(of html: String) -> String.Index {
        var index = html.startIndex
        for bom in ["\u{FEFF}", "\u{EF}\u{BB}\u{BF}"] where html[index...].hasPrefix(bom) {
            index = html.index(index, offsetBy: bom.count)
        }
        let afterBOM = index
        while true {
            while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
            let rest = html[index...]
            if rest.hasPrefix("<!--"), let end = rest.range(of: "-->") {
                index = end.upperBound
            } else if rest.hasPrefix("<?"), let end = rest.range(of: "?>") {
                index = end.upperBound
            } else if rest.prefix(9).lowercased() == "<!doctype", let end = rest.firstIndex(of: ">") {
                return html.index(after: end)
            } else {
                return afterBOM
            }
        }
    }

    /// UTF-16 or UTF-32: a byte order mark, or a NUL among the first bytes.
    static func isWideEncoding(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) { return true }
        return head.contains(0)
    }
}
