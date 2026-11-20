import AVFoundation
import SwiftUI
import UIKit

struct MacSetupGuide: View {
    @ObservedObject var connection: PhoneConnection
    let close: () -> Void

    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var player: AVPlayer?
    @State private var sharing = false
    @State private var wantsPlayback = true
    @State private var ended = false
    @State private var step = 0
    @State private var showShareError = false

    private let installer = Bundle.main.url(forResource: "AirPointer Remote for Mac", withExtension: "dmg")
    private let stillTimes = [1.0, 6.5, 10.5]
    private let directions = [String(localized: "Choose your Mac in AirDrop."), String(localized: "Drag AirPointer Remote into Applications."),
                              String(localized: "Open the Mac app, then select your Mac on iPhone.")]
    private var manual: Bool { reduceMotion || voiceOver || player == nil }
    private var nearbyMac: NearbyMac? { connection.nearby.count == 1 ? connection.nearby.first : nil }
    private var connectTitle: String {
        if connection.connected { return String(localized: "Return to Controls") }
        if connection.connecting { return String(localized: "Continue Connecting") }
        if let nearbyMac { return String(localized: "Connect to \(nearbyMac.name)") }
        return String(localized: "Already installed? Choose Your Mac")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let player {
                    PlayerSurface(player: player)
                        .aspectRatio(1000.0 / 660, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                }
                if manual {
                    Text(directions[step]).font(.headline)
                    HStack {
                        Button("Previous") { selectStep(step - 1) }.disabled(step == 0)
                        Spacer()
                        Text("\(step + 1) of 3").foregroundStyle(.secondary)
                        Spacer()
                        Button("Next") { selectStep(step + 1) }.disabled(step == 2)
                    }
                } else {
                    Button {
                        if ended { player?.seek(to: .zero); ended = false }
                        wantsPlayback.toggle()
                        updatePlayback()
                    } label: {
                        Label(ended ? String(localized: "Replay tutorial") : wantsPlayback ? String(localized: "Pause tutorial") : String(localized: "Play tutorial"),
                              systemImage: ended ? "arrow.counterclockwise" : wantsPlayback ? "pause.circle" : "play.circle")
                    }
                }
                Text("Send the installer to your Mac using AirDrop, then open it from Downloads.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    player?.pause()
                    sharing = true
                } label: {
                    Label("Share Mac Installer", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(installer == nil)
                Text(installer == nil ? String(localized: "The installer is unavailable in this version.") : String(localized: "Requires macOS 14 or later."))
                    .font(.footnote).foregroundStyle(.secondary)
                Button(connectTitle) {
                    if !connection.connected, !connection.connecting, let nearbyMac { connection.connect(nearbyMac) }
                    close()
                }.frame(minHeight: 44)
            }
            .padding(.horizontal).padding(.top, 12).background(.regularMaterial)
        }
        .navigationTitle("Mac Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: close) } }
        .task {
            if player == nil, let url = Bundle.main.url(forResource: "MacSetupGuide", withExtension: "mp4") {
                let movie = AVPlayer()
                movie.isMuted = true
                if #available(iOS 27.0, *) {
                    await withCheckedContinuation { continuation in
                        movie.setDisconnectedFromSystemAudio(true) { continuation.resume() }
                    }
                    guard !Task.isCancelled else { return }
                } else {
                    // On older systems a muted player can still activate the shared session.
                    let audio = AVAudioSession.sharedInstance()
                    if audio.category != .ambient && !audio.categoryOptions.contains(.mixWithOthers) {
                        do { try audio.setCategory(.ambient, mode: .default) }
                        catch { return } // Keep the text guide available if mixing cannot be configured.
                    }
                }
                movie.replaceCurrentItem(with: AVPlayerItem(url: url))
                player = movie
            }
            if manual { selectStep(step) }
            updatePlayback()
        }
        .onDisappear { player?.pause() }
        .onChange(of: scene) { _, _ in updatePlayback() }
        .onChange(of: manual) { _, value in
            if value { selectStep(step) }
            updatePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { event in
            guard let item = event.object as? AVPlayerItem, item === player?.currentItem else { return }
            wantsPlayback = false
            ended = true
        }
        .sheet(isPresented: $sharing, onDismiss: updatePlayback) {
            if let installer {
                InstallerShare(url: installer) { completed, failed in
                    if completed {
                        ended = false
                        wantsPlayback = true
                        if manual { selectStep(1) } else { seek(4.0) }
                    }
                    showShareError = failed
                    sharing = false
                }
            }
        }
        .alert("Couldn’t share the installer", isPresented: $showShareError) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try sharing the installer again.") }
    }

    private func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func selectStep(_ index: Int) {
        step = index
        seek(stillTimes[index])
    }

    private func updatePlayback() {
        if scene == .active && !sharing && !manual && wantsPlayback { player?.play() }
        else { player?.pause() }
    }
}

private final class MovieSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> MovieSurface {
        let view = MovieSurface()
        view.backgroundColor = .black
        (view.layer as? AVPlayerLayer)?.player = player
        return view
    }
    func updateUIView(_ view: MovieSurface, context: Context) {}
}

private struct InstallerShare: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool, Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            DispatchQueue.main.async { completion(completed && error == nil, error != nil) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
