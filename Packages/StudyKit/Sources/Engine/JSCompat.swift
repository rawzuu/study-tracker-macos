/// Chování JavaScriptu tam, kde se Swift liší a na výsledku záleží (parita s webem).
enum JS {
    /// `Math.round`: nejbližší celé číslo, poloviny nahoru (−2,5 → −2). `rounded()` by dalo −3.
    static func round(_ x: Double) -> Double {
        let r = x.rounded(.down)
        return x - r >= 0.5 ? r + 1 : r
    }

    /// `Array.prototype.sort` z V8 pro pole do 64 prvků: úvodní běh a binární vkládání (TimSort
    /// krátké pole nedělí). Dává stejné pořadí jako web i pro porovnání, které není konzistentní –
    /// web řadí položky kalendáře `a.start - b.start || (a.kind === 'plan' ? -1 : 1)`, takže o pořadí
    /// dvou bloků se shodným začátkem rozhoduje postup řazení.
    ///
    /// Delší pole se v kalendáři nevyskytují; pro ně je tu obyčejné stabilní řazení (pro konzistentní
    /// porovnání dává stejný výsledek jako V8).
    static func sort<T>(_ items: [T], by compare: (T, T) -> Int) -> [T] {
        var a = items
        let n = a.count
        guard n >= 2 else { return a }
        guard n < 64 else { return a.sorted { compare($0, $1) < 0 } }

        // CountAndMakeRun: neklesající nebo ostře klesající úvodní běh (klesající se otočí)
        var run = 2
        let descending = compare(a[1], a[0]) < 0
        var previous = a[1]
        while run < n {
            let order = compare(a[run], previous)
            if descending ? order >= 0 : order < 0 { break }
            previous = a[run]
            run += 1
        }
        if descending { a[0..<run].reverse() }

        // BinaryInsertionSort: zbytek pole se vkládá za běh
        for start in run..<n {
            let pivot = a[start]
            var left = 0, right = start
            while left < right {
                let mid = left + (right - left) >> 1
                if compare(pivot, a[mid]) < 0 { right = mid } else { left = mid + 1 }
            }
            a.remove(at: start)
            a.insert(pivot, at: left)
        }
        return a
    }
}
