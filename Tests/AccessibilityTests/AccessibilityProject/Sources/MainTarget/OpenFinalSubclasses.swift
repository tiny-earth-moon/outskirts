import TargetA

final class OpenFinalCrossModuleSubclass: OpenFinalClassSubclassedCrossModule {
    override func openFinalOverriddenCrossModule() {}
}

#if os(iOS)
    final class OpenFinalCrossModuleSubclassOnOtherPlatform: OpenFinalClassSubclassedOnOtherPlatform {
        override func openFinalOverriddenOnOtherPlatform() {}
    }
#endif

func openFinalRetain() {
    let object: OpenFinalClassSubclassedCrossModule = OpenFinalCrossModuleSubclass()
    object.openFinalOverriddenCrossModule()
    object.openFinalNeverOverriddenMember()
    OpenFinalRetainer.retain()
}
