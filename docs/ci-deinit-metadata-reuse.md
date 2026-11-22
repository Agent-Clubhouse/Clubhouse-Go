# Reuse parser-tool metadata without caching ownership surfaces

The original full run's Build-for-testing policy step took61s, including all20
source-parser fixture tests in43.319s. Every extraction previously asked xcrun
for the selected compiler, its version and an SDK path, even when the compiled
scanner already existed. The scanner and fixtures themselves remain unchanged.

The correction still resolves the selected compiler for EVERY extraction and
stats its real target. A bounded process-local version cache is keyed by selected
path, resolved identity/device/inode/size/mtime/ctime/mode and the selection
context (DEVELOPER_DIR, SDKROOT, TOOLCHAINS and PATH). Replacing the compiler,
switching selection or changing context misses the cache. Failed requests are
not cached. The scanner-binary key also binds that context with the existing
scanner-source bytes and version. SDK-path lookup occurs only on a real compile
miss. Version and compile requests execute the selected compiler path directly.

Every fixture/app source extraction still executes the original SwiftParser
scanner on fresh input paths; there is no AST, capture, storage or policy-result
cache. The scanner source, ownership policy/fingerprints, all20 fixture tests and
the actual app-symbol/field-affinity check remain byte-identical. The cache is
not a concurrent toolchain-installation transaction or cross-process metadata cache.

A scoped real-process observer ran the unchanged normal20-test discovery entry
point before and after. It wrapped process creation and returned SDK/scanner
output unchanged; no app or simulator was run. Both suites passed20tests.

| Actual explicit process launches | Before | After |
| --- | ---: | ---: |
| Selected compiler lookup | 86 | 86 |
| Compiler version lookup | 86 | 1 |
| SDK path lookup | 86 | 1 |
| Scanner compilation | 1 | 1 |
| Fresh scanner invocation | 86 | 86 |

The ordered input hashes and all86 full canonical output-value hashes match.
Only temporary top-level path keys were normalized to argument indices; no
ownership fields, callbacks, macros, constructors or teardown values were removed.
The local runs took7.987s and1.822s on the same selected local compiler. Both
included one cold scanner compilation (the corrected context-bound key differs).
These LOCAL observations are not hosted savings or a prediction that the old61s
step disappears. A next necessary hosted Build must retain its20-fixture result,
real app-policy result and measured stage time.

Five cheap mock-toolchain controls cover warm reuse with freshly changing source
inputs, compiler replacement/selection/scanner-source misses, environment changes,
failed version requests and failed compile-time SDK lookup. They do not pretend to
be a Swift parser or replace the normal real fixtures. Counts are also recorded
in `ci-deinit-metadata-counts.json`; full private traces retain exact argv and
per-invocation fingerprints without publishing local paths.
