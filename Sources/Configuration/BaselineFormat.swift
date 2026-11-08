/// The ids that `--write-baseline` records: `v1` the ids of the declarations (their USRs), `v2` the ids of the output
/// v2, which include the rule, so that a result of another rule on a baselined declaration is still reported.
public enum BaselineFormat: String, CaseIterable, Equatable, Sendable {
    case v1
    case v2

    public static let `default` = BaselineFormat.v1
}
