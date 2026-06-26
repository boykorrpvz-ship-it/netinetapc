package shop.ironvpn.app

import android.content.Context
import java.io.File

object VpnStateStore {
    private const val FILE_NAME = "vpn-state.txt"
    private const val UPDATED_AT_FILE_NAME = "vpn-state-updated-at.txt"
    private const val PROTOCOL_FILE_NAME = "vpn-active-protocol.txt"
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

    /** Remembers which engine (protocol) is currently selected/active so the
     *  main process can route a stop request to the correct per-protocol
     *  service process. */
    fun setProtocol(context: Context, protocol: String) {
        runCatching {
            stateFile(context, PROTOCOL_FILE_NAME).writeText(protocol)
        }
    }

    fun getProtocol(context: Context): String? {
        return runCatching {
            stateFile(context, PROTOCOL_FILE_NAME).readText().trim()
        }.getOrNull()?.takeIf { it.isNotBlank() }
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
