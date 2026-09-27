import XCTest
@testable import TabType

final class SettingsNavigationTests: XCTestCase {

    func testSidebarHasExactlyFourItemsInOrder() {
        XCTAssertEqual(SettingsItem.allCases, [.suggestions, .apps, .modelAndPower, .about])
        XCTAssertEqual(SettingsItem.allCases.map(\.rawValue),
                       ["Suggestions", "Apps", "Model & Power", "About"])
    }

    func testItemSectionMappingMatchesSpec() {
        XCTAssertEqual(SettingsItem.suggestions.anchors,
                       [.permissions, .general, .emoji, .textTools, .personalization, .shortcuts])
        XCTAssertEqual(SettingsItem.apps.anchors, [.apps, .context])
        XCTAssertEqual(SettingsItem.modelAndPower.anchors, [.engine, .battery, .advanced])
        XCTAssertEqual(SettingsItem.about.anchors, [.about, .statistics, .setupStatus])
    }

    func testEveryAnchorBelongsToExactlyOneItem() {
        let all = SettingsItem.allCases.flatMap(\.anchors)
        XCTAssertEqual(all.count, Set(all).count, "an anchor is listed under two items")
        XCTAssertEqual(Set(all), Set(SettingsAnchor.allCases), "an anchor is not reachable")
        for item in SettingsItem.allCases {
            for anchor in item.anchors { XCTAssertEqual(anchor.item, item) }
        }
    }

    func testDefaultDestinationGoesToPermissionsUntilSetupIsDone() {
        let permissions = SettingsDestination(item: .suggestions, anchor: .permissions)
        XCTAssertEqual(SettingsNavigator.defaultDestination(axGranted: false, modelReady: true), permissions)
        XCTAssertEqual(SettingsNavigator.defaultDestination(axGranted: true, modelReady: false), permissions)
        XCTAssertEqual(SettingsNavigator.defaultDestination(axGranted: false, modelReady: false), permissions)
        XCTAssertEqual(SettingsNavigator.defaultDestination(axGranted: true, modelReady: true),
                       SettingsDestination(item: .suggestions, anchor: nil))
    }

    func testMenuEntryDestinations() {
        for (ax, model) in [(true, true), (false, false)] {
            XCTAssertEqual(SettingsNavigator.destination(for: .statistics, axGranted: ax, modelReady: model),
                           SettingsDestination(item: .about, anchor: .statistics))
            XCTAssertEqual(SettingsNavigator.destination(for: .about, axGranted: ax, modelReady: model),
                           SettingsDestination(item: .about, anchor: nil))
            XCTAssertEqual(SettingsNavigator.destination(for: .settings, axGranted: ax, modelReady: model),
                           SettingsNavigator.defaultDestination(axGranted: ax, modelReady: model))
        }
    }

    func testOnlyAppsGetsTheWideWindow() {
        XCTAssertEqual(SettingsNavigator.contentWidth(for: .apps), 980)
        for item in SettingsItem.allCases where item != .apps {
            XCTAssertEqual(SettingsNavigator.contentWidth(for: item), 760)
        }
    }
}
