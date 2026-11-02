import UIKit

private enum Locals { @TaskLocal static var value: Int = 0 }
final class DefaultHelper { let value = "probe" }
@MainActor final class ExplicitHelper { let value = "probe" }
final class EmptyDeinitHelper { let value = "probe"; deinit {} }
final class NonisolatedDeinitHelper { let value = "probe"; nonisolated deinit {} }
nonisolated final class UnisolatedHelper { let value = "probe" }
@inline(never) func releaseDefault() { let x = DefaultHelper(); print("value=\(x.value)"); withExtendedLifetime(x) {} }
@inline(never) func releaseExplicit() { let x = ExplicitHelper(); print("value=\(x.value)"); withExtendedLifetime(x) {} }
@inline(never) func releaseEmpty() { let x = EmptyDeinitHelper(); print("value=\(x.value)"); withExtendedLifetime(x) {} }
@inline(never) func releaseNonisolated() { let x = NonisolatedDeinitHelper(); print("value=\(x.value)"); withExtendedLifetime(x) {} }
@inline(never) func releaseUnisolated() { let x = UnisolatedHelper(); print("value=\(x.value)"); withExtendedLifetime(x) {} }
func probe(_ mode: String) {
    print("PROBE begin mode=\(mode) main=\(Thread.isMainThread) task=\(withUnsafeCurrentTask { $0 != nil }) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    fflush(stdout)
    switch mode {
    case "outside": releaseDefault()
    case "inside": Locals.$value.withValue(1) { releaseDefault() }
    case "explicit": Locals.$value.withValue(1) { releaseExplicit() }
    case "empty": Locals.$value.withValue(1) { releaseEmpty() }
    case "nonisolated": Locals.$value.withValue(1) { releaseNonisolated() }
    case "unisolated": Locals.$value.withValue(1) { releaseUnisolated() }
    case "after":
        var x: DefaultHelper?
        Locals.$value.withValue(1) { x = DefaultHelper() }
        print(x!.value); x = nil
    default: fatalError("unknown probe")
    }
    print("PROBE passed mode=\(mode)"); fflush(stdout)
}
@main struct ProbeMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)) }
}
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let args = ProcessInfo.processInfo.arguments
        let mode = args.dropFirst().first ?? "outside"
        let w = UIWindow(frame: UIScreen.main.bounds); w.rootViewController = UIViewController(); w.makeKeyAndVisible(); window = w
        if mode == "async" {
            Task { @MainActor in Locals.$value.withValue(1) { releaseDefault() }; print("PROBE passed mode=async task=\(withUnsafeCurrentTask { $0 != nil })"); fflush(stdout); exit(0) }
        } else { probe(mode); exit(0) }
        return true
    }
}
