package xyz.dnstt.app

/**
 * JNI entry points of libhev-socks5-tunnel.so (vendor/hev-socks5-tunnel, src/hev-jni.c).
 * The library registers them on this class by name in JNI_OnLoad, so the name, the
 * package and the signatures must not change (proguard-rules.pro keeps the class).
 * Use [Tun2Socks] instead of calling these directly.
 */
object TProxyService {
    init {
        System.loadLibrary("hev-socks5-tunnel")
    }

    /** Starts the engine in a new native thread on [fd] and returns at once; ignored while one runs. */
    @JvmStatic
    external fun TProxyStartService(configPath: String, fd: Int)

    /** Stops the engine and waits for its thread. */
    @JvmStatic
    external fun TProxyStopService()

    /** tx packets, tx bytes, rx packets, rx bytes since the engine started. */
    @JvmStatic
    external fun TProxyGetStats(): LongArray
}
