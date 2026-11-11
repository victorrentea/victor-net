import XCTest
@testable import VictorNet

/// ⇄ over the bars: only when the SIM not carrying data is 2+ bars better.
final class SimSwitchHintTests: XCTestCase {
    private func sim(_ name: String, data: Bool, _ level: Int) -> SimSignal {
        SimSignal(name: name, isData: data, level: level, operatorName: name, network: "LTE", rsrp: nil, sinr: nil)
    }

    func testTwoBarsBetterOnTheOtherSim() {
        let sims = [sim("orange", data: true, 1), sim("vodafone", data: false, 3)]
        XCTAssertEqual(SimSwitchHint.better(sims)?.name, "vodafone")
        XCTAssertEqual(SimSwitchHint.tooltip(sims[1], over: sims),
                       "Vodafone has 3/4, data is on Orange with 1/4 — try switching the data SIM")
    }

    func testOneBarIsNotWorthIt() {
        XCTAssertNil(SimSwitchHint.better([sim("orange", data: true, 2), sim("vodafone", data: false, 3)]))
    }

    func testNotWhenTheDataSimIsTheBetterOne() {
        XCTAssertNil(SimSwitchHint.better([sim("orange", data: true, 4), sim("vodafone", data: false, 0)]))
    }

    func testOneSimOrNoDataSimSaysNothing() {
        XCTAssertNil(SimSwitchHint.better([sim("orange", data: true, 0)]))
        XCTAssertNil(SimSwitchHint.better([sim("orange", data: false, 0), sim("vodafone", data: false, 4)]))
    }
}
