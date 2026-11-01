import SwiftUI

@main
struct IPACheckApp: App {
    var body: some Scene {
        WindowGroup { CounterView() }
    }
}

struct CounterView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("Приложение работает")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Тест установки IPA на iPhone")
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("counter")
            Button("Нажми меня") { count += 1 }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Сбросить") { count = 0 }
                .foregroundStyle(.secondary)
        }
        .padding(28)
    }
}
