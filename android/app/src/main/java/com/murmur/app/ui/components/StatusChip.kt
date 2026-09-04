package com.murmur.app.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.murmur.app.ui.theme.MurmurAttention
import com.murmur.app.ui.theme.MurmurOk

/**
 * One line of "is this ready?" on the Home screen, and the tap that fixes it.
 *
 * The whole chip is the fix button rather than a label with a small button beside it: on a
 * phone the thing to tap is the problem itself. A chip that is already fine simply has nothing
 * to do — it stays a plain row rather than a dead-looking disabled control.
 */
@Composable
fun StatusChip(
    title: String,
    detail: String,
    ok: Boolean,
    modifier: Modifier = Modifier,
    /** Draws the row as the one thing on screen to deal with — the mic chip after the IME
     * sent the user here to grant the microphone. */
    highlighted: Boolean = false,
    onClick: (() -> Unit)? = null,
) {
    val row = Modifier
        .fillMaxWidth()
        .let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .padding(vertical = 10.dp)

    Row(
        modifier = modifier.then(row).clearAndSetSemantics { contentDescription = "$title: $detail" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = if (ok) Icons.Default.CheckCircle else Icons.Default.Error,
            contentDescription = null,
            tint = if (ok) MurmurOk else MurmurAttention,
            modifier = Modifier.size(20.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = if (highlighted) FontWeight.Bold else FontWeight.Medium,
                color = MaterialTheme.colorScheme.onBackground,
            )
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (onClick != null && !ok) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}
