//
//  main.swift
//  MenuBarItemService
//

import AXSwift
import Foundation

// Accessibility calls block until the target app responds, for up to about
// 6 seconds by default, and the app waits on the service's replies.
UIElement.globalMessagingTimeout = 1

SourcePIDCache.shared.start()
Listener.shared.activate()
RunLoop.current.run()
