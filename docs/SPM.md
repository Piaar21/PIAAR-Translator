# Swift Package reproducibility

The official Supabase URL is https://github.com/supabase/supabase-swift.git.
The one remote reference uses exactVersion 2.49.0. Both application and Unit Test
products refer to that same remote package; RecurrenceTests directly imports
Supabase, so the Unit Test target has its own product link/framework build entry.
There is no UI Test target and no manually embedded Supabase framework.

Keep project.pbxproj and the shared application lockfile in version control:

    PIAAR Translator.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

Do not replace that file with the SDK checkout's own Package.resolved. Do not
ignore or delete the shared swiftpm directory. Xcode regenerates the lockfile on
resolve, so retain/review it when committing package changes. The current graph
contains Supabase 2.49.0, swift-asn1 1.4.0, swift-clocks 1.0.6,
swift-concurrency-extras 1.1.0, swift-crypto 3.15.1, swift-http-types 1.5.1,
and xctest-dynamic-overlay 1.3.0. No private credentials are in this file.

The installed Xcode is 15.4. The system xcode-select currently points to
CommandLineTools, which cannot run xcodebuild. Use the full Xcode per command;
no global developer-directory or signing setting was changed by this repair:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project "PIAAR Translator.xcodeproj" -scheme "PIAAR Translator" -resolvePackageDependencies
xcodebuild -list -project "PIAAR Translator.xcodeproj"
```

For reproducible builds add -onlyUsePackageVersionsFromResolvedFile. To verify
that a compiled module cache is not hiding missing dependencies, use a fresh
-derivedDataPath and perform Debug clean build, Release clean build, then Debug
build again. The final normal build should also resolve without special package
cache paths or package-resolution bypasses. Run Unit Tests; never run UI Tests.

The repair found no duplicated remote package, dangling UUID, invalid requirement,
workspace override, or stale scheme target. The shared lockfile was absent and the
Test target relied on an indirect SDK link. The default cache also retained an old
unused MultipartFormData checkout. The reported GUI error was not reproduced by
the initial CLI resolve, so cache corruption is not asserted as a proven cause.
No global cache purge is required. If an already-open Xcode window still retains
an old graph, reopen this project after saving edits and resolve once; do not remove
and re-add the SDK or edit production code to suppress the error.
