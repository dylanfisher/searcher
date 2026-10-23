import AppKit
import Browser

/// Forwards the system's mount and unmount notifications to `VolumeEvents`, which acts on them.
@MainActor
enum VolumeNotifications {
    static func start() {
        forward(NSWorkspace.willUnmountNotification, to: VolumeEvents.willUnmount(at:))
        forward(NSWorkspace.didUnmountNotification, to: VolumeEvents.didUnmount(at:))
        forward(NSWorkspace.didMountNotification, to: VolumeEvents.didMount(at:))
    }

    private static func forward(
        _ name: Notification.Name, to event: @escaping @MainActor (String) -> Void
    ) {
        // The observers stay for the life of the app, so their tokens aren't kept.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { notification in
            guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else {
                preconditionFailure("\(name.rawValue) came without a volume URL")
            }
            let mountPoint = volume.path
            MainActor.assumeIsolated { event(mountPoint) }
        }
    }
}
