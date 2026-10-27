import Browser
import Foundation

/// The words of a pane's status: the spinner's label and the note shown while a folder is slow or
/// offline, such as "music is offline. Listed 5 minutes ago." The only copy of them.
@MainActor
struct PaneStatusText {
    /// The note's sentences are English, so its age is too, whatever the system's language.
    static let ageLocale = Locale(identifier: "en_US")

    private let ages: RelativeDateTimeFormatter

    /// `systemLocale` is the locale a formatter starts with, the system's; tests pass another to
    /// check that the age doesn't follow it.
    init(systemLocale: Locale = .autoupdatingCurrent) {
        ages = RelativeDateTimeFormatter()
        ages.locale = systemLocale
        ages.locale = Self.ageLocale
        ages.unitsStyle = .full
        ages.dateTimeStyle = .numeric
    }

    /// What VoiceOver calls the spinner while `folderName` loads.
    static func spinnerLabel(_ folderName: String) -> String {
        "Loading \(folderName)"
    }

    /// The note for `state` at `now`, or nil for a state that needs none. `volumeName` names the
    /// volume that stopped answering.
    func note(for state: ListingState, volumeName: String, now: Date) -> String? {
        let kept: ListingState.KeptRows?
        let headline: String
        switch state {
        case .slow(let rows):
            kept = rows
            headline = "\(volumeName) is slow to answer."
        case .offline(let rows):
            kept = rows
            headline = "\(volumeName) is offline."
        case .loading, .partial, .loaded, .cachedRefreshing, .denied, .failed, .notConnected:
            return nil
        }
        guard let kept else { return headline }
        guard let listedAt = kept.listedAt else { return "\(headline) Showing part of the folder." }
        return "\(headline) Listed \(age(of: listedAt, now: now))."
    }

    /// The note for a listed folder that has `count` entries whose names aren't valid UTF-8, which
    /// the listing leaves out (docs/decisions/0117-unreadable-names.md); nil for none.
    static func unreadableNamesNote(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 item with an unreadable name isn't shown."
        default: "\(count) items with unreadable names aren't shown."
        }
    }

    /// "just now" under a minute, else whole minutes and up, "5 minutes ago": the note changes
    /// as each minute passes, so seconds would be wrong for most of it.
    private func age(of listedAt: Date, now: Date) -> String {
        let minutes = (now.timeIntervalSince(listedAt) / 60).rounded(.down)
        guard minutes >= 1 else { return "just now" }
        return ages.localizedString(for: now.addingTimeInterval(-minutes * 60), relativeTo: now)
    }

    /// How long after `now` the age of rows listed at `listedAt` reaches its next whole minute,
    /// when the note's words can change.
    static func nextAgeChange(listedAt: Date, now: Date) -> Duration {
        let age = now.timeIntervalSince(listedAt)
        guard age >= 0 else { return .seconds(-age) }
        return .seconds(60 - age.truncatingRemainder(dividingBy: 60))
    }
}
