import AppKit
import StorPulseMacUI

let application = NSApplication.shared
let applicationDelegate = StorPulseApplicationDelegate()
application.delegate = applicationDelegate
application.run()
