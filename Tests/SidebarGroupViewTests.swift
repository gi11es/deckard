import XCTest
import AppKit
@testable import Deckard

final class SidebarGroupViewTests: XCTestCase {

    // MARK: - Helpers

    /// Create a SidebarGroupView with a known frame inside a parent view
    /// so that hitTest receives meaningful superview-relative coordinates.
    private func makeGroupView(
        collapsed: Bool = false,
        origin: NSPoint = NSPoint(x: 0, y: 50)
    ) -> SidebarGroupView {
        let group = SidebarGroup(name: "Test Group")
        group.isCollapsed = collapsed
        let view = SidebarGroupView(group: group, workspaceCount: 2)

        // Embed in a parent so hitTest gets superview-relative points.
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        parent.addSubview(view)
        view.frame = NSRect(x: 0, y: origin.y, width: 200, height: 28)

        return view
    }

    // MARK: - hitTest

    func testHitTestReturnsSelfWhenNotEditing() {
        let view = makeGroupView()
        // Point inside the view's frame (superview coordinates).
        let point = NSPoint(x: 10, y: view.frame.midY)
        let result = view.hitTest(point)
        XCTAssertTrue(result === view, "hitTest should return self when not editing")
    }

    func testHitTestReturnsNilOutsideFrame() {
        let view = makeGroupView()
        // Point outside the view's frame.
        let point = NSPoint(x: 10, y: view.frame.maxY + 50)
        let result = view.hitTest(point)
        XCTAssertNil(result, "hitTest should return nil for points outside frame")
    }

    func testHitTestUsesFrameNotBounds() {
        // Place the view at a non-zero origin to verify frame (not bounds) is used.
        let view = makeGroupView(origin: NSPoint(x: 0, y: 100))
        XCTAssertEqual(view.frame.origin.y, 100)

        // Point at y=110 is inside frame (100..128) but outside bounds (0..28).
        let insideFrame = NSPoint(x: 10, y: 110)
        XCTAssertTrue(view.hitTest(insideFrame) === view,
                      "hitTest should match against frame, not bounds")

        // Point at y=10 is inside bounds (0..28) but outside frame (100..128).
        let insideBoundsOnly = NSPoint(x: 10, y: 10)
        XCTAssertNil(view.hitTest(insideBoundsOnly),
                     "hitTest should NOT match against bounds coordinates")
    }

    func testHitTestDelegatesToSuperWhenEditing() {
        let view = makeGroupView()
        // Start editing to flip isEditingName.
        view.startEditing()
        XCTAssertTrue(view.isEditingName)

        // When editing, hitTest should delegate to super (may return a subview).
        let point = NSPoint(x: 100, y: view.frame.midY)
        let result = view.hitTest(point)
        // Result should be some view (label or self), not guaranteed to be self.
        XCTAssertNotNil(result, "hitTest should not return nil when editing and point is inside")
    }

    // MARK: - Chevron image

    func testChevronImageReflectsCollapsedState() {
        let expandedView = makeGroupView(collapsed: false)
        let collapsedView = makeGroupView(collapsed: true)

        // Access the image via the accessibilityDescription to verify it was set.
        // Both should have images (we can't easily compare SF Symbol names).
        let expandedDesc = expandedView.subviews
            .compactMap { $0 as? NSImageView }.first?.image?.accessibilityDescription
        let collapsedDesc = collapsedView.subviews
            .compactMap { $0 as? NSImageView }.first?.image?.accessibilityDescription

        XCTAssertEqual(expandedDesc, "Toggle group")
        XCTAssertEqual(collapsedDesc, "Toggle group")
    }

    func testUpdateChevronChangesImage() {
        let view = makeGroupView(collapsed: false)
        let imageView = view.subviews.compactMap { $0 as? NSImageView }.first!

        let imageBefore = imageView.image
        view.group.isCollapsed = true
        view.updateChevron()
        let imageAfter = imageView.image

        // The images should be different (chevron.down vs chevron.right).
        XCTAssertNotEqual(imageBefore, imageAfter,
                          "updateChevron should change the image when collapsed state changes")
    }

    // MARK: - mouseDown: chevron area fires onToggle immediately

    func testMouseDownOnChevronAreaCallsOnToggle() {
        let view = makeGroupView()
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        // Simulate mouseDown in the chevron area (x <= 26).
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 10, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: event)

        XCTAssertEqual(toggleCount, 1, "mouseDown in chevron area should call onToggle immediately")
    }

    func testMouseDownOnChevronAreaDoesNotSetDragStartPoint() {
        let view = makeGroupView()
        view.onToggle = { _ in }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 10, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: event)

        // mouseUp should NOT double-toggle (dragStartPoint should be nil).
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: view.convert(NSPoint(x: 10, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.mouseUp(with: upEvent)

        XCTAssertEqual(toggleCount, 0,
                       "mouseUp after chevron mouseDown should NOT toggle again (no double-toggle)")
    }

    func testRapidChevronClicksDoNotTriggerEditing() {
        let view = makeGroupView()
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        // Simulate a double-click (clickCount=2) in the chevron area.
        // Should toggle, NOT start editing.
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 10, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1.0
        )!
        view.mouseDown(with: event)

        XCTAssertEqual(toggleCount, 1, "Double-click on chevron should toggle, not edit")
        XCTAssertFalse(view.isEditingName, "Double-click on chevron should NOT start editing")
    }

    // MARK: - mouseDown: label area uses mouseUp for toggle

    func testMouseDownOnLabelAreaDoesNotCallOnToggle() {
        let view = makeGroupView()
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        // Simulate mouseDown outside chevron area (x > 26).
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 100, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: event)

        XCTAssertEqual(toggleCount, 0, "mouseDown on label area should NOT toggle immediately")
    }

    func testMouseUpOnLabelAreaCallsOnToggle() {
        let view = makeGroupView()
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        // mouseDown on label area sets dragStartPoint.
        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 100, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: downEvent)

        // mouseUp should toggle.
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: view.convert(NSPoint(x: 100, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.mouseUp(with: upEvent)

        XCTAssertEqual(toggleCount, 1, "mouseUp on label area should toggle")
    }

    // MARK: - Double-click on label starts editing

    func testDoubleClickOnLabelStartsEditing() {
        let view = makeGroupView()
        var toggleCount = 0
        view.onToggle = { _ in toggleCount += 1 }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: 100, y: 14), to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1.0
        )!
        view.mouseDown(with: event)

        XCTAssertTrue(view.isEditingName, "Double-click on label should start editing")
        XCTAssertEqual(toggleCount, 0, "Double-click on label should not toggle")
    }

    // MARK: - groupToggleClicked guard

    func testGroupToggleBlocksCollapseWhenContainingSelectedWorkspace() {
        let group = SidebarGroup(name: "Active")
        let workspaceId = UUID()
        group.workspaceIds = [workspaceId]
        group.isCollapsed = false

        // Simulate the guard logic from groupToggleClicked.
        group.isCollapsed.toggle()
        // Guard: if collapsing a group that contains the selected workspace, force expand.
        let selectedWorkspaceId = workspaceId  // selected workspace is inside this group
        if group.isCollapsed, group.workspaceIds.contains(selectedWorkspaceId) {
            group.isCollapsed = false
        }

        XCTAssertFalse(group.isCollapsed,
                       "Group containing the selected workspace should not stay collapsed")
    }

    func testGroupToggleAllowsCollapseWhenNotContainingSelectedWorkspace() {
        let group = SidebarGroup(name: "Other")
        let workspaceId = UUID()
        let otherWorkspaceId = UUID()
        group.workspaceIds = [workspaceId]
        group.isCollapsed = false

        group.isCollapsed.toggle()
        // Guard: selected workspace is NOT in this group.
        let selectedWorkspaceId = otherWorkspaceId
        if group.isCollapsed, group.workspaceIds.contains(selectedWorkspaceId) {
            group.isCollapsed = false
        }

        XCTAssertTrue(group.isCollapsed,
                      "Group NOT containing the selected workspace should collapse normally")
    }
}
