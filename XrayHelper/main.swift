import Foundation

let listener = NSXPCListener(machServiceName: HelperMachServiceName)
let delegate = HelperDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
