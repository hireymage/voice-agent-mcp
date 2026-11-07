import CarPlay

/// What the car shows. Never the conversation itself: in CarPlay the agent is speech in both directions.
enum CarVoiceState: String, CaseIterable {
    case listening, thinking, speaking, problem

    init(phase: ConversationModel.Phase, last: ChatItem?) {
        if last?.kind == .error {
            self = .problem
            return
        }
        switch phase {
        case .idle, .listening, .hearing: self = .listening
        case .speaking: self = .speaking
        case .transcribing, .preparing, .thinking: self = .thinking
        }
    }

    var template: CPVoiceControlState {
        let (title, symbol): (String, String)
        switch self {
        case .listening: (title, symbol) = (tr("Listening"), "waveform")
        case .thinking: (title, symbol) = (tr("Thinking"), "ellipsis")
        case .speaking: (title, symbol) = (tr("Speaking"), "speaker.wave.2.fill")
        case .problem: (title, symbol) = (tr("Problem, details in the app"), "exclamationmark.triangle.fill")
        }
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 80))
        return CPVoiceControlState(identifier: rawValue, titleVariants: [title], image: image, repeats: false)
    }
}

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// The open microphone keeps the car's music off, so a conversation nobody is using ends itself.
    private static let idleLimit: TimeInterval = 60

    private let conversation = AppModel.conversation
    private var interfaceController: CPInterfaceController?
    private var voice: CPVoiceControlTemplate?
    private var watcher: Task<Void, Never>?

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let talk = CPListItem(text: tr("Talk"), detailText: nil, image: UIImage(systemName: "mic.fill"))
        talk.handler = { [weak self] _, done in
            self?.startTalking()
            done()
        }
        let root = CPListTemplate(title: "Voice Agent", sections: [CPListSection(items: [talk])])
        interfaceController.setRootTemplate(root, animated: false, completion: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController) {
        stopWatching()
        conversation.endCarSession()
        self.interfaceController = nil
    }

    /// Opening the app in the car starts the conversation, without a tap.
    func sceneDidBecomeActive(_ scene: UIScene) {
        startTalking()
    }

    private func startTalking() {
        guard let interfaceController, voice == nil else { return }
        let template = CPVoiceControlTemplate(voiceControlStates: CarVoiceState.allCases.map(\.template))
        if #available(iOS 26.4, *) {
            template.trailingNavigationBarButtons = [CPBarButton(title: tr("End")) { [weak self] _ in self?.endTalking() }]
        }
        voice = template
        interfaceController.presentTemplate(template, animated: true) { [weak self] presented, _ in
            guard let self else { return }
            guard presented else {
                self.voice = nil
                return
            }
            self.conversation.startCarSession()
            self.watch(template)
        }
    }

    private func endTalking() {
        stopWatching()
        conversation.endCarSession()
        interfaceController?.dismissTemplate(animated: true, completion: nil)
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        voice = nil
    }

    /// Polled, not observed: the template ignores state changes that come too quickly, so a change has to be retried.
    private func watch(_ template: CPVoiceControlTemplate) {
        watcher = Task { [weak self] in
            var quietSince = Date()
            while !Task.isCancelled, let self {
                let state = CarVoiceState(phase: self.conversation.phase, last: self.conversation.items.last)
                if template.activeStateIdentifier != state.rawValue {
                    template.activateVoiceControlState(withIdentifier: state.rawValue)
                }
                if self.conversation.phase != .listening {
                    quietSince = Date()
                } else if Date().timeIntervalSince(quietSince) > Self.idleLimit {
                    self.endTalking()
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}
