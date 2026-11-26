import Foundation

enum LidPowerService {
    static let identifier = "cn.zhaodk.glidecue.direct.power"
    static let plistName = identifier + ".plist"
}

@objc protocol LidPowerProtocol {
    func begin(reply: @escaping (String?) -> Void)
    func renew(reply: @escaping (String?, String?) -> Void)
    func end(reply: @escaping (String?) -> Void)
}
