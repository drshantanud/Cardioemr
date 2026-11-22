"""Bearer token verification.  The API trusts only signed OIDC access tokens;
it never accepts a user id from a header."""
from __future__ import annotations

import jwt
from fastapi import Request

from .errors import Problem

ALGORITHMS = ["RS256", "ES256"]


class TokenVerifier:
    def __init__(self, issuer: str, audience: str, jwks_url: str | None = None, jwk_client=None):
        if not issuer:
            raise RuntimeError("CEMR_OIDC_ISSUER is not set")
        self.issuer, self.audience = issuer, audience
        self._jwks = jwk_client or (jwt.PyJWKClient(jwks_url, cache_keys=True) if jwks_url else None)
        if self._jwks is None:
            raise RuntimeError("CEMR_OIDC_JWKS_URL is not set")

    def subject(self, token: str) -> str:
        try:
            key = self._jwks.get_signing_key_from_jwt(token).key
            claims = jwt.decode(token, key, algorithms=ALGORITHMS, audience=self.audience, issuer=self.issuer,
                                options={"require": ["exp", "iat", "sub", "iss", "aud"]})
        except jwt.PyJWTError as e:
            raise Problem(401, "UNAUTHENTICATED", "Token not accepted", detail=str(e)) from None
        return claims["sub"]


def bearer_subject(request: Request) -> str:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise Problem(401, "UNAUTHENTICATED", "Bearer token required")
    return request.app.state.verifier.subject(token)
