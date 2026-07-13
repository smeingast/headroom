import Foundation

// One-shot harness: runs UpdateChecker.installPhase (zip preflight, ditto
// extract, Developer ID + Gatekeeper verification, version cross-check,
// eligibility, rename-aside swap) against a release zip and a SCRATCH bundle,
// so the whole dangerous chain is exercisable without touching the installed
// app or relaunching anything. Point it at a copy of Headroom.app inside a
// scratch directory named "Applications" for the success path.
//
// Build: swiftc -o /tmp/update_probe Sources/UpdateChecker.swift tools/update_probe.swift
// Usage: update_probe <zip> <bundle-to-replace> <running-version> <tag>

@main
struct UpdateProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 5 else {
            print("usage: update_probe <zip> <bundle-to-replace> <running-version> <tag>")
            exit(2)
        }
        let zip = URL(fileURLWithPath: args[1])
        let bundle = URL(fileURLWithPath: args[2])
        let running = args[3]
        let tag = args[4]

        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("update-probe-\(ProcessInfo.processInfo.processIdentifier)")
        try! fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // installPhase deletes the staging dir when done, so hand it a copy of the zip.
        let stagedZip = staging.appendingPathComponent("Headroom.zip")
        try! fm.copyItem(at: zip, to: stagedZip)

        let release = UpdateLogic.Release(tagName: tag, htmlURL: "https://example.invalid", assets: [])
        do {
            let path = try UpdateChecker.installPhase(
                zipURL: stagedZip, stagingDir: staging,
                release: release, running: running, bundleURL: bundle)
            print("OK: installed at \(path)")
        } catch let e as UpdateChecker.InstallError {
            print("REFUSED: \(e.message)")
            exit(1)
        } catch {
            print("ERROR: \(error)")
            exit(1)
        }
    }
}
