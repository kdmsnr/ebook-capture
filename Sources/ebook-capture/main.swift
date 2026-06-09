import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI
import Foundation

enum CaptureError: Error, CustomStringConvertible {
    case usage(String)
    case processFailed(command: String, status: Int32, stderr: String)
    case permissionMissing(String)
    case applicationNotFound(String)
    case windowNotFound(String)
    case invalidKey(String)
    case cancelled
    case captureFailed(String)
    case eventCreationFailed

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .processFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(command) failed with exit status \(status)."
            }
            return "\(command) failed with exit status \(status): \(detail)"
        case .permissionMissing(let message):
            return message
        case .applicationNotFound(let name):
            return "Could not find or launch \(name). Open the target application once, then try again."
        case .windowNotFound(let message):
            return message
        case .invalidKey(let key):
            return "Unsupported key '\(key)'. Use one of: right, left, page-down, page-up, space."
        case .cancelled:
            return "Capture cancelled."
        case .captureFailed(let path):
            return "Screenshot was not written: \(path)"
        case .eventCreationFailed:
            return "Could not create a keyboard event."
        }
    }
}

enum PageTurnKey: String, CaseIterable {
    case right
    case left
    case pageDown = "page-down"
    case pageUp = "page-up"
    case space

    init(argument: String) throws {
        switch argument.lowercased() {
        case "right", "arrow-right", "right-arrow":
            self = .right
        case "left", "arrow-left", "left-arrow":
            self = .left
        case "page-down", "pagedown", "page_down":
            self = .pageDown
        case "page-up", "pageup", "page_up":
            self = .pageUp
        case "space":
            self = .space
        default:
            throw CaptureError.invalidKey(argument)
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .right:
            return 124
        case .left:
            return 123
        case .pageDown:
            return 121
        case .pageUp:
            return 116
        case .space:
            return 49
        }
    }

    var displayName: String {
        switch self {
        case .right:
            return "Right"
        case .left:
            return "Left"
        case .pageDown:
            return "Page Down"
        case .pageUp:
            return "Page Up"
        case .space:
            return "Space"
        }
    }
}

struct CaptureConfig {
    var appName: String? = "Kindle.app"
    var bundleIdentifier: String?
    var count = 10
    var captureUntilEnd = false
    var outputDirectory = URL(fileURLWithPath: "captures")
    var pageDelay = 0.8
    var selfTimer = 0.0
    var countdownSound = defaultCountdownSoundName()
    var key = PageTurnKey.pageDown
    var prefix = "page"
    var windowTitle: String?
    var dryRun = false
    var listWindows = false
}

struct WindowInfo {
    let id: CGWindowID
    let title: String
    let ownerName: String
    let bounds: CGRect

    var area: CGFloat {
        bounds.width * bounds.height
    }
}

struct PermissionState {
    let accessibility: Bool
    let screenCapture: Bool
}

func usage() -> String {
    """
    Usage:
      ebook-capture [options]

    Options:
      -n, --count <number>          Number of pages to capture. Default: 10
          --until-end               Capture until the page stops changing. Uses --count as a safety limit.
      -o, --output-dir <directory>  Directory for captured images. Default: captures
          --delay <seconds>         Delay after each page turn. Default: 0.8
          --self-timer <seconds>    Camera-style countdown before first capture. Default: 0
          --key <key>               Page-turn key: right, left, page-down, page-up, space. Default: page-down
          --app-name <name>         macOS application name. Default: Kindle.app
          --bundle-id <id>          Optional application bundle identifier.
          --window-title <text>     Select a window whose title contains this text.
          --prefix <text>           Screenshot filename prefix. Default: page
          --list-windows            List visible target windows without capturing.
      -h, --help                    Show this help.

    Example:
      ebook-capture --count 30 --output-dir ./captures --delay 1.0
    """
}

func parseArguments(_ arguments: [String]) throws -> CaptureConfig {
    var config = CaptureConfig()
    var index = 0

    func requireValue(for option: String) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw CaptureError.usage("Missing value for \(option).\n\n\(usage())")
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "-h", "--help":
            throw CaptureError.usage(usage())
        case "-n", "--count":
            let rawValue = try requireValue(for: argument)
            guard let value = Int(rawValue), value > 0 else {
                throw CaptureError.usage("--count must be a positive integer.")
            }
            config.count = value
        case "--until-end":
            config.captureUntilEnd = true
        case "-o", "--output-dir", "--out":
            config.outputDirectory = URL(fileURLWithPath: try requireValue(for: argument))
        case "--delay":
            let rawValue = try requireValue(for: argument)
            guard let value = Double(rawValue), value >= 0 else {
                throw CaptureError.usage("--delay must be zero or greater.")
            }
            config.pageDelay = value
        case "--self-timer", "--timer":
            let rawValue = try requireValue(for: argument)
            guard let value = Double(rawValue), value >= 0 else {
                throw CaptureError.usage("--self-timer must be zero or greater.")
            }
            config.selfTimer = value
        case "--countdown-sound":
            config.countdownSound = try requireValue(for: argument)
        case "--key":
            config.key = try PageTurnKey(argument: try requireValue(for: argument))
        case "--app-name":
            let value = try requireValue(for: argument)
            config.appName = value.isEmpty ? nil : value
        case "--bundle-id":
            let value = try requireValue(for: argument)
            config.bundleIdentifier = value.isEmpty ? nil : value
        case "--window-title":
            let value = try requireValue(for: argument)
            config.windowTitle = value.isEmpty ? nil : value
        case "--prefix":
            config.prefix = try requireValue(for: argument)
        case "--dry-run":
            config.dryRun = true
        case "--list-windows":
            config.listWindows = true
        default:
            throw CaptureError.usage("Unknown option: \(argument)\n\n\(usage())")
        }

        index += 1
    }

    return config
}

@discardableResult
func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""
    let error = String(data: errorData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw CaptureError.processFailed(
            command: ([executable] + arguments).joined(separator: " "),
            status: process.terminationStatus,
            stderr: error
        )
    }

    return output
}

func permissionState(prompt: Bool) -> PermissionState {
    let promptKey = "AXTrustedCheckOptionPrompt"
    let accessibilityOptions = [promptKey: prompt] as CFDictionary
    let accessibility = AXIsProcessTrustedWithOptions(accessibilityOptions)

    let screenCapture: Bool
    if #available(macOS 10.15, *) {
        if CGPreflightScreenCaptureAccess() {
            screenCapture = true
        } else if prompt {
            screenCapture = CGRequestScreenCaptureAccess()
        } else {
            screenCapture = false
        }
    } else {
        screenCapture = true
    }

    return PermissionState(accessibility: accessibility, screenCapture: screenCapture)
}

func shouldPromptForPermissions() -> Bool {
    ProcessInfo.processInfo.environment["EBOOK_CAPTURE_SUPPRESS_PERMISSION_PROMPT"] != "1"
}

func validatePermissions(_ config: CaptureConfig) throws {
    guard !config.dryRun, !config.listWindows else {
        return
    }

    let permissions = permissionState(prompt: shouldPromptForPermissions())
    if !permissions.accessibility {
        throw CaptureError.permissionMissing(
            """
            Accessibility permission is required to send page-turn keys.
            Open System Settings > Privacy & Security > Accessibility, add or enable Ebook Capture.app, then quit and reopen Ebook Capture.
            """
        )
    }

    if !permissions.screenCapture {
        throw CaptureError.permissionMissing(
            """
            Screen Recording permission is required to capture the target window.
            Open System Settings > Privacy & Security > Screen & System Audio Recording, add or enable Ebook Capture.app, then quit and reopen Ebook Capture.
            """
        )
    }
}

func targetApplicationDescription(_ config: CaptureConfig) -> String {
    if let appName = config.appName {
        return appName
    }

    if let bundleIdentifier = config.bundleIdentifier {
        return bundleIdentifier
    }

    return "target application"
}

func applicationNameCandidates(_ appName: String) -> [String] {
    let trimmedName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName.lowercased().hasSuffix(".app") else {
        return [trimmedName]
    }

    let nameWithoutSuffix = String(trimmedName.dropLast(4))
    return [trimmedName, nameWithoutSuffix]
}

func findRunningApplication(_ config: CaptureConfig) -> NSRunningApplication? {
    if let bundleIdentifier = config.bundleIdentifier {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app = matches.first(where: { !$0.isTerminated }) {
            return app
        }
    }

    guard let appName = config.appName else {
        return nil
    }

    let exactNames = applicationNameCandidates(appName).map { $0.lowercased() }

    return NSWorkspace.shared.runningApplications.first { app in
        guard !app.isTerminated, let name = app.localizedName?.lowercased() else {
            return false
        }
        return exactNames.contains { exactName in
            name == exactName || name.contains(exactName) || exactName.contains(name)
        }
    }
}

func launchApplication(_ config: CaptureConfig) throws {
    if let bundleIdentifier = config.bundleIdentifier {
        do {
            try runProcess("/usr/bin/open", ["-b", bundleIdentifier])
            return
        } catch {
            guard let appName = config.appName else {
                throw error
            }
            print("Could not launch bundle identifier \(bundleIdentifier); trying app name \(appName).")
        }
    }

    guard let appName = config.appName else {
        throw CaptureError.usage("Specify --app-name or --bundle-id.\n\n\(usage())")
    }

    var latestError: Error?
    for candidate in applicationNameCandidates(appName) {
        do {
            try runProcess("/usr/bin/open", ["-a", candidate])
            return
        } catch {
            latestError = error
        }
    }

    if let latestError {
        throw latestError
    }

    throw CaptureError.applicationNotFound(appName)
}

func activateApplication(_ config: CaptureConfig) throws -> NSRunningApplication {
    if let running = findRunningApplication(config) {
        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return running
    }

    try launchApplication(config)

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let running = findRunningApplication(config) {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return running
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    throw CaptureError.applicationNotFound(targetApplicationDescription(config))
}

func targetWindows(for processIdentifier: pid_t, matchingTitle titleFilter: String?) -> [WindowInfo] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        return []
    }

    return windowList.compactMap { dictionary in
        guard
            let ownerPID = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
            ownerPID == processIdentifier,
            let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
            layer == 0,
            let windowNumber = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
            let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
        else {
            return nil
        }

        guard bounds.width >= 100, bounds.height >= 100 else {
            return nil
        }

        let title = dictionary[kCGWindowName as String] as? String ?? ""
        if let titleFilter, !title.localizedCaseInsensitiveContains(titleFilter) {
            return nil
        }

        let ownerName = dictionary[kCGWindowOwnerName as String] as? String ?? ""
        return WindowInfo(
            id: CGWindowID(windowNumber),
            title: title,
            ownerName: ownerName,
            bounds: bounds
        )
    }
    .sorted { $0.area > $1.area }
}

func selectedTargetWindow(for app: NSRunningApplication, config: CaptureConfig) throws -> WindowInfo {
    let windows = targetWindows(for: app.processIdentifier, matchingTitle: config.windowTitle)
    guard let window = windows.first else {
        var message = "Could not find an on-screen \(targetApplicationDescription(config)) window."
        if let title = config.windowTitle {
            message += " No visible window title contained '\(title)'."
        }
        message += " Make sure the target window is open and not minimized."
        throw CaptureError.windowNotFound(message)
    }
    return window
}

func waitForReadyTargetWindow(
    for app: NSRunningApplication,
    config: CaptureConfig,
    timeout: TimeInterval = 10
) throws -> WindowInfo {
    let deadline = Date().addingTimeInterval(timeout)
    var latestWindowError: CaptureError?

    while Date() < deadline {
        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        if !isFrontmost {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        do {
            let window = try selectedTargetWindow(for: app, config: config)
            return window
        } catch let error as CaptureError {
            latestWindowError = error
        }

        Thread.sleep(forTimeInterval: 0.2)
    }

    if let latestWindowError {
        throw latestWindowError
    }

    throw CaptureError.windowNotFound("Could not find a visible target window for \(targetApplicationDescription(config)).")
}

func requestApplicationActivation(_ app: NSRunningApplication) {
    let deadline = Date().addingTimeInterval(3)

    while Date() < deadline {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return
        }

        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func captureWindow(_ window: WindowInfo, to destination: URL, dryRun: Bool) throws {
    if dryRun {
        print("dry-run: capture window \(window.id) -> \(destination.path)")
        return
    }

    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    try runProcess("/usr/sbin/screencapture", [
        "-x",
        "-l",
        String(window.id),
        destination.path
    ])

    guard FileManager.default.fileExists(atPath: destination.path) else {
        throw CaptureError.captureFailed(destination.path)
    }
}

func sendPageTurn(_ key: PageTurnKey, to processIdentifier: pid_t, dryRun: Bool) throws {
    if dryRun {
        print("dry-run: send key \(key.rawValue) to process \(processIdentifier)")
        return
    }

    guard
        let source = CGEventSource(stateID: .hidSystemState),
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: true),
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: false)
    else {
        throw CaptureError.eventCreationFailed
    }

    keyDown.postToPid(processIdentifier)
    usleep(80_000)
    keyUp.postToPid(processIdentifier)
}

func filename(prefix: String, index: Int) -> String {
    "\(prefix)-\(String(format: "%04d", index)).png"
}

let noCountdownSoundName = "None"

let preferredCountdownSoundNames = [
    "Pop",
    "Glass",
    "Ping",
    "Bottle",
    "Tink",
    "Hero",
    "Sosumi",
    "Purr",
    "Blow",
    "Morse",
    "Funk",
    "Basso",
    "Submarine",
    "Frog"
]

func availableCountdownSoundNames() -> [String] {
    let soundDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    let discoveredNames = (try? FileManager.default.contentsOfDirectory(
        at: soundDirectory,
        includingPropertiesForKeys: nil
    ))?
        .filter { $0.pathExtension.caseInsensitiveCompare("aiff") == .orderedSame }
        .map { $0.deletingPathExtension().lastPathComponent } ?? []

    let discoveredSet = Set(discoveredNames)
    let preferredNames = preferredCountdownSoundNames.filter { discoveredSet.contains($0) }
    let extraNames = discoveredSet.subtracting(preferredNames).sorted()
    return [noCountdownSoundName] + preferredNames + extraNames
}

func defaultCountdownSoundName() -> String {
    noCountdownSoundName
}

func normalizedCountdownSoundName(_ soundName: String) -> String {
    soundName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ".aiff", with: "", options: [.caseInsensitive])
}

func isNoCountdownSoundName(_ soundName: String) -> Bool {
    let normalizedName = normalizedCountdownSoundName(soundName).lowercased()
    return normalizedName.isEmpty || ["none", "off", "silent", "mute", "muted"].contains(normalizedName)
}

func countdownSoundPath(named soundName: String) -> String? {
    let trimmedName = normalizedCountdownSoundName(soundName)

    guard !isNoCountdownSoundName(trimmedName) else {
        return nil
    }

    let names = availableCountdownSoundNames()
    let resolvedName = names.first { $0.caseInsensitiveCompare(trimmedName) == .orderedSame } ?? trimmedName
    let soundPath = "/System/Library/Sounds/\(resolvedName).aiff"
    guard FileManager.default.fileExists(atPath: soundPath) else {
        return nil
    }

    return soundPath
}

func playCountdownSound(named soundName: String) {
    guard let soundPath = countdownSoundPath(named: soundName) else {
        return
    }
    _ = try? runProcess("/usr/bin/afplay", [soundPath])
}

struct ImageFingerprint {
    let samples: [UInt8]

    func normalizedMeanDifference(from other: ImageFingerprint) -> Double {
        guard samples.count == other.samples.count else {
            return .greatestFiniteMagnitude
        }

        let totalDifference = zip(samples, other.samples).reduce(0) { partialResult, pair in
            partialResult + abs(Int(pair.0) - Int(pair.1))
        }

        return Double(totalDifference) / Double(samples.count * 255)
    }

    func isVisuallyUnchanged(from other: ImageFingerprint) -> Bool {
        normalizedMeanDifference(from: other) <= 0.001
    }
}

func imageFingerprint(for url: URL) throws -> ImageFingerprint {
    guard let image = NSImage(contentsOf: url),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CaptureError.captureFailed(url.path)
    }

    let width = 32
    let height = 32
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CaptureError.captureFailed(url.path)
    }

    context.interpolationQuality = .low
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var samples = [UInt8]()
    samples.reserveCapacity(width * height)

    for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
        let red = Double(pixels[index])
        let green = Double(pixels[index + 1])
        let blue = Double(pixels[index + 2])
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        samples.append(UInt8(luminance.rounded()))
    }

    return ImageFingerprint(samples: samples)
}

func runSelfTimer(seconds: Double, soundName: String, dryRun: Bool) {
    guard seconds > 0 else {
        return
    }

    if dryRun {
        print("dry-run: self-timer \(seconds) second(s), countdown sound \(soundName)")
        return
    }

    let countdownSeconds = min(3, Int(seconds.rounded(.down)))
    let leadSeconds = seconds - Double(countdownSeconds)

    print("Self-timer: \(String(format: "%.1f", seconds)) second(s)")
    fflush(stdout)

    if leadSeconds > 0 {
        Thread.sleep(forTimeInterval: leadSeconds)
    }

    if countdownSeconds > 0 {
        for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
            let tickStartedAt = Date()
            print("\(remaining)...")
            fflush(stdout)
            playCountdownSound(named: soundName)

            let elapsed = Date().timeIntervalSince(tickStartedAt)
            if elapsed < 1 {
                Thread.sleep(forTimeInterval: 1 - elapsed)
            }
        }
    }
}

func listTargetWindows(_ config: CaptureConfig) throws {
    let app = try activateApplication(config)
    let windows = targetWindows(for: app.processIdentifier, matchingTitle: config.windowTitle)

    print("Target: \(targetApplicationDescription(config))")
    print("Process ID: \(app.processIdentifier)")

    guard !windows.isEmpty else {
        print("No visible target windows found.")
        return
    }

    for window in windows {
        let title = window.title.isEmpty ? "(untitled)" : window.title
        let bounds = window.bounds
        print(
            "window \(window.id): \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(bounds.minX)),\(Int(bounds.minY)) - \(title)"
        )
    }
}

func runCapture(_ config: CaptureConfig) throws {
    if config.listWindows {
        try listTargetWindows(config)
        return
    }

    try validatePermissions(config)

    let outputDirectory = config.outputDirectory.standardizedFileURL
    print("Activating \(targetApplicationDescription(config))...")
    let app = try activateApplication(config)

    var window = try waitForReadyTargetWindow(for: app, config: config)
    if config.captureUntilEnd {
        print("Capturing until the page stops changing, up to \(config.count) page(s), from window \(window.id) to \(outputDirectory.path)")
    } else {
        print("Capturing \(config.count) page(s) from window \(window.id) to \(outputDirectory.path)")
    }
    runSelfTimer(seconds: config.selfTimer, soundName: config.countdownSound, dryRun: config.dryRun)

    let iterationLimit = config.captureUntilEnd && config.dryRun ? min(config.count, 3) : config.count
    if config.captureUntilEnd && config.dryRun && iterationLimit < config.count {
        print("dry-run: showing the first \(iterationLimit) planned page(s); a real run stops at an unchanged page or the safety limit.")
    }

    var previousFingerprint: ImageFingerprint?
    var savedPageCount = 0
    var detectedEnd = false

    for pageNumber in 1...iterationLimit {
        try checkCancellation()

        let destination = outputDirectory.appendingPathComponent(
            filename(prefix: config.prefix, index: pageNumber)
        )

        window = try selectedTargetWindow(for: app, config: config)
        try captureWindow(window, to: destination, dryRun: config.dryRun)

        if config.captureUntilEnd && !config.dryRun {
            let currentFingerprint = try imageFingerprint(for: destination)
            if let previousFingerprint,
               currentFingerprint.isVisuallyUnchanged(from: previousFingerprint) {
                try? FileManager.default.removeItem(at: destination)
                detectedEnd = true
                print("Detected an unchanged page after page turn; stopping at \(savedPageCount) page(s).")
                break
            }
            previousFingerprint = currentFingerprint
        }

        savedPageCount += 1
        print("Captured \(destination.lastPathComponent)")

        if pageNumber < iterationLimit {
            try checkCancellation()
            requestApplicationActivation(app)
            window = try selectedTargetWindow(for: app, config: config)
            try sendPageTurn(config.key, to: app.processIdentifier, dryRun: config.dryRun)
            Thread.sleep(forTimeInterval: config.pageDelay)
        }
    }

    if config.captureUntilEnd && !detectedEnd && !config.dryRun && savedPageCount >= config.count {
        print("Reached the safety limit of \(config.count) page(s) before detecting the end.")
    }
}

func checkCancellation() throws {
    guard let cancelFile = ProcessInfo.processInfo.environment["EBOOK_CAPTURE_CANCEL_FILE"],
          !cancelFile.isEmpty else {
        return
    }

    if FileManager.default.fileExists(atPath: cancelFile) {
        throw CaptureError.cancelled
    }
}

func writeLaunchStatus(_ status: Int32) {
    guard let statusFile = ProcessInfo.processInfo.environment["EBOOK_CAPTURE_STATUS_FILE"],
          !statusFile.isEmpty else {
        return
    }

    try? "\(status)\n".write(toFile: statusFile, atomically: true, encoding: .utf8)
}

func runCommandLineCapture(arguments: [String]) {
    do {
        let config = try parseArguments(arguments)
        try runCapture(config)
        writeLaunchStatus(0)
    } catch let error as CaptureError {
        let message = error.description
        if message == usage() {
            print(message)
            writeLaunchStatus(0)
            exit(0)
        }
        fputs("error: \(message)\n", stderr)
        writeLaunchStatus(1)
        exit(1)
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        writeLaunchStatus(1)
        exit(1)
    }
}

func defaultOutputDirectoryPath() -> String {
    let fileManager = FileManager.default
    let baseDirectory = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser
    return baseDirectory.appendingPathComponent("Ebook Capture").path
}

@MainActor
final class CaptureViewModel: ObservableObject {
    @Published var appName = "Kindle.app"
    @Published var bundleIdentifier = ""
    @Published var windowTitle = ""
    @Published var outputDirectory = defaultOutputDirectoryPath()
    @Published var prefix = "page"
    @Published var count = 10
    @Published var captureUntilEnd = false
    @Published var delay = 0.8
    @Published var selfTimer = 3.0
    @Published var countdownSound = defaultCountdownSoundName()
    @Published var key = PageTurnKey.pageDown
    @Published var log = ""
    @Published var isRunning = false

    let countdownSoundNames = availableCountdownSoundNames()

    private var process: Process?
    private var pollTimer: Timer?
    private var stdoutURL: URL?
    private var stderrURL: URL?
    private var statusURL: URL?
    private var cancelURL: URL?
    private var stdoutOffset: UInt64 = 0
    private var stderrOffset: UInt64 = 0
    private var didRequestPermissions = false

    var canStart: Bool {
        !isRunning && count > 0 && delay >= 0 && selfTimer >= 0 && !outputDirectory.isEmpty
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(URL(fileURLWithPath: outputDirectory, isDirectory: true))
    }

    func previewCountdownSound() {
        let soundName = countdownSound
        Task.detached {
            playCountdownSound(named: soundName)
        }
    }

    func listWindows() {
        runInternalCommand(extraArguments: ["--list-windows"], clearLog: true)
    }

    func startCapture() {
        guard ensureCapturePermissions() else {
            return
        }

        runInternalCommand(extraArguments: [], clearLog: true)
    }

    func stopCapture() {
        guard isRunning else {
            return
        }

        appendLog("\nStopping capture...\n")
        if let cancelURL {
            FileManager.default.createFile(atPath: cancelURL.path, contents: Data())
        }
    }

    private func captureArguments() -> [String] {
        var arguments: [String] = [
            "--count", String(count),
            "--output-dir", outputDirectory,
            "--delay", String(delay),
            "--self-timer", String(selfTimer),
            "--countdown-sound", countdownSound,
            "--key", key.rawValue,
            "--prefix", prefix.isEmpty ? "page" : prefix
        ]

        if captureUntilEnd {
            arguments.append("--until-end")
        }

        let trimmedAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAppName.isEmpty {
            arguments += ["--app-name", trimmedAppName]
        }

        let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBundleIdentifier.isEmpty {
            arguments += ["--bundle-id", trimmedBundleIdentifier]
        }

        let trimmedWindowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWindowTitle.isEmpty {
            arguments += ["--window-title", trimmedWindowTitle]
        }

        return arguments
    }

    private func ensureCapturePermissions() -> Bool {
        var permissions = permissionState(prompt: false)
        if permissions.accessibility && permissions.screenCapture {
            return true
        }

        if !didRequestPermissions {
            didRequestPermissions = true
            permissions = permissionState(prompt: true)
            if permissions.accessibility && permissions.screenCapture {
                return true
            }
        }

        log = ""
        appendLog(
            """
            Ebook Capture needs two macOS privacy permissions before capture can start:

            - Privacy & Security > Accessibility
            - Privacy & Security > Screen & System Audio Recording

            Enable Ebook Capture.app in both places, then quit and reopen Ebook Capture before starting capture again.

            """
        )

        if !permissions.accessibility {
            appendLog("Missing: Accessibility\n")
        }
        if !permissions.screenCapture {
            appendLog("Missing: Screen & System Audio Recording\n")
        }

        return false
    }

    private func runInternalCommand(extraArguments: [String], clearLog: Bool) {
        guard !isRunning else {
            return
        }

        let bundleURL = Bundle.main.bundleURL

        let temporaryDirectory = FileManager.default.temporaryDirectory
        let runID = UUID().uuidString
        let stdoutURL = temporaryDirectory.appendingPathComponent("ebook-capture-\(runID).stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("ebook-capture-\(runID).stderr")
        let statusURL = temporaryDirectory.appendingPathComponent("ebook-capture-\(runID).status")
        let cancelURL = temporaryDirectory.appendingPathComponent("ebook-capture-\(runID).cancel")

        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        try? FileManager.default.removeItem(at: statusURL)
        try? FileManager.default.removeItem(at: cancelURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n",
            "-g",
            "--stdout", stdoutURL.path,
            "--stderr", stderrURL.path,
            "--env", "EBOOK_CAPTURE_STATUS_FILE=\(statusURL.path)",
            "--env", "EBOOK_CAPTURE_CANCEL_FILE=\(cancelURL.path)",
            "--env", "EBOOK_CAPTURE_SUPPRESS_PERMISSION_PROMPT=1",
            bundleURL.path,
            "--args"
        ] + captureArguments() + extraArguments

        if clearLog {
            log = ""
        }

        self.stdoutURL = stdoutURL
        self.stderrURL = stderrURL
        self.statusURL = statusURL
        self.cancelURL = cancelURL
        stdoutOffset = 0
        stderrOffset = 0

        let displayedArguments = (captureArguments() + extraArguments).joined(separator: " ")
        appendLog("$ open \(bundleURL.path) --args \(displayedArguments)\n")

        do {
            try process.run()
            self.process = process
            isRunning = true
            startPollingCommandOutput()
        } catch {
            appendLog("error: \(error.localizedDescription)\n")
            cleanupCommandFiles()
        }
    }

    private func startPollingCommandOutput() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCommandOutput()
            }
        }
    }

    private func pollCommandOutput() {
        if let stdoutURL {
            appendNewText(from: stdoutURL, offset: &stdoutOffset, toStandardError: false)
        }

        if let stderrURL {
            appendNewText(from: stderrURL, offset: &stderrOffset, toStandardError: true)
        }

        guard let statusURL, FileManager.default.fileExists(atPath: statusURL.path) else {
            return
        }

        let rawStatus = (try? String(contentsOf: statusURL, encoding: .utf8))
            ?? "unknown"
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)

        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
        process = nil
        appendLog("\nFinished with exit status \(status).\n")
        cleanupCommandFiles()
        activateMainWindow()
    }

    private func activateMainWindow() {
        if let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func appendNewText(from url: URL, offset: inout UInt64, toStandardError: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }

        defer {
            try? handle.close()
        }

        do {
            try handle.seek(toOffset: offset)
            let data = handle.readDataToEndOfFile()
            offset = try handle.offset()

            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }

            appendLog(text)
        } catch {
            appendLog("error: could not read \(toStandardError ? "stderr" : "stdout") log: \(error.localizedDescription)\n")
        }
    }

    private func cleanupCommandFiles() {
        for url in [stdoutURL, stderrURL, statusURL, cancelURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }

        stdoutURL = nil
        stderrURL = nil
        statusURL = nil
        cancelURL = nil
    }

    private func appendLog(_ text: String) {
        log += text
    }
}

struct InfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(message)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }
}

struct CaptureAppView: View {
    @StateObject private var model = CaptureViewModel()

    private var pageCountSliderValue: Binding<Double> {
        Binding(
            get: { Double(min(model.count, 1000)) },
            set: { model.count = max(1, Int($0.rounded())) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                GroupBox("Target") {
                    HStack(spacing: 8) {
                        Text("App name")
                            .frame(width: 108, alignment: .leading)
                        TextField("", text: $model.appName)
                        Button(action: model.listWindows) {
                            Label("Check Windows", systemImage: "macwindow")
                        }
                        .disabled(model.isRunning)
                        InfoButton(
                            title: "Check Windows",
                            message: "Shows the visible windows the app can capture. Use it when the target window is not being found."
                        )
                    }
                    .padding(.top, 2)
                }

                GroupBox("Capture") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("Pages")
                                .frame(width: 108, alignment: .leading)
                            Slider(value: pageCountSliderValue, in: 1...1000, step: 1)
                            TextField("", value: $model.count, format: .number)
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                        }

                        HStack(spacing: 8) {
                            Text("")
                                .frame(width: 108, alignment: .leading)
                            HStack(spacing: 6) {
                                Toggle("Capture until book end", isOn: $model.captureUntilEnd)
                                InfoButton(
                                    title: "Capture until book end",
                                    message: "Stops at whichever comes first: the detected book end or the Pages count. Set Pages higher than expected."
                                )
                            }
                        }

                        HStack(spacing: 8) {
                            Text("Output Folder")
                                .frame(width: 108, alignment: .leading)
                            TextField("", text: $model.outputDirectory)
                            Button(action: model.chooseOutputDirectory) {
                                Label("Choose", systemImage: "folder")
                            }
                            Button(action: model.openOutputDirectory) {
                                Label("Open", systemImage: "arrow.up.forward.app")
                            }
                            .disabled(model.outputDirectory.isEmpty)
                        }

                        HStack(spacing: 8) {
                            Text("Filename")
                                .frame(width: 108, alignment: .leading)
                            TextField("Filename prefix", text: $model.prefix)
                        }

                        HStack(spacing: 8) {
                            Text("Page key")
                                .frame(width: 108, alignment: .leading)
                            Menu {
                                ForEach(PageTurnKey.allCases, id: \.self) { key in
                                    Button(key.displayName) {
                                        model.key = key
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(model.key.displayName)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 160, alignment: .leading)
                            }
                            .menuStyle(.button)
                            Spacer()
                        }
                    }
                    .padding(.top, 2)
                }

                GroupBox("Timing") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Delay")
                                InfoButton(
                                    title: "Delay",
                                    message: "Wait time after each page-turn key. Increase it when the next page is still drawing when captured."
                                )
                            }
                            .frame(width: 108, alignment: .leading)
                            Slider(value: $model.delay, in: 0...5, step: 0.1)
                            Text(String(format: "%.1fs", model.delay))
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text("Self timer")
                                InfoButton(
                                    title: "Self timer",
                                    message: "Countdown before the first screenshot. Use it to move the pointer away or confirm the reader window is ready."
                                )
                            }
                            .frame(width: 108, alignment: .leading)
                            Slider(value: $model.selfTimer, in: 0...15, step: 1)
                            Text("\(Int(model.selfTimer))s")
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }

                        HStack(spacing: 8) {
                            Text("Sound")
                                .frame(width: 108, alignment: .leading)
                            Picker("", selection: $model.countdownSound) {
                                ForEach(model.countdownSoundNames, id: \.self) { soundName in
                                    Text(soundName).tag(soundName)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 160, alignment: .leading)
                            Button(action: model.previewCountdownSound) {
                                Label("Preview", systemImage: "speaker.wave.2")
                            }
                            .disabled(model.isRunning || isNoCountdownSoundName(model.countdownSound))
                            Spacer()
                        }
                    }
                    .padding(.top, 2)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                if model.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(action: model.stopCapture) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!model.isRunning)
                Button(action: model.startCapture) {
                    Label("Start Capture", systemImage: "camera.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }

            TextEditor(text: $model.log)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25))
                )
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 560)
    }
}

final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ebook Capture"
        window.contentView = NSHostingView(rootView: CaptureAppView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Ebook Capture",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
func runGraphicalApplication() {
    let app = NSApplication.shared
    let delegate = CaptureAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    _ = delegate
}

func shouldRunGraphicalApplication(arguments: [String]) -> Bool {
    arguments.isEmpty || arguments.allSatisfy { $0.hasPrefix("-psn_") }
}

let launchArguments = Array(CommandLine.arguments.dropFirst())

if shouldRunGraphicalApplication(arguments: launchArguments) {
    runGraphicalApplication()
} else {
    runCommandLineCapture(arguments: launchArguments)
}
