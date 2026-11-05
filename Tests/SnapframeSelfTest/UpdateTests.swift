import Foundation
import Security
@testable import SnapframeCore

extension SelfTests {
    static let update: [TestCase] = [
        TestCase("update: version comparison") {
            try check(UpdateLogic.isNewer(version: "0.3.0", build: "1", thanVersion: "0.2.0", build: "9"))
            try check(UpdateLogic.isNewer(version: "0.10.0", build: "1", thanVersion: "0.9.9", build: "1"), "numeric, not lexical")
            try check(UpdateLogic.isNewer(version: "1.0", build: "1", thanVersion: "0.9.9", build: "1"))
            try check(!UpdateLogic.isNewer(version: "0.3", build: "5", thanVersion: "0.3.0", build: "5"), "missing component = 0")
            try check(UpdateLogic.isNewer(version: "0.3.0", build: "202610161900", thanVersion: "0.3.0", build: "202610161800"),
                      "same version, newer build")
            try check(!UpdateLogic.isNewer(version: "0.2.9", build: "999999999999", thanVersion: "0.3.0", build: "1"),
                      "older version never wins on build")
        },
        TestCase("update: sha256 of a file and relative archive URL") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-upd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let f = dir.appendingPathComponent("a.bin")
            try Data("abc".utf8).write(to: f)
            try checkEqual(try UpdateLogic.sha256Hex(of: f),
                           "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            let m = UpdateManifest(version: "0.3.0", build: "1", url: "Snapframe-0.3.0-1.zip", sha256: "x")
            let feed = URL(string: "https://host.example:4445/update.json")!
            try checkEqual(UpdateLogic.archiveURL(m, relativeTo: feed)?.absoluteString, "https://host.example:4445/Snapframe-0.3.0-1.zip")
        },
        TestCase("update: signature check accepts the same signer and rejects others") {
            // Uses the built app when present (scripts/build-app.sh); skipped otherwise.
            let app = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/Snapframe.app")
            guard FileManager.default.fileExists(atPath: app.path) else { print("      (skipped: no dist/Snapframe.app)"); return }
            var code: SecStaticCode?
            try check(SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess && code != nil)
            var dr: SecRequirement?
            try check(SecCodeCopyDesignatedRequirement(code!, [], &dr) == errSecSuccess && dr != nil)
            try check(UpdateLogic.signatureSatisfies(app, requirement: dr!), "own designated requirement")
            var other: SecRequirement?
            try check(SecRequirementCreateWithString("identifier \"com.example.other\"" as CFString, [], &other) == errSecSuccess)
            try check(!UpdateLogic.signatureSatisfies(app, requirement: other!), "different identifier must fail")
            var otherCert: SecRequirement?
            let req = "identifier \"com.dwlt.snapframe\" and certificate leaf = H\"0000000000000000000000000000000000000000\""
            try check(SecRequirementCreateWithString(req as CFString, [], &otherCert) == errSecSuccess)
            try check(!UpdateLogic.signatureSatisfies(app, requirement: otherCert!), "different certificate must fail")
            // A tampered copy (resource changed after signing) must fail strict validation.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-upd-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let copy = dir.appendingPathComponent("Snapframe.app")
            try FileManager.default.copyItem(at: app, to: copy)
            try Data("tampered".utf8).write(to: copy.appendingPathComponent("Contents/Resources/AppIcon.icns"))
            try check(!UpdateLogic.signatureSatisfies(copy, requirement: dr!), "tampered bundle must fail")
        },
        TestCase("update: shell and AppleScript quoting survives spaces, apostrophes and backslashes") {
            let nasty = ["/Applications/Snapframe's App.app", #"/tmp/a b\c"#, "/tmp/$HOME `x` \"q\"", "plain",
                          // Combining marks fuse with the quote into one Character; they must still be escaped.
                          "it'\u{301}s", "\"\u{301}", "x'\u{301}; id #", "\\\u{301}x"]
            for path in nasty {
                // Shell: the quoted form must come back byte for byte.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "printf %s " + HelperScript.shellQuote(path)]
                let out = Pipe()
                p.standardOutput = out
                try p.run()
                p.waitUntilExit()
                try checkEqual(String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), path)
            }
            // AppleScript layer: the whole command goes through `do shell script` (without admin here) and
            // prints its arguments back.
            let source = HelperScript.appleScript(running: "printf '%s|' " + nasty.map(HelperScript.shellQuote).joined(separator: " "), admin: false)
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            try check(error == nil, "\(String(describing: error))")
            try checkEqual(result?.stringValue, nasty.map { $0 + "|" }.joined())
            // CRLF is one Character; both scalars must be escaped, with no raw line break left in the literal.
            try checkEqual(HelperScript.appleScript(running: "a\r\nb", admin: false), "do shell script \"a\\r\\nb\"")
            try checkEqual(HelperScript.appleScript(running: "\"\u{301}", admin: false), "do shell script \"\\\"\u{301}\"")
            try checkEqual(HelperScript.shellQuote("'\u{301}"), "''\\''\u{301}'")
            try check(HelperScript.appleScript(running: "x").hasSuffix(" with administrator privileges"))
            try check(!HelperScript.appleScript(running: "x", admin: false).contains("administrator"))
        },
        TestCase("update: elevated script quotes paths and requirement") {
            let nasty = "/tmp/My Apps/it's \"x\" $HOME `id`/Snapframe.app"
            let req = "identifier \"com.dwlt.snapframe\" and certificate leaf = H\"ab\""
            let script = ElevatedInstall.script(newApp: nasty, priv: nasty + "-s", target: nasty + "-t", old: nasty + "-o",
                                                requirement: req, bundleID: "com.dwlt.snapframe", version: "1", build: "2")
            try check(script.hasPrefix("set -e\n"))
            try check(script.contains("NEW=" + HelperScript.shellQuote(nasty)), "path assigned through the quoting helper")
            try check(script.contains("REQ=" + HelperScript.shellQuote(req)), "requirement quoted")
            // The shell must read back exactly the original strings (no expansion, no splitting).
            let probe = script.components(separatedBy: "\n").prefix { !$0.hasPrefix("fail()") }.joined(separator: "\n")
                + "\nprintf '%s\\n%s\\n%s' \"$NEW\" \"$REQ\" \"$PRIV\""
            let (out, _, rc) = try runShell(probe)
            try checkEqual(rc, 0)
            try checkEqual(out, [nasty, req, nasty + "-s"].joined(separator: "\n"))
            // Nothing user-controlled outside the quoted assignments.
            for line in script.components(separatedBy: "\n") where !line.contains("=") || line.contains("\"$") {
                try check(!line.contains("it's") && !line.contains("My Apps"), "unquoted path in: \(line)")
            }
        },
        TestCase("update: install mode decision, paths, error mapping and messages") {
            try checkEqual(ElevatedInstall.installMode(translocated: false, parentWritable: true, targetWritable: true), .plain)
            try checkEqual(ElevatedInstall.installMode(translocated: false, parentWritable: false, targetWritable: true), .elevated)
            try checkEqual(ElevatedInstall.installMode(translocated: false, parentWritable: true, targetWritable: false), .elevated)
            try checkEqual(ElevatedInstall.installMode(translocated: true, parentWritable: false, targetWritable: false), .translocated)
            let target = URL(fileURLWithPath: "/Applications/Snapframe.app")
            try checkEqual(ElevatedInstall.privatePath(for: target, token: "T"), "/Applications/.Snapframe-update-T")
            try check(ElevatedInstall.isAllowedTarget(target))
            for other in ["/tmp/Snapframe.app", "/Applications/Sub/Snapframe.app", "/Users/x/Applications/Snapframe.app",
                          "/Applications/Snapframe.app/../Snapframe.app"] {
                try check(!ElevatedInstall.isAllowedTarget(URL(fileURLWithPath: other)), "\(other) must not elevate")
            }
            // A symlinked parent that resolves elsewhere is refused even though the literal path matches.
            try check(!ElevatedInstall.isAllowedTarget(URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Applications/Snapframe.app")))
            try checkEqual(ElevatedInstall.oldPath(for: target, token: "T"), "/Applications/.Snapframe-old-T.app")
            try checkEqual(ElevatedInstall.mapError(number: -128, message: "User canceled."), .cancelled)
            try checkEqual(ElevatedInstall.mapError(number: 1, message: "a\nb\nc\nd\ne\nf"), .install("c\nd\ne\nf"))
            try checkEqual(ElevatedInstall.mapError(number: 1, message: nil), .install("macOS didn't say why."))
            try checkEqual(UpdateError.cancelled.description, "Update cancelled.")
            try checkEqual(UpdateError.translocated.description,
                           "Move Snapframe out of Downloads into Applications first, then try again.")
            try check(UpdateError.notWritable("/Applications/Snapframe.app").description.contains("needs administrator rights"))
            try check(!UpdateError.notWritable("/x").description.contains("Move it to the Applications folder"))
            try checkEqual(ElevatedInstall.adminNotice,
                           "Snapframe is installed for all users in /Applications. macOS will ask for an administrator's name and password to replace it.")
        },
        TestCase("update: privileged script stages, re-verifies and swaps (run unprivileged on a temp Applications)") {
            guard let fx = try ElevatedFixture() else { print("      (skipped: no dist/Snapframe.app)"); return }
            defer { fx.cleanup() }
            let hooks = fx.hooks()
            let before = try fx.targetID()
            let (_, err, rc) = try runShell(fx.script(hooks: hooks))
            try check(rc == 0, "script failed: \(err)")
            try check(try fx.targetID() != before, "the installed bundle was replaced")
            try check(UpdateLogic.signatureSatisfies(fx.target, requirement: fx.requirement), "installed copy satisfies the requirement")
            try checkEqual(Bundle(url: fx.target)?.infoDictionary?["CFBundleShortVersionString"] as? String, fx.version)
            try checkEqual(try fx.leftovers(), [])
            // go-w applied
            let mode = (try FileManager.default.attributesOfItem(atPath: fx.target.path)[.posixPermissions] as? Int ?? 0) & 0o022
            try checkEqual(mode, 0)
        },
        TestCase("update: privileged script refuses a tampered, wrong-signer or wrong-version stage and keeps the original") {
            guard let fx = try ElevatedFixture() else { print("      (skipped: no dist/Snapframe.app)"); return }
            defer { fx.cleanup() }
            let before = try fx.targetID()
            func expectRefused(_ label: String, _ command: String) throws {
                let (_, err, rc) = try runShell(command)
                try check(rc != 0, "\(label): should fail")
                try check(try fx.targetID() == before, "\(label): original must be intact")
                try check(try fx.leftovers().isEmpty, "\(label): stage/old removed (\(err))")
            }
            try expectRefused("tampered", fx.script(hooks: .init(
                skipChown: true, beforeVerify: "echo tampered > \"$STAGE/Contents/Resources/AppIcon.icns\"",
                allowedTarget: fx.target.path)))
            try expectRefused("wrong signer", fx.script(requirement: "identifier \"com.example.other\"",
                                                        hooks: fx.hooks()))
            try expectRefused("wrong version", fx.script(version: "99.0.0", hooks: fx.hooks()))
            try expectRefused("wrong bundle id", fx.script(bundleID: "com.example.other", hooks: fx.hooks()))
            // The guard compares TARGET with the allowed path; anything else is refused before anything is touched.
            try expectRefused("other target", fx.script(target: fx.apps.appendingPathComponent("Other.app").path,
                                                        hooks: fx.hooks()))
            try expectRefused("default guard (/Applications/Snapframe.app)", fx.script(hooks: .init(skipChown: true)))
            // A symlink at TARGET is refused.
            let link = fx.root.appendingPathComponent("Link.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.target)
            try expectRefused("symlinked target", fx.script(target: link.path, hooks: .init(skipChown: true, allowedTarget: link.path)))
            try FileManager.default.removeItem(at: link)
            // A tampered installed copy (not genuinely signed) is not moved aside.
            try Data("x".utf8).write(to: fx.target.appendingPathComponent("Contents/Resources/extra.txt"))
            try expectRefused("unsigned target", fx.script(hooks: fx.hooks()))
        },
    ]
}

private func runShell(_ command: String) throws -> (out: String, err: String, rc: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    try p.run()
    let out = o.fileHandleForReading.readDataToEndOfFile(), err = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), p.terminationStatus)
}

/// A temp "Applications" folder with an old app to replace, plus the signed built app as the verified download.
private struct ElevatedFixture {
    let root: URL, apps: URL, newApp: URL, target: URL
    let requirement: SecRequirement, requirementString: String, version: String, build: String, bundleID: String

    init?() throws {
        let built = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/Snapframe.app")
        guard FileManager.default.fileExists(atPath: built.path) else { return nil }
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("sf-elev-\(UUID().uuidString)")
        apps = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        newApp = root.appendingPathComponent("download/Snapframe.app")
        try fm.createDirectory(at: newApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: built, to: newApp)
        target = apps.appendingPathComponent("Snapframe.app")
        try fm.copyItem(at: built, to: target)
        var code: SecStaticCode?, dr: SecRequirement?, str: CFString?
        guard SecStaticCodeCreateWithPath(built as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &dr) == errSecSuccess, let dr,
              SecRequirementCopyString(dr, [], &str) == errSecSuccess, let str else {
            throw CheckFailure(description: "can't read the built app's requirement")
        }
        requirement = dr
        requirementString = str as String
        let info = Bundle(url: built)?.infoDictionary
        version = info?["CFBundleShortVersionString"] as? String ?? ""
        build = info?["CFBundleVersion"] as? String ?? ""
        bundleID = info?["CFBundleIdentifier"] as? String ?? ""
    }

    /// Identity of the installed directory (a replaced bundle has a different inode).
    func targetID() throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? Int) ?? -1
    }

    func script(target override: String? = nil, requirement: String? = nil, version: String? = nil, bundleID: String? = nil,
                hooks: ElevatedInstall.TestHooks) -> String {
        let token = UUID().uuidString
        return ElevatedInstall.script(
            newApp: newApp.path, priv: ElevatedInstall.privatePath(for: target, token: token), target: override ?? target.path,
            old: ElevatedInstall.oldPath(for: target, token: token), requirement: requirement ?? requirementString,
            bundleID: bundleID ?? self.bundleID, version: version ?? self.version, build: build, hooks: hooks)
    }

    /// Anything besides Snapframe.app left in the Applications folder.
    func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: apps.path).filter { $0 != "Snapframe.app" }
    }

    func hooks() -> ElevatedInstall.TestHooks { .init(skipChown: true, allowedTarget: target.path) }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
