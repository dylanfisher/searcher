/// `folder` ending in one `/`, so a path that starts with it is inside the folder. The root
/// stays `/` rather than becoming `//`.
public func folderPrefix(_ folder: String) -> String {
    folder.hasSuffix("/") ? folder : folder + "/"
}
