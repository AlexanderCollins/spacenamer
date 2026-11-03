import AppKit
import SpaceNamerCore

/// Says when an agent finishes, if the user has asked: its desktop's name pops up green
/// where the switch pill shows, and their chosen sound plays. Agents finishing together
/// get one sound, and the pop-up for the latest.
@MainActor
final class FinishAlerts {
    private unowned let model: AppModel
    private let hud: HUDController
    private let isMissionControlUp: () -> Bool
    private var soundPlayedAt = Date.distantPast
    private static let soundGap: TimeInterval = 1.5

    init(model: AppModel, hud: HUDController, isMissionControlUp: @escaping () -> Bool) {
        self.model = model
        self.hud = hud
        self.isMissionControlUp = isMissionControlUp
    }

    func agentFinished(_ session: AgentSession) {
        let preferences = model.preferences
        let space = session.space.flatMap(model.snapshot.space(forKey:))
        alert(for: space, chat: session.chat?.title, popUp: preferences.finishPopUp, sound: preferences.finishSound)
    }

    /// Both, for the current desktop, to try them out.
    func preview() {
        soundPlayedAt = .distantPast
        alert(for: model.snapshot.current, chat: nil, popUp: true, sound: true)
    }

    private func alert(for space: Space?, chat: String?, popUp: Bool, sound: Bool) {
        if sound, Date().timeIntervalSince(soundPlayedAt) > Self.soundGap {
            soundPlayedAt = Date()
            AlertSound.play(model.preferences.finishSoundName)
        }
        // Mission Control's bar shows it already, and the pill would sit on the bar.
        guard popUp, !isMissionControlUp() else { return }
        hud.showFinished(
            title: space.map(model.title(for:)) ?? chat ?? "An agent",
            detail: "finished",
            space: space,
            display: space.flatMap { model.snapshot.display(withID: $0.displayID) },
            on: space.flatMap { model.screen(for: $0.displayID) },
            position: model.preferences.hudPosition
        )
    }
}
