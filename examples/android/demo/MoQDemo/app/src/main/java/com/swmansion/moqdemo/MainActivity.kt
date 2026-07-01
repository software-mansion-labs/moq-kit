package com.swmansion.moqdemo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.material3.MaterialTheme
import com.swmansion.moqkit.NativeLogging

data class MoQDemoRelayUrls(
    val sharedRelayUrl: String,
) {
    companion object {
        val defaults = MoQDemoRelayUrls(
            // sharedRelayUrl = "http://192.168.92.134:4443/anon",
            sharedRelayUrl = "https://cdn.moq.dev/demo/bbb.hang",
        )
    }
}

class MainActivity : ComponentActivity() {
    private val relayUrls = MoQDemoRelayUrls.defaults

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NativeLogging.setLogLevel("trace")
        enableEdgeToEdge()
        setContent {
            MaterialTheme {
                MainScreen(relayUrls = relayUrls)
            }
        }
    }
}
