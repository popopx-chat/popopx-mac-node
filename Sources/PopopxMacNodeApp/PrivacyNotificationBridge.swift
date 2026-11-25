//
//  PrivacyNotificationBridge.swift
//  POPOPX Mac Node — the Notification Center half of the human-in-the-loop gate.
//
//  Lives in the host target rather than in `PopopxMacNode` on purpose:
//  `UNUserNotificationCenter.current()` traps in a test host with no bundle
//  identifier, and the ledger's unit tests must be able to count proposals without
//  a user granting anything. The module therefore ships `SilentProposalNotifier`,
//  and this file is the real one the composition root hands it.
//

import Foundation
import PopopxMacNode
import UserNotifications

/// Reminds the owner that a write is waiting for them.
///
/// Two channels, deliberately:
///
/// * the console event stream, which always works and is what the Privacy Bridges
///   panel renders its pending list from — including for a proposal that arrived
///   from a phone, when nobody has the panel open;
/// * Notification Center, which is best effort: an ad-hoc signed build can be
///   refused authorization, and a refused `requestAuthorization` must never turn
///   into a proposal that nobody hears about.
actor PrivacyCenterNotifier: ProposalNotifier {
    private let hub: ConsoleEventHub
    private var authorizationAttempted = false

    init(hub: ConsoleEventHub) {
        self.hub = hub
    }

    func announce(_ proposal: PrivacyProposal) async {
        await hub.publish(
            .privacy,
            "待批准 · \(proposal.title) / awaiting approval",
            level: .notice,
            payload: [
                "proposalId": .string(proposal.id),
                "domain": .string(proposal.domain.rawValue),
                "action": .string(proposal.action.rawValue),
                "minutesLeft": .int(max(1, proposal.secondsLeft() / 60))
            ]
        )
        await deliverToNotificationCenter(proposal)
    }

    private func deliverToNotificationCenter(_ proposal: PrivacyProposal) async {
        let center = UNUserNotificationCenter.current()
        if !authorizationAttempted {
            authorizationAttempted = true
            // Denied or unsupported, the console event above still carries the
            // proposal, so the answer here is allowed to be no.
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = "POPOPX 需要你的确认 / POPOPX needs your confirmation"
        content.body = "\(proposal.title)\n\(proposal.detail)\n"
            + "15 分钟内未批准即失效 / unapproved proposals expire after 15 minutes"
        content.sound = .default
        content.categoryIdentifier = "ppx-privacy-proposal"
        content.userInfo = ["proposalId": proposal.id, "domain": proposal.domain.rawValue]
        let request = UNNotificationRequest(
            identifier: proposal.id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try? await center.add(request)
    }
}
