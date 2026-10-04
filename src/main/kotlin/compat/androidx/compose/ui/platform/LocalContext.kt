package androidx.compose.ui.platform

import android.content.Context
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import com.vauth.foxyvpn.platform.AppHolder

val LocalContext: ProvidableCompositionLocal<Context> = staticCompositionLocalOf { AppHolder.context }
