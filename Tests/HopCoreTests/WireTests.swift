import XCTest
@testable import HopCore
final class WireTests: XCTestCase {
    func testRelativePathsAndTraversal() throws {
        XCTAssertEqual(try SafePath.components("Фото/снимок.jpg"), ["Фото", "снимок.jpg"])
        for value in ["../secret", "/etc/passwd", "C:/private", "a//b", "a/./b", "a/../../b", "a\\..\\b", "a\u{0}b"] { XCTAssertThrowsError(try SafePath.components(value), value) }
    }
    func testFixedLengthAndDuplicateHeaders() throws {
        let h = try HTTPHead.parse(Data("POST /offer HTTP/1.1\r\nContent-Length: 3\r\n\r\n".utf8))
        XCTAssertEqual(h.length, 3); XCTAssertEqual(h.path, "/offer")
        for headers in ["Content-Length: 2\r\nContent-Length: 3", "Content-Length: -1", "Transfer-Encoding: chunked\r\nContent-Length: 2", "Host: a\r\nHost: b"] {
            XCTAssertThrowsError(try HTTPHead.parse(Data("POST /offer HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)))
        }
    }
    func testIDAndLocalAddressValidation() {
        XCTAssertTrue(HopValidation.validID("phone-123_test")); XCTAssertFalse(HopValidation.validID("../phone"))
        XCTAssertTrue(HopValidation.localAddress("192.168.2.7")); XCTAssertTrue(HopValidation.localAddress("fe80::1234%en0"))
        XCTAssertFalse(HopValidation.localAddress("example.com")); XCTAssertFalse(HopValidation.localAddress("8.8.8.8"))
        XCTAssertFalse(HopValidation.localAddress("10.bad.0.0.1"))
    }
}
