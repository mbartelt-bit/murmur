use super::*;

#[test]
fn pkce_matches_rfc7636_vector() {
    assert_eq!(
        challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
}
#[test]
fn callback_requires_state_and_issued_client() {
    assert_eq!(
        callback(
            "/auth/callback?state=s&code=c&client_id=oaiapp_test",
            "s",
            None
        )
        .unwrap(),
        ("c".into(), "oaiapp_test".into())
    );
    for target in [
        "/auth/callback?state=wrong&code=c&client_id=oaiapp_test",
        "/auth/callback?state=s&state=s&code=c&client_id=oaiapp_test",
        "/auth/callback?state=s&code=c&client_id=dynamic_agent_client",
        "/callback?state=s&code=c&client_id=oaiapp_test",
        "/auth/callback?state=s&code=c",
        "/auth/callback?state=s&error=access_denied",
    ] {
        assert!(callback(target, "s", None).is_err(), "accepted {target}");
    }
}
#[test]
fn returning_callback_cannot_replace_registration() {
    assert!(callback(
        "/auth/callback?state=s&code=c",
        "s",
        Some("oaiapp_original")
    )
    .is_ok());
    assert!(callback(
        "/auth/callback?state=s&code=c&client_id=oaiapp_other",
        "s",
        Some("oaiapp_original")
    )
    .is_err());
}
#[test]
fn nonce_future_issuance_and_authorized_party_checked() {
    let mut c = Claims {
        sub: "s".into(),
        email: None,
        nonce: Some("n".into()),
        iat: 100,
        exp: 200,
        aud: serde_json::json!("client"),
        azp: None,
    };
    assert!(validate_claim_details(&c, "client", Some("n"), 100).is_ok());
    assert!(validate_claim_details(&c, "client", Some("wrong"), 100).is_err());
    assert!(validate_claim_details(&c, "client", Some("n"), 90).is_err());
    c.aud = serde_json::json!(["client", "other"]);
    assert!(validate_claim_details(&c, "client", Some("n"), 100).is_err());
    c.azp = Some("client".into());
    assert!(validate_claim_details(&c, "client", Some("n"), 100).is_ok());
}
#[test]
fn discovery_cannot_redirect_credentials_to_another_origin() {
    assert!(auth_endpoint("https://auth.openai.com/.well-known/jwks.json").is_ok());
    for url in [
        "https://evil.test/revoke",
        "http://auth.openai.com/revoke",
        "https://auth.openai.com:8443/revoke",
        "https://user@auth.openai.com/revoke",
    ] {
        assert!(auth_endpoint(url).is_err());
    }
}
#[test]
fn token_scopes_never_assumed_at_first_sign_in() {
    let response = TokenResponse {
        access_token: "a".into(),
        refresh_token: Some("r".into()),
        id_token: None,
        token_type: "Bearer".into(),
        expires_in: 3600,
        scope: None,
    };
    assert!(token_set(response, None).unwrap().scopes.is_empty());
}
#[test]
fn rotated_refresh_and_scope_reduction_replace_old_values() {
    let old = Tokens {
        access_token: "old".into(),
        refresh_token: Some("old-refresh".into()),
        id_token: Some("id".into()),
        scopes: vec![PLAN_SCOPE.into()],
        expires_at: 0,
    };
    let response = TokenResponse {
        access_token: "new".into(),
        refresh_token: Some("new-refresh".into()),
        id_token: None,
        token_type: "Bearer".into(),
        expires_in: 3600,
        scope: Some("openid".into()),
    };
    let result = token_set(response, Some(&old)).unwrap();
    assert_eq!(result.refresh_token.as_deref(), Some("new-refresh"));
    assert_eq!(result.id_token.as_deref(), Some("id"));
    assert!(!result.scopes.iter().any(|s| s == PLAN_SCOPE));
}
#[test]
fn incomplete_stream_never_returns_partial_cleanup() {
    assert!(response_text(
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\ndata: [DONE]\n\n"
    )
    .is_err());
    assert!(response_text("data: {\"type\":\"response.incomplete\"}\n\n").is_err());
}
#[test]
fn only_completed_assistant_text_is_accepted() {
    let body = serde_json::json!({"type":"response.completed","response":{"status":"completed","output":[
        {"type":"reasoning","content":[{"type":"output_text","text":"secret reasoning"}]},
        {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello, world."}]}
    ]}});
    assert_eq!(
        response_text(&format!("data: {body}\r\n\r\n")).unwrap(),
        "Hello, world."
    );
    let refusal = serde_json::json!({"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"refusal","refusal":"No"}]}]}});
    assert!(response_text(&format!("data: {refusal}\n\n")).is_err());
}

// This deliberately public, generated fixture is exclusively a test signing key.
// It has never represented a real account and must never be used in production.
#[test]
fn identity_signature_issuer_audience_expiry_and_nonce_are_verified() {
    use jsonwebtoken::{encode, EncodingKey, Header};
    let keys: JwkSet = serde_json::from_str(include_str!("fixtures/test-only-jwks.json")).unwrap();
    let key = EncodingKey::from_ec_pem(include_bytes!("fixtures/test-only-ec.pem")).unwrap();
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some("test-only".into());
    let claims = serde_json::json!({"sub":"test-user","iss":ISSUER,"aud":"oaiapp_test","iat":now(),"exp":now()+300,"nonce":"n"});
    let token = encode(&header, &claims, &key).unwrap();
    assert!(verify_identity_with_keys(&token, "oaiapp_test", Some("n"), &keys).is_ok());
    assert!(verify_identity_with_keys(&token, "other-client", Some("n"), &keys).is_err());
    assert!(verify_identity_with_keys(&token, "oaiapp_test", Some("other-nonce"), &keys).is_err());
    for (field, value) in [
        ("iss", serde_json::json!("https://evil.test")),
        ("exp", serde_json::json!(now() - 60)),
        ("sub", serde_json::json!("")),
    ] {
        let mut bad = claims.clone();
        bad[field] = value;
        assert!(verify_identity_with_keys(
            &encode(&header, &bad, &key).unwrap(),
            "oaiapp_test",
            Some("n"),
            &keys
        )
        .is_err());
    }
    // Change signed claims without recomputing the signature.
    let mut pieces: Vec<String> = token.split('.').map(str::to_owned).collect();
    let mut tampered = claims.clone();
    tampered["sub"] = serde_json::json!("attacker");
    pieces[1] = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&tampered).unwrap());
    assert!(verify_identity_with_keys(&pieces.join("."), "oaiapp_test", Some("n"), &keys).is_err());
    let symmetric = encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(b"not-a-real-secret"),
    )
    .unwrap();
    assert!(verify_identity_with_keys(&symmetric, "oaiapp_test", Some("n"), &keys).is_err());
}

#[test]
fn failed_account_mutation_does_not_change_active_cached_account() {
    let mut v = Vault {
        active: Some("original".into()),
        ..Vault::default()
    };
    let result = transaction(
        &mut v,
        |candidate| {
            candidate.active = Some("different".into());
            Ok(())
        },
        |_| anyhow::bail!("locked credential store"),
    );
    assert!(result.is_err());
    assert_eq!(v.active.as_deref(), Some("original"));
    transaction(
        &mut v,
        |candidate| {
            candidate.active = Some("different".into());
            Ok(())
        },
        |_| Ok(()),
    )
    .unwrap();
    assert_eq!(v.active.as_deref(), Some("different"));
}
