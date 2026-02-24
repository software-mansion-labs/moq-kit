package com.swmansion.moqsubscriber

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.swmansion.moqkit.MoQSession
import kotlinx.coroutines.launch

class MainViewModel : ViewModel() {
    var relayUrl by mutableStateOf("http://192.168.92.140:4443")
    var broadcastPath by mutableStateOf("anon/bbb")
    var sessionState by mutableStateOf<MoQSession.State>(MoQSession.State.Idle)
    var broadcastInfo by mutableStateOf<MoQSession.BroadcastInfo?>(null)

    private var session: MoQSession? = null

    fun connect() {
        val s = MoQSession(url = relayUrl, path = broadcastPath, scope = viewModelScope)
        session = s

        viewModelScope.launch {
            s.state.collect { sessionState = it }
        }
        viewModelScope.launch {
            s.broadcasts.collect { info ->
                broadcastInfo = info
            }
        }
        viewModelScope.launch {
            try { s.connect() } catch (_: Exception) {}
        }
    }

    fun stop() {
        val s = session
        session = null
        broadcastInfo = null
        sessionState = MoQSession.State.Idle
        viewModelScope.launch { s?.close() }
    }

    override fun onCleared() {
        super.onCleared()
        viewModelScope.launch { session?.close() }
    }
}
