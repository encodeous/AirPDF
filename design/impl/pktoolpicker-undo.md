# PKToolPicker Undo/Redo with Empty Canvas

## Context

AirPDF keeps `PKCanvasView` empty between strokes — finalized strokes live as `PDFAnnotation` stamps, not on the canvas. This breaks `PKToolPicker`'s built-in undo/redo buttons.

## How PKToolPicker Undo/Redo Actually Works

**Common misconception**: PKToolPicker undo/redo routes through the responder chain (`undo:` / `redo:` selectors). It does not.

**Reality**: PKToolPicker undo/redo is tied to `PKCanvasView`'s internal `UndoManager`, which is the `undoManager` of the view controller that owns the canvas (the VC's `undoManager` property, inherited from `UIResponder`). The buttons are enabled/disabled based on whether that `undoManager` has registered undo/redo actions. When tapped, they call `undoManager.undo()` / `undoManager.redo()` directly.

This means:
- If the canvas is empty and nothing is registered on the VC's `undoManager`, the buttons are grayed out.
- `@objc undo(_:)` / `redo(_:)` on the VC are **not** called by PKToolPicker — those are responder chain methods for system undo (e.g. keyboard shortcut ⌘Z), not for the tool picker buttons.
- Overriding `canPerformAction(_:withSender:)` to return `true` for `undo:` / `redo:` does not help — the tool picker doesn't use that path.

Source: https://developer.apple.com/forums/thread/651788 (confirmed by community, 2020)

## The Fix

Register a real undo action on the VC's `undoManager` each time a stroke is committed. The action sends `Undo` to Mac. Inside the undo handler, register a redo action that sends `Redo` to Mac and re-registers the undo (so the cycle continues).

```swift
func registerUndoAction() {
    undoManager?.registerUndo(withTarget: self) { vc in
        vc.onStrokeDelta?(.wrap(.undo(...)))
        vc.undoManager?.registerUndo(withTarget: vc) { vc2 in
            vc2.onStrokeDelta?(.wrap(.redo(...)))
            vc2.registerUndoAction()  // re-register for next undo
        }
    }
}
```

Called from `OverlayCoordinator.commitStrokesToAnnotations` via `onStrokeCommitted` callback → `DrawingViewController.registerUndoAction()`.

Clear the stack on document load: `undoManager?.removeAllActions()`.

## Why the Responder Chain Approach Didn't Work

Before the annotation system, strokes lived on the canvas. PKToolPicker's undo/redo operated on `PKCanvasView`'s internal undo stack (which tracked canvas drawing changes). This worked automatically.

After moving strokes to annotations, the canvas is always empty. PKToolPicker sees an empty undo stack and disables its buttons. The `@objc undo(_:)` / `redo(_:)` methods on the VC were never called by the tool picker — they were only reachable via the system responder chain (⌘Z on a keyboard), which is a different path.

## Additional Gotcha: First Responder Loss

Page re-insert (`doc.removePage` + `doc.insert`) — used to force PDFKit to visually refresh after annotation removal — causes `PKCanvasView` to steal first responder from the VC. This doesn't affect PKToolPicker undo/redo (which uses `undoManager` directly), but it would break any responder-chain-based undo. Fixed by calling `becomeFirstResponder()` on the VC after each page re-insert via `onNeedsFirstResponder` callback.
