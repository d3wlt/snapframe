import Foundation

/// Quoting for the one privileged shell command the elevated update runs through `do shell script`.
public enum HelperScript {
    /// POSIX single-quoted string: safe for spaces, `$`, backslashes and apostrophes (`'` becomes `'\''`).
    public static func shellQuote(_ s: String) -> String {
        // Scalars, not Characters: "'" + U+0301 is one Character and would slip past a Character-level replace.
        var out = "'"
        for u in s.unicodeScalars {
            if u == "'" { out += "'\\''" } else { out.unicodeScalars.append(u) }
        }
        return out + "'"
    }

    /// AppleScript that runs `command` through the shell; `admin` adds the password prompt.
    /// The command goes into a double-quoted AppleScript literal, where only `\` and `"` (and line breaks) need escaping.
    public static func appleScript(running command: String, admin: Bool = true) -> String {
        // Scalars, not Characters: "\r\n" is one Character, and `"` + a combining mark would hide the quote.
        var literal = ""
        for u in command.unicodeScalars {
            switch u {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case "\t": literal += "\\t"
            default: literal.unicodeScalars.append(u)
            }
        }
        return "do shell script \"\(literal)\"" + (admin ? " with administrator privileges" : "")
    }
}
