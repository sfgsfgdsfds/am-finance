/// Meal-time daypart buckets for a wall-clock hour — the numeric policy
/// behind the AI capture prompt's meal hint when a typed food/drink line
/// carries no explicit time. Non-overlapping ranges: sáng 05–10,
/// trưa 11–13, chiều 14–17, tối 18–22; the 23:00–04:59 stretch stays
/// neutral so no meal is inferred. Calendar choice and Vietnamese labels
/// belong to callers, not here.
public enum MealDaypart: Sendable, Equatable, CaseIterable {
    case sang
    case trua
    case chieu
    case toi

    /// The bucket `hour` (wall-clock 0–23) falls into, or nil for the
    /// neutral late-night stretch; out-of-range input is neutral too.
    public static func at(hour: Int) -> MealDaypart? {
        switch hour {
        case 5...10: return .sang
        case 11...13: return .trua
        case 14...17: return .chieu
        case 18...22: return .toi
        default: return nil
        }
    }
}
