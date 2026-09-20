# Warden refresh ownership and adapter contract

## Question and status

- Can an existing verified session refresh its access material without reusing authorization-code consumption or granting an unverified response authority to change identity?
- This note records primary-source inspection and a proposed interface experiment. It is not an executed refresh adapter or a conformance result.
- The reference remains `oidcc` 3.9.0 at commit `aa212d52d0140addf057c34917b734647401b34e`. The inspected `src/oidcc_token.erl` SHA-256 is `289be9bcb0e4677cba3dc98a3b4675070aec7beb27054726da395166b85ac2e3`.

## Protocol evidence

- A successful OIDC refresh may omit an ID token. If present, the refreshed ID token retains the original issuer, subject, and audience; a present authentication time describes the original authentication. A present nonce must retain its original value. Other ID-token validation requirements still apply. [OIDC Core §12.2](https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokenResponse)
- When the authorization server supplies a replacement refresh token, the client replaces the old token. The replacement refresh token retains the original refresh token's scope. [RFC 6749 §6](https://www.rfc-editor.org/rfc/rfc6749.html#section-6)
- Public-client refresh tokens require sender constraints or rotation. Rotation can revoke the active token when an invalidated predecessor is replayed; a client must not assume a retry is harmless. [RFC 9700 §4.14](https://www.rfc-editor.org/rfc/rfc9700.html#name-refresh-token-protection)

## Pinned backend evidence

- The raw refresh-token overload requires `expected_subject`. The token-record overload extracts it from the original ID-token claims. The refresh path requests the refresh grant, extracts the response, and accepts only a returned ID token whose subject matches. An absent returned ID token reaches `sub_invalid`. This is narrower than the OIDC response vocabulary. [Pinned refresh source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L576-L621)
- Refresh forces `nonce: any` before response extraction. Warden cannot claim that this call alone verifies continuity of a nonce returned in the new ID token. The wrapper must retain sufficient original evidence and check continuity when relevant. [Pinned refresh source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L605-L618)
- Response extraction returns `none` for an absent refresh token. It constructs a new token record rather than retaining the prior refresh token. Warden's custody owner therefore needs an explicit distinction between retaining the existing token and installing a replacement. [Pinned extraction source](https://github.com/erlef/oidcc/blob/aa212d52d0140addf057c34917b734647401b34e/src/oidcc_token.erl#L781-L890)

## Proposed ownership

- Refresh begins from a session reference, stored revision, original verified identity evidence, and a configured provider binding. It must not accept a different issuer, client, or backend merely because the native continuation types match.
- The custody owner serializes refresh admission for one token generation. A claim for an old session revision cannot publish new access material over a later revision.
- The refresh backend returns an explicit token update and optional verified identity attestation. An absent ID token preserves the established identity; it does not create a new authentication event.
- The pinned default adapter must declare its narrower response support. A scripted alternative may exercise the absent-ID-token case, while the default path must not fabricate an ID token or disguise the mismatch as success.
- The owner commits access material and any replacement refresh token together. No public successful result should expose rotated material before its custody transition is settled.
- A possibly transmitted request with no known response is an uncertain refresh outcome. Releasing the old token for an ordinary retry would invent evidence that the provider did not rotate it.
- Token custody, refresh admission, and replacement belong to one owner. Login callback state, code-consumption tombstones, and Relay resource grants remain different capabilities.

## Consumer and oracle obligations

- Exercise retained and replaced refresh tokens, absent and present ID tokens, issuer/subject/audience mismatch, stale session revision, overlapping refresh claims, definite endpoint rejection, proven no-send failure, and uncertain transmission.
- Include a lost-response case where the scripted provider has rotated its token. The local owner must retain uncertainty rather than admit a second ordinary refresh with the predecessor.
- Keep scope handling, expiry, logout-only ID-token hints, redacted errors, and original authentication evidence explicit in the token/session representation.
- Compile negative consumers that reject access tokens as refresh tokens, a session revision as a refresh claim, and unverified claims as verified identity.
- Run the same response corpus through the pinned backend before choosing the default adapter strategy. Current findings are source inspection; cryptographic validation, concurrency, secret inspection, and foreign-error mapping remain executable oracle work.
