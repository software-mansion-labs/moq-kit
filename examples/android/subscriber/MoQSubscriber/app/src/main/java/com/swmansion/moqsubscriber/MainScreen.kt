package com.swmansion.moqsubscriber

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material3.Card
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.swmansion.moqsubscriber.features.chat.ChatDemoScreen
import com.swmansion.moqsubscriber.features.player.PlayerDemoScreen

private enum class SubscriberDemo(
    val title: String,
    val subtitle: String,
    val icon: ImageVector,
) {
    Player(
        title = "Player",
        subtitle = "Raw broadcast player with relay controls.",
        icon = Icons.Default.PlayCircle,
    ),
    Chat(
        title = "Chat",
        subtitle = "Publish and receive JSON chat messages over raw MoQ data tracks.",
        icon = Icons.AutoMirrored.Filled.Chat,
    ),
}

@Composable
fun MainScreen() {
    var selectedDemo by remember { mutableStateOf<SubscriberDemo?>(null) }

    when (selectedDemo) {
        null -> DemoSelectionScreen(onDemoSelected = { selectedDemo = it })
        SubscriberDemo.Player -> {
            BackHandler { selectedDemo = null }
            PlayerDemoScreen()
        }
        SubscriberDemo.Chat -> {
            BackHandler { selectedDemo = null }
            ChatDemoScreen()
        }
    }
}

@Composable
private fun DemoSelectionScreen(
    onDemoSelected: (SubscriberDemo) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = "Subscriber Demo",
                style = MaterialTheme.typography.headlineLarge,
            )
            Text(
                text = "Choose the demo mode you want to launch.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 160.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            items(SubscriberDemo.entries) { demo ->
                DemoCard(demo = demo, onClick = { onDemoSelected(demo) })
            }
        }
    }
}

@Composable
private fun DemoCard(
    demo: SubscriberDemo,
    onClick: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = demo.icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
            Text(
                text = demo.title,
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = demo.subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "Open Demo",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
            )
        }
    }
}
