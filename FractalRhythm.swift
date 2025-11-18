import SwiftUI
import SpriteKit
import AVFoundation

// MARK: - Data Model

/// A tiny description of a branch in the fractal tree.
/// Each branch knows its generation (distance from the trunk),
/// whether it should play a sound, and its start/end points for drawing.
struct FractalNode: Identifiable, Hashable {
    let id: UUID = UUID()
    let generation: Int
    var isActive: Bool
    let startPoint: CGPoint
    let endPoint: CGPoint
}

// MARK: - Audio

/// Instruments the game can use. Each has an optional sample name and a fallback tone.
private enum FractalInstrument: String, CaseIterable {
    case kick
    case snare
    case hihat
    case shaker

    /// Helpful colors that match the visual tree so kids can link sight + sound.
    var highlightColor: SKColor {
        switch self {
        case .kick: return .systemRed
        case .snare: return .systemBlue
        case .hihat: return .systemGreen
        case .shaker: return .systemOrange
        }
    }

    /// Simple "beep" frequencies used when no audio file is found.
    var fallbackFrequency: Double {
        switch self {
        case .kick: return 80
        case .snare: return 160
        case .hihat: return 400
        case .shaker: return 600
        }
    }

    /// Optional file name (without extension). You can drop matching WAV files in your bundle later.
    var sampleName: String { rawValue }
}

/// Delegate used to tell the SpriteKit scene when a branch fires so it can flash.
protocol FractalAudioEngineDelegate: AnyObject {
    func fractalAudioEngine(_ engine: FractalAudioEngine, didTrigger nodeID: UUID)
}

/// Handles the metronome and plays sounds for every active branch.
final class FractalAudioEngine {
    weak var delegate: FractalAudioEngineDelegate?

    /// 120 BPM means each quarter note is 0.5 s and each eighth note is 0.25 s.
    private let bpm: Double
    private let audioEngine = AVAudioEngine()
    private var players: [FractalInstrument: AVAudioPlayerNode] = [:]
    private var buffers: [FractalInstrument: AVAudioPCMBuffer] = [:]

    /// Smallest rhythm unit is an eighth note (3rd generation).
    /// Using a dispatch timer keeps timing tight without needing a full sequencer.
    private let subdivision: Int = 8 // eighth notes inside a 4/4 bar
    private var stepIndex: Int = 0
    private var timer: DispatchSourceTimer?

    /// Tracks which branches are active and their generation so we can schedule them.
    private var nodeStates: [UUID: Int] = [:]
    private var mutedNodes: Set<UUID> = []

    init(bpm: Double = 120) {
        self.bpm = bpm
        preparePlayers()
        startEngine()
        startTimer()
    }

    deinit {
        timer?.cancel()
        audioEngine.stop()
    }

    /// Register a node so the engine knows which generation it belongs to.
    func register(node: FractalNode) {
        nodeStates[node.id] = node.generation
        if !node.isActive {
            mutedNodes.insert(node.id)
        }
    }

    /// Toggle a node on/off when the player taps it.
    func setNode(_ nodeID: UUID, isActive: Bool) {
        if isActive {
            mutedNodes.remove(nodeID)
        } else {
            mutedNodes.insert(nodeID)
        }
    }

    // MARK: - Setup

    private func preparePlayers() {
        for instrument in FractalInstrument.allCases {
            let player = AVAudioPlayerNode()
            audioEngine.attach(player)
            players[instrument] = player

            let buffer = loadBuffer(for: instrument)
            buffers[instrument] = buffer
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
        }
    }

    private func startEngine() {
        do {
            try audioEngine.start()
        } catch {
            print("Audio engine failed: \(error.localizedDescription)")
        }
    }

    /// Uses a precise dispatch timer to tick every eighth note.
    private func startTimer() {
        // Every tick represents an eighth note (the smallest beat we need).
        // At 120 BPM: 60 / 120 = 0.5 seconds per quarter note, so an eighth is 0.25 seconds.
        let tickDuration = (60.0 / bpm) / 2.0 // eighth note length
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + tickDuration, repeating: tickDuration)
        timer.setEventHandler { [weak self] in
            self?.handleTick()
        }
        timer.resume()
        self.timer = timer
    }

    /// Converts generation -> instrument + rhythm interval.
    private func instrument(for generation: Int) -> FractalInstrument {
        // "Visual structure = Musical structure"
        // The farther a branch is from the trunk, the lighter the instrument becomes.
        switch generation {
        case 0: return .kick
        case 1: return .snare
        case 2: return .hihat
        default: return .shaker
        }
    }

    private func interval(for generation: Int) -> Int {
        // We divide the bar into 8 steps (eighth notes).
        // Generation 0 plays every 8th step (whole note), Generation 1 every 4th step (half note), etc.
        switch generation {
        case 0: return subdivision // whole note (play once per bar)
        case 1: return subdivision / 2 // half notes
        case 2: return subdivision / 4 // quarter notes
        default: return 1 // eighth notes and beyond
        }
    }

    // MARK: - Sequencing

    private func handleTick() {
        // Imagine an 8-slot loop like a clock. We move the hand one slot each tick.
        stepIndex = (stepIndex + 1) % subdivision
        for (nodeID, generation) in nodeStates {
            guard !mutedNodes.contains(nodeID) else { continue }
            let interval = max(1, interval(for: generation))
            if stepIndex % interval == 0 {
                let instrument = instrument(for: generation)
                play(instrument)
                delegate?.fractalAudioEngine(self, didTrigger: nodeID)
            }
        }
    }

    private func play(_ instrument: FractalInstrument) {
        guard let player = players[instrument], let buffer = buffers[instrument] else { return }
        if !audioEngine.isRunning {
            startEngine()
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts) {
            // no-op
        }
        player.play()
    }

    // MARK: - Buffer Creation

    private func loadBuffer(for instrument: FractalInstrument) -> AVAudioPCMBuffer {
        let sampleRate: Double = 44100
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        // Try to load a WAV from the bundle first.
        if let url = Bundle.main.url(forResource: instrument.sampleName, withExtension: "wav"),
           let file = try? AVAudioFile(forReading: url),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) {
            do {
                try file.read(into: buffer)
                return buffer
            } catch {
                print("Failed to read \(instrument.sampleName).wav, using fallback tone.\")
            }
        }

        // Fallback: create a tiny sine wave "beep" so the game always makes a sound.
        let duration: Double = 0.15
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let freq = instrument.fallbackFrequency
        let channels = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            channels[frame] = Float(sin(2.0 * .pi * freq * time) * 0.4)
        }
        return buffer
    }
}

// MARK: - SpriteKit Scene

/// A SpriteKit scene that draws the fractal tree and handles taps.
final class FractalTreeScene: SKScene, FractalAudioEngineDelegate {
    private let maxGeneration = 4
    private var nodes: [UUID: SKShapeNode] = [:]
    private var nodeData: [UUID: FractalNode] = [:]
    private let audioEngine = FractalAudioEngine()

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        audioEngine.delegate = self
        buildTree()
    }

    // MARK: - Tree Construction

    private func buildTree() {
        nodes.removeAll()
        nodeData.removeAll()

        let trunkLength = size.height * 0.18
        let start = CGPoint(x: size.width / 2, y: size.height * 0.15)
        let end = CGPoint(x: size.width / 2, y: size.height * 0.15 + trunkLength)
        spawnBranch(start: start, end: end, generation: 0)
    }

    @discardableResult
    private func spawnBranch(start: CGPoint, end: CGPoint, generation: Int) -> FractalNode {
        // Each branch is a mini record in our model so we can map it back to a sound.
        let node = FractalNode(generation: generation, isActive: true, startPoint: start, endPoint: end)
        draw(node: node)
        audioEngine.register(node: node)
        nodeData[node.id] = node

        // Recursively add two children until we reach the maximum depth.
        if generation < maxGeneration {
            let nextGen = generation + 1
            // Branches shrink and rotate to make the Pythagoras tree shape.
            let branchLength = distance(from: start, to: end) * 0.72
            let angleSpread: CGFloat = .pi / 6
            let baseAngle = atan2(end.y - start.y, end.x - start.x)

            let leftAngle = baseAngle + angleSpread
            let rightAngle = baseAngle - angleSpread
            let leftEnd = CGPoint(x: end.x + cos(leftAngle) * branchLength,
                                  y: end.y + sin(leftAngle) * branchLength)
            let rightEnd = CGPoint(x: end.x + cos(rightAngle) * branchLength,
                                   y: end.y + sin(rightAngle) * branchLength)

            spawnBranch(start: end, end: leftEnd, generation: nextGen)
            spawnBranch(start: end, end: rightEnd, generation: nextGen)
        }

        return node
    }

    private func draw(node: FractalNode) {
        let path = CGMutablePath()
        path.move(to: node.startPoint)
        path.addLine(to: node.endPoint)
        let shape = SKShapeNode(path: path)
        shape.lineWidth = max(1.5, 8 - CGFloat(node.generation) * 1.2)
        shape.strokeColor = color(for: node)
        shape.name = node.id.uuidString
        addChild(shape)
        nodes[node.id] = shape
    }

    private func color(for node: FractalNode) -> SKColor {
        switch node.generation {
        case 0: return SKColor.systemRed
        case 1: return SKColor.systemBlue
        case 2: return SKColor.systemGreen
        case 3: return SKColor.systemOrange
        default: return SKColor.systemPurple
        }
    }

    // MARK: - Interaction

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self), let tapped = nodes.values.first(where: { $0.contains(location) }) else {
            return
        }
        guard let id = nodes.first(where: { $0.value == tapped })?.key, var data = nodeData[id] else { return }
        // Tap = prune or grow the rhythm. Off branches turn transparent.
        data.isActive.toggle()
        nodeData[id] = data
        tapped.alpha = data.isActive ? 1.0 : 0.25
        audioEngine.setNode(id, isActive: data.isActive)
    }

    // MARK: - Audio Delegate

    func fractalAudioEngine(_ engine: FractalAudioEngine, didTrigger nodeID: UUID) {
        guard let shape = nodes[nodeID], let data = nodeData[nodeID] else { return }
        let flashColor = color(for: data)
        let flash = SKAction.sequence([
            .run { shape.strokeColor = .white },
            .wait(forDuration: 0.08),
            .run { shape.strokeColor = flashColor }
        ])
        shape.run(flash)
    }

    // MARK: - Helpers

    private func distance(from: CGPoint, to: CGPoint) -> CGFloat {
        hypot(to.x - from.x, to.y - from.y)
    }
}

// MARK: - SwiftUI Wrapper

struct ContentView: View {
    var scene: SKScene {
        let scene = FractalTreeScene()
        scene.size = CGSize(width: 800, height: 600)
        scene.scaleMode = .resizeFill
        return scene
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("FractalRhythm")
                .font(.largeTitle.bold())
            Text("Every branch = a beat. Tap to prune or grow the rhythm!")
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            SpriteView(scene: scene)
                .frame(minWidth: 600, minHeight: 400)
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
            Text("Tempo: 120 BPM · Tree depth: 4 generations")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Preview (for SwiftUI canvas in Xcode)

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
