package shop.ironvpn.app

import android.content.Context
import java.io.File

object VpnStateStore {
    private const val FILE_NAME = "vpn-state.txt"
    private val knownStates = setOf(
        "disconnected",
        "connecting",
        "connected",
        "disconnecting",
        "unsupported",
        "error",
    )

    fun set(context: Context, state: String) {
        val normalized = state.takeIf { it in knownStates } ?: "disconnected"
        runCatching {
            stateFile(context).writeText(normalized)
        }
    }

    fun get(context: Context): String {
        return runCatching {
            stateFile(context).readText().trim()
        }.getOrNull()
            ?.takeIf { it in knownStates }
            ?: "disconnected"
    }

    private fun stateFile(context: Context): File {
        val directory = context.noBackupFilesDir
        if (!directory.exists()) {
            directory.mkdirs()
        }
        return File(directory, FILE_NAME)
    }
}
