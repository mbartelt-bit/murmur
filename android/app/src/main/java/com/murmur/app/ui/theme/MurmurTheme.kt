package com.murmur.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * The desktop's `--accent: #6366f1` (`src/index.css`), on every platform. iOS calls the same
 * value `Color.murmurIndigo`.
 */
val MurmurIndigo = Color(0xFF6366F1)

/** A finished check. Fixed rather than themed so light and dark agree on "this is fine". */
val MurmurOk = Color(0xFF2E9E5B)

/** Something the user has to do — a permission, a missing key, a keyboard not added yet. */
val MurmurAttention = Color(0xFFC77700)

/**
 * Fixed light tokens, matching the desktop's. Dynamic colour is deliberately off (spec §5):
 * Murmur is indigo everywhere, and a keyboard that changes colour with the user's wallpaper
 * while the app does not would read as two products.
 */
private val LightColors = lightColorScheme(
    primary = MurmurIndigo,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE5E5FB),
    onPrimaryContainer = Color(0xFF2A2A6A),
    secondary = MurmurIndigo,
    onSecondary = Color.White,
    background = Color(0xFFF5F5F7),
    onBackground = Color(0xFF1C1C1E),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF1C1C1E),
    surfaceVariant = Color(0xFFEDEDF0),
    onSurfaceVariant = Color(0xFF5A5A60),
    outline = Color(0xFFC9C9CF),
    outlineVariant = Color(0xFFE2E2E7),
    error = Color(0xFFB3261E),
    onError = Color.White,
)

/** The same roles in the dark palette; only the colours change. */
private val DarkColors = darkColorScheme(
    primary = MurmurIndigo,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF34346B),
    onPrimaryContainer = Color(0xFFDDDDFB),
    secondary = MurmurIndigo,
    onSecondary = Color.White,
    background = Color(0xFF1C1C1E),
    onBackground = Color(0xFFF2F2F5),
    surface = Color(0xFF2C2C2E),
    onSurface = Color(0xFFF2F2F5),
    surfaceVariant = Color(0xFF3A3A3C),
    onSurfaceVariant = Color(0xFFA0A0A6),
    outline = Color(0xFF56565A),
    outlineVariant = Color(0xFF3A3A3C),
    error = Color(0xFFF2B8B5),
    onError = Color(0xFF601410),
)

/** Every screen in the app. The keyboard carries its own copy of these tokens — it renders
 * inside the system's input view, not inside this theme. */
@Composable
fun MurmurTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        content = content,
    )
}
