import Foundation
import Testing
@testable import ClubhouseTransport

private final class FixtureBrowser: NetServiceBrowser {
    var searched: (String, String)?
    var didStop = false
    override func searchForServices(ofType type: String, inDomain domain: String) { searched = (type, domain) }
    override func stop() { didStop = true }
}
private final class FixtureService: NetService {
    var resolved = false
    var stopped = false
    override var hostName: String? { "fixture.local." }
    override var port: Int { 8443 }
    override func resolve(withTimeout timeout: TimeInterval) { resolved = true }
    override func stop() { stopped = true }
}
@Test @MainActor func bonjourFindResolveRemoveAndStopUseDesktopServiceType() async throws {
    let browser = FixtureBrowser()
    let discovery = AnnexDiscovery(makeBrowser: { browser })
    var states = discovery.states().makeAsyncIterator()
    _ = await states.next()
    discovery.start()
    #expect(browser.searched?.0 == "_clubhouse-annex._tcp.")
    #expect(browser.searched?.1 == "local.")
    let service = FixtureService(domain: "local.", type: "_clubhouse-annex._tcp.", name: "Fixture", port: 8443)
    discovery.netServiceBrowser(browser, didFind: service, moreComing: false)
    #expect(service.resolved)
    discovery.netServiceDidResolveAddress(service)
    let found = await states.next()
    #expect(found?.hosts.first?.endpoint.host == "fixture.local.")
    #expect(found?.hosts.first?.endpoint.port == 8443)
    discovery.netServiceBrowser(browser, didRemove: service, moreComing: false)
    #expect(await states.next()?.hosts.isEmpty == true)
    discovery.stop()
    #expect(browser.didStop)
    #expect(await states.next()?.isSearching == false)
    // Late resolver callbacks cannot resurrect disappeared desktops.
    discovery.netServiceDidResolveAddress(service)
}
@Test @MainActor func discoveryDenialStopsAndSurfacesErrorWithoutTrustOrCredentials() async {
    let browser = FixtureBrowser()
    let discovery = AnnexDiscovery(makeBrowser: { browser })
    var states = discovery.states().makeAsyncIterator()
    discovery.start()
    discovery.netServiceBrowser(browser, didNotSearch: [NetService.errorCode: NSNumber(value: -72008)])
    let failed = await states.next()
    #expect(failed?.errorCode == -72008)
    #expect(failed?.isSearching == false)
    #expect(failed?.hosts.isEmpty == true)
    #expect(browser.didStop)
}
