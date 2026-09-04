package com.murmur.app

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.murmur.core.CleanResult
import kotlinx.coroutines.launch

/** Indigo accent, matching `--accent: #6366f1` in the desktop app's `src/index.css`. */
val MurmurAccent = Color(0xFF6366F1)

/** Pure helper so the button's label is unit-testable without the FFI. */
fun formatCleaned(result: CleanResult): String = "Cleaned: ${result.clean}"

@Composable
fun HomeScreen() {
    val scope = rememberCoroutineScope()
    var cleaned by remember { mutableStateOf<String?>(null) }
    val keyPage = remember { CoreClient.groqKeyPage() }

    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(text = "Murmur", style = MaterialTheme.typography.headlineMedium)
            Text(
                text = keyPage,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.padding(top = 12.dp),
            )
            Button(
                onClick = {
                    scope.launch {
                        cleaned = formatCleaned(CoreClient.cleanLocally("um hello world"))
                    }
                },
                colors = ButtonDefaults.buttonColors(containerColor = MurmurAccent),
                modifier = Modifier.padding(top = 24.dp),
            ) {
                Text("Run core")
            }
            Text(
                text = cleaned ?: "",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(top = 24.dp),
            )
        }
    }
}
