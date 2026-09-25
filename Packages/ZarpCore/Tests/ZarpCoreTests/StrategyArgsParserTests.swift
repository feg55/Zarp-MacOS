import XCTest
@testable import ZarpCore

final class StrategyArgsParserTests: XCTestCase {
    func testEmptyArgsIsDirect() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3, args: "")
        XCTAssertTrue(plan.isDirect)
    }

    func testCleanQuicFake() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=6")
        XCTAssertNil(plan.parseIssue)
        XCTAssertEqual(plan.fakeSteps, [FakeStep(blob: .quicGoogle, repeats: 6)])
    }

    func testTwoFakeStepsInOrder() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=3 --lua-desync=fake:blob=quic_vk:repeats=3")
        XCTAssertEqual(plan.fakeSteps, [
            FakeStep(blob: .quicGoogle, repeats: 3),
            FakeStep(blob: .quicVk, repeats: 3),
        ])
    }

    func testTTLAppliesOnlyToFakes() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:ip_ttl=4:ip6_ttl=4:repeats=6")
        XCTAssertEqual(plan.fakeSteps, [FakeStep(blob: .quicGoogle, repeats: 6, ipTTL: 4, ip6TTL: 4)])
    }

    func testBadsumIsFlaggedNotSilentlyDropped() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:badsum:repeats=6")
        XCTAssertTrue(plan.fakeSteps.isEmpty)
        XCTAssertEqual(plan.parseIssue?.key, "strategy.badsum")
    }

    func testWireGuardFakeParsesLikeQuicFake() {
        let plan = StrategyArgsParser.parse(transport: .wireGuard,
            args: "--payload=wireguard_initiation --lua-desync=fake:blob=quic_google:repeats=6")
        XCTAssertNil(plan.parseIssue)
        XCTAssertEqual(plan.fakeSteps, [FakeStep(blob: .quicGoogle, repeats: 6)])
    }

    func testH2PlainSplitParsesCleanly() {
        let plan = StrategyArgsParser.parse(transport: .masqueH2,
            args: "--payload=tls_client_hello --lua-desync=multisplit:pos=1,midsld")
        XCTAssertNil(plan.parseIssue)
        XCTAssertEqual(plan.tcpDesync, TCPDesyncStep(mode: .split, positions: ["1", "midsld"]))
    }

    func testH2DisorderParsesCleanly() {
        let plan = StrategyArgsParser.parse(transport: .masqueH2,
            args: "--payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld")
        XCTAssertEqual(plan.tcpDesync?.mode, .disorder)
    }

    func testH2FakeIsUnsupportedRegardlessOfParams() {
        // Over TCP a plain socket send cannot precede the real ClientHello with a decoy without
        // corrupting the handshake — that needs raw-socket tricks, same reasoning as Android Zarp.
        let plan = StrategyArgsParser.parse(transport: .masqueH2,
            args: "--payload=tls_client_hello --lua-desync=fake:blob=tls_google:tcp_md5:repeats=6 --lua-desync=multisplit:pos=1,midsld")
        XCTAssertNotNil(plan.parseIssue)
        XCTAssertEqual(plan.parseIssue?.key, "strategy.unknownFeature")
    }

    func testSeqovlIsFlagged() {
        let plan = StrategyArgsParser.parse(transport: .masqueH2,
            args: "--payload=tls_client_hello --lua-desync=multisplit:pos=2:seqovl=681:seqovl_pattern=tls_google")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.unknownFeature")
    }

    func testHostfakesplitIsFlagged() {
        let plan = StrategyArgsParser.parse(transport: .masqueH2,
            args: "--payload=tls_client_hello --lua-desync=hostfakesplit:host=vk.com:tcp_md5")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.unknownFeature")
    }

    func testPayloadMismatchIsRejected() {
        let plan = StrategyArgsParser.parse(transport: .masqueH2, args: "--payload=quic_initial")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.badSyntax")
    }

    func testUnknownBlobIsRejected() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=not_a_real_blob:repeats=6")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.badSyntax")
    }

    func testRepeatsOutOfRangeIsRejected() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3,
            args: "--payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=999")
        XCTAssertNotNil(plan.parseIssue)
    }

    func testUnknownTopLevelOptionIsRejected() {
        let plan = StrategyArgsParser.parse(transport: .masqueH3, args: "--not-a-real-option=1")
        XCTAssertEqual(plan.parseIssue?.key, "strategy.badSyntax")
    }
}
