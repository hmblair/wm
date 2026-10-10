import Foundation

// A behavior of the daemon that the user can turn on and off. The raw value is
// the feature's key in the features table of config.toml and in the daemon's
// lock file.
enum Feature: String, CaseIterable, CodingKey {
    case tiling
    case focusFollowsMouse = "focus_follows_mouse"
    case focusBorder = "focus_border"

    var title: String {
        switch self {
        case .tiling:            return "Tiling"
        case .focusFollowsMouse: return "Focus Follows Mouse"
        case .focusBorder:       return "Focus Border"
        }
    }

    var isEnabledByDefault: Bool {
        switch self {
        case .tiling, .focusFollowsMouse: return true
        case .focusBorder:                return false
        }
    }

    static let enabledByDefault = Set(allCases.filter { $0.isEnabledByDefault })
}

// Returns the features that the config's features table turns on. A feature
// with a missing or malformed field keeps its default.
func decodeFeatures(from container: KeyedDecodingContainer<Feature>) -> Set<Feature> {
    return Set(Feature.allCases.filter { feature in
        (try? container.decode(Bool.self, forKey: feature)) ?? feature.isEnabledByDefault
    })
}

// The features that are on now. The daemon sets them from the config at start
// and on each config reload. The menu bar changes them and the config together.
var enabledFeatures: Set<Feature> = []

func isEnabled(_ feature: Feature) -> Bool {
    return enabledFeatures.contains(feature)
}

// Turns a feature on or off in the running daemon.
func setFeature(_ feature: Feature, enabled: Bool) {
    guard isEnabled(feature) != enabled else { return }
    if enabled { enabledFeatures.insert(feature) } else { enabledFeatures.remove(feature) }
    log("feature: \(feature.title) → \(enabled ? "on" : "off")")
    applyFeatureState(feature)
    writeDaemonLockInfo(fd: lockFD, enabledFeatures: enabledFeatures)
    // The tick skips an unchanged snapshot, so clear the last one to make the
    // next tick apply the feature's new state.
    lastSignature = nil
}

// Toggles a feature in the running daemon and saves its new state to the
// config file.
func toggleFeature(_ feature: Feature) {
    let enabled = !isEnabled(feature)
    setFeature(feature, enabled: enabled)
    writeFeatureField(feature, enabled)
}

// Creates or removes the resources that the feature owns.
func applyFeatureState(_ feature: Feature) {
    switch feature {
    case .focusBorder:
        if isEnabled(.focusBorder) { setupFocusBorder() } else { teardownFocusBorder() }
    case .tiling, .focusFollowsMouse:
        break
    }
}

// Applies each feature whose config field changed. A feature whose field did
// not change keeps its running state.
func applyFeatureConfigChanges(from old: Config, to new: Config) {
    for feature in Feature.allCases {
        let enabled = new.features.contains(feature)
        if enabled != old.features.contains(feature) {
            setFeature(feature, enabled: enabled)
        }
    }
}
