// Copyright 2025-present 650 Industries. All rights reserved.

import ExpoModulesCore
import os

/// Whether the user consented to Observe collecting data. While not granted, app metrics stores
/// nothing and Observe sends nothing.
public enum ObserveConsent {
  public enum State: Sendable {
    case granted
    case notGranted
    /// The saved value could not be read, for example before the first unlock after a restart.
    /// Nothing is stored, and the launch cleanup keeps the stored data, because it can belong to
    /// a user who granted consent.
    case unknown
  }

  /// The consent of this process and the changes it allows.
  struct Gate: Sendable {
    private(set) var state: State
    private var hasRevoked = false

    init(state: State) {
      self.state = state
    }

    /// Returns whether the gate changed. After a revoke, a grant changes it only at the next launch.
    mutating func apply(granted: Bool) -> Bool {
      if granted {
        guard state != .granted, !hasRevoked else {
          return false
        }
        state = .granted
      } else {
        guard state != .notGranted else {
          return false
        }
        state = .notGranted
        hasRevoked = true
      }
      return true
    }
  }

  /// Resolved on first access: the saved value, else the app config embedded in the app.
  private static let gate = OSAllocatedUnfairLock<Gate?>(initialState: nil)

  private static let savedValueUrl = try? MetricsDatabase.defaultDirectoryUrl().appendingPathComponent("observe-consent")

  public static var isGranted: Bool {
    return state == .granted
  }

  public static var state: State {
    return gate.withLock { gate in
      if let gate {
        return gate.state
      }
      let state = resolveState()
      gate = Gate(state: state)
      return state
    }
  }

  private static func resolveState() -> State {
    guard let savedValueUrl else {
      return .unknown
    }
    // TODO(ENG-29293): Read the config with a public reader from expo-modules-core when it exists.
    return readSavedState(at: savedValueUrl) ?? (isGranted(appConfig: EmbeddedAppConfig.read()) ? .granted : .notGranted)
  }

  /// Saves the value and changes the gate. When the save fails, a revoke still closes the gate,
  /// but a grant changes nothing: the next launch would read the earlier value.
  static func update(granted: Bool) -> (changed: Bool, isSaved: Bool) {
    let isSaved = savedValueUrl.map { save(granted: granted, to: $0) } ?? false
    _ = state
    let changed = ConsentGatedDefaults.transitionLock.withLock {
      gate.withLock { gate in
        guard isSaved || !granted, var next = gate, next.apply(granted: granted) else {
          return false
        }
        gate = next
        return true
      }
    }
    return (changed, isSaved)
  }

  /// `nil` when no value was saved, `.unknown` when the saved value cannot be read.
  static func readSavedState(at url: URL) -> State? {
    do {
      return try String(contentsOf: url, encoding: .utf8) == "granted" ? .granted : .notGranted
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      logger.warn("[AppMetrics] Failed to read the saved Observe consent: \(error.localizedDescription)")
      return .unknown
    }
  }

  /// Returns whether the value was written.
  static func save(granted: Bool, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data((granted ? "granted" : "not-granted").utf8).write(to: url, options: .atomic)
      return true
    } catch {
      logger.warn("[AppMetrics] Failed to save the Observe consent: \(error.localizedDescription)")
      return false
    }
  }

  /// Consent from the `extra.eas.observe.consent` key of the app config, granted when the key is missing.
  static func isGranted(appConfig: [String: Any]?) -> Bool {
    let extra = appConfig?["extra"] as? [String: Any]
    let eas = extra?["eas"] as? [String: Any]
    let observe = eas?["observe"] as? [String: Any]
    guard let consent = observe?["consent"] else {
      return true
    }
    let value = consent as? String
    if value != "granted" && value != "not-granted" {
      logger.warn(
        "[AppMetrics] The app config value `extra.eas.observe.consent` is \(consent), which is not 'granted' or 'not-granted', so Observe stays inactive. Set it to 'granted' or 'not-granted'."
      )
    }
    return value == "granted"
  }
}

/// A settings suite that saves nothing while consent is not granted.
public final class ConsentGatedDefaults: @unchecked Sendable {
  // `UserDefaults` is thread-safe, and the in-memory values are behind a mutex.
  private let defaults: UserDefaults
  private let isGranted: @Sendable () -> Bool
  // Values set without consent. They are kept only in memory, and reads return them.
  private let unsavedValues = Mutex<[String: Any]>([:])

  public convenience init(_ defaults: UserDefaults) {
    self.init(defaults, isGranted: { ObserveConsent.isGranted })
  }

  init(_ defaults: UserDefaults, isGranted: @escaping @Sendable () -> Bool) {
    self.defaults = defaults
    self.isGranted = isGranted
  }

  // Taken before the consent gate lock. `ObserveConsent.update` changes the gate under it, and the
  // writes and the not-granted reads check the gate under it.
  static let transitionLock = OSAllocatedUnfairLock()

  public func object(forKey key: String) -> Any? {
    var value: Any?
    if whileNotGranted({ value = unsavedValues.withLock { $0[key] } }) {
      return value
    }
    return defaults.object(forKey: key)
  }

  // `ObserveConsent.update` changes the gate under the same lock. So a write cannot land in the
  // suite after a revoke closed the gate.
  public func set(_ value: Any?, forKey key: String) {
    Self.transitionLock.withLockUnchecked {
      if isGranted() {
        defaults.set(value, forKey: key)
      } else {
        unsavedValues.withLock { $0[key] = value }
      }
    }
  }

  // Runs `body` and returns true while consent is not granted. Like `set`, but a read with consent
  // does not wait for the lock: a stale value read during a transition changes nothing on disk.
  private func whileNotGranted(_ body: () -> Void) -> Bool {
    guard !isGranted() else {
      return false
    }
    return Self.transitionLock.withLockUnchecked {
      guard !isGranted() else {
        return false
      }
      body()
      return true
    }
  }
}
