import FlightCore
import FlightWeb
import Foundation
import HTTPTypes
import Logging

extension RequestContext {
    /// §7: a ready-made context for exercising middleware and handlers
    /// without any transport. Backed by a fresh scope and (by default) an
    /// empty frozen container; pass a `TestContainer.build`-produced
    /// container to make `context.resolve` meaningful.
    public static func mock(
        method: HTTPRequest.Method = .get,
        path: String = "/",
        headers: HTTPFields = [:],
        body: Data = Data(),
        pathParameters: [String: String] = [:],
        container: Container? = nil
    ) -> RequestContext {
        var logger = Logger(label: "flight.web.test")
        logger.logLevel = .critical
        return RequestContext(
            request: Request(method: method, path: path, headers: headers, body: body),
            pathParameters: pathParameters,
            scope: Scope(),
            logger: logger,
            tracingContext: .topLevel,
            container: container ?? TestContainer.empty()
        )
    }
}
