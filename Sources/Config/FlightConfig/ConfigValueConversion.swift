import Configuration

extension ConfigContent {

    /// The raw-string → scalar conversion table, in one place.
    ///
    /// It was written twice — once in `ConfigSourceProvider`, once in
    /// `FlightYAMLSnapshot` — as two near-identical switches differing only
    /// in which error they threw and whether they marked the value secret.
    /// Neither had drifted yet, which is the moment to merge them rather
    /// than the moment after.
    ///
    /// Returns nil for a value that does not convert *and* for the array
    /// types: this is the scalar table by definition, and reassembling
    /// flattened sequence keys (`hosts.0`) needs the document structure only
    /// `FlightYAMLSnapshot` has. The caller decides what nil means and what
    /// to throw, which is the only thing that ever differed.
    static func flightScalar(_ raw: String, as type: ConfigType) -> ConfigContent? {
        switch type {
        case .string: .string(raw)
        case .int: Int(configValue: raw).map(ConfigContent.int)
        case .double: Double(configValue: raw).map(ConfigContent.double)
        case .bool: Bool(configValue: raw).map(ConfigContent.bool)
        case .bytes: .bytes([UInt8](raw.utf8))
        case .stringArray, .intArray, .doubleArray, .boolArray, .byteChunkArray: nil
        }
    }
}

extension ConfigType {
    /// The Swift type name a failed conversion should name.
    var flightTargetTypeName: String {
        switch self {
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .bytes: "[UInt8]"
        case .stringArray: "[String]"
        case .intArray: "[Int]"
        case .doubleArray: "[Double]"
        case .boolArray: "[Bool]"
        case .byteChunkArray: "[[UInt8]]"
        }
    }
}

/// A provider that can answer "do you hold this key at all?" without being
/// asked for a type.
///
/// swift-configuration's lookup is type-directed, so establishing that a key
/// is *absent* from a provider means asking for every shape it could be:
/// four scalars, then six non-scalars, ten calls — and an absent key on a
/// three-layer stack was thirty. Flight's own providers know their key set
/// outright, so they answer in one.
///
/// Internal, and deliberately not a requirement on `ConfigProvider`: a
/// third-party provider keeps the type-directed path, which is correct, just
/// slower. This is boot-time work either way — the reason it is worth doing
/// at all is that `AdapterPresence` and the build plugin's key checks probe
/// many keys that are deliberately absent.
internal protocol FlightKeyPresenceProvider {
    func flightHoldsKey(_ key: AbsoluteConfigKey) -> Bool
}
