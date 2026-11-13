import Foundation

/// Every name the product shows or registers. Renaming the product starts here,
/// then the CLI product name in Package.swift, the README and the repo name.
public enum Brand {
    public static let displayName = "Lockloop"
    public static let cliName = "lockloop"
    /// Placeholder until the owner picks the final identifier.
    public static let bundleID = "it.estatheo.lockloop"
    public static let supportDirName = "Lockloop"
    public static let version = "0.1.0"
    public static var agentLabel: String { bundleID + ".keeper" }
    /// Point every path inside this directory and switch off all system side effects.
    public static let rootOverrideVariable = "LOCKLOOP_ROOT"
}
