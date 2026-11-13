import Foundation

/// Every string a person can see, in the app and the CLI. British English, short
/// sentences, no em dashes. The product name only ever comes from `Brand`.
public enum Copy {
    static let name = Brand.displayName
    static let cli = Brand.cliName

    // MARK: Window and menus
    public static let windowTitle = name
    public static func windowTitleTestMode(_ path: String) -> String { "\(name) (test mode: \(path))" }
    public static let menuOpen = "Open…"
    public static let menuRestore = "Restore Apple's Wallpaper"
    public static let aboutText = "\(name) puts your own video or GIF on your Mac's lock screen. It is not affiliated with Apple."

    // MARK: S1 Empty
    public static let dropHeading = "Drop a video or GIF here"
    public static let dropHelp = "MP4, MOV, M4V or GIF. It will loop on your lock screen."
    public static let chooseFile = "Choose File…"
    public static let dropHeadingTargeted = "Let go to use this file"
    public static let dropAccessibilityLabel = "Drop a video or GIF here"
    public static let dropAccessibilityHint = "Or press Choose File to pick one."
    public static let panelPrompt = "Choose"
    public static let panelMessage = "Choose a video or a GIF."

    // MARK: S2 and S3
    public static func reading(_ filename: String) -> String { "Reading \(filename)…" }
    public static func fileLineVideo(_ filename: String, duration: String, width: Int, height: Int) -> String {
        "\(filename). \(duration), \(width) × \(height)."
    }
    public static func fileLineGIF(_ filename: String, duration: String, width: Int, height: Int, frames: Int) -> String {
        "\(filename). \(duration), \(width) × \(height), \(frames) frames."
    }
    public static let pausePreview = "Pause preview"
    public static let playPreview = "Play preview"
    public static func previewLabel(_ filename: String, fit: String) -> String { "Preview of \(filename), \(fit)" }
    public static let fitControlLabel = "How it fits the screen"
    public static let fitOption = "Fit"
    public static let fillOption = "Fill"
    public static let fitHelp = "Shows the whole picture. \(name) fills the space around it with a colour taken from its edges."
    public static let fillHelp = "Covers the whole screen. The edges of the picture are cut off."
    public static let sameShapeHelp = "Your file is already the shape of the screen, so Fit and Fill look the same."
    public static let longerThanFive = "This video is longer than 5 minutes. \(name) will use the first 5 minutes."
    public static func oneFileOnly(_ filename: String) -> String { "\(name) takes one file at a time. It is using \(filename)." }
    public static let useOnLockScreen = "Use on lock screen"
    public static func noteFirstApply(_ aerialName: String) -> String {
        "This takes the place of Apple's \"\(aerialName)\" wallpaper. \(name) keeps Apple's video so you can put it back. Your desktop will show your video too."
    }
    public static let noteFirstApplyUnknown = "This takes the place of one of Apple's moving wallpapers. \(name) keeps Apple's video so you can put it back. Your desktop will show your video too."
    public static let noteAlreadyApplied = "This replaces the video you are using now. Your desktop will show it too."
    public static let chooseAnotherFile = "Choose another file"

    // MARK: S4 Needs an aerial
    public static let needsAerialHeading = "\(name) needs one of Apple's moving wallpapers"
    public static let needsAerialBody = "macOS only plays its own moving wallpapers on the lock screen. \(name) puts your video in the place of one of them, and there isn't one on this Mac yet. Choose one to download from Apple. Your video will show instead of it."
    public static let aerialListLabel = "Apple's moving wallpapers"
    public static func downloadButton(size: Int64?) -> String {
        guard let size else { return "Download from Apple" }
        return "Download from Apple (\(bytes(size)))"
    }
    public static let needsAerialOtherRoute = "Or choose any moving wallpaper in System Settings. \(name) will carry on when the download finishes."
    public static let openWallpaperSettings = "Open Wallpaper Settings"
    public static func downloading(_ aerialName: String, done: Int64, total: Int64?) -> String {
        if let total { return "Downloading \"\(aerialName)\" from Apple. \(bytes(done)) of \(bytes(total))." }
        return "Downloading \"\(aerialName)\" from Apple. \(bytes(done))."
    }
    public static let cancelDownload = "Cancel download"
    public static let downloadCancelled = "Download cancelled."
    public static let noDownloadableAerials = "\(name) couldn't find any wallpapers it can download. Choose a moving wallpaper in System Settings instead."

    // MARK: S5 Working
    public static func convertingVideo(_ percent: Int) -> String { "Converting your video. \(percent)%" }
    public static func convertingGIF(_ percent: Int) -> String { "Converting your GIF. \(percent)%" }
    public static func repeating(_ percent: Int) -> String { "Making it 5 minutes long. \(percent)%" }
    public static let installing = "Putting it on the lock screen…"
    public static let cancel = "Cancel"
    public static let installingHelp = "\(name) is swapping the files. This takes a moment."
    public static let cancelledNothingChanged = "Cancelled. Nothing on your Mac was changed."
    public static func percentAnnouncement(_ percent: Int) -> String { "\(percent) per cent" }

    // MARK: S6 Applied
    public static let doneJustApplied = "Done. Lock your Mac (Ctrl+Cmd+Q) to see it."
    public static func appliedOnOpen(_ filename: String) -> String { "\(filename) is on your lock screen." }
    public static let keepApplied = "Keep it applied"
    public static let keepAppliedHelp = "macOS sometimes puts Apple's video back, for example after an update. With this on, \(name) checks when you log in and once an hour, and puts yours back."
    public static let keepAppliedJustOn = "On. macOS may show a notice that \(name) can run in the background."
    public static let restoreApple = "Restore Apple's wallpaper"

    // MARK: S7 Attention
    public static let revertedHeading = "macOS put Apple's video back"
    public static let revertedBody = "This can happen after a macOS update. \(name) still has your video."
    public static let useMyVideoAgain = "Use my video again"
    public static let leaveApple = "Leave Apple's wallpaper"
    public static let revertedCopyGone = "macOS put Apple's video back, and \(name) no longer has its copy of yours. Choose your file again."
    public static let otherWallpaperHeading = "A different wallpaper is chosen in System Settings"
    public static func otherWallpaperBody(_ aerialName: String) -> String {
        "Your video is still in place. It will show again if you choose \"\(aerialName)\" as your wallpaper, or \(name) can choose it for you."
    }

    // MARK: S8 Restore
    public static let restoring = "Putting Apple's wallpaper back…"
    public static let restored = "Apple's wallpaper is back. \(name) has deleted its copy of your video. Your own file hasn't been touched."
    public static let nothingToRestoreApp = "Nothing to restore. \(name) hasn't changed your wallpaper."
    public static let chooseAFile = "Choose a file"

    // MARK: S9 buttons
    public static let tryAgain = "Try again"
    public static let downloadAndRestore = "Download and restore"

    // MARK: Errors
    public static func message(for error: LoopError) -> String {
        switch error {
        case .unsupportedLayout(.legacy):
            return "\(name) doesn't work on this version of macOS yet. Here, Apple keeps its moving wallpapers in a system folder that needs an administrator password. \(name) only changes files in your own Library, so it has stopped."
        case .unsupportedLayout(.none):
            return "\(name) couldn't find Apple's moving wallpapers on this Mac. Open Wallpaper in System Settings once, then open \(name) again."
        case .catalogueUnreadable:
            return "\(name) couldn't read Apple's list of moving wallpapers. Open Wallpaper in System Settings once, then try again."
        case .indexUnreadable, .noDesktopEntries:
            return "\(name) couldn't read your wallpaper settings. Choose any wallpaper in System Settings, then try again. Nothing was changed."
        case .permissionDenied(_, let detail):
            return "macOS stopped \(name) from opening the wallpaper folder. Nothing was changed.\n\(detail)"
        case .needsDownload:
            return "No Apple moving wallpaper is downloaded yet. Choose one in System Settings > Wallpaper, or run: \(cli) set <file> --download <asset-id>. Run \"\(cli) status\" to list them."
        case .downloadFailed(let detail):
            return "The download from Apple stopped. Check your internet connection and try again.\n\(detail)"
        case .unsupportedFile(let filename):
            return "\(name) can't use \(filename). Try an MP4, MOV, M4V or GIF."
        case .unreadableFile(let filename):
            return "\(name) couldn't open \(filename). The file may be damaged."
        case .noPicture(let filename):
            return "\(filename) has sound but no picture. Choose a video or a GIF."
        case .protectedFile(let filename):
            return "\(filename) is copy-protected, so \(name) can't convert it."
        case .notEnoughSpace(let needed, let free):
            return "There isn't enough free space. \(name) needs about \(bytes(needed)) and this Mac has \(bytes(free)). Nothing was changed."
        case .conversionFailed(let filename, let detail):
            return "\(name) couldn't convert \(filename). Nothing on your Mac was changed.\n\(detail)"
        case .cancelled:
            return cancelledNothingChanged
        case .swapFailed(let detail):
            return "\(name) couldn't put your video in place, so it put everything back as it was.\n\(detail)"
        case .rollbackFailed(let path):
            return "Something went wrong part-way and \(name) couldn't undo it. Apple's video is safe at \(path). Press Restore Apple's wallpaper to put it back."
        case .choiceNotAccepted(let label):
            return "Your video is in place, but macOS didn't switch to it. Open Wallpaper in System Settings and choose \"\(label)\"."
        case .originalMissing:
            return "\(name) can't find its copy of Apple's video. It can download a fresh one from Apple."
        case .busy:
            return "\(name) is already doing this in another window or in the background. Try again in a minute."
        case .keeperFailed(let detail):
            return "\(name) couldn't turn on Keep it applied.\n\(detail)"
        case .stateUnreadable(let detail):
            return "\(name) couldn't read its own notes about what it changed, so it has stopped without changing anything.\n\(detail)"
        }
    }

    // MARK: CLI
    public static let cliHelp = """
    \(cli) puts your own video or GIF on the Mac lock screen.

    Usage:
      \(cli) set <file> [--fill] [--download <asset-id>] [--keep]
      \(cli) restore
      \(cli) status [--json]
      \(cli) keep on|off
      \(cli) reapply [--quiet]
      \(cli) help

    set       Convert the file and put it on the lock screen. Fit is the default; --fill crops to cover the screen.
    restore   Put Apple's wallpaper back and delete \(cli)'s copy of your video.
    status    Say what is applied. Lists the downloaded Apple wallpapers when nothing is.
    keep      Check at login and once an hour, and put your video back if macOS replaced it.
    reapply   Put your video back if macOS replaced it. The background check runs this.
    """
    public static func cliConverting(_ percent: Int) -> String { "Converting… \(percent)%" }
    public static func cliRepeating(_ percent: Int) -> String { "Making it 5 minutes long… \(percent)%" }
    public static let cliDone = doneJustApplied
    public static let cliRestored = "Apple's wallpaper is back."
    public static let cliNothingToRestore = "Nothing to restore."
    public static func cliStatusApplied(_ filename: String, aerialName: String, assetID: String, date: String) -> String {
        "Applied: \(filename), in place of \"\(aerialName)\" (\(assetID)), since \(date)."
    }
    public static let cliStatusNotApplied = "Not applied."
    public static let cliStatusReverted = "macOS put Apple's video back. Run \"\(cli) reapply\" to use yours again."
    public static let cliStatusMissing = "Apple's video file is missing from its folder. Run \"\(cli) reapply\" to put yours back, or \"\(cli) restore\"."
    public static let cliStatusOtherWallpaper = "Your video is in place, but a different wallpaper is chosen in System Settings."
    public static func cliStatusKeep(_ on: Bool) -> String { "Keep applied: \(on ? "on" : "off")" }
    public static let cliDownloadedHeader = "Downloaded Apple wallpapers:"
    public static let cliNone = "none"
    public static let cliDownloadableHeader = "Apple wallpapers you can download with --download <asset-id>:"
    public static func cliUnsupported(_ kind: AerialLayoutKind) -> String { message(for: .unsupportedLayout(kind)) }
    public static let cliKeepOn = "Keep applied is on. \(name) will check at login and once an hour."
    public static let cliKeepOff = "Keep applied is off."
    public static func cliUnknownCommand(_ command: String) -> String { "Unknown command \"\(command)\". Run \"\(cli) help\"." }
    public static func cliUnknownOption(_ option: String) -> String { "Unknown option \"\(option)\". Run \"\(cli) help\"." }
    public static func cliMissingArgument(_ what: String) -> String { "Missing \(what). Run \"\(cli) help\"." }
    public static func cliFileNotFound(_ path: String) -> String { "There is no file at \(path)." }
    public static func cliDownloading(_ aerialName: String, percent: Int) -> String { "Downloading \"\(aerialName)\" from Apple… \(percent)%" }
    public static func cliTestMode(_ path: String) -> String { "Test mode: \(path)" }
    public static func cliUnknownAsset(_ id: String) -> String { "There is no Apple wallpaper with the id \(id). Run \"\(cli) status\" to list them." }

    // MARK: Formatting
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        if total < 60 { return "\(total) s" }
        return String(format: "%d min %02d s", total / 60, total % 60)
    }
}
