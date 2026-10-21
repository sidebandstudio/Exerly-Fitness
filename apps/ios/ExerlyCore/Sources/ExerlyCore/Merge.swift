import Foundation

/// Three-way merge of a local and a remote copy against their last common
/// version. Nothing logged on either side is lost:
/// - a field takes whichever side changed it; when both changed it
///   differently it takes the preferred side (local unless asked) and is
///   reported, so sync can keep the other version for review;
/// - items in lists merge by ID, recursively, and additions on both sides stay;
/// - a deletion applies only when the other side left the item unchanged;
///   deleted on one side and changed on the other, the item stays and is
///   reported, so a set logged mid-workout is never lost; preferring the
///   remote side, as a resolution does, follows it instead;
/// - the local order wins, and remote additions are appended.
/// Without a common version every item is treated as added on its side.
public enum Merge {
    /// Which side a field takes when both sides changed it differently.
    public enum Preference: Sendable, Hashable { case local, remote }

    /// Collects the paths both sides changed differently.
    final class Recorder {
        let prefer: Preference
        var conflicts: [String] = []
        init(_ prefer: Preference) { self.prefer = prefer }
    }

    public static func session(base: WorkoutSession?, local: WorkoutSession, remote: WorkoutSession) -> WorkoutSession {
        session(base, local, remote, Recorder(.local), path: "")
    }

    /// The session merge, also naming the fields both sides changed differently.
    public static func session(base: WorkoutSession?, local: WorkoutSession, remote: WorkoutSession,
                               preferring prefer: Preference) -> (merged: WorkoutSession, conflicts: [String]) {
        let recorder = Recorder(prefer)
        let merged = session(base, local, remote, recorder, path: "")
        return (merged, recorder.conflicts)
    }

    public static func exercise(base: PerformedExercise?, local: PerformedExercise, remote: PerformedExercise) -> PerformedExercise {
        exercise(base, local, remote, Recorder(.local), path: "")
    }

    public static func set(base: PerformedSet?, local: PerformedSet, remote: PerformedSet) -> PerformedSet {
        set(base, local, remote, Recorder(.local), path: "")
    }

    private static func session(_ base: WorkoutSession?, _ local: WorkoutSession, _ remote: WorkoutSession,
                                _ recorder: Recorder, path: String) -> WorkoutSession {
        var merged = local
        merged.name = value(base?.name, local.name, remote.name, recorder, "name")
        merged.startedAt = value(base?.startedAt, local.startedAt, remote.startedAt, recorder, "startedAt")
        merged.endedAt = value(base?.endedAt, local.endedAt, remote.endedAt, recorder, "endedAt")
        merged.timeZoneID = value(base?.timeZoneID, local.timeZoneID, remote.timeZoneID, recorder, "timeZoneID")
        merged.notes = value(base?.notes, local.notes, remote.notes, recorder, "notes")
        merged.bodyweight = value(base?.bodyweight, local.bodyweight, remote.bodyweight, recorder, "bodyweight")
        merged.program = value(base?.program, local.program, remote.program, recorder, "program")
        merged.exercises = list(base?.exercises, local.exercises, remote.exercises, recorder, "exercises") { b, l, r, path in
            exercise(b, l, r, recorder, path: path)
        }
        return merged
    }

    private static func exercise(_ base: PerformedExercise?, _ local: PerformedExercise, _ remote: PerformedExercise,
                                 _ recorder: Recorder, path: String) -> PerformedExercise {
        func at(_ field: String) -> String { path.isEmpty ? field : "\(path).\(field)" }
        var merged = local
        merged.exerciseID = value(base?.exerciseID, local.exerciseID, remote.exerciseID, recorder, at("exerciseID"))
        merged.notes = value(base?.notes, local.notes, remote.notes, recorder, at("notes"))
        merged.supersetID = value(base?.supersetID, local.supersetID, remote.supersetID, recorder, at("supersetID"))
        merged.restOverride = value(base?.restOverride, local.restOverride, remote.restOverride, recorder, at("restOverride"))
        merged.slotID = value(base?.slotID, local.slotID, remote.slotID, recorder, at("slotID"))
        merged.sets = list(base?.sets, local.sets, remote.sets, recorder, at("sets")) { b, l, r, path in
            set(b, l, r, recorder, path: path)
        }
        return merged
    }

    private static func set(_ base: PerformedSet?, _ local: PerformedSet, _ remote: PerformedSet,
                            _ recorder: Recorder, path: String) -> PerformedSet {
        func at(_ field: String) -> String { path.isEmpty ? field : "\(path).\(field)" }
        var merged = local
        merged.kind = value(base?.kind, local.kind, remote.kind, recorder, at("kind"))
        merged.side = value(base?.side, local.side, remote.side, recorder, at("side"))
        merged.efforts = value(base?.efforts, local.efforts, remote.efforts, recorder, at("efforts"))
        merged.rir = value(base?.rir, local.rir, remote.rir, recorder, at("rir"))
        merged.completedAt = value(base?.completedAt, local.completedAt, remote.completedAt, recorder, at("completedAt"))
        return merged
    }

    /// Custom exercises merge as whole values: whichever side changed wins,
    /// and local wins when both did.
    public static func exerciseDefinition(base: Exercise?, local: Exercise, remote: Exercise) -> Exercise {
        value(base, local, remote)
    }

    static func value<T: Equatable>(_ base: T?, _ local: T, _ remote: T) -> T {
        value(base, local, remote, Recorder(.local), "")
    }

    static func value<T: Equatable>(_ base: T?, _ local: T, _ remote: T, _ recorder: Recorder, _ path: String) -> T {
        if local == remote { return local }
        if let base {
            if local == base { return remote }
            if remote == base { return local }
        }
        recorder.conflicts.append(path)
        return recorder.prefer == .local ? local : remote
    }

    private static func list<Element: Identifiable & Equatable>(
        _ base: [Element]?, _ local: [Element], _ remote: [Element], _ recorder: Recorder, _ path: String,
        merge: (Element?, Element, Element, String) -> Element
    ) -> [Element] {
        let baseByID = Dictionary((base ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        func at(_ item: Element) -> String { "\(path)[\(item.id)]" }
        var result: [Element] = []
        for item in local {
            let original = baseByID[item.id]
            if let other = remoteByID[item.id] {
                result.append(merge(original, item, other, at(item)))
            } else if original == nil {
                result.append(item)
            } else if item != original {
                // The remote deleted something local changed.
                recorder.conflicts.append(at(item))
                if recorder.prefer == .local { result.append(item) }
            }
        }
        for item in remote where !localIDs.contains(item.id) {
            let original = baseByID[item.id]
            if original == nil {
                result.append(item)
            } else if item != original {
                // Local deleted something the remote changed.
                recorder.conflicts.append(at(item))
                result.append(item)
            }
        }
        return result
    }

    // MARK: Fields

    /// Three-way merge of a record's top-level fields, as JSON. A field takes
    /// whichever side changed it; one both changed differently takes the
    /// preferred side and is reported. Fields in one of `groups` (an amount's
    /// grams, serving and quantity) merge together, as one value, under the
    /// group's first name. Values that aren't objects merge whole, reported
    /// as "*". Without a base, a field only one side has is taken from it.
    public static func fields(base: JSONValue?, local: JSONValue, remote: JSONValue, groups: [[String]] = [],
                              preferring prefer: Preference = .local) -> (merged: JSONValue, conflicts: [String]) {
        guard case .object(let mine) = local, case .object(let theirs) = remote else {
            let recorder = Recorder(prefer)
            let merged = value(base, local, remote, recorder, "*")
            return (merged, recorder.conflicts)
        }
        var original: [String: JSONValue]?
        if case .object(let fields)? = base { original = fields }
        let grouped = Set(groups.joined())
        let units = groups + Set(mine.keys).union(theirs.keys).subtracting(grouped).sorted().map { [$0] }
        var merged = mine
        var conflicts: [String] = []
        for unit in units {
            func part(_ fields: [String: JSONValue]) -> [String: JSONValue] { fields.filter { unit.contains($0.key) } }
            let l = part(mine), r = part(theirs), b = original.map(part)
            if l == r { continue }
            let chosen: [String: JSONValue]
            if let b, l == b {
                chosen = r
            } else if let b, r == b {
                chosen = l
            } else if b == nil, l.isEmpty || r.isEmpty {
                chosen = l.isEmpty ? r : l
            } else {
                conflicts.append(unit[0])
                chosen = prefer == .local ? l : r
            }
            for key in unit { merged[key] = chosen[key] }
        }
        return (.object(merged), conflicts)
    }
}
