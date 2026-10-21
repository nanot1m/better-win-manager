import Cocoa
import CoreAudio
import AudioToolbox

/// Output and input devices, their volumes and mute, through the CoreAudio HAL, with change notifications.
final class SoundService {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
    }
    struct State: Equatable {
        var outputs: [Device] = []
        var inputs: [Device] = []
        var output: AudioDeviceID = 0
        var input: AudioDeviceID = 0
        var outputVolume: Float = 0
        var outputMuted = false
        var inputVolume: Float = 0
    }

    private(set) var state = State()
    var onChange: (() -> Void)?
    private var listening = false
    private var listenedDevices: [AudioDeviceID] = []
    private let queue = DispatchQueue.main

    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }

    func start() {
        guard !listening else { return }
        listening = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector, kAudioObjectPropertyScopeGlobal)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        refresh()
    }

    func stop() {
        guard listening else { return }
        listening = false
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector, kAudioObjectPropertyScopeGlobal)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
        }
        unlistenDevices()
    }

    // MARK: Reading

    func refresh() {
        var s = State()
        // Like Control Center: no hidden, virtual or aggregate devices; built-in first, then by transport and name.
        let all = deviceIDs().filter { !isHidden($0) && ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeUnknown].contains(transport($0)) }
            .sorted { (transportRank(transport($0)), name($0)) < (transportRank(transport($1)), name($1)) }
        s.outputs = all.filter { streams($0, kAudioObjectPropertyScopeOutput) > 0 }.map { Device(id: $0, name: name($0)) }
        s.inputs = all.filter { streams($0, kAudioObjectPropertyScopeInput) > 0 }.map { Device(id: $0, name: name($0)) }
        s.output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        s.input = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        s.outputVolume = volume(of: s.output, kAudioObjectPropertyScopeOutput)
        s.outputMuted = muted(s.output)
        s.inputVolume = volume(of: s.input, kAudioObjectPropertyScopeInput)
        listenDevices([s.output, s.input])
        guard s != state else { return }
        state = s
        onChange?()
    }

    private func listenDevices(_ ids: [AudioDeviceID]) {
        guard ids != listenedDevices else { return }
        unlistenDevices()
        for id in ids where id != 0 {
            for (selector, scope) in deviceSelectors {
                var addr = address(selector, scope)
                AudioObjectAddPropertyListenerBlock(id, &addr, queue, listener)
            }
        }
        listenedDevices = ids
    }

    private func unlistenDevices() {
        for id in listenedDevices where id != 0 {
            for (selector, scope) in deviceSelectors {
                var addr = address(selector, scope)
                AudioObjectRemovePropertyListenerBlock(id, &addr, queue, listener)
            }
        }
        listenedDevices = []
    }

    private var deviceSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] {
        [(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput),
         (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput),
         (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)]
    }

    // MARK: Writing

    func setOutputVolume(_ v: Float) { setVolume(min(1, max(0, v)), of: state.output, kAudioObjectPropertyScopeOutput); if v > 0, state.outputMuted { setMuted(false) } }
    func setInputVolume(_ v: Float) { setVolume(min(1, max(0, v)), of: state.input, kAudioObjectPropertyScopeInput) }
    func setMuted(_ m: Bool) {
        var value: UInt32 = m ? 1 : 0
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(state.output, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        refresh()
    }
    func setDefaultOutput(_ id: AudioDeviceID) { setDefault(kAudioHardwarePropertyDefaultOutputDevice, id) }
    func setDefaultInput(_ id: AudioDeviceID) { setDefault(kAudioHardwarePropertyDefaultInputDevice, id) }

    private func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var value = id
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value)
        refresh()
    }

    private func setVolume(_ v: Float, of id: AudioDeviceID, _ scope: AudioObjectPropertyScope) {
        guard id != 0 else { return }
        var value = v
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        if AudioObjectHasProperty(id, &addr), AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr {
            refresh()
            return
        }
        // Devices without a main volume: set each channel.
        for channel in 1...2 as ClosedRange<UInt32> {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: channel)
            if AudioObjectHasProperty(id, &a) { AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &value) }
        }
        refresh()
    }

    // MARK: HAL helpers

    private func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func deviceIDs() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func streams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private func transport(_ id: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return kAudioDeviceTransportTypeUnknown }
        return v
    }

    private func transportRank(_ t: UInt32) -> Int {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return 0
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return 1
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeThunderbolt: return 2
        case kAudioDeviceTransportTypeUSB: return 3
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 4
        case kAudioDeviceTransportTypeAirPlay: return 5
        default: return 6
        }
    }

    private func isHidden(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr), AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    private func name(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return "Device \(id)" }
        return v.takeRetainedValue() as String
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func volume(of id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Float {
        guard id != 0 else { return 0 }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        var v: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(id, &addr), AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        var sum: Float = 0, n: Float = 0
        for channel in 1...2 as ClosedRange<UInt32> {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: channel)
            var cv: Float = 0
            if AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cv) == noErr { sum += cv; n += 1 }
        }
        return n > 0 ? sum / n : 0
    }

    private func muted(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr), AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return false }
        return v != 0
    }

    /// Symbol for the current output level.
    var symbolName: String {
        if state.outputMuted || state.outputVolume == 0 { return "speaker.slash.fill" }
        if state.outputVolume < 0.34 { return "speaker.wave.1.fill" }
        if state.outputVolume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// The sound widget's popover: output volume and mute, output device, input volume, input device.
final class SoundPopover: NSViewController {
    private let service: SoundService
    private let popover = NSPopover()
    private let outputSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let inputSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteButton = NSButton(title: "", target: nil, action: nil)
    private let outputs = NSStackView()
    private let inputs = NSStackView()

    init(service: SoundService) {
        self.service = service
        super.init(nibName: nil, bundle: nil)
        popover.behavior = .transient
        popover.contentViewController = self
    }

    /// Called by the bar on every sound change; only redraws while visible.
    func refreshIfShown() { if popover.isShown { render() } }
    required init?(coder: NSCoder) { fatalError() }

    func toggle(relativeTo view: NSView) {
        if popover.isShown { popover.performClose(nil); return }
        service.refresh()
        render()
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        // The bar sits behind every app window; the popover must not inherit that.
        popover.contentViewController?.view.window?.level = .popUpMenu
    }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        func header(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .secondaryLabelColor
            return l
        }
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        outputSlider.target = self
        outputSlider.action = #selector(outputChanged)
        outputSlider.isContinuous = true
        inputSlider.target = self
        inputSlider.action = #selector(inputChanged)
        inputSlider.isContinuous = true
        let outRow = NSStackView(views: [muteButton, outputSlider])
        outRow.orientation = .horizontal
        outRow.spacing = 8
        let micIcon = NSImageView(image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Input")!)
        micIcon.contentTintColor = .labelColor
        let inRow = NSStackView(views: [micIcon, inputSlider])
        inRow.orientation = .horizontal
        inRow.spacing = 8
        for st in [outputs, inputs] {
            st.orientation = .vertical
            st.alignment = .leading
            st.spacing = 2
        }
        root.addArrangedSubview(header("Output"))
        root.addArrangedSubview(outRow)
        root.addArrangedSubview(outputs)
        root.addArrangedSubview(header("Input"))
        root.addArrangedSubview(inRow)
        root.addArrangedSubview(inputs)
        for r in [outRow, inRow, outputs, inputs] { r.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        root.widthAnchor.constraint(equalToConstant: 300).isActive = true
        view = root
    }

    private func render() {
        let s = service.state
        outputSlider.floatValue = s.outputVolume
        inputSlider.floatValue = s.inputVolume
        muteButton.image = NSImage(systemSymbolName: service.symbolName, accessibilityDescription: s.outputMuted ? "Unmute" : "Mute")
        fill(outputs, devices: s.outputs, selected: s.output, action: #selector(pickOutput(_:)))
        fill(inputs, devices: s.inputs, selected: s.input, action: #selector(pickInput(_:)))
    }

    private func fill(_ stack: NSStackView, devices: [SoundService.Device], selected: AudioDeviceID, action: Selector) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for d in devices {
            let b = NSButton(radioButtonWithTitle: d.name, target: self, action: action)
            b.state = d.id == selected ? .on : .off
            b.tag = Int(d.id)
            b.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(b)
        }
    }

    @objc private func toggleMute() { service.setMuted(!service.state.outputMuted) }
    @objc private func outputChanged() { service.setOutputVolume(outputSlider.floatValue) }
    @objc private func inputChanged() { service.setInputVolume(inputSlider.floatValue) }
    @objc private func pickOutput(_ b: NSButton) { service.setDefaultOutput(AudioDeviceID(b.tag)) }
    @objc private func pickInput(_ b: NSButton) { service.setDefaultInput(AudioDeviceID(b.tag)) }
}
