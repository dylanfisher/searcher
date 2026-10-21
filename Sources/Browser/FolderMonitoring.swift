/// Watches the folder a pane shows. The pane only stops it when it navigates away; whoever starts
/// a monitor hands it to the pane.
public protocol FolderMonitoring: AnyObject {
    func stop()
}
