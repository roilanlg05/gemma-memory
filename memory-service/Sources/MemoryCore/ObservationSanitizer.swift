import Foundation
import BrainContract

/// The gateway must discard raw tool bodies and headers before creating evidence or context.
/// Only these closed, structured fields may be rendered. No free-form strings are accepted.
public struct SafeToolObservation: Sendable {
    public enum Result: String, Sendable { case succeeded, failed, partial, unknown }
    public let result: Result
    public let httpStatus: Int?
    public init(result: Result, httpStatus: Int? = nil) {
        self.result = result
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    }
    /// Only the exact canonical rendering is admitted as persisted tool evidence.
    public static func admits(_ text: String) -> Bool {
        for result in [Result.succeeded, .failed, .partial, .unknown] {
            if text == SafeToolObservation(result: result).rendered { return true }
            let prefix = "result=\(result.rawValue); httpStatus="
            if text.hasPrefix(prefix), let status = Int(text.dropFirst(prefix.count)),
               (100...599).contains(status), text == SafeToolObservation(result: result, httpStatus: status).rendered { return true }
        }
        return false
    }
    public var rendered: String {
        if let httpStatus { return "result=\(result.rawValue); httpStatus=\(httpStatus)" }
        return "result=\(result.rawValue)"
    }
}
