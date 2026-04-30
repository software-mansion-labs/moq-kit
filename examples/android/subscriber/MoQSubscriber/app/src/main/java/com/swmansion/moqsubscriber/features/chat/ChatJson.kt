package com.swmansion.moqsubscriber.features.chat

import org.json.JSONObject
import java.nio.charset.StandardCharsets

object ChatJson {
    fun encode(payload: ChatPayload): ByteArray {
        return JSONObject()
            .put("from", payload.from)
            .put("message", payload.message)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
    }

    fun decode(bytes: ByteArray): ChatPayload {
        val json = JSONObject(String(bytes, StandardCharsets.UTF_8))
        return ChatPayload(
            from = json.getString("from"),
            message = json.getString("message"),
        )
    }
}

