package com.vauth.foxyvpn.platform

import com.vauth.foxyvpn.data.AppLogger
import java.awt.Toolkit
import java.awt.datatransfer.StringSelection
import java.awt.Desktop
import java.io.File
import java.net.URI

private const val TAG = "Platform"

object Platform {

    fun openUrl(url: String) {
        val attempt = runCatching {
            if (Desktop.isDesktopSupported() && Desktop.getDesktop().isSupported(Desktop.Action.BROWSE)) {
                Desktop.getDesktop().browse(URI(url))
            } else if (Os.isWindows) {
                ProcessBuilder("cmd", "/c", "start", "", url).start()
            } else {
                ProcessBuilder("open", url).start()
            }
        }
        attempt.onFailure { AppLogger.w(TAG, "could not open $url in the browser", it) }
    }

    fun copyText(text: String) {
        runCatching {
            Toolkit.getDefaultToolkit().systemClipboard.setContents(StringSelection(text), null)
        }.onFailure { AppLogger.w(TAG, "could not copy to the clipboard", it) }
    }

    fun revealInFinder(file: File) {
        if (Os.isWindows) {
            runCatching {
                ProcessBuilder("explorer", "/select,${file.absolutePath}")
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start()
            }.onFailure { AppLogger.w(TAG, "could not reveal ${file.absolutePath} in Explorer", it) }
            return
        }
        runCatching {
            if (Desktop.isDesktopSupported() && Desktop.getDesktop().isSupported(Desktop.Action.OPEN)) {
                Desktop.getDesktop().open(file.parentFile)
            }
            ProcessBuilder("osascript", "-e", "tell application \"Finder\" to activate").also {
                it.redirectOutput(ProcessBuilder.Redirect.DISCARD)
                it.redirectError(ProcessBuilder.Redirect.DISCARD)
            }.start()
            ProcessBuilder(
                "osascript",
                "-e",
                "tell application \"Finder\" to reveal POSIX file \"${file.absolutePath.replace("\"", "\\\"")}\"",
            ).redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
        }.onFailure { AppLogger.w(TAG, "could not reveal ${file.absolutePath} in Finder", it) }
    }

    fun launchApplication(bundlePath: String) {
        runCatching {
            ProcessBuilder("open", bundlePath)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
        }.onFailure { AppLogger.w(TAG, "could not launch $bundlePath", it) }
    }
}
