package expo.modules.appmetrics

import android.content.Context
import android.util.Log
import androidx.core.content.edit
import expo.modules.appmetrics.crashreporting.CrashFileFormat
import expo.modules.appmetrics.jserrors.PendingErrorStore
import expo.modules.appmetrics.storage.MetricsDatabase
import java.io.FileNotFoundException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Whether the user consented to Observe collecting data. While not granted, app metrics stores
 * nothing and Observe sends nothing.
 */
object ObserveConsent {
  // Granted until the application start hook calls `load`.
  @Volatile
  var isGranted: Boolean = true
    private set

  // After a revoke, a grant in the same process only saves the value.
  private var hasRevoked = false

  /** Reads the saved consent value, or the app config embedded in the app when there is none. */
  @Synchronized
  fun load(context: Context) {
    isGranted = resolve(AppMetricsPreferences.getObserveConsent(context), readEmbeddedAppConfig(context))
    hasRevoked = false
  }

  internal data class Update(val changed: Boolean, val isSaved: Boolean)

  /**
   * Saves the value and changes the gate. A grant after a revoke changes it only at the next launch.
   * When the save fails, a revoke still closes the gate, but a grant changes nothing: the next
   * launch would read the earlier value.
   */
  @Synchronized
  internal fun update(context: Context, granted: Boolean): Update {
    val isSaved = AppMetricsPreferences.setObserveConsent(context, if (granted) GRANTED else NOT_GRANTED)
    if (granted == isGranted || (granted && (hasRevoked || !isSaved))) {
      return Update(changed = false, isSaved = isSaved)
    }
    if (granted) {
      // Before the gate opens, so no reader sees the stored settings without them.
      ConsentGatedPreferences.saveUnsavedValues(context)
    }
    isGranted = granted
    hasRevoked = hasRevoked || !granted
    return Update(changed = true, isSaved = isSaved)
  }

  // TODO(ENG-29293): Take the already parsed config when expo-constants has a public reader.
  /**
   * Consent from the saved value, else from the `extra.eas.observe.consent` key of the app config
   * JSON, granted when both are missing.
   */
  internal fun resolve(savedConsent: String?, appConfig: String?): Boolean {
    if (savedConsent != null) {
      return savedConsent == GRANTED
    }
    val consent = (appConfig?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() } as? JsonObject)
      ?.let { it["extra"] as? JsonObject }
      ?.let { it["eas"] as? JsonObject }
      ?.let { it["observe"] as? JsonObject }
      ?.get("consent")
      ?: return true
    val value = (consent as? JsonPrimitive)?.takeIf { it.isString }?.content
    if (value != GRANTED && value != NOT_GRANTED) {
      Log.w(
        TAG,
        "[AppMetrics] The app config value `extra.eas.observe.consent` is $consent, which is not " +
          "'granted' or 'not-granted', so Observe stays inactive. Set it to 'granted' or 'not-granted'."
      )
    }
    return value == GRANTED
  }

  private const val GRANTED = "granted"
  private const val NOT_GRANTED = "not-granted"

  // TODO(ENG-29293): Use a public reader from expo-constants when it exists. This copy exists
  // because the consent feature is backported to sdk-58.
  // `load` runs in `Application.onCreate`, before JS and the Expo modules start, so the value
  // cannot come from the module constants. The expo-constants reader is private, and this
  // package does not depend on expo-constants, so read the asset directly.
  private fun readEmbeddedAppConfig(context: Context): String? =
    try {
      context.assets.open("app.config").bufferedReader().use { it.readText() }
    } catch (_: FileNotFoundException) {
      null
    } catch (e: Exception) {
      Log.w(TAG, "[AppMetrics] Failed to read the embedded app config", e)
      null
    }
}

/** Deletes the metrics database, the crash files, the pending-error files, and the settings. */
internal fun deleteStoredData(context: Context) {
  context.deleteDatabase(MetricsDatabase.NAME)
  CrashFileFormat.crashesDir(context).deleteRecursively()
  PendingErrorStore.directory(context).deleteRecursively()
  AppMetricsPreferences.deleteStoredSettings(context)
}

/** Shared preferences that save nothing while consent is not granted. */
class ConsentGatedPreferences(private val name: String) {
  // Values set without consent. The app sends its config at startup, before the user can grant
  // consent. The first grant saves these values, so Observe does not send with the defaults.
  private val unsavedValues = ConcurrentHashMap<String, Any>()

  init {
    stores.add(this)
  }

  fun getString(context: Context, key: String): String? =
    read(inMemory = { unsavedValues[key] as? String }, stored = { preferences(context).getString(key, null) })

  fun getLong(context: Context, key: String, defaultValue: Long): Long =
    read(
      inMemory = { unsavedValues[key] as? Long ?: defaultValue },
      stored = { preferences(context).getLong(key, defaultValue) }
    )

  /** With `commit`, the value is on disk when this returns. */
  fun putString(context: Context, key: String, value: String, commit: Boolean = true) {
    write(inMemory = { unsavedValues[key] = value }, stored = { preferences(context).edit(commit) { putString(key, value) } })
  }

  fun putLong(context: Context, key: String, value: Long) {
    write(inMemory = { unsavedValues[key] = value }, stored = { preferences(context).edit(commit = true) { putLong(key, value) } })
  }

  // `update` changes the gate under the same lock. So a write cannot land in memory after the first
  // grant saved those values, or in storage after a revoke closed the gate.
  private inline fun write(inMemory: () -> Unit, stored: () -> Unit) {
    synchronized(ObserveConsent) {
      if (ObserveConsent.isGranted) {
        stored()
      } else {
        inMemory()
      }
    }
  }

  // Like `write`, but a read with consent does not wait for the lock: a stale value read during a
  // transition changes nothing on disk.
  private inline fun <T> read(inMemory: () -> T, stored: () -> T): T {
    if (!ObserveConsent.isGranted) {
      synchronized(ObserveConsent) {
        if (!ObserveConsent.isGranted) {
          return inMemory()
        }
      }
    }
    return stored()
  }

  /** Deletes the settings file. Runs at a launch without consent. */
  fun delete(context: Context) {
    context.deleteSharedPreferences(name)
  }

  private fun preferences(context: Context) = context.getSharedPreferences(name, Context.MODE_PRIVATE)

  companion object {
    // A store that was never created holds no values in memory, so this list has every such value.
    private val stores = CopyOnWriteArrayList<ConsentGatedPreferences>()

    /** Saves the values kept in memory, then forgets them. Runs at the first grant. */
    internal fun saveUnsavedValues(context: Context) {
      for (store in stores) {
        if (store.unsavedValues.isEmpty()) {
          continue
        }
        store.preferences(context).edit(commit = true) {
          for ((key, value) in store.unsavedValues) {
            when (value) {
              is String -> putString(key, value)
              is Long -> putLong(key, value)
            }
          }
        }
        store.unsavedValues.clear()
      }
    }
  }
}
