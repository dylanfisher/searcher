import AppKit
import Browser
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

/// The errors a `WorkspaceSystemActions` presented.
@MainActor
private final class ErrorLog {
    var errors: [any Error] = []
}

/// The lookup finds no app, so nothing is opened, and the error is recorded instead of shown.
@MainActor @Test func aBundleIDWithNoInstalledAppFailsWithAnErrorNamingIt() {
    let log = ErrorLog()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) })

    actions.open(
        URL(fileURLWithPath: "/tmp", isDirectory: true), inAppWithBundleID: "com.example.missing")

    #expect(log.errors.count == 1)
    #expect(log.errors.first?.localizedDescription.contains("com.example.missing") == true)
}

/// Open With lists what Launch Services lists for a file of the type, once per app, the default
/// first. Nothing is opened.
@MainActor @Test(arguments: ["txt", "png", "mp3"])
func openWithListsTheAppsLaunchServicesListsForAFileDefaultFirst(pathExtension: String)
    async throws
{
    let folder = try TemporaryFolder("OpenWith")
    let file = folder.url.appending(path: "sample.\(pathExtension)")
    try Data().write(to: file)
    let type = try #require(UTType(filenameExtension: pathExtension))
    let actions = WorkspaceSystemActions(applicationURL: { _ in nil }, presentError: { _ in })
    let cache = OpenWith(systemActions: actions, didBuild: { _, _ in })

    let choices = await cache.choices(for: [type])

    let listed = NSWorkspace.shared.urlsForApplications(toOpen: file)
    let defaultApp = try #require(NSWorkspace.shared.urlForApplication(toOpen: file))
    // One entry per bundle ID and version: copies of one version are listed once.
    let listedApps = Set(
        listed.map { url in
            let bundle = Bundle(url: url)
            return [
                bundle?.bundleIdentifier ?? url.path,
                bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            ]
        })
    let chosen = choices.all.map { [$0.bundleID, $0.version ?? ""] }
    #expect(Set(chosen) == listedApps)
    #expect(chosen.count == listedApps.count)
    #expect(choices.defaultApp?.bundleID == Bundle(url: defaultApp)?.bundleIdentifier)
    #expect(choices.all.first == choices.defaultApp)
}

/// An app is read with the name Finder shows for it, its bundle ID and version, and its icon at
/// 16 points, 2x, off the main thread.
@MainActor @Test func anAppIsReadWithItsDisplayNameBundleIDVersionAndIcon() async throws {
    let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)
    let actions = WorkspaceSystemActions(applicationURL: { _ in nil }, presentError: { _ in })

    let app = await Task.detached { actions.application(at: textEdit) }.value
    let icon = await actions.applicationIcon(at: textEdit)

    let bundle = try #require(Bundle(url: textEdit))
    #expect(app.url == textEdit)
    #expect(app.name == FileManager.default.displayName(atPath: textEdit.path))
    #expect(app.bundleID == bundle.bundleIdentifier)
    #expect(app.version == bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
    #expect(icon?.width == 32)
    #expect(icon?.height == 32)
}

/// An app path with no bundle there is listed by its path, with no version, and reported.
@MainActor @Test func anAppWithNoBundleIsListedByItsPath() async throws {
    let folder = try TemporaryFolder("OpenWithNoBundle")
    let url = folder.url.appending(path: "Empty.app", directoryHint: .isDirectory)
    let actions = WorkspaceSystemActions(applicationURL: { _ in nil }, presentError: { _ in })
    var missing: [URL] = []

    let app = OpenWith.App(readingBundleAt: url) { missing.append($0) }
    let logged = await Task.detached { actions.application(at: url) }.value

    #expect(missing == [url])
    #expect(app.bundleID == url.path)
    #expect(app.version == nil)
    #expect(logged.bundleID == url.path)
}

// MARK: Get Info

/// What a stand-in for Finder was asked: the items, and whether that ran on the main thread.
private struct InfoRequest: Sendable {
    let urls: [URL]
    let onMainThread: Bool
}

private let infoItems = [
    URL(fileURLWithPath: "/r/a.txt", isDirectory: false),
    URL(fileURLWithPath: "/r/docs", isDirectory: true),
]

@MainActor @Test func getInfoAsksFinderOffTheMainThreadAndShowsNoError() async {
    let log = ErrorLog()
    let requests = EventLog<InfoRequest>()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) },
        sendToFinder: { urls in
            requests.append(InfoRequest(urls: urls, onMainThread: Thread.isMainThread))
        })

    actions.showInfo(infoItems)

    #expect(await requests.wait { $0.count == 1 })
    #expect(requests.all.first?.urls == infoItems)
    #expect(requests.all.first?.onMainThread == false)
    for _ in 0..<20 { await Task.yield() }
    #expect(log.errors.isEmpty)
}

/// A Finder that doesn't answer, or the Automation prompt waiting for the user, holds a thread of
/// its own, not the main one.
@MainActor @Test func aFinderThatDoesntAnswerLeavesTheMainThreadFree() async {
    let started = EventLog<Bool>()
    let answer = DispatchSemaphore(value: 0)
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { _ in },
        sendToFinder: { _ in
            started.append(true)
            answer.wait()
        })

    actions.showInfo(infoItems)

    // The main actor gets here, and waits here, while Finder still hasn't answered.
    #expect(await started.wait { $0.count == 1 })
    answer.signal()
}

/// While Finder hasn't answered, another Get Info sends nothing; once it answers, the next one
/// is sent.
@MainActor @Test func getInfoWhileFinderHasntAnsweredDoesNothing() async {
    let requests = EventLog<InfoRequest>()
    let answer = DispatchSemaphore(value: 0)
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { _ in },
        sendToFinder: { urls in
            requests.append(InfoRequest(urls: urls, onMainThread: Thread.isMainThread))
            answer.wait()
        })
    let second = [URL(fileURLWithPath: "/r/b.txt", isDirectory: false)]

    actions.showInfo(infoItems)
    #expect(await requests.wait { $0.count == 1 })
    actions.showInfo(second)
    answer.signal()
    await settle { !actions.isShowingInfo }
    #expect(requests.all.map(\.urls) == [infoItems])

    actions.showInfo(second)
    #expect(await requests.wait { $0.count == 2 })
    answer.signal()
    #expect(requests.all.map(\.urls) == [infoItems, second])
    await settle { !actions.isShowingInfo }
}

/// Finder keeps an event it didn't answer in time and opens the windows later, so a timeout
/// shows no error, and the next Get Info is sent.
@MainActor @Test func aTimeoutShowsNoErrorAndFreesTheNextGetInfo() async {
    let log = ErrorLog()
    let sends = EventLog<Bool>()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) },
        sendToFinder: { _ in
            sends.append(true)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1712)
        })

    actions.showInfo(infoItems)
    await settle { sends.all.count == 1 && !actions.isShowingInfo }
    actions.showInfo(infoItems)
    await settle { sends.all.count == 2 && !actions.isShowingInfo }

    #expect(log.errors.isEmpty)
}

@MainActor @Test func aRefusedEventExplainsAutomationAndOffersItsSettings() async throws {
    let log = ErrorLog()
    let opened = EventLog<URL>()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) },
        sendToFinder: { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -1743) },
        openURL: { opened.append($0) })

    actions.showInfo(infoItems)

    await settle { log.errors.count == 1 }
    let error = try #require(log.errors.first as? WorkspaceSystemActions.AutomationDenied)
    #expect(error.localizedDescription == "Searcher can’t show Finder’s Info window")
    #expect(error.recoverySuggestion?.contains("Automation list") == true)
    #expect(error.recoveryOptions.first == "Open Automation Settings")
    #expect(!error.attemptRecovery(optionIndex: 1))
    #expect(opened.all.isEmpty)
    #expect(error.attemptRecovery(optionIndex: 0))
    #expect(opened.all == [WorkspaceSystemActions.AutomationDenied.automationSettings])
}

@MainActor @Test func anotherFailureSaysFinderDidntShowTheWindowAndWhy() async throws {
    let log = ErrorLog()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) },
        sendToFinder: { _ in
            throw NSError(
                domain: NSOSStatusErrorDomain, code: -1728,
                userInfo: [NSLocalizedDescriptionKey: "Can’t get information window."])
        })

    actions.showInfo(infoItems)

    await settle { log.errors.count == 1 }
    let error = try #require(log.errors.first as? WorkspaceSystemActions.InfoFailed)
    #expect(error.localizedDescription == "Finder didn’t show the Info window")
    #expect(error.recoverySuggestion == "Can’t get information window.")
}

/// The event AppleScript sends for `open information window of item`, one specifier per item,
/// built without sending it, and the `activate` after it.
@Test func theInfoEventOpensTheInformationWindowOfEachItem() throws {
    let event = WorkspaceSystemActions.infoEvent(for: infoItems)

    #expect(event.eventClass == AEEventClass(kCoreEventClass))
    #expect(event.eventID == AEEventID(kAEOpenDocuments))
    let target = try #require(event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
    #expect(target.descriptorType == DescType(typeApplicationBundleID))
    #expect(String(data: target.data, encoding: .utf8) == "com.apple.finder")
    let windows = try #require(event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
    #expect(windows.numberOfItems == infoItems.count)
    for (index, url) in infoItems.enumerated() {
        let window = try #require(windows.atIndex(index + 1))
        #expect(window.descriptorType == DescType(typeObjectSpecifier))
        #expect(
            window.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == DescType(cProperty))
        #expect(
            window.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue == DescType(formPropertyID))
        #expect(
            window.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue
                == WorkspaceSystemActions.informationWindow)
        let item = try #require(window.forKeyword(AEKeyword(keyAEContainer)))
        #expect(item.descriptorType == DescType(typeObjectSpecifier))
        #expect(item.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == DescType(cObject))
        #expect(
            item.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue
                == DescType(formAbsolutePosition))
        #expect(item.forKeyword(AEKeyword(keyAEKeyData))?.fileURLValue == url)
        #expect(item.forKeyword(AEKeyword(keyAEContainer))?.descriptorType == DescType(typeNull))
    }
    let activate = WorkspaceSystemActions.activateEvent()
    #expect(activate.eventClass == AEEventClass(kAEMiscStandards))
    #expect(activate.eventID == AEEventID(kAEActivate))
}
