import Foundation
import Testing
@testable import MelogoldCore

/// Одна обложка разных размеров — один ключ: по нему большая обложка «Сейчас играет» берёт маленькую из мини-плеера, пока
/// грузится (задание 0033 §6).
@Suite("Обложка в разных размерах")
struct ThumbnailFamilyTests {
    @Test func googleSizesShareTheKey() {
        let original = "https://lh3.googleusercontent.com/abc=w60-h60-l90-rj"
        let small = Thumbnails.sized(original, px: 108)!
        let big = Thumbnails.sized(original, px: 1200)!
        #expect(small != big)
        #expect(Thumbnails.family(small) == Thumbnails.family(big))
        #expect(Thumbnails.family(big) == "https://lh3.googleusercontent.com/abc")
        #expect(Thumbnails.family("//yt3.ggpht.com/x=s88") == Thumbnails.family(Thumbnails.sized("//yt3.ggpht.com/x=s88", px: 600)!))
    }

    @Test func videoPreviewsShareTheVideo() {
        let original = Thumbnails.forVideo("xtxjm7ciwmc")
        let small = Thumbnails.sized(original, px: 120)!
        let big = Thumbnails.sized(original, px: 1200)!
        #expect(small.hasSuffix("mqdefault.jpg") && big.hasSuffix("hq720.jpg"))
        #expect(Thumbnails.family(small) == Thumbnails.family(big))
        #expect(Thumbnails.family(big) != Thumbnails.family(Thumbnails.sized(Thumbnails.forVideo("dQw4w9WgXcQ"), px: 1200)!))
    }

    @Test func otherAddressesAreTheirOwnKey() {
        #expect(Thumbnails.family("https://example.com/cover.jpg") == "https://example.com/cover.jpg")
        #expect(Thumbnails.family("https://lh3.googleusercontent.com/abc") == "https://lh3.googleusercontent.com/abc")
    }
}
