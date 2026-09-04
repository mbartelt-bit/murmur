package com.murmur.app.ui

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.History
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.murmur.app.KeyboardStatus
import com.murmur.app.Permissions
import com.murmur.app.R
import com.murmur.app.data.Settings
import com.murmur.app.di.AppGraph
import com.murmur.app.engine.SpeechEngines
import com.murmur.app.ime.asDictation
import com.murmur.app.ui.history.HistoryScreen
import com.murmur.app.ui.history.HistoryViewModel
import com.murmur.app.ui.home.HomeScreen
import com.murmur.app.ui.home.HomeViewModel
import com.murmur.app.ui.onboarding.OnboardingScreen
import com.murmur.app.ui.onboarding.OnboardingViewModel
import com.murmur.app.ui.recorder.RecorderScreen
import com.murmur.app.ui.recorder.RecorderViewModel
import com.murmur.app.ui.settings.EngineSettingsViewModel
import com.murmur.app.ui.settings.SettingsScreen

/** The app's five destinations. Three of them are tabs; two are full-screen. */
object Route {
    const val ONBOARDING = "onboarding"
    const val HOME = "home"
    const val HISTORY = "history"
    const val SETTINGS = "settings"
    const val RECORDER = "recorder"

    /** Everything a `murmurScreen` debug extra is allowed to name. */
    fun fromDebugName(name: String?): String? = when (name) {
        HOME, HISTORY, SETTINGS, ONBOARDING, RECORDER -> name
        else -> null
    }
}

/**
 * The app's one navigation decision: onboarding, or the three tabs.
 *
 * The start destination is read once, from the first value the settings flow produces. After
 * that the user's own navigation owns where they are — finishing onboarding navigates, it does
 * not re-key the graph, so nobody is yanked off the screen they walked to.
 */
@Composable
fun RootNav(
    graph: AppGraph,
    micGranted: () -> Boolean,
    keyboardEnabled: () -> Boolean,
    localAvailable: () -> Boolean,
    modifier: Modifier = Modifier,
    /** A debug-only override (`murmurScreen`), for deterministic screenshots. */
    forcedRoute: String? = null,
    /** The keyboard sent the user here to grant the microphone. */
    requestMic: Boolean = false,
) {
    val settings by graph.settings.settings.collectAsState(initial = null)
    val loaded = settings != null
    val onboardingComplete = settings?.onboardingComplete == true

    Surface(modifier = modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        if (!loaded) {
            // One frame at most: DataStore answers from its own cache after the first read.
            Box(Modifier.fillMaxSize())
        } else {
            val nav = rememberNavController()
            val start = rememberSaveable {
                forcedRoute
                    // The keyboard's "Open Murmur": straight to the microphone step while it
                    // is still missing, otherwise Home with the chip pointed at.
                    ?: if (requestMic && !micGranted()) Route.ONBOARDING
                    else if (onboardingComplete) Route.HOME
                    else Route.ONBOARDING
            }
            val highlightMic = requestMic && start != Route.ONBOARDING

            NavHost(
                navController = nav,
                startDestination = start,
                modifier = Modifier.fillMaxSize(),
            ) {
                composable(Route.ONBOARDING) {
                    val viewModel: OnboardingViewModel = murmurViewModel {
                        OnboardingViewModel(
                            settings = graph.settings,
                            micGranted = micGranted,
                            keyboardEnabled = keyboardEnabled,
                            localAvailable = localAvailable,
                        )
                    }
                    val engine: EngineSettingsViewModel = murmurViewModel {
                        EngineSettingsViewModel(settings = graph.settings, secrets = graph.secrets)
                    }
                    OnboardingScreen(
                        viewModel = viewModel,
                        engine = engine,
                        // No Scaffold here, so this screen keeps itself out of the status bar
                        // and off the gesture pill by hand.
                        modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing),
                        onFinished = {
                            nav.navigate(Route.HOME) {
                                popUpTo(Route.ONBOARDING) { inclusive = true }
                            }
                        },
                    )
                }

                composable(Route.HOME) {
                    val viewModel: HomeViewModel = murmurViewModel {
                        HomeViewModel(
                            settings = graph.settings,
                            secrets = graph.secrets,
                            history = graph.history,
                            micGranted = micGranted,
                            keyboardEnabled = keyboardEnabled,
                        )
                    }
                    Tabs(nav, Route.HOME) { padding ->
                        HomeScreen(
                            viewModel = viewModel,
                            onTryDictation = { nav.navigate(Route.RECORDER) },
                            onOpenSettings = { nav.switchTab(Route.SETTINGS) },
                            highlightMic = highlightMic,
                            modifier = Modifier.padding(padding),
                        )
                    }
                }

                composable(Route.HISTORY) {
                    val viewModel: HistoryViewModel = murmurViewModel { HistoryViewModel(graph.history) }
                    Tabs(nav, Route.HISTORY) { padding ->
                        HistoryScreen(viewModel = viewModel, modifier = Modifier.padding(padding))
                    }
                }

                composable(Route.SETTINGS) {
                    val engine: EngineSettingsViewModel = murmurViewModel {
                        EngineSettingsViewModel(settings = graph.settings, secrets = graph.secrets)
                    }
                    // The toggles are drawn straight from the store, so a change the keyboard
                    // or another screen makes shows up here without a refresh.
                    val current by graph.settings.settings.collectAsState(initial = Settings())
                    Tabs(nav, Route.SETTINGS) { padding ->
                        SettingsScreen(
                            engine = engine,
                            settingsStore = graph.settings,
                            settings = current,
                            modifier = Modifier.padding(padding),
                        )
                    }
                }

                composable(Route.RECORDER) {
                    val viewModel: RecorderViewModel = murmurViewModel {
                        RecorderViewModel(
                            settings = graph.settings,
                            pipeline = graph.pipeline.asDictation(),
                            permissions = micGranted,
                            offlineAvailable = localAvailable,
                            sessionFactory = graph.sessionFactory,
                        )
                    }
                    RecorderScreen(
                        viewModel = viewModel,
                        onDone = { nav.popBackStack() },
                        modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing),
                    )
                }
            }
        }
    }
}

/**
 * A view model owned by its navigation entry, so it survives a rotation and is cleared when
 * the user leaves the screen for good. The app graph is a hand-rolled singleton, so there is
 * nothing to inject beyond the closure that builds one.
 */
@Composable
private inline fun <reified T : ViewModel> murmurViewModel(crossinline build: () -> T): T =
    viewModel(
        factory = remember {
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <V : ViewModel> create(modelClass: Class<V>): V = build() as V
            }
        },
    )

/**
 * The three tabs, in the order the spec lists them. Only these three carry the bottom bar; the
 * recorder and onboarding are full-screen, because each is one job with one way out.
 */
@Composable
private fun Tabs(
    nav: NavHostController,
    selected: String,
    content: @Composable (PaddingValues) -> Unit,
) {
    Scaffold(
        bottomBar = {
            NavigationBar {
                Tab(nav, selected, Route.HOME, Icons.Default.Mic, R.string.tab_home)
                Tab(nav, selected, Route.HISTORY, Icons.Outlined.History, R.string.tab_history)
                Tab(nav, selected, Route.SETTINGS, Icons.Default.Settings, R.string.tab_settings)
            }
        },
        content = content,
    )
}

@Composable
private fun RowScope.Tab(
    nav: NavHostController,
    selected: String,
    route: String,
    icon: ImageVector,
    label: Int,
) {
    NavigationBarItem(
        selected = selected == route,
        onClick = { if (selected != route) nav.switchTab(route) },
        icon = { Icon(icon, contentDescription = null) },
        label = { Text(stringResource(label)) },
    )
}

/**
 * Moving between tabs is not a stack: the back stack stays one entry deep, and coming back to
 * a tab restores where the user was in it rather than rebuilding it.
 */
private fun NavHostController.switchTab(route: String) {
    navigate(route) {
        popUpTo(graph.startDestinationId) { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

/** The live system answers, for the activity to hand in — and for a fake to replace. */
object SystemStatus {
    fun micGranted(context: Context): Boolean = Permissions.hasRecordAudio(context)
    fun keyboardEnabled(context: Context): Boolean = KeyboardStatus.isEnabled(context)
    fun localAvailable(context: Context): Boolean = SpeechEngines.isLocalAvailable(context)
}
