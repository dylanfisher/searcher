/// The path of the item `name` in `folder`. A folder that ends in `/`, as the root does, gets
/// no second one.
public func join(_ folder: String, _ name: String) -> String {
    folderPrefix(folder) + name
}
