import AppKit

for screen in NSScreen.screens {
    print("frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
}
print("mouse=\(NSEvent.mouseLocation)")
