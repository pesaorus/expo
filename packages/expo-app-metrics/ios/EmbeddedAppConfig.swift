// Copyright 2025-present 650 Industries. All rights reserved.

import Foundation

// TODO(ENG-29293): Use a public reader from expo-modules-core when it exists. This copy exists
// because the consent feature is backported to sdk-58.
/// Reads the app config that the build embeds in `EXConstants.bundle`.
/// The consent value is needed at app launch, before JS runs and before an `AppContext` exists,
/// so it cannot come from the `AppContext` constants. The reader in expo-modules-core
/// (`ConstantsProvider.swift`) is private, so this copies its bundle lookup.
final class EmbeddedAppConfig {
  /// Nil when the app has no embedded app config, or when it cannot be read.
  static func read() -> [String: Any]? {
    guard let url = findConstantsBundle()?.url(forResource: "app", withExtension: "config") else {
      return nil
    }
    do {
      return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    } catch {
      logger.warn("[AppMetrics] Failed to read the embedded app config: \(error)")
      return nil
    }
  }

  // The bundle is in the main app for a standard CocoaPods setup. With brownfield or precompiled
  // modules, it can be in this framework or in another loaded framework.
  private static func findConstantsBundle() -> Bundle? {
    func constantsBundle(in candidate: Bundle) -> Bundle? {
      candidate.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("EXConstants.bundle")) }
    }
    return constantsBundle(in: Bundle.main)
      ?? constantsBundle(in: Bundle(for: EmbeddedAppConfig.self))
      ?? Bundle.allFrameworks.lazy.compactMap(constantsBundle).first
  }
}
