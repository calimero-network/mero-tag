import Foundation

/// One place where "send it, and if the node refuses the credential do the right
/// thing" is decided, so the RPC, admin and blob clients cannot drift apart
/// about what a 401 or a 403 means.
///
/// The rule, in full:
///
/// - **2xx** → hand back the body.
/// - **401/403 with a refreshable reason** (`token_expired`) → refresh once
///   through `SessionAuthority`, rebuild the request with the new token and
///   send it again. Exactly once: a second refusal for the same credential was
///   never about expiry.
/// - **401/403 with a terminal reason** (`token_revoked`, `token_reuse`,
///   `permission_denied`, `invalid_node`, `invalid_token`) → `authRevoked`. Not
///   `.http(403, …)`: a caller that sees a plain forbidden response retries it,
///   and every retry re-sends a credential the node has already destroyed.
/// - anything else → `.http(status, body)`, untouched.
struct AuthorizedTransport {
    let session: URLSession
    let authority: SessionAuthority

    /// - Parameters:
    ///   - build: builds the request for a given bearer token. Called again
    ///     with the refreshed token if the first attempt is refused.
    ///   - onUnauthorized: legacy notification, fired on the first 401 only.
    func send(
        build: (String?) -> URLRequest,
        onUnauthorized: (() -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse?) {
        let (token, generation) = await authority.credential()
        let (data, response) = try await perform(build(token))

        guard let http = response as? HTTPURLResponse, let failure = http.authFailure else {
            return (data, response as? HTTPURLResponse)
        }
        if http.statusCode == 401 { onUnauthorized?() }

        let refreshed: String
        do {
            refreshed = try await authority.recover(from: failure, generation: generation)
        } catch let revoked as MeroError {
            if case .authRevoked = revoked { throw revoked }
            // The refresh itself could not be delivered (offline, DNS, …). That
            // says nothing about the session, so report what the node actually
            // said rather than inventing a logout.
            throw MeroError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let (retryData, retryResponse) = try await perform(build(refreshed))
        if let retryHttp = retryResponse as? HTTPURLResponse, let again = retryHttp.authFailure {
            // Refused again on a token minted seconds ago. Whatever this is, it
            // is not expiry — end the session rather than loop.
            throw MeroError.authRevoked(again.isRefreshable ? .invalidToken : again)
        }
        return (retryData, retryResponse as? HTTPURLResponse)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw MeroError.transport(error.localizedDescription)
        }
    }
}

/// Throw for any non-2xx that is not already an auth refusal.
func ensureSuccess(_ response: HTTPURLResponse?, _ data: Data, fallbackBody: String? = nil) throws {
    guard let response, !(200..<300).contains(response.statusCode) else { return }
    throw MeroError.http(
        status: response.statusCode,
        body: fallbackBody ?? String(data: data, encoding: .utf8) ?? ""
    )
}
