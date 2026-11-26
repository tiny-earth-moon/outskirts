import LayerA
import LayerB

struct FarewellAdopter: LayerFarewell {}

public func farewellFromC() -> String {
    let farewell: any LayerFarewell = FarewellAdopter()
    return farewell.farewellText()
}
