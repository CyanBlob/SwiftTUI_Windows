import Foundation
#if os(macOS)
    import AppKit
#elseif os(Windows)
    import WinSDK
#endif

public class Application {
    private let node: Node
    private let window: Window
    private let control: Control
    private let renderer: Renderer

    private let runLoopType: RunLoopType

    private var arrowKeyParser = ArrowKeyParser()

    private var invalidatedNodes: [Node] = []
    private var updateScheduled = false

    #if os(Windows)
        private static var currentApplication: Application?
        private var inputBuffer: [UInt8] = []
        private var inputThread: Thread?
        private var shouldStopInputThread = false
        private var inputHandle: HANDLE?
        private let inputQueue = DispatchQueue(label: "com.swiftui.input")
    #endif

    public init<I: View>(rootView: I, runLoopType: RunLoopType = .dispatch) {
        self.runLoopType = runLoopType

        node = Node(view: VStack(content: rootView).view)
        node.build()

        control = node.control!

        window = Window()
        window.addControl(control)

        window.firstResponder = control.firstSelectableElement
        window.firstResponder?.becomeFirstResponder()

        renderer = Renderer(layer: window.layer)
        window.layer.renderer = renderer

        node.application = self
        renderer.application = self

        #if os(Windows)
            Application.currentApplication = self
            inputHandle = GetStdHandle(STD_INPUT_HANDLE)
        #endif
    }

    var stdInSource: DispatchSourceRead?

    public enum RunLoopType {
        /// The default option, using Dispatch for the main run loop.
        case dispatch

        #if os(macOS)
            /// This creates and runs an NSApplication with an associated run loop. This allows you
            /// e.g. to open NSWindows running simultaneously to the terminal app. This requires macOS
            /// and AppKit.
            case cocoa
        #endif
    }

    public func start() {
        #if os(macOS)
            setInputMode()
        #elseif os(Windows)
            guard let inputHandle = inputHandle else { return }
            var mode: DWORD = 0
            GetConsoleMode(inputHandle, &mode)
            mode &= ~(DWORD(ENABLE_ECHO_INPUT) | DWORD(ENABLE_LINE_INPUT))
            SetConsoleMode(inputHandle, mode)
        #endif

        updateWindowSize()
        control.layout(size: window.layer.frame.size)
        renderer.draw()

        #if os(macOS)
            let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
            stdInSource.setEventHandler(qos: .default, flags: [], handler: handleInput)
            stdInSource.resume()
            self.stdInSource = stdInSource
        #elseif os(Windows)
            // Windows-specific input handling
            inputThread = Thread { [weak self] in
                guard let self = self,
                      let inputHandle = self.inputHandle else { return }

                while !self.shouldStopInputThread {
                    var inputRecord = INPUT_RECORD()
                    var eventsRead: DWORD = 0

                    if ReadConsoleInputW(inputHandle, &inputRecord, 1, &eventsRead) {
                        if eventsRead > 0 {
                            switch UInt16(inputRecord.EventType) {
                            case UInt16(KEY_EVENT):
                                let keyEvent = inputRecord.Event.KeyEvent
                                if keyEvent.bKeyDown != false {
                                    self.inputQueue.async {
                                        if keyEvent.wVirtualKeyCode == UInt16(VK_ESCAPE) {
                                            // Handle escape sequence
                                            self.inputBuffer.append(0x1B) // ESC
                                            self.checkEscapeSequence()
                                        } else if keyEvent.wVirtualKeyCode == UInt16(VK_RETURN) {
                                            // Handle enter key
                                            DispatchQueue.main.async {
                                                self.handleInput("\n")
                                            }
                                        } else if keyEvent.wVirtualKeyCode == UInt16(VK_BACK) {
                                            // Handle backspace
                                            DispatchQueue.main.async {
                                                self.handleInput("\u{8}")
                                            }
                                        } else if keyEvent.wVirtualKeyCode == UInt16(VK_SPACE) {
                                            // Handle space
                                            DispatchQueue.main.async {
                                                self.handleInput(" ")
                                            }
                                        } else if keyEvent.wVirtualKeyCode >= UInt16(0x41) && keyEvent.wVirtualKeyCode <= UInt16(0x5A) {
                                            // Handle letters (A-Z)
                                            if let scalar = UnicodeScalar(UInt32(keyEvent.wVirtualKeyCode + 32)) {
                                                let char = Character(scalar)
                                                DispatchQueue.main.async {
                                                    self.handleInput(String(char))
                                                }
                                            }
                                        } else if keyEvent.wVirtualKeyCode >= UInt16(0x30) && keyEvent.wVirtualKeyCode <= UInt16(0x39) {
                                            // Handle numbers (0-9)
                                            if let scalar = UnicodeScalar(UInt32(keyEvent.wVirtualKeyCode)) {
                                                let char = Character(scalar)
                                                DispatchQueue.main.async {
                                                    self.handleInput(String(char))
                                                }
                                            }
                                        }

                                        else if keyEvent.wVirtualKeyCode == UInt16(VK_UP) {
                                            self.handleInput("\u{1B}[A")
                                        }
                                        else if keyEvent.wVirtualKeyCode == UInt16(VK_DOWN) {
                                            self.handleInput("\u{1B}[B")
                                        }
                                        else if keyEvent.wVirtualKeyCode == UInt16(VK_RIGHT) {
                                            self.handleInput("\u{1B}[C")
                                        }
                                        else if keyEvent.wVirtualKeyCode == UInt16(VK_LEFT) {
                                            self.handleInput("\u{1B}[D")
                                        }
                                    }
                                }
                            default:
                                break
                            }
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.01) // Prevent busy waiting
                }
            }
            inputThread?.start()
        #endif

        #if os(macOS)
            let sigWinChSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
            sigWinChSource.setEventHandler(qos: .default, flags: [], handler: handleWindowSizeChange)
            sigWinChSource.resume()

            signal(SIGINT, SIG_IGN)
            let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigIntSource.setEventHandler(qos: .default, flags: [], handler: stop)
            sigIntSource.resume()
        #elseif os(Windows)
            // Windows-specific signal handling
            let handler: PHANDLER_ROUTINE = { signal in
                if signal == CTRL_C_EVENT || signal == CTRL_BREAK_EVENT {
                    DispatchQueue.main.async {
                        Application.currentApplication?.stop()
                    }
                }
                return WindowsBool(true)
            }
            _ = SetConsoleCtrlHandler(handler, true)
        #endif

        switch runLoopType {
        case .dispatch:
            dispatchMain()
        #if os(macOS)
            case .cocoa:
                NSApplication.shared.setActivationPolicy(.accessory)
                NSApplication.shared.run()
        #endif
        }
    }

    #if os(Windows)
        private func checkEscapeSequence() {
            guard let inputHandle = inputHandle else { return }
            // Read more input to complete the escape sequence
            var inputRecord = INPUT_RECORD()
            var eventsRead: DWORD = 0

            if ReadConsoleInputW(inputHandle, &inputRecord, 1, &eventsRead) {
                if eventsRead > 0, UInt16(inputRecord.EventType) == UInt16(KEY_EVENT) {
                    let keyEvent = inputRecord.Event.KeyEvent
                    if keyEvent.bKeyDown != false {
                        print("Key: \(keyEvent.wVirtualKeyCode)")
                        switch keyEvent.wVirtualKeyCode {
                        case UInt16(VK_UP):
                            handleInput("\u{1B}[A")
                        case UInt16(VK_DOWN):
                            handleInput("\u{1B}[B")
                        case UInt16(VK_RIGHT):
                            handleInput("\u{1B}[C")
                        case UInt16(VK_LEFT):
                            handleInput("\u{1B}[D")
                        default:
                            break
                        }
                    }
                }
            }
        }
    #endif

    private func handleInput(_ input: String) {
        for char in input {
            if arrowKeyParser.parse(character: char) {
                guard let key = arrowKeyParser.arrowKey else { continue }
                arrowKeyParser.arrowKey = nil
                if key == .down {
                    if let next = window.firstResponder?.selectableElement(below: 0) {
                        window.firstResponder?.resignFirstResponder()
                        window.firstResponder = next
                        window.firstResponder?.becomeFirstResponder()
                    }
                } else if key == .up {
                    if let next = window.firstResponder?.selectableElement(above: 0) {
                        window.firstResponder?.resignFirstResponder()
                        window.firstResponder = next
                        window.firstResponder?.becomeFirstResponder()
                    }
                } else if key == .right {
                    if let next = window.firstResponder?.selectableElement(rightOf: 0) {
                        window.firstResponder?.resignFirstResponder()
                        window.firstResponder = next
                        window.firstResponder?.becomeFirstResponder()
                    }
                } else if key == .left {
                    if let next = window.firstResponder?.selectableElement(leftOf: 0) {
                        window.firstResponder?.resignFirstResponder()
                        window.firstResponder = next
                        window.firstResponder?.becomeFirstResponder()
                    }
                }
            } else if char == ASCII.EOT {
                stop()
            } else {
                window.firstResponder?.handleEvent(char)
            }
        }
    }

    func invalidateNode(_ node: Node) {
        invalidatedNodes.append(node)
        scheduleUpdate()
    }

    func scheduleUpdate() {
        if !updateScheduled {
            DispatchQueue.main.async { self.update() }
            updateScheduled = true
        }
    }

    private func update() {
        updateScheduled = false

        for node in invalidatedNodes {
            node.update(using: node.view)
        }
        invalidatedNodes = []

        control.layout(size: window.layer.frame.size)
        renderer.update()
    }

    private func handleWindowSizeChange() {
        updateWindowSize()
        control.layer.invalidate()
        update()
    }

    private func updateWindowSize() {
        #if os(macOS)
            var size = winsize()
            guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
                  size.ws_col > 0, size.ws_row > 0
            else {
                assertionFailure("Could not get window size")
                return
            }
            window.layer.frame.size = Size(width: Extended(Int(size.ws_col)), height: Extended(Int(size.ws_row)))
        #elseif os(Windows)
            let handle = GetStdHandle(STD_OUTPUT_HANDLE)
            var info = CONSOLE_SCREEN_BUFFER_INFO()
            guard GetConsoleScreenBufferInfo(handle, &info) else {
                assertionFailure("Could not get window size")
                return
            }
            window.layer.frame.size = Size(
                width: Extended(Int(info.srWindow.Right - info.srWindow.Left + 1)),
                height: Extended(Int(info.srWindow.Bottom - info.srWindow.Top + 1))
            )
        #endif
        renderer.setCache()
    }

    private func stop() {
        #if os(Windows)
            shouldStopInputThread = true
            // Wait for the input thread to finish
            while inputThread?.isExecuting == true {
                Thread.sleep(forTimeInterval: 0.01)
            }
        #endif
        renderer.stop()
        resetInputMode()
        exit(0)
    }

    private func resetInputMode() {
        #if os(macOS)
            var tattr = termios()
            tcgetattr(STDIN_FILENO, &tattr)
            tattr.c_lflag |= tcflag_t(ECHO | ICANON)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
        #elseif os(Windows)
            let handle = GetStdHandle(STD_INPUT_HANDLE)
            var mode: DWORD = 0
            GetConsoleMode(handle, &mode)
            mode |= (DWORD(ENABLE_ECHO_INPUT) | DWORD(ENABLE_LINE_INPUT))
            SetConsoleMode(handle, mode)
        #endif
    }
}
