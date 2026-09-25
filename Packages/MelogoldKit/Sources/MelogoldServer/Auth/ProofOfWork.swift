import CryptoKit
import Foundation

/// Proof-of-work регистрации (API §4.3): `nonce` — десятичное число, такое что `sha256(challenge + ":" + nonce)`
/// начинается хотя бы с `bits` нулевых битов. Векторы — `spec/pow.vectors.json`.
public enum ProofOfWork {
    /// Первое подходящее число по порядку "0", "1", … — как в векторах. `nil` — задача отменена.
    public static func firstNonce(challenge: String, bits: Int) -> String? {
        search(challenge: challenge, bits: bits, start: 0, stride: 1)
    }

    /// Решение на всех ядрах: каждое ищет своё подмножество чисел. Сервер принимает любое подходящее число,
    /// поэтому ответ может отличаться от `firstNonce`, но он верный. На часах ядра два, на iPhone — шесть.
    public static func solve(challenge: String, bits: Int) async -> String? {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        guard workers > 1, bits > 8 else { return firstNonce(challenge: challenge, bits: bits) }
        return await withTaskGroup(of: String?.self) { group in
            for worker in 0 ..< workers {
                group.addTask(priority: .userInitiated) {
                    search(challenge: challenge, bits: bits, start: UInt64(worker), stride: UInt64(workers))
                }
            }
            defer { group.cancelAll() }
            for await found in group {
                if let found { return found }
            }
            return nil
        }
    }

    /// Число ведущих нулевых битов, старший бит первого байта — первый.
    public static func leadingZeroBits(_ digest: some Sequence<UInt8>) -> Int {
        var count = 0
        for byte in digest {
            if byte == 0 {
                count += 8
            } else {
                return count + byte.leadingZeroBitCount
            }
        }
        return count
    }

    private static func search(challenge: String, bits: Int, start: UInt64, stride: UInt64) -> String? {
        // Префикс хэшируется один раз, дальше копируется состояние: sha256 — значение, копия дешёвая
        var prefix = SHA256()
        prefix.update(data: Data("\(challenge):".utf8))
        var nonce = start
        while true {
            if nonce % 4096 < stride, Task.isCancelled { return nil }
            var hasher = prefix
            let text = String(nonce)
            hasher.update(data: Data(text.utf8))
            if leadingZeroBits(hasher.finalize()) >= bits { return text }
            nonce += stride
        }
    }
}
