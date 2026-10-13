// The Mac stand-in for UIKit. Upstream files `import UIKit`; on macOS that
// import resolves to this module (PRODUCT_MODULE_NAME = UIKit), which
// re-exports AppKit and supplies the UIKit names upstream uses.
@_exported import AppKit

public typealias UIImage = NSImage
public typealias UIColor = NSColor
public typealias UIFont = NSFont
public typealias UIResponder = NSResponder
public typealias UIEdgeInsets = NSEdgeInsets
