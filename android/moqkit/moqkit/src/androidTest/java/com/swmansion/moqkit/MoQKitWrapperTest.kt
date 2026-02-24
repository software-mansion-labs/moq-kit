package com.swmansion.moqkit

import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MoQKitWrapperTest {

    @Test
    fun createAndCloseMoQOrigin() {
        val origin = MoQOrigin()
        assertTrue(origin.handle > 0u)
        origin.close()
        // calling close again must not crash
        origin.close()
    }

    @Test
    fun connectWithBadUrlThrowsMoQTransportException() {
        assertThrows(MoQTransportException::class.java) {
            runBlocking {
                MoQTransport.connect("https://not-a-moq-relay.invalid:4433")
            }
        }
    }
}
