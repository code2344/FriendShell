import AppKit
import Foundation

let consentMessage = "Only run this if you trust the person helping you. They will be able to run terminal commands as your user account."

final class HelperClient: NSObject, URLSessionWebSocketDelegate {
  private let code: String
  private let serverURL: URL
  private let onStatus: (String) -> Void
  private let onAlert: (String, String) -> Void
  private let onDisconnect: () -> Void
  private let process = Process()
  private let stdinPipe = Pipe()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()
  private var webSocket: URLSessionWebSocketTask?
  private var isDisconnecting = false

  init(code: String, serverURL: URL, onStatus: @escaping (String) -> Void, onAlert: @escaping (String, String) -> Void, onDisconnect: @escaping () -> Void) {
    self.code = code
    self.serverURL = serverURL
    self.onStatus = onStatus
    self.onAlert = onAlert
    self.onDisconnect = onDisconnect
  }

  func start() {
    setStatus("Connecting to \(serverURL.absoluteString)...")
    startShell()
    connectWebSocket()
  }

  func disconnect() {
    guard !isDisconnecting else { return }
    isDisconnecting = true
    setStatus("Disconnected.")
    webSocket?.send(.string("{\"type\":\"disconnect\"}")) { _ in }
    webSocket?.cancel(with: .normalClosure, reason: nil)

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil

    if process.isRunning {
      process.terminate()
    }

    DispatchQueue.main.async { self.onDisconnect() }
  }

  private func startShell() {
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.send(handle.availableData)
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      self?.send(handle.availableData)
    }

    do {
      try process.run()
    } catch {
      setStatus("Could not start /bin/zsh -i: \(error.localizedDescription)")
      disconnect()
    }
  }

  private func connectWebSocket() {
    let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    let task = session.webSocketTask(with: serverURL)
    webSocket = task
    task.resume()

    let registration = "{\"role\":\"helper\",\"code\":\"\(code)\"}"
    task.send(.string(registration)) { [weak self] error in
      if let error {
        self?.setStatus("Registration failed: \(error.localizedDescription)")
      } else {
        self?.setStatus("Waiting for dashboard. Code: \(self?.code ?? "")")
      }
    }

    receiveNextMessage()
  }

  private func receiveNextMessage() {
    webSocket?.receive { [weak self] result in
      guard let self else { return }

      switch result {
      case .success(.data(let data)):
        self.stdinPipe.fileHandleForWriting.write(self.normalizedTerminalInput(data))
        self.receiveNextMessage()
      case .success(.string(let text)):
        self.handleControlMessage(text)
        self.receiveNextMessage()
      case .success:
        self.receiveNextMessage()
      case .failure(let error):
        if !self.isDisconnecting {
          self.setStatus("WebSocket closed: \(error.localizedDescription)")
          self.disconnect()
        }
      }
    }
  }

  private func handleControlMessage(_ text: String) {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else { return }

    if type == "disconnect" {
      disconnect()
    } else if type == "paired" {
      setStatus("Dashboard connected.")
    } else if type == "alert", let message = json["message"] as? String {
      let kind = (json["kind"] as? String) == "notification" ? "notification" : "alert"
      DispatchQueue.main.async { self.onAlert(kind, message) }
    } else if type == "error", let message = json["message"] as? String {
      setStatus(message)
    }
  }

  private func normalizedTerminalInput(_ data: Data) -> Data {
    Data(data.map { $0 == 13 ? 10 : $0 })
  }

  private func send(_ data: Data) {
    guard !data.isEmpty, let webSocket else { return }
    webSocket.send(.data(data)) { [weak self] error in
      if let error {
        self?.setStatus("Send failed: \(error.localizedDescription)")
      }
    }
  }

  private func setStatus(_ message: String) {
    DispatchQueue.main.async { self.onStatus(message) }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    disconnect()
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private let code = String(format: "%06d", Int.random(in: 0...999_999))
  private var window: NSWindow!
  private var statusLabel: NSTextField!
  private var startButton: NSButton!
  private var disconnectButton: NSButton!
  private var serverField: NSTextField!
  private var client: HelperClient?

  func applicationDidFinishLaunching(_ notification: Notification) {
    buildWindow()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "FriendShell Helper"
    window.center()

    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
    content.translatesAutoresizingMaskIntoConstraints = false

    let warning = NSTextField(labelWithString: consentMessage)
    warning.font = .systemFont(ofSize: 16, weight: .semibold)
    warning.maximumNumberOfLines = 0
    warning.lineBreakMode = .byWordWrapping

    let codeLabel = NSTextField(labelWithString: "Session code: \(code)")
    codeLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold)

    let serverLabel = NSTextField(labelWithString: "Server WebSocket URL")
    serverField = NSTextField(string: defaultServerURL())
    serverField.placeholderString = "wss://your-domain.example"

    statusLabel = NSTextField(labelWithString: "Not connected.")
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.maximumNumberOfLines = 0

    startButton = NSButton(title: "Start", target: self, action: #selector(startSession))
    startButton.bezelStyle = .rounded

    disconnectButton = NSButton(title: "Disconnect", target: self, action: #selector(disconnectSession))
    disconnectButton.bezelStyle = .rounded
    disconnectButton.isEnabled = false

    let buttons = NSStackView(views: [startButton, disconnectButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    content.addArrangedSubview(warning)
    content.addArrangedSubview(codeLabel)
    content.addArrangedSubview(serverLabel)
    content.addArrangedSubview(serverField)
    content.addArrangedSubview(statusLabel)
    content.addArrangedSubview(buttons)

    window.contentView = NSView()
    window.contentView?.addSubview(content)

    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
      content.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
      content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
      warning.widthAnchor.constraint(equalToConstant: 512),
      statusLabel.widthAnchor.constraint(equalToConstant: 512),
      serverField.widthAnchor.constraint(equalToConstant: 512)
    ])

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func startSession() {
    guard let url = URL(string: serverField.stringValue), url.scheme == "ws" || url.scheme == "wss" else {
      statusLabel.stringValue = "Enter a valid ws:// or wss:// URL."
      return
    }

    startButton.isEnabled = false
    disconnectButton.isEnabled = true
    serverField.isEnabled = false

    client = HelperClient(
      code: code,
      serverURL: url,
      onStatus: { [weak self] message in self?.statusLabel.stringValue = message },
      onAlert: { [weak self] kind, message in self?.showOsascriptMessage(kind: kind, message: message) },
      onDisconnect: { [weak self] in self?.resetControls() }
    )
    client?.start()
  }

  @objc private func disconnectSession() {
    client?.disconnect()
  }

  private func showOsascriptMessage(kind: String, message: String) {
    let script: String
    if kind == "notification" {
      script = "display notification " + appleScriptString(message) + " with title " + appleScriptString("FriendShell")
    } else {
      script = "display dialog " + appleScriptString(message) + " with title " + appleScriptString("FriendShell") + " buttons {\"OK\"} default button \"OK\""
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
  }

  private func appleScriptString(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"" + escaped + "\""
  }

  private func resetControls() {
    startButton.isEnabled = true
    disconnectButton.isEnabled = false
    serverField.isEnabled = true
    client = nil
  }

  private func defaultServerURL() -> String {
    ProcessInfo.processInfo.environment["FRIENDSHELL_SERVER"] ?? "ws://localhost:3000"
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
