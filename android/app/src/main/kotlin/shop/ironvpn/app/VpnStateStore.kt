package shop.ironvpn.app

import android.content.Context
import java.io.File

object VpnStateStore {
    private const val FILE_NAME = "vpn-state.txt"
    private const val UPDATED_AT_FILE_NAME = "vpn-state-updated-at.txt"
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
            updatedAtFile(context).writeText(System.currentTimeMillis().toString())
        }
    }

    fun get(context: Context): String {
        return runCatching {
            stateFile(context).readText().trim()
        }.getOrNull()
            ?.takeIf { it in knownStates }
            ?: "disconnected"
    }

    fun updatedAt(context: Context): Long {
        return runCatching {
            updatedAtFile(context).readText().trim().toLong()
        }.getOrDefault(0L)
    }

    private fun stateFile(context: Context): File {
        return stateFile(context, FILE_NAME)
    }

    private fun updatedAtFile(context: Context): File {
        return stateFile(context, UPDATED_AT_FILE_NAME)
    }

    private fun stateFile(context: Context, name: String): File {
        val directory = context.noBackupFilesDir
        if (!directory.exists()) {
            directory.mkdirs()
        }
        return File(directory, name)
    }
}
