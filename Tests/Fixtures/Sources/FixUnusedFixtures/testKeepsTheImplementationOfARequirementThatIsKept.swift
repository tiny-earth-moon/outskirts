protocol FixUnusedPairedProtocol {
    func paired()
}

public struct FixUnusedPairedConformer: FixUnusedPairedProtocol {
    func paired() {}
}
