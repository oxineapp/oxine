import AppKit

@MainActor
extension NSWindow {
    /// Classes we've already patched, so we never add the method twice.
    private static var patchedGlassClasses = Set<ObjectIdentifier>()

    /// Force this window's *class* to report key appearance, so SwiftUI Liquid
    /// Glass (and vibrancy) renders its lively, refractive state even though our
    /// accessory app is never frontmost.
    ///
    /// Glass falls back to a plain blur whenever its window lacks key appearance.
    /// The notch panel never becomes key (we deliberately don't activate on hover),
    /// so without this it always looks dead. We patch the concrete window class
    /// (DynamicNotchKit's `DynamicNotchPanel`, which we don't own) via the ObjC
    /// runtime instead of subclassing, adding the override onto that one class so
    /// no other `NSWindow` in the app is affected. Only the read-only appearance
    /// getters are touched — overriding `canBecomeKey`/`canBecomeMain` is what
    /// crashes shortly after show, so we leave those alone.
    func forceActiveGlassAppearance() {
        guard let cls: AnyClass = object_getClass(self) else { return }
        let key = ObjectIdentifier(cls)
        guard !Self.patchedGlassClasses.contains(key) else { return }
        Self.patchedGlassClasses.insert(key)

        let always: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(always)
        // Both getters return Bool, so they share the same type encoding.
        guard let base = class_getInstanceMethod(NSWindow.self,
                                                 #selector(getter: NSWindow.isKeyWindow)),
              let types = method_getTypeEncoding(base) else { return }
        for sel in [#selector(getter: NSWindow.isKeyWindow),
                    Selector(("hasKeyAppearance"))] {
            // `DynamicNotchPanel` only inherits these from NSWindow, so addMethod
            // installs a class-specific override that shadows the inherited one.
            class_addMethod(cls, sel, imp, types)
        }
    }
}
