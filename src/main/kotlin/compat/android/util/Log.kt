package android.util

object Log {
    fun v(tag: String, message: String) = println("V/$tag: $message")
    fun d(tag: String, message: String) = println("D/$tag: $message")
    fun i(tag: String, message: String) = println("I/$tag: $message")

    fun w(tag: String, message: String) = println("W/$tag: $message")

    fun w(tag: String, message: String, error: Throwable?) {
        println("W/$tag: $message")
        error?.printStackTrace(System.out)
    }

    fun e(tag: String, message: String) = println("E/$tag: $message")

    fun e(tag: String, message: String, error: Throwable?) {
        println("E/$tag: $message")
        error?.printStackTrace(System.err)
    }
}
