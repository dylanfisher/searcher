/// The way a split divides its space. `.horizontal` puts the two children side by side;
/// `.vertical` stacks them.
public enum Axis: String, Codable, Sendable {
    case horizontal, vertical
}
