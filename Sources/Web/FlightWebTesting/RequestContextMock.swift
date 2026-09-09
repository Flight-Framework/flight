import FlightCore
import FlightWeb
import Foundation
import HTTPTypes
import Logging

extension RequestContext {
    /// A ready-made context for exercising middleware and handlers without any
    /// transport. Handlers inject their dependencies (constructed for the
    /// test), so a context no longer carries a container to resolve from.
    public static func mock(
        method: HTTPRequest.Method = .get,
        path: String = "/",
        headers: HTTPFields = [:],
        body: Data = Data(),
        pathParameters: [String: String] = [:]
    ) -> RequestContext {
        var logger = Logger(label: "flight.web.test")
        logger.logLevel = .critical
        return RequestContext(
            request: Request(method: method, path: path, headers: headers, body: body),
            pathParameters: pathParameters,
            logger: logger,
            tracingContext: .topLevel
        )
    }
}
