import Foundation
import Testing
@testable import CompanionDomain

struct CompanionMachineStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func everyMachineStateHasOneLabelAndAnOptionalSymbol() {
        let cases: [(CompanionMachineState, String, String?)] = [
            (.connected, "Connected", nil), (.working, "Working", "gearshape.2"),
            (.asleep, "Asleep", "moon"), (.offline, "Offline", "wifi.slash"),
            (.turnedOff, "Turned off", "power"), (.connecting, "Connecting", nil),
            (.reconnecting, "Reconnecting", nil), (.unknown, "Unknown", "questionmark.circle")
        ]
        for (state, label, symbol) in cases {
            let presentation = state.presentation(now: now)
            #expect(presentation.label == label)
            #expect(presentation.detail == label, "No second link-state label when it does not block")
            #expect(presentation.symbol == symbol)
        }
    }

    @Test func pairedConnectionsUseSharedWordsWithoutChangingCommandAuthorityOrRecoveryDetails() {
        let cases: [(CompanionConnection, CompanionMachineState)] = [
            (.offline, .offline), (.connecting, .connecting), (.synchronizing, .reconnecting),
            (.reconnecting, .reconnecting), (.connected, .connected), (.failed("TLS recovery detail"), .offline)
        ]
        for (connection, state) in cases {
            #expect(connection.machineState == state)
            #expect(connection.label == state.label)
            #expect(connection.presentation(now: now) == state.presentation(now: now))
            #expect(connection.canOperate == (connection == .connected))
        }
        #expect(CompanionConnection.connecting.label == "Connecting", "A first connection has never connected before")
        #expect(CompanionConnection.connecting.presentation().symbol == CompanionConnection.reconnecting.presentation().symbol)
        #expect(CompanionConnection.failed("TLS recovery detail").detail == "TLS recovery detail")
        let failed = CompanionConnection.failed("TLS recovery detail")
            .presentation(lastSeen: now.addingTimeInterval(-300), linkBlocked: true, now: now)
        #expect(failed.label.hasPrefix("Offline · last seen "))
        #expect(failed.detail == "\(failed.label)\nCan't reach from this phone")
    }

    @Test func onlyOfflineShowsLastSeenAndFutureTimesNeverClaimAVisitFromTheFuture() {
        let seen = now.addingTimeInterval(-300)
        #expect(CompanionMachineState.offline.presentation(lastSeen: seen, now: now).label.hasPrefix("Offline · last seen "))
        for state in [CompanionMachineState.connected, .working, .asleep, .turnedOff, .connecting, .reconnecting, .unknown] {
            #expect(state.presentation(lastSeen: seen, now: now).label == state.label)
        }
        #expect(CompanionMachineState.offline.presentation(lastSeen: now.addingTimeInterval(300), now: now)
                == CompanionMachineState.offline.presentation(lastSeen: now, now: now))
    }

    @Test func presenceUsesTheSameFormatterAndOnlyKnownBlockingLinksAddReachabilityCopy() {
        let cases: [(String, CompanionMachineState)] = [
            ("online", .connected), ("working", .working), ("asleep", .asleep), ("offline", .offline),
            ("off", .turnedOff), ("connecting", .connecting), ("reconnecting", .reconnecting), ("future", .unknown)
        ]
        var remote = CompanionDispatcherPresence.Remote(machineId: "remote", machineName: "Mac", label: "Chat on Mac",
                                                         state: "online", link: .init(state: "active"))
        for (wireState, state) in cases {
            remote.state = wireState
            #expect(remote.presentation(now: now) == state.presentation(now: now))
        }
        remote.state = "offline"
        for value in ["2027-01-15T08:00:00Z", "2027-01-15T08:00:00.000Z"] {
            remote.lastSeen = value
            #expect(remote.stateText(now: now).hasPrefix("Offline · last seen "))
        }
        remote.lastSeen = "invalid timestamp"
        #expect(remote.stateText(now: now) == "Offline")
        for linkState in ["active", "future"] {
            remote.link = .init(state: linkState, reason: "Do not display raw reasons")
            #expect(remote.link.text == nil)
            #expect(remote.detailText(now: now) == "Offline")
        }
        for linkState in ["paused", "unavailable"] {
            remote.link = .init(state: linkState, reason: "Do not display raw reasons")
            #expect(remote.link.text == "Can't reach from this phone")
            #expect(remote.detailText(now: now) == "Offline\nCan't reach from this phone")
        }
    }
}
