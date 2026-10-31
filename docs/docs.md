# Docs — reference sources

Where to look things up about Swift, the toolchain and Apple's frameworks, and which source
answers which kind of question. Open only the source a question needs; don't read these ahead
of time.

The cloned sources live in `tmp/docs/`, which git ignores. Run the commands in
[Getting the clones](#getting-the-clones) once per checkout. If `tmp/docs/` is missing, say so
rather than guessing from memory.

## Which source to use

| Question | Source | Path |
|---|---|---|
| How a language feature works: generics, macros, actors, `async`, ownership | The Swift Programming Language | `tmp/docs/swift-book/TSPL.docc/` |
| A Swift 6 concurrency error, `Sendable`, actor isolation, `@MainActor` | Swift 6 migration guide | `tmp/docs/swift-migration-guide/Guide.docc/` |
| The exact rule behind a feature, when the book doesn't settle it | Swift Evolution proposals | `tmp/docs/swift-evolution/proposals/` |
| Writing tests: `@Test`, `#expect`, tags, traits, exit tests, attachments | Swift Testing guides | `tmp/docs/swift-testing/Sources/Testing/Testing.docc/` |
| `Package.swift`, targets, C targets, unsafe flags, resources | SwiftPM docs | `tmp/docs/swift-package-manager/Sources/PackageManagerDocs/Documentation.docc/` |
| A formatter or lint result from `./scripts/format` or `./scripts/check` | swift-format docs | `tmp/docs/swift-format/Documentation/` |
| Naming a type, method or argument label | API Design Guidelines | `tmp/docs/swift-org-website/documentation/api-design-guidelines/index.md` |
| An AppKit or Foundation class: what a property does, its availability | SDK headers (doc comments) | `$(xcrun --show-sdk-path)/System/Library/Frameworks/<Name>.framework/Headers/` |
| Whether a Swift-only API (SwiftUI, Observation) exists, and on which macOS | SDK `.swiftinterface` files (signatures only, no prose) | `$(xcrun --show-sdk-path)/System/Library/Frameworks/<Name>.framework/Modules/` |
| What a compiler error group means | Compiler diagnostics | `/Library/Developer/CommandLineTools/usr/share/doc/swift/diagnostics/` |
| Apple guides and articles not in the headers: file system, FSEvents, HIG, WWDC | Web, through sosumi.ai | `https://sosumi.ai/documentation/<path>`, one page at a time |

Search before reading: proposals are named by number and title (`0414-region-based-isolation.md`),
so `ls` or `grep -ril` the folder for the feature name, then open the one file.

## Getting the clones

Each repo is a shallow clone, and the large ones are sparse, so only the docs come down (about
33 MB in all). All are Apache 2.0 repos from github.com/swiftlang.

```sh
mkdir -p tmp/docs && cd tmp/docs
clone() {
  git clone -q --depth 1 --filter=blob:none --sparse "https://github.com/swiftlang/$1.git" "$1" &&
    git -C "$1" sparse-checkout set "${@:2}"
}
clone swift-book TSPL.docc
clone swift-migration-guide Guide.docc
clone swift-evolution proposals
clone swift-testing Sources/Testing/Testing.docc Documentation
clone swift-package-manager Sources/PackageManagerDocs
clone swift-format Documentation
clone swift-org-website documentation/api-design-guidelines
```

To update them all:

```sh
for d in tmp/docs/*/; do git -C "$d" pull -q --depth 1; done
```

## Adding a source

Add a row to the table and a line to the clone block in the same change. A source belongs here
when it answers questions this project keeps asking and can be fetched under its license; the
Swift standard library reference is not here because it exists only as comments in the compiler
repo.
