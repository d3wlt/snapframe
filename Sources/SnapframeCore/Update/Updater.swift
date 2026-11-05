import CryptoKit
import Foundation
import Security
import Synchronization

// One-click updates from a self-hosted feed (`update.json` + versioned zips). The feed URL comes from the app's
// Info.plist key `SnapframeUpdateURL`, filled at build time, so it never lives in the source; builds without it
// have no updater. A download is installed only if its SHA-256 matches the manifest AND its code signature
// satisfies the running app's designated requirement (same bundle id + same signing certificate). An ad-hoc signed
// copy has a cdhash-only requirement that no other build can satisfy, so it refuses to self-update by design.

public struct UpdateManifest: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    /// Zip location, relative to the manifest URL (or absolute).
    public var url: String
    public var sha256: String
    public var notes: String?

    public init(version: String, build: String, url: String, sha256: String, notes: String? = nil) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.notes = notes
    }
}

public enum UpdateError: Error, Equatable, CustomStringConvertible {
    case notConfigured
    case network(String)
    case badManifest
    case checksumMismatch
    case badArchive
    case signatureMismatch
    case versionMismatch
    case notWritable(String)
    case translocated
    case cancelled
    case install(String)

    public var description: String {
        switch self {
        case .notConfigured: "Updates aren't set up in this build."
        case .network(let s): "Couldn't reach the update server (\(s)). Check your network connection."
        case .badManifest: "The update information couldn't be read."
        case .checksumMismatch: "The download was damaged (checksum mismatch). Nothing was changed."
        case .badArchive: "The download doesn't contain Snapframe. Nothing was changed."
        case .signatureMismatch:
            "The update isn't signed like this copy of Snapframe, so it wasn't installed. Install it manually once."
        case .versionMismatch: "The download's version doesn't match the update information. Nothing was changed."
        case .notWritable(let p): "Snapframe can't replace itself at \(p). The folder needs administrator rights."
        case .translocated: "Move Snapframe out of Downloads into Applications first, then try again."
        case .cancelled: "Update cancelled."
        case .install(let s): "Installing the update failed: \(s)"
        }
    }
}

public enum UpdateLogic {
    /// Dotted numeric versions ("0.10.1" > "0.9.3"); a missing component counts as 0. Equal versions compare builds
    /// (numeric strings like "202610161900").
    public static func isNewer(version: String, build: String, thanVersion local: String, build localBuild: String) -> Bool {
        let a = components(version), b = components(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return (Int(build) ?? 0) > (Int(localBuild) ?? 0)
    }

    static func components(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The zip URL for a manifest fetched from `manifestURL`.
    public static func archiveURL(_ manifest: UpdateManifest, relativeTo manifestURL: URL) -> URL? {
        URL(string: manifest.url, relativeTo: manifestURL)?.absoluteURL
    }

    /// True when the code at `candidate` is validly signed and satisfies `requirement` (all architectures, strict).
    public static func signatureSatisfies(_ candidate: URL, requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The running app's designated requirement.
    public static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var staticMe: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess else { return nil }
        return req
    }
}

/// Checks the feed and installs updates. All network and file work runs on a private queue; completions run on main.
public final class Updater: @unchecked Sendable {
    public let manifestURL: URL?
    public let currentVersion: String
    public let currentBuild: String
    private let queue = DispatchQueue(label: "com.dwlt.snapframe.updater", qos: .utility)
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 300
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    public init(bundle: Bundle = .main) {
        let raw = (bundle.object(forInfoDictionaryKey: "SnapframeUpdateURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        manifestURL = raw.hasPrefix("https://") ? URL(string: raw) : nil
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    public var isConfigured: Bool { manifestURL != nil }

    /// True when replacing this copy needs the administrator prompt.
    public var needsAdministrator: Bool {
        let target = Bundle.main.bundleURL
        return ElevatedInstall.installMode(
            translocated: target.path.contains("/AppTranslocation/"),
            parentWritable: FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
            targetWritable: FileManager.default.isWritableFile(atPath: target.path)) == .elevated
    }

    /// nil manifest = up to date.
    public func check(completion: @escaping @MainActor @Sendable (Result<UpdateManifest?, UpdateError>) -> Void) {
        guard let manifestURL else { return DispatchQueue.main.async { completion(.failure(.notConfigured)) } }
        queue.async { [self] in
            let result: Result<UpdateManifest?, UpdateError> = Result {
                let data = try fetch(manifestURL)
                guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { throw UpdateError.badManifest }
                return UpdateLogic.isNewer(version: m.version, build: m.build, thanVersion: currentVersion,
                                           build: currentBuild) ? m : nil
            }.mapError { $0 as? UpdateError ?? .network($0.localizedDescription) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Downloads, verifies and swaps in the new app. On success the caller relaunches (`relaunch()`).
    /// `allowElevation: false` (headless) fails with `.notWritable` instead of asking for an administrator.
    public func install(_ manifest: UpdateManifest, allowElevation: Bool = true,
                        elevatedRunner: (@Sendable (String) -> UpdateError?)? = nil,
                        completion: @escaping @MainActor @Sendable (Result<Void, UpdateError>) -> Void) {
        guard let manifestURL, let zipURL = UpdateLogic.archiveURL(manifest, relativeTo: manifestURL) else {
            return DispatchQueue.main.async { completion(.failure(.notConfigured)) }
        }
        let target = Bundle.main.bundleURL
        queue.async { [self] in
            let result: Result<Void, UpdateError> = Result {
                guard let requirement = UpdateLogic.ownRequirement() else { throw UpdateError.signatureMismatch }
                // Launched straight from Downloads, macOS runs a read-only translocated copy.
                let parent = target.deletingLastPathComponent()
                let mode = ElevatedInstall.installMode(
                    translocated: target.path.contains("/AppTranslocation/"),
                    parentWritable: FileManager.default.isWritableFile(atPath: parent.path),
                    targetWritable: FileManager.default.isWritableFile(atPath: target.path))
                if mode == .translocated { throw UpdateError.translocated }
                if mode == .elevated && !(allowElevation && ElevatedInstall.isAllowedTarget(target)) {
                    throw UpdateError.notWritable(target.path)
                }
                // A fresh, private work directory on the app's own volume (so the final swap is atomic); removed
                // afterwards.
                let work: URL
                if let w = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                        appropriateFor: target, create: true) {
                    work = w
                } else if mode == .elevated {  // the folder isn't ours: any private temp directory will do
                    work = FileManager.default.temporaryDirectory.appendingPathComponent("snapframe-update-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                } else {
                    throw UpdateError.install("couldn't create a work folder next to the app")
                }
                defer { try? FileManager.default.removeItem(at: work) }

                let zip = work.appendingPathComponent("Snapframe.zip")
                try fetch(zipURL).write(to: zip)
                guard try UpdateLogic.sha256Hex(of: zip) == manifest.sha256.lowercased() else { throw UpdateError.checksumMismatch }

                let unpacked = work.appendingPathComponent("unpacked")
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) else { throw UpdateError.badArchive }
                let newApp = unpacked.appendingPathComponent("Snapframe.app")
                guard let info = Bundle(url: newApp)?.infoDictionary,
                      info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw UpdateError.badArchive }
                guard info["CFBundleShortVersionString"] as? String == manifest.version,
                      info["CFBundleVersion"] as? String == manifest.build else { throw UpdateError.versionMismatch }
                guard UpdateLogic.signatureSatisfies(newApp, requirement: requirement) else { throw UpdateError.signatureMismatch }

                if mode == .elevated {
                    // Copy, re-verify and swap as root in one admin prompt (see ElevatedInstall).
                    var reqString: CFString?
                    guard SecRequirementCopyString(requirement, [], &reqString) == errSecSuccess, let reqString else {
                        throw UpdateError.install("this copy of Snapframe couldn't read its own signature")
                    }
                    let token = UUID().uuidString
                    let command = ElevatedInstall.script(
                        newApp: newApp.path, priv: ElevatedInstall.privatePath(for: target, token: token),
                        target: target.path, old: ElevatedInstall.oldPath(for: target, token: token),
                        requirement: reqString as String, bundleID: Bundle.main.bundleIdentifier ?? "",
                        version: manifest.version, build: manifest.build)
                    if let failure = (elevatedRunner ?? ElevatedInstall.runWithAdminPrompt)(command) { throw failure }
                    return
                }

                // Atomic swap in place (same volume); the old bundle is removed. The running process keeps its
                // mapped code until it relaunches.
                do {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp, backupItemName: nil,
                                                              options: [.usingNewMetadataOnly])
                } catch {
                    throw UpdateError.install(error.localizedDescription)
                }
            }.mapError { $0 as? UpdateError ?? .install($0.localizedDescription) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Starts the (new) app once this process has exited, then the caller terminates.
    public func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? p.run()
    }

    private func fetch(_ url: URL) throws -> Data {
        let out = Mutex<Result<Data, Error>>(.failure(UpdateError.network("no response")))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, error in
            if let error { out.withLock { $0 = .failure(UpdateError.network(error.localizedDescription)) } }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                out.withLock { $0 = .failure(UpdateError.network("HTTP \(http.statusCode)")) }
            } else if let data { out.withLock { $0 = .success(data) } }
            done.signal()
        }.resume()
        done.wait()
        return try out.withLock { $0 }.get()
    }

    private func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
