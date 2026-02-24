package com.swmansion.moqkit

class MoQTransportException(val code: Int, message: String) : Exception(message)
class MoQSessionException(message: String) : Exception(message)
