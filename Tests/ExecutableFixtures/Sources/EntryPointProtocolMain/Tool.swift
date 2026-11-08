protocol Runnable {
    static func runIt()
}

extension Runnable {
    static func main() {
        runIt()
    }
}

@main
struct Tool: Runnable {
    static func runIt() {
        helper()
    }

    static func helper() {}

    static func unusedHelper() {}
}
