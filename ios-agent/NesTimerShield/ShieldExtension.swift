import ManagedSettings
import ManagedSettingsUI
import NesTimerCore
import UIKit

/// The text on Apple's shield. The reason is written to the App Group by ManagedShield.
final class ShieldExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration { make() }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { make() }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { make() }

    private func make() -> ShieldConfiguration {
        let reason = AppGroup.read(ShieldReason.self, from: AppGroup.shieldReasonURL)
        let subtitle: String
        switch reason {
        case .downtime(let until): subtitle = "Downtime until \(until)"
        case .deviceCapReached: subtitle = "This iPhone's daily limit is reached"
        case .timeExpired, .none: subtitle = "Today's screen time is used up"
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            icon: UIImage(systemName: "hourglass"),
            title: .init(text: "NesTimer", color: .label),
            subtitle: .init(text: subtitle + "\n\nOpen NesTimer to enter a code", color: .secondaryLabel),
            primaryButtonLabel: .init(text: "OK", color: .white),
            primaryButtonBackgroundColor: .systemIndigo
        )
    }
}
