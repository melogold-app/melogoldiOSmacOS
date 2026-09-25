import Testing
@testable import MelogoldServer

@Suite("Коды входа и восстановления — нормализация API §1.6")
struct LinkCodeTests {
    @Test(arguments: ["K7QX-M2PD", "k7qx m2pd", "k7qxm2pd", " K7QX_M2PD "])
    func userCode(_ input: String) {
        #expect(LinkCode.userCode(input) == "K7QXM2PD")
    }

    @Test func lookalikes() {
        #expect(LinkCode.userCode("oIL0-abcd") == "0110ABCD")
    }

    @Test(arguments: ["K7QX-M2P", "K7QX-M2PD-1", "K7QX-M2PU", ""])
    func rejected(_ input: String) {
        #expect(LinkCode.userCode(input) == nil)
    }

    @Test func recoveryCode() {
        #expect(LinkCode.recoveryCode("7kq2 mx9d 4tnp b8rw 3hzf") == "7KQ2MX9D4TNPB8RW3HZF")
        #expect(LinkCode.grouped("7KQ2MX9D4TNPB8RW3HZF") == "7KQ2-MX9D-4TNP-B8RW-3HZF")
        #expect(LinkCode.grouped("K7QXM2PD") == "K7QX-M2PD")
    }
}
