package com.swmansion.moqkit

/**
 * Thrown when the selected media codec cannot be encoded or decoded on this device.
 */
class UnsupportedCodecException(message: String) : IllegalArgumentException(message)
