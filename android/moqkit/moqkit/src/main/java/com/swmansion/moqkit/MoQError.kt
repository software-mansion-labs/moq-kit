package com.swmansion.moqkit

/**
 * Thrown when a [MoQSession] operation fails (e.g. connection refused, protocol error).
 */
class MoQSessionException(message: String) : Exception(message)
