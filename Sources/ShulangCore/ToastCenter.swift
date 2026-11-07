import Foundation

/// 提示消息的生命周期票据（P0-A4）。
///
/// 放在 Core 层以保持纯逻辑、可独立单测：每次显示新消息都会签发新票据，
/// 旧消息的定时任务持旧票据，调用 `shouldDismiss` 时不会清掉新消息。
/// 设计参考: 137137137/OpenDisk (MIT) — 仅借鉴「界面状态与异步定时解耦」的思路，源码独立实现，未复制任何代码。
public struct ToastCenter: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let id: UInt64
    }

    private var nextID: UInt64 = 0
    private var current: Ticket?

    public init() {}

    public var hasCurrent: Bool { current != nil }

    /// 签发一张新票据，并让此前所有票据失效。
    public mutating func issue() -> Ticket {
        nextID &+= 1
        let ticket = Ticket(id: nextID)
        current = ticket
        return ticket
    }

    /// 只有持有当前票据的定时任务才能清除消息；旧票据返回 false。
    public mutating func shouldDismiss(_ ticket: Ticket) -> Bool {
        guard current == ticket else { return false }
        current = nil
        return true
    }

    /// 用户手动关闭或界面主动清空。
    public mutating func clear() { current = nil }
}
