//
//  URLSessionUpdateTransport.swift
//  PopopxMacNode — the one network client the signed-update checker and the
//  Discover aggregator may use.
//
//  Three refusals, all structural:
//
//  * https only;
//  * no redirects at all — a 3xx is an error, so a pinned host cannot hand the
//    request to a host nobody pinned;
//  * a hard byte ceiling, checked against the declared length *and* the bytes that
//    actually arrived.
//
//  The centres validate the address before calling this; the transport re-checks
//  the scheme because "the URL was checked upstream" is exactly the assumption a
//  redirect would exploit.
//

import Foundation

public struct URLSessionUpdateTransport: UpdateTransport, DiscoverTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 600)
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func fetch(_ url: URL, limit: Int) async throws -> Data {
        try requireHTTPS(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request, delegate: NoRedirects.shared)
        try inspect(response, limit: limit)
        guard data.count <= limit else { throw UpdateTransportError.tooManyBytes(limit: limit) }
        return data
    }

    public func download(_ url: URL, limit: Int, to destination: URL) async throws {
        try requireHTTPS(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (temporary, response) = try await session.download(for: request, delegate: NoRedirects.shared)
        try inspect(response, limit: limit)
        let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        guard size >= 0, size <= limit else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateTransportError.tooManyBytes(limit: limit)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateTransportError.notHTTPS(url.absoluteString)
        }
    }

    private func inspect(_ response: URLResponse, limit: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateTransportError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateTransportError.httpStatus(http.statusCode)
        }
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(limit) {
            throw UpdateTransportError.tooManyBytes(limit: limit)
        }
    }
}

/// Cancels every redirect. A refused redirect surfaces as the 3xx status, which
/// `inspect` turns into `httpStatus` — and `hostNotPinned` is reserved for the
/// case where a caller ever chooses to follow one deliberately.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}