import LayerA

struct GreetingAdopter: LayerGreeting {}

public func greetFromB() -> String {
    let greeting: any LayerGreeting = GreetingAdopter()
    return greeting.greetingText()
}
