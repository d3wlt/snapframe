import Foundation

// Installing an update into a folder the user can't write to (a standard account, Snapframe in /Applications owned by
// root:admin). Everything up to and including the signature check runs as the user (see `Updater.install`); only the
// final copy + swap runs as root, in ONE `do shell script ... with administrator privileges`.
//
// Swap choice: two renames (`mv target old`, `mv stage target`) with the old bundle moved back if the second one
// fails. There is no shell tool for renamex_np(RENAME_SWAP), so the swap is not a single syscall; the gap between the
// renames is a few microseconds on the same volume and it is recoverable (the old bundle is only deleted after the
// new one is in place). The stage lives in the target's own directory so both renames stay on one volume.

/// What `Updater.install` does for a given target.
public enum InstallMode: Equatable, Sendable {
    /// The user can replace the bundle directly.
    case plain
    /// The folder or bundle isn't writable by the user: copy and swap as root after the admin prompt.
    case elevated
    /// Running from a read-only AppTranslocation copy: nothing can be replaced.
    case translocated
}

public enum ElevatedInstall {
    public static let adminNotice =
        "Snapframe is installed for all users in /Applications. macOS will ask for an administrator's name and password to replace it."

    /// The only place the root script will replace.
    public static let allowedTarget = "/Applications/Snapframe.app"

    /// Test-only switches for the privileged script. Production code never passes one.
    public struct TestHooks: Sendable {
        /// Skip `chown -R root:admin` (a normal user can't).
        public var skipChown = false
        /// Shell run on the staged copy after it is staged and before the signature re-check.
        public var beforeVerify: String?
        /// Replaces the hard-coded /Applications/Snapframe.app guard (tests work in a temp folder).
        public var allowedTarget: String?
        public init(skipChown: Bool = false, beforeVerify: String? = nil, allowedTarget: String? = nil) {
            self.skipChown = skipChown
            self.beforeVerify = beforeVerify
            self.allowedTarget = allowedTarget
        }
    }

    public static func installMode(translocated: Bool, parentWritable: Bool, targetWritable: Bool) -> InstallMode {
        if translocated { return .translocated }
        return parentWritable && targetWritable ? .plain : .elevated
    }

    /// Elevation is only ever offered for the shared copy, by its literal path and with no symlink in the way.
    public static func isAllowedTarget(_ target: URL) -> Bool {
        target.path == allowedTarget && target.resolvingSymlinksInPath().path == allowedTarget
    }

    /// Root-created private directory next to the target (mode 700); the staged app lives inside it as Snapframe.app.
    public static func privatePath(for target: URL, token: String) -> String {
        target.deletingLastPathComponent().appendingPathComponent(".Snapframe-update-\(token)").path
    }

    public static func oldPath(for target: URL, token: String) -> String {
        target.deletingLastPathComponent().appendingPathComponent(".Snapframe-old-\(token).app").path
    }

    /// The shell script (run as root) as one string. Every value is a single-quoted assignment; the body only uses
    /// the variables, always inside double quotes.
    ///
    /// Why a user process can't touch the staged copy: `mkdir -m 700` (as root) creates PRIV, which the user can't
    /// traverse, and everything inside is created by root's ditto. The user never owns, and never holds an open
    /// handle to, anything inside PRIV; the only user-owned things read are the source tree ($NEW, which must be a
    /// real directory, not a symlink), and those are copied, not used in place. Files the copy takes from a
    /// user-swapped $NEW are caught by the signature check on the root-owned copy.
    public static func script(newApp: String, priv: String, target: String, old: String, requirement: String,
                              bundleID: String, version: String, build: String, hooks: TestHooks? = nil) -> String {
        let q = HelperScript.shellQuote
        var lines = [
            "set -e",
            "NEW=\(q(newApp))",
            "PRIV=\(q(priv))",
            "TARGET=\(q(target))",
            "OLD=\(q(old))",
            "REQ=\(q(requirement))",
            "WANT_ID=\(q(bundleID))",
            "WANT_VERSION=\(q(version))",
            "WANT_BUILD=\(q(build))",
            "fail() { echo \"$1\" >&2; exit 1; }",
            // Only the shared copy, a real directory, and nothing already at the side paths.
            "[ \"$TARGET\" = \(q(hooks?.allowedTarget ?? allowedTarget)) ] && [ -d \"$TARGET\" ] && [ ! -L \"$TARGET\" ] || fail 'unexpected install location'",
            "[ ! -e \"$OLD\" ] || fail 'unexpected leftover file'",
            "[ -d \"$NEW\" ] && [ ! -L \"$NEW\" ] || fail 'the downloaded copy is not a plain folder'",
            // Fails if PRIV exists, so the trap below only ever removes what this run created.
            "/bin/mkdir -m 700 \"$PRIV\"",
            "trap '/bin/rm -rf \"$PRIV\"' EXIT",
            "STAGE=\"$PRIV/Snapframe.app\"",
            // a. Copy into the private directory: root-created, out of the user's reach.
            "/usr/bin/ditto \"$NEW\" \"$STAGE\"",
        ]
        // b. Standard ownership for /Applications apps.
        if hooks?.skipChown != true { lines.append("/usr/sbin/chown -R root:admin \"$STAGE\"") }
        lines.append("/bin/chmod -R go-w \"$STAGE\"")
        if let hook = hooks?.beforeVerify { lines.append(hook) }
        lines += [
            // c. Re-verify as root on the staged copy: signature against the running app's own requirement, then
            // the identity and version the user-side checks already saw; the installed copy must be genuine too.
            "/usr/bin/codesign --verify --deep --strict -R=\"$REQ\" \"$STAGE\" || fail 'the staged copy failed the signature check'",
            "PB=/usr/libexec/PlistBuddy",
            "[ \"$($PB -c 'Print :CFBundleIdentifier' \"$STAGE/Contents/Info.plist\")\" = \"$WANT_ID\" ] || fail 'the staged copy has the wrong bundle id'",
            "[ \"$($PB -c 'Print :CFBundleShortVersionString' \"$STAGE/Contents/Info.plist\")\" = \"$WANT_VERSION\" ] || fail 'the staged copy has the wrong version'",
            "[ \"$($PB -c 'Print :CFBundleVersion' \"$STAGE/Contents/Info.plist\")\" = \"$WANT_BUILD\" ] || fail 'the staged copy has the wrong build'",
            "/usr/bin/codesign --verify --deep --strict -R=\"$REQ\" \"$TARGET\" || fail 'the installed copy is not the genuine Snapframe'",
            // d. Swap: the old bundle is only deleted once the new one is in place; if the second rename fails the
            // old one goes back.
            "/bin/mv \"$TARGET\" \"$OLD\"",
            "if ! /bin/mv \"$STAGE\" \"$TARGET\"; then /bin/mv \"$OLD\" \"$TARGET\"; fail 'could not move the new copy into place'; fi",
            "/bin/rmdir \"$PRIV\" || true",
            "/bin/rm -rf \"$OLD\" || true",
        ]
        return lines.joined(separator: "\n")
    }

    /// Last few lines of an error message, short enough for an alert.
    public static func tail(_ message: String, lines: Int = 4, maxChars: Int = 500) -> String {
        let kept = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(lines).joined(separator: "\n")
        return kept.count > maxChars ? "…" + kept.suffix(maxChars) : kept
    }

    /// AppleScript error -128 is the user cancelling the password prompt.
    public static func mapError(number: Int?, message: String?) -> UpdateError {
        if number == -128 { return .cancelled }
        let t = tail(message ?? "")
        return .install(t.isEmpty ? "macOS didn't say why." : t)
    }

    /// Runs `script` with the system admin prompt. NSAppleScript belongs on the main thread; the prompt itself is
    /// shown by the system.
    public static func runWithAdminPrompt(_ command: String) -> UpdateError? {
        let run: () -> UpdateError? = {
            guard let s = NSAppleScript(source: HelperScript.appleScript(running: command)) else {
                return .install("the installer script couldn't be prepared")
            }
            var error: NSDictionary?
            s.executeAndReturnError(&error)
            guard let error else { return nil }
            return mapError(number: error[NSAppleScript.errorNumber] as? Int,
                            message: error[NSAppleScript.errorMessage] as? String)
        }
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }
}
