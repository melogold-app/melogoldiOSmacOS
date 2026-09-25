import Foundation

/// Одно изменение треков плейлиста в терминах ops сервера (API §4.8).
public enum ItemChange: Equatable, Sendable {
    case remove(videoId: String)
    /// Новые треки одним блоком: сразу после `after`, иначе перед `before`, иначе в конец.
    case add(videoIds: [String], after: String?, before: String?)
    /// Трек сменил место: сразу после `after`, иначе перед `before`, иначе в конец.
    case move(videoId: String, after: String?, before: String?)
}

/// Чистые функции порядка плейлиста (DESIGN §3.7 «Якоря», §3.13.3) — одинаковые на сервере и во всех клиентах,
/// векторы `spec/playlist-ops.vectors.json` (раздел `anchors`). Список — `videoId` треков плейлиста по порядку.
public enum PlaylistAnchors {
    /// Без повторов, первое вхождение остаётся.
    public static func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Куда встаёт вставка: `after` в списке → сразу после него; иначе `before` в списке → перед ним; иначе в конец.
    public static func anchorIndex(_ list: [String], after: String?, before: String?) -> Int {
        if let after, let index = list.firstIndex(of: after) { return index + 1 }
        if let before, let index = list.firstIndex(of: before) { return index }
        return list.count
    }

    /// `playlist.items.add`: `dedupe(ids) − list` одним блоком у якорей.
    public static func applyAdd(_ list: [String], _ ids: [String], after: String? = nil, before: String? = nil) -> [String] {
        let present = Set(list)
        let fresh = dedupe(ids).filter { !present.contains($0) }
        var result = list
        result.insert(contentsOf: fresh, at: anchorIndex(list, after: after, before: before))
        return result
    }

    /// `playlist.item.remove`: `list − v`.
    public static func applyRemove(_ list: [String], _ videoId: String) -> [String] {
        list.filter { $0 != videoId }
    }

    /// `playlist.item.move`: `v ∉ list` → без изменений; иначе `v` встаёт в `list − v` по якорям.
    public static func applyMove(_ list: [String], _ videoId: String, after: String? = nil, before: String? = nil) -> [String] {
        guard list.contains(videoId) else { return list }
        var rest = applyRemove(list, videoId)
        rest.insert(videoId, at: anchorIndex(rest, after: after, before: before))
        return rest
    }

    /// `playlist.items.replace`: `dedupe(ids)`.
    public static func applyReplace(_ list: [String], _ ids: [String]) -> [String] {
        dedupe(ids)
    }

    /// `playlist.import`: недостающие дописываются в конец в данном порядке.
    public static func applyImport(_ list: [String], _ ids: [String]) -> [String] {
        let present = Set(list)
        return list + dedupe(ids).filter { !present.contains($0) }
    }

    /// `playlist.create`: пустой список становится `dedupe(ids)`, непустой не меняется.
    public static func applyCreate(_ list: [String], _ ids: [String]) -> [String] {
        list.isEmpty ? dedupe(ids) : list
    }
}

/// Ops, которые превращают плейлист, каким его знал сервер (`before`, в его порядке), в плейлист этого устройства
/// (`after`) — вариант синхронизации со снимком (REWRITE §4.12a Android, `PlaylistDiff.kt`; Windows `PlaylistDiff.cs`):
/// сначала убранные треки, затем в новом порядке новые треки блоками и перемещённые, каждый — сразу после соседа
/// в новом порядке (у стоящих в начале — перед первым оставшимся). Треки самой длинной цепочки, сохранившей порядок,
/// остаются на местах, поэтому перенос одного трека — одна op. `items.replace` для ручных правок не используется:
/// он стирает то, что добавило другое устройство (грабли §9 п. 6).
public enum PlaylistDiff {
    /// Не больше стольких треков в одном `playlist.items.add` (API §4.8).
    public static let maxAdd = 500

    public static func changes(before: [String], after: [String]) -> [ItemChange] {
        var changes: [ItemChange] = []
        let afterSet = Set(after)
        var beforeIndex: [String: Int] = [:]
        for (index, videoId) in before.enumerated() where beforeIndex[videoId] == nil { beforeIndex[videoId] = index }

        for videoId in PlaylistAnchors.dedupe(before) where !afterSet.contains(videoId) {
            changes.append(.remove(videoId: videoId))
        }

        let kept = after.filter { beforeIndex[$0] != nil }
        let staying = Set(longestIncreasingSubsequence(kept.compactMap { beforeIndex[$0] }).map { kept[$0] })
        let firstStaying = after.first { staying.contains($0) }

        var previous: String?
        var block: [String] = []
        var blockAfter: String?

        func flush() {
            var anchor = blockAfter
            var start = 0
            while start < block.count {
                let chunk = Array(block[start ..< min(start + maxAdd, block.count)])
                changes.append(.add(videoIds: chunk, after: anchor, before: anchor == nil ? firstStaying : nil))
                anchor = chunk.last
                start += maxAdd
            }
            block.removeAll()
        }

        for videoId in after {
            if beforeIndex[videoId] == nil {
                if block.isEmpty { blockAfter = previous }
                block.append(videoId)
            } else {
                flush()
                if !staying.contains(videoId) {
                    changes.append(.move(videoId: videoId, after: previous, before: previous == nil ? firstStaying : nil))
                }
            }
            previous = videoId
        }
        flush()
        return changes
    }

    /// Индексы (по возрастанию) одной самой длинной строго возрастающей подпоследовательности, O(n log n):
    /// терпеливая сортировка со ссылками на предшественника. Выбор среди равных по длине — как у сервера
    /// (`lis.ts`): векторы `spec/playlist-ops.vectors.json` (раздел `lis`) его закрепляют.
    public static func longestIncreasingSubsequence(_ values: [Int]) -> [Int] {
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            // Первый хвост со значением >= value: равные значения друг друга не продолжают
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var result: [Int] = []
        var index = tails.last ?? -1
        while index >= 0 {
            result.append(index)
            index = previous[index]
        }
        return result.reversed()
    }

    /// Применяет изменения по правилам якорей — для проверки: `apply(before, changes(before, after)) == after`.
    public static func apply(_ list: [String], _ changes: [ItemChange]) -> [String] {
        changes.reduce(list) { result, change in
            switch change {
            case .remove(let videoId): PlaylistAnchors.applyRemove(result, videoId)
            case .add(let videoIds, let after, let before): PlaylistAnchors.applyAdd(result, videoIds, after: after, before: before)
            case .move(let videoId, let after, let before): PlaylistAnchors.applyMove(result, videoId, after: after, before: before)
            }
        }
    }
}
