import SwiftUI
import AVFoundation
import LiveKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var contentViewModel = ContentViewModel.shared

    var body: some View {
        VStack {
            Button {
                Task {
                    if contentViewModel.isConnected {
                        await contentViewModel.disconnect()
                    } else {
                        await contentViewModel.connect()
                    }
                }
            } label: {
                Text(contentViewModel.isConnected ? "Connected" : "Tap to Connect")
            }
            .padding(.bottom, 20)

            Button {
                Task {
                    if contentViewModel.isPublished {
                        await contentViewModel.unpublishAudio()
                    } else {
                        await contentViewModel.publishAudio()
                    }
                }
            } label: {
                Text(contentViewModel.isPublished ? "Published" : "Tap to Publish")
            }
        }
        .padding()
        .onChange(of: scenePhase) { oldScenePhase, newScenePhase in
            contentViewModel.handleScenePhaseChange(to: newScenePhase)
        }
    }
}

#Preview {
    ContentView()
}
