import UIKit

/// Dictation keyboard: records through the app's background session and types the
/// transcript into the focused text field, so the field never loses focus.
final class KeyboardViewController: UIInputViewController {
    private enum State {
        case checking, noSession, ready, starting, recording, transcribing
    }

    private var state = State.checking {
        didSet { render() }
    }

    private let observer = DarwinObserver()
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private var timeout: DispatchWorkItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        observer.observe(DictationBridge.alive) { [weak self] in
            MainActor.assumeIsolated { self?.sessionIsAlive() }
        }
        observer.observe(DictationBridge.recording) { [weak self] in
            MainActor.assumeIsolated { self?.recordingStarted() }
        }
        observer.observe(DictationBridge.done) { [weak self] in
            MainActor.assumeIsolated { self?.insertTranscript() }
        }
        observer.observe(DictationBridge.failed) { [weak self] in
            MainActor.assumeIsolated { self?.transcriptionFailed() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        checkSession()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton.isHidden = !needsInputModeSwitchKey
    }

    // MARK: - Session

    private func checkSession() {
        guard hasFullAccess else {
            state = .noSession
            statusLabel.text = "در تنظیمات کیبورد، Allow Full Access را روشن کنید."
            return
        }
        state = .checking
        DictationBridge.post(DictationBridge.ping)
        schedule(after: 0.6) { [weak self] in
            if self?.state == .checking { self?.state = .noSession }
        }
    }

    private func sessionIsAlive() {
        if state == .checking || state == .noSession {
            cancelTimeout()
            state = .ready
        }
    }

    @objc private func micTapped() {
        switch state {
        case .ready:
            state = .starting
            DictationBridge.post(DictationBridge.start)
            // No answer means the app was closed and the session is gone.
            schedule(after: 0.8) { [weak self] in
                if self?.state == .starting { self?.state = .noSession }
            }
        case .recording:
            state = .transcribing
            DictationBridge.post(DictationBridge.stop)
            schedule(after: 90) { [weak self] in
                if self?.state == .transcribing { self?.transcriptionFailed() }
            }
        case .noSession, .checking:
            openApp()
        case .starting, .transcribing:
            break
        }
    }

    private func recordingStarted() {
        guard state == .starting else { return }
        cancelTimeout()
        state = .recording
    }

    private func insertTranscript() {
        guard state == .transcribing else { return }
        cancelTimeout()
        if let text = UIPasteboard.general.string, !text.isEmpty {
            textDocumentProxy.insertText(text)
        }
        state = .ready
    }

    private func transcriptionFailed() {
        guard state == .transcribing else { return }
        cancelTimeout()
        state = .ready
        statusLabel.text = "متنی تشخیص داده نشد. دوباره امتحان کنید."
    }

    /// Extensions cannot call UIApplication.shared; the host's UIApplication is reached
    /// through the responder chain instead.
    private func openApp() {
        guard hasFullAccess else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(DictationBridge.sessionURL, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
        statusLabel.text = "اپ «گفتار به متن» را باز کنید و «شروع جلسه‌ی کیبورد» را بزنید."
    }

    private func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        cancelTimeout()
        let item = DispatchWorkItem(block: work)
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    // MARK: - UI

    private func render() {
        let title: String
        let symbol: String
        var tint = UIColor.systemBlue
        switch state {
        case .checking:
            title = "در حال اتصال…"; symbol = "ellipsis.circle"
        case .noSession:
            title = "شروع جلسه (یک بار باز شدن اپ)"; symbol = "arrow.up.forward.app"
        case .ready:
            title = "برای صحبت بزنید"; symbol = "mic.circle.fill"
        case .starting:
            title = "…"; symbol = "mic.circle"
        case .recording:
            title = "در حال ضبط، برای پایان بزنید"; symbol = "stop.circle.fill"; tint = .systemRed
        case .transcribing:
            title = "در حال تبدیل به متن…"; symbol = "waveform.circle"
        }
        statusLabel.text = title
        micButton.setImage(UIImage(systemName: symbol,
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 64)), for: .normal)
        micButton.tintColor = tint
        micButton.isEnabled = state != .transcribing && state != .starting
    }

    private func buildUI() {
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.semanticContentAttribute = .forceRightToLeft

        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let space = keyButton(title: "فاصله") { $0.textDocumentProxy.insertText(" ") }
        let backspace = keyButton(symbol: "delete.left") { $0.textDocumentProxy.deleteBackward() }
        let newline = keyButton(symbol: "return") { $0.textDocumentProxy.insertText("\n") }

        let bottomRow = UIStackView(arrangedSubviews: [globeButton, space, backspace, newline])
        bottomRow.spacing = 8
        bottomRow.distribution = .fill
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [globeButton, backspace, newline] {
            view.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [statusLabel, micButton, bottomRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            bottomRow.heightAnchor.constraint(equalToConstant: 42),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 230)
        height.priority = .defaultHigh
        height.isActive = true
        render()
    }

    private func keyButton(title: String? = nil, symbol: String? = nil,
                           action: @escaping (KeyboardViewController) -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        if let symbol { config.image = UIImage(systemName: symbol) }
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
            if let self { action(self) }
        })
        return button
    }
}
